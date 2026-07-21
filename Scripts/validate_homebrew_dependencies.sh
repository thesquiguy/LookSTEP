#!/bin/sh

# Keep every LookSTEP build aligned with the dependency sources and notices
# checked into this release. The installer and Xcode build phase both call this
# script so a manual Xcode build cannot silently bundle a different closure.

set -eu

fail() {
    printf 'error: LookSTEP dependency check: %s\n' "$*" >&2
    exit 1
}

if [ -n "${BREW_COMMAND:-}" ]; then
    brew_command=$BREW_COMMAND
elif command -v brew >/dev/null 2>&1; then
    brew_command=$(command -v brew)
elif [ -x /opt/homebrew/bin/brew ]; then
    brew_command=/opt/homebrew/bin/brew
else
    fail "Homebrew was not found. Install it from https://brew.sh/."
fi

if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    homebrew_prefix=$HOMEBREW_PREFIX
else
    homebrew_prefix=$($brew_command --prefix 2>/dev/null) || fail "Homebrew is not ready. Run 'brew doctor' and try again."
fi

if [ -n "${OCCT_ROOT:-}" ]; then
    occt_root=$OCCT_ROOT
else
    occt_root=$($brew_command --prefix opencascade 2>/dev/null) || fail "Open CASCADE Technology is missing. Run 'brew install opencascade'."
fi

case "$occt_root" in
    "$homebrew_prefix"/*) ;;
    *) fail "OCCT_ROOT ($occt_root) is not inside HOMEBREW_PREFIX ($homebrew_prefix)." ;;
esac

[ -d "$occt_root/include/opencascade" ] || fail "Open CASCADE headers were not found at $occt_root."
[ -d "$occt_root/lib" ] || fail "Open CASCADE libraries were not found at $occt_root."
kernel_library="$occt_root/lib/libTKernel.dylib"
[ -f "$kernel_library" ] || fail "Open CASCADE's libTKernel.dylib was not found at $occt_root."

command -v lipo >/dev/null 2>&1 || fail "lipo is unavailable. Install Xcode's command-line components."
kernel_architectures=$(lipo -archs "$kernel_library" 2>/dev/null) || fail "could not inspect the Open CASCADE library architecture."
case " $kernel_architectures " in
    *" arm64 "*) ;;
    *) fail "the installed Open CASCADE libraries are not built for Apple Silicon. Check that Apple Silicon Homebrew is active." ;;
esac

check_formula_version() {
    formula_name=$1
    expected_version=$2
    installed_versions=$($brew_command list --versions "$formula_name" 2>/dev/null) ||
        fail "Homebrew dependency $formula_name is missing. Run 'brew reinstall opencascade' and try again."
    set -- $installed_versions
    if [ "$#" -eq 2 ] && [ "$1" = "$formula_name" ] && [ "$2" = "$expected_version" ]; then
        return 0
    fi
    fail "this source release expects $formula_name $expected_version, but Homebrew reports: $installed_versions. See THIRD_PARTY.md before building with a different dependency set."
}

# These exact versions match the archives, checksums, and notices recorded in
# THIRD_PARTY.md. Intentionally supporting newer versions requires updating
# that register and its notices first.
check_formula_version opencascade 7.9.3
check_formula_version freetype 2.14.3
check_formula_version libpng 1.6.58
check_formula_version tbb 2023.1.0
