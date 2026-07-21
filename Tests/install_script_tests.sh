#!/bin/sh

set -eu

readonly tests_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
readonly repository_root=$(dirname -- "$tests_directory")
readonly installer_source="$repository_root/install.sh"
readonly validator_source="$repository_root/Scripts/validate_homebrew_dependencies.sh"

passed=0
failed=0

pass() {
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$1"
}

fail_test() {
  failed=$((failed + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

assert_file() {
  [ -e "$1" ]
}

assert_contains() {
  grep -Fq "$2" "$1"
}

make_fixture() {
  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/lookstep-installer-tests.XXXXXX")
  fixture_root=$(CDPATH= cd -- "$fixture_root" && pwd -P)
  fixture_repo="$fixture_root/source folder"
  fixture_home="$fixture_root/home"
  fixture_bin="$fixture_root/bin"
  fixture_log="$fixture_root/commands.log"
  fixture_brew="$fixture_root/homebrew"
  mkdir -p \
    "$fixture_repo/StepLook/StepLook.xcodeproj" \
    "$fixture_repo/Scripts" \
    "$fixture_home/.Trash" \
    "$fixture_bin" \
    "$fixture_root/tmp" \
    "$fixture_root/System Applications" \
    "$fixture_brew/opt/opencascade/include/opencascade" \
    "$fixture_brew/opt/opencascade/lib"
  cp "$installer_source" "$fixture_repo/install.sh"
  cp "$validator_source" "$fixture_repo/Scripts/validate_homebrew_dependencies.sh"
  : > "$fixture_repo/StepLook/StepLook.xcodeproj/project.pbxproj"
  : > "$fixture_brew/opt/opencascade/lib/libTKernel.dylib"
  : > "$fixture_log"

  cat > "$fixture_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_ARCHITECTURE:-arm64}"
EOF
  cat > "$fixture_bin/sw_vers" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_MACOS_VERSION:-15.5}"
EOF
  cat > "$fixture_bin/brew" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --prefix)
    if [ "${2:-}" = opencascade ]; then
      if [ "${FAKE_OCCT_MISSING:-0}" -ne 0 ] && [ ! -f "$FAKE_OCCT_INSTALLED_STATE" ]; then
        exit 1
      fi
      printf '%s\n' "$FAKE_BREW_PREFIX/opt/opencascade"
    else
      printf '%s\n' "$FAKE_BREW_PREFIX"
    fi
    ;;
  install)
    printf 'brew install %s\n' "${2:-}" >> "$FAKE_COMMAND_LOG"
    [ "${2:-}" != opencascade ] || : > "$FAKE_OCCT_INSTALLED_STATE"
    ;;
  list)
    [ "${2:-}" = --versions ] || exit 2
    case "${3:-}" in
      opencascade) printf 'opencascade %s\n' "${FAKE_OCCT_VERSION:-7.9.3}" ;;
      freetype) printf 'freetype %s\n' "${FAKE_FREETYPE_VERSION:-2.14.3}" ;;
      libpng) printf 'libpng %s\n' "${FAKE_LIBPNG_VERSION:-1.6.58}" ;;
      tbb) printf 'tbb %s\n' "${FAKE_TBB_VERSION:-2023.1.0}" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
  cat > "$fixture_bin/xcodebuild" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -version ]; then
  [ "${FAKE_XCODE_NOT_READY:-0}" -eq 0 ] || exit 1
  printf 'Xcode 99.0\n'
  exit 0
fi
if [ "${1:-}" = -checkFirstLaunchStatus ]; then
  [ "${FAKE_XCODE_SETUP_INCOMPLETE:-0}" -eq 0 ]
  exit
fi
printf 'xcodebuild %s\n' "$*" >> "$FAKE_COMMAND_LOG"
[ "${FAKE_BUILD_FAILURE:-0}" -eq 0 ] || exit 65
derived=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -derivedDataPath ]; then
    shift
    derived=$1
  fi
  shift
