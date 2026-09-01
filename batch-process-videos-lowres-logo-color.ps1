#Requires -Version 5.1
<#
.SYNOPSIS
Batch converts videos to a small, low-resolution colour preview with the Ongehoord logo
overlaid twice, semi-transparent.

.DESCRIPTION
Starter script for producing "viewable but unusable" previews:
  - 854x480 (480p, 16:9), 15 fps, colour preserved
  - logo overlaid twice, semi-transparent, so the footage stays readable but not reusable
  - audio dropped by default (smaller files)

FFmpeg is fetched automatically the first time you run this: it is downloaded from
gyan.dev, checksum-verified and unpacked into a "bin" folder next to this script.
Nothing is installed system-wide and no administrator rights are needed. Use
-NoAutoFetch to turn that off.

Prints an input-vs-output size summary at the end so you can check whether the files
end up small enough. Tune with -CRF, -Width/-Height and -Fps and run again.

.PARAMETER FolderPath
Input folder containing videos to process (searched recursively).

.PARAMETER OutputFolder
Output folder (default: <FolderPath>\_output). Folder structure is mirrored.

.PARAMETER Width
Output width in pixels (default: 854).

.PARAMETER Height
Output height in pixels (default: 480).

.PARAMETER Fps
Output frame rate (default: 15).

.PARAMETER CRF
Quality: higher = smaller file, lower quality (default: 30). Try 32-36 for smaller files.

.PARAMETER WatermarkFile
Logo PNG with transparency (default: watermark.png next to this script).

.PARAMETER WatermarkOpacity
Logo opacity, 0.0 - 1.0 (default: 0.35).

.PARAMETER WatermarkScale
Logo width as a fraction of the video width (default: 0.6).

.PARAMETER Fit
How to fit the source into WxH: pad (black bars, default), crop, or stretch.

.PARAMETER NoAutoFetch
Do not download FFmpeg automatically; fail with install instructions instead.

.EXAMPLE
.\batch-process-videos-lowres-logo-color.ps1 -FolderPath "F:\" -OutputFolder "C:\Users\tom\Documents\video-export"

.EXAMPLE
.\batch-process-videos-lowres-logo-color.ps1 -FolderPath "F:\" -CRF 34 -WatermarkOpacity 0.25 -UseNVENC

.EXAMPLE
.\batch-process-videos-lowres-logo-color.ps1 -FolderPath "F:\test" -Verbose
Shows the full ffmpeg command line for every file.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$FolderPath,

  [Parameter(Position = 1)]
  [string]$OutputFolder,

  [int]$Width = 854,

  [int]$Height = 480,

  [int]$Fps = 15,

  [int]$CRF = 30,

  [string]$Preset = 'veryfast',

  [string]$WatermarkFile,

  [ValidateRange(0.0, 1.0)]
  [double]$WatermarkOpacity = 0.35,

  [ValidateRange(0.1, 1.0)]
  [double]$WatermarkScale = 0.6,

  [ValidateSet('pad', 'crop', 'stretch')]
  [string]$Fit = 'pad',

  [switch]$UseNVENC,

  [switch]$KeepAudio,

  [switch]$Force,

  [switch]$NoAutoFetch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:VIDEO_EXTENSIONS = @('.mp4', '.mov', '.avi', '.mkv', '.m4v', '.mpg', '.mpeg', '.wmv', '.mts', '.m2ts', '.3gp')

# FFmpeg download sources, tried in order. The gyan.dev build publishes a checksum next
# to the zip; the BtbN build is a fallback for when gyan.dev is unreachable.
$script:FFMPEG_SOURCES = @(
  [pscustomobject]@{
    Name        = 'gyan.dev (release essentials)'
    Url         = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    ChecksumUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256'
  },
  [pscustomobject]@{
    Name        = 'BtbN (win64-gpl)'
    Url         = 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
    ChecksumUrl = $null
  }
)

$script:ffmpegCmd = $null
$script:ffmpegOrigin = $null

