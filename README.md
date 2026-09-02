# harvester-windows-cloudbase

Build a **reusable Windows golden image** for [Harvester HCI](https://harvesterhci.io/)
that personalises itself per-VM on first boot — the same experience Harvester's
Linux cloud images give you, but for Windows Server and Windows 11.

The image ships with:

- **SUSE VMDP** (Virtual Machine Driver Pack) — WHQL-signed virtio drivers
  (block, scsi, net) **and** `qemu-guest-agent`.
- **Cloudbase-Init** — the "cloud-init for Windows", pre-configured for
  KubeVirt's `NoCloud` metadata, so each cloned VM applies its own hostname,
  users, password, network and `runcmd` from a cloud-config.
- **Sysprep `/generalize`** — a clean, SID-less base, with Cloudbase-Init
  re-armed to run on the deployed VM's first boot.
- **`ExtendVolumesPlugin`** — `C:` auto-grows to the target disk, so one small
  image serves any disk size.

> New to the design? Read **[docs/how-it-works.md](docs/how-it-works.md)** first
> — it explains the sysprep volume, the answer-file passes, VMDP, Cloudbase-Init
> and the sizing model in one page.

## Contents

| Path | What it is |
|---|---|
| [`kubectl/`](kubectl/) | Copy-paste-apply build: answer files, `bootstrap.ps1`, build-VM + export manifests, and `build-answerfile.py` |
| [`terraform/`](terraform/) | One `terraform apply` that templates, builds, waits, and exports |
| [`shrink-export/`](shrink-export/) | A parameterized Job to compact/shrink any disk PVC and register it as an image |
| [`docs/`](docs/) | Architecture, per-version specifics, the v1.9 UI sysprep flow, sizing/export, and troubleshooting |

## Prerequisites

1. A Harvester cluster (v1.8+).
2. A Windows Server 2022, Windows Server 2025 or Windows 11 ISO uploaded as a
   Harvester Image (**Images → Create → Upload**). You must tell the build which
   one you have — see **[docs/windows-versions.md](docs/windows-versions.md)**.
3. `kubectl` with your Harvester kubeconfig (**Support → Download KubeConfig**).
4. A StorageClass you have tested for VM volumes. **`harvester-longhorn` ships
   on every Harvester cluster** and is a safe default; substitute any class
   you've validated.
5. Terraform ≥ 1.5 for the Terraform path.

The VMDP driver ISO ships as a KubeVirt container disk at
`registry.suse.com/suse/vmdp/vmdp:2.5.5` — the build attaches it automatically.

---

## What you provide

Every path needs the same handful of inputs from your cluster. Gather them once;
the table shows where each one goes. To find your ISO image's names and its
dedicated StorageClass:

```bash
export KUBECONFIG=/path/to/your/harvester.yaml     # your downloaded kubeconfig
kubectl get virtualmachineimage -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DISPLAY:.spec.displayName,SC:.status.storageClassName'
# e.g.  default   image-4fxrm   server_eval_x64fre_en-us.iso   longhorn-image-4fxrm
```

| Input | Where to get it | UI path | kubectl path | Terraform path |
|---|---|---|---|---|
| **Kubeconfig** (path/filename) | Harvester → **Support → Download KubeConfig** | you're already in the UI | `export KUBECONFIG=/path/to/harvester.yaml` (or `kubectl --kubeconfig`) | `-var 'kubeconfig=/path/to/harvester.yaml'` |
| **Windows ISO image** (already uploaded) | the `NS`/`NAME` columns above — use the short `metadata.name` (e.g. `image-4fxrm`), **not** the display name | select it in the CD-ROM **Image** dropdown | `REPLACE_NAMESPACE/REPLACE_IMAGE_NAME` in `kubectl/winbuild-vm.yaml` | `-var 'windows_iso_image_ref=default/image-4fxrm'` |
| **ISO image's own StorageClass** | the `SC` column above (e.g. `longhorn-image-4fxrm`) | handled automatically | `REPLACE_IMAGE_STORAGECLASS` in `kubectl/winbuild-vm.yaml` | `-var 'iso_storage_class=longhorn-image-4fxrm'` |
| **Rootdisk StorageClass** (for the golden disk) | any class you've tested; `harvester-longhorn` works everywhere | rootdisk **Volume** tab | `REPLACE_STORAGECLASS` in `kubectl/winbuild-vm.yaml` | `-var 'storage_class=harvester-longhorn'` |

> The **ISO image's own StorageClass** matters: Harvester gives every uploaded
> image a dedicated class, and the install-ISO clone only populates when the CD
> PVC uses *that* class. Using a generic class yields an empty CD →
> "No Bootable Device". See [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Choose a build path

All three paths build the *same* golden image; they differ only in how you drive
the build VM.

| Path | You do | Best when |
|---|---|---|
| **[Harvester UI](#build-via-the-harvester-ui-answer-file-only)** | paste one answer file into the VM create form | you want a click-through, no CLI |
| **[Terraform](#build-via-terraform)** | one `terraform apply` | you want it automated / repeatable |
| **[kubectl](#build-via-kubectl)** | `kubectl create secret` + `apply` | you want to see every step |

The heart of all three is the **unattended answer file** — how it's built and
consumed is documented in **[docs/ui-sysprep.md](docs/ui-sysprep.md)** and
**[docs/how-it-works.md](docs/how-it-works.md)**.

---

## Build via the Harvester UI (answer file only)

Harvester v1.9 adds a **Windows Unattended & Sysprep** section to the VM create
form. It writes a Secret with a single `autounattend.xml` key and attaches it as
a sysprep CD — so the *only* thing you paste is one answer file.

Our first-boot logic lives in `bootstrap.ps1`, and the UI has no field for a
second file, so the script is folded into the answer file. **That is already
done for you** — pick the file matching your Windows version and copy its whole
contents. No CLI, no clone; open it straight from the repo:

| Your ISO | Paste this file |
|---|---|
| Windows Server 2022 | [`kubectl/Autounattend-selfcontained-2022.xml`](kubectl/Autounattend-selfcontained-2022.xml) |
| Windows Server 2025 | [`kubectl/Autounattend-selfcontained-2025.xml`](kubectl/Autounattend-selfcontained-2025.xml) |
| Windows 11 | [`kubectl/Autounattend-selfcontained-w11.xml`](kubectl/Autounattend-selfcontained-w11.xml) |

Getting the version wrong is not cosmetic — the edition string inside has to
match your ISO's `install.wim` exactly, or Setup stops on the edition picker and
the unattended run hangs. See
[docs/windows-versions.md](docs/windows-versions.md).

You only need `build-answerfile.py` if you **edit** `bootstrap.ps1` or a base
answer file, or want a non-default edition (Datacenter, Core):

```bash
cd kubectl/
./build-answerfile.py -w 2025 --edition 'Windows Server 2025 SERVERDATACENTER'
```

Then create the VM in the UI from the **`windows-iso-medium-template`** profile
in `harvester-public`. It carries the whole build shape: a **CD-ROM boot disk**,
a rootdisk, the **VMDP driver CD** (`registry.suse.com/suse/vmdp/vmdp:2.5.5`),
4 vCPU / 16 GiB, and the **Hyper-V enlightenments** with matching clock timers.

The sized Windows profiles (`windows-iso-small` / `-medium` / `-large`,
`windows-w11-iso`) ship with Harvester **v1.9.0**
([harvester/harvester#11127](https://github.com/harvester/harvester/pull/11127)).
On an older cluster, apply the backport in this repo once and it appears in the
template dropdown:

```bash
kubectl apply -f templates/windows-iso-medium-template.yaml
```

Steps:

1. **Virtual Machines → Create → From Template →** `windows-iso-medium-template`.
2. On the CD-ROM (boot) disk, set the **Image** to your uploaded Windows ISO.
3. On the **rootdisk (Volume tab)**, reduce the size to **36Gi** — the profile
   ships 64Gi for a general-purpose VM, but the exported image keeps the build
   disk's virtual size, and `C:` grows on deploy. If your StorageClass is
   block/LVM-based it may be ReadWriteOnce-only — set the access mode to
   **Single-Node (ReadWriteOnce)**; the build VM is the disk's only consumer,
   so RWO is always sufficient.
4. **Advanced Options → set OS Type = `Windows`.** This is what makes the
   **Windows Unattended & Sysprep Configuration** section appear. Then
   **Create New →** paste `Autounattend-selfcontained-<version>.xml`.
5. **Create.** The VM installs, sypreps, and powers off (~20 min). Console log
   inside the VM: `C:\winbuild.log`.
6. Capture the image: **Images → Create → from the build VM's rootdisk volume**
   (or apply `kubectl/export-image.yaml`).

> The enlightenments come from the **template**, not from a control in the
> create form — there is nothing to tick. They are a performance default, not a
> correctness gate
> ([#11124](https://github.com/harvester/harvester/issues/11124): −16% total
> wall time, +77% create throughput, worst stall 9.55s → 3.70s); without them
> the build still completes, just slower. The `kubectl` and Terraform paths set
> the block explicitly and depend on no template. A
> `VirtualMachineTemplateVersion` is immutable — to change one, delete it and
> re-apply.

Full detail — the single-key Secret model, the 1024-char `FirstLogonCommands`
limit, and why we base64-fold the script — is in
**[docs/ui-sysprep.md](docs/ui-sysprep.md)**.

---

## Build via kubectl

```bash
cd kubectl/

# 1. Find your uploaded Windows ISO. Every Harvester image has TWO names:
#      displayName   — what the UI shows (e.g. "server_eval_x64fre_en-us.iso")
#      metadata.name — the short k8s name (e.g. "image-xxxxx")  ← use THIS
#    You also need the image's OWN StorageClass for the ISO clone.
kubectl get virtualmachineimage -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DISPLAY:.spec.displayName,SC:.status.storageClassName'

# 2. Edit winbuild-vm.yaml and replace:
#      REPLACE_NAMESPACE/REPLACE_IMAGE_NAME  → e.g. default/image-xxxxx
#      REPLACE_IMAGE_STORAGECLASS            → the ISO image's own SC (SC column)
#    ⚠ Using a generic StorageClass for the ISO clone yields an empty volume and
#      "No Bootable Device". This is the #1 gotcha — see docs/troubleshooting.md.

# 3a. Create the sysprep secret (TWO-FILE layout — simplest for kubectl).
#     Pick the answer file for YOUR Windows version — the /IMAGE/NAME edition
#     string in it must match your ISO. See docs/windows-versions.md.
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=Autounattend-2025.xml \
  --from-file=bootstrap.ps1=bootstrap.ps1

# 3b. …OR the SINGLE-FILE layout, identical to what the Harvester v1.9 UI
#     writes (one key). Generate it, then create the secret from it:
./build-answerfile.py -w 2025
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=Autounattend-selfcontained-2025.xml
#   (or paste Autounattend-selfcontained-2025.xml into the UI's
#    "Windows Unattended & Sysprep → Create New" form — see docs/ui-sysprep.md)

# 4. Apply the build VM (virtio-scsi rootdisk, 36Gi, full Hyper-V enlightenments)
kubectl apply -f winbuild-vm.yaml

# 5. Wait for the VM to sysprep and power itself off (~20 min)
kubectl wait --for=jsonpath='{.status.printableStatus}'=Stopped \
  vm/winbuild --timeout=45m
#   Watch progress on the VM console; first-boot log is C:\winbuild.log.

# 6. Capture the golden image from the rootdisk PVC
kubectl apply -f export-image.yaml
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Imported")].status}'=True \
  virtualmachineimage/win2022-cloudbase --timeout=15m

# 7. Clean up the build VM (the image persists)
kubectl delete -f winbuild-vm.yaml
kubectl delete secret winbuild-unattend
```

You now have a `VirtualMachineImage` named `win2022-cloudbase`, ready to create
VMs from. For a **smaller / compacted** image, see
[docs/shrink-and-export.md](docs/shrink-and-export.md).

## Consuming the image

Create a Cloud Configuration Template (**Advanced → Cloud Configuration
Templates → Create**, Type: **User Data**):

```yaml
#cloud-config
set_hostname: myserver01
set_timezone: America/New_York
users:
  - name: tux
    password: MyStr0ngPass!
    groups: [Administrators]
runcmd:
  - powershell.exe -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools"
  - powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd"
```

Create a new VM from the `win2022-cloudbase` image and select this template
under **Advanced Options → User Data**. Cloudbase-Init applies it on first boot,
and `C:` extends to the VM's rootdisk size automatically.

---

## Build via Terraform

```bash
cd terraform/
terraform init
terraform apply -auto-approve \
  -var 'kubeconfig=~/.kube/harvester.yaml' \
  -var 'windows_version=2025' \
  -var 'windows_iso_image_ref=default/image-xxxxx' \
  -var 'iso_storage_class=longhorn-image-xxxxx'

terraform output image_ref   # → default/win2025-cloudbase
```

`windows_version` (`2022` | `2025` | `w11`) is required. Everything it implies —
the `install.wim` edition string, the firmware and partition layout, the Win11
compat-check bypasses and product key, the output image name — is derived from
it and individually overridable. See
[docs/windows-versions.md](docs/windows-versions.md).

Key variables (full list in [`terraform/variables.tf`](terraform/variables.tf)):

| Name | Default | Description |
|---|---|---|
| `kubeconfig` | `~/.kube/config` | Path to your Harvester kubeconfig |
| `windows_version` | *required* | `2022`, `2025` or `w11` — drives every version-specific default below |
| `windows_iso_image_ref` | *required* | `<namespace>/<image metadata.name>` of the ISO |
| `iso_storage_class` | *required* | The ISO image's **own** StorageClass (`longhorn-<image-name>`) |
| `windows_edition` | per version | Override the `install.wim` edition string (e.g. for Datacenter) |
| `output_image_name` | `win<version>-cloudbase` | Name of the golden image |
| `storage_class` | `harvester-longhorn` | StorageClass for the rootdisk + exported image (use any class you've tested) |
| `rootdisk_gib` | `36` | Golden image disk size (kept small; grows on deploy) |
| `install_openssh` | `false` | Bake OpenSSH into the image (adds ~6 min) |

Windows 11:

```bash
terraform apply \
  -var 'windows_version=w11' \
  -var 'windows_iso_image_ref=default/image-yyyyy' \
  -var 'iso_storage_class=longhorn-image-yyyyy'
```

`windows_version=w11` already implies `windows_edition=Windows 11 Pro`,
`enable_efi_tpm=true`, `enable_win11_bypass_checks=true`, the Pro KMS client
setup key and `output_image_name=win11-cloudbase`; pass any of them explicitly
to override.

---

## What the golden image contains

- Windows Server 2022, Windows Server 2025 or Windows 11, fully installed on a
  virtio-scsi disk.
- **SUSE VMDP 2.5.5** — virtio block/scsi/net drivers + `qemu-guest-agent`.
- **Cloudbase-Init** — `NoCloud` metadata; `ExtendVolumesPlugin` grows `C:` on
  first boot.
- Optional **OpenSSH Server** (commented block in `bootstrap.ps1`).
- Sysprepped `/generalize /oobe /shutdown` — SID regenerated, machine identity
  clean, Cloudbase-Init re-armed.

## Version notes

The build is version-specific: the answer file names the exact edition inside
your ISO's `install.wim`, and the partition layout differs between the Server
releases and Windows 11. **[docs/windows-versions.md](docs/windows-versions.md)**
covers the edition strings, how to verify them against your own media, and the
2025-specific gotchas (stricter `DriverPaths`, hungrier Microsoft Store).

### Windows 11

- Use `Autounattend-w11.xml` / `enable_efi_tpm=true` — Win11 requires UEFI +
  Secure Boot + vTPM.
- The answer file writes `HKLM\System\Setup\LabConfig\Bypass*Check=1` during
  `windowsPE` to lift the CPU/TPM/Secure Boot/RAM/storage gates on older hosts.
- Win11 needs a product key; the bundled answer file uses the public **Pro KMS
  client setup key** `W269N-WFGWX-YVC9B-4J6C9-T83GX`. Change as needed.
- Win11 sysprep occasionally hangs on `Sysprep_Clean_Validate_Opk` — see
  [docs/troubleshooting.md](docs/troubleshooting.md).

## Documentation

- **[docs/how-it-works.md](docs/how-it-works.md)** — architecture and flow.
- **[docs/ui-sysprep.md](docs/ui-sysprep.md)** — the Harvester v1.9
  *Windows Unattended & Sysprep* form and the single-file answer file.
- **[docs/shrink-and-export.md](docs/shrink-and-export.md)** — image sizing;
  compacting/shrinking a disk and registering it as an image.
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — every symptom hit
  during validation, with fixes.

## License

Apache 2.0. VMDP and Cloudbase-Init retain their own licenses.
