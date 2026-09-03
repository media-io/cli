# Media.io setup script for Windows.
# setup-mediaio.ps1 script version: 0.1.4
# Installs the Media.io plugin, CLI, and skills in one pass.
# CLI prefers npm and falls back to a release archive; direct skills are installed with npx only when plugin install is unavailable.
#
# Usage (from an existing PowerShell session):
#   irm https://raw.githubusercontent.com/<owner>/<repo>/main/setup-mediaio.ps1 | iex
#
# Environment variables (all optional):
#   MEDIAIO_INSTALL_DIR      — where to put the CLI binary       (default: ~/.local/bin)
#   MEDIAIO_VERSION          — version to install                (default: latest)
#   MEDIAIO_NPM_PACKAGE      — npm package name for the CLI      (default: @mediaio/cli)
#   MEDIAIO_NPM_REGISTRY     — npm registry URL                  (default: https://registry.npmjs.org)
#   MEDIAIO_RELEASE_REPO     — GitHub repo for release assets    (default: media-io/cli)
#   MEDIAIO_SKILL_REPO       — GitHub repo for skill source       (default: media-io/plugin)
#   MEDIAIO_SKILL_SOURCE     — local or remote skill source path
#
[CmdletBinding()]
param()


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StepIndex = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:ScriptVersion = "0.1.4"
$script:ResolvedClaudeMarketplaceName = $null
$script:UseCodexPersonalMarketplaceFallback = $false
$script:CodexPersonalMarketplaceFallbackReason = $null
$script:CodexMarketplaceAddFailure = $null
$script:ResolvedCodexMarketplaceName = $null
$script:ResolvedMediaIoSkillSource = $null
$script:ClaudeAvailable = $false
$script:CodexAvailable = $false
$script:ClaudePluginInstalled = $false
$script:CodexPluginInstalled = $false
$script:ClaudePluginReady = $false
$script:CodexPluginReady = $false

$MediaIoPackageName = if ($env:MEDIAIO_NPM_PACKAGE) { $env:MEDIAIO_NPM_PACKAGE } else { "@mediaio/cli" }
$MediaIoMarketplaceSource = if ($env:MEDIAIO_MARKETPLACE_SOURCE) { $env:MEDIAIO_MARKETPLACE_SOURCE } else { "media-io/plugin" }
$MediaIoClaudePluginId = if ($env:MEDIAIO_CLAUDE_PLUGIN_ID) { $env:MEDIAIO_CLAUDE_PLUGIN_ID } else { "media-io@media-io" }
$MediaIoCodexPluginName = if ($env:MEDIAIO_CODEX_PLUGIN_NAME) { $env:MEDIAIO_CODEX_PLUGIN_NAME } else { "media-io" }
$MediaIoCodexMarketplaceName = if ($env:MEDIAIO_CODEX_MARKETPLACE_NAME) { $env:MEDIAIO_CODEX_MARKETPLACE_NAME } else { "media-io" }
$MediaIoInstallDir = if ($env:MEDIAIO_INSTALL_DIR) { $env:MEDIAIO_INSTALL_DIR } else { Join-Path $HOME ".local\bin" }
$MediaIoNpmRegistry = if ($env:MEDIAIO_NPM_REGISTRY) { $env:MEDIAIO_NPM_REGISTRY.TrimEnd('/') } else { "https://registry.npmjs.org" }
$MediaIoReleaseRepo = if ($env:MEDIAIO_RELEASE_REPO) { $env:MEDIAIO_RELEASE_REPO } else { "media-io/cli" }
$MediaIoReleaseBaseUrl = if ($env:MEDIAIO_RELEASE_BASE_URL) { $env:MEDIAIO_RELEASE_BASE_URL.TrimEnd('/') } else { "https://github.com/$MediaIoReleaseRepo/releases/download" }
$MediaIoVersion = if ($env:MEDIAIO_VERSION) { $env:MEDIAIO_VERSION } else { "latest" }
$MediaIoSkillRepo = if ($env:MEDIAIO_SKILL_REPO) { $env:MEDIAIO_SKILL_REPO } else { "media-io/plugin" }
$MediaIoSkillSource = if ($env:MEDIAIO_SKILL_SOURCE) { $env:MEDIAIO_SKILL_SOURCE } else { "" }
$MediaIoPluginArchiveUrl = if ($env:MEDIAIO_PLUGIN_ARCHIVE_URL) { $env:MEDIAIO_PLUGIN_ARCHIVE_URL } else { "https://github.com/media-io/plugin/archive/refs/heads/main.zip" }

function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Label)
  $script:StepIndex++
  Write-Host ""
  Write-Host ("[{0}] {1}" -f $script:StepIndex, $Label) -ForegroundColor Cyan
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)
  $script:Failures.Add($Message) | Out-Null
  Write-Host "  FAIL: $Message" -ForegroundColor Red
}

function Add-Warning {
  param([Parameter(Mandatory = $true)][string]$Message)
  $script:Warnings.Add($Message) | Out-Null
  Write-Host "  WARN: $Message" -ForegroundColor Yellow
}