$script:TotalFiles = 0
$script:ProcessedFiles = 0
$script:SkippedFiles = 0
$script:FailedFiles = 0
$script:TotalInputSize = 0
$script:TotalOutputSize = 0
$script:StartTime = Get-Date

function Write-ColorOutput {
  param(
    [string]$Message,
    [ValidateSet('Red', 'Green', 'Yellow', 'Blue', 'White', 'Cyan', 'DarkGray')]
    [string]$Color = 'White'
  )
  Write-Host $Message -ForegroundColor $Color
}

function Write-Step {
  param([string]$Message)
  Write-Host '  * ' -ForegroundColor DarkGray -NoNewline
  Write-Host $Message
}

function Format-FileSize {
  param([long]$Bytes)
  if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
  if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
  if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
  return "$Bytes B"
}

function Format-Duration {
  param([TimeSpan]$Span)
  # Not using TimeSpan format strings: %h wraps at 24h, and an overnight batch would
  # then be reported as "2h" instead of "26h".
  if ($Span.TotalHours -ge 1) { return '{0:N0}h{1:00}m' -f [math]::Floor($Span.TotalHours), $Span.Minutes }
  if ($Span.TotalMinutes -ge 1) { return '{0:N0}m{1:00}s' -f [math]::Floor($Span.TotalMinutes), $Span.Seconds }
  return '{0:N0}s' -f $Span.TotalSeconds
}

function Test-IsWindows {
  return ($env:OS -eq 'Windows_NT')
}

# --- FFmpeg dependency handling ---------------------------------------------------

function Save-RemoteFile {
  <#
    Streams a URL to disk, printing progress. Invoke-WebRequest is avoided on purpose:
    on Windows PowerShell 5.1 its built-in progress bar slows large downloads to a crawl.
  #>
  param(
    [string]$Uri,
    [string]$Destination,
    [string]$Label
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }

  $client = [System.Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromMinutes(30)
  $client.DefaultRequestHeaders.Add('User-Agent', 'video-scan-setup')

  $response = $null
  $source = $null
  $target = $null
  try {
    $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
    }

    $total = 0L
    if ($response.Content.Headers.ContentLength) { $total = [long]$response.Content.Headers.ContentLength }

    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $target = [System.IO.File]::Create($Destination)

    $buffer = New-Object byte[] (1024 * 256)
    $read = 0L
    $lastPercent = -1
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
      $count = $source.Read($buffer, 0, $buffer.Length)
      if ($count -le 0) { break }
      $target.Write($buffer, 0, $count)
      $read += $count

      if ($total -gt 0) {
        $percent = [int](100 * $read / $total)
        if ($percent -ne $lastPercent) {
          $lastPercent = $percent
          $speed = if ($watch.Elapsed.TotalSeconds -gt 0) { $read / $watch.Elapsed.TotalSeconds } else { 0 }
          Write-Progress -Activity $Label -Status "$(Format-FileSize $read) of $(Format-FileSize $total) at $(Format-FileSize ([long]$speed))/s" -PercentComplete $percent
        }
      }
    }

    $target.Flush()
    $watch.Stop()
    Write-Progress -Activity $Label -Completed
    return [pscustomobject]@{ Bytes = $read; Elapsed = $watch.Elapsed }
  } finally {
    if ($target) { $target.Dispose() }
    if ($source) { $source.Dispose() }
    if ($response) { $response.Dispose() }
    $client.Dispose()
  }
}

function Get-RemoteText {
  param([string]$Uri)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60).Content
}

function Expand-ZipArchive {
  param([string]$ZipPath, [string]$Destination)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
  } catch {
    # Fall back to the cmdlet if the assembly trick is unavailable.
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
  }
}

