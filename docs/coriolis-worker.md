# Coriolis OSMorphing worker flavor

[Coriolis](https://cloudbase.it/coriolis/) migrates VMs into Harvester. For a
**Windows** VM it boots a temporary *OSMorphing worker* from a Windows image you
supply, attaches the migrated disks to it, and drives it over **WinRM HTTPS
(5986)** to inject VirtIO drivers and Cloudbase-Init into the migrated OS.

The `coriolis` flavor builds that worker image with the same pipeline as the
general-purpose image. It follows Cloudbase's two reference pages:

- Temporary migration worker requirements —
  <https://cloudbase.it/coriolis-temporary-migration-worker/>
- KubeVirt/Harvester as a destination (Cloudbase-Init config) —
  <https://cloudbase.it/kubevirt-harvester-as-a-destination-cloud/>

## Why a separate flavor

A general-purpose Cloudbase-Init image is **not** a usable Coriolis worker.
Three things have to hold on the worker's first boot, and the `standard` image
gets none of them right:

1. **The login user must be created from userdata.** Coriolis never knows the
   image's passwords; it sends a fresh user + password in NoCloud userdata and
   logs in with that (see below). Cloudbase-Init's `UserDataPlugin` must run,
   and must run *after* Windows Setup has finished — on a sysprepped image it
   otherwise runs too early, fails to create the user, and never retries.
2. **WinRM must accept that user over HTTPS with Basic auth** on 5986, through
   the firewall.
3. **Remote UAC must not filter the user's admin token**, or WinRM rejects a
   non-built-in local admin even with the right password.

Miss any one and Coriolis fails at *Testing connection on remote management
port 5986* with "credentials were invalid".

## How Coriolis logs in

Coriolis does **not** use the build's Administrator password. Each worker VM it
creates gets a `cloudInitNoCloud` volume (a SATA disk labelled `cidata`) whose
userdata is inline in the VM spec — so it does not show in Harvester's *Cloud
Config* tab, only in **Edit YAML**:

```yaml
#cloud-config
users:
  - name: cloudbase
    gecos: 'Admin'
    primary_group: Administrators
    passwd: <random, per worker>
    inactive: False
```

Cloudbase-Init's `UserDataPlugin` must create that user on first boot, and
WinRM must then accept it over HTTPS with Basic auth. If any link in that chain
is missing, the Coriolis task log shows:

```
Testing connection on remote management port 5986
ERROR coriolis_provider_kubevirt.util [-] managed to connect via winrm, but credentials were invalid
```

## What the flavor changes

Everything else (VMDP, sysprep, zero-fill, the Windows Update freeze during the
build) is the same as the `standard` flavor.

| | `standard` | `coriolis` |
|---|---|---|
| Main `cloudbase-init.conf` metadata services | NoCloud, ConfigDrive, `EmptyMetadataService` | **NoCloud only** — no silent "boot with no userdata" fallback |
| Main conf `plugins=` | Cloudbase-Init defaults | Cloudbase's KubeVirt list: MTU, NTPClient, SetHostName, ExtendVolumes, **ConfigWinRMListener**, **UserData** |
| `[config_drive] raw_hdd=true` | — | yes |
| `check_latest_version` | `true` | `false` |
| `allow_reboot` (main conf) | `false` | Cloudbase-Init default (`true`) — safe, the service only runs after Setup |
| `cloudbase-init` service at first boot | Automatic | **Manual in the image; `SetupComplete.cmd` sets it Automatic and starts it** once Windows Setup has finished (see below) |
| Build autologon / Administrator password | left as built | autologon removed, Administrator set to a random password |
| Cloudbase-Init plugin state + logs | — | cleared before shutdown, so every clone runs every plugin once |
| WinRM HTTPS listener (5986) + self-signed cert | created by Cloudbase-Init at first boot only | **baked into the image** (steps of Cloudbase's [`winrm-gen.ps1`](https://raw.githubusercontent.com/cloudbase/coriolis-resources/master/windows/winrm-gen.ps1)), and re-created per clone by ConfigWinRMListenerPlugin |
| WinRM Basic auth, `MaxTimeoutms=1800000` | — | yes |
| Firewall `Windows Remote Management (HTTPS-In)` 5986 | — | yes |
| `LocalAccountTokenFilterPolicy=1` | — | yes — Coriolis' `cloudbase` user is a non-built-in local admin; without this, remote UAC filters its token and WinRM rejects it |
| Default image name (Terraform) | `win<ver>-cloudbase` | `win<ver>-coriolis` |

`cloudbase-init-unattend.conf` (run during sysprep specialize) is identical in
both flavors.

### Why Cloudbase-Init starts from SetupComplete.cmd

Left Automatic, the Cloudbase-Init service starts on a clone's first boot,
waits for `GeneralizationState`, and runs its plugins while Windows Setup is
still in the OOBE pass. Observed on Server 2025:

```
ERROR plugin 'ConfigWinRMListenerPlugin' failed with error 'CryptoAPI error: 0x800706d9'
WARNING ...users [-] An error occurred during user 'cloudbase' creation: 'Failed to get user
        info: This operation is only allowed on the primary domain controller of the domain.'
... (reboot) ...
DEBUG Plugin 'UserDataPlugin' execution already done, skipping
```

The user failure is only a warning, so `UserDataPlugin` is recorded as done and
never retried: the user Coriolis logs in with is never created. Cloudbase's
KubeVirt guide avoids this by not sysprepping at all. This flavor keeps sysprep
(unique SID per worker, `SetupComplete.cmd` restores Windows Update) and
instead ships the service as **Manual**; `SetupComplete.cmd`, which Windows
Setup runs once OOBE is complete, sets it back to Automatic and starts it.
Validated on Server 2025 and Server 2022: `UserDataPlugin` creates the user and
a Coriolis-style WinRM login succeeds on first boot; a real VMware → Harvester
Coriolis migration (Server 2022 source) passes the worker's WinRM check and
proceeds into OS morphing. The upstream Cloudbase-Init behaviour is reported
to Cloudbase; this flavor does not depend on a fix.

### Deliberate deviations from the Cloudbase pages

- **Sysprep is kept** (as in the SUSE technical guide), with the
  SetupComplete.cmd service start above; Cloudbase's KubeVirt page skips
  sysprep.
- **Windows Updates are not installed.** The worker page asks for a fully
  patched template. The build keeps its servicing freeze (see
  `bootstrap.ps1` step 0a) because live servicing is what breaks sysprep.

## Build it

Use **Windows Server 2025** unless you have a reason not to: the worker's
Windows version must be equal to or newer than every Windows VM you migrate
(a 2022 worker covers Server 2022 and older, and Windows 10/11). Keep the
ISO's system language **English** (the bundled answer files set `en-US`).

The build is the normal one from the README — only the answer file differs.
Total time is about 30–45 minutes, unattended.

### Harvester UI

Follow the README's UI steps, but paste
[`kubectl/Autounattend-selfcontained-coriolis-2025.xml`](../kubectl/Autounattend-selfcontained-coriolis-2025.xml)
(or `-coriolis-2022.xml`) into the *Windows Unattended & Sysprep* section.

### kubectl

1. Pick the ISO image and its StorageClass, as in the README:

   ```bash
   kubectl get virtualmachineimage -A \
     -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DISPLAY:.spec.displayName,SC:.status.storageClassName'
   ```

2. Create the sysprep secret from the Coriolis answer file (regenerate it with
   `./build-answerfile.py -w 2025 --flavor coriolis` only if you edited
   `bootstrap.ps1` or need another edition):

   ```bash
   cd kubectl/
   kubectl create secret generic winbuild-unattend \
     --from-file=autounattend.xml=Autounattend-selfcontained-coriolis-2025.xml
   ```

3. Fill in `winbuild-vm.yaml` (ISO image, its StorageClass, rootdisk class) and
   apply it. If the ISO's StorageClass is ReadWriteOnce-only (LVM, Longhorn
   V2), change the ISO volume's `accessModes` to `["ReadWriteOnce"]`.

   ```bash
   kubectl apply -f winbuild-vm.yaml
   ```

4. Wait for the VM to install, sysprep and power itself off (`Stopped`) — about
   30 minutes. A new VM reports `Stopped` for a moment before it first starts,
   so only trust `Stopped` after you have seen it `Running`.

5. Turn the rootdisk into an image — either a straight export
   (`export-image.yaml`, `pvcName: winbuild-rootdisk`, name it
   `win2025-coriolis`) or, smaller, the compact Job in
   [`shrink-export/`](../shrink-export/) (`MODE=compact`, `BACKEND=cdi`,
   `TARGET_STORAGECLASS` = where workers should live). Shrinking matters
   little when that class clones copy-on-write (e.g. `ceph-rbd` via CDI
   `csi-clone`); it matters a lot on Longhorn backing images.

6. Delete the build VM and its PVCs once the image is ready.

### Terraform

```bash
terraform apply -var 'flavor=coriolis' -var 'windows_version=2025' \
  -var 'windows_iso_image_ref=default/image-xxxxx' \
  -var 'iso_storage_class=longhorn-image-xxxxx'
terraform output image_ref   # → default/win2025-coriolis
```

### Check the build

`C:\winbuild.log` in the build VM should contain:

```
Coriolis WinRM: HTTPS listeners=1, Basic auth on, 5986 open, LocalAccountTokenFilterPolicy=1
Coriolis: autologon removed, Administrator password randomized, Cloudbase-Init state cleared
Coriolis: cloudbase-init service set to Manual; SetupComplete.cmd starts it after Setup
```

The build's Administrator password (`admin_password` / the answer file) is
replaced with a random one before sysprep, so it does **not** work on workers;
use the userdata login below to get in.

## Register it with Coriolis

- Label the image as Windows — neither export path does this for you:

  ```bash
  kubectl -n default label vmimage win2025-coriolis harvesterhci.io/os-type=windows
  ```

  For a UEFI build, also annotate it `vm.boot/firmware=uefi`.
- Point the Harvester endpoint's destination options at it. In Coriolis
  terms that is `migr_image_map`, for example:

  ```yaml
  migr_image_map:
    windows: default/win2025-coriolis
    linux: default/<linux-worker-image>
  migr_network: default/vlan1        # a network with DHCP the appliance can reach
  storage_mappings:
    default: ceph-rbd
  ```
- Windows migrations need **both** workers: the Linux one copies the disks, the
  Windows one does OSMorphing. The Coriolis appliance must reach the worker's
  DHCP address on TCP 5986.

## Verify a worker without running a migration

Boot a VM from the image with the same kind of userdata Coriolis sends, then
log in as that user over WinRM HTTPS + Basic:

```yaml
# volumes:
- name: cloudinitdisk
  cloudInitNoCloud:
    userData: |
      #cloud-config
      users:
        - name: cloudbase
          gecos: 'Admin'
          primary_group: Administrators
          passwd: Test-Passw0rd-123
          inactive: False
# disks:
- name: cloudinitdisk
  disk: { bus: sata }
```

```python
import winrm  # pip install pywinrm
s = winrm.Session('https://<vm-ip>:5986/wsman', auth=('cloudbase', 'Test-Passw0rd-123'),
                  transport='basic', server_cert_validation='ignore')
print(s.run_ps('whoami').std_out)
```

If that is rejected, read Cloudbase-Init's log without logging in: it is also
written to COM1, which KubeVirt captures in the `guest-console-log` container:

```bash
kubectl -n default logs virt-launcher-<vm>-xxxxx -c guest-console-log \
  | grep -E "Executing plugin|user|ERROR"
```
