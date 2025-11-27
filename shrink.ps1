<#
.SYNOPSIS
Video processing script with watermark, resizing, and color correction.

.DESCRIPTION
Processes videos recursively with optional timestamp blur.

.PARAMETER FolderPath
Input folder containing videos to process

.PARAMETER OutputFolder
Output folder for processed videos (default: input_folder/_output)

.PARAMETER MaxParallelJobs
Maximum number of parallel encoding jobs (default: auto-detect CPU cores / 4)

.PARAMETER BlurTimestamp
Switch to enable timestamp blurring

.EXAMPLE
.\shrink.ps1 -FolderPath "F:\" -OutputFolder "C:\Users\tom\Documents\video-export"

.EXAMPLE
.\shrink.ps1 -FolderPath "F:\" -BlurTimestamp -MaxParallelJobs 5
#>

[CmdletBinding()]
param(
[Parameter(Mandatory=$true, Position=0)]
[string]$FolderPath,

[Parameter(Position=1)]
[string]$OutputFolder,

[Parameter(Position=2)]
[int]$MaxParallelJobs,

[Parameter(Position=3)]
[int]$CRF = 23,

[Parameter(Position=4)]
[string]$Preset = "veryfast",

[Parameter(Position=5)]
[int]$ThreadsPerJob = 0,

[switch]$UseNVENC,

[switch]$BlurTimestamp
)

# Strict mode
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Constants
$script:WATERMARK_FILE = "watermark.png"
$script:OUTPUT_WIDTH = 640
$script:OUTPUT_HEIGHT = 360
$script:CRF_VALUE = $CRF
$script:PRESET = $Preset
$script:USE_NVENC = $UseNVENC
$script:THREADS_PER_JOB = $ThreadsPerJob
$script:RESUME_LOG = ".shrink_resume.log"

# Tracking variables
$script:TotalFiles = 0
$script:ProcessedFiles = 0
$script:SkippedFiles = 0
$script:FailedFiles = 0
$script:TotalInputSize = 0
$script:TotalOutputSize = 0
$script:StartTime = $null

# Thread-safe counters for parallel processing
$script:ProcessedCounter = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
$script:SkippedCounter = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
$script:FailedCounter = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
$script:InputSizeCounter = [System.Collections.Concurrent.ConcurrentBag[long]]::new()
$script:OutputSizeCounter = [System.Collections.Concurrent.ConcurrentBag[long]]::new()

function Write-ColorOutput {
  param(
  [string]$Message,
  [ValidateSet('Red', 'Green', 'Yellow', 'Blue', 'White')]
  [string]$Color = 'White'
  )
  Write-Host $Message -ForegroundColor $Color
}

function Test-Dependencies {
  $binPath = Join-Path $PSScriptRoot 'bin'
  $ffmpegLocal = Join-Path $binPath 'ffmpeg.exe'
  $ffprobeLocal = Join-Path $binPath 'ffprobe.exe'

  $script:ffmpegCmd = $null
  $script:ffprobeCmd = $null

  if (Test-Path $ffmpegLocal) {
    $script:ffmpegCmd = $ffmpegLocal
  } elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $script:ffmpegCmd = 'ffmpeg'
  }

  if (Test-Path $ffprobeLocal) {
    $script:ffprobeCmd = $ffprobeLocal
  } elseif (Get-Command ffprobe -ErrorAction SilentlyContinue) {
    $script:ffprobeCmd = 'ffprobe'
  }

  $missingDeps = @()
  if (-not $script:ffmpegCmd) { $missingDeps += 'ffmpeg' }
  if (-not $script:ffprobeCmd) { $missingDeps += 'ffprobe' }

  if ($missingDeps.Count -gt 0) {
    Write-ColorOutput "Error: Missing required dependencies:" -Color Red
    foreach ($dep in $missingDeps) {
      Write-ColorOutput "  - $dep" -Color Red
    }
    Write-ColorOutput "Please install them and try again." -Color Red
    Write-ColorOutput "You can install ffmpeg from: https://ffmpeg.org/download.html" -Color Yellow
    exit 1
  }
}

function Test-Watermark {
  if (-not (Test-Path $script:WATERMARK_FILE)) {
    Write-ColorOutput "Error: Watermark file '$script:WATERMARK_FILE' not found" -Color Red
    Write-ColorOutput "Please ensure the watermark file exists in the current directory." -Color Red
    exit 1
  }
}