function Test-CommandAvailable {
  param([Parameter(Mandatory = $true)][string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-DirectoryToPath {
  param([Parameter(Mandatory = $true)][string]$Directory)
  if (-not (Test-Path $Directory)) { return $false }

  $segments = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($segments -contains $Directory) { return $false }

  $env:Path = "$Directory;$env:Path"
  return $true
}

function Get-UserEnvironmentPathValue {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
  if ($null -eq $key) { return "" }
  try {
    $value = $key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [string]$value
  } finally {
    $key.Close()
  }
}

function Set-UserEnvironmentPathValue {
  param([Parameter(Mandatory = $true)][string]$Value)

  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Environment")
  if ($null -eq $key) {
    throw "Could not open HKCU\Environment for writing."
  }

  try {
    $key.SetValue("Path", $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
  } finally {
    $key.Close()
  }
}

function Broadcast-EnvironmentChange {
  if (-not ("User32.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace User32 {
  public static class NativeMethods {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, IntPtr wParam, string lParam, int flags, int timeout, out IntPtr result);
  }
}
"@
  }

  $HWND_BROADCAST = [IntPtr]0xffff
  $WM_SETTINGCHANGE = 0x001A
  $SMTO_ABORTIFHUNG = 0x0002
  $result = [IntPtr]::Zero
  [void][User32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, "Environment", $SMTO_ABORTIFHUNG, 5000, [ref]$result)
}

function Add-DirectoryToUserPath {
  param([Parameter(Mandatory = $true)][string]$Directory)
  if (-not (Test-Path $Directory)) { return }

  [void](Add-DirectoryToPath -Directory $Directory)
  $userPath = Get-UserEnvironmentPathValue
  $segments = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($segments -contains $Directory) { return }

  if ([string]::IsNullOrWhiteSpace($userPath)) {
    Set-UserEnvironmentPathValue -Value $Directory
  } else {
    Set-UserEnvironmentPathValue -Value "$Directory;$userPath"
  }

  Broadcast-EnvironmentChange
}

function Repair-NodePathFromCommonLocations {
  $nodeDirs = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $nodeDirs.Add((Join-Path -Path $env:ProgramFiles -ChildPath "nodejs"))
  }
  $programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
  if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
    $nodeDirs.Add((Join-Path -Path $programFilesX86 -ChildPath "nodejs"))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
    $nodeDirs.Add((Join-Path -Path $env:LocalAppData -ChildPath "Programs\nodejs"))
  }

  $changed = $false
  foreach ($dir in $nodeDirs) {
    if (Test-Path (Join-Path $dir "npm.cmd")) {
      if (Add-DirectoryToPath -Directory $dir) { $changed = $true }
    }
  }

  return $changed
}

function Install-NodeLts {
  Write-Host "  npm is missing, so I will install Node.js LTS (which includes npm)." -ForegroundColor Yellow

  $installed = $false
  if (Test-CommandAvailable "winget") {
    Write-Host "  Trying winget install: OpenJS.NodeJS.LTS" -ForegroundColor DarkGray
    & cmd /c "winget install --id OpenJS.NodeJS.LTS -e --scope user --silent --accept-package-agreements --accept-source-agreements"
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -eq 0) {
      $installed = $true
    } else {
      Add-Warning "winget install returned exit code $exitCode."
    }
  } elseif (Test-CommandAvailable "choco") {
    Write-Host "  Trying choco install: nodejs-lts" -ForegroundColor DarkGray
    & cmd /c "choco install nodejs-lts -y --limit-output"
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -eq 0) {
      $installed = $true
    } else {
      Add-Warning "choco install returned exit code $exitCode."
    }
  } else {
    throw "No supported package manager was found. Install Node.js LTS manually so npm becomes available."
  }

  if (-not $installed) { throw "Node.js LTS installation did not complete successfully." }

  Start-Sleep -Seconds 2
  [void](Repair-NodePathFromCommonLocations)
}

function Ensure-NodeAndNpm {
  $nodeOk = Test-CommandAvailable "node"
  $npmOk = Test-CommandAvailable "npm"

  if (-not $nodeOk -or -not $npmOk) {
    Add-Warning "Node.js/npm are not both available in PATH. Trying a local PATH repair first."
    [void](Repair-NodePathFromCommonLocations)
    $nodeOk = Test-CommandAvailable "node"
    $npmOk = Test-CommandAvailable "npm"
  }

  if (-not $nodeOk -or -not $npmOk) {
    Install-NodeLts
    $nodeOk = Test-CommandAvailable "node"
    $npmOk = Test-CommandAvailable "npm"
  }

  if (-not $nodeOk -or -not $npmOk) {
    throw "Node.js/npm are still unavailable after repair and install attempts."
  }

  & cmd /c "node -v"
  if ($LASTEXITCODE -ne 0) { throw "node -v failed." }
  & cmd /c "npm -v"
  if ($LASTEXITCODE -ne 0) { throw "npm -v failed." }
  & cmd /c "npx --version"
  if ($LASTEXITCODE -ne 0) { throw "npx --version failed." }
}

function Invoke-CheckedStep {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [scriptblock]$Verify = $null,
    [string]$SuccessMessage = ""
  )

  Write-Step $Label

  try {
    $global:LASTEXITCODE = 0
    & $Action
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) { throw "Command exited with code $exitCode." }

    if ($Verify) {
      & $Verify
      $verifyExitCode = $LASTEXITCODE
      if ($null -ne $verifyExitCode -and $verifyExitCode -ne 0) {
        throw "Verification command exited with code $verifyExitCode."
      }
    }

    if ($SuccessMessage) {
      Write-Host "  OK: $SuccessMessage" -ForegroundColor Green
    } else {
      Write-Host "  OK" -ForegroundColor Green
    }
    return
  } catch {
    Add-Failure "$Label - $($_.Exception.Message)"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
      Write-Host $_.InvocationInfo.PositionMessage.TrimEnd() -ForegroundColor DarkRed
    }
    if ($_.ScriptStackTrace) {
      Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    return
  }
}

function Invoke-OptionalFallbackStep {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][scriptblock]$Primary,
    [Parameter(Mandatory = $true)][scriptblock]$Fallback,
    [scriptblock]$Verify = $null,
    [string]$SuccessMessage = ""
  )

  Write-Step $Label

  try {
    $global:LASTEXITCODE = 0
    & $Primary
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
      throw "Primary command exited with code $exitCode."
    }
  } catch {
    Add-Warning "$Label primary path failed: $($_.Exception.Message)"
    Write-Host "  Trying fallback path..." -ForegroundColor DarkGray
    try {
      $global:LASTEXITCODE = 0
      & $Fallback
      $fallbackExitCode = $LASTEXITCODE
      if ($null -ne $fallbackExitCode -and $fallbackExitCode -ne 0) {
        throw "Fallback command exited with code $fallbackExitCode."
      }
    } catch {
      Add-Failure "$Label fallback failed: $($_.Exception.Message)"
      return
    }
  }

  try {
    if ($Verify) {
      & $Verify
      $verifyExitCode = $LASTEXITCODE
      if ($null -ne $verifyExitCode -and $verifyExitCode -ne 0) {
        throw "Verification command exited with code $verifyExitCode."
      }
    }
  } catch {
    Add-Failure "$Label verification failed: $($_.Exception.Message)"
    return
  }

  if ($SuccessMessage) {
    Write-Host "  OK: $SuccessMessage" -ForegroundColor Green
  } else {
    Write-Host "  OK" -ForegroundColor Green
  }
  return
}

function Invoke-SoftStep {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [string]$SuccessMessage = ""
  )

  Write-Step $Label

  try {
    $global:LASTEXITCODE = 0
    & $Action
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
      throw "Command exited with code $exitCode."
    }

    if ($SuccessMessage) {
      Write-Host "  OK: $SuccessMessage" -ForegroundColor Green
    } else {
      Write-Host "  OK" -ForegroundColor Green
    }
    return $true
  } catch {
    Add-Warning "$Label failed: $($_.Exception.Message)"
    return $false
  }
}

function Invoke-OptionalHostDetection {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$CommandName,
    [Parameter(Mandatory = $true)][scriptblock]$Setter
  )

  Write-Step $Label
  if (Test-CommandAvailable $CommandName) {
    & $Setter $true
    Write-Host "  OK: $CommandName is available" -ForegroundColor Green
  } else {
    & $Setter $false
    Add-Warning "$CommandName is not available; skipping $Label dependent steps."
  }
}

