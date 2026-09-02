[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StepIndex = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

$MediaIoPackageName = if ($env:MEDIAIO_NPM_PACKAGE) { $env:MEDIAIO_NPM_PACKAGE } else { "@mediaio/cli" }
$MediaIoInstallDir = if ($env:MEDIAIO_INSTALL_DIR) { $env:MEDIAIO_INSTALL_DIR } else { Join-Path $HOME ".local\bin" }
$MediaIoClaudePluginId = if ($env:MEDIAIO_CLAUDE_PLUGIN_ID) { $env:MEDIAIO_CLAUDE_PLUGIN_ID } else { "media-io@media-io" }
$MediaIoCodexPluginName = if ($env:MEDIAIO_CODEX_PLUGIN_NAME) { $env:MEDIAIO_CODEX_PLUGIN_NAME } else { "media-io" }
$MediaIoCodexMarketplaceName = if ($env:MEDIAIO_CODEX_MARKETPLACE_NAME) { $env:MEDIAIO_CODEX_MARKETPLACE_NAME } else { "media-io" }

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
    if ($null -ne $exitCode -and $exitCode -ne 0) {
      throw "Command exited with code $exitCode."
    }

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

function Remove-PathIfPresent {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
    Write-Host "  OK: removed $Path" -ForegroundColor Green
    return $true
  }

  return $false
}

function Get-PersonalMarketplacePath {
  return Join-Path $env:USERPROFILE ".agents\plugins\marketplace.json"
}

function Get-PersonalMarketplaceName {
  $marketplacePath = Get-PersonalMarketplacePath
  if (Test-Path $marketplacePath) {
    try {
      $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
      if ($payload -and
          (Test-ObjectProperty -InputObject $payload -Name "name") -and
          -not [string]::IsNullOrWhiteSpace([string]$payload.name)) {
        return [string]$payload.name
      }
    } catch {
      Add-Warning "Personal marketplace file exists but could not be parsed cleanly."
    }
  }

  return "personal"
}

function Remove-PersonalMarketplaceEntry {
  $marketplacePath = Get-PersonalMarketplacePath
  if (-not (Test-Path $marketplacePath)) { return $false }

  try {
    $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
  } catch {
    Add-Warning "Personal marketplace file exists but could not be parsed cleanly; skipping marketplace entry removal."
    return $false
  }
  if (-not (Test-ObjectProperty -InputObject $payload -Name "plugins") -or -not $payload.plugins) {
    return $false
  }

  $before = @($payload.plugins).Count
  $plugins = @()
  foreach ($entry in @($payload.plugins)) {
    if ($null -eq $entry) { continue }
    if ((Test-ObjectProperty -InputObject $entry -Name "name") -and $entry.name -eq $MediaIoCodexPluginName) {
      continue
    }
    $plugins += $entry
  }

  if ($plugins.Count -eq $before) { return $false }

  if (-not (Test-ObjectProperty -InputObject $payload -Name "name") -or
      [string]::IsNullOrWhiteSpace([string]$payload.name)) {
    Set-ObjectProperty -InputObject $payload -Name "name" -Value "personal"
  }
  if (-not (Test-ObjectProperty -InputObject $payload -Name "interface") -or -not $payload.interface) {
    Set-ObjectProperty -InputObject $payload -Name "interface" -Value ([ordered]@{})
  }
  if (-not (Test-ObjectProperty -InputObject $payload.interface -Name "displayName") -or
      [string]::IsNullOrWhiteSpace([string]$payload.interface.displayName)) {
    Set-ObjectProperty -InputObject $payload.interface -Name "displayName" -Value "Personal"
  }
  Set-ObjectProperty -InputObject $payload -Name "plugins" -Value ([object[]]$plugins)

  Write-JsonNoBom -Path $marketplacePath -InputObject $payload
  return $true
}