done
[ -n "$derived" ] || exit 2
app="$derived/Build/Products/Release/LookSTEP.app"
mkdir -p \
  "$app/Contents/MacOS" \
  "$app/Contents/PlugIns/StepLookPreview.appex" \
  "$app/Contents/XPCServices/StepImportService.xpc"
if [ "${FAKE_MISSING_NESTED_SERVICE:-0}" -eq 0 ]; then
  mkdir -p "$app/Contents/PlugIns/StepLookPreview.appex/Contents/XPCServices/StepImportService.xpc"
fi
if [ "${FAKE_UNWANTED_THUMBNAIL:-0}" -ne 0 ]; then
  mkdir -p "$app/Contents/PlugIns/StepLookThumbnail.appex"
fi
printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/LookSTEP"
chmod +x "$app/Contents/MacOS/LookSTEP"
EOF
  cat > "$fixture_bin/codesign" <<'EOF'
#!/bin/sh
printf 'codesign %s\n' "$*" >> "$FAKE_COMMAND_LOG"
[ "${FAKE_SIGNATURE_FAILURE:-0}" -eq 0 ]
EOF
  cat > "$fixture_bin/lipo" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_LIBRARY_ARCHITECTURES:-arm64}"
EOF
  cat > "$fixture_bin/ditto" <<'EOF'
#!/bin/sh
cp -R "$1" "$2"
if [ "${FAKE_STAGED_APP_INVALID:-0}" -ne 0 ]; then
  rm -rf "$2/Contents/PlugIns/StepLookPreview.appex/Contents/XPCServices/StepImportService.xpc"
fi
EOF
  cat > "$fixture_bin/mv" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -- ]; then
  shift
fi
if [ "${FAKE_INSTALL_MOVE_FAILURE:-0}" -ne 0 ]; then
  case "$1:$2" in
    */.lookstep-install.*/LookSTEP.app:*/LookSTEP.app)
      if [ ! -e "$FAKE_MV_FAILURE_STATE" ]; then
        : > "$FAKE_MV_FAILURE_STATE"
        exit 1
      fi
      ;;
  esac
fi
exec /bin/mv "$@"
EOF
  cat > "$fixture_bin/open" <<'EOF'
#!/bin/sh
printf 'open %s\n' "$*" >> "$FAKE_COMMAND_LOG"
EOF
  cat > "$fixture_bin/pluginkit" <<'EOF'
#!/bin/sh
printf 'pluginkit %s\n' "$*" >> "$FAKE_COMMAND_LOG"
if [ "${1:-}" = -m ] && [ -n "${FAKE_PLUGIN_DISCOVERED_PATH:-}" ]; then
  printf '%s\n' "$FAKE_PLUGIN_DISCOVERED_PATH"
fi
if [ "${1:-}" = -a ] && [ "${FAKE_PLUGIN_ADD_FAILURE:-0}" -ne 0 ]; then
  exit 1