function Get-MediaIoArch {
  if ($env:MEDIAIO_ARCH) {
    $override = $env:MEDIAIO_ARCH.ToLower()
    if ($override -eq "amd64" -or $override -eq "arm64") { return $override }
    throw "Invalid MEDIAIO_ARCH value '$env:MEDIAIO_ARCH'. Must be 'amd64' or 'arm64'."
  }

  try {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch) {
      switch ($arch.ToString()) {
        "X64" { return "amd64" }
        "Arm64" { return "arm64" }
      }
    }
  } catch {}

  $envArch = $env:PROCESSOR_ARCHITECTURE
  if ($envArch) {
    switch ($envArch.ToUpper()) {
      "AMD64" { return "amd64" }
      "ARM64" { return "arm64" }
      "X86" {
        $realArch = $env:PROCESSOR_ARCHITEW6432
        if ($realArch) {
          switch ($realArch.ToUpper()) {
            "AMD64" { return "amd64" }
            "ARM64" { return "arm64" }
          }
        }
        throw "32-bit Windows is not supported."
      }
    }
  }

  throw "Unsupported architecture. Set MEDIAIO_ARCH to 'amd64' or 'arm64'."
}

function Get-NpmPackageMetadataUrl {
  $escapedPackageName = [System.Uri]::EscapeDataString($MediaIoPackageName)
  return "$MediaIoNpmRegistry/$escapedPackageName"
}

function Resolve-MediaIoNpmPackageInfo {
  $metadataUrl = Get-NpmPackageMetadataUrl
  Write-Host "  Resolving $MediaIoPackageName from $metadataUrl" -ForegroundColor DarkGray
  $metadata = Invoke-RestMethod -Uri $metadataUrl -UseBasicParsing -ErrorAction Stop

  $npmVersion = $script:MediaIoVersion
  if ($npmVersion -eq "latest") {
    $latestTag = $metadata.'dist-tags'.latest
    if ([string]::IsNullOrWhiteSpace([string]$latestTag)) {
      throw "npm metadata for $MediaIoPackageName does not declare dist-tags.latest."
    }
    $npmVersion = [string]$latestTag
  } elseif ($npmVersion.StartsWith("v")) {
    $npmVersion = $npmVersion.Substring(1)
  }

  $versionProperty = $metadata.versions.PSObject.Properties[$npmVersion]
  if ($null -eq $versionProperty) {
    throw "npm metadata for $MediaIoPackageName does not contain version $npmVersion."
  }

  $versionInfo = $versionProperty.Value
  if ($null -eq $versionInfo.dist -or [string]::IsNullOrWhiteSpace([string]$versionInfo.dist.tarball)) {
    throw "npm metadata for $MediaIoPackageName@$npmVersion does not declare dist.tarball."
  }

  $script:MediaIoVersion = $npmVersion
  return [pscustomobject]@{
    Version = $npmVersion
    Tarball = [string]$versionInfo.dist.tarball
    Integrity = [string]$versionInfo.dist.integrity
    Shasum = [string]$versionInfo.dist.shasum
  }
}

function Resolve-MediaIoVersionFromNpm {
  $packageInfo = Resolve-MediaIoNpmPackageInfo
  Write-Host "  Resolved Media.io CLI npm release to $($packageInfo.Version)" -ForegroundColor DarkGray
}

function Get-NpmGlobalBinDir {
  return [string]((npm prefix -g) | Out-String).Trim()
}

function Get-MediaIoReleaseTag {
  if ($script:MediaIoVersion.StartsWith("v")) { return $script:MediaIoVersion }
  return "v$script:MediaIoVersion"
}

function Assert-NpmPackageIntegrityIfAvailable {
  param(
    [Parameter(Mandatory = $true)][string]$AssetPath,
    [string]$Integrity = "",
    [string]$Shasum = ""
  )

  if (-not [string]::IsNullOrWhiteSpace($Integrity)) {
    $integrityItems = @($Integrity -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($item in $integrityItems) {
      if ($item -notmatch '^sha512-(.+)$') { continue }
      $expectedBytes = [Convert]::FromBase64String($Matches[1])
      $actualBytes = [System.Security.Cryptography.SHA512]::Create().ComputeHash([System.IO.File]::ReadAllBytes($AssetPath))
      $expected = [Convert]::ToBase64String($expectedBytes)
      $actual = [Convert]::ToBase64String($actualBytes)
      if ($actual -ne $expected) {
        throw "npm package integrity mismatch. Expected sha512-$expected, got sha512-$actual."
      }
      Write-Host "  OK: npm package integrity verified with sha512" -ForegroundColor Green
      return
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($Shasum)) {
    $actualSha1 = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA1 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actualSha1 -ne $Shasum.ToLowerInvariant()) {
      throw "npm package shasum mismatch. Expected $Shasum, got $actualSha1."
    }
    Write-Host "  OK: npm package shasum verified with sha1" -ForegroundColor Green
    return
  }

  Add-Warning "npm metadata did not include dist.integrity or dist.shasum, so package verification is skipped."
}

function Get-WindowsTarPath {
  $systemTarCandidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
    $systemTarCandidates += Join-Path $env:WINDIR "Sysnative\tar.exe"
    $systemTarCandidates += Join-Path $env:WINDIR "System32\tar.exe"
  }

  foreach ($candidate in $systemTarCandidates) {
    if (Test-Path $candidate) { return $candidate }
  }

  $command = Get-Command "tar.exe" -ErrorAction SilentlyContinue
  if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
    $source = [string]$command.Source
    if ($source -notmatch "\\Git\\usr\\bin\\tar\.exe$") { return $source }
  }

  $command = Get-Command "tar" -ErrorAction SilentlyContinue
  if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
    $source = [string]$command.Source
    if ($source -notmatch "\\Git\\usr\\bin\\tar\.exe$") { return $source }
  }

  throw "Windows tar.exe was not found. Windows 10+ should include C:\Windows\System32\tar.exe; Git Bash tar is not supported for this installer."
}

function Expand-TarGzArchive {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  $tarPath = Get-WindowsTarPath
  Write-Host "  Extracting with $tarPath" -ForegroundColor DarkGray
  & $tarPath -xzf $ArchivePath -C $Destination
  if ($LASTEXITCODE -ne 0) {
    throw "tar failed to extract $(Split-Path $ArchivePath -Leaf)."
  }
}

