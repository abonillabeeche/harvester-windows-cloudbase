# How it works

This project turns a stock Windows installation ISO into a **reusable,
cloneable Harvester golden image** that behaves like the Linux cloud images do:
create a VM from it, hand it a cloud-config, and it personalises itself on first
boot.

There are three moving parts: **Windows Setup automation** (the answer file),
**a first-boot provisioner** (`bootstrap.ps1`), and **Cloudbase-Init** (the
per-VM personalisation engine baked into the image). A build VM wires them
together; when it powers itself off, its rootdisk *is* the golden image.

```
                       build VM (winbuild)
  ┌───────────────────────────────────────────────────────────┐
  │  CD0  Windows ISO   (boots Setup)                           │
  │  CD1  VMDP driver pack  (registry.suse.com/suse/vmdp)       │
  │  CD2  sysprep ISO   (autounattend.xml  [+ bootstrap.ps1])   │
  │  DISK rootdisk      (virtio-scsi, becomes the golden image) │
  └───────────────────────────────────────────────────────────┘
        │
        ▼
  windowsPE pass ──► load virtio-scsi driver from VMDP CD (DriverPaths)
        │            wipe + partition rootdisk, apply the WIM
        ▼
  oobeSystem pass ─► auto-logon Administrator, run FirstLogonCommands
        │
        ▼
  bootstrap.ps1 ───► install VMDP (virtio + qemu-guest-agent)
        │            install Cloudbase-Init + write its conf
        │            strip sysprep-blocking AppX packages
        │            delete build scratch + zero free space
        ▼
  sysprep /generalize /oobe /shutdown  (with Cloudbase-Init's Unattend.xml)
        │
        ▼
  VM powers off ──► rootdisk PVC is now a clean, generalised base
                    export it → VirtualMachineImage
```

## 1. The sysprep volume

KubeVirt has a first-class [`sysprep`
volume](https://kubevirt.io/user-guide/virtual_machines/startup_scripts/#sysprep):
it mounts a Secret (or ConfigMap) as a CD-ROM ISO, and Windows Setup
automatically looks for `autounattend.xml` on any attached media during the
`windowsPE` pass. That's the whole delivery mechanism — no PXE, no custom ISO
remastering.

```yaml
- name: sysprep
  sysprep:
    secret:
      name: winbuild-unattend
```

Every key in the Secret becomes a file at the root of that ISO. That detail
drives the two supported answer-file layouts (see below).

## 2. The answer file (`Autounattend-<version>.xml`)

A Windows unattend file scripts Setup across several *passes*. We use two:

- **`windowsPE`** — runs inside the Windows pre-install environment. Here we:
  - load the **virtio-scsi driver** from the VMDP CD via
    `Microsoft-Windows-PnpCustomizationsWinPE` → `DriverPaths`, so Setup can see
    a `bus: scsi` rootdisk. (Without it, a virtio-scsi disk is invisible and
    Setup reports "no disks found". A `bus: sata` disk needs no driver but
    installs noticeably slower.)
  - wipe and partition the rootdisk and apply the Windows image (`ImageInstall`
    → `/IMAGE/NAME` must match an edition inside the ISO's `install.wim`).

  Both of these are why there is one base answer file **per Windows version** —
  the edition string differs, and Windows 11 needs a UEFI/GPT partition layout
  where the Server releases use BIOS. See
  [windows-versions.md](windows-versions.md).
- **`oobeSystem`** — runs on first boot. Here we auto-logon Administrator and
  fire `FirstLogonCommands`, which launches `bootstrap.ps1`.

The `C:` partition is created with `<Extend>true</Extend>`, so it fills whatever
rootdisk it's installed onto. Build on a small disk to get a small image — see
[shrink-and-export.md](shrink-and-export.md).

## 3. Two answer-file layouts

Because the sysprep Secret turns each key into a file, there are two ways to
ship `bootstrap.ps1`:

| Layout | Secret keys | How bootstrap is found | Use it for |
|---|---|---|---|
| **Two-file** | `autounattend.xml` + `bootstrap.ps1` | `FirstLogonCommands` scans the optical drives for `bootstrap.ps1` | `kubectl` and Terraform |
| **Single-file** | `autounattend.xml` only | `bootstrap.ps1` is base64-folded *into* `FirstLogonCommands` | the Harvester UI's **Windows Unattended & Sysprep** form (v1.9+), which only writes one key |

`build-answerfile.py -w <version>` converts the two-file sources into the
single-file artifact. See [ui-sysprep.md](ui-sysprep.md).

## 4. `bootstrap.ps1` — the first-boot provisioner

Runs once, at first logon, logging to `C:\winbuild.log`:

1. **Find the VMDP CD by content** (scan every drive for `VMDP-WIN-2.5.5.exe` —
   drive letters shift with disk bus/order).
2. **Install VMDP** — the SUSE Virtual Machine Driver Pack: WHQL-signed virtio
   drivers **and** `qemu-guest-agent` as a Windows service. (The ISO-root
   `setup.exe` is just a menu wrapper; the real installer is the self-extracting
   `VMDP-WIN-*.exe`, run with `/lic_accepted /no_reboot` as a single arg
   string.)
3. **Install Cloudbase-Init** and overwrite its conf for KubeVirt's `NoCloud`
   metadata (see below).
4. **Remove AppX packages** that make sysprep `/generalize` fail with
   `0x80073cf2` (Microsoft Edge is the usual culprit).
5. **Minimize** — delete build scratch, zero free space (for a compact export).
6. **`sysprep /generalize /oobe /shutdown`** using *Cloudbase-Init's own*
   `Unattend.xml`, which re-arms Cloudbase-Init to run on the next boot.

## 5. Cloudbase-Init — the "cloud-init for Windows"

[Cloudbase-Init](https://cloudbase.it/cloudbase-init/) is the Windows analogue
of cloud-init. Baked into the image and re-armed by sysprep, it runs on the
**first boot of every cloned VM** and reads the `NoCloud` config drive that
KubeVirt/Harvester attaches from the VM's cloud-config.

Two conf profiles are written:

- `cloudbase-init.conf` — the main run: applies users, passwords, network,
  `runcmd`, etc. from your per-VM cloud-config.
- `cloudbase-init-unattend.conf` — the specialize/sysprep run: a minimal plugin
  set including **`ExtendVolumesPlugin`**, which grows `C:` to fill the target
  disk. This is why a 36 GiB image deployed onto a 200 GiB VM disk comes up with
  a 200 GiB `C:` — no manual `diskpart`.

## 6. "Clean up so it comes back clean"

There is no `cloudbase-init clean` command on Windows. The reset is
`sysprep /generalize`: it removes the machine SID and per-machine state, and —
because we pass Cloudbase-Init's `Unattend.xml` — it re-arms Cloudbase-Init for
the deployed image's first boot. The "sysprep plugin" you may see running is
Cloudbase-Init arming itself. Combined with the scratch-delete + zero-free-space
step, the powered-off rootdisk is a clean, compact, generalised base ready to
capture as a `VirtualMachineImage`.
