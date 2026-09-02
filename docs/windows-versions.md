# Windows versions

The build is version-specific. You have to tell the tooling which Windows you
are installing — there is no autodetect, and the wrong value fails in ways that
look like something else.

| Version | Base answer file | `build-answerfile.py -w` | `/IMAGE/NAME` (default) | Firmware |
|---|---|---|---|---|
| Windows Server 2022 (Desktop Experience) | `kubectl/Autounattend-2022.xml` | `2022` | `Windows Server 2022 SERVERSTANDARD` | BIOS |
| Windows Server 2025 (Desktop Experience) | `kubectl/Autounattend-2025.xml` | `2025` | `Windows Server 2025 SERVERSTANDARD` | BIOS |
| Windows 11 | `kubectl/Autounattend-w11.xml` | `w11` | `Windows 11 Pro` | UEFI + TPM |

```bash
cd kubectl
./build-answerfile.py -w 2025     # → Autounattend-selfcontained-2025.xml
```

`-w/--windows-version` is required. It picks the base answer file, the output
filename, and the `/IMAGE/NAME` edition string.

## Why the version matters

### 1. `/IMAGE/NAME` must match `install.wim` exactly

`ImageInstall/OSImage/InstallFrom/MetaData` names which image inside the ISO's
`sources\install.wim` to apply. The string is compared byte for byte. If it does
not match, Setup falls back to the **"Select the operating system you want to
install"** picker and waits for a human — so an unattended build just hangs at a
screen you never see, and the watcher eventually times out with the VM still
`Running`.

Confirm the names in *your* media before you build:

```bash
# Linux, wimlib-imagex
wiminfo /mnt/iso/sources/install.wim
```

```cmd
:: Windows / WinPE (Shift+F10 at the Setup screen works too)
dism /Get-WimInfo /WimFile:D:\sources\install.wim
```

Retail and **Evaluation** media use the *same* image names, so an eval ISO needs
no change here. Datacenter and Server Core do differ — override without editing
the XML:

```bash
./build-answerfile.py -w 2025 --edition 'Windows Server 2025 SERVERDATACENTER'
```

> Server **Core** is not supported by this build: `bootstrap.ps1` assumes the
> Desktop Experience (Server Manager, the full AppX surface, the GUI OOBE path).

### 2. Partition layout differs

Server 2022/2025 install to a BIOS layout — a 500 MB active `System` partition
plus an extended `Windows` partition, `InstallTo` PartitionID **2**.

Windows 11 requires UEFI, so `Autounattend-w11.xml` lays down EFI (300 MB,
FAT32) + MSR (128 MB) + Windows, and `InstallTo` PartitionID is **3**. Boot the
build VM with `efi: {}` / `secureBoot: false` and a TPM; the `LabConfig`
`Bypass*Check` registry writes in the `windowsPE` pass cover the rest.

### 3. Driver injection is shared, but 2025 is less forgiving

All three use the same VMDP folder, `\Server2022-25-Win11\x64` — one driver set
covers Server 2022, Server 2025 and Windows 11.

What changed with 2025 is the *tolerance* for a sloppy `DriverPaths`. Server
2022 survived pointing `DriverPaths` at CD **roots**; Server 2025 media does
not. Rooted paths make Setup walk the whole volume looking for INFs, including
the multi-GB install ISO and every other OS folder on the VMDP CD, which blows
the scan budget: Setup reaches `DiskConfiguration` with no virtio-scsi driver
loaded and dies with `Error code: 0xD000A000 - 0x40031`. All the answer files
now name the exact nested folder on each candidate letter (`D:`–`G:`; missing
letters are skipped silently). See
[troubleshooting](troubleshooting.md#setup-dies-with-error-code-0xd000a000---0x40031).

### 4. Servicing drift during the build

The build VM has outbound internet (it downloads Cloudbase-Init), so Windows
Update and the Microsoft Store will service the machine mid-build. On **Server
2025** the Store is noticeably more eager: it reliably updated
`Microsoft.DesktopAppInstaller` for the Administrator account only, leaving it
"installed for a user, but not provisioned for all users", which aborts
`sysprep /generalize` with **0x80073cf2**. Server 2022 hit this less often but
is not immune.

`bootstrap.ps1` step 0a freezes servicing for the duration of the build and
`SetupComplete.cmd` restores it on every deployed clone, so this is handled for
all versions — but it is the reason the freeze exists. Details in
[troubleshooting](troubleshooting.md).

### 5. Disk size

Use a **36 GiB** rootdisk for every version. Server 2025 + VMDP +
Cloudbase-Init + the zero-fill pass does not fit comfortably in less, and
running the disk to full does not merely slow the build — `sysprep /generalize`
itself needs to write (registry servicing, AppX state, its own Panther logs) and
fails outright when it cannot. The zero-fill in `bootstrap.ps1` deliberately
leaves 2 GiB free and hard-fails the build below 1 GiB rather than handing
sysprep a full volume. The image shrinks on export, so the 36 GiB is provisioned
size, not the size you ship.

## Adding another version

1. Copy the closest base file to `kubectl/Autounattend-<ver>.xml` and adjust the
   partition layout if the firmware differs.
2. Add the edition string to `EDITIONS` in `kubectl/build-answerfile.py`.
3. `./build-answerfile.py -w <ver>` and check in the generated
   `Autounattend-selfcontained-<ver>.xml`.
4. Verify the VMDP driver folder actually covers that release — the
   `Server2022-25-Win11` name is not a promise about future ones.
