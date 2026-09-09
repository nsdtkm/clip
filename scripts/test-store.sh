#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/store-tests
swiftc -I Sources/CSQLite Sources/Clip/HistoryStore.swift Tests/ClipTests/main.swift -o .build/store-tests/check
.build/store-tests/check
