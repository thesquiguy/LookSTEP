#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/step-cache-envelope-tests.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

xcrun swiftc \
  -O \
  -D STEP_CACHE_TESTING \
  -parse-as-library \
  -module-cache-path "$scratch_dir/ModuleCache" \
  "$repo_dir/Sources/StepSceneCache/StepCaliperHandoff.swift" \
  "$repo_dir/Sources/StepSceneCache/StepSourceComplexityScan.swift" \
  "$repo_dir/Sources/StepSceneCache/StepPreviewImportBudget.swift" \
  "$repo_dir/Sources/StepSceneCache/StepMeshArchive.swift" \
  "$repo_dir/Sources/StepSceneCache/StepPreviewCache.swift" \
  "$repo_dir/Tests/StepCacheEnvelopeTests.swift" \
  -o "$scratch_dir/StepCacheEnvelopeTests"

"$scratch_dir/StepCacheEnvelopeTests"
