# Video Processing Scripts

Collection of video processing scripts for batch conversion, watermarking, resizing, face detection, and privacy protection.

## batch-process-videos-nvenc-watermark-bw.ps1

PowerShell script for batch video processing with NVENC GPU acceleration. Converts videos to 640x360, applies optional watermark overlay, converts to black & white, and optionally blurs timestamps.

```powershell
pwsh -ExecutionPolicy Bypass -File batch-process-videos-nvenc-watermark-bw.ps1 -FolderPath "F:\" -OutputFolder "C:\output" -UseNVENC -CRF 28
```

Optional parameters:
- `-NoWatermark` - Process without watermark overlay
- `-BlurTimestamp` - Enable timestamp blurring
- `-MaxParallelJobs 8` - Set number of parallel encoding jobs

## batch-process-videos-watermark-resize-bw.sh

Bash script for batch video processing. Resizes videos to 640x360, applies watermark, converts to black & white, and optionally blurs timestamps.

```bash
./batch-process-videos-watermark-resize-bw.sh /path/to/videos /path/to/output
```

## batch-resize-videos-with-watermark.sh

Basic bash script for batch resizing videos with watermark overlay. Converts to 640x360 resolution with watermark.

```bash
./batch-resize-videos-with-watermark.sh /path/to/videos
```

## convert-video-blur-timestamp.sh

Converts individual videos while blurring timestamp regions. Useful for removing date/time stamps from camera footage.

```bash
./convert-video-blur-timestamp.sh /path/to/video/folder
```

## scan-videos-detect-faces.sh

Scans videos to detect faces for privacy protection purposes. Outputs detection data for use with blur-faces-in-videos.sh.

```bash
./scan-videos-detect-faces.sh /path/to/videos
```

## blur-faces-in-videos.sh

Blurs or obscures detected faces in videos based on scan data. Requires prior face detection with scan-videos-detect-faces.sh.

```bash
./blur-faces-in-videos.sh /path/to/videos /path/to/scan-data
```

## Requirements

- FFmpeg with NVENC support (for GPU acceleration)
- PowerShell 7+ (for .ps1 scripts)
- Bash (for .sh scripts)
- watermark.png file in the script directory (unless using -NoWatermark)
