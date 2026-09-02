# Troubleshooting

Every symptom below was hit and fixed while validating this build. The
first-boot log inside the VM is `C:\winbuild.log`; Windows Setup logs are under
`C:\Windows\panther\` (and `setuperr.log` for sysprep failures).

## "No Bootable Device" — the ISO clone is empty

**Cause:** the `winbuild-iso` PVC was cloned from the install-ISO image using a
*generic* StorageClass (e.g. `harvester-longhorn` or any class you'd use for a
normal data disk). Harvester only populates an `imageId`-annotated clone when
the PVC uses the **image's own dedicated StorageClass**, which carries the
backingImage reference. With a generic class you get a correctly-sized but
all-zero volume — no `CD001` / El Torito boot record — so nothing boots.

**Fix:** set the ISO PVC's `storageClassName` to the image's dedicated class:

```bash
kubectl get vmimage <image-name> -o jsonpath='{.status.storageClassName}'
# e.g. longhorn-image-xxxxx  → put that in winbuild-vm.yaml's winbuild-iso template
```

Verify the clone is real:

```bash
# on the node, the first bytes of the ISO block device should contain CD001
```

## `unsupported access mode MULTI_NODE_MULTI_WRITER`

**Cause:** the rootdisk PVC requested `ReadWriteMany` on a StorageClass that
only supports ReadWriteOnce (block-mode / LVM-based CSI classes typically are
RWO-only; Longhorn supports RWX).

**Fix:** set the rootdisk `accessModes: [ReadWriteOnce]`. RWO is always
sufficient here — the build VM is the disk's only consumer.

## oobeSystem: "the answer file is invalid"

**Symptom:** Windows installs (`windowsPE` passes, files copy), then first boot
fails validating `C:\Windows\panther\unattend.xml` for the `oobeSystem` pass.

**Cause:** a `FirstLogonCommands` `<CommandLine>` exceeded the **1024-character**
limit — typically from folding `bootstrap.ps1` into the answer file with chunks
that are too large.

**Fix:** regenerate with `build-answerfile.py` (700-char chunks). Then do a
**clean reinstall** — delete the VM *and* the rootdisk PVC. Windows caches the
bad answer file at `C:\Windows\panther\unattend.xml`, so a mere reboot
re-validates the cached copy; you must wipe the rootdisk so `windowsPE` re-copies
the fixed file.

## Deployed VM boot-loops: "The computer restarted unexpectedly" (only with a cloud-init disk)

**Symptom:** a VM cloned from the golden image boots, shows the "Getting ready" /
mini-setup screens (looks like it's "re-running sysprep"), then fails with **"The
computer restarted unexpectedly or encountered an unexpected error. Windows
installation cannot proceed."** and loops. It only happens when a **cloud-init /
NoCloud disk** (user-data) is attached; the same image deploys fine without one.

**Cause:** on first boot the main Cloudbase-Init **service** runs *during* the
sysprep **specialize** pass. It finds the NoCloud metadata, `SetHostNamePlugin`
sets the hostname — which requires a reboot — and if `allow_reboot` is left at its
**default of `true`**, the service **reboots the machine itself**, out from under
Windows Setup. Setup sees an unsanctioned restart mid-pass and bails with the
error above. The concurrent specialize instance logs the tell-tale
`ExtendVolumesPlugin failed ... 'A system shutdown is in progress.'`, and
`C:\Windows\Panther\setupact.log` shows `Unattend action requested immediate
reboot and recall` / `Restarting machine during first boot phase`.

Without a metadata disk there's no hostname to set, so nothing reboots and
specialize completes — which is why it looks intermittent.

**Fix:** set **`allow_reboot=false`** in **`cloudbase-init.conf`** (the main
service config) — not just in `cloudbase-init-unattend.conf`. The hostname is then
just written to the registry and applied by Setup's own sanctioned reboot at the
end of specialize. `bootstrap.ps1` now writes both `allow_reboot=false` and
`stop_service_on_exit=false` into the main config. To repair an **existing**
golden image without a full rebuild, offline-mount its rootdisk and append those
two lines to `…\Cloudbase-Init\conf\cloudbase-init.conf`, then re-export.

## sysprep: "a fatal error occurred while trying to sysprep the machine" (0x80073cf2)

**Symptom:** `bootstrap.ps1` runs, but sysprep aborts.
`C:\Windows\System32\Sysprep\Panther\setuperr.log` shows:

```
SYSPRP Package Microsoft.MicrosoftEdge.Stable_… was installed for a user,
       but not provisioned for all users
