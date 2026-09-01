[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StepIndex = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

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

    return $true
  } catch {
    Add-Failure "$Label - $($_.Exception.Message)"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
      Write-Host $_.InvocationInfo.PositionMessage.TrimEnd() -ForegroundColor DarkRed
    }
    if ($_.ScriptStackTrace) {
      Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    return $false
  }
}

function Get-JsonFromCmd {
  param([Parameter(Mandatory = $true)][string]$Command)

  $raw = (& cmd /c $Command 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed: $raw"
  }

  return $raw | ConvertFrom-Json
}

function Get-PersonalMarketplacePath {
  return Join-Path $env:USERPROFILE ".agents\plugins\marketplace.json"
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
      Add-Warning "Personal marketplace file exists but could not be parsed cleanly."
    }
  }

  return "personal"
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

function Remove-PersonalMarketplaceEntry {
  $marketplacePath = Get-PersonalMarketplacePath
  if (-not (Test-Path $marketplacePath)) {
    return $false
  }

  $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
  if (-not $payload.plugins) {
    return $false
  }

  $before = @($payload.plugins).Count
  $payload.plugins = @($payload.plugins | Where-Object { $_.name -ne "media-io" })
  if (@($payload.plugins).Count -eq $before) {
    return $false
  }

  if (-not $payload.interface) {
    $payload.interface = [ordered]@{}
  }
  if ([string]::IsNullOrWhiteSpace([string]$payload.name)) {
    $payload.name = "personal"
  }
  if ([string]::IsNullOrWhiteSpace([string]$payload.interface.displayName)) {
    $payload.interface.displayName = "Personal"
  }

  Write-JsonNoBom -Path $marketplacePath -InputObject $payload
  return $true
}

function Remove-CodexPluginCaches {
  $cacheRoots = @(
    (Join-Path $env:USERPROFILE ".codex\plugins\cache\personal\media-io"),
    (Join-Path $env:USERPROFILE ".codex\plugins\cache\media-io\media-io")
  )

  foreach ($cacheRoot in $cacheRoots) {
    if (Test-Path $cacheRoot) {
      Remove-Item -LiteralPath $cacheRoot -Recurse -Force
      Write-Host "  OK: removed plugin cache $cacheRoot" -ForegroundColor Green
    }
  }
}

function Test-CodexPluginCachePresent {
  $cacheRoots = @(
    (Join-Path $env:USERPROFILE ".codex\plugins\cache\personal\media-io"),
    (Join-Path $env:USERPROFILE ".codex\plugins\cache\media-io\media-io")
  )

  foreach ($cacheRoot in $cacheRoots) {
    if (Test-Path $cacheRoot) {
      return $true
    }
  }

  return $false
}

function Remove-SkillDirectories {
  $skillRoots = @(
    (Join-Path $env:USERPROFILE ".agents\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".agents\skills\mediaio-install"),
    (Join-Path $env:USERPROFILE ".codex\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".codex\skills\mediaio-install")
  )

  foreach ($skillRoot in $skillRoots) {
    if (Test-Path $skillRoot) {
      Remove-Item -LiteralPath $skillRoot -Recurse -Force
      Write-Host "  OK: removed skill directory $skillRoot" -ForegroundColor Green
    }
  }
}

function Test-SkillDirectoriesAbsent {
  $skillRoots = @(
    (Join-Path $env:USERPROFILE ".agents\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".agents\skills\mediaio-install"),
    (Join-Path $env:USERPROFILE ".codex\skills\mediaio-generate"),
    (Join-Path $env:USERPROFILE ".codex\skills\mediaio-install")
  )

  foreach ($skillRoot in $skillRoots) {
    if (Test-Path $skillRoot) {
      return $false
    }
  }

  return $true
}

Write-Host "Media.io uninstall script" -ForegroundColor White
Write-Host "This script removes the Media.io CLI, Codex plugin, and Media.io skills with checks after each step." -ForegroundColor DarkGray

Invoke-CheckedStep "Preflight: locate npm" {
  & cmd /c "where npm"
} -SuccessMessage "npm is available"

Invoke-CheckedStep "Preflight: locate npx" {
  & cmd /c "where npx"
} -SuccessMessage "npx is available"

Invoke-CheckedStep "Preflight: locate codex" {
  & cmd /c "where codex"
} -SuccessMessage "codex is available"

Invoke-CheckedStep "Uninstall Media.io CLI" {
  & cmd /c "npm uninstall -g @mediaio/cli"
} -Verify {
  if (Test-CommandAvailable "mediaio") {
    throw "mediaio is still present on PATH."
  }
} -SuccessMessage "Media.io CLI removed"

Invoke-CheckedStep "Remove Codex plugin" {
  $marketplaceName = Get-PersonalMarketplaceName
  $targets = @(
    "media-io@$marketplaceName",
    "media-io@media-io"
  )

  $removedByCli = $false
  foreach ($target in $targets) {
    $raw = (& cmd /c "codex plugin remove $target" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
      $removedByCli = $true
      Write-Host "  OK: codex plugin remove $target" -ForegroundColor Green
      break
    }
    Add-Warning "codex plugin remove $target returned exit code $LASTEXITCODE. $raw"
  }

  $removedFromMarketplace = Remove-PersonalMarketplaceEntry
  if ($removedFromMarketplace) {
    Write-Host "  OK: removed media-io from personal marketplace file" -ForegroundColor Green
  } elseif (-not (Test-Path (Get-PersonalMarketplacePath))) {
    Add-Warning "Personal marketplace file does not exist."
  } else {
    Add-Warning "No media-io entry was found in the personal marketplace file."
  }

  Remove-CodexPluginCaches

  if (-not $removedByCli -and -not $removedFromMarketplace -and -not (Test-CodexPluginCachePresent)) {
    Add-Warning "Codex did not report removing media-io, but the plugin cache was cleared."
  }

  if (-not $removedByCli) {
    throw "codex plugin remove did not succeed for any target."
  }
} -Verify {
  if (Test-CodexPluginCachePresent) {
    throw "Media.io plugin cache is still present."
  }

  $marketplacePath = Get-PersonalMarketplacePath
  if (Test-Path $marketplacePath) {
    $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
    $names = @($payload.plugins | ForEach-Object { $_.name })
    if ($names -contains "media-io") {
      throw "media-io is still listed in the personal marketplace file."
    }
  }
} -SuccessMessage "Codex plugin removed"

Invoke-CheckedStep "Remove Media.io skills" {
  Remove-SkillDirectories
} -Verify {
  if (-not (Test-SkillDirectoriesAbsent)) {
    throw "Some Media.io skill directories are still present."
  }
} -SuccessMessage "Media.io skills removed"

Write-Step "Final verification"

try {
  if (Test-CommandAvailable "mediaio") {
    throw "mediaio still resolves on PATH."
  }
  Write-Host "  OK: mediaio is absent from PATH" -ForegroundColor Green
} catch {
  Add-Failure "Final verification - $($_.Exception.Message)"
}

try {
  if (Test-CodexPluginCachePresent) {
    throw "Media.io plugin cache is still present."
  }
  if (-not (Test-SkillDirectoriesAbsent)) {
    throw "Some Media.io skill directories are still present."
  }
  $marketplacePath = Get-PersonalMarketplacePath
  if (Test-Path $marketplacePath) {
    $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
    $names = @($payload.plugins | ForEach-Object { $_.name })
    if ($names -contains "media-io") {
      throw "media-io is still present in the personal marketplace file."
    }
  }
  Write-Host "  OK: media-io is absent from Codex cache and personal marketplace" -ForegroundColor Green
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
