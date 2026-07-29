
#!/bin/bash

BUILD_TYPE=${BUILD_TYPE:-Debug}
BUILD_DIR=".build.${BUILD_TYPE}"

# Map common CMake build type names to Meson equivalents
case "$BUILD_TYPE" in
  Debug)          MESON_BUILDTYPE="debug" ;;
  Release)        MESON_BUILDTYPE="release" ;;
  RelWithDebInfo) MESON_BUILDTYPE="debugoptimized" ;;
  MinSizeRel)     MESON_BUILDTYPE="minsize" ;;
  *)              MESON_BUILDTYPE="debug" ;;
esac

meson setup "$BUILD_DIR" \
  --native-file meson-native.ini \
  --buildtype "$MESON_BUILDTYPE" \
  --reconfigure