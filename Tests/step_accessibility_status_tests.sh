#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/step-accessibility-status-tests.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$scratch_dir/ModuleCache" \
  "$repo_dir/Sources/StepRendererRealityKit/StepAccessibilityStatus.swift" \
  "$repo_dir/Tests/StepAccessibilityStatusTests.swift" \
  -o "$scratch_dir/StepAccessibilityStatusTests"

"$scratch_dir/StepAccessibilityStatusTests"
