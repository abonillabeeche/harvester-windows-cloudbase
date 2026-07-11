$ErrorActionPreference = 'Continue'
$log = 'C:\winbuild.log'
function Log($m) {
  $t = (Get-Date).ToString('HH:mm:ss')
  "$t $m" | Tee-Object -FilePath $log -Append | Out-Host
}

Log '=== winbuild bootstrap starting ==='

# 0. OpenSSH is NOT installed in the golden image by default. Add-WindowsCapability
# for OpenSSH.Server pulls the FoD package online and adds ~6 minutes to the
# build. For per-VM SSH, install it from cloud-config runcmd at first boot.
# To include it in the golden image anyway, uncomment the block below and
# paste your public key.
#
# try {
#   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
#   Set-Service -Name sshd -StartupType Automatic
#   Start-Service sshd
#   New-NetFirewallRule -Name AllowSSHIn -DisplayName 'Allow SSH' -Protocol TCP `
#     -LocalPort 22 -Action Allow -Direction Inbound | Out-Null
#   $sshDir = 'C:\ProgramData\ssh'
#   New-Item -Force -ItemType Directory $sshDir | Out-Null
#   $authKeys = Join-Path $sshDir 'administrators_authorized_keys'
#   Set-Content -Path $authKeys -Value 'ssh-rsa AAAA... your-key-here'
#   icacls $authKeys /inheritance:r /grant 'SYSTEM:(F)' `
#     /grant 'BUILTIN\Administrators:(F)' | Out-Null
#   Log 'OpenSSH installed'
# } catch { Log "OpenSSH setup warning: $_" }

# 1. VMDP CD-ROM is hardcoded to E: — that's where the KubeVirt virtio-container-disk
# is attached (SATA bus, third disk after Windows ISO on D: and rootdisk on C:).
# NOTE: if the disk order changes (extra disks attached), update this letter.
$vmdp = 'E:'
if (-not (Test-Path "$vmdp\VMDP-WIN-2.5.5.exe")) {
  Log "ERROR: E:\VMDP-WIN-2.5.5.exe not found - VMDP CD-ROM not on expected drive"
  Get-Volume | Where-Object DriveType -eq 'CD-ROM' | Format-Table DriveLetter,FileSystemLabel | Out-String | ForEach-Object { Log $_ }
  exit 1
}
Log "VMDP CD-ROM at $vmdp"

# 2. Install VMDP silently — the setup.exe at the ISO root is just a wrapper
# that shows a dialog; the real installer is the self-extracting
# VMDP-WIN-*.exe. Extract it first, then run its inner setup.exe with silent
# flags passed as ONE STRING (Start-Process arg-array tokenization mangles
# the command line and triggers an interactive dialog).
$localSfx = 'C:\Windows\Temp\VMDP-WIN-2.5.5.exe'
Copy-Item "$vmdp\VMDP-WIN-2.5.5.exe" $localSfx -Force
Log "Copied VMDP self-extractor to $localSfx"
$extractDir = 'C:\Windows\Temp\vmdp-extracted'
if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
Log 'Extracting VMDP self-extractor...'
$p = Start-Process -FilePath $localSfx -ArgumentList "-o`"$extractDir`" -y" -Wait -PassThru
Log "extractor exit: $($p.ExitCode)"
$innerDir = (Get-ChildItem $extractDir -Directory -EA SilentlyContinue | Select -First 1).FullName
if (-not $innerDir) { Log 'no extracted dir'; exit 1 }
$innerSetup = Join-Path $innerDir 'setup.exe'
if (-not (Test-Path $innerSetup)) { Log "no setup.exe in $innerDir"; exit 1 }
Log "Running extracted setup.exe from $innerDir with single-string args..."
$p = Start-Process -FilePath $innerSetup -ArgumentList '/lic_accepted /no_reboot' -WorkingDirectory $innerDir -Wait -PassThru
Log "VMDP inner setup exit: $($p.ExitCode)"
Start-Sleep 15
$qgaSvc = Get-Service qemu-ga -EA SilentlyContinue
if ($qgaSvc) { Log "qemu-ga service: $($qgaSvc.Status)" } else { Log 'WARNING: qemu-ga NOT installed' }
# SUSE VMDP uses pvvx* prefix (not RedHat's vio*)
$drv = @(Get-ChildItem 'C:\Windows\System32\drivers\pvvx*.sys','C:\Windows\System32\drivers\vio*.sys' -EA SilentlyContinue)
Log "virtio-family drivers on disk: $($drv.Count) files"

# 3. Download Cloudbase-Init MSI
Log 'Downloading Cloudbase-Init...'
$msi = 'C:\Windows\Temp\CloudbaseInitSetup_x64.msi'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
  Invoke-WebRequest -UseBasicParsing -Uri 'https://cloudbase.it/downloads/CloudbaseInitSetup_x64.msi' -OutFile $msi
  Log "Downloaded to $msi ($((Get-Item $msi).Length) bytes)"
} catch {
  Log "ERROR downloading CBI: $_"; exit 1
}

# 4. Install Cloudbase-Init silently
Log 'Installing Cloudbase-Init...'
$p = Start-Process msiexec -ArgumentList "/i `"$msi`" /qn /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1 LOGGINGSERIALPORTNAME=COM1" -Wait -PassThru
Log "CBI msiexec exit code: $($p.ExitCode)"

# 5. Overwrite CBI config files with SUSE-KB content
$cbiConf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
$common = @'
[DEFAULT]
username=Admin
groups=Administrators
inject_user_password=true
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
verbose=true
debug=true
logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
logging_serial_port_settings=COM1,115200,N,8
mtu_use_dhcp_config=true
ntp_use_dhcp_config=true
local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService,cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.base.EmptyMetadataService
'@

$mainConf = $common + "`nlogfile=cloudbase-init.log`ncheck_latest_version=true`n"
$unattendConf = $common + @'

logfile=cloudbase-init-unattend.log
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin
check_latest_version=false
allow_reboot=false
stop_service_on_exit=false
'@

Set-Content -Path (Join-Path $cbiConf 'cloudbase-init.conf') -Value $mainConf -Encoding ASCII
Set-Content -Path (Join-Path $cbiConf 'cloudbase-init-unattend.conf') -Value $unattendConf -Encoding ASCII
Log 'CBI conf files written'

# 6. Run sysprep /generalize /shutdown using CBI-provided Unattend.xml.
# Copy the file to a spaces-free path first — Start-Process -ArgumentList array
# joins items with plain spaces, breaking any path arg that contains spaces.
$cbiUnattend = Join-Path $cbiConf 'Unattend.xml'
if (-not (Test-Path $cbiUnattend)) { Log "ERROR: CBI Unattend.xml missing at $cbiUnattend"; exit 1 }
$syspUnattend = 'C:\Windows\Temp\cbi-unattend.xml'
Copy-Item -Force $cbiUnattend $syspUnattend
Log "Copied CBI Unattend to $syspUnattend"
Log 'Running sysprep /generalize /oobe /shutdown ...'
Start-Process -FilePath "$env:WINDIR\System32\sysprep\sysprep.exe" `
  -ArgumentList '/generalize','/oobe','/shutdown',"/unattend:$syspUnattend"
Log '=== bootstrap done (sysprep will shut the VM down) ==='