fi
EOF
  chmod +x "$fixture_bin"/* "$fixture_repo/install.sh" "$fixture_repo/Scripts/validate_homebrew_dependencies.sh"
}

remove_fixture() {
  case "${fixture_root:-}" in
    "${TMPDIR:-/tmp}"/lookstep-installer-tests.*) rm -rf -- "$fixture_root" ;;
  esac
}

run_installer() {
  HOME="$fixture_home" \
  TMPDIR="$fixture_root/tmp" \
  PATH="$fixture_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  FAKE_BREW_PREFIX="$fixture_brew" \
  FAKE_COMMAND_LOG="$fixture_log" \
  FAKE_OCCT_INSTALLED_STATE="$fixture_root/occt-installed" \
  FAKE_MV_FAILURE_STATE="$fixture_root/mv-failed" \
  LOOKSTEP_TEST_SYSTEM_APPLICATIONS_DIRECTORY="$fixture_root/System Applications" \
  LOOKSTEP_TEST_USER_APPLICATIONS_DIRECTORY="$fixture_home/Applications" \
  "$fixture_repo/install.sh" "$@"
}

test_help() {
  make_fixture
  if run_installer --help > "$fixture_root/output" 2>&1 &&
     assert_contains "$fixture_root/output" "Usage:" &&
     ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "help exits without building"
  else
    fail_test "help exits without building"
  fi
  remove_fixture
}

test_fresh_install() {
  make_fixture
  install_root="$fixture_root/Applications"
  if run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1 &&
     assert_file "$install_root/LookSTEP.app/Contents/MacOS/LookSTEP" &&
     assert_contains "$fixture_log" "OCCT_ROOT=$fixture_brew/opt/opencascade" &&
     assert_contains "$fixture_log" "pluginkit -a" &&
     assert_contains "$fixture_log" "pluginkit -r" &&
     assert_contains "$fixture_log" "open -g $install_root/LookSTEP.app" &&
     ! find "$fixture_root/tmp" -name 'lookstep-install-build.*' -print | grep -q .; then
    pass "fresh install builds, verifies, registers, and opens"
  else
    fail_test "fresh install builds, verifies, registers, and opens"
  fi
  remove_fixture
}

test_upgrade_backup() {
  make_fixture
  install_root="$fixture_root/Applications"
  mkdir -p "$install_root/LookSTEP.app"
  printf 'old app\n' > "$install_root/LookSTEP.app/old-marker"
  if run_installer --install-dir "$install_root" --no-open > "$fixture_root/output" 2>&1 &&
     assert_file "$install_root/LookSTEP.app/Contents/MacOS/LookSTEP" &&
     find "$fixture_home/.Trash" -name 'LookSTEP-before-install-*.app' -exec test -f '{}/old-marker' \; -print | grep -q . &&
     ! assert_contains "$fixture_log" "open "; then
    pass "upgrade keeps a recoverable backup and honors --no-open"
  else
    fail_test "upgrade keeps a recoverable backup and honors --no-open"
  fi
  remove_fixture
}

test_old_macos_rejected() {
  make_fixture
  if FAKE_MACOS_VERSION=14.7 run_installer --install-dir "$fixture_root/Applications" > "$fixture_root/output" 2>&1; then
    fail_test "old macOS is rejected"
  elif assert_contains "$fixture_root/output" "requires macOS 15" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "old macOS is rejected before building"
  else
    fail_test "old macOS is rejected"
  fi
  remove_fixture
}

test_build_failure_preserves_install() {
  make_fixture
  install_root="$fixture_root/Applications"
  mkdir -p "$install_root/LookSTEP.app"
  printf 'old app\n' > "$install_root/LookSTEP.app/old-marker"
  if FAKE_BUILD_FAILURE=1 run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    fail_test "build failure preserves installed app"
  elif assert_file "$install_root/LookSTEP.app/old-marker" &&
       assert_contains "$fixture_root/output" "Release build failed"; then
    pass "build failure preserves installed app"
  else
    fail_test "build failure preserves installed app"
  fi
  remove_fixture
}

test_signature_failure_preserves_install() {
  make_fixture
  install_root="$fixture_root/Applications"
  mkdir -p "$install_root/LookSTEP.app"
  printf 'old app\n' > "$install_root/LookSTEP.app/old-marker"
  if FAKE_SIGNATURE_FAILURE=1 run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    fail_test "signature failure preserves installed app"
  elif assert_file "$install_root/LookSTEP.app/old-marker" &&
       assert_contains "$fixture_root/output" "signature verification"; then
    pass "signature failure preserves installed app"
  else
    fail_test "signature failure preserves installed app"
  fi
  remove_fixture
}

test_missing_nested_service_rejected() {
  make_fixture
  install_root="$fixture_root/Applications"
  if FAKE_MISSING_NESTED_SERVICE=1 run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    fail_test "missing preview importer is rejected"
  elif assert_contains "$fixture_root/output" "preview is missing its isolated STEP importer" &&
       [ ! -e "$install_root/LookSTEP.app" ]; then
    pass "missing preview importer is rejected"
  else
    fail_test "missing preview importer is rejected"
  fi
  remove_fixture
}

test_thumbnail_extension_rejected() {
  make_fixture
  install_root="$fixture_root/Applications"
  if FAKE_UNWANTED_THUMBNAIL=1 run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    fail_test "retired thumbnail extension is rejected"
  elif assert_contains "$fixture_root/output" "retired thumbnail extension" &&
       [ ! -e "$install_root/LookSTEP.app" ]; then
    pass "retired thumbnail extension is rejected"
  else
    fail_test "retired thumbnail extension is rejected"
  fi
  remove_fixture
}

test_staged_verification_failure_preserves_install() {
  make_fixture
  install_root="$fixture_root/Applications"
  mkdir -p "$install_root/LookSTEP.app"
  printf 'old app\n' > "$install_root/LookSTEP.app/old-marker"
  if FAKE_STAGED_APP_INVALID=1 run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    fail_test "staged verification failure preserves installed app"
  elif assert_file "$install_root/LookSTEP.app/old-marker" &&
       assert_contains "$fixture_root/output" "preview is missing its isolated STEP importer" &&
       ! find "$install_root" -name '.lookstep-install.*' -print | grep -q .; then
    pass "staged verification failure preserves installed app and cleans staging"
  else
    fail_test "staged verification failure preserves installed app"
  fi
  remove_fixture
}

test_failed_install_move_restores_backup() {
  make_fixture
  install_root="$fixture_root/Applications"
  mkdir -p "$install_root/LookSTEP.app"
  printf 'old app\n' > "$install_root/LookSTEP.app/old-marker"
  if FAKE_INSTALL_MOVE_FAILURE=1 run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    fail_test "failed final move restores installed app"
  elif assert_file "$install_root/LookSTEP.app/old-marker" &&
       assert_contains "$fixture_root/output" "previous copy was restored" &&
       ! find "$install_root" -name '.lookstep-install.*' -print | grep -q . &&
       ! find "$fixture_root/tmp" -name 'lookstep-install-build.*' -print | grep -q .; then
    pass "failed final move restores installed app and cleans temporary files"
  else
    fail_test "failed final move restores installed app"
  fi
  remove_fixture
}

test_competing_copy_rejected() {
  make_fixture
  mkdir -p "$fixture_home/Applications/LookSTEP.app"
  if run_installer --install-dir "$fixture_root/System Applications/" --no-open > "$fixture_root/output" 2>&1; then
    fail_test "competing standard install is rejected"
  elif assert_contains "$fixture_root/output" "$fixture_home/Applications/LookSTEP.app" &&
       assert_contains "$fixture_root/output" "Finder has only one" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "competing standard install is rejected before building"
  else
    fail_test "competing standard install is rejected"
  fi
  remove_fixture
}

test_custom_destination_with_standard_copy_rejected() {
  make_fixture
  mkdir -p "$fixture_root/System Applications/LookSTEP.app"
  custom_root="$fixture_root/Custom Applications"
  if run_installer --install-dir "$custom_root" --no-open > "$fixture_root/output" 2>&1; then
    fail_test "custom destination with a standard copy is rejected"
  elif assert_contains "$fixture_root/output" "$fixture_root/System Applications/LookSTEP.app" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "custom destination cannot leave a competing standard provider"
  else
    fail_test "custom destination with a standard copy is rejected"
  fi
  remove_fixture
}

test_missing_occt_noninteractive_rejected() {
  make_fixture
  if FAKE_OCCT_MISSING=1 run_installer --install-dir "$fixture_root/Applications" > "$fixture_root/output" 2>&1; then
    fail_test "missing OCCT is rejected without a terminal"
  elif assert_contains "$fixture_root/output" "brew install opencascade" &&
       ! assert_contains "$fixture_log" "brew install" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "missing OCCT is rejected without making changes in non-interactive use"
  else
    fail_test "missing OCCT is rejected without a terminal"
  fi
  remove_fixture
}

test_unwritable_destination_rejected_before_build() {
  make_fixture
  install_root="$fixture_root/Applications"
  mkdir -p "$install_root"
  chmod 555 "$install_root"
  if run_installer --install-dir "$install_root" > "$fixture_root/output" 2>&1; then
    chmod 755 "$install_root"
    fail_test "unwritable destination is rejected before building"
  else
    chmod 755 "$install_root"
    if assert_contains "$fixture_root/output" "is not writable" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
      pass "unwritable destination is rejected before building"
    else
      fail_test "unwritable destination is rejected before building"
    fi
  fi
  remove_fixture
}

test_registered_provider_skips_fallback() {
  make_fixture
  install_root="$fixture_root/Applications"
  provider="$install_root/LookSTEP.app/Contents/PlugIns/StepLookPreview.appex"
  if FAKE_PLUGIN_DISCOVERED_PATH="$provider" run_installer --install-dir "$install_root" --no-open > "$fixture_root/output" 2>&1 &&
     ! assert_contains "$fixture_log" "pluginkit -a"; then
    pass "already discovered preview provider skips fallback registration"
  else
    fail_test "already discovered preview provider skips fallback registration"
  fi
  remove_fixture
}

test_registration_failure_is_nonfatal() {
  make_fixture
  install_root="$fixture_root/Applications"
  if FAKE_PLUGIN_ADD_FAILURE=1 run_installer --install-dir "$install_root" --no-open > "$fixture_root/output" 2>&1 &&
     assert_file "$install_root/LookSTEP.app/Contents/MacOS/LookSTEP" &&
     assert_contains "$fixture_root/output" "Finder may need a moment"; then
    pass "registration fallback failure leaves a verified installation"
  else
    fail_test "registration fallback failure leaves a verified installation"
  fi
  remove_fixture
}

test_invalid_destination_rejected() {
  make_fixture
  if run_installer --install-dir / > "$fixture_root/output" 2>&1; then
    fail_test "filesystem root destination is rejected"
  elif assert_contains "$fixture_root/output" "refusing to install directly" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "filesystem root destination is rejected"
  else
    fail_test "filesystem root destination is rejected"
  fi
  remove_fixture
}

test_dependency_version_mismatch_rejected() {
  make_fixture
  if FAKE_OCCT_VERSION=8.0.0 run_installer --install-dir "$fixture_root/Applications" > "$fixture_root/output" 2>&1; then
    fail_test "dependency version mismatch is rejected"
  elif assert_contains "$fixture_root/output" "expects opencascade 7.9.3" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "dependency version mismatch is rejected before building"
  else
    fail_test "dependency version mismatch is rejected"
  fi
  remove_fixture
}

test_xcode_setup_incomplete_rejected() {
  make_fixture
  if FAKE_XCODE_SETUP_INCOMPLETE=1 run_installer --install-dir "$fixture_root/Applications" > "$fixture_root/output" 2>&1; then
    fail_test "unfinished Xcode setup is rejected"
  elif assert_contains "$fixture_root/output" "unfinished setup tasks" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "unfinished Xcode setup is rejected before building"
  else
    fail_test "unfinished Xcode setup is rejected"
  fi
  remove_fixture
}

test_intel_dependency_rejected() {
  make_fixture
  if FAKE_LIBRARY_ARCHITECTURES=x86_64 run_installer --install-dir "$fixture_root/Applications" > "$fixture_root/output" 2>&1; then
    fail_test "Intel OCCT dependency is rejected"
  elif assert_contains "$fixture_root/output" "not built for Apple Silicon" &&
       ! assert_contains "$fixture_log" "xcodebuild"; then
    pass "Intel OCCT dependency is rejected before building"
  else
    fail_test "Intel OCCT dependency is rejected"
  fi
  remove_fixture
}

test_help
test_fresh_install
test_upgrade_backup
test_old_macos_rejected
test_build_failure_preserves_install
test_signature_failure_preserves_install
test_missing_nested_service_rejected
test_thumbnail_extension_rejected
test_staged_verification_failure_preserves_install
test_failed_install_move_restores_backup
test_competing_copy_rejected
test_custom_destination_with_standard_copy_rejected
test_missing_occt_noninteractive_rejected
test_unwritable_destination_rejected_before_build
test_registered_provider_skips_fallback
test_registration_failure_is_nonfatal
test_invalid_destination_rejected
test_dependency_version_mismatch_rejected
test_xcode_setup_incomplete_rejected
test_intel_dependency_rejected

printf '\nInstaller tests: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