function Get-CodexPluginCacheRoots {
  $roots = New-Object System.Collections.Generic.List[string]
  $cacheRoot = Join-Path $env:USERPROFILE ".codex\plugins\cache"
  foreach ($marketplace in @($MediaIoCodexMarketplaceName, (Get-PersonalMarketplaceName), "personal")) {
    if ([string]::IsNullOrWhiteSpace($marketplace)) { continue }
    $roots.Add((Join-Path $cacheRoot "$marketplace\$MediaIoCodexPluginName"))
  }

  if (Test-Path $cacheRoot) {
    foreach ($candidate in Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue) {
      $roots.Add((Join-Path $candidate.FullName $MediaIoCodexPluginName))
    }
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  return @($roots | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $seen.Add([System.IO.Path]::GetFullPath($_))
  })
}

function Get-CodexMarketplaceRoots {
  $roots = New-Object System.Collections.Generic.List[string]
  $tmpMarketplaceRoot = Join-Path $env:USERPROFILE ".codex\.tmp\marketplaces"
  foreach ($marketplace in @($MediaIoCodexMarketplaceName, "media-io")) {
    if ([string]::IsNullOrWhiteSpace($marketplace)) { continue }
    $roots.Add((Join-Path $tmpMarketplaceRoot $marketplace))
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  return @($roots | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $seen.Add([System.IO.Path]::GetFullPath($_))
  })
}

function Get-ClaudePluginCacheRoots {
  $roots = New-Object System.Collections.Generic.List[string]
  $cacheRoot = Join-Path $env:USERPROFILE ".claude\plugins\cache"
  $roots.Add((Join-Path $cacheRoot "media-io\media-io"))

  if (Test-Path $cacheRoot) {
    foreach ($candidate in Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue) {
      $roots.Add((Join-Path $candidate.FullName "media-io"))
    }
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  return @($roots | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $seen.Add([System.IO.Path]::GetFullPath($_))
  })
}

function Remove-CodexPluginCaches {
  foreach ($cacheRoot in Get-CodexPluginCacheRoots) {
    [void](Remove-PathIfPresent -Path $cacheRoot)
  }
}

function Remove-CodexMarketplaces {
  if (Test-CommandAvailable "codex") {
    foreach ($marketplace in @($MediaIoCodexMarketplaceName, "media-io") | Select-Object -Unique) {
      if ([string]::IsNullOrWhiteSpace($marketplace)) { continue }
      try {
        $global:LASTEXITCODE = 0
        $raw = (& cmd /c "codex plugin marketplace remove $marketplace" 2>&1 | Out-String)
      } catch {
        $raw = $_.Exception.Message
      }
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK: codex plugin marketplace remove $marketplace" -ForegroundColor Green
      } elseif ($raw -match "not configured or installed") {
        Add-Warning "codex marketplace $marketplace was already absent."
        $global:LASTEXITCODE = 0
      } else {
        Add-Warning "codex plugin marketplace remove $marketplace returned exit code $LASTEXITCODE. $raw"
        $global:LASTEXITCODE = 0
      }
    }
  } else {
    Add-Warning "codex is not available; removing Codex marketplace snapshots directly."
  }

  foreach ($marketplaceRoot in Get-CodexMarketplaceRoots) {
    [void](Remove-PathIfPresent -Path $marketplaceRoot)
  }
}

function Remove-ClaudePluginCaches {
  foreach ($cacheRoot in Get-ClaudePluginCacheRoots) {
    [void](Remove-PathIfPresent -Path $cacheRoot)
  }
}

function Test-CodexPluginCachePresent {
  foreach ($cacheRoot in Get-CodexPluginCacheRoots) {
    if (Test-Path $cacheRoot) { return $true }
  }
  return $false
}

function Test-CodexMarketplacePresent {
  foreach ($marketplaceRoot in Get-CodexMarketplaceRoots) {
    if (Test-Path $marketplaceRoot) { return $true }
  }
  return $false
}

function Test-ClaudePluginCachePresent {
  foreach ($cacheRoot in Get-ClaudePluginCacheRoots) {
    if (Test-Path $cacheRoot) { return $true }
  }
  return $false
}

