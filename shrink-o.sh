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

output_folder="$folder_path/_output"
if [[ ! -d $output_folder ]]; then
  mkdir $output_folder
fi

for file in "$folder_path"/*.{avi,mov,mpeg,mkv,wmv,m4a,m4v,mp4}; do
  if [[ -f $file ]]; then
    filename=$(basename -- "$file")
    extension="${filename##*.}"
    filename="${filename%.*}"

    # Output file
    output_file="$output_folder/$filename.resized.mp4"

    # Convert the file
    if [[ ! -f "$output_file" ]]; then

      ffmpeg \
        -i "${file}" \
        -i watermark.png \
        -filter_complex "\
          [0:v]crop=347:30:1557:33,avgblur=15[fg];\
          [0:v][fg]overlay=1557:33[blurredTimestamp];\
          [blurredTimestamp]hflip,vflip,scale=640:360,colorchannelmixer=.3:.4:.3:0:.3:.4:.3:0:.3:.4:.3[blurredTimestamp];\
          [blurredTimestamp][1:v]overlay=0:0\
        " \
        -c:v libx264 \
        -crf 23 \
        -preset medium \
        -profile:v baseline \
        -level 3.0 \
        -an \
        "${output_file}"
    else
      echo "File $output_file already exists. Skipping..."
    fi
  fi
done

echo "All video files in $folder_path have been converted to MP4 format and saved to $output_folder."
