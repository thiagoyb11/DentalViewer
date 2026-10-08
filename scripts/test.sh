#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p output/module-cache
test_sources=()
for source in Sources/*.swift; do
  if [[ "$source" != "Sources/App.swift" ]]; then test_sources+=("$source"); fi
done
swiftc -swift-version 5 -O -module-cache-path output/module-cache "${test_sources[@]}" Tests/*.swift -framework AppKit -framework SwiftUI -framework Metal -framework MetalKit -o output/viewer-tests
output/viewer-tests "$@"