function Get-OptimalParallelJobs {
  $cpuCores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

  # NVENC can handle more parallel jobs than CPU encoding
  if ($script:USE_NVENC) {
    $jobs = 8  # RTX GPUs can handle 6-10 NVENC sessions
  } else {
    $jobs = [Math]::Max(1, [Math]::Floor($cpuCores / 2))
  }

  # Auto-calculate threads per job if not specified
  if ($script:THREADS_PER_JOB -le 0) {
    if ($script:USE_NVENC) {
      $script:THREADS_PER_JOB = [Math]::Max(4, [Math]::Floor($cpuCores / $jobs))  # More threads for filtering
    } else {
      $script:THREADS_PER_JOB = [Math]::Max(2, [Math]::Floor($cpuCores / $jobs))
    }
  }

  if ($script:USE_NVENC) {
    Write-ColorOutput "Auto-detected $cpuCores CPU cores, using $jobs parallel NVENC jobs with $($script:THREADS_PER_JOB) threads each for filtering" -Color Blue
  } else {
    Write-ColorOutput "Auto-detected $cpuCores CPU cores, using $jobs parallel jobs with $($script:THREADS_PER_JOB) threads each" -Color Blue
  }
  return $jobs
}function Initialize-Setup {
  if (-not (Test-Path $FolderPath)) {
    Write-ColorOutput "Error: $FolderPath is not a directory" -Color Red
    exit 1
  }

  if (-not (Test-Path $script:OutputFolder)) {
    New-Item -ItemType Directory -Path $script:OutputFolder -Force | Out-Null
  }
}

function Get-FileSize {
  param([string]$FilePath)
  if (Test-Path $FilePath) {
    return (Get-Item $FilePath).Length
  }
  return 0
}

