#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/step-import-client-slot-tests.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

xcrun swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$scratch_dir/ModuleCache" \
  "$repo_dir/Sources/StepSceneCache/StepCaliperHandoff.swift" \
  "$repo_dir/Sources/StepSceneCache/StepSourceComplexityScan.swift" \
  "$repo_dir/Sources/StepSceneCache/StepPreviewImportBudget.swift" \
  "$repo_dir/Sources/StepSceneCache/StepImportClient.swift" \
  "$repo_dir/Tests/StepImportClientRequestSlotTests.swift" \
  -o "$scratch_dir/StepImportClientRequestSlotTests"

"$scratch_dir/StepImportClientRequestSlotTests"
