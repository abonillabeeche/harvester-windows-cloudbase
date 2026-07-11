# harvester-windows-cloudbase

Build a **reusable Windows golden image** for [Harvester HCI](https://harvesterhci.io/) that:

- Installs Windows Server (or Windows 11) unattended from an ISO
- Installs the SUSE **VMDP** (Virtual Machine Driver Pack) — virtio drivers + qemu-guest-agent
- Installs **Cloudbase-Init** and configures it to consume the KubeVirt `NoCloud` metadata
- Runs `sysprep /generalize /shutdown` so the disk becomes a clean, cloneable base
- Installs OpenSSH Server (optional — commented block in `bootstrap.ps1`) so operators can SSH into the running build for observation

Once built, every VM cloned from the image applies its own **Cloud Configuration Template** on first boot — the same way Linux VMs do — so you can set the hostname, users, packages, and `runcmd` steps declaratively per VM.

Two supported workflows:

- **`kubectl/`** — copy-paste-apply. Manually run `kubectl create secret` + `kubectl apply`, wait for the build VM to stop, then create the image from the resulting PVC.
- **`terraform/`** — one `terraform apply`. Templates the secret from your inputs, provisions the build VM, waits for it to reach `Stopped`, and creates the `VirtualMachineImage` for you.

---

## Prerequisites

1. A Harvester cluster (v1.8 or later).
2. A Windows Server 2022 (or Windows 11) ISO already uploaded as a Harvester Image (Images → Create → Upload).
3. `kubectl` configured with your Harvester kubeconfig — download from **Support → Copy Kubeconfig** in the Harvester UI.
4. For the Terraform path: `terraform >= 1.5` and the [kubernetes provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs) (auto-installed).
5. `lvm-thin` StorageClass available (or edit the manifests to use `harvester-longhorn`).

The SUSE VMDP driver ISO is already shipped as a KubeVirt container disk at `registry.suse.com/suse/vmdp/vmdp:2.5.5` — the build attaches it automatically.

---

## Quick start (kubectl)

```bash
cd kubectl/

# 1. Get the image ID of your uploaded Windows ISO
kubectl get virtualmachineimage -A | grep -i server_eval  # or the name you used
# note the metadata.name (e.g. image-l5hwf) and namespace (default)

# 2. Edit winbuild-vm.yaml — change the imageId annotation to match your image
#    "harvesterhci.io/imageId": "<namespace>/<image-name>"

# 3. Create the secret containing the unattend + bootstrap
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=Autounattend.xml \
  --from-file=bootstrap.ps1=bootstrap.ps1

# 4. Apply the build VM
kubectl apply -f winbuild-vm.yaml

# 5. Wait ~25 min for the VM to reach Stopped state
kubectl wait --for=jsonpath='{.status.printableStatus}'=Stopped \
  vm/winbuild --timeout=45m

# 6. Create the golden image from the rootdisk PVC
kubectl apply -f export-image.yaml
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Imported")].status}'=True \
  virtualmachineimage/win2022-cloudbase --timeout=15m

# 7. Clean up the build VM (image persists)
kubectl delete -f winbuild-vm.yaml
kubectl delete secret winbuild-unattend
```

You now have a `VirtualMachineImage` named `win2022-cloudbase` in the `default` namespace, ready to create VMs from.

## Consuming the image

Create a Cloud Configuration Template in the Harvester UI (**Advanced → Cloud Configuration Templates → Create**, Type: **User Data**) with your per-VM cloud-config. Example:

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
  - powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
  - powershell.exe -Command "Start-Service sshd"
```

Then create a new Windows VM from the `win2022-cloudbase` image and select this Cloud Configuration Template in the **Advanced Options → User Data Template** dropdown. First boot will apply the config.

---

## Quick start (Terraform)

```bash
cd terraform/

terraform init
terraform plan \
  -var 'kubeconfig=~/.kube/harvester.yaml' \
  -var 'windows_iso_image_ref=default/image-l5hwf' \
  -var 'output_image_name=win2022-cloudbase'

terraform apply -auto-approve
# Terraform waits for the build VM to stop, then creates the image.
# Total wall clock: ~25 min for the Windows install + sysprep phase.

terraform output image_name
# → win2022-cloudbase   (ready to reference from new VMs)
```

Variables (see `terraform/variables.tf`):

| Name | Default | Description |
|---|---|---|
| `kubeconfig` | `~/.kube/config` | Path to your Harvester kubeconfig |
| `namespace` | `default` | Namespace for build VM + resulting image |
| `windows_iso_image_ref` | *required* | `<namespace>/<image-name>` of your uploaded ISO |
| `windows_edition` | `Windows Server 2022 SERVERSTANDARD` | Edition name from the ISO's `install.wim` |
| `output_image_name` | `win2022-cloudbase` | Name for the golden VirtualMachineImage |
| `storage_class` | `lvm-thin` | StorageClass for both build PVCs and the image |
| `install_openssh` | `true` | Include OpenSSH Server in the golden image |
| `admin_password` | `HarvesterBuild1!` | Temp password used only during build (sysprep clears it) |
| `cpu_cores` | `4` | Build VM vCPU count |
| `memory_gib` | `8` | Build VM memory |
| `rootdisk_gib` | `64` | Golden image disk size |

To build Windows 11 instead, set:

```
-var 'windows_iso_image_ref=default/image-wpf76' \
-var 'windows_edition=Windows 11 Pro' \
-var 'output_image_name=win11-cloudbase' \
-var 'enable_efi_tpm=true'
```

---

## What the golden image contains

- Windows Server 2022 (or Win11), fully installed
- **SUSE VMDP 2.5.5** — virtio-block, virtio-scsi, virtio-net drivers + qemu-guest-agent as a Windows service
- **Cloudbase-Init 1.1.6** — configured for `NoCloud` metadata (matches KubeVirt's `cloudInitNoCloud` volume type)
- **OpenSSH Server** (optional, on by default) — listens on port 22, admin key from the build controller
- Sysprepped (`/generalize /oobe /shutdown`) — SID regenerated on first boot, machine identity clean

Cloudbase-Init's `ExtendVolumesPlugin` runs on first boot in each cloned VM, so if you create a new VM with a larger rootdisk than the image's original 64 GiB, `C:` extends automatically. No manual `diskpart`.

---

## Windows 11 notes

- Set `enable_efi_tpm=true` (Terraform) or use `win11build-vm.yaml` (kubectl) — Windows 11 Setup enforces UEFI + Secure Boot + vTPM.
- The Autounattend for Windows 11 writes `HKLM\System\Setup\LabConfig\Bypass*Check=1` registry keys during the `windowsPE` pass — these lift the CPU / RAM / storage compatibility gates for older host CPUs. If your host CPU is on Microsoft's Windows 11 approved list, the keys are harmless.
- Windows 11 Setup requires a product key. The bundled Autounattend uses the public **KMS client setup key** for Windows 11 Pro (`W269N-WFGWX-YVC9B-4J6C9-T83GX`). Change to your retail key or another KMS client key as needed.

---

## Files

| File | Purpose |
|---|---|
| `kubectl/Autounattend.xml` | Windows Setup unattend for Server 2022 |
| `kubectl/Autounattend-w11.xml` | Windows Setup unattend for Windows 11 (with TPM / Secure Boot / bypass keys) |
| `kubectl/bootstrap.ps1` | First-boot PowerShell — installs OpenSSH + VMDP + Cloudbase-Init, writes CBI conf, runs sysprep |
| `kubectl/winbuild-vm.yaml` | KubeVirt VirtualMachine spec for the Server 2022 build |
| `kubectl/win11build-vm.yaml` | KubeVirt VirtualMachine spec for the Windows 11 build (EFI + TPM) |
| `kubectl/export-image.yaml` | VirtualMachineImage manifest that exports the rootdisk PVC via CDI backend |
| `terraform/main.tf` | Full Terraform module — templates everything, applies, waits, exports |
| `terraform/variables.tf` | Input variables |
| `terraform/versions.tf` | Provider version constraints |

---

## License

Apache 2.0. VMDP and Cloudbase-Init retain their own licenses.
