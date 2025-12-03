#!/bin/bash
set -euo pipefail
#
# Video processing script with watermark, resizing, and color correction.
# Processes videos recursively with optional timestamp blur.

# Constants
readonly WATERMARK_FILE="watermark.png"
readonly OUTPUT_WIDTH=640
readonly OUTPUT_HEIGHT=360
readonly CRF_VALUE=23
readonly RESUME_LOG=".shrink_resume.log"

# Color codes for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# Tracking variables
total_files=0
processed_files=0
skipped_files=0
failed_files=0
total_input_size=0
total_output_size=0
start_time=0

#######################################
# Display usage information.
# Outputs:
#   Writes usage to stderr
#######################################
usage() {
  echo "Usage: $0 [-b] folder_path [output_folder] [max_parallel_jobs]" >&2
  echo "  -b: Blur timestamp in videos (optional)" >&2
}

#######################################
# Check if required dependencies are installed.
# Outputs:
#   Writes errors to stderr
# Returns:
#   0 if all dependencies present, exits with 1 otherwise
#######################################
check_dependencies() {
  local -a missing_deps=()
  local -a required_commands=("ffmpeg" "ffprobe" "bc" "nproc" "find" "xargs")

  for cmd in "${required_commands[@]}"; do
    if ! command -v "${cmd}" &> /dev/null; then
      missing_deps+=("${cmd}")
    fi
  done

  if (( ${#missing_deps[@]} > 0 )); then
    echo -e "${COLOR_RED}Error: Missing required dependencies:${COLOR_RESET}" >&2
    printf '  - %s\n' "${missing_deps[@]}" >&2
    echo "Please install them and try again." >&2
    exit 1
  fi
}

#######################################
# Validate that watermark file exists.
# Globals:
#   WATERMARK_FILE
# Outputs:
#   Writes errors to stderr
# Returns:
#   0 if watermark exists, exits with 1 otherwise
#######################################
validate_watermark() {
  if [[ ! -f "${WATERMARK_FILE}" ]]; then
    echo -e "${COLOR_RED}Error: Watermark file '${WATERMARK_FILE}' not found${COLOR_RESET}" >&2
    echo "Please ensure the watermark file exists in the current directory." >&2
    exit 1
  fi
}

#######################################
# Parse command-line arguments.
# Globals:
#   blur_timestamp
#   folder_path
#   output_folder
#   max_jobs
# Arguments:
#   All command-line arguments
# Outputs:
#   Writes messages to stdout/stderr
# Returns:
#   0 on success, exits on error
#######################################
parse_arguments() {
  # Parse command-line options
  blur_timestamp='false'
  while getopts "b" opt; do
    case "${opt}" in
      b) blur_timestamp='true' ;;
      *)
        usage
        exit 1
        ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  if (( $# < 1 || $# > 3 )); then
    usage
    exit 1
  fi

  folder_path="$1"
  output_folder="${2:-${folder_path}/_output}"

  # Calculate parallel jobs
  if [[ -z "${3:-}" ]]; then
    max_jobs="$(calculate_parallel_jobs)"
  else
    max_jobs="$3"
    echo "Using ${max_jobs} parallel jobs (manually specified)"
  fi
}

#######################################
# Calculate optimal number of parallel jobs based on CPU cores.
# Outputs:
#   Writes number of parallel jobs to stdout
#   Writes informational message to stdout
# Returns:
#   Number of parallel jobs
#######################################
calculate_parallel_jobs() {
  # Get number of CPU cores
  local -i cpu_cores
  cpu_cores="$(nproc)"

  # Use fewer jobs to give each ffmpeg process more CPU threads
  # This is more efficient for video encoding than many parallel jobs
  local -i jobs
  jobs=$(( cpu_cores / 4 ))

  # Ensure at least 1 job
  (( jobs = jobs > 0 ? jobs : 1 ))

  echo "Auto-detected ${cpu_cores} CPU cores, using ${jobs} parallel jobs" >&2
  echo "${jobs}"
}

#######################################
# Validate input and create output directories.
# Globals:
#   folder_path
#   output_folder
# Outputs:
#   Writes errors to stderr
# Returns:
#   0 on success, exits on error
#######################################
validate_and_setup() {
  if [[ ! -d "${folder_path}" ]]; then
    echo -e "${COLOR_RED}Error: ${folder_path} is not a directory${COLOR_RESET}" >&2
    exit 1
  fi

  if [[ ! -d "${output_folder}" ]]; then
    mkdir -p "${output_folder}"
  fi
}

#######################################
# Cleanup handler for graceful shutdown.
# Globals:
#   COLOR_YELLOW
#   COLOR_RESET
# Outputs:
#   Writes cleanup message to stderr
#######################################
cleanup() {
  echo "" >&2
  echo -e "${COLOR_YELLOW}Interrupted! Cleaning up...${COLOR_RESET}" >&2
  print_summary
  exit 130
}

#######################################
# Get file size in bytes.
# Arguments:
#   File path
# Outputs:
#   File size in bytes to stdout
#######################################
get_file_size() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    stat -c%s "${file}" 2>/dev/null || stat -f%z "${file}" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

#######################################
# Format bytes to human-readable size.
# Arguments:
#   Size in bytes
# Outputs:
#   Human-readable size to stdout
#######################################
format_size() {
  local -i bytes="$1"
  if (( bytes < 1024 )); then
    echo "${bytes}B"
  elif (( bytes < 1048576 )); then
    echo "$(( bytes / 1024 ))KB"
  elif (( bytes < 1073741824 )); then
    echo "$(( bytes / 1048576 ))MB"
  else
    echo "$(( bytes / 1073741824 ))GB"
  fi
}

#######################################
# Format seconds to human-readable time.
# Arguments:
#   Seconds
# Outputs:
#   Human-readable time to stdout
#######################################
format_time() {
  local -i total_seconds="$1"
  local -i hours minutes seconds
  hours=$(( total_seconds / 3600 ))
  minutes=$(( (total_seconds % 3600) / 60 ))
  seconds=$(( total_seconds % 60 ))

  if (( hours > 0 )); then
    printf "%dh %dm %ds" "${hours}" "${minutes}" "${seconds}"
  elif (( minutes > 0 )); then
    printf "%dm %ds" "${minutes}" "${seconds}"
  else
    printf "%ds" "${seconds}"
  fi
}

#######################################
# Print final summary statistics.
# Globals:
#   total_files
#   processed_files
#   skipped_files
#   failed_files
#   total_input_size
#   total_output_size
#   start_time
#   COLOR_*
# Outputs:
#   Summary report to stdout
#######################################
print_summary() {
  local -i elapsed
  elapsed=$(( $(date +%s) - start_time ))
  local -i saved_space
  saved_space=$(( total_input_size - total_output_size ))

  echo ""
  echo -e "${COLOR_BLUE}═══════════════════════════════════════════${COLOR_RESET}"
  echo -e "${COLOR_BLUE}           PROCESSING SUMMARY${COLOR_RESET}"
  echo -e "${COLOR_BLUE}═══════════════════════════════════════════${COLOR_RESET}"
  echo -e "Total files found:    ${total_files}"
  echo -e "${COLOR_GREEN}Successfully processed: ${processed_files}${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}Skipped (existing):   ${skipped_files}${COLOR_RESET}"
  if (( failed_files > 0 )); then
    echo -e "${COLOR_RED}Failed:               ${failed_files}${COLOR_RESET}"
  fi
  echo ""
  if (( total_input_size > 0 )); then
    echo -e "Total input size:     $(format_size "${total_input_size}")"
    echo -e "Total output size:    $(format_size "${total_output_size}")"
    echo -e "${COLOR_GREEN}Space saved:          $(format_size "${saved_space}")${COLOR_RESET}"
    local -i compression_ratio
    compression_ratio=$(( (saved_space * 100) / total_input_size ))
    echo -e "Compression ratio:    ${compression_ratio}%"
    echo ""
  fi
  echo -e "Time elapsed:         $(format_time "${elapsed}")"
  if (( processed_files > 0 )); then
    local -i avg_time
    avg_time=$(( elapsed / processed_files ))
    echo -e "Average per file:     $(format_time "${avg_time}")"
  fi
  echo -e "${COLOR_BLUE}═══════════════════════════════════════════${COLOR_RESET}"
}

#######################################
# Process a single video file with watermark and transformations.
# Globals:
#   WATERMARK_FILE
#   OUTPUT_WIDTH
#   OUTPUT_HEIGHT
#   CRF_VALUE
#   processed_files
#   skipped_files
#   failed_files
#   total_files
#   total_input_size
#   total_output_size
#   start_time
#   RESUME_LOG
#   COLOR_*
# Arguments:
#   File path to process
#   Input folder path
#   Output folder path
#   Blur timestamp flag (true/false)
# Outputs:
#   Writes progress to stdout
#   Writes errors to stderr
# Returns:
#   0 on success, non-zero on error
#######################################
process_video() {
  local file="$1"
  local folder_path="$2"
  local output_folder="$3"
  local blur_timestamp="$4"

  # Get relative path from input folder
  local relative_path="${file#"${folder_path}"/}"
  local filename
  filename="$(basename -- "${file}")"
  filename="${filename%.*}"

  # Preserve directory structure in output
  local file_dir
  file_dir="$(dirname "${relative_path}")"
  local output_file
  if [[ "${file_dir}" != "." ]]; then
    mkdir -p "${output_folder}/${file_dir}"
    output_file="${output_folder}/${file_dir}/${filename}.resized.mp4"
  else
    output_file="${output_folder}/${filename}.resized.mp4"
  fi

  # Check if already processed in resume log
  if [[ -f "${RESUME_LOG}" ]] && grep -Fxq "${output_file}" "${RESUME_LOG}"; then
    echo -e "${COLOR_YELLOW}[$(date '+%H:%M:%S')] Skipping (in resume log): ${file}${COLOR_RESET}"
    (( skipped_files++ )) || true
    return 0
  fi

  # Convert the file
  if [[ ! -f "${output_file}" ]]; then
    local input_size
    input_size="$(get_file_size "${file}")"

    local -i processed_count remaining eta
    (( processed_count = processed_files + skipped_files + failed_files ))
    (( remaining = total_files - processed_count ))

    # Calculate ETA
    if (( processed_count > 0 && start_time > 0 )); then
      local -i elapsed avg_time
      elapsed=$(( $(date +%s) - start_time ))
      avg_time=$(( elapsed / processed_count ))
      eta=$(( avg_time * remaining ))
      echo -e "${COLOR_BLUE}[$(date '+%H:%M:%S')] Processing ${processed_count}/${total_files} (ETA: $(format_time "${eta}")): ${file}${COLOR_RESET}"
    else
      echo -e "${COLOR_BLUE}[$(date '+%H:%M:%S')] Processing ${processed_count}/${total_files}: ${file}${COLOR_RESET}"
    fi

    if encode_video "${file}" "${output_file}" "${blur_timestamp}"; then
      local output_size
      output_size="$(get_file_size "${output_file}")"
      (( total_input_size += input_size )) || true
      (( total_output_size += output_size )) || true
      (( processed_files++ )) || true
      echo "${output_file}" >> "${RESUME_LOG}"

      local saved
      saved=$(( input_size - output_size ))
      echo -e "${COLOR_GREEN}[$(date '+%H:%M:%S')] Completed: ${output_file} (saved $(format_size "${saved}"))${COLOR_RESET}"
    else
      (( failed_files++ )) || true
      echo -e "${COLOR_RED}[$(date '+%H:%M:%S')] FAILED: ${file}${COLOR_RESET}" >&2
    fi
  else
    echo -e "${COLOR_YELLOW}[$(date '+%H:%M:%S')] File ${output_file} already exists. Skipping...${COLOR_RESET}"
    (( skipped_files++ )) || true
  fi
}

#######################################
# Get video resolution.
# Arguments:
#   Video file path
# Outputs:
#   Writes "widthxheight" to stdout
#######################################
get_video_resolution() {
  local file="$1"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=s=x:p=0 "${file}"
}

#######################################
# Calculate crop coordinates based on video height.
# Arguments:
#   Video height in pixels
# Outputs:
#   Writes "width:height:x:y" to stdout
#######################################
calculate_crop_coordinates() {
  local -i height="$1"
  local -i crop_w crop_h crop_x crop_y

  if (( height == 720 )); then
    # 720p: scale coordinates by 720/1080 = 0.667
    crop_w=369
    crop_h=71
    crop_x=41
    crop_y=617
  elif (( height == 1080 )); then
    # 1080p: use original coordinates
    crop_w=554
    crop_h=106
    crop_x=62
    crop_y=926
  else
    # For other resolutions, scale proportionally to height
    local scale
    scale="$(echo "scale=4; ${height}/1080" | bc)"
    crop_w="$(echo "${scale} * 554 / 1" | bc)"
    crop_h="$(echo "${scale} * 106 / 1" | bc)"
    crop_x="$(echo "${scale} * 62 / 1" | bc)"
    crop_y="$(echo "${scale} * 926 / 1" | bc)"
  fi

  echo "${crop_w}:${crop_h}:${crop_x}:${crop_y}"
}

#######################################
# Build ffmpeg filter chain.
# Globals:
#   OUTPUT_WIDTH
#   OUTPUT_HEIGHT
# Arguments:
#   Crop coordinates (width:height:x:y)
#   Blur timestamp flag (true/false)
# Outputs:
#   Writes filter_complex string to stdout
#######################################
build_filter_chain() {
  local crop_coords="$1"
  local blur_timestamp="$2"

  # Color channel mixer applied to all videos
  local color_filter="colorchannelmixer=.3:.4:.3:0:.3:.4:.3:0:.3:.4:.3"

  # Parse crop coordinates
  local crop_w crop_h crop_x crop_y
  IFS=':' read -r crop_w crop_h crop_x crop_y <<< "${crop_coords}"

  # Build filter based on blur_timestamp flag
  if [[ "${blur_timestamp}" == "true" ]]; then
    echo "[0:v]crop=${crop_w}:${crop_h}:${crop_x}:${crop_y},avgblur=15[fg];[0:v][fg]overlay=${crop_x}:${crop_y}[blurredTimestamp];[blurredTimestamp]scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT},${color_filter}[processed];[processed][1:v]overlay=0:0"
  else
    echo "[0:v]scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT},${color_filter}[processed];[processed][1:v]overlay=0:0"
  fi
}

#######################################
# Encode a video file with ffmpeg.
# Globals:
#   WATERMARK_FILE
#   CRF_VALUE
# Arguments:
#   Input file path
#   Output file path
#   Blur timestamp flag (true/false)
# Outputs:
#   Writes progress to stdout
#   Writes errors to stderr
# Returns:
#   0 on success, non-zero on error
#######################################
encode_video() {
  local file="$1"
  local output_file="$2"
  local blur_timestamp="$3"

  # Get video resolution
  local resolution
  resolution="$(get_video_resolution "${file}")"
  local -i height
  height="$(echo "${resolution}" | cut -d'x' -f2)"

  # Calculate crop coordinates
  local crop_coords
  crop_coords="$(calculate_crop_coordinates "${height}")"

  echo "[$(date '+%H:%M:%S')] Processing: ${file}"

  # Use CPU encoding for reliability with parallel processing
  # NVENC has concurrent session limits that cause failures with many parallel jobs
  local hw_encoder="libx264"
  local hw_preset="veryfast"

  # Build filter chain
  local filter_complex
  filter_complex="$(build_filter_chain "${crop_coords}" "${blur_timestamp}")"

  local error_log
  error_log="$(mktemp)"

  ffmpeg \
    -nostdin \
    -y \
    -loglevel error \
    -threads 0 \
    -i "${file}" \
    -i "${WATERMARK_FILE}" \
    -filter_complex "${filter_complex}" \
    -c:v "${hw_encoder}" \
    -preset "${hw_preset}" \
    -crf "${CRF_VALUE}" \
    -profile:v baseline \
    -level 3.0 \
    -movflags +faststart \
    -an \
    "${output_file}" 2> "${error_log}"

  local exit_code=$?
  if (( exit_code == 0 )); then
    rm -f "${error_log}"
    return 0
  else
    echo -e "${COLOR_RED}FFmpeg error details:${COLOR_RESET}" >&2
    cat "${error_log}" >&2
    rm -f "${error_log}"
    return 1
  fi
}

#######################################
# Process all video files in parallel.
# Globals:
#   folder_path
#   output_folder
#   blur_timestamp
#   max_jobs
#   total_files
#   start_time
#   WATERMARK_FILE
#   OUTPUT_WIDTH
#   OUTPUT_HEIGHT
#   CRF_VALUE
#   RESUME_LOG
#   COLOR_*
# Outputs:
#   Writes completion message to stdout
#######################################
process_all_videos() {
  # Count total files first
  echo -e "${COLOR_BLUE}Scanning for video files...${COLOR_RESET}"
  total_files=$(find "${folder_path}" -type f \
    \( -iname "*.avi" \
    -o -iname "*.mov" \
    -o -iname "*.mpeg" \
    -o -iname "*.mkv" \
    -o -iname "*.wmv" \
    -o -iname "*.m4a" \
    -o -iname "*.m4v" \
    -o -iname "*.mp4" \) \
    | wc -l)

  echo -e "${COLOR_GREEN}Found ${total_files} video files${COLOR_RESET}"

  if (( total_files == 0 )); then
    echo -e "${COLOR_YELLOW}No video files to process${COLOR_RESET}"
    return 0
  fi

  start_time=$(date +%s)

  # Export functions and variables for parallel execution
  export -f process_video
  export -f encode_video
  export -f get_video_resolution
  export -f calculate_crop_coordinates
  export -f build_filter_chain
  export -f get_file_size
  export -f format_size
  export -f format_time
  export folder_path
  export output_folder
  export blur_timestamp
  export total_files
  export processed_files
  export skipped_files
  export failed_files
  export total_input_size
  export total_output_size
  export start_time
  export WATERMARK_FILE
  export OUTPUT_WIDTH
  export OUTPUT_HEIGHT
  export CRF_VALUE
  export RESUME_LOG
  export COLOR_RED
  export COLOR_GREEN
  export COLOR_YELLOW
  export COLOR_BLUE
  export COLOR_RESET

  echo ""
  echo -e "${COLOR_BLUE}Starting processing with ${max_jobs} parallel jobs...${COLOR_RESET}"
  echo ""

  # Find all video files and process them in parallel
  find "${folder_path}" -type f \
    \( -iname "*.avi" \
    -o -iname "*.mov" \
    -o -iname "*.mpeg" \
    -o -iname "*.mkv" \
    -o -iname "*.wmv" \
    -o -iname "*.m4a" \
    -o -iname "*.m4v" \
    -o -iname "*.mp4" \) \
    -print0 \
    | xargs -0 -P "${max_jobs}" -I {} \
      bash -c 'process_video "$@"' _ {} "${folder_path}" "${output_folder}" "${blur_timestamp}"
}

#######################################
# Main execution function.
# Arguments:
#   All command-line arguments
#######################################
main() {
  # Set up signal handlers
  trap cleanup SIGINT SIGTERM

  # Check dependencies first
  check_dependencies

  # Parse arguments
  parse_arguments "$@"

  # Validate watermark and setup
  validate_watermark
  validate_and_setup

  # Process all videos
  process_all_videos

  # Print summary
  print_summary
}

main "$@"
