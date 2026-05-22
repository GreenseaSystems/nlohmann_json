#!/bin/bash
set -e

####################################################

# Paths
PROJECT_ROOT="$(dirname "$0")"
BUILD_DIR="$PROJECT_ROOT/build"

# Make sure build/ exists
mkdir -p "$BUILD_DIR"

####################################################

# Cmake configure step
echo "Configuring project in $BUILD_DIR"
cmake -S . -B "$BUILD_DIR" \
    -DBUILD_TARGET="GSIQ"  \
    -DCMAKE_INSTALL_PREFIX=/usr/local

####################################################

# Build the package
echo "Packaging project into .deb"
cmake --build "$BUILD_DIR" --target package

# Move deb back to package root; Jenkins can have issues if this isn't done
mv "$BUILD_DIR"/*.deb .

####################################################
