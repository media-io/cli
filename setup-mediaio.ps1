[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StepIndex = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:UsePersonalMarketplaceFallback = $false
$script:ResolvedCodexMarketplaceName = $null

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

  if (-not (Test-Path $Directory)) {
    return $false
  }

  $segments = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($segments -contains $Directory) {
    return $false
  }

  $env:Path = "$Directory;$env:Path"
  return $true
}

function Repair-NodePathFromCommonLocations {
  $nodeDirs = @(
    (Join-Path $env:ProgramFiles "nodejs"),
    (Join-Path [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86) "nodejs"),
    (Join-Path $env:LocalAppData "Programs\nodejs")
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $changed = $false
  foreach ($dir in $nodeDirs) {
    if (Test-Path (Join-Path $dir "npm.cmd")) {
      if (Add-DirectoryToPath $dir) {
        $changed = $true
      }
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

  if (-not $installed) {
    throw "Node.js LTS installation did not complete successfully."
  }

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
  if ($LASTEXITCODE -ne 0) {
    throw "node -v failed."
  }

  & cmd /c "npm -v"
  if ($LASTEXITCODE -ne 0) {
    throw "npm -v failed."
  }

  & cmd /c "npx --version"
  if ($LASTEXITCODE -ne 0) {
    throw "npx --version failed."
  }
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

function Invoke-SkillInstall {
  Write-Step "Install Media.io skills"

  $commandFailed = $false
  try {
    $global:LASTEXITCODE = 0
    & cmd /c "npx --yes skills add media-io/plugin -g --skill * -y"
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
      $commandFailed = $true
      Add-Warning "Installer returned exit code $exitCode. Checking whether the skill files still landed."
    }
  } catch {
    Add-Failure "Install Media.io skills - $($_.Exception.Message)"
    return $false
  }

  $requiredPaths = @(
    Join-Path $env:USERPROFILE ".agents\skills\mediaio-generate\SKILL.md"
    Join-Path $env:USERPROFILE ".agents\skills\mediaio-install\SKILL.md"
  )
  $missing = @()
  foreach ($path in $requiredPaths) {
    if (-not (Test-Path $path)) {
      $missing += $path
    }
  }

  if ($missing.Count -gt 0) {
    Add-Failure ("Missing skill file(s): " + ($missing -join ", "))
    return $false
  }

  if ($commandFailed) {
    Add-Warning "Skill files are present even though the installer warned. That is usually enough for Codex to load the skills."
  } else {
    Write-Host "  OK: skills are installed" -ForegroundColor Green
  }

  return $true
}

function Get-MediaIoSourceRoot {
  return Join-Path $env:USERPROFILE ".codex\.tmp\marketplaces\media-io"
}

function Get-MediaIoPluginVersion {
  $manifestPath = Join-Path (Get-MediaIoSourceRoot) ".codex-plugin\plugin.json"
  if (-not (Test-Path $manifestPath)) {
    throw "Media.io plugin manifest not found at $manifestPath."
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace([string]$manifest.version)) {
    throw "Media.io plugin manifest does not declare a version."
  }

  return [string]$manifest.version
}

function Get-PersonalMarketplacePath {
  return Join-Path $env:USERPROFILE ".agents\plugins\marketplace.json"
}

function Get-LocalMediaIoPluginRoot {
  return Join-Path $env:USERPROFILE "plugins\media-io"
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
  if ($parts.Count -eq 0) {
    return "Personal"
  }

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

function Initialize-LocalMediaIoPluginRoot {
  $sourceRoot = Get-MediaIoSourceRoot
  $pluginRoot = Get-LocalMediaIoPluginRoot

  if (-not (Test-Path $sourceRoot)) {
    throw "Media.io marketplace checkout not found at $sourceRoot."
  }

  New-Item -ItemType Directory -Force -Path $pluginRoot | Out-Null
  Copy-Item -Path (Join-Path $sourceRoot "*") -Destination $pluginRoot -Recurse -Force

  $sourceManifest = Join-Path $sourceRoot ".codex-plugin\plugin.json"
  if (-not (Test-Path $sourceManifest)) {
    throw "Media.io marketplace checkout is missing .codex-plugin\plugin.json."
  }

  Copy-Item -LiteralPath $sourceManifest -Destination (Join-Path $pluginRoot "plugin.json") -Force
  return $pluginRoot
}

function Initialize-PersonalMarketplaceFallback {
  $marketplacePath = Get-PersonalMarketplacePath
  $marketplaceName = Get-PersonalMarketplaceName
  $displayName = Format-DisplayNameFromName $marketplaceName
  $payload = $null

  if (Test-Path $marketplacePath) {
    $payload = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
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

  if ([string]::IsNullOrWhiteSpace([string]$payload.name)) {
    $payload.name = $marketplaceName
  }
  if (-not $payload.interface) {
    $payload.interface = [ordered]@{}
  }
  if ([string]::IsNullOrWhiteSpace([string]$payload.interface.displayName)) {
    $payload.interface.displayName = $displayName
  }
  if (-not $payload.plugins) {
    $payload.plugins = @()
  }

  $newEntry = [ordered]@{
    name = "media-io"
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
    if ($null -eq $entry) {
      continue
    }
    if ($entry.name -eq "media-io") {
      continue
    }
    $plugins += $entry
  }
  $plugins += $newEntry
  $payload.plugins = $plugins

  Write-JsonNoBom -Path $marketplacePath -InputObject $payload
  Initialize-LocalMediaIoPluginRoot | Out-Null
  return $marketplaceName
}

function Get-CodexAvailablePluginIds {
  $raw = (& cmd /c "codex plugin list --json --available" | Out-String)
  $parsed = $raw | ConvertFrom-Json
  return @($parsed.available | ForEach-Object { $_.pluginId })
}

function Get-CodexPluginCacheRoot {
  param([Parameter(Mandatory = $true)][string]$MarketplaceName)

  $version = Get-MediaIoPluginVersion
  return (Join-Path $env:USERPROFILE ".codex\plugins\cache\$MarketplaceName\media-io\$version")
}

Write-Host "Media.io setup script" -ForegroundColor White
Write-Host "This script prints each step, checks the result, and reports failures at the end." -ForegroundColor DarkGray

Invoke-CheckedStep "Preflight: ensure Node.js and npm" {
  Ensure-NodeAndNpm
} -SuccessMessage "Node.js, npm, and npx are available"

Invoke-CheckedStep "Preflight: locate codex" {
  & cmd /c "where codex"
} -SuccessMessage "codex is available"

Invoke-CheckedStep "Install Media.io CLI" {
  & cmd /c "npm i -g @mediaio/cli"
} -Verify {
  & cmd /c "mediaio version"
} -SuccessMessage "Media.io CLI is installed"

Invoke-CheckedStep "Run Media.io doctor" {
  & cmd /c "mediaio doctor"
} -SuccessMessage "local Media.io checks passed"

Invoke-CheckedStep "Add Media.io marketplace" {
  & cmd /c "codex plugin marketplace add media-io/plugin"
} -SuccessMessage "marketplace is registered"

Invoke-CheckedStep "Refresh Media.io marketplace" {
  & cmd /c "codex plugin marketplace upgrade media-io"
} -SuccessMessage "marketplace is refreshed"

Invoke-CheckedStep "Verify marketplace visibility" {
  $availableIds = Get-CodexAvailablePluginIds
  if ($availableIds -contains "media-io@media-io") {
    Write-Host "  OK: Codex can see media-io in the git marketplace snapshot" -ForegroundColor Green
  } else {
    $script:UsePersonalMarketplaceFallback = $true
    Add-Warning "Codex does not surface media-io from the git marketplace snapshot on this build. I will fall back to the personal marketplace."
  }
} -SuccessMessage "Marketplace lookup finished"

Invoke-CheckedStep "Install Codex plugin" {
  $installedMarketplaceName = "media-io"

  if (-not $script:UsePersonalMarketplaceFallback) {
    & cmd /c "codex plugin add media-io@media-io"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Get-CodexPluginCacheRoot -MarketplaceName "media-io"))) {
      Add-Warning "The git marketplace install did not leave an installable cache root. Switching to the personal marketplace fallback."
      $script:UsePersonalMarketplaceFallback = $true
    } else {
      $script:ResolvedCodexMarketplaceName = "media-io"
    }
  }

  if ($script:UsePersonalMarketplaceFallback) {
    $installedMarketplaceName = Initialize-PersonalMarketplaceFallback
    & cmd /c "codex plugin add media-io@$installedMarketplaceName"
    if ($LASTEXITCODE -ne 0) {
      throw "codex plugin add media-io@$installedMarketplaceName failed."
    }
    if (-not (Test-Path (Get-CodexPluginCacheRoot -MarketplaceName $installedMarketplaceName))) {
      throw "Codex plugin cache root was not created for marketplace '$installedMarketplaceName'."
    }
    $script:ResolvedCodexMarketplaceName = $installedMarketplaceName
  }
} -SuccessMessage "Codex plugin install completed"

Invoke-CheckedStep "Verify Codex plugin cache" {
  if ([string]::IsNullOrWhiteSpace([string]$script:ResolvedCodexMarketplaceName)) {
    throw "Codex marketplace name was not recorded."
  }

  $cacheRoot = Get-CodexPluginCacheRoot -MarketplaceName $script:ResolvedCodexMarketplaceName
  if (-not (Test-Path $cacheRoot)) {
    throw "Codex plugin cache root is missing: $cacheRoot"
  }

  $raw = (& cmd /c "codex plugin list --json --available" | Out-String)
  $parsed = $raw | ConvertFrom-Json
  $availableIds = @($parsed.available | ForEach-Object { $_.pluginId })
  $expectedId = "media-io@$($script:ResolvedCodexMarketplaceName)"
  if ($availableIds -notcontains $expectedId) {
    Add-Warning "Codex does not currently list $expectedId in the available plugin list, but the cache root exists."
  } else {
    Write-Host "  OK: Codex lists $expectedId as available" -ForegroundColor Green
  }
} -SuccessMessage "Codex plugin cache is present"

Invoke-SkillInstall | Out-Null

Write-Step "Final verification"

try {
  $raw = (& cmd /c "mediaio version" | Out-String)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "mediaio version returned no output."
  }
  Write-Host "  OK: mediaio version responded" -ForegroundColor Green
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
