#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/tests
swiftc -parse-as-library \
    Sources/Capture/VideoCaptureMath.swift \
    Tests/QuickSnapTests.swift \
    -o .build/tests/QuickSnapTests

.build/tests/QuickSnapTests
