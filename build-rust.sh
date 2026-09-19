#!/bin/bash
# Builds the Rustlyn library Pilot links against, and copies its header in.
#
# Rustlyn is a separate repository. By default it is expected next to this
# one; point RUSTLYN_PATH somewhere else if it is not:
#
#     RUSTLYN_PATH=~/code/rustlyn ./build-rust.sh
#
# The header is copied rather than checked in, so the declarations Swift
# compiles against always come from the build it will link against. A header
# committed here would be a second copy to keep in step, and the day it fell
# behind, Swift would be calling functions with the wrong signatures and the
# linker would not notice.
set -euo pipefail
cd "$(dirname "$0")"

RUSTLYN_PATH="${RUSTLYN_PATH:-../rustlyn}"

if [[ ! -f "$RUSTLYN_PATH/Cargo.toml" ]]; then
    echo "Rustlyn not found at $RUSTLYN_PATH" >&2
    echo "Clone it beside this repository, or set RUSTLYN_PATH." >&2
    exit 1
fi

if ! command -v cargo > /dev/null; then
    echo "cargo not found — install Rust from https://rustup.rs" >&2
    exit 1
fi

RUSTLYN_PATH="$(cd "$RUSTLYN_PATH" && pwd -P)"

# Always release: this is a compiler front end, and a debug build of one is
# slow enough to be noticeable while scrolling. It is also cached by cargo,
# so the second build costs nothing.
echo "==> cargo build --release -p rustlyn-ffi ($RUSTLYN_PATH)"
cargo build --release -p rustlyn-ffi --manifest-path "$RUSTLYN_PATH/Cargo.toml"

OUT=".build/rustlyn"
mkdir -p "$OUT" Sources/CRustlyn/include
cp "$RUSTLYN_PATH/target/release/librustlyn_ffi.a" "$OUT/"
cp "$RUSTLYN_PATH/crates/rustlyn-ffi/include/rustlyn.h" Sources/CRustlyn/include/

echo "    $(pwd)/$OUT/librustlyn_ffi.a"
echo "    header -> Sources/CRustlyn/include/rustlyn.h"
