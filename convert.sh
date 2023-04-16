#!/bin/bash

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 folder_path"
  exit 1
fi

folder_path=$1

if [[ ! -d $folder_path ]]; then
  echo "Error: $folder_path is not a directory"
  exit 1
fi

for file in "$folder_path"/*.{avi,mov,mpeg,mkv,wmv,m4a,m4v}; do
  filename=$(basename -- "$file")
  extension="${filename##*.}"
  filename="${filename%.*}"

  # Output file
  output_file="$folder_path/$filename.mp4"

  # Convert the file
  if [[ -f $file ]] && [[ ! -f "$output_file" ]]; then
    ffmpeg -i "${file}" \
      -filter_complex "[0:v]crop=554:106:62:926,avgblur=15[fg];[0:v][fg]overlay=62:926[v]" \
      -map "[v]" \
      -c:v libx264 \
      -crf 23 \
      -preset medium \
      -profile:v baseline \
      -level 3.0 \
      -an \
      "${output_file}"
  fi
done

echo "All video files in $folder_path have been converted to MP4 format."
