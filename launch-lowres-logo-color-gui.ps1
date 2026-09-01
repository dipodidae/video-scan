#Requires -Version 5.1
<#
.SYNOPSIS
Folder-picker window for batch-process-videos-lowres-logo-color.ps1.

.DESCRIPTION
Shows a small window with two folder pickers - one for the input folder, one for the
output folder - and then runs the processing script in this console window, so you keep
the usual per-file progress output. The output picker can create a new folder; the input
picker cannot, so you can only ever point it at footage that already exists.

Two ways to use this:
  - keep it in the same folder as batch-process-videos-lowres-logo-color.ps1 and run it
  - compile it with build\build-exe.ps1, which bakes the processing script and the logo
    into a standalone .exe that needs neither file next to it

FFmpeg is still fetched by the processing script itself on first run.

.EXAMPLE
.\launch-lowres-logo-color-gui.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# build\build-exe.ps1 replaces these two placeholders with gzipped, base64-encoded copies
# of the processing script and the logo. Left as placeholders - which is how they are
# stored in git - the launcher uses the files next to it instead.
$script:PAYLOAD_SCRIPT = '@@PAYLOAD_SCRIPT@@'
$script:PAYLOAD_WATERMARK = '@@PAYLOAD_WATERMARK@@'

$script:PROCESSING_SCRIPT_NAME = 'batch-process-videos-lowres-logo-color.ps1'
$script:WATERMARK_NAME = 'watermark.png'

# The processing script caches its FFmpeg download in a "bin" folder next to itself, so
# the embedded copies are unpacked to a stable per-user folder rather than to a temporary
# one - otherwise every run would download FFmpeg again.
$script:UNPACK_DIR = Join-Path $env:LOCALAPPDATA 'video-scan'

function Test-Payload {
  param([string]$Payload)

  return [bool]$Payload -and -not $Payload.StartsWith('@@')
}

function Expand-Payload {
  param(
    [Parameter(Mandatory = $true)][string]$Payload,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $compressed = New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($Payload))
  $expanded = New-Object System.IO.MemoryStream
  try {
    $gzip = New-Object System.IO.Compression.GZipStream($compressed, [System.IO.Compression.CompressionMode]::Decompress)
    try {
      $gzip.CopyTo($expanded)
    }
    finally {
      $gzip.Dispose()
    }
    [System.IO.File]::WriteAllBytes($Destination, $expanded.ToArray())
  }
  finally {
    $expanded.Dispose()
    $compressed.Dispose()
  }
}

function Get-LauncherRoot {
  if ($PSScriptRoot) {
    return $PSScriptRoot
  }

  # PS2EXE leaves $PSScriptRoot empty and offers $ScriptRoot instead.
  $compiledRoot = Get-Variable -Name 'ScriptRoot' -ValueOnly -ErrorAction SilentlyContinue
  if ($compiledRoot) {
    return $compiledRoot
  }

  return (Get-Location).Path
}

function Resolve-ProcessingScript {
  if (Test-Payload $script:PAYLOAD_SCRIPT) {
    if (-not (Test-Path -LiteralPath $script:UNPACK_DIR)) {
      New-Item -ItemType Directory -Path $script:UNPACK_DIR -Force | Out-Null
    }

    $unpacked = Join-Path $script:UNPACK_DIR $script:PROCESSING_SCRIPT_NAME
    Expand-Payload -Payload $script:PAYLOAD_SCRIPT -Destination $unpacked

    if (Test-Payload $script:PAYLOAD_WATERMARK) {
      Expand-Payload -Payload $script:PAYLOAD_WATERMARK -Destination (Join-Path $script:UNPACK_DIR $script:WATERMARK_NAME)
    }

    return $unpacked
  }

  $sibling = Join-Path (Get-LauncherRoot) $script:PROCESSING_SCRIPT_NAME
  if (Test-Path -LiteralPath $sibling) {
    return $sibling
  }

  throw "Cannot find $($script:PROCESSING_SCRIPT_NAME). Keep this launcher in the same folder as the processing script, or use the compiled .exe."
}

function Show-Warning {
  param([Parameter(Mandatory = $true)][string]$Message)

  [void][System.Windows.Forms.MessageBox]::Show(
    $Message,
    'Low-res logo preview',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Select-Folder {
  param(
    [Parameter(Mandatory = $true)][string]$Description,
    [string]$StartPath,
    [switch]$AllowCreate
  )

  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  try {
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = [bool]$AllowCreate
    if ($StartPath -and (Test-Path -LiteralPath $StartPath)) {
      $dialog.SelectedPath = $StartPath
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      return $dialog.SelectedPath
    }

    return $null
  }
  finally {
    $dialog.Dispose()
  }
}

function New-Label {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][int]$Top,
    [switch]$Muted
  )

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point(12, $Top)
  $label.Size = New-Object System.Drawing.Size(520, 18)
  $label.AutoSize = $false
  if ($Muted) {
    $label.ForeColor = [System.Drawing.SystemColors]::GrayText
  }

  return $label
}

function New-PathBox {
  param([Parameter(Mandatory = $true)][int]$Top)

  $box = New-Object System.Windows.Forms.TextBox
  $box.Location = New-Object System.Drawing.Point(12, $Top)
  $box.Size = New-Object System.Drawing.Size(420, 23)

  return $box
}

