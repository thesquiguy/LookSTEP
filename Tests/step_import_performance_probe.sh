#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 PRIVACY_SAFE_ID SOURCE_PATH SIMPLIFICATION_LEVEL" >&2
  exit 64
fi

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
products_dir="${STEPLOOK_RELEASE_PRODUCTS:-/Applications/LookSTEP.app/Contents/XPCServices}"
service_bundle="$products_dir/StepImportService.xpc"
test -d "$service_bundle" || {
  echo "Release StepImportService.xpc is missing: $service_bundle" >&2
  exit 2
}

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/step-import-performance-probe.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM
probe_bundle="$scratch_dir/StepImportPerformanceProbe.app"
mkdir -p \
  "$probe_bundle/Contents/MacOS" \
  "$probe_bundle/Contents/XPCServices"

xcrun swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$scratch_dir/ModuleCache" \
  "$repo_dir/Sources/StepSceneCache/StepCaliperHandoff.swift" \
  "$repo_dir/Sources/StepSceneCache/StepSourceComplexityScan.swift" \
  "$repo_dir/Sources/StepSceneCache/StepPreviewImportBudget.swift" \
  "$repo_dir/Sources/StepSceneCache/StepImportClient.swift" \
  "$repo_dir/Tests/StepImportPerformanceProbe.swift" \
  -o "$probe_bundle/Contents/MacOS/StepImportPerformanceProbe"

cp "$repo_dir/Tests/StepImportPerformanceProbe-Info.plist" \
  "$probe_bundle/Contents/Info.plist"
cp -R "$service_bundle" "$probe_bundle/Contents/XPCServices/"

codesign --force --sign - --options runtime --timestamp=none "$probe_bundle"
codesign --verify --deep --strict "$probe_bundle"
"$probe_bundle/Contents/MacOS/StepImportPerformanceProbe" "$@"