SYSPRP Failed to remove apps for the current user: 0x80073cf2
SYSPRP Exit code of RemoveAllApps: 0x3cf2
[0x0f0082] SYSPRP … AppxSysprep.dll … 0x80073cf2
```

**Cause:** an AppX package is **installed for the current user but not
provisioned for all users** (or provisioned at an older version than the per-user
copy) — sysprep `/generalize` refuses.

The reason a *freshly installed* Windows drifts into that state mid-build is
that the build VM has outbound internet (it downloads Cloudbase-Init), so
**Windows Update and the Microsoft Store service the machine while the build
runs**. The Store updates a preinstalled app for the Administrator account only
and the mismatch appears. On Server 2025 the repeat offender is
`Microsoft.DesktopAppInstaller` (winget); on older media it is usually Chromium
Edge (`Microsoft.MicrosoftEdge.Stable`).

**Fix:** `bootstrap.ps1` step 0a freezes servicing for the duration of the
build, *before* anything else runs — stop and disable `wuauserv`, `UsoSvc`,
`WaaSMedicSvc`, `InstallService` and `DoSvc`, and set the `WindowsStore`
`AutoDownload=2` / `WindowsUpdate` `NoAutoUpdate=1` policies. The AppX state
then stays exactly as the install media shipped it and generalize is satisfied.
Step 5b writes `C:\Windows\Setup\Scripts\SetupComplete.cmd`, which Windows Setup
runs once on every clone of the image, to put servicing back — so the golden
image does not ship with Windows Update permanently disabled.

> **Gotcha — do not try to repair the drift after the fact.** Earlier revisions
> of `bootstrap.ps1` tried to remove and then re-provision AppX packages to make
> provisioned == installed. Every variant of that made things worse:
>
> - Blanket `Remove-AppxProvisionedPackage` *manufactures* the failure. Deprovision
>   a package whose per-user copy then refuses to uninstall and you have created
>   the exact mismatch generalize aborts on.
> - `Remove-AppxPackage -AllUsers` can **deadlock indefinitely at 0% CPU**. Nothing
>   in the AppX deployment stack times out, so one stuck package wedges the whole
>   build. (Wrapping each call in `Start-Job`/`Wait-Job -Timeout` bounds it, but
>   only converts a hang into a skipped package.)
> - `Add-AppxProvisionedPackage` re-stages every package into
>   `C:\Program Files\WindowsApps`. Run over ~30 packages, twice, that **filled a
>   36 GiB build disk**: sysprep then ran with negative reported free space
>   (`fsutil volume diskfree c:` showed `Total free bytes: -425,984`) and failed
>   anyway — this time for lack of space, on a *different* package each run.
>
> Prevent the drift; don't chase it.

## virtio-scsi: Setup shows "no disks found"

**Cause:** the rootdisk is `bus: scsi` but the answer file has no WinPE
`DriverPaths` block, so Setup has no virtio-scsi driver and can't see the disk.
(Windows ships no in-box virtio driver.)

**Fix:** include the `Microsoft-Windows-PnpCustomizationsWinPE` → `DriverPaths`
component (present in both answer files), pointing at the optical-drive letters
the VMDP CD might take in WinPE (`D:`–`G:`). Or, to skip driver injection
entirely, set the rootdisk to `bus: sata` (slower install, native AHCI).

> The VMDP CD (`registry.suse.com/suse/vmdp/vmdp:2.5.5`) ships **loose,
> WHQL-signed** per-OS drivers (`pvvxscsi.inf`/`vioscsi.inf` for virtio-scsi —
> SUSE uses the `pvvx*` prefix — plus `pvvxblk.inf`/`vrtioblk.inf`, in `2k22` /
> `2k25` / `amd64` folders), which is exactly what `drvload`/DriverPaths needs.

## Setup dies with "Error code: 0xD000A000 - 0x40031"

**Symptom:** Setup starts, then fails early with
*"Windows installation encountered an unexpected error. Error code:
0xD000A000 - 0x40031"*. Pressing **Shift+F10** for a WinPE prompt and running
`diskpart` → `list disk` reports **no fixed disks**.

**Cause:** the `DriverPaths` entries point at *drive roots* (`D:\`, `E:\`, …).
Setup then recursively scans each whole volume for INFs — including the
multi-GB Windows install ISO and every other OS's folder on the VMDP CD. On
larger media (Server 2025) that exceeds whatever time/depth budget DriverPaths
has, so Setup reaches `DiskConfiguration` with no virtio-scsi driver loaded and
cannot find the disk named in `ImageInstall`.

Confirm it by `drvload`-ing the driver by hand from the Shift+F10 prompt:

```
drvload D:\Server2022-25-Win11\x64\pvvxscsi.inf
diskpart
  list disk        # the disk now appears
