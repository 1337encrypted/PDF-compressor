#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
mkdir -p "$ROOT/.build-cache"
TEST_ROOT="$(mktemp -d "$ROOT/.build-cache/tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
"$PYTHON_BIN" "$ROOT/Tests/make_fixtures.py" "$TEST_ROOT/fixtures"
"$PYTHON_BIN" "$ROOT/Tests/make_image_fixtures.py" "$TEST_ROOT/fixtures"
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$ROOT/.build-cache" \
  "$ROOT/Sources/Compression.swift" "$ROOT/Sources/ImageCompression.swift" \
  "$ROOT/Tests/Integration.swift" "$ROOT/Tests/ImageChecks.swift" \
  -o "$TEST_ROOT/Integration"
"$TEST_ROOT/Integration" "$TEST_ROOT/fixtures"
