# Driving the build from the Harvester UI (Windows Unattended & Sysprep)

Harvester v1.9 adds a **Windows Unattended & Sysprep** section to the VM create
form. It lets you attach a sysprep answer file to a Windows VM without hand-writing
the `sysprep` volume. This page explains how that form consumes the answer file,
and how to make *this project's* build run through it.

## What the UI actually creates

The form creates (or reuses) a Kubernetes **Secret with exactly one key:
`autounattend.xml`**, and wires it into the VM as a `sysprep` volume. Before it
accepts the content it validates, client-side, that the XML:

- parses, and
- has the root namespace `urn:schemas-microsoft-com:unattend`
  (i.e. `<unattend xmlns="urn:schemas-microsoft-com:unattend">`).

Both `Autounattend.xml` and `Autounattend-w11.xml` in this repo pass that check.

## The constraint: one file only

The UI has **no field for a second file**. Our first-boot logic lives in
`bootstrap.ps1`, and the two-file layout (`kubectl`/Terraform) relies on that
script riding the sysprep CD as its own file. Through the UI, only
`autounattend.xml` reaches the CD — so a plain answer file that points at
`bootstrap.ps1` would never find it.

The fix is to **fold `bootstrap.ps1` into the answer file itself.**

## `build-answerfile.py`

```bash
cd kubectl/
./build-answerfile.py           # reads Autounattend.xml + bootstrap.ps1
# → writes Autounattend-selfcontained.xml
```

It base64-encodes `bootstrap.ps1`, splits it into ≤700-character chunks, and
rewrites `FirstLogonCommands` to:

1. append each chunk to `C:\Windows\Temp\bootstrap.b64` with
   `cmd /c echo <chunk>>>...`,
2. decode it to `C:\bootstrap.ps1`
   (`[Convert]::FromBase64String((Get-Content -Raw ...))` — base64 ignores the
   CRLFs `echo` inserts), then
3. run it.

> **Why 700-char chunks?** A `FirstLogonCommands` `<CommandLine>` has a hard
> **1024-character limit**. Exceed it and `windowsPE` still passes (the OS
> installs) but the `oobeSystem` pass fails with
> *"C:\Windows\panther\unattend.xml … the answer file is invalid."* 700 base64
> chars + the `cmd /c echo …>>path` wrapper stays comfortably under 1024.

The script prints the longest generated `CommandLine` and asserts it's < 1024,
so a too-large `bootstrap.ps1` fails loudly at generation time instead of
mid-install.

## Using it in the UI

1. Generate `kubectl/Autounattend-selfcontained.xml`.
2. **Virtual Machines → Create → From Template →**
   `windows-iso-image-base-template` (namespace `harvester-public`, the stock
   built-in). It provides the CD-ROM boot disk, a rootdisk, and the VMDP driver
   CD (`registry.suse.com/suse/vmdp/vmdp:2.5.5`). Set the CD-ROM's **Image** to
   your Windows ISO; on the **Volume** tab set the rootdisk bus to
   **virtio-scsi** and reduce it to **32Gi** (access mode
   **Single-Node/ReadWriteOnce** on `lvm-thin`); under **Advanced Options**
   enable the **Hyper-V enlightenments** for a fast install.
3. **Advanced Options → set OS Type = `Windows`.** The **Windows Unattended &
   Sysprep Configuration** section only appears once the OS type is Windows.
   Then **Create New**, name the secret (e.g. `winbuild-unattend`), and paste
   the contents of `Autounattend-selfcontained.xml`.
4. **Create.** The VM installs, sypreps, and powers off.

> **Version/name caveats.**
> - The **OS Type = Windows** step in (3) is easy to miss: without it the
>   Unattended & Sysprep section is hidden entirely.
> - On **Harvester v1.9+**, the disk-bus / Hyper-V / cloud-init choices in (2)
>   are largely defaults for Windows VMs
>   ([harvester/harvester#11124](https://github.com/harvester/harvester/issues/11124)),
>   so a plain Windows VM already has most of the right shape.
> - **Template names vary by cluster/version.**
>   `windows-iso-image-base-template` is the stock built-in; some clusters also
>   ship sized variants (`windows-iso-small` / `-medium` / `-large`). If none
>   exist, build a blank VM with a CD-ROM boot disk, a 32Gi virtio-scsi
>   rootdisk, and a container-image volume `registry.suse.com/suse/vmdp/vmdp:2.5.5`
>   — matching [`kubectl/winbuild-vm.yaml`](../kubectl/winbuild-vm.yaml).

Or create the secret from the generated file directly:

```bash
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=kubectl/Autounattend-selfcontained.xml
```

## Re-generate whenever the sources change

`Autounattend-selfcontained.xml` is a build artifact — regenerate it any time
you edit `Autounattend.xml` or `bootstrap.ps1`. If you change the answer file
enough to alter its structure, keep exactly one `<FirstLogonCommands>` block:
the generator replaces that single block and errors if it finds zero or many.