function Format-FileSize {
  param([long]$Bytes)

  if ($Bytes -lt 1KB) { return "$Bytes B" }
  elseif ($Bytes -lt 1MB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
  elseif ($Bytes -lt 1GB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
  else { return "{0:N2} GB" -f ($Bytes / 1GB) }
}

function Format-TimeSpan {
  param([int]$Seconds)

  $hours = [Math]::Floor($Seconds / 3600)
  $minutes = [Math]::Floor(($Seconds % 3600) / 60)
  $secs = $Seconds % 60

  if ($hours -gt 0) {
    return "${hours}h ${minutes}m ${secs}s"
  } elseif ($minutes -gt 0) {
    return "${minutes}m ${secs}s"
  } else {
    return "${secs}s"
  }
}

function Write-Summary {
  $elapsed = ((Get-Date) - $script:StartTime).TotalSeconds

  # Aggregate thread-safe counters
  $script:ProcessedFiles = $script:ProcessedCounter.Count
  $script:SkippedFiles = $script:SkippedCounter.Count
  $script:FailedFiles = $script:FailedCounter.Count
  $script:TotalInputSize = ($script:InputSizeCounter | Measure-Object -Sum).Sum
  $script:TotalOutputSize = ($script:OutputSizeCounter | Measure-Object -Sum).Sum

  $savedSpace = $script:TotalInputSize - $script:TotalOutputSize

  Write-Host ""
  Write-ColorOutput "═══════════════════════════════════════════" -Color Blue
  Write-ColorOutput "           PROCESSING SUMMARY" -Color Blue
  Write-ColorOutput "═══════════════════════════════════════════" -Color Blue
  Write-Host "Total files found:    $script:TotalFiles"
  Write-ColorOutput "Successfully processed: $script:ProcessedFiles" -Color Green
  Write-ColorOutput "Skipped (existing):   $script:SkippedFiles" -Color Yellow
  if ($script:FailedFiles -gt 0) {
    Write-ColorOutput "Failed:               $script:FailedFiles" -Color Red
  }
  Write-Host ""
  if ($script:TotalInputSize -gt 0) {
    Write-Host "Total input size:     $(Format-FileSize $script:TotalInputSize)"
    Write-Host "Total output size:    $(Format-FileSize $script:TotalOutputSize)"
    Write-ColorOutput "Space saved:          $(Format-FileSize $savedSpace)" -Color Green
    $compressionRatio = [Math]::Round(($savedSpace * 100) / $script:TotalInputSize, 1)
    Write-Host "Compression ratio:    $compressionRatio%"
    Write-Host ""
  }
  Write-Host "Time elapsed:         $(Format-TimeSpan ([int]$elapsed))"
  if ($script:ProcessedFiles -gt 0) {
    $avgTime = [Math]::Floor($elapsed / $script:ProcessedFiles)
    Write-Host "Average per file:     $(Format-TimeSpan $avgTime)"
  }
  Write-ColorOutput "═══════════════════════════════════════════" -Color Blue
}

function Get-VideoResolution {
  param([string]$FilePath)

  try {
    $output = & $script:ffprobeCmd -v error -select_streams v:0 `
      -show_entries stream=width,height -of csv=s=x:p=0 "$FilePath" 2>&1

    if ($LASTEXITCODE -ne 0 -or -not $output -or $output -notmatch '^\d+x\d+$') {
      throw "Unable to get video resolution"
    }

    return $output
  } catch {
    Write-ColorOutput "Error getting video resolution for ${FilePath}: $_" -Color Red
    return $null
  }
}

function Test-VideoFile {
  param([string]$FilePath)

  if (-not (Test-Path $FilePath)) {
    return $false
  }

  # Check if file size is greater than 0
  $fileSize = (Get-Item $FilePath).Length
  if ($fileSize -eq 0) {
    return $false
  }

  # Use ffprobe to validate video file integrity
  $output = & $script:ffprobeCmd -v error -i "$FilePath" 2>&1

  # If ffprobe returns any error, file is invalid
  if ($LASTEXITCODE -ne 0 -or $output) {
    return $false
  }

  return $true
}

function Get-CropCoordinates {
  param([int]$Height)

  if ($Height -eq 720) {
    # 720p: scale coordinates by 720/1080 = 0.667
    return @{
      Width = 369
      Height = 71
      X = 41
      Y = 617
    }
  } elseif ($Height -eq 1080) {
    # 1080p: use original coordinates
    return @{
      Width = 554
      Height = 106
      X = 62
      Y = 926
    }
  } else {
    # For other resolutions, scale proportionally to height
    $scale = $Height / 1080.0
    return @{
      Width = [Math]::Floor($scale * 554)
      Height = [Math]::Floor($scale * 106)
      X = [Math]::Floor($scale * 62)
      Y = [Math]::Floor($scale * 926)
    }
  }
}

function Get-FilterChain {
  param(
  [hashtable]$CropCoords,
  [bool]$EnableBlur
  )

  # Black and white filter - remove all saturation
  $colorFilter = "hue=s=0"

  if ($EnableBlur) {
    return "[0:v]crop=$($CropCoords.Width):$($CropCoords.Height):$($CropCoords.X):$($CropCoords.Y),avgblur=8[fg];[0:v][fg]overlay=$($CropCoords.X):$($CropCoords.Y)[blurred];[blurred]scale=${script:OUTPUT_WIDTH}:${script:OUTPUT_HEIGHT}:flags=fast_bilinear,${colorFilter}[v];[v][1:v]overlay=0:0"
  } else {
    return "[0:v]scale=${script:OUTPUT_WIDTH}:${script:OUTPUT_HEIGHT}:flags=fast_bilinear,${colorFilter}[v];[v][1:v]overlay=0:0"
  }
}

function Invoke-VideoEncode {
  param(
  [string]$InputFile,
  [string]$OutputFile,
  [bool]$EnableBlur
  )

  try {
    # Get video resolution
    $resolution = Get-VideoResolution -FilePath $InputFile
    if (-not $resolution) {
      Write-ColorOutput "Failed to get video resolution for: $InputFile" -Color Red
      return $false
    }

    $heightStr = ($resolution -split 'x')[1]
    if (-not $heightStr -or $heightStr -notmatch '^\d+$') {
      Write-ColorOutput "Invalid resolution format: $resolution for file: $InputFile" -Color Red
      return $false
    }

    $height = [int]$heightStr

    # Calculate crop coordinates
    $cropCoords = Get-CropCoordinates -Height $height

    # Build filter chain
    $filterComplex = Get-FilterChain -CropCoords $cropCoords -EnableBlur $EnableBlur

    # Use NVENC GPU encoding if requested, otherwise CPU
    if ($script:USE_NVENC) {
      $encoder = "h264_nvenc"
      $preset = "p4"  # NVENC presets: p1-p7, p4 is balanced
      $hwaccel = @()  # No hardware decode - filters need CPU
      $qualityParam = "-cq"
      $qualityValue = $script:CRF_VALUE
      $rateControl = @("-rc", "constqp")
    } else {
      $encoder = "libx264"
      $preset = $script:PRESET
      $hwaccel = @()
      $qualityParam = "-crf"
      $qualityValue = $script:CRF_VALUE
      $rateControl = @()
    }

    # Create temp file for error logging
    $errorLog = [System.IO.Path]::GetTempFileName()
    $progressLog = [System.IO.Path]::GetTempFileName()

    # Get video duration for progress calculation
    $durationOutput = & $script:ffprobeCmd -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>&1
    $totalDuration = [double]$durationOutput

    # Build arguments array with properly quoted paths
    $ffmpegArgs = New-Object System.Collections.ArrayList
    $ffmpegArgs.AddRange(@("-nostdin", "-y"))
    if ($hwaccel.Count -gt 0) { $ffmpegArgs.AddRange($hwaccel) }
    $ffmpegArgs.AddRange(@("-progress", "`"$progressLog`"", "-loglevel", "error"))
    if (-not $script:USE_NVENC) { $ffmpegArgs.AddRange(@("-threads", $script:THREADS_PER_JOB)) }
    $ffmpegArgs.AddRange(@("-i", "`"$InputFile`"", "-i", "`"$($script:WATERMARK_FILE)`""))
    $ffmpegArgs.AddRange(@("-filter_complex", "`"$filterComplex`"", "-c:v", $encoder, "-preset", $preset))
    if ($rateControl.Count -gt 0) { $ffmpegArgs.AddRange($rateControl) }
    $ffmpegArgs.AddRange(@($qualityParam, $qualityValue, "-movflags", "+faststart", "-an", "`"$OutputFile`""))

    # Start ffmpeg with progress output
    $process = Start-Process -FilePath $script:ffmpegCmd -ArgumentList ($ffmpegArgs -join ' ') -NoNewWindow -PassThru -RedirectStandardError $errorLog    # Monitor progress
    $lastProgress = -1
    while (-not $process.HasExited) {
      Start-Sleep -Milliseconds 500
      if (Test-Path $progressLog) {
        $progressContent = Get-Content $progressLog -Tail 20 -ErrorAction SilentlyContinue
        $timeLine = $progressContent | Where-Object { $_ -match 'out_time_ms=(\d+)' } | Select-Object -Last 1
        if ($timeLine -and $timeLine -match 'out_time_ms=(\d+)') {
          $currentTime = [double]$matches[1] / 1000000  # Convert microseconds to seconds
          if ($totalDuration -gt 0) {
            $percentComplete = [Math]::Min(100, [Math]::Floor(($currentTime / $totalDuration) * 100))
            if ($percentComplete -ne $lastProgress -and $percentComplete -ge 0) {
              Write-Progress -Activity "Encoding: $(Split-Path $InputFile -Leaf)" -Status "$percentComplete% Complete" -PercentComplete $percentComplete
              $lastProgress = $percentComplete
            }
          }
        }
      }
    }

    $process.WaitForExit()
    Write-Progress -Activity "Encoding" -Completed

    Remove-Item $progressLog -ErrorAction SilentlyContinue

    if ($process.ExitCode -eq 0) {
      Remove-Item $errorLog -ErrorAction SilentlyContinue
      return $true
    } else {
      Write-ColorOutput "FFmpeg error details:" -Color Red
      Get-Content $errorLog | Write-Host
      Remove-Item $errorLog -ErrorAction SilentlyContinue
      return $false
    }
  } catch {
    Write-ColorOutput "Fatal error in Invoke-VideoEncode for ${InputFile}: $_" -Color Red
    Remove-Item $errorLog -ErrorAction SilentlyContinue
    Remove-Item $progressLog -ErrorAction SilentlyContinue
    return $false
  }
}

function Invoke-ProcessVideo {
  param(
  [string]$File,
  [string]$FolderPath,
  [string]$OutputFolder,
  [bool]$EnableBlur
  )

  try {
    # Get relative path from input folder
    $relativePath = $File.Substring($FolderPath.Length) -replace '^[\\/]+', ''
    $filename = [System.IO.Path]::GetFileNameWithoutExtension($File)

    # Preserve directory structure in output
    $fileDir = [System.IO.Path]::GetDirectoryName($relativePath)
    if ($fileDir) {
      $outputDir = Join-Path $OutputFolder $fileDir
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
      $outputFile = Join-Path $outputDir "$filename.resized.mp4"
    } else {
      $outputFile = Join-Path $OutputFolder "$filename.resized.mp4"
    }

    # Check if already processed in resume log
    if ((Test-Path $script:RESUME_LOG) -and (Get-Content $script:RESUME_LOG -ErrorAction SilentlyContinue | Where-Object { $_ -eq $outputFile })) {
      $timestamp = Get-Date -Format "HH:mm:ss"
      Write-ColorOutput "[$timestamp] Skipping (in resume log): ${File}" -Color Yellow
      $script:SkippedCounter.Add(1)
      return
    }

    # Convert the file
    $shouldProcess = $false

    if (Test-Path $outputFile) {
      # File exists, validate it
      if (Test-VideoFile -FilePath $outputFile) {
        # Valid file, skip processing
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] File already exists and is valid. Skipping..." -Color Yellow
        $script:SkippedCounter.Add(1)
        return
      } else {
        # Invalid/corrupted file, reprocess
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Existing file is invalid/corrupted, reprocessing: ${File}" -Color Yellow
        Remove-Item $outputFile -ErrorAction SilentlyContinue
        $shouldProcess = $true
      }
    } else {
      $shouldProcess = $true
    }

    if ($shouldProcess) {
      $inputSize = Get-FileSize -FilePath $File

      $processedCount = $script:ProcessedCounter.Count + $script:SkippedCounter.Count + $script:FailedCounter.Count
      $remaining = $script:TotalFiles - $processedCount

      # Calculate ETA
      if ($processedCount -gt 0 -and $script:StartTime) {
        $elapsed = ((Get-Date) - $script:StartTime).TotalSeconds
        $avgTime = [Math]::Floor($elapsed / $processedCount)
        $eta = $avgTime * $remaining
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Processing $processedCount/$script:TotalFiles (ETA: $(Format-TimeSpan $eta)): ${File}" -Color Blue
      } else {
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Processing $processedCount/$script:TotalFiles: ${File}" -Color Blue
      }

      if (Invoke-VideoEncode -InputFile $File -OutputFile $outputFile -EnableBlur $EnableBlur) {
        $outputSize = Get-FileSize -FilePath $outputFile
        $script:InputSizeCounter.Add($inputSize)
        $script:OutputSizeCounter.Add($outputSize)
        $script:ProcessedCounter.Add(1)

        # Thread-safe file append
        $mutex = New-Object System.Threading.Mutex($false, "ShrinkResumeLog")
        $mutex.WaitOne() | Out-Null
        try {
          Add-Content -Path $script:RESUME_LOG -Value $outputFile
        } finally {
          $mutex.ReleaseMutex()
        }

        $saved = $inputSize - $outputSize
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Completed: $outputFile (saved $(Format-FileSize $saved))" -Color Green
      } else {
        $script:FailedCounter.Add(1)
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] FAILED: ${File}" -Color Red
      }
    }
  } catch {
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-ColorOutput "[$timestamp] CRITICAL ERROR processing ${File}: $_" -Color Red
    $script:FailedCounter.Add(1)
  }
}

function Invoke-ProcessAllVideos {
  # Scan for video files
  Write-ColorOutput "Scanning for video files..." -Color Blue

  $videoFiles = Get-ChildItem -Path $FolderPath -Recurse -File -Include @(
  '*.avi', '*.mov', '*.mpeg', '*.mkv', '*.wmv', '*.m4a', '*.m4v', '*.mp4'
  ) | Where-Object { $_.FullName -like '*\stens staphorst\*' }

  $script:TotalFiles = $videoFiles.Count
  Write-ColorOutput "Found $script:TotalFiles video files (only 'stens staphorst' folder)" -Color Green

  if ($script:TotalFiles -eq 0) {
    Write-ColorOutput "No video files to process" -Color Yellow
    return
  }

  $script:StartTime = Get-Date

  Write-Host ""
  Write-ColorOutput "Starting processing with $script:MaxParallelJobs parallel jobs..." -Color Blue
  Write-Host ""

  # Process videos in parallel
  $videoFiles | ForEach-Object -ThrottleLimit $script:MaxParallelJobs -Parallel {
    # Import variables into parallel scope
    $FolderPath = $using:FolderPath
    $OutputFolder = $using:OutputFolder
    $EnableBlur = $using:BlurTimestamp
    $WATERMARK_FILE = $using:WATERMARK_FILE
    $OUTPUT_WIDTH = $using:OUTPUT_WIDTH
    $OUTPUT_HEIGHT = $using:OUTPUT_HEIGHT
    $CRF_VALUE = $using:CRF_VALUE
    $PRESET = $using:PRESET
    $USE_NVENC = $using:USE_NVENC
    $THREADS_PER_JOB = $using:THREADS_PER_JOB
    $RESUME_LOG = $using:RESUME_LOG
    $TotalFiles = $using:TotalFiles
    $StartTime = $using:StartTime
    $ProcessedCounter = $using:ProcessedCounter
    $SkippedCounter = $using:SkippedCounter
    $FailedCounter = $using:FailedCounter
    $InputSizeCounter = $using:InputSizeCounter
    $OutputSizeCounter = $using:OutputSizeCounter
    $ffmpegCmd = $using:ffmpegCmd
    $ffprobeCmd = $using:ffprobeCmd

    # Re-define functions in parallel scope
    function Write-ColorOutput {
      param([string]$Message, [string]$Color = 'White')
      Write-Host $Message -ForegroundColor $Color
    }

    function Get-FileSize {
      param([string]$FilePath)
      if (Test-Path $FilePath) { return (Get-Item $FilePath).Length }
      return 0
    }

    function Format-FileSize {
      param([long]$Bytes)
      if ($Bytes -lt 1KB) { return "$Bytes B" }
      elseif ($Bytes -lt 1MB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
      elseif ($Bytes -lt 1GB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
      else { return "{0:N2} GB" -f ($Bytes / 1GB) }
    }

    function Format-TimeSpan {
      param([int]$Seconds)
      $hours = [Math]::Floor($Seconds / 3600)
      $minutes = [Math]::Floor(($Seconds % 3600) / 60)
      $secs = $Seconds % 60
      if ($hours -gt 0) { return "${hours}h ${minutes}m ${secs}s" }
      elseif ($minutes -gt 0) { return "${minutes}m ${secs}s" }
      else { return "${secs}s" }
    }

    function Get-VideoResolution {
      param([string]$FilePath)
      try {
        $output = & $ffprobeCmd -v error -select_streams v:0 `
        -show_entries stream=width,height -of csv=s=x:p=0 "$FilePath" 2>&1

        if ($LASTEXITCODE -ne 0 -or -not $output -or $output -notmatch '^\d+x\d+$') {
          throw "Unable to get video resolution"
        }

        return $output
      } catch {
        Write-ColorOutput "Error getting video resolution for ${FilePath}: $_" -Color Red
        return $null
      }
    }

    function Test-VideoFile {
      param([string]$FilePath)

      if (-not (Test-Path $FilePath)) {
        return $false
      }

      # Check if file size is greater than 0
      $fileSize = (Get-Item $FilePath).Length
      if ($fileSize -eq 0) {
        return $false
      }

      # Use ffprobe to validate video file integrity
      $output = & $ffprobeCmd -v error -i "$FilePath" 2>&1

      # If ffprobe returns any error, file is invalid
      if ($LASTEXITCODE -ne 0 -or $output) {
        return $false
      }

      return $true
    }

    function Get-CropCoordinates {
      param([int]$Height)
      if ($Height -eq 720) {
        return @{ Width = 369; Height = 71; X = 41; Y = 617 }
      } elseif ($Height -eq 1080) {
        return @{ Width = 554; Height = 106; X = 62; Y = 926 }
      } else {
        $scale = $Height / 1080.0
        return @{
          Width = [Math]::Floor($scale * 554)
          Height = [Math]::Floor($scale * 106)
          X = [Math]::Floor($scale * 62)
          Y = [Math]::Floor($scale * 926)
        }
      }
    }

    function Get-FilterChain {
      param([hashtable]$CropCoords, [bool]$EnableBlur)
      # Black and white filter - remove all saturation
      $colorFilter = "hue=s=0"
      if ($EnableBlur) {
        return "[0:v]crop=$($CropCoords.Width):$($CropCoords.Height):$($CropCoords.X):$($CropCoords.Y),avgblur=8[fg];[0:v][fg]overlay=$($CropCoords.X):$($CropCoords.Y)[blurred];[blurred]scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT}:flags=fast_bilinear,${colorFilter}[v];[v][1:v]overlay=0:0"
      } else {
        return "[0:v]scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT}:flags=fast_bilinear,${colorFilter}[v];[v][1:v]overlay=0:0"
      }
    }

    function Invoke-VideoEncode {
      param([string]$InputFile, [string]$OutputFile, [bool]$EnableBlur)
      try {
        $resolution = Get-VideoResolution -FilePath $InputFile
        if (-not $resolution) {
          Write-ColorOutput "Failed to get video resolution for: $InputFile" -Color Red
          return $false
        }

        $heightStr = ($resolution -split 'x')[1]
        if (-not $heightStr -or $heightStr -notmatch '^\d+$') {
          Write-ColorOutput "Invalid resolution format: $resolution for file: $InputFile" -Color Red
          return $false
        }

        $height = [int]$heightStr
        $cropCoords = Get-CropCoordinates -Height $height
        $filterComplex = Get-FilterChain -CropCoords $cropCoords -EnableBlur $EnableBlur

        # Use NVENC GPU encoding if requested, otherwise CPU
        if ($USE_NVENC) {
          $encoder = "h264_nvenc"
          $preset = "p4"  # NVENC presets: p1-p7, p4 is balanced
          $hwaccel = @()  # No hardware decode - filters need CPU
          $qualityParam = "-cq"
          $qualityValue = $CRF_VALUE
          $rateControl = @("-rc", "constqp")
        } else {
          $encoder = "libx264"
          $preset = $PRESET
          $hwaccel = @()
          $qualityParam = "-crf"
          $qualityValue = $CRF_VALUE
          $rateControl = @()
        }

        $errorLog = [System.IO.Path]::GetTempFileName()
        $progressLog = [System.IO.Path]::GetTempFileName()

        # Get video duration for progress calculation
        $durationOutput = & $ffprobeCmd -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>&1
        $totalDuration = [double]$durationOutput

        # Build arguments array with properly quoted paths
        $ffmpegArgs = New-Object System.Collections.ArrayList
        $ffmpegArgs.AddRange(@("-nostdin", "-y"))
        if ($hwaccel.Count -gt 0) { $ffmpegArgs.AddRange($hwaccel) }
        $ffmpegArgs.AddRange(@("-progress", "`"$progressLog`"", "-loglevel", "error"))
        if (-not $USE_NVENC) { $ffmpegArgs.AddRange(@("-threads", $THREADS_PER_JOB)) }
        $ffmpegArgs.AddRange(@("-i", "`"$InputFile`"", "-i", "`"$WATERMARK_FILE`""))
        $ffmpegArgs.AddRange(@("-filter_complex", "`"$filterComplex`"", "-c:v", $encoder, "-preset", $preset))
        if ($rateControl.Count -gt 0) { $ffmpegArgs.AddRange($rateControl) }
        $ffmpegArgs.AddRange(@($qualityParam, $qualityValue, "-movflags", "+faststart", "-an", "`"$OutputFile`""))

        # Start ffmpeg with progress output
        $process = Start-Process -FilePath $ffmpegCmd -ArgumentList ($ffmpegArgs -join ' ') -NoNewWindow -PassThru -RedirectStandardError $errorLog        # Monitor progress
        $lastProgress = -1
        while (-not $process.HasExited) {
          Start-Sleep -Milliseconds 500
          if (Test-Path $progressLog) {
            $progressContent = Get-Content $progressLog -Tail 20 -ErrorAction SilentlyContinue
            $timeLine = $progressContent | Where-Object { $_ -match 'out_time_ms=(\d+)' } | Select-Object -Last 1
            if ($timeLine -and $timeLine -match 'out_time_ms=(\d+)') {
              $currentTime = [double]$matches[1] / 1000000  # Convert microseconds to seconds
              if ($totalDuration -gt 0) {
                $percentComplete = [Math]::Min(100, [Math]::Floor(($currentTime / $totalDuration) * 100))
                if ($percentComplete -ne $lastProgress -and $percentComplete -ge 0) {
                  Write-Progress -Id ([System.Threading.Thread]::CurrentThread.ManagedThreadId) -Activity "Encoding: $(Split-Path $InputFile -Leaf)" -Status "$percentComplete% Complete" -PercentComplete $percentComplete
                  $lastProgress = $percentComplete
                }
              }
            }
          }
        }

        $process.WaitForExit()
        Write-Progress -Id ([System.Threading.Thread]::CurrentThread.ManagedThreadId) -Activity "Encoding" -Completed

        Remove-Item $progressLog -ErrorAction SilentlyContinue

        if ($process.ExitCode -eq 0) {
          Remove-Item $errorLog -ErrorAction SilentlyContinue
          return $true
        } else {
          Write-ColorOutput "FFmpeg error details:" -Color Red
          Get-Content $errorLog | Write-Host
          Remove-Item $errorLog -ErrorAction SilentlyContinue
          return $false
        }
      } catch {
        Write-ColorOutput "Fatal error in Invoke-VideoEncode for ${InputFile}: $_" -Color Red
        Remove-Item $errorLog -ErrorAction SilentlyContinue
        Remove-Item $progressLog -ErrorAction SilentlyContinue
        return $false
      }
    }

    # Process the video
    try {
      $File = $_.FullName
      $relativePath = $File.Substring($FolderPath.Length) -replace '^[\\/]+', ''
      $filename = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $fileDir = [System.IO.Path]::GetDirectoryName($relativePath)

    if ($fileDir) {
      $outputDir = Join-Path $OutputFolder $fileDir
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
      $outputFile = Join-Path $outputDir "$filename.resized.mp4"
    } else {
      $outputFile = Join-Path $OutputFolder "$filename.resized.mp4"
    }

    if ((Test-Path $RESUME_LOG) -and (Get-Content $RESUME_LOG -ErrorAction SilentlyContinue | Where-Object { $_ -eq $outputFile })) {
      $timestamp = Get-Date -Format "HH:mm:ss"
      Write-ColorOutput "[$timestamp] Skipping (in resume log): ${File}" -Color Yellow
      $SkippedCounter.Add(1)
      return
    }

    $shouldProcess = $false

    if (Test-Path $outputFile) {
      # File exists, validate it
      if (Test-VideoFile -FilePath $outputFile) {
        # Valid file, skip processing
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] File already exists and is valid. Skipping..." -Color Yellow
        $SkippedCounter.Add(1)
        return
      } else {
        # Invalid/corrupted file, reprocess
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Existing file is invalid/corrupted, reprocessing: ${File}" -Color Yellow
        Remove-Item $outputFile -ErrorAction SilentlyContinue
        $shouldProcess = $true
      }
    } else {
      $shouldProcess = $true
    }

    if ($shouldProcess) {
      $inputSize = Get-FileSize -FilePath $File
      $processedCount = $ProcessedCounter.Count + $SkippedCounter.Count + $FailedCounter.Count
      $remaining = $TotalFiles - $processedCount

      if ($processedCount -gt 0 -and $StartTime) {
        $elapsed = ((Get-Date) - $StartTime).TotalSeconds
        $avgTime = [Math]::Floor($elapsed / $processedCount)
        $eta = $avgTime * $remaining
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Processing $processedCount/${TotalFiles} (ETA: $(Format-TimeSpan $eta)): ${File}" -Color Blue
      } else {
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Processing $processedCount/${TotalFiles}: ${File}" -Color Blue
      }

      if (Invoke-VideoEncode -InputFile $File -OutputFile $outputFile -EnableBlur $EnableBlur) {
        $outputSize = Get-FileSize -FilePath $outputFile
        $InputSizeCounter.Add($inputSize)
        $OutputSizeCounter.Add($outputSize)
        $ProcessedCounter.Add(1)

        $mutex = New-Object System.Threading.Mutex($false, "ShrinkResumeLog")
        $mutex.WaitOne() | Out-Null
        try {
          Add-Content -Path $RESUME_LOG -Value $outputFile
        } finally {
          $mutex.ReleaseMutex()
        }

        $saved = $inputSize - $outputSize
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] Completed: $outputFile (saved $(Format-FileSize $saved))" -Color Green
      } else {
        $FailedCounter.Add(1)
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-ColorOutput "[$timestamp] FAILED: ${File}" -Color Red
      }
    }
  } catch {
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-ColorOutput "[$timestamp] CRITICAL ERROR processing ${File}: $_" -Color Red
    $FailedCounter.Add(1)
  }
  }
}

# Main execution
try {
  # Set up Ctrl+C handler
  $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Host ""
    Write-ColorOutput "Interrupted! Cleaning up..." -Color Yellow
    Write-Summary
  }

  # Check dependencies
  Test-Dependencies

  # Set default output folder if not specified
  if (-not $OutputFolder) {
    $script:OutputFolder = Join-Path $FolderPath "_output"
  } else {
    $script:OutputFolder = $OutputFolder
  }

  # Calculate parallel jobs if not specified
  if ($MaxParallelJobs -le 0) {
    $script:MaxParallelJobs = Get-OptimalParallelJobs
  } else {
    $script:MaxParallelJobs = $MaxParallelJobs
    $cpuCores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ($script:THREADS_PER_JOB -le 0) {
      $script:THREADS_PER_JOB = [Math]::Max(2, [Math]::Floor($cpuCores / $MaxParallelJobs))
    }
    Write-ColorOutput "Using $script:MaxParallelJobs parallel jobs with $($script:THREADS_PER_JOB) threads each (manually specified)" -Color Blue
  }

  # Show encoding settings
  $encoderName = if ($script:USE_NVENC) { "NVENC (GPU)" } else { "libx264 (CPU)" }
  Write-ColorOutput "Encoder: $encoderName, CRF: $script:CRF_VALUE, Preset: $script:PRESET" -Color Blue

  # Validate watermark and setup
  Test-Watermark
  Initialize-Setup

  # Process all videos
  Invoke-ProcessAllVideos

  # Print summary
  Write-Summary

} catch {
  Write-ColorOutput "Error: $_" -Color Red
  Write-ColorOutput $_.ScriptStackTrace -Color Red
  exit 1
} finally {
  Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
}
