#Requires -Version 5.1
<#
.SYNOPSIS
Compiles launch-lowres-logo-color-gui.ps1 into a standalone Windows executable.

.DESCRIPTION
Bakes batch-process-videos-lowres-logo-color.ps1 and watermark.png into the launcher as
gzipped base64 payloads, then compiles the result with PS2EXE. The resulting .exe needs
no other file next to it: it unpacks the script and the logo into
%LOCALAPPDATA%\video-scan on first run and lets that script fetch FFmpeg as usual.

Windows only - PS2EXE compiles against the .NET Framework. Run it from the repository
root or from anywhere; paths are resolved relative to this script.

.PARAMETER OutputPath
Folder for the executable (default: dist next to the repository root).

.PARAMETER Version
File version stamped into the executable (default: 0.0.0).

.PARAMETER SkipModuleInstall
Fail instead of installing the PS2EXE module from the PowerShell Gallery when missing.

.EXAMPLE
.\build\build-exe.ps1

.EXAMPLE
.\build\build-exe.ps1 -Version 1.2.3 -OutputPath C:\temp\out
#>

[CmdletBinding()]
param(
  [string]$OutputPath,

  [ValidatePattern('^\d+(\.\d+){0,3}$')]
  [string]$Version = '0.0.0',

  [switch]$SkipModuleInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:EXE_NAME = 'low-res-logo-preview.exe'
$script:PAYLOADS = @(
  [pscustomobject]@{ Placeholder = '@@PAYLOAD_SCRIPT@@'; FileName = 'batch-process-videos-lowres-logo-color.ps1' }
  [pscustomobject]@{ Placeholder = '@@PAYLOAD_WATERMARK@@'; FileName = 'watermark.png' }
)

function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)

  Write-Host '  * ' -ForegroundColor DarkGray -NoNewline
  Write-Host $Message
}

function ConvertTo-Payload {
  param([Parameter(Mandatory = $true)][string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $buffer = New-Object System.IO.MemoryStream
  try {
    $gzip = New-Object System.IO.Compression.GZipStream($buffer, [System.IO.Compression.CompressionMode]::Compress, $true)
    try {
      $gzip.Write($bytes, 0, $bytes.Length)
    }
    finally {
      $gzip.Dispose()
    }

    return [Convert]::ToBase64String($buffer.ToArray())
  }
  finally {
    $buffer.Dispose()
  }
}

function Install-Ps2Exe {
  if (Get-Module -ListAvailable -Name 'ps2exe') {
    Write-Step 'PS2EXE module already available'
    return
  }

  if ($SkipModuleInstall) {
    throw 'The ps2exe module is not installed. Run "Install-Module ps2exe -Scope CurrentUser" or drop -SkipModuleInstall.'
  }

  Write-Step 'installing the PS2EXE module from the PowerShell Gallery'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Install-Module -Name 'ps2exe' -Scope CurrentUser -Force -AllowClobber
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Format-FileSize {
  param([Parameter(Mandatory = $true)][long]$Bytes)

  if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
  if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }

  return "$Bytes B"
}

if ($env:OS -ne 'Windows_NT') {
  throw 'This build script only runs on Windows: PS2EXE compiles against the .NET Framework.'
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$launcher = Join-Path $repoRoot 'launch-lowres-logo-color-gui.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
  throw "Cannot find the launcher script at $launcher."
}

if (-not $OutputPath) {
  $OutputPath = Join-Path $repoRoot 'dist'
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
$exePath = Join-Path $OutputPath $script:EXE_NAME

Write-Host ''
Write-Host "Building $($script:EXE_NAME) $Version" -ForegroundColor Cyan

$source = Get-Content -LiteralPath $launcher -Raw

foreach ($payload in $script:PAYLOADS) {
  if (-not $source.Contains($payload.Placeholder)) {
    throw "The launcher no longer contains the $($payload.Placeholder) placeholder - the executable would ship without its payload."
  }

  $file = Join-Path $repoRoot $payload.FileName
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Cannot find $($payload.FileName) at $file."
  }

  $encoded = ConvertTo-Payload -Path $file
  $source = $source.Replace($payload.Placeholder, $encoded)
  Write-Step "embedded $($payload.FileName) ($(Format-FileSize ((Get-Item -LiteralPath $file).Length)) -> $(Format-FileSize $encoded.Length) base64)"
}

Install-Ps2Exe
Import-Module -Name 'ps2exe' -Force

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("video-scan-build-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
  # PS2EXE reads UTF-8 without a BOM as ASCII, which mangles any non-ASCII character in
  # the script, so the staged copy is written as UTF-8 with a BOM.
  $stagedScript = Join-Path $staging 'launch-lowres-logo-color-gui.ps1'
  [System.IO.File]::WriteAllText($stagedScript, $source, (New-Object System.Text.UTF8Encoding($true)))

  Write-Step 'compiling with PS2EXE'
  Invoke-ps2exe `
    -inputFile $stagedScript `
    -outputFile $exePath `
    -title 'Low-res logo preview' `
    -description 'Batch converts videos to small low-resolution colour previews with a semi-transparent logo.' `
    -product 'video-scan' `
    -version $Version `
    -STA `
    -DPIAware
}
finally {
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $exePath)) {
  throw 'PS2EXE reported no error but produced no executable.'
}

$checksum = Get-Sha256 -Path $exePath
Set-Content -LiteralPath "$exePath.sha256" -Value "$checksum  $($script:EXE_NAME)" -Encoding ASCII

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  file:     $exePath"
Write-Host "  size:     $(Format-FileSize ((Get-Item -LiteralPath $exePath).Length))"
Write-Host "  sha256:   $checksum"
Write-Host ''
