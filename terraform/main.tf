provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig)
}

locals {
  build_vm_name = "winbuild-tf"
  is_win11      = var.enable_efi_tpm

  iso_ns   = split("/", var.windows_iso_image_ref)[0]
  iso_name = split("/", var.windows_iso_image_ref)[1]

  # Autounattend + bootstrap.ps1 are rendered from templates so that the
  # Windows edition, product key, bypass keys, and admin password all flow
  # from Terraform variables. Rendered content is embedded in a KubeVirt
  # sysprep-volume Secret.
  autounattend = templatefile("${path.module}/autounattend.xml.tftpl", {
    windows_edition            = var.windows_edition
    windows_product_key        = var.windows_product_key
    enable_efi_tpm             = var.enable_efi_tpm
    enable_win11_bypass_checks = var.enable_win11_bypass_checks
    admin_password             = var.admin_password
  })

  bootstrap = templatefile("${path.module}/bootstrap.ps1.tftpl", {
    install_openssh        = var.install_openssh
    authorized_ssh_key     = var.authorized_ssh_key
    cloudbase_init_msi_url = var.cloudbase_init_msi_url
  })

  volume_claim_templates = jsonencode([
    {
      metadata = {
        name        = "${local.build_vm_name}-iso"
        annotations = { "harvesterhci.io/imageId" = var.windows_iso_image_ref }
      }
      spec = {
        accessModes      = ["ReadWriteMany"]
        resources        = { requests = { storage = "20Gi" } }
        volumeMode       = "Block"
        storageClassName = var.storage_class
      }
    },
    {
      metadata = { name = "${local.build_vm_name}-rootdisk" }
      spec = {
        accessModes      = ["ReadWriteMany"]
        resources        = { requests = { storage = "${var.rootdisk_gib}Gi" } }
        volumeMode       = "Block"
        storageClassName = var.storage_class
      }
    },
  ])
}

# ---------------------------------------------------------------------------
# 1. Sysprep secret carrying the rendered Autounattend.xml and bootstrap.ps1.
#    KubeVirt turns this into a CD-ROM ISO with both files at the root.
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "unattend" {
  metadata {
    name      = "${local.build_vm_name}-unattend"
    namespace = var.namespace
  }
  data = {
    "autounattend.xml" = local.autounattend
    "bootstrap.ps1"    = local.bootstrap
  }
}

# ---------------------------------------------------------------------------
# 2. Build VM. Windows ISO + VMDP container disk + sysprep CD-ROM + empty
#    rootdisk (which becomes the golden image after sysprep). SATA rootdisk
#    during build (built-in Windows drivers); consumer VMs can use virtio-scsi
#    after the image is captured because VMDP installs virtio drivers.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "build_vm" {
  manifest = {
    apiVersion = "kubevirt.io/v1"
    kind       = "VirtualMachine"
    metadata = {
      name      = local.build_vm_name
      namespace = var.namespace
      labels = {
        "harvesterhci.io/creator" = "harvester"
        "harvesterhci.io/os"      = "windows"
      }
      annotations = {
        "harvesterhci.io/reservedMemory"        = "256Mi"
        "harvesterhci.io/volumeClaimTemplates"  = local.volume_claim_templates
      }
    }
    spec = {
      runStrategy = "RerunOnFailure"
      template = {
        metadata = { labels = { "harvesterhci.io/vmName" = local.build_vm_name } }
        spec = {
          evictionStrategy = "LiveMigrateIfPossible"
          domain = {
            firmware = local.is_win11 ? {
              bootloader = { efi = { secureBoot = true } }
            } : null
            cpu = { cores = var.cpu_cores }
            features = {
              acpi = { enabled = true }
              apic = { enabled = true }
              smm  = { enabled = true }
              hyperv = {
                relaxed    = { enabled = true }
                vapic      = { enabled = true }
                spinlocks  = { enabled = true, spinlocks = 8191 }
                vpindex    = { enabled = true }
                synic      = { enabled = true }
                synictimer = { enabled = true }
                ipi        = { enabled = true }
                runtime    = { enabled = true }
                reset      = { enabled = true }
              }
            }
            clock = {
              utc = {}
              timer = {
                hpet   = { present = false }
                hyperv = { present = true }
                pit    = { tickPolicy = "delay" }
                rtc    = { tickPolicy = "catchup" }
              }
            }
            devices = merge(
              local.is_win11 ? { tpm = {} } : {},
              {
                disks = [
                  { cdrom = { bus = "sata" }, name = "windows-iso", bootOrder = 1 },
                  { disk  = { bus = "sata" }, name = "rootdisk",    bootOrder = 2 },
                  { cdrom = { bus = "sata" }, name = "virtio-container-disk" },
                  { cdrom = { bus = "sata" }, name = "sysprep" },
                ]
                interfaces = [{ name = "default", masquerade = {}, model = "e1000" }]
                inputs     = [{ bus = "usb", name = "tablet", type = "tablet" }]
              },
            )
            resources = {
              limits = {
                cpu    = tostring(var.cpu_cores)
                memory = "${var.memory_gib}Gi"
              }
            }
          }
          networks = [{ name = "default", pod = {} }]
          volumes = [
            { name = "windows-iso",           persistentVolumeClaim = { claimName = "${local.build_vm_name}-iso" } },
            { name = "rootdisk",              persistentVolumeClaim = { claimName = "${local.build_vm_name}-rootdisk" } },
            { name = "virtio-container-disk", containerDisk = { image = var.vmdp_container_image, imagePullPolicy = "IfNotPresent" } },
            { name = "sysprep",               sysprep = { secret = { name = kubernetes_secret.unattend.metadata[0].name } } },
          ]
        }
      }
    }
  }
  wait {
    fields = { "status.printableStatus" = "Stopped" }
  }
  timeouts { create = "${var.wait_for_stop_seconds}s" }
}

# ---------------------------------------------------------------------------
# 3. Export the sysprepped rootdisk PVC as a VirtualMachineImage via CDI.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "golden_image" {
  manifest = {
    apiVersion = "harvesterhci.io/v1beta1"
    kind       = "VirtualMachineImage"
    metadata = {
      name      = var.output_image_name
      namespace = var.namespace
    }
    spec = {
      displayName  = var.output_image_name
      backend      = "cdi"
      sourceType   = "export-from-volume"
      pvcName      = "${local.build_vm_name}-rootdisk"
      pvcNamespace = var.namespace
    }
  }
  depends_on = [kubernetes_manifest.build_vm]
  wait {
    condition {
      type   = "Imported"
      status = "True"
    }
  }
  timeouts { create = "20m" }
}

# ---------------------------------------------------------------------------
# 4. Optional post-image cleanup — remove the build VM + PVCs. Golden image
#    is independent of the build resources once created.
# ---------------------------------------------------------------------------
resource "time_sleep" "settle_after_image" {
  count           = var.cleanup_build_vm ? 1 : 0
  create_duration = "10s"
  depends_on      = [kubernetes_manifest.golden_image]
}

output "image_name" {
  value       = var.output_image_name
  description = "Name of the produced VirtualMachineImage. Reference this from new VMs' volumeClaimTemplates annotation."
}

output "image_ref" {
  value       = "${var.namespace}/${var.output_image_name}"
  description = "Full '<namespace>/<name>' reference for the imageId annotation on consumer VMs."
}
