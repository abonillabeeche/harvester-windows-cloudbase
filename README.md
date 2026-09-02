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
| [`docs/`](docs/) | Architecture, the v1.9 UI sysprep flow, sizing/export, and troubleshooting |

## Prerequisites

1. A Harvester cluster (v1.8+).
2. A Windows Server 2022 (or Windows 11) ISO uploaded as a Harvester Image
   (**Images → Create → Upload**).
3. `kubectl` with your Harvester kubeconfig (**Support → Download KubeConfig**).
4. An `lvm-thin` StorageClass (or edit the manifests for `harvester-longhorn`).
5. Terraform ≥ 1.5 for the Terraform path.

The VMDP driver ISO ships as a KubeVirt container disk at
`registry.suse.com/suse/vmdp/vmdp:2.5.5` — the build attaches it automatically.

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
second file, so we fold the script into the answer file:

```bash
cd kubectl/
./build-answerfile.py          # → Autounattend-selfcontained.xml
```

Then, creating the VM in the UI:

1. **Windows Unattended & Sysprep → Create New** → paste
   `Autounattend-selfcontained.xml`.
2. Add a **virtio-scsi** rootdisk (32Gi is plenty).
3. Add the **VMDP driver CD** — a container-image volume
   `registry.suse.com/suse/vmdp/vmdp:2.5.5`.
4. Boot from your uploaded Windows ISO. Start the VM; it installs, sypreps, and
   powers off (~20 min). Console log inside the VM: `C:\winbuild.log`.
5. Capture the image: **Images → Create → from the build VM's rootdisk volume**
   (or apply `kubectl/export-image.yaml`).

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

# 3a. Create the sysprep secret (TWO-FILE layout — simplest for kubectl):
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=Autounattend.xml \
  --from-file=bootstrap.ps1=bootstrap.ps1

# 3b. …OR the SINGLE-FILE layout, identical to what the Harvester v1.9 UI
#     writes (one key). Generate it, then create the secret from it:
./build-answerfile.py
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=Autounattend-selfcontained.xml
#   (or paste Autounattend-selfcontained.xml into the UI's
#    "Windows Unattended & Sysprep → Create New" form — see docs/ui-sysprep.md)

# 4. Apply the build VM (virtio-scsi rootdisk, 32Gi, full Hyper-V enlightenments)
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
  -var 'windows_iso_image_ref=default/image-xxxxx' \
  -var 'iso_storage_class=longhorn-image-xxxxx' \
  -var 'output_image_name=win2022-cloudbase'

terraform output image_ref   # → default/win2022-cloudbase
```

Key variables (full list in [`terraform/variables.tf`](terraform/variables.tf)):

| Name | Default | Description |
|---|---|---|
| `kubeconfig` | `~/.kube/config` | Path to your Harvester kubeconfig |
| `windows_iso_image_ref` | *required* | `<namespace>/<image metadata.name>` of the ISO |
| `iso_storage_class` | *required* | The ISO image's **own** StorageClass (`longhorn-<image-name>`) |
| `windows_edition` | `Windows Server 2022 SERVERSTANDARD` | Edition inside `install.wim` |
| `output_image_name` | `win2022-cloudbase` | Name of the golden image |
| `storage_class` | `lvm-thin` | StorageClass for the rootdisk + exported image |
| `rootdisk_gib` | `32` | Golden image disk size (kept small; grows on deploy) |
| `install_openssh` | `false` | Bake OpenSSH into the image (adds ~6 min) |

Windows 11:

```bash
terraform apply \
  -var 'windows_iso_image_ref=default/image-yyyyy' \
  -var 'iso_storage_class=longhorn-image-yyyyy' \
  -var 'windows_edition=Windows 11 Pro' \
  -var 'output_image_name=win11-cloudbase' \
  -var 'enable_efi_tpm=true' \
  -var 'enable_win11_bypass_checks=true'
```

---

## What the golden image contains

- Windows Server 2022 (or Windows 11), fully installed on a virtio-scsi disk.
- **SUSE VMDP 2.5.5** — virtio block/scsi/net drivers + `qemu-guest-agent`.
- **Cloudbase-Init** — `NoCloud` metadata; `ExtendVolumesPlugin` grows `C:` on
  first boot.
- Optional **OpenSSH Server** (commented block in `bootstrap.ps1`).
- Sysprepped `/generalize /oobe /shutdown` — SID regenerated, machine identity
  clean, Cloudbase-Init re-armed.

## Windows 11 notes

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