function New-BrowseButton {
  param([Parameter(Mandatory = $true)][int]$Top)

  $button = New-Object System.Windows.Forms.Button
  $button.Text = 'Browse...'
  $button.Location = New-Object System.Drawing.Point(440, $Top)
  $button.Size = New-Object System.Drawing.Size(92, 25)

  return $button
}

function Request-Folders {
  $documents = Join-Path $env:USERPROFILE 'Documents'

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Low-res logo preview'
  $form.ClientSize = New-Object System.Drawing.Size(544, 226)
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false

  $inputBox = New-PathBox -Top 32
  $inputBrowse = New-BrowseButton -Top 31
  $outputBox = New-PathBox -Top 96
  $outputBrowse = New-BrowseButton -Top 95

  $inputBrowse.Add_Click({
      $start = if ($inputBox.Text) { $inputBox.Text } else { $documents }
      $picked = Select-Folder -Description 'Pick the folder with the videos to convert.' -StartPath $start
      if ($picked) {
        $inputBox.Text = $picked
        if (-not $outputBox.Text) {
          $outputBox.Text = Join-Path $picked '_output'
        }
      }
    })

  $outputBrowse.Add_Click({
      $start = if ($outputBox.Text) { Split-Path -Path $outputBox.Text -Parent } else { $documents }
      $picked = Select-Folder -Description 'Pick or create the folder for the previews.' -StartPath $start -AllowCreate
      if ($picked) {
        $outputBox.Text = $picked
      }
    })

  $startButton = New-Object System.Windows.Forms.Button
  $startButton.Text = 'Start'
  $startButton.Location = New-Object System.Drawing.Point(348, 186)
  $startButton.Size = New-Object System.Drawing.Size(90, 28)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = 'Cancel'
  $cancelButton.Location = New-Object System.Drawing.Point(444, 186)
  $cancelButton.Size = New-Object System.Drawing.Size(88, 28)
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

  $startButton.Add_Click({
      $inputFolder = $inputBox.Text.Trim()
      $outputFolder = $outputBox.Text.Trim()

      if (-not $inputFolder) {
        Show-Warning 'Pick an input folder first.'
        return
      }
      if (-not (Test-Path -LiteralPath $inputFolder -PathType Container)) {
        Show-Warning "That input folder does not exist:`n`n$inputFolder"
        return
      }

      $form.Tag = [pscustomobject]@{
        InputFolder  = $inputFolder
        OutputFolder = $outputFolder
      }
      $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })

  $form.Controls.AddRange(@(
    (New-Label -Text 'Input folder - the videos to convert (searched recursively)' -Top 10),
      $inputBox,
      $inputBrowse,
    (New-Label -Text 'Output folder - where the previews go' -Top 74),
      $outputBox,
      $outputBrowse,
    (New-Label -Text 'The output picker can create a new folder. Leave it empty to use <input folder>\_output.' -Top 128 -Muted),
    (New-Label -Text 'Everything else uses the defaults: 854x480, 15 fps, CRF 30, logo at 35% over the picture.' -Top 148 -Muted),
      $startButton,
      $cancelButton
    ))

  $form.AcceptButton = $startButton
  $form.CancelButton = $cancelButton

  try {
    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      return $form.Tag
    }

    return $null
  }
  finally {
    $form.Dispose()
  }
}

function Format-Argument {
  param([Parameter(Mandatory = $true)][string]$Value)

  # A path ending in a backslash ("F:\") would escape the closing quote when the child
  # process parses its command line, so any trailing run of backslashes is doubled.
  $escaped = $Value -replace '(\\+)$', '$1$1'

  return '"' + $escaped + '"'
}

function Invoke-ProcessingScript {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$InputFolder,
    [string]$OutputFolder
  )

  # Run it as a child process sharing this console: that keeps the colours and the
  # progress bar of the processing script intact, which capturing its output would not.
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arguments = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', (Format-Argument $ScriptPath)
    '-FolderPath', (Format-Argument $InputFolder)
  )
  if ($OutputFolder) {
    $arguments += @('-OutputFolder', (Format-Argument $OutputFolder))
  }

  $process = Start-Process -FilePath $powershell -ArgumentList $arguments -NoNewWindow -Wait -PassThru

  return $process.ExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
  $processingScript = Resolve-ProcessingScript

  $selection = Request-Folders
  if (-not $selection) {
    Write-Host 'Cancelled.' -ForegroundColor DarkGray
    exit 0
  }

  $exitCode = Invoke-ProcessingScript -ScriptPath $processingScript -InputFolder $selection.InputFolder -OutputFolder $selection.OutputFolder

  Write-Host ''
  if ($exitCode -eq 0) {
    Write-Host 'Finished.' -ForegroundColor Green
  }
  else {
    Write-Host "The processing script stopped with exit code $exitCode - see the messages above." -ForegroundColor Red
  }

  [void](Read-Host 'Press Enter to close this window')
  exit $exitCode
}
catch {
  $message = $_.Exception.Message
  Write-Host "Error: $message" -ForegroundColor Red
  [void][System.Windows.Forms.MessageBox]::Show(
    $message,
    'Low-res logo preview',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error)
  exit 1
}
