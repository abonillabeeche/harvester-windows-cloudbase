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

Every `Autounattend-*.xml` in this repo passes that check.

## The constraint: one file only

The UI has **no field for a second file**. Our first-boot logic lives in
`bootstrap.ps1`, and the two-file layout (`kubectl`/Terraform) relies on that
script riding the sysprep CD as its own file. Through the UI, only
`autounattend.xml` reaches the CD — so a plain answer file that points at
`bootstrap.ps1` would never find it.

The fix is to **fold `bootstrap.ps1` into the answer file itself.**

## `build-answerfile.py`

> **You do not need to run this to use the UI path.** The folded artifacts are
> checked in — `kubectl/Autounattend-selfcontained-{2022,2025,w11}.xml` — so the
> UI flow below is copy-and-paste. Run the generator only when you **edit**
> `bootstrap.ps1` or a base answer file, or want a non-default edition. This
> section explains what it does and why the artifact looks the way it does.

```bash
cd kubectl/
./build-answerfile.py -w 2025   # reads Autounattend-2025.xml + bootstrap.ps1
# → writes Autounattend-selfcontained-2025.xml
```

`-w/--windows-version` (`2022` | `2025` | `w11`) is **required**: it picks the
base answer file and pins the `/IMAGE/NAME` edition string, which has to match
your ISO's `install.wim` exactly. See
[windows-versions.md](windows-versions.md).

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

1. The ready-to-paste files are already checked in, one per Windows version:
   [`Autounattend-selfcontained-2022.xml`](../kubectl/Autounattend-selfcontained-2022.xml),
   [`-2025.xml`](../kubectl/Autounattend-selfcontained-2025.xml),
   [`-w11.xml`](../kubectl/Autounattend-selfcontained-w11.xml)
   — open the one matching your ISO and copy the whole contents. Only regenerate
   it (see below) if you've edited the base answer file or `bootstrap.ps1`.
2. **Virtual Machines → Create → From Template →**
   `windows-iso-medium-template` (namespace `harvester-public`). It provides
   the CD-ROM boot disk, a rootdisk, the VMDP driver CD
   (`registry.suse.com/suse/vmdp/vmdp:2.5.5`), 4 vCPU / 16 GiB, and the Hyper-V
   enlightenments. Set the CD-ROM's **Image** to your Windows ISO; on the
   **Volume** tab reduce the rootdisk to **36Gi** and pick your tested
   StorageClass (`harvester-longhorn` is fine; use access mode
   **Single-Node/ReadWriteOnce** if the class is RWO-only).
3. **Advanced Options → set OS Type = `Windows`.** The **Windows Unattended &
   Sysprep Configuration** section only appears once the OS type is Windows.
   Then **Create New**, name the secret (e.g. `winbuild-unattend`), and paste
   the contents of `Autounattend-selfcontained-<version>.xml`.
4. **Create.** The VM installs, sypreps, and powers off.

> **Caveats.**
> - The **OS Type = Windows** step in (3) is easy to miss: without it the
>   Unattended & Sysprep section is hidden entirely.
> - The Hyper-V enlightenments come from the **template** — there is no toggle
>   for them in the create form. They ship on the Windows templates as of
>   [harvester/harvester#11127](https://github.com/harvester/harvester/pull/11127)
>   (merged, milestone v1.9.0), which also added the sized profiles
>   (`windows-iso-small` / `-medium` / `-large`, `windows-w11-iso`). On a
>   pre-v1.9 cluster, apply
>   [`templates/windows-iso-medium-template.yaml`](../templates/windows-iso-medium-template.yaml)
>   from this repo. They affect *performance*, not correctness.
> - With no suitable template at all, build a blank VM with a CD-ROM boot disk,
>   a 36Gi rootdisk, and a container-image volume
>   `registry.suse.com/suse/vmdp/vmdp:2.5.5` — matching
>   [`kubectl/winbuild-vm.yaml`](../kubectl/winbuild-vm.yaml), which sets the
>   enlightenments explicitly.

Or create the secret from the generated file directly:

```bash
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=kubectl/Autounattend-selfcontained-2025.xml
```

## Re-generate whenever the sources change

`Autounattend-selfcontained-<version>.xml` is a build artifact — regenerate it
any time you edit `Autounattend-<version>.xml` or `bootstrap.ps1`. If you change the answer file
enough to alter its structure, keep exactly one `<FirstLogonCommands>` block:
the generator replaces that single block and errors if it finds zero or many.