function Install-MediaIoExeFromArchive {
  param(
    [Parameter(Mandatory = $true)][string]$AssetPath,
    [Parameter(Mandatory = $true)][string]$AssetName,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $sourceExe = $AssetPath
  $extractRoot = Join-Path $TempDir "extract"
  $assetNameLower = $AssetName.ToLower()

  if ($assetNameLower.EndsWith(".zip")) {
    Expand-Archive -Path $AssetPath -DestinationPath $extractRoot -Force
    $binFile = Get-ChildItem -Path $extractRoot -Recurse -Filter "mediaio.exe" | Select-Object -First 1
    if ($null -eq $binFile) { throw "Could not find mediaio.exe in $AssetName." }
    $sourceExe = $binFile.FullName
  } elseif ($assetNameLower.EndsWith(".tar.gz") -or $assetNameLower.EndsWith(".tgz")) {
    Expand-TarGzArchive -ArchivePath $AssetPath -Destination $extractRoot
    $binFile = Get-ChildItem -Path $extractRoot -Recurse -Filter "mediaio.exe" | Select-Object -First 1
    if ($null -eq $binFile) { throw "Could not find mediaio.exe in $AssetName." }
    $sourceExe = $binFile.FullName
  }

  if (!(Test-Path $MediaIoInstallDir)) {
    New-Item -ItemType Directory -Path $MediaIoInstallDir -Force | Out-Null
  }

  $destBin = Join-Path $MediaIoInstallDir "mediaio.exe"
  $stagedBin = Join-Path $MediaIoInstallDir ".mediaio.tmp-$PID.exe"
  Copy-Item -LiteralPath $sourceExe -Destination $stagedBin -Force
  Move-Item -LiteralPath $stagedBin -Destination $destBin -Force
  Add-DirectoryToUserPath -Directory $MediaIoInstallDir
}

function Install-MediaIoCliFromNpmPackage {
  $npmInstallOutput = ""
  try {
    $npmInstallOutput = (& cmd /c "npm install -g $MediaIoPackageName" 2>&1 | Out-String)
  } catch {
    $npmInstallOutput = $_.Exception.Message
  }

  if ($LASTEXITCODE -ne 0) {
    throw "npm install -g $MediaIoPackageName failed. $npmInstallOutput"
  }

  $npmBinDir = Get-NpmGlobalBinDir
  if (-not [string]::IsNullOrWhiteSpace($npmBinDir)) {
    Add-DirectoryToUserPath -Directory $npmBinDir
  }
}

function Resolve-MediaIoLatestVersion {
  if ($script:MediaIoVersion -ne "latest") { return }

  $latestApiUrl = "https://api.github.com/repos/$MediaIoReleaseRepo/releases/latest"
  try {
    $latestRelease = Invoke-RestMethod -Uri $latestApiUrl -UseBasicParsing -ErrorAction Stop
    $tag = [string]$latestRelease.tag_name
    if (-not [string]::IsNullOrWhiteSpace($tag)) {
      $script:MediaIoVersion = $tag
      Write-Host "  Resolved latest Media.io CLI release to $script:MediaIoVersion" -ForegroundColor DarkGray
      return
    }
  } catch {
    Add-Warning "Could not resolve latest Media.io CLI version from GitHub releases API: $($_.Exception.Message)"
  }

  throw "Could not determine the latest Media.io CLI release version. Set MEDIAIO_VERSION explicitly."
}

function Get-MediaIoArchiveName {
  if ($env:MEDIAIO_ARCHIVE_NAME) { return $env:MEDIAIO_ARCHIVE_NAME }
  $arch = Get-MediaIoArch
  $releaseVersion = $script:MediaIoVersion
  if ($releaseVersion.StartsWith("v")) {
    $releaseVersion = $releaseVersion.Substring(1)
  }
  return "mediaio_${releaseVersion}_windows_${arch}.tar.gz"
}

function Assert-MediaIoChecksumIfAvailable {
  param(
    [Parameter(Mandatory = $true)][string]$AssetPath,
    [Parameter(Mandatory = $true)][string]$AssetName,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $checksumUrl = $env:MEDIAIO_CHECKSUM_URL
  if ([string]::IsNullOrWhiteSpace($checksumUrl)) {
    if ([string]::IsNullOrWhiteSpace($env:MEDIAIO_BINARY_URL)) {
      $checksumUrl = "$MediaIoReleaseBaseUrl/$(Get-MediaIoReleaseTag)/checksums.txt"
    } else {
      Add-Warning "MEDIAIO_BINARY_URL is set without MEDIAIO_CHECKSUM_URL, so checksum verification is skipped."
      return
    }
  }

  $checksumPath = Join-Path $TempDir "checksums.txt"
  try {
    Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath -UseBasicParsing -ErrorAction Stop
  } catch {
    Add-Warning "Could not download checksums.txt from $checksumUrl, so fallback binary checksum verification is skipped."
    return
  }

  $expectedLine = Get-Content -LiteralPath $checksumPath | Where-Object {
    $_ -match "^[0-9A-Fa-f]{64}[ ]+[*]?$([regex]::Escape($AssetName))$"
  } | Select-Object -First 1

  if (-not $expectedLine) {
    Add-Warning "$AssetName is missing from checksums.txt, so fallback binary checksum verification is skipped."
    return
  }

  $expected = ($expectedLine -split '\s+')[0].ToLowerInvariant()
  $actual = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "SHA256 checksum mismatch for $AssetName. Expected $expected, got $actual."
  }
  Write-Host "  OK: SHA256 checksum verified for $AssetName" -ForegroundColor Green
}

function Install-MediaIoCliFromRelease {
  Resolve-MediaIoLatestVersion

  $archiveName = Get-MediaIoArchiveName
  $downloadUrl = $env:MEDIAIO_BINARY_URL
  if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
    $downloadUrl = "$MediaIoReleaseBaseUrl/$(Get-MediaIoReleaseTag)/$archiveName"
  }

  if (!(Test-Path $MediaIoInstallDir)) {
    New-Item -ItemType Directory -Path $MediaIoInstallDir -Force | Out-Null
  }

  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "mediaio-install-$PID"
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

  try {
    $assetName = Split-Path ([System.Uri]$downloadUrl).AbsolutePath -Leaf
    if ([string]::IsNullOrWhiteSpace($assetName)) { $assetName = $archiveName }
    $assetPath = Join-Path $tmpDir $assetName

    Write-Host "  Downloading Media.io CLI from $downloadUrl" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $downloadUrl -OutFile $assetPath -UseBasicParsing
    Assert-MediaIoChecksumIfAvailable -AssetPath $assetPath -AssetName $assetName -TempDir $tmpDir

    $sourceExe = $assetPath
    $extractRoot = Join-Path $tmpDir "extract"
    if ($assetName.ToLower().EndsWith(".zip")) {
      Expand-Archive -Path $assetPath -DestinationPath $extractRoot -Force
      $binFile = Get-ChildItem -Path $extractRoot -Recurse -Filter "mediaio.exe" | Select-Object -First 1
      if ($null -eq $binFile) { throw "Could not find mediaio.exe in $assetName." }
      $sourceExe = $binFile.FullName
    } elseif ($assetName.ToLower().EndsWith(".tar.gz") -or $assetName.ToLower().EndsWith(".tgz")) {
      Expand-TarGzArchive -ArchivePath $assetPath -Destination $extractRoot
      $binFile = Get-ChildItem -Path $extractRoot -Recurse -Filter "mediaio.exe" | Select-Object -First 1
      if ($null -eq $binFile) { throw "Could not find mediaio.exe in $assetName." }
      $sourceExe = $binFile.FullName
    }

    $destBin = Join-Path $MediaIoInstallDir "mediaio.exe"
    $stagedBin = Join-Path $MediaIoInstallDir ".mediaio.tmp-$PID.exe"
    Copy-Item -LiteralPath $sourceExe -Destination $stagedBin -Force
    Move-Item -LiteralPath $stagedBin -Destination $destBin -Force
    Add-DirectoryToUserPath -Directory $MediaIoInstallDir
  } finally {
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-MediaIoSkillSourceCandidates {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($MediaIoSkillSource)) {
    $candidates.Add($MediaIoSkillSource)
  }
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $candidates.Add((Join-Path $PSScriptRoot "skills"))
  }
  $localPluginSkills = Join-Path (Get-LocalMediaIoPluginRoot) "skills"
  $candidates.Add($localPluginSkills)

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  return @($candidates | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $seen.Add([System.IO.Path]::GetFullPath($_))
  })
}

