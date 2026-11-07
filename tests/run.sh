#!/bin/bash
# Runs the LidAwake test suites. Requires only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "== Guards"
swiftc -o "$OUT/guards" Guards.swift tests/guards/main.swift
"$OUT/guards"

if [ -f tests/failsafe-test.sh ]; then
    echo "== Fail-safe"
    bash tests/failsafe-test.sh
fi