function Remove-MediaIoCli {
  $removedSomething = $false

  if (Test-CommandAvailable "npm") {
    $raw = (& cmd /c "npm uninstall -g $MediaIoPackageName" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  OK: npm uninstall -g $MediaIoPackageName" -ForegroundColor Green
      $removedSomething = $true
    } else {
      Add-Warning "npm uninstall -g $MediaIoPackageName returned exit code $LASTEXITCODE. $raw"
    }
  } else {
    Add-Warning "npm is not available; skipping npm global package removal."
  }

  $releaseExe = Join-Path $MediaIoInstallDir "mediaio.exe"
  if (Remove-PathIfPresent -Path $releaseExe) {
    $removedSomething = $true
  }

  if (-not $removedSomething) {
    Add-Warning "No Media.io CLI installation was removed from npm or $releaseExe."
  }
}

function Remove-CodexPlugin {
  $marketplaceName = Get-PersonalMarketplaceName
  $targets = @(
    "$MediaIoCodexPluginName@$marketplaceName",
    "$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName",
    "$MediaIoCodexPluginName@personal"
  )

  $removedByCli = $false
  if (Test-CommandAvailable "codex") {
    foreach ($target in @($targets | Select-Object -Unique)) {
      $raw = (& cmd /c "codex plugin remove $target" 2>&1 | Out-String)
      if ($LASTEXITCODE -eq 0) {
        $removedByCli = $true
        Write-Host "  OK: codex plugin remove $target" -ForegroundColor Green
        continue
      }
      Add-Warning "codex plugin remove $target returned exit code $LASTEXITCODE. $raw"
    }
  } else {
    Add-Warning "codex is not available; removing Codex plugin files directly."
  }

  if (Remove-PersonalMarketplaceEntry) {
    Write-Host "  OK: removed $MediaIoCodexPluginName from personal marketplace file" -ForegroundColor Green
  }

  [void](Remove-PathIfPresent -Path (Join-Path $env:USERPROFILE "plugins\media-io"))
  Remove-CodexMarketplaces
  Remove-CodexPluginCaches

  if (-not $removedByCli -and (Test-CodexPluginCachePresent)) {
    throw "Codex plugin cache is still present."
  }
}

function Remove-ClaudePlugin {
  $removedByCli = $false
  if (Test-CommandAvailable "claude") {
    $raw = (& cmd /c "claude plugin uninstall $MediaIoClaudePluginId -s user -y" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
      $removedByCli = $true
      Write-Host "  OK: claude plugin uninstall $MediaIoClaudePluginId -s user -y" -ForegroundColor Green
    } else {
      Add-Warning "claude plugin uninstall $MediaIoClaudePluginId returned exit code $LASTEXITCODE. $raw"
    }
  } else {
    Add-Warning "claude is not available; removing Claude Code plugin cache directly."
  }

  Remove-ClaudePluginCaches

  if (-not $removedByCli -and (Test-ClaudePluginCachePresent)) {
    throw "Claude Code plugin cache is still present."
  }
}

