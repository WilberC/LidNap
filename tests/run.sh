#!/bin/bash
# Runs the LidNap test suites. Requires only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "== Guards"
swiftc -o "$OUT/guards" Guards.swift tests/guards/main.swift
"$OUT/guards"

echo "== Session"
# Named LidNap so failsafe.sh recognizes it as the app process.
swiftc -o "$OUT/LidNap" Guards.swift Session.swift tests/session/main.swift
"$OUT/LidNap"

echo "== Fail-safe"
bash tests/failsafe-test.sh
