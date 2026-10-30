# frozen_string_literal: true

# @summary Private shared strings for `winget::install::*` (issue #75).
#
# Single source of truth for the PowerShell fragments duplicated across
# `winget::install::cdn`, `winget::install::github` and
# `winget::install::local`: the uninstall command and its `onlyif` guard,
# the presence-only install guard, the version-aware presence-check
# template and the download/install command templates.
#
# Private: do not declare this class directly. The install defines consume
# these variables (`$winget::install::common::...`), filling the
# placeholders with `sprintf` (their own URI, source path or escaped
# version). The composed commands are unchanged: the `cdn` presence-only
# guard and its version warning, the `msstore` alias and the `local`
# dependency guard stay exactly as they are.
class winget::install::common {
  # Removal covers both registration flavors: per-user/all-users instances
  # and the staged provisioned package. Each step is best effort; the exec
  # fails closed only when an instance still resolves afterwards.
  $uninstall_command = "\$pkgs = Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller; if (\$pkgs) { try { \$pkgs | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch { Write-Warning ('Remove-AppxPackage failed, trying provisioned removal: ' + \$_.Exception.Message) } }; \$prov = Get-AppxProvisionedPackage -Online | Where-Object { \$_.PackageName -like 'Microsoft.DesktopAppInstaller*' }; if (\$prov) { try { \$prov | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName \$_.PackageName -ErrorAction Stop } } catch { Write-Warning ('Remove-AppxProvisionedPackage failed: ' + \$_.Exception.Message) } }; if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { throw 'Microsoft.DesktopAppInstaller is still installed' }"
  $uninstall_onlyif = "if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } elseif (Get-AppxProvisionedPackage -Online | Where-Object { \$_.PackageName -like 'Microsoft.DesktopAppInstaller*' }) { exit 0 } else { exit 1 }"

  # Presence-only install guard: the install runs only when App Installer
  # is absent.
  $presence_check = 'if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }'

  # Version-aware presence-check template (placeholder is the regex-escaped
  # pinned version): reinstalls while another version is present and stays
  # idempotent once installed. AppX versions carry an extra revision segment
  # (installed `1.8.2391.0` satisfies pin `1.8.2391`).
  $presence_check_version_template = "if (((Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Select-Object -First 1).Version -join '') -match '^%s(\\.|$)') { exit 0 } else { exit 1 }"

  # Download/install template (placeholder is the bundle URI): downloads into a
  # per-run unique directory locked down to SYSTEM and Administrators,
  # fails closed unless the bundle signature is a valid Microsoft one, and
  # falls back to provisioning when `Add-AppxPackage` fails under SYSTEM.
  $download_install_template = "\$ProgressPreference = 'SilentlyContinue'; \$workDir = Join-Path \$env:TEMP ('winget-install-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path \$workDir -Force | Out-Null; \$acl = Get-Acl -Path \$workDir; \$acl.SetAccessRuleProtection(\$true, \$false); \$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))); \$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))); Set-Acl -Path \$workDir -AclObject \$acl; try { \$bundle = Join-Path \$workDir 'winget.msixbundle'; Invoke-WebRequest -UseBasicParsing -Uri '%s' -OutFile \$bundle; \$sig = Get-AuthenticodeSignature -FilePath \$bundle; if ((\$sig.Status -ne 'Valid') -or (\$sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation')) { throw ('winget bundle signature check failed (Status: ' + \$sig.Status + ')') }; try { Add-AppxPackage -Path \$bundle -ErrorAction Stop } catch { Add-AppxProvisionedPackage -Online -PackagePath \$bundle -SkipLicense } } finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \$workDir }"

  # Local-file install template (placeholder is the quoted source path, used
  # twice): falls back to provisioning when `Add-AppxPackage` fails under
  # SYSTEM.
  $local_install_template = "try { Add-AppxPackage -Path '%s' -ErrorAction Stop } catch { Add-AppxProvisionedPackage -Online -PackagePath '%s' -SkipLicense }"
}