function Get-MediaIoSkillRoots {
  return @(
    (Join-Path $env:USERPROFILE ".codex\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".codex\skills\mediaio-install"),
    (Join-Path $env:USERPROFILE ".claude\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".claude\skills\mediaio-install"),
    (Join-Path $env:USERPROFILE ".agents\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".agents\skills\mediaio-install")
  )
}

function Remove-SkillDirectories {
  foreach ($skillRoot in Get-MediaIoSkillRoots) {
    [void](Remove-PathIfPresent -Path $skillRoot)
  }
}

function Invoke-MediaIoSkillRemove {
  if (Test-CommandAvailable "npx") {
    try {
      $global:LASTEXITCODE = 0
      $raw = (& cmd /c "npx --yes skills remove mediaio-generate mediaio-install -g -a codex -a claude-code -y" 2>&1 | Out-String)
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK: npx skills remove mediaio-generate mediaio-install" -ForegroundColor Green
      } else {
        Add-Warning "npx skills remove returned exit code $LASTEXITCODE. Falling back to direct directory removal. $raw"
      }
    } catch {
      Add-Warning "npx skills remove failed. Falling back to direct directory removal. $($_.Exception.Message)"
    } finally {
      $global:LASTEXITCODE = 0
    }
  } else {
    Add-Warning "npx is not available; removing Media.io skill directories directly."
  }

  Remove-SkillDirectories
}

function Test-SkillDirectoriesAbsent {
  foreach ($skillRoot in Get-MediaIoSkillRoots) {
    if (Test-Path $skillRoot) { return $false }
  }
  return $true
}

function Test-PersonalMarketplaceEntryAbsent {
  $marketplacePath = Get-PersonalMarketplacePath
  if (-not (Test-Path $marketplacePath)) { return $true }

  try {
    $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
  } catch {
    Add-Warning "Personal marketplace file exists but could not be parsed cleanly; treating the Media.io entry as absent."
    return $true
  }
  if (-not (Test-ObjectProperty -InputObject $payload -Name "plugins") -or -not $payload.plugins) {
    return $true
  }

  foreach ($entry in @($payload.plugins)) {
    if ($null -eq $entry) { continue }
    if ((Test-ObjectProperty -InputObject $entry -Name "name") -and $entry.name -eq $MediaIoCodexPluginName) {
      return $false
    }
  }

  return $true
}

Write-Host "Media.io uninstall script" -ForegroundColor White
Write-Host "This script removes the Media.io CLI, Claude Code plugin, Codex plugin, and Media.io skills with checks after each step." -ForegroundColor DarkGray

Invoke-CheckedStep "Uninstall Media.io CLI" {
  Remove-MediaIoCli
} -Verify {
  $releaseExe = Join-Path $MediaIoInstallDir "mediaio.exe"
  if (Test-Path $releaseExe) {
    throw "release-installed mediaio.exe is still present at $releaseExe."
  }
} -SuccessMessage "Media.io CLI removal attempted"

Invoke-CheckedStep "Remove Claude Code plugin" {
  Remove-ClaudePlugin
} -Verify {
  if (Test-ClaudePluginCachePresent) {
    throw "Claude Code plugin cache is still present."
  }
} -SuccessMessage "Claude Code plugin removed"

Invoke-CheckedStep "Remove Codex plugin" {
  Remove-CodexPlugin
} -Verify {
  if (Test-CodexPluginCachePresent) {
    throw "Codex plugin cache is still present."
  }
  if (Test-CodexMarketplacePresent) {
    throw "Codex marketplace snapshot is still present."
  }
  if (-not (Test-PersonalMarketplaceEntryAbsent)) {
    throw "$MediaIoCodexPluginName is still listed in the personal marketplace file."
  }
} -SuccessMessage "Codex plugin removed"

Invoke-CheckedStep "Remove Media.io skills" {
  Invoke-MediaIoSkillRemove
} -Verify {
  if (-not (Test-SkillDirectoriesAbsent)) {
    throw "Some Media.io skill directories are still present."
  }
} -SuccessMessage "Media.io skills removed"

Write-Step "Final verification"

try {
  $releaseExe = Join-Path $MediaIoInstallDir "mediaio.exe"
  if (Test-Path $releaseExe) {
    throw "release-installed mediaio.exe is still present at $releaseExe."
  }
  if (Test-CodexPluginCachePresent) {
    throw "Codex plugin cache is still present."
  }
  if (Test-CodexMarketplacePresent) {
    throw "Codex marketplace snapshot is still present."
  }
  if (Test-ClaudePluginCachePresent) {
    throw "Claude Code plugin cache is still present."
  }
  if (-not (Test-SkillDirectoriesAbsent)) {
    throw "Some Media.io skill directories are still present."
  }
  if (-not (Test-PersonalMarketplaceEntryAbsent)) {
    throw "$MediaIoCodexPluginName is still present in the personal marketplace file."
  }
  Write-Host "  OK: requested Media.io uninstall targets are absent" -ForegroundColor Green
} catch {
  Add-Failure "Final verification - $($_.Exception.Message)"
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Uninstall finished with failures." -ForegroundColor Red
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
Write-Host "Uninstall finished successfully." -ForegroundColor Green
if ($script:Warnings.Count -gt 0) {
  Write-Host "Warnings were emitted, but the requested removal targets are gone." -ForegroundColor Yellow
}