```

If that works instantly, the driver is fine and the scan was the problem.

**Fix:** point each `PathAndCredentials` at the **exact nested driver folder**,
not the CD root — `D:\Server2022-25-Win11\x64` etc. (this is what the checked-in
answer files do). Missing drive letters are skipped, so listing `D:`–`G:` costs
nothing.

## The build fills the disk / sysprep fails with no space

Check from inside the build VM:

```
fsutil volume diskfree c:
```

A near-zero — or *negative* — "Total free bytes" means the free-space zero-fill
in `bootstrap.ps1` step 5c ran to `ENOSPC`. NTFS does not hand every byte back
the moment the fill file is deleted, so sysprep `/generalize` then has nowhere
to write and fails (usually surfacing as some *other* error, e.g. 0x80073cf2).

**Fix:** step 5c reserves `$reserve = 2GB` and stops the fill there instead of
running to `ENOSPC`, and aborts the build with a clear log line if under 1 GiB
is free before sysprep. Raise `$reserve` if you add more to the image.

> A build disk that is genuinely too small shows the same way. 36 GiB is enough
> for Server 2022/2025 + VMDP + Cloudbase-Init with the 2 GiB reserve.

## VMDP setup pops an interactive dialog instead of installing silently

**Cause:** running the wrong `setup.exe`. The `setup.exe` at the VMDP ISO root is
a menu wrapper that shows a dialog; and passing silent flags as a
`Start-Process -ArgumentList` **array** re-tokenizes the command line and
triggers the dialog too.

**Fix (in `bootstrap.ps1`):** extract the self-extracting `VMDP-WIN-2.5.5.exe`
first, then run its *inner* `setup.exe` with the flags as a **single string**:
`'/lic_accepted /no_reboot'`.

## VMDP CD not found / wrong drive letter

**Cause:** the drive letter of the VMDP CD shifts depending on disk bus and
order (a virtio-scsi rootdisk changes lettering vs SATA).

**Fix:** `bootstrap.ps1` scans every filesystem drive for
`VMDP-WIN-2.5.5.exe` instead of hardcoding a letter.

## The build VM restarts instead of staying off

`runStrategy: RerunOnFailure` restarts a VM that exits non-zero, but a clean
sysprep `/shutdown` is a graceful power-off, so the VM stays `Stopped`. If it
loops, sysprep failed — check `setuperr.log` (see 0x80073cf2 above). A `Normal`
event *"The VirtualMachineInstance was shut down"* is the success signal.

## Windows 11 sysprep hangs on `Sysprep_Clean_Validate_Opk`

Intermittent (~50%) on Windows 11 builds; Server 2022 is reliable. Usually
Store apps that don't generalise cleanly — the servicing freeze in step 0a is
the mitigation. If it recurs, delete the VM + rootdisk and retry.

## Cloudbase-Init didn't personalise the cloned VM

- Confirm the image was captured from a **sysprepped** rootdisk (VM reached
  `Stopped` via sysprep `/shutdown`, not a manual power-off).
- Check `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\` in the cloned
  VM.
- Confirm the consumer VM actually has a cloud-config / user-data attached
  (KubeVirt `cloudInitNoCloud` or a Harvester cloud-config template).

## Cloud-config doesn't show up in the Harvester UI's "Cloud Config" tab

**Symptom:** the VM's user-data is being applied correctly by Cloudbase-Init
(hostname/user creation works, `AgentConnected=True`), but the Harvester UI
shows no cloud-config for the VM.

**Cause:** the UI's cloud-config tab reads the backing **Secret**, not just the
VM's `cloudInitNoCloud` volume reference. Two things on the Secret are
required for the UI to recognize it — KubeVirt/Cloudbase-Init don't care about
either, so a Secret missing them still works functionally, it just won't
render in the UI:

1. **`type: secret`** (the Kubernetes Secret `type` field) — a default
   `Opaque` secret with identical `data`/`stringData` is invisible to the UI's
   picker.
2. The label `harvesterhci.io/cloud-init-template: harvester`.

```yaml
apiVersion: v1
kind: Secret
type: secret                 # not Opaque
metadata:
  name: my-vm-cloudinit
  labels:
    harvesterhci.io/cloud-init-template: harvester
stringData:
  userdata: |
    #cloud-config
    ...
  networkdata: ""
---
# VM volume, referencing it the normal KubeVirt way:
volumes:
  - name: cloudinitdisk
    cloudInitNoCloud:
      secretRef:            # NOT userDataSecretRef — that field doesn't exist
        name: my-vm-cloudinit
      networkDataSecretRef:
        name: my-vm-cloudinit
```

Confirmed by diffing a hand-written manifest (booted fine, cloud-init applied,
but no UI tab) against a VM created through the Harvester UI itself — the only
structural difference was the Secret's `type`.
