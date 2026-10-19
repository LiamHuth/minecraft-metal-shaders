#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$(mktemp -d /tmp/mcopt-presentation.XXXXXX)}"
mkdir -p "$OUT"
NATIVE="$ROOT/metal/build/natives/natives"
clang -fno-objc-arc -O2 -Wall -mmacosx-version-min=15.0 -I"$ROOT/metal/src/main/native" \
  -framework AppKit -framework Metal -framework QuartzCore -L"$NATIVE" -lmcmetal -Wl,-rpath,"$NATIVE" \
  "$ROOT/tools/presentation/check.m" -o "$OUT/check"
MTL_DEBUG_LAYER=1 "$OUT/check" "${2:-1}"