function Install-Ffmpeg {
  <#
    Downloads a static FFmpeg build and drops ffmpeg.exe + ffprobe.exe into .\bin.
    Returns the path to ffmpeg.exe, or $null when every source failed.
  #>
  param([string]$BinPath)

  if (-not (Test-IsWindows)) {
    Write-ColorOutput 'Auto-fetch only supports Windows; install ffmpeg with your package manager.' -Color Yellow
    return $null
  }

  if (-not [Environment]::Is64BitOperatingSystem) {
    Write-ColorOutput 'Auto-fetch needs 64-bit Windows; install ffmpeg manually.' -Color Yellow
    return $null
  }

  Write-ColorOutput 'FFmpeg not found - fetching it now (one-off, ~80 MB).' -Color Yellow

  foreach ($source in $script:FFMPEG_SOURCES) {
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ffmpeg-fetch-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $workDir 'ffmpeg.zip'
    $extractDir = Join-Path $workDir 'unpacked'

    try {
      New-Item -ItemType Directory -Path $workDir -Force | Out-Null

      Write-Step "Source: $($source.Name)"
      Write-Step "Downloading $($source.Url)"
      $result = Save-RemoteFile -Uri $source.Url -Destination $zipPath -Label 'Downloading FFmpeg'
      Write-Step "Downloaded $(Format-FileSize $result.Bytes) in $(Format-Duration $result.Elapsed)"

      if ($source.ChecksumUrl) {
        Write-Step 'Verifying SHA-256 checksum'
        $expectedRaw = Get-RemoteText -Uri $source.ChecksumUrl
        $match = [regex]::Match($expectedRaw, '[A-Fa-f0-9]{64}')
        if (-not $match.Success) { throw 'could not read the published checksum' }
        $expected = $match.Value
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
          throw "checksum mismatch (expected $expected, got $actual)"
        }
        Write-Step "Checksum OK ($($expected.Substring(0, 16))...)"
      } else {
        Write-ColorOutput '  * No published checksum for this source; download not verified.' -Color Yellow
      }

      Write-Step 'Unpacking archive'
      Expand-ZipArchive -ZipPath $zipPath -Destination $extractDir

      $ffmpegBin = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $ffmpegBin) { throw 'the archive contained no ffmpeg.exe' }
      $ffprobeBin = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'ffprobe.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

      if (-not (Test-Path -LiteralPath $BinPath)) {
        New-Item -ItemType Directory -Path $BinPath -Force | Out-Null
      }
      Copy-Item -LiteralPath $ffmpegBin.FullName -Destination (Join-Path $BinPath 'ffmpeg.exe') -Force
      if ($ffprobeBin) {
        Copy-Item -LiteralPath $ffprobeBin.FullName -Destination (Join-Path $BinPath 'ffprobe.exe') -Force
      }

      $installed = Join-Path $BinPath 'ffmpeg.exe'
      Write-Step "Installed to $installed"
      return $installed
    } catch {
      Write-ColorOutput "  * $($source.Name) failed: $($_.Exception.Message)" -Color Red
    } finally {
      if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  return $null
}

function Get-FfmpegVersion {
  param([string]$Command)
  try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $line = & $Command -hide_banner -version 2>&1 | Select-Object -First 1
    } finally {
      $ErrorActionPreference = $prev
    }
    if ($line) { return ($line | Out-String).Trim() }
  } catch { }
  return 'unknown version'
}

function Resolve-Dependencies {
  $binPath = Join-Path $PSScriptRoot 'bin'
  $ffmpegLocal = Join-Path $binPath 'ffmpeg.exe'

  Write-ColorOutput 'Checking dependencies' -Color Blue

  if (Test-Path -LiteralPath $ffmpegLocal) {
    $script:ffmpegCmd = $ffmpegLocal
    $script:ffmpegOrigin = 'bundled in .\bin'
  } else {
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($onPath) {
      $script:ffmpegCmd = $onPath.Source
      $script:ffmpegOrigin = 'found on PATH'
    }
  }

  if (-not $script:ffmpegCmd -and -not $NoAutoFetch) {
    $fetched = Install-Ffmpeg -BinPath $binPath
    if ($fetched) {
      $script:ffmpegCmd = $fetched
      $script:ffmpegOrigin = 'downloaded just now'
    }
  }

  if (-not $script:ffmpegCmd) {
    Write-Host ''
    Write-ColorOutput 'Error: ffmpeg is required and could not be obtained.' -Color Red
    Write-ColorOutput 'Install it in one of these ways, then run this script again:' -Color Yellow
    Write-ColorOutput '  winget install Gyan.FFmpeg' -Color Yellow
    Write-ColorOutput "  or download https://www.gyan.dev/ffmpeg/builds/ and copy ffmpeg.exe into $binPath" -Color Yellow
    exit 1
  }

  Write-Step "ffmpeg: $($script:ffmpegCmd) ($($script:ffmpegOrigin))"
  Write-Step (Get-FfmpegVersion -Command $script:ffmpegCmd)
}

