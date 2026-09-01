# Video Processing Scripts

Collection of video processing scripts for batch conversion, watermarking, resizing, face detection, and privacy protection.

## batch-process-videos-lowres-logo-color.ps1

PowerShell starter for small "viewable but unusable" previews: 854x480 (480p, 16:9), 15 fps, colour kept, with the Ongehoord logo stamped twice at 35% opacity. Audio is dropped. Prints an input-vs-output size summary so you can check whether the files come out small enough.

FFmpeg is downloaded automatically on first run (checksum-verified, unpacked into `bin\` next to the script, no admin rights, nothing installed system-wide), so this script works on a clean Windows machine with no setup. If the primary source (gyan.dev) is unreachable it falls back to the BtbN build on GitHub, which publishes no checksum; that download cannot be verified and the script warns when it uses it.

```powershell
powershell -ExecutionPolicy Bypass -File batch-process-videos-lowres-logo-color.ps1 -FolderPath "$env:USERPROFILE\Documents\input" -OutputFolder "$env:USERPROFILE\Documents\output"
```

Optional parameters:
- `-CRF 34` - smaller files, lower quality (default 30; higher number = smaller)
- `-Width 854 -Height 480` - output resolution (default 854x480; `-Width 640 -Height 360` for smaller files)
- `-Fps 15` - frame rate (default 15)
- `-Fit pad|crop|stretch` - how to fit the source into the frame (default `pad`, black bars)
- `-WatermarkOpacity 0.25` - logo transparency, 0.0-1.0 (default 0.35)
- `-WatermarkScale 0.5` - logo width as a fraction of video width (default 0.6)
- `-WatermarkFile "C:\path\ongehoord.png"` - logo file (default `watermark.png` next to the script)
- `-KeepAudio` - keep audio (64k mono AAC) instead of dropping it
- `-UseNVENC` - NVIDIA GPU encoding
- `-Force` - re-encode files that already exist in the output folder
- `-NoAutoFetch` - never download FFmpeg; fail with install instructions instead
- `-Verbose` - print the full ffmpeg command line for every file

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

## Running on Windows

`batch-process-videos-lowres-logo-color.ps1` fetches its own dependencies, so on a clean machine this is the whole setup:

1. **Download the scripts** - open https://github.com/dipodidae/video-scan in your browser, click the green **Code** button, then **Download ZIP**. The file lands in your `Downloads` folder as `video-scan-main.zip`.

   Unzip it: right-click the ZIP in File Explorer, choose **Extract All...**, then **Extract**. You now have a folder like `$env:USERPROFILE\Downloads\video-scan-main\video-scan-main` containing the scripts and `watermark.png` (the Ongehoord logo). Everything must stay together in that one folder.

   > Running the scripts straight from inside the ZIP does not work - Windows needs them extracted first.

2. **Open PowerShell in that folder** - in File Explorer, open the extracted folder so you see `batch-process-videos-lowres-logo-color.ps1` in it, then:

   - **Windows 11**: right-click on an empty spot in the folder and choose **Open in Terminal**.
   - **Windows 10**: hold **Shift**, right-click on an empty spot, and choose **Open PowerShell window here**.

   No such menu item? Press the **Windows key**, type `powershell`, press **Enter**, and then move to the folder by typing `cd ` (with a space) followed by the folder path, for example:
   ```powershell
   cd "$env:USERPROFILE\Downloads\video-scan-main\video-scan-main"
   ```
   You can get that path by clicking the address bar in File Explorer and copying it. Paste into PowerShell with a right-click.

   Check you are in the right place - this should list the script:
   ```powershell
   dir *.ps1
   ```

3. **Run it** - paste this in, adjusting the two folders, and press **Enter**:
   ```powershell
   powershell -ExecutionPolicy Bypass -File batch-process-videos-lowres-logo-color.ps1 -FolderPath "$env:USERPROFILE\Documents\input" -OutputFolder "$env:USERPROFILE\Documents\output"
   ```

   **Check both paths before running.** `$env:USERPROFILE` is filled in by PowerShell with your own user folder (`C:\Users\your-name`), so there is no user name to edit - but the input folder has to be where your videos actually are, and it has to exist.

   - `-FolderPath` is the folder holding your original videos. Point it wherever they actually are: `$env:USERPROFILE\Documents\input` if you copied them there first, or something like `F:\` for a memory card or external drive.
   - `-OutputFolder` is where the small previews are written. It is created for you if it does not exist yet, and it must not be the same folder as the input.

   On the first run it reports `FFmpeg not found - fetching it now (one-off, ~80 MB)`, downloads a static build, verifies its SHA-256 checksum and unpacks `ffmpeg.exe` into `bin\` (the GitHub fallback source has no published checksum and is flagged as unverified). Later runs reuse it. If FFmpeg is already on your PATH that is used instead and nothing is downloaded.

4. **Watch the output** - the script prints its settings, then a line per file:
   ```
   [3/57] DCIM\clip.mp4 ... 1.2 GB -> 18.4 MB (1.5%) in 42s | ETA 18m
   ```
   `-FolderPath` is searched recursively; the folder structure is mirrored in the output folder and everything is written as `.mp4`. Files that already exist are skipped, so you can stop with Ctrl+C and start again later.

5. **Check the sizes** - the summary at the end shows total input vs output size and the average per file. Too big? Run again on a test folder with `-CRF 34`, or a smaller `-Width`/`-Height`.

Notes:

- Prefer git? `git clone https://github.com/dipodidae/video-scan.git` then `cd video-scan` replaces steps 1 and 2.
- Windows PowerShell 5.1 (which ships with Windows) is enough for this script. The other `.ps1` scripts in this repo want PowerShell 7: `winget install Microsoft.PowerShell`, then use `pwsh` instead of `powershell`.
- To install FFmpeg yourself instead, run `winget install Gyan.FFmpeg`, or download a build from https://www.gyan.dev/ffmpeg/builds/ and copy `ffmpeg.exe` and `ffprobe.exe` into a `bin` folder next to the scripts. Pass `-NoAutoFetch` to make the script refuse to download anything.
- If PowerShell blocks the script, it was flagged as downloaded from the internet: `Unblock-File .\batch-process-videos-lowres-logo-color.ps1`.

## Requirements

- FFmpeg with NVENC support (for GPU acceleration) - `batch-process-videos-lowres-logo-color.ps1` downloads it for you if missing
- PowerShell 7+ (for .ps1 scripts, except `batch-process-videos-lowres-logo-color.ps1` which runs on 5.1)
- Bash (for .sh scripts)
- watermark.png file in the script directory (unless using -NoWatermark)
