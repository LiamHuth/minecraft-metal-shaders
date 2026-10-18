#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/mcopt-hazecheck.XXXXXX")}"
mkdir -p "$OUT/classes"
JOML="$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.joml/joml" -name 'joml-*.jar' ! -name '*sources*' | head -1)"
CP="$ROOT/metal/build/classes/java/main:$ROOT/metal/src/main/resources:$JOML"
JAVABIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
"${JAVABIN}javac" -cp "$CP" -d "$OUT/classes" "$HERE/Fixtures.java"
"${JAVABIN}java" -Dmcopt.shade=true -cp "$CP:$OUT/classes" Fixtures "$OUT/vl.metal"
clang -fobjc-arc -O2 -framework Foundation -framework Metal "$HERE/check.m" -o "$OUT/check"
"$OUT/check" "$OUT/vl.metal" "$HERE/probe.metal"