function Get-LocalMediaIoSkillDirs {
  foreach ($source in Get-MediaIoSkillSourceCandidates) {
    if (!(Test-Path $source)) { continue }
    $dirs = @(Get-ChildItem -Path $source -Directory -ErrorAction SilentlyContinue | Where-Object {
      Test-Path (Join-Path $_.FullName "SKILL.md")
    })
    if ($dirs.Count -gt 0) {
      $script:ResolvedMediaIoSkillSource = $source
      return $dirs
    }
  }

  return @()
}

function Get-DefaultMediaIoSkillNames {
  return @("mediaio-generate", "mediaio-install")
}

function Get-MediaIoSkillNames {
  $names = @(Get-LocalMediaIoSkillDirs | ForEach-Object { $_.Name })
  if ($names.Count -gt 0) { return $names }

  return @(Get-DefaultMediaIoSkillNames)
}

function Test-MediaIoSkillSetInBase {
  param([Parameter(Mandatory = $true)][string]$BaseDir)

  foreach ($skillName in @(Get-MediaIoSkillNames)) {
    if (-not (Test-Path (Join-Path $BaseDir "$skillName\SKILL.md"))) {
      return $false
    }
  }
  return $true
}

function Test-ClaudePluginProvidedSkillsPresent {
  $namespaceRoot = Join-Path $HOME ".claude\plugins\cache\media-io\media-io"
  if (-not (Test-Path $namespaceRoot)) { return $false }

  $candidateRoots = @($namespaceRoot)
  $candidateRoots += @(
    Get-ChildItem -LiteralPath $namespaceRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object -Property LastWriteTime -Descending |
      ForEach-Object { $_.FullName }
  )

  foreach ($root in @($candidateRoots | Select-Object -Unique)) {
    if (Test-MediaIoSkillSetInBase -BaseDir (Join-Path $root "skills")) {
      return $true
    }
  }

  return $false
}

function Test-CodexPluginProvidedSkillsPresent {
  param([Parameter(Mandatory = $true)][string]$MarketplaceName)

  $namespaceRoot = Join-Path $HOME ".codex\plugins\cache\$MarketplaceName\$MediaIoCodexPluginName"
  if (-not (Test-Path $namespaceRoot)) { return $false }

  $candidateRoots = @($namespaceRoot)
  $candidateRoots += @(
    Get-ChildItem -LiteralPath $namespaceRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object -Property LastWriteTime -Descending |
      ForEach-Object { $_.FullName }
  )

  foreach ($root in @($candidateRoots | Select-Object -Unique)) {
    if (Test-MediaIoSkillSetInBase -BaseDir (Join-Path $root "skills")) {
      return $true
    }
  }

  return $false
}

function Get-MediaIoSkillTargetBases {
  $targets = @()
  if ($script:CodexAvailable -and -not $script:CodexPluginReady) {
    $targets += [pscustomobject]@{ Agent = "codex"; BaseDir = (Join-Path $HOME ".codex\skills") }
  }
  if ($script:ClaudeAvailable -and -not $script:ClaudePluginReady) {
    $targets += [pscustomobject]@{ Agent = "claude-code"; BaseDir = (Join-Path $HOME ".claude\skills") }
  }
  return @($targets)
}

function Test-MediaIoSkillsInstalled {
  $requiredPaths = @()
  $targets = @(Get-MediaIoSkillTargetBases)
  if ($targets.Count -eq 0) {
    Add-Warning "Neither Codex nor Claude Code is available; no Media.io skills target was verified."
    return
  }

  $skillNames = @(Get-MediaIoSkillNames)
  if ($skillNames.Count -eq 0) {
    throw "No Media.io skill names were found in the local skills directory."
  }
  foreach ($target in $targets) {
    foreach ($skillName in $skillNames) {
      $requiredPaths += Join-Path $target.BaseDir "$skillName\SKILL.md"
    }
  }

  $missing = @()
  foreach ($path in $requiredPaths) {
    if (-not (Test-Path $path)) { $missing += $path }
  }

  if ($missing.Count -gt 0) {
    throw "Missing skill file(s): $($missing -join ', ')"
  }
}

function Get-MediaIoSkillAgentArgs {
  $agents = @()
  foreach ($target in @(Get-MediaIoSkillTargetBases)) {
    $agents += "-a $($target.Agent)"
  }

  if ($agents.Count -eq 0) {
    throw "Neither Codex nor Claude Code is available; cannot run targeted npx skills fallback."
  }

  return ($agents -join " ")
}

function Invoke-MediaIoSkillInstall {
  Invoke-CheckedStep "Install Media.io skills" {
    Ensure-NodeAndNpm
    $agentArgs = Get-MediaIoSkillAgentArgs
    Write-Host "  Installing Media.io skills with npx" -ForegroundColor DarkGray
    & cmd /c "npx --yes skills add $MediaIoSkillRepo -g $agentArgs --skill * -y"
  } {
    Test-MediaIoSkillsInstalled
  } -SuccessMessage "Media.io skills are installed"
}

function Test-MediaIoPluginInstalled {
  $installed = $false

  if ($script:ClaudePluginReady) {
    $installed = $true
  }

  if ($script:CodexPluginReady) {
    $installed = $true
  }

  return $installed
}

function Test-MediaIoIntegrationInstalled {
  if (Test-MediaIoPluginInstalled) { return }
  Test-MediaIoSkillsInstalled
}

