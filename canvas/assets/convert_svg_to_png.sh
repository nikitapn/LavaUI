#!/bin/bash

set -e

if [ $# -eq 0 ]; then
  echo "No arguments supplied"
  exit -1
fi

if [ ! -f "$1" ]; then
  echo "$1 does not exist."
  exit -1
fi

for size in 64 128 256; do
  inkscape \
    --export-area-drawing \
    --export-png-color-mode=RGBA_8 \
    --export-filename="$1_$size.png" \
    --export-width=$size --export-height=$size $1
done