function Resolve-Watermark {
  $logoPath = $WatermarkFile
  if (-not $logoPath) {
    $logoPath = Join-Path $PSScriptRoot 'watermark.png'
  }
  if (-not (Test-Path -LiteralPath $logoPath)) {
    Write-ColorOutput "Error: logo file not found: $logoPath" -Color Red
    Write-ColorOutput 'Place the Ongehoord logo (PNG with transparency) there, or pass -WatermarkFile.' -Color Yellow
    exit 1
  }
  $resolved = (Resolve-Path -LiteralPath $logoPath).Path
  Write-Step "logo:   $resolved"
  return $resolved
}

# --- Encoding ---------------------------------------------------------------------

function Get-FilterComplex {
  # Scale/pad the source, force the frame rate, keep colour, then stamp the logo twice.
  switch ($Fit) {
    'crop'    { $fitFilter = "scale=${Width}:${Height}:force_original_aspect_ratio=increase,crop=${Width}:${Height}" }
    'stretch' { $fitFilter = "scale=${Width}:${Height}" }
    default   { $fitFilter = "scale=${Width}:${Height}:force_original_aspect_ratio=decrease,pad=${Width}:${Height}:(ow-iw)/2:(oh-ih)/2" }
  }

  $logoWidth = [math]::Round($Width * $WatermarkScale)
  $opacity = $WatermarkOpacity.ToString([System.Globalization.CultureInfo]::InvariantCulture)

  $chain = @(
    "[0:v]${fitFilter},fps=${Fps},format=yuv420p[base]"
    "[1:v]format=rgba,scale=${logoWidth}:-2,colorchannelmixer=aa=${opacity},split=2[wm1][wm2]"
    # upper third and lower third, horizontally centred
    "[base][wm1]overlay=(W-w)/2:(H*0.28)-(h/2)[stamped1]"
    "[stamped1][wm2]overlay=(W-w)/2:(H*0.72)-(h/2)"
  )
  return ($chain -join ';')
}

function Invoke-VideoEncode {
  param(
    [string]$InputFile,
    [string]$OutputFile,
    [string]$Watermark
  )

  $ffmpegArgs = @('-nostdin', '-y', '-loglevel', 'error')
  $ffmpegArgs += @('-i', $InputFile, '-i', $Watermark)
  $ffmpegArgs += @('-filter_complex', (Get-FilterComplex))

  if ($UseNVENC) {
    $ffmpegArgs += @('-c:v', 'h264_nvenc', '-preset', 'p4', '-rc', 'vbr', '-cq', $CRF, '-b:v', '0')
  } else {
    $ffmpegArgs += @('-c:v', 'libx264', '-preset', $Preset, '-crf', $CRF)
  }

  if ($KeepAudio) {
    $ffmpegArgs += @('-c:a', 'aac', '-b:a', '64k', '-ac', '1')
  } else {
    $ffmpegArgs += '-an'
  }

  $ffmpegArgs += @('-movflags', '+faststart', $OutputFile)

  Write-Verbose "$($script:ffmpegCmd) $($ffmpegArgs -join ' ')"

  # Capture stderr so a failure can be reported in full instead of scrolling past.
  $errLog = [System.IO.Path]::GetTempFileName()
  try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & $script:ffmpegCmd @ffmpegArgs 2> $errLog
    } finally {
      $ErrorActionPreference = $prev
    }
    $exitCode = $LASTEXITCODE

    $stderr = ''
    if (Test-Path -LiteralPath $errLog) {
      $stderr = (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)
      if ($null -eq $stderr) { $stderr = '' }
    }
    return [pscustomobject]@{ Success = ($exitCode -eq 0); ExitCode = $exitCode; Error = $stderr.Trim() }
  } finally {
    Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue
  }
}