function Invoke-MediaIoAuth {
  Write-Step "Authenticate Media.io"

  try {
    $raw = (& cmd /c "mediaio whoami" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  OK: already signed in" -ForegroundColor Green
      return
    }

    Write-Host "  Run `mediaio whoami` first." -ForegroundColor Cyan
    Write-Host "  If not signed in, run `mediaio auth login` and complete sign-in in the browser it opens." -ForegroundColor Cyan
  } catch {
    Write-Host "  Run `mediaio whoami` first." -ForegroundColor Cyan
    Write-Host "  If not signed in, run `mediaio auth login` and complete sign-in in the browser it opens." -ForegroundColor Cyan
  }
}

function Remove-DirectMediaIoSkillsIfPresent {
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($skillName in @(Get-MediaIoSkillNames)) {
    $paths.Add((Join-Path $HOME ".codex\skills\$skillName"))
    $paths.Add((Join-Path $HOME ".claude\skills\$skillName"))
  }

  foreach ($path in @($paths | Select-Object -Unique)) {
    if (Test-Path $path) {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      Write-Host "  Removed duplicate direct skill: $path" -ForegroundColor DarkGray
    }
  }
}

function Get-CodexMarketplaceCheckoutRoot {
  return Join-Path $env:USERPROFILE ".codex\.tmp\marketplaces\$MediaIoCodexMarketplaceName"
}

function Get-PersonalMarketplacePath {
  return Join-Path $env:USERPROFILE ".agents\plugins\marketplace.json"
}

function Get-LocalMediaIoPluginRoot {
  return Join-Path $env:USERPROFILE "plugins\media-io"
}

function Get-MediaIoPluginSourceCandidates {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($env:MEDIAIO_PLUGIN_SOURCE) {
    $candidates.Add($env:MEDIAIO_PLUGIN_SOURCE)
  }
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $candidates.Add($PSScriptRoot)
  }
  $candidates.Add((Get-CodexMarketplaceCheckoutRoot))
  $candidates.Add((Get-LocalMediaIoPluginRoot))

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  return @($candidates | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $seen.Add([System.IO.Path]::GetFullPath($_))
  })
}

function Get-PersonalMarketplaceName {
  $marketplacePath = Get-PersonalMarketplacePath
  if (Test-Path $marketplacePath) {
    try {
      $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
      if ($payload -and -not [string]::IsNullOrWhiteSpace([string]$payload.name)) {
        return [string]$payload.name
      }
    } catch {
      Add-Warning "Personal marketplace file exists but could not be parsed cleanly. It will be recreated."
    }
  }

  return "personal"
}

