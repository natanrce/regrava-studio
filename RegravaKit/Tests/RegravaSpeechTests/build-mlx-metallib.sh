#!/bin/sh
# SwiftPM on the command line does not compile mlx-swift's Metal kernels (mlx-swift README,
# "SwiftPM (command line) cannot build the Metal shaders"). Xcode builds do. For `swift test`
# this script compiles the checked-out kernels into one metallib, which the tests hand to MLX
# through `GPU.metallib`. Usage: build-mlx-metallib.sh <package dir> <output .metallib>
set -eu
package="$1"
out="$2"
mlx="$package/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
kernels="$mlx/mlx/backend/metal/kernels"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
find "$kernels" -name '*.metal' | while read -r src; do
    name="$(echo "${src#$kernels/}" | tr '/' '_')"
    xcrun -sdk macosx metal -x metal -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
        -mmacosx-version-min=26.0 -c "$src" -I"$mlx" -o "$work/${name%.metal}.air"
done
xcrun -sdk macosx metallib "$work"/*.air -o "$out.tmp"
mv "$out.tmp" "$out"
