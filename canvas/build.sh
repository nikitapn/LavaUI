#!/bin/bash

set -e

# Clear the terminal for a fresh build output
clear

. ./common.shi

ninja -C "$BUILD_DIR" -j$(nproc)
echo "Build completed successfully!"

if [ "$1" == "run" ]; then
  echo "Running from $BUILD_DIR"
  cd "$BUILD_DIR" && ./2d
fi