function Format-DisplayNameFromName {
  param([Parameter(Mandatory = $true)][string]$Name)

  $parts = @($Name -split "[-_]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($parts.Count -eq 0) { return "Personal" }

  return (($parts | ForEach-Object {
    if ($_.Length -le 1) {
      $_.ToUpper()
    } else {
      $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower()
    }
  }) -join " ")
}

function Write-JsonNoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$InputObject
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  $json = ($InputObject | ConvertTo-Json -Depth 10) + [Environment]::NewLine
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Test-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)][object]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name
  )

  return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Set-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)][object]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][object]$Value
  )

  if (Test-ObjectProperty -InputObject $InputObject -Name $Name) {
    $InputObject.$Name = $Value
  } else {
    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Initialize-LocalMediaIoPluginRoot {
  $pluginRoot = Get-LocalMediaIoPluginRoot
  $sourceRoot = $null

  foreach ($candidate in Get-MediaIoPluginSourceCandidates) {
    if (Test-Path (Join-Path $candidate ".codex-plugin\plugin.json")) {
      $sourceRoot = $candidate
      break
    }
  }

  $tmpDir = $null
  if ($null -eq $sourceRoot) {
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "mediaio-plugin-$PID"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $archivePath = Join-Path $tmpDir "mediaio-plugin.zip"
    Write-Host "  Downloading Media.io plugin source from $MediaIoPluginArchiveUrl" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $MediaIoPluginArchiveUrl -OutFile $archivePath -UseBasicParsing
    Expand-Archive -Path $archivePath -DestinationPath $tmpDir -Force
    foreach ($candidate in Get-ChildItem -Path $tmpDir -Directory -Recurse -ErrorAction SilentlyContinue) {
      if (Test-Path (Join-Path $candidate.FullName ".codex-plugin\plugin.json")) {
        $sourceRoot = $candidate.FullName
        break
      }
    }
  }

  if ($null -eq $sourceRoot) {
    throw "Media.io plugin source with .codex-plugin\plugin.json was not found."
  }

  New-Item -ItemType Directory -Force -Path $pluginRoot | Out-Null
  try {
    $sourceManifest = Join-Path $sourceRoot ".codex-plugin\plugin.json"
    if (-not (Test-Path $sourceManifest)) {
      throw "Media.io plugin source is missing .codex-plugin\plugin.json."
    }

    $sourceFullPath = [System.IO.Path]::GetFullPath($sourceRoot).TrimEnd('\', '/')
    $pluginFullPath = [System.IO.Path]::GetFullPath($pluginRoot).TrimEnd('\', '/')
    if (-not [string]::Equals($sourceFullPath, $pluginFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      Get-ChildItem -LiteralPath $sourceRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $pluginRoot -Recurse -Force
      }
    }

    Copy-Item -LiteralPath $sourceManifest -Destination (Join-Path $pluginRoot "plugin.json") -Force
    return $pluginRoot
  } finally {
    if ($tmpDir -and (Test-Path $tmpDir)) {
      Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Initialize-PersonalMarketplaceFallback {
  $marketplacePath = Get-PersonalMarketplacePath
  $marketplaceName = Get-PersonalMarketplaceName
  $displayName = Format-DisplayNameFromName -Name $marketplaceName
  $payload = $null

  if (Test-Path $marketplacePath) {
    try {
      $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
    } catch {
      Add-Warning "Personal marketplace file exists but could not be parsed cleanly. It will be recreated."
      $payload = $null
    }
  }

  if (-not $payload) {
    $payload = [ordered]@{
      name = $marketplaceName
      interface = [ordered]@{
        displayName = $displayName
      }
      plugins = @()
    }
  }

  if (-not (Test-ObjectProperty -InputObject $payload -Name "name") -or
      [string]::IsNullOrWhiteSpace([string]$payload.name)) {
    Set-ObjectProperty -InputObject $payload -Name "name" -Value $marketplaceName
  }
  if (-not (Test-ObjectProperty -InputObject $payload -Name "interface") -or -not $payload.interface) {
    Set-ObjectProperty -InputObject $payload -Name "interface" -Value ([ordered]@{})
  }
  if (-not (Test-ObjectProperty -InputObject $payload.interface -Name "displayName") -or
      [string]::IsNullOrWhiteSpace([string]$payload.interface.displayName)) {
    Set-ObjectProperty -InputObject $payload.interface -Name "displayName" -Value $displayName
  }
  if (-not (Test-ObjectProperty -InputObject $payload -Name "plugins") -or -not $payload.plugins) {
    Set-ObjectProperty -InputObject $payload -Name "plugins" -Value ([object[]]@())
  }

  $newEntry = [ordered]@{
    name = $MediaIoCodexPluginName
    source = [ordered]@{
      source = "local"
      path = "./plugins/media-io"
    }
    policy = [ordered]@{
      installation = "AVAILABLE"
      authentication = "ON_INSTALL"
    }
    category = "Design"
  }

  $plugins = @()
  foreach ($entry in @($payload.plugins)) {
    if ($null -eq $entry) { continue }
    if ((Test-ObjectProperty -InputObject $entry -Name "name") -and $entry.name -eq $MediaIoCodexPluginName) { continue }
    $plugins += $entry
  }
  $plugins += $newEntry
  Set-ObjectProperty -InputObject $payload -Name "plugins" -Value ([object[]]$plugins)

  Write-JsonNoBom -Path $marketplacePath -InputObject $payload
  Initialize-LocalMediaIoPluginRoot | Out-Null
  return $marketplaceName
}

function Use-CodexPersonalMarketplaceFallback {
  param([Parameter(Mandatory = $true)][string]$Reason)

  if (-not $script:UseCodexPersonalMarketplaceFallback) {
    Add-Warning "Using Codex personal marketplace fallback: $Reason"
    $script:CodexPersonalMarketplaceFallbackReason = $Reason
  } else {
    Write-Host "  Codex personal marketplace fallback still active: $Reason" -ForegroundColor DarkGray
    if ([string]::IsNullOrWhiteSpace([string]$script:CodexPersonalMarketplaceFallbackReason)) {
      $script:CodexPersonalMarketplaceFallbackReason = $Reason
    }
  }

  $script:UseCodexPersonalMarketplaceFallback = $true
}

function Get-CodexAvailablePluginIds {
  $raw = (& cmd /c "codex plugin list --json --available" | Out-String)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

  $parsed = $raw | ConvertFrom-Json
  return @($parsed.available | ForEach-Object { $_.pluginId })
}

function Get-CodexInstalledPluginIds {
  $raw = (& cmd /c "codex plugin list --json --available" | Out-String)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

  $parsed = $raw | ConvertFrom-Json
  return @($parsed.installed | ForEach-Object { $_.pluginId })
}

function Get-ClaudeMarketplaceIds {
  $raw = (& cmd /c "claude plugin marketplace list --json" | Out-String)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

  $parsed = $raw | ConvertFrom-Json
  return @($parsed | ForEach-Object { $_.name })
}

Write-Host "Media.io setup script" -ForegroundColor White
Write-Host "Script version: $script:ScriptVersion" -ForegroundColor DarkGray
Write-Host "This script installs the Media.io plugin, CLI, and skills. The CLI prefers npm and falls back to a release archive; direct skills are installed with npx only when plugin install is unavailable." -ForegroundColor DarkGray

Invoke-OptionalHostDetection "Preflight: locate claude" "claude" {
  param([bool]$Available)
  $script:ClaudeAvailable = $Available
}

Invoke-OptionalHostDetection "Preflight: locate codex" "codex" {
  param([bool]$Available)
  $script:CodexAvailable = $Available
}

Invoke-OptionalFallbackStep "Install Media.io CLI" {
  Ensure-NodeAndNpm
  Install-MediaIoCliFromNpmPackage
} {
  Install-MediaIoCliFromRelease
} {
  & cmd /c "mediaio version"
} -SuccessMessage "Media.io CLI is installed"

Invoke-CheckedStep "Run Media.io doctor" {
  & cmd /c "mediaio doctor"
} -SuccessMessage "local Media.io checks passed"

if ($script:ClaudeAvailable) {
  Invoke-CheckedStep "Add Media.io marketplace" {
    & cmd /c "claude plugin marketplace add $MediaIoMarketplaceSource"
  } -SuccessMessage "marketplace is registered"

  Invoke-CheckedStep "Refresh Media.io marketplace" {
    & cmd /c "claude plugin marketplace update media-io"
  } -SuccessMessage "marketplace is refreshed"

  Invoke-CheckedStep "Verify marketplace visibility" {
    $availableIds = Get-ClaudeMarketplaceIds
    if ($availableIds -contains "media-io") {
      Write-Host "  OK: Claude Code can see media-io in the configured marketplaces" -ForegroundColor Green
    } else {
      Add-Warning "Claude Code does not surface media-io from the configured marketplaces on this build."
    }
  } -SuccessMessage "Marketplace lookup finished"

  Invoke-CheckedStep "Install Claude Code plugin" {
    & cmd /c "claude plugin install $MediaIoClaudePluginId -s user -y"
    if ($LASTEXITCODE -ne 0) {
      throw "claude plugin install $MediaIoClaudePluginId failed."
    }
    $script:ResolvedClaudeMarketplaceName = "media-io"
    $script:ClaudePluginInstalled = $true
  } -SuccessMessage "Claude Code plugin install completed"

  Invoke-CheckedStep "Verify Claude Code plugin install" {
    if ([string]::IsNullOrWhiteSpace([string]$script:ResolvedClaudeMarketplaceName)) {
      throw "Claude marketplace name was not recorded."
    }

    $raw = (& cmd /c "claude plugin list --json" | Out-String)
    $parsed = $raw | ConvertFrom-Json
    $ids = @($parsed | ForEach-Object { $_.id })
    if ($ids -notcontains $MediaIoClaudePluginId) {
      Add-Warning "Claude Code does not currently list $MediaIoClaudePluginId in the installed plugin list."
    } else {
      Write-Host "  OK: Claude Code lists $MediaIoClaudePluginId as installed" -ForegroundColor Green
    }

    if (Test-ClaudePluginProvidedSkillsPresent) {
      Write-Host "  OK: Claude Code plugin-provided skills are present" -ForegroundColor Green
      $script:ClaudePluginReady = $true
    } else {
      Add-Warning "Claude Code plugin-provided skills are missing; direct skills install will be attempted with npx."
    }
  } -SuccessMessage "Claude Code plugin install verification completed"
}

if ($script:CodexAvailable) {
  if (-not (Invoke-SoftStep "Add Media.io Codex marketplace" {
    $output = (& cmd /c "codex plugin marketplace add $MediaIoMarketplaceSource" 2>&1 | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($output)) {
      Write-Host $output
    }
    if ($LASTEXITCODE -ne 0) {
      $script:CodexMarketplaceAddFailure = $output
      throw "codex plugin marketplace add exited with code $LASTEXITCODE."
    }
  } -SuccessMessage "Codex marketplace is registered")) {
    $reason = "Codex marketplace add failed for '$MediaIoMarketplaceSource'."
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CodexMarketplaceAddFailure)) {
      $reason = "$reason $script:CodexMarketplaceAddFailure"
    }
    Use-CodexPersonalMarketplaceFallback $reason
  }

  if (-not $script:UseCodexPersonalMarketplaceFallback) {
    if (-not (Invoke-SoftStep "Refresh Media.io Codex marketplace" {
      & cmd /c "codex plugin marketplace upgrade $MediaIoCodexMarketplaceName"
    } -SuccessMessage "Codex marketplace is refreshed")) {
      Use-CodexPersonalMarketplaceFallback "Codex marketplace refresh failed for '$MediaIoCodexMarketplaceName'."
    }
  }

  if (-not $script:UseCodexPersonalMarketplaceFallback) {
    if (-not (Invoke-SoftStep "Verify Codex marketplace visibility" {
      $expectedId = "$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName"
      $installedIds = Get-CodexInstalledPluginIds
      if ($installedIds -contains $expectedId) {
        Write-Host "  OK: Codex plugin $expectedId is already installed" -ForegroundColor Green
        return
      }

      $availableIds = Get-CodexAvailablePluginIds
      if ($availableIds -contains $expectedId) {
        Write-Host "  OK: Codex can see $expectedId in the git marketplace snapshot" -ForegroundColor Green
      } else {
        throw "Codex does not surface $expectedId from the git marketplace snapshot on this build."
      }
    } -SuccessMessage "Codex marketplace lookup finished")) {
      Use-CodexPersonalMarketplaceFallback "Codex marketplace visibility check failed for '$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName'."
    }
  }

  Invoke-CheckedStep "Install Codex plugin" {
    $installedMarketplaceName = $MediaIoCodexMarketplaceName

    if (-not $script:UseCodexPersonalMarketplaceFallback) {
      & cmd /c "codex plugin add $MediaIoCodexPluginName@$MediaIoCodexMarketplaceName"
      if ($LASTEXITCODE -ne 0) {
        Use-CodexPersonalMarketplaceFallback "Codex git marketplace install failed for '$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName'."
      } else {
        $script:ResolvedCodexMarketplaceName = $MediaIoCodexMarketplaceName
        $script:CodexPluginInstalled = $true
      }
    }

    if ($script:UseCodexPersonalMarketplaceFallback) {
      $installedMarketplaceName = Initialize-PersonalMarketplaceFallback
      if (-not [string]::IsNullOrWhiteSpace([string]$script:CodexPersonalMarketplaceFallbackReason)) {
        Write-Host "  Codex personal marketplace fallback reason: $script:CodexPersonalMarketplaceFallbackReason" -ForegroundColor Yellow
      }
      Write-Host "  Installing through Codex personal marketplace fallback: $MediaIoCodexPluginName@$installedMarketplaceName" -ForegroundColor Yellow
      Write-Host "  Personal marketplace file: $(Get-PersonalMarketplacePath)" -ForegroundColor DarkGray
      & cmd /c "codex plugin add $MediaIoCodexPluginName@$installedMarketplaceName"
      if ($LASTEXITCODE -ne 0) {
        throw "codex plugin add $MediaIoCodexPluginName@$installedMarketplaceName failed."
      }
      $script:ResolvedCodexMarketplaceName = $installedMarketplaceName
      $script:CodexPluginInstalled = $true
    }
  } -SuccessMessage "Codex plugin install completed"

  Invoke-CheckedStep "Verify Codex plugin install" {
    if ([string]::IsNullOrWhiteSpace([string]$script:ResolvedCodexMarketplaceName)) {
      throw "Codex marketplace name was not recorded."
    }

    $expectedId = "$MediaIoCodexPluginName@$($script:ResolvedCodexMarketplaceName)"
    try {
      $installedIds = Get-CodexInstalledPluginIds
      if ($installedIds -notcontains $expectedId) {
        Add-Warning "Codex does not currently list $expectedId in the installed plugin list."
      } else {
        Write-Host "  OK: Codex lists $expectedId as installed" -ForegroundColor Green
      }
      $global:LASTEXITCODE = 0
    } catch {
      Add-Warning "Codex installed plugin list could not be read: $($_.Exception.Message)"
      $global:LASTEXITCODE = 0
    }

    if (Test-CodexPluginProvidedSkillsPresent -MarketplaceName $script:ResolvedCodexMarketplaceName) {
      Write-Host "  OK: Codex plugin-provided skills are present" -ForegroundColor Green
      $script:CodexPluginReady = $true
    } else {
      Add-Warning "Codex plugin-provided skills are missing; direct skills install will be attempted with npx."
    }
  } -SuccessMessage "Codex plugin install verification completed"
}

$skipDirectSkillsInstall = (@(Get-MediaIoSkillTargetBases).Count -eq 0)
if ($skipDirectSkillsInstall) {
  Write-Step "Skip direct Media.io skills install"
  Write-Host "  OK: plugin-provided skills are installed; direct skills install is skipped to avoid duplicate entries" -ForegroundColor Green
} else {
  Invoke-MediaIoSkillInstall | Out-Null
}

Write-Step "Final verification"

try {
  $raw = (& cmd /c "mediaio version" | Out-String)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "mediaio version returned no output."
  }
  Test-MediaIoIntegrationInstalled
  Write-Host "  OK: mediaio version responded and Media.io integration is present" -ForegroundColor Green
  if ($skipDirectSkillsInstall) {
    $skillPaths = New-Object System.Collections.Generic.List[string]
    foreach ($skillName in @(Get-MediaIoSkillNames)) {
      $skillPaths.Add((Join-Path $HOME ".codex\skills\$skillName"))
      $skillPaths.Add((Join-Path $HOME ".claude\skills\$skillName"))
    }
    if (@($skillPaths | Where-Object { Test-Path $_ }).Count -gt 0) {
      Add-Warning "Residual direct Media.io skill directories still exist alongside the plugin install."
    }
  }
} catch {
  Add-Failure "Final verification - $($_.Exception.Message)"
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Setup finished with failures." -ForegroundColor Red
  foreach ($item in $script:Failures) {
    Write-Host "  - $item" -ForegroundColor Red
  }
  if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor Yellow
    foreach ($item in $script:Warnings) {
      Write-Host "  - $item" -ForegroundColor Yellow
    }
  }
  exit 1
}

Write-Host ""
Write-Host "Setup finished successfully." -ForegroundColor Green
if ($script:Warnings.Count -gt 0) {
  Write-Host "Warnings were emitted, but the required files and commands are present." -ForegroundColor Yellow
}
Invoke-MediaIoAuth
