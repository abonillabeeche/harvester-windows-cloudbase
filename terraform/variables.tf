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

variable "windows_iso_image_ref" {
  description = "Harvester VirtualMachineImage reference for the Windows install ISO, as '<namespace>/<image-name>'."
  type        = string
}

variable "windows_edition" {
  description = "Edition name inside the ISO's install.wim (must match exactly). Examples: 'Windows Server 2022 SERVERSTANDARD', 'Windows 11 Pro'."
  type        = string
  default     = "Windows Server 2022 SERVERSTANDARD"
}

variable "windows_product_key" {
  description = "Product key inserted into the unattend. Empty for Server evaluation ISOs. For Windows 11 the default is the public Pro KMS client setup key."
  type        = string
  default     = ""
}

variable "output_image_name" {
  description = "Name of the resulting VirtualMachineImage."
  type        = string
  default     = "win2022-cloudbase"
}

variable "storage_class" {
  description = "StorageClass for the build PVCs and the exported image PVC. Use 'lvm-thin' for intra-driver COW clone (fastest)."
  type        = string
  default     = "lvm-thin"
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
  description = "Golden image rootdisk size in GiB."
  type        = number
  default     = 64
}

variable "enable_efi_tpm" {
  description = "Enable UEFI + Secure Boot + vTPM in the build VM (required for Windows 11)."
  type        = bool
  default     = false
}

variable "enable_win11_bypass_checks" {
  description = "Write LabConfig registry keys during Setup to bypass Windows 11 CPU / TPM / Secure Boot / RAM / storage compatibility checks. Ignored for non-Win11 editions."
  type        = bool
  default     = false
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
