provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig)
}

provider "kubectl" {
  config_path      = pathexpand(var.kubeconfig)
  load_config_file = true
}

locals {
  build_vm_name = "winbuild-tf"
  is_win11      = var.enable_efi_tpm

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

  # Harvester's admission webhook forbids directly referencing an image
  # source PVC in a VM ("golden image ... can't be used as a volume"),
  # so we go through the standard imageId-annotation clone path. On
  # lvm-thin the clone is intra-driver COW (fast); on longhorn it's a
  # byte-stream copy (~5 min for a 5 GB Windows ISO).
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

  build_vm_yaml = yamlencode({
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
        "harvesterhci.io/reservedMemory"       = "256Mi"
        "harvesterhci.io/volumeClaimTemplates" = local.volume_claim_templates
      }
    }
    spec = {
      runStrategy = "RerunOnFailure"
      template = {
        metadata = { labels = { "harvesterhci.io/vmName" = local.build_vm_name } }
        spec = merge(
          {
            evictionStrategy = "LiveMigrateIfPossible"
            domain = merge(
              local.is_win11 ? {
                firmware = { bootloader = { efi = { secureBoot = true } } }
              } : {},
              {
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
                resources = { limits = { cpu = tostring(var.cpu_cores), memory = "${var.memory_gib}Gi" } }
              },
            )
            networks = [{ name = "default", pod = {} }]
            volumes = [
              { name = "windows-iso",           persistentVolumeClaim = { claimName = "${local.build_vm_name}-iso" } },
              { name = "rootdisk",              persistentVolumeClaim = { claimName = "${local.build_vm_name}-rootdisk" } },
              { name = "virtio-container-disk", containerDisk = { image = var.vmdp_container_image, imagePullPolicy = "IfNotPresent" } },
              { name = "sysprep",               sysprep = { secret = { name = kubernetes_secret.unattend.metadata[0].name } } },
            ]
          },
        )
      }
    }
  })

  export_image_yaml = yamlencode({
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
  })
}

# ---------------------------------------------------------------------------
# Sysprep secret carrying the rendered Autounattend.xml + bootstrap.ps1.
# KubeVirt mounts this as a CD-ROM ISO with both files at the root.
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
# Build VM. Waits for status.printableStatus=Stopped (sysprep completed).
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "build_vm" {
  yaml_body = local.build_vm_yaml
}

# kubectl_manifest doesn't support field-value waits for arbitrary CRDs, so
# poll status.printableStatus via `kubectl wait` in a null_resource. Windows
# install + VMDP + CBI + sysprep is 20-25 min. Give plenty of headroom.
resource "null_resource" "wait_build_vm_stopped" {
  depends_on = [kubectl_manifest.build_vm]
  triggers   = { build_vm_id = kubectl_manifest.build_vm.uid }
  provisioner "local-exec" {
    # `kubectl wait --for=jsonpath` sometimes returns "condition met" on a
    # freshly-created CR whose status subresource isn't populated yet, so
    # we roll our own polling loop that only counts a real "Stopped" match.
    command     = <<-EOT
      KC="${pathexpand(var.kubeconfig)}"
      NS="${var.namespace}"
      NAME="${local.build_vm_name}"
      MAX=${var.wait_for_stop_seconds}
      START=$(date +%s)
      while :; do
        NOW=$(date +%s); ELAPSED=$((NOW - START))
        if [ $ELAPSED -ge $MAX ]; then echo "TIMEOUT after $${ELAPSED}s"; exit 1; fi
        STATUS=$(kubectl --kubeconfig "$KC" -n "$NS" get vm "$NAME" -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
        if [ "$STATUS" = "Stopped" ]; then
          echo "vm/$NAME reached Stopped after $${ELAPSED}s"
          exit 0
        fi
        if [ $((ELAPSED % 60)) -lt 5 ]; then echo "[$${ELAPSED}s] vm/$NAME status=$${STATUS:-<empty>}"; fi
        sleep 5
      done
    EOT
    interpreter = ["bash", "-c"]
  }
}

# ---------------------------------------------------------------------------
# Export the sysprepped rootdisk PVC as a VirtualMachineImage via CDI.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "golden_image" {
  yaml_body  = local.export_image_yaml
  depends_on = [null_resource.wait_build_vm_stopped]
}

resource "null_resource" "wait_image_imported" {
  depends_on = [kubectl_manifest.golden_image]
  triggers   = { image_id = kubectl_manifest.golden_image.uid }
  provisioner "local-exec" {
    command     = <<-EOT
      KC="${pathexpand(var.kubeconfig)}"
      NS="${var.namespace}"
      NAME="${var.output_image_name}"
      MAX=1200  # 20 min
      START=$(date +%s)
      while :; do
        NOW=$(date +%s); ELAPSED=$((NOW - START))
        if [ $ELAPSED -ge $MAX ]; then echo "TIMEOUT after $${ELAPSED}s"; exit 1; fi
        STATUS=$(kubectl --kubeconfig "$KC" -n "$NS" get virtualmachineimage "$NAME" -o jsonpath='{.status.conditions[?(@.type=="Imported")].status}' 2>/dev/null || true)
        PROGRESS=$(kubectl --kubeconfig "$KC" -n "$NS" get virtualmachineimage "$NAME" -o jsonpath='{.status.progress}' 2>/dev/null || true)
        if [ "$STATUS" = "True" ]; then
          echo "virtualmachineimage/$NAME Imported=True after $${ELAPSED}s"
          exit 0
        fi
        if [ $((ELAPSED % 60)) -lt 5 ]; then echo "[$${ELAPSED}s] image/$NAME imported=$${STATUS:-<empty>} progress=$${PROGRESS:-0}"; fi
        sleep 5
      done
    EOT
    interpreter = ["bash", "-c"]
  }
}

# ---------------------------------------------------------------------------
# Optional post-image settle. The golden image is independent of the build
# resources once created — you can `terraform destroy -target=kubectl_manifest.build_vm`
# to clean up the build VM while keeping the image.
# ---------------------------------------------------------------------------
resource "time_sleep" "settle_after_image" {
  count           = var.cleanup_build_vm ? 1 : 0
  create_duration = "10s"
  depends_on      = [null_resource.wait_image_imported]
}

output "image_name" {
  value       = var.output_image_name
  description = "Name of the produced VirtualMachineImage. Reference this from new VMs' volumeClaimTemplates annotation."
}

output "image_ref" {
  value       = "${var.namespace}/${var.output_image_name}"
  description = "Full '<namespace>/<name>' reference for the imageId annotation on consumer VMs."
}
