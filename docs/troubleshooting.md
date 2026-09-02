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
copy) — sysprep `/generalize` refuses. Modern Chromium Edge
(`Microsoft.MicrosoftEdge.Stable`) is the classic offender because it resists
`Remove-AppxPackage`.

> **Gotcha:** blanket-running `Remove-AppxProvisionedPackage` for *every* package
> makes this **worse**, not better. If you deprovision a package whose per-user
> copy then refuses to uninstall, you have just manufactured the exact
> "installed-but-not-provisioned" mismatch that fails generalize. An earlier
> revision of `bootstrap.ps1` did this and hit 0x80073cf2 on the Edge Stable AppX.

**Fix:** `bootstrap.ps1` step 5b now *reconciles* instead of blindly stripping:

1. Stop any running `msedge`/`msedgewebview2` processes.
2. Best-effort `Remove-AppxPackage -AllUsers` for each package (keeps the image
   lean; unremovable ones are just left in place).
3. Hard-uninstall Chromium Edge via its own
   `setup.exe --uninstall --system-level --force-uninstall`.
4. **Reconciliation pass** — for every package *still* installed for a user,
   `Add-AppxProvisionedPackage -Online -PackagePath <InstallLocation>\AppxManifest.xml
   -SkipLicense`. This makes provisioned == installed for whatever refused to
   uninstall, so generalize is satisfied. `-SkipLicense` lets it provision from
   the installed package's manifest without the original `.appx` + license file.

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
Store apps that don't generalise cleanly — the AppX cleanup in step 5b is the
mitigation. If it recurs, delete the VM + rootdisk and retry.

## Cloudbase-Init didn't personalise the cloned VM

- Confirm the image was captured from a **sysprepped** rootdisk (VM reached
  `Stopped` via sysprep `/shutdown`, not a manual power-off).
- Check `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\` in the cloned
  VM.
- Confirm the consumer VM actually has a cloud-config / user-data attached
  (KubeVirt `cloudInitNoCloud` or a Harvester cloud-config template).
