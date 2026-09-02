variable "kubeconfig" {
  description = "Path to the Harvester kubeconfig file."
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Namespace for the build VM and the resulting image."
  type        = string
  default     = "default"
}

variable "windows_version" {
  description = "Which Windows you are installing: \"2022\", \"2025\" or \"w11\". REQUIRED. It selects the install.wim edition string, the firmware/partition layout, the Win11 compat-check bypasses and the default image name -- each of which is overridable below. See docs/windows-versions.md."
  type        = string

  validation {
    condition     = contains(["2022", "2025", "w11"], var.windows_version)
    error_message = "windows_version must be one of: 2022, 2025, w11."
  }
}

variable "windows_iso_image_ref" {
  description = "Harvester VirtualMachineImage reference for the Windows install ISO, as '<namespace>/<image-name>'."
  type        = string
}

variable "windows_edition" {
  description = "Override the /IMAGE/NAME edition name inside the ISO's install.wim (must match byte for byte). Leave null to use the Desktop Experience Standard/Pro edition for windows_version. Set it for Datacenter media, e.g. 'Windows Server 2025 SERVERDATACENTER'. Verify with `wiminfo` or `dism /Get-WimInfo`."
  type        = string
  default     = null
}

variable "windows_product_key" {
  description = "Product key inserted into the unattend. Leave null for the per-version default: none for Server (evaluation and retail media do not need one here), and the public Pro KMS client setup key for Windows 11. Set \"\" to force no key."
  type        = string
  default     = null
}

variable "output_image_name" {
  description = "Name of the resulting VirtualMachineImage. Leave null to derive it from windows_version (win2022-cloudbase / win2025-cloudbase / win11-cloudbase)."
  type        = string
  default     = null
}

variable "storage_class" {
  description = "StorageClass for the rootdisk build PVC and the exported image PVC. Use any class you have tested; 'harvester-longhorn' ships on every Harvester cluster."
  type        = string
  default     = "harvester-longhorn"
}

variable "iso_storage_class" {
  description = "StorageClass for the ISO-clone PVC. MUST be the install ISO image's OWN dedicated StorageClass (Harvester names it 'longhorn-<image-name>'; read it from `kubectl get vmimage <name> -o jsonpath='{.status.storageClassName}'`). A generic class produces an empty clone and 'No Bootable Device'."
  type        = string
}

variable "install_openssh" {
  description = "Include OpenSSH Server in the golden image. Adds ~6 min to build time because Add-WindowsCapability pulls the FoD package online. Recommended: leave off, install SSH per-VM via cloud-config runcmd when you actually need it."
  type        = bool
  default     = false
}

variable "authorized_ssh_key" {
  description = "SSH public key granted admin login on the built VM (only if install_openssh=true). Leave empty to skip key install."
  type        = string
  default     = ""
}

variable "admin_password" {
  description = "Temporary admin password used only during build. Sysprep /generalize clears it before the image is captured. Consumer VMs set their own password via cloud-config."
  type        = string
  default     = "HarvesterBuild1!"
  sensitive   = true
}

variable "cpu_cores" {
  description = "Build VM vCPU count."
  type        = number
  default     = 4
}

variable "memory_gib" {
  description = "Build VM memory in GiB."
  type        = number
  default     = 8
}

variable "rootdisk_gib" {
  description = "Golden image rootdisk size in GiB. Keep this small; Cloudbase-Init's ExtendVolumesPlugin grows C: to the target disk when a consumer VM is created larger. Do not go far below the 36 default: Server 2025 + VMDP + Cloudbase-Init + the zero-fill pass needs the headroom, and sysprep /generalize fails outright on a full volume."
  type        = number
  default     = 36
}

variable "enable_efi_tpm" {
  description = "Enable UEFI + Secure Boot + vTPM in the build VM, and lay down the matching EFI/MSR/Windows partition layout. Leave null to derive from windows_version: on for w11, off for the Server releases (which install BIOS/MBR)."
  type        = bool
  default     = null
}

variable "enable_win11_bypass_checks" {
  description = "Write LabConfig registry keys during Setup to bypass the Windows 11 CPU / TPM / Secure Boot / RAM / storage compatibility checks. Leave null to derive from windows_version: on for w11, off otherwise (the Server releases have no such gates)."
  type        = bool
  default     = null
}

variable "vmdp_container_image" {
  description = "Container image for the VMDP driver CD-ROM."
  type        = string
  default     = "registry.suse.com/suse/vmdp/vmdp:2.5.5"
}

variable "cloudbase_init_msi_url" {
  description = "URL to the Cloudbase-Init MSI installer."
  type        = string
  default     = "https://cloudbase.it/downloads/CloudbaseInitSetup_x64.msi"
}

variable "wait_for_stop_seconds" {
  description = "How long to wait for the build VM to reach Stopped state after apply. Windows install + sysprep is typically 20-25 min."
  type        = number
  default     = 2700
}

variable "cleanup_build_vm" {
  description = "Delete the build VM + PVCs after the image is exported."
  type        = bool
  default     = true
}