function Write-RunHeader {
  $encoder = if ($UseNVENC) { 'h264_nvenc (GPU)' } else { "libx264 (CPU, preset $Preset)" }
  $audio = if ($KeepAudio) { 'AAC 64k mono' } else { 'dropped' }
  Write-Host ''
  Write-ColorOutput 'Settings' -Color Blue
  Write-Step "input:  $FolderPath"
  Write-Step "output: $OutputFolder"
  Write-Step "video:  ${Width}x${Height} @ ${Fps}fps, colour, fit=$Fit"
  Write-Step "codec:  $encoder, CRF $CRF"
  Write-Step "audio:  $audio"
  Write-Step "logo:   2 stamps, $([int]($WatermarkOpacity * 100))% opacity, $([int]($WatermarkScale * 100))% of frame width"
  Write-Host ''
}

function Invoke-ProcessAllVideos {
  param([string]$Watermark)

  $inputRoot = (Resolve-Path -LiteralPath $FolderPath).Path
  $outputPrefix = $OutputFolder.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

  Write-ColorOutput 'Scanning for videos...' -Color Blue
  # -ErrorAction SilentlyContinue: unreadable folders (e.g. "System Volume Information" or
  # "$RECYCLE.BIN" on a drive root) would otherwise abort the whole scan, because
  # $ErrorActionPreference is 'Stop'.
  $videos = Get-ChildItem -LiteralPath $inputRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $script:VIDEO_EXTENSIONS -contains $_.Extension.ToLower() } |
    Where-Object { -not $_.FullName.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase) }

  $script:TotalFiles = ($videos | Measure-Object).Count
  if ($script:TotalFiles -eq 0) {
    Write-ColorOutput 'No videos found.' -Color Yellow
    return
  }

  $totalInput = ($videos | Measure-Object -Property Length -Sum).Sum
  Write-Step "$($script:TotalFiles) video(s), $(Format-FileSize $totalInput) of source material"
  Write-Host ''

  $index = 0
  $encodeSeconds = 0.0
  $usedOutputs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

  foreach ($video in $videos) {
    $index++
    $relative = $video.FullName.Substring($inputRoot.Length).TrimStart('\', '/')
    $outputFile = Join-Path $OutputFolder ([System.IO.Path]::ChangeExtension($relative, '.mp4'))
    if (-not $usedOutputs.Add($outputFile)) {
      # Two sources collapse onto the same name (e.g. clip.mov and clip.mp4); keep both.
      $outputFile = Join-Path $OutputFolder ($relative + '.mp4')
      [void]$usedOutputs.Add($outputFile)
    }
    $outputDir = Split-Path $outputFile -Parent

    if ((Test-Path -LiteralPath $outputFile) -and -not $Force) {
      Write-ColorOutput "[$index/$($script:TotalFiles)] Skipping (exists): $relative" -Color Yellow
      $script:SkippedFiles++
      continue
    }

    Write-Host "[$index/$($script:TotalFiles)] $relative ... " -NoNewline

    if (-not (Test-Path -LiteralPath $outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Encode to a temporary name and only publish it on success: an interrupted run
    # must not leave a truncated file behind that the next run skips as "done".
    $tempOutput = Join-Path $outputDir ('{0}.partial.mp4' -f [System.IO.Path]::GetFileNameWithoutExtension($outputFile))
    if (Test-Path -LiteralPath $tempOutput) { Remove-Item -LiteralPath $tempOutput -Force }

    $inputSize = $video.Length
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
      $result = Invoke-VideoEncode -InputFile $video.FullName -OutputFile $tempOutput -Watermark $Watermark
    } catch {
      $result = [pscustomobject]@{ Success = $false; ExitCode = -1; Error = $_.Exception.Message }
    }
    $watch.Stop()

    if ($result.Success -and (Test-Path -LiteralPath $tempOutput)) {
      Move-Item -LiteralPath $tempOutput -Destination $outputFile -Force
      $outputSize = (Get-Item -LiteralPath $outputFile).Length
      $script:TotalInputSize += $inputSize
      $script:TotalOutputSize += $outputSize
      $script:ProcessedFiles++
      $encodeSeconds += $watch.Elapsed.TotalSeconds

      $percent = if ($inputSize -gt 0) { [math]::Round(100 * $outputSize / $inputSize, 1) } else { 0 }
      $line = "$(Format-FileSize $inputSize) -> $(Format-FileSize $outputSize) ($percent%) in $(Format-Duration $watch.Elapsed)"

      $remaining = $script:TotalFiles - $index
      if ($remaining -gt 0 -and $script:ProcessedFiles -gt 0) {
        $eta = [TimeSpan]::FromSeconds(($encodeSeconds / $script:ProcessedFiles) * $remaining)
        $line += " | ETA $(Format-Duration $eta)"
      }
      Write-ColorOutput $line -Color Green
    } else {
      $script:FailedFiles++
      if (Test-Path -LiteralPath $tempOutput) { Remove-Item -LiteralPath $tempOutput -Force }
      Write-ColorOutput "failed (exit $($result.ExitCode))" -Color Red
      if ($result.Error) {
        foreach ($errLine in ($result.Error -split "`r?`n" | Select-Object -First 5)) {
          Write-ColorOutput "      $errLine" -Color DarkGray
        }
      }
    }
  }
}

function Write-Summary {
  $elapsed = (Get-Date) - $script:StartTime
  Write-Host ''
  Write-ColorOutput '=== Summary ===' -Color Blue
  Write-Host "Processed: $($script:ProcessedFiles)"
  Write-Host "Skipped:   $($script:SkippedFiles)"
  Write-Host "Failed:    $($script:FailedFiles)"
  Write-Host "Runtime:   $(Format-Duration $elapsed)"
  if ($script:ProcessedFiles -gt 0) {
    $ratio = if ($script:TotalInputSize -gt 0) { [math]::Round(100 * $script:TotalOutputSize / $script:TotalInputSize, 1) } else { 0 }
    Write-Host "Input:     $(Format-FileSize $script:TotalInputSize)"
    Write-Host "Output:    $(Format-FileSize $script:TotalOutputSize) ($ratio% of input)"
    $avg = [math]::Round($script:TotalOutputSize / $script:ProcessedFiles)
    Write-Host "Average:   $(Format-FileSize $avg) per file"
    Write-Host ''
    Write-ColorOutput 'Too big? Raise -CRF (e.g. 34), lower -Fps or shrink -Width/-Height.' -Color Cyan
  }
  if ($script:FailedFiles -gt 0) {
    Write-ColorOutput 'Some files failed. Re-run with -Verbose to see the exact ffmpeg command.' -Color Yellow
  }
}

# --- Main -------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $FolderPath)) {
  Write-ColorOutput "Error: input folder not found: $FolderPath" -Color Red
  exit 1
}

if (($Width % 2) -ne 0 -or ($Height % 2) -ne 0) {
  Write-ColorOutput "Error: -Width and -Height must be even (got ${Width}x${Height}); H.264 cannot encode odd dimensions." -Color Red
  exit 1
}

Resolve-Dependencies
$watermarkPath = Resolve-Watermark

if (-not $OutputFolder) {
  $OutputFolder = Join-Path (Resolve-Path -LiteralPath $FolderPath).Path '_output'
}
if (-not (Test-Path -LiteralPath $OutputFolder)) {
  New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$OutputFolder = (Resolve-Path -LiteralPath $OutputFolder).Path

Write-RunHeader
Invoke-ProcessAllVideos -Watermark $watermarkPath
Write-Summary
