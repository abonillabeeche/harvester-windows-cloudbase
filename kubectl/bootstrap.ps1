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

# 1. Locate the VMDP CD-ROM by content, not a fixed letter — the drive letter
# shifts with disk order/bus (e.g. a virtio-scsi rootdisk changes the CD
# lettering). Scan every drive for the VMDP self-extractor.
$vmdp = $null
foreach ($d in (Get-PSDrive -PSProvider FileSystem).Root) {
  if (Test-Path (Join-Path $d 'VMDP-WIN-2.5.5.exe')) { $vmdp = $d.TrimEnd('\'); break }
}
if (-not $vmdp) {
  Log 'ERROR: VMDP-WIN-2.5.5.exe not found on any drive - VMDP CD-ROM not attached'
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

# allow_reboot=false is CRITICAL: on first boot the main service runs during the
# sysprep *specialize* pass. If SetHostNamePlugin (or any plugin) requests a
# reboot and allow_reboot defaults to true, the service reboots the machine out
# from under Windows Setup -> "The computer restarted unexpectedly or encountered
# an unexpected error. Windows installation cannot proceed." boot loop. With
# allow_reboot=false the hostname is just written and applied by Setup's own
# sanctioned reboot at the end of specialize. Only bites when a metadata/config
# (NoCloud) disk is attached (otherwise there's no hostname to set).
$mainConf = $common + "`nlogfile=cloudbase-init.log`ncheck_latest_version=true`nallow_reboot=false`nstop_service_on_exit=false`n"
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

# 5b. Reconcile AppX packages so sysprep /generalize won't abort with 0x80073cf2
# ("installed for a user, but not provisioned for all users" in AppxSysprep.dll;
# modern Chromium Edge — Microsoft.MicrosoftEdge.Stable — is the classic culprit).
#
# IMPORTANT: do NOT blanket-run Remove-AppxProvisionedPackage. Deprovisioning a
# package whose per-user copy then refuses to uninstall is exactly what *creates*
# the mismatch that fails sysprep. Instead:
#   (a) best-effort remove per-user packages (keeps the image lean),
#   (b) hard-uninstall Chromium Edge via its own setup.exe (its AppX resists
#       Remove-AppxPackage), and
#   (c) a RECONCILIATION pass that (re)provisions every package STILL installed
#       for a user. That last pass is what actually prevents the failure: whatever
#       refused to uninstall is made consistent (provisioned == installed) so
#       generalize is satisfied instead of aborting.
Log 'Reconciling AppX packages for sysprep generalize...'
# Edge tends to hold a running process; stop it so removal/uninstall can proceed.
Get-Process msedge,MicrosoftEdge,msedgewebview2 -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Get-AppxPackage -AllUsers -EA SilentlyContinue | ForEach-Object {
  try { Remove-AppxPackage -AllUsers -Package $_.PackageFullName -EA Stop; Log "removed pkg $($_.Name)" }
  catch { Log "keep pkg $($_.Name)" }
}
$edgeSetup = Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe' -EA SilentlyContinue | Select-Object -Last 1
if ($edgeSetup) {
  Log "Uninstalling Chromium Edge via $($edgeSetup.FullName)"
  try { Start-Process -FilePath $edgeSetup.FullName -ArgumentList '--uninstall','--system-level','--force-uninstall' -Wait -EA Stop } catch { Log "Edge uninstall warn: $_" }
}
# (c) Reconciliation: provision whatever is still installed for a user so there is
# no "installed-but-not-provisioned" (or provisioned-but-newer-per-user) mismatch
# left for generalize to trip over. -SkipLicense provisions from the installed
# package's manifest without needing the original .appx + license file.
Get-AppxPackage -AllUsers -EA SilentlyContinue | ForEach-Object {
  $manifest = Join-Path $_.InstallLocation 'AppxManifest.xml'
  if (Test-Path $manifest) {
    try { Add-AppxProvisionedPackage -Online -PackagePath $manifest -SkipLicense -EA Stop | Out-Null; Log "provisioned $($_.Name)" }
    catch { Log "provision skip $($_.Name): $($_.Exception.Message)" }
  }
}
Log 'AppX reconcile done'

# 5c. Minimize the golden image. Two things shrink the exported image:
#   (1) delete build scratch so it is not baked into the image, and
#   (2) zero the remaining NTFS free space so `qemu-img convert` (which drops
#       runs of zeros) produces a compact qcow2. Windows ships no sdelete, so
#       fill free space with a zero file, then delete it.
# NOTE: the zero-fill briefly allocates the whole rootdisk in the thin pool;
# on a small (e.g. 32 GiB) build disk this is fine. Skip it (comment out the
# zero-fill block) if your build volume shares a nearly-full thin pool.
Log 'Cleaning up build scratch...'
Remove-Item C:\Windows\Temp\bootstrap.b64, C:\bootstrap.ps1, `
  C:\Windows\Temp\vmdp-extracted, C:\Windows\Temp\VMDP-WIN-2.5.5.exe, `
  C:\Windows\Temp\CloudbaseInitSetup_x64.msi -Recurse -Force -EA SilentlyContinue

Log 'Zeroing free space for a compact export...'
$zero = 'C:\zero.fill'
try {
  $bufSize = 64MB
  $buf = New-Object byte[] $bufSize
  $fs = [System.IO.File]::Create($zero)
  try { while ($true) { $fs.Write($buf, 0, $bufSize) } }  # runs until ENOSPC
  catch { }
  finally { $fs.Close() }
} catch { Log "zero-fill note: $_" }
Remove-Item $zero -Force -EA SilentlyContinue
Log 'Free space zeroed'

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
