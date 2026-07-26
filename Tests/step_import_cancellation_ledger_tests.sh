#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/step-import-cancellation-ledger-tests.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

xcrun swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$scratch_dir/ModuleCache" \
  "$repo_dir/StepLook/StepImportService/StepImportCancellationLedger.swift" \
  "$repo_dir/Tests/StepImportCancellationLedgerTests.swift" \
  -o "$scratch_dir/StepImportCancellationLedgerTests"

"$scratch_dir/StepImportCancellationLedgerTests"
