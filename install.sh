#!/bin/sh

set -eu

readonly program_name=${0##*/}
readonly script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
readonly project_path="$script_directory/StepLook/StepLook.xcodeproj"
readonly dependency_validator="$script_directory/Scripts/validate_homebrew_dependencies.sh"

install_directory=/Applications
open_after_install=1
staging_directory=
temporary_root=${TMPDIR:-/tmp}
temporary_root=${temporary_root%/}
build_directory=
built_preview_extension=

usage() {
  cat <<EOF
Usage: $program_name [--user | --install-dir DIRECTORY] [--no-open]

Builds LookSTEP from source, verifies it, and installs it on this Mac.

Options:
  --user                   Install in ~/Applications instead of /Applications.
  --install-dir DIRECTORY  Install in another absolute directory.
  --no-open                Do not open LookSTEP after installation.
  -h, --help               Show this help.
EOF
}

note() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nLookSTEP installation stopped: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "${staging_directory:-}" ] && [ -d "$staging_directory" ]; then
    case "$staging_directory" in
      "$install_directory"/.lookstep-install.*)
        rm -rf -- "$staging_directory"
        ;;
    esac
  fi
  if [ -n "${build_directory:-}" ] && [ -d "$build_directory" ]; then
    case "$build_directory" in
      "$temporary_root"/lookstep-install-build.*)
        if [ -n "${built_preview_extension:-}" ] && command -v pluginkit >/dev/null 2>&1; then
          pluginkit -r "$built_preview_extension" >/dev/null 2>&1 || true
        fi
        rm -rf -- "$build_directory"
        ;;
    esac
  fi
}

trap cleanup EXIT HUP INT TERM

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$2"
}

verify_app() {
  app_path=$1
  [ -d "$app_path" ] || fail "the build did not produce LookSTEP.app."
  [ -x "$app_path/Contents/MacOS/LookSTEP" ] || fail "LookSTEP.app is missing its executable."
  [ -d "$app_path/Contents/PlugIns/StepLookPreview.appex" ] || fail "LookSTEP.app is missing its Finder preview extension."
  [ -d "$app_path/Contents/PlugIns/StepLookPreview.appex/Contents/XPCServices/StepImportService.xpc" ] || fail "LookSTEP's Finder preview is missing its isolated STEP importer."
  [ -d "$app_path/Contents/XPCServices/StepImportService.xpc" ] || fail "LookSTEP.app is missing its isolated STEP importer."
  [ ! -e "$app_path/Contents/PlugIns/StepLookThumbnail.appex" ] || fail "LookSTEP.app unexpectedly contains the retired thumbnail extension."
  codesign --verify --deep --strict "$app_path" || fail "LookSTEP.app did not pass signature verification."
  verify_step_importers_load "$app_path"
}

# The import services are the only executables that link Open CASCADE. If the
# hardened runtime refuses to map those bundled libraries, the app still
# installs, still launches, and still registers with Finder, but every preview
# fails. That is invisible until someone presses Spacebar, so prove the
# libraries load before installing rather than after.
verify_step_importers_load() {
  app_path=$1
  for importer_path in \
    "$app_path/Contents/XPCServices/StepImportService.xpc/Contents/MacOS/StepImportService" \
    "$app_path/Contents/PlugIns/StepLookPreview.appex/Contents/XPCServices/StepImportService.xpc/Contents/MacOS/StepImportService"; do
    [ -x "$importer_path" ] || fail "LookSTEP.app is missing an executable STEP import service."
    # Launched directly, the service refuses to run and exits. Anything dyld
    # cannot map is reported before that guard is ever reached.
    importer_output=$("$importer_path" 2>&1 || true)
    case "$importer_output" in
      *"Library not loaded"*|*"code signature"*)
        printf '%s\n' "$importer_output" >&2
        fail "LookSTEP's STEP importer cannot load its bundled Open CASCADE libraries, so no preview would render."
        ;;
    esac
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      : "${HOME:?HOME is required for --user}"
      install_directory="$HOME/Applications"
      ;;
    --install-dir)
      shift
      [ "$#" -gt 0 ] || fail "--install-dir requires a directory."
      install_directory=$1
      ;;
    --no-open)
      open_after_install=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1. Run '$program_name --help' for usage."
      ;;
  esac
  shift
done

case "$install_directory" in
  /*) ;;
  *) fail "the install directory must be an absolute path." ;;
esac
[ "$install_directory" != / ] || fail "refusing to install directly in the filesystem root."

[ -f "$project_path/project.pbxproj" ] || fail "run this script from an intact LookSTEP source download."
[ -x "$dependency_validator" ] || fail "run this script from an intact LookSTEP source download; the dependency validator is missing."

if ! mkdir -p -- "$install_directory"; then
  fail "cannot create $install_directory. Run '$program_name --user' to install only for your account."
fi
[ -w "$install_directory" ] || fail "$install_directory is not writable. Run '$program_name --user' to install only for your account."
install_directory=$(CDPATH= cd -- "$install_directory" && pwd -P) || fail "could not resolve the install directory."
[ "$install_directory" != / ] || fail "refusing to install directly in the filesystem root."

# Test-only directory overrides keep the installer suite isolated from apps on
# the developer's Mac. Normal invocations always use the two standard paths.
system_applications_directory=${LOOKSTEP_TEST_SYSTEM_APPLICATIONS_DIRECTORY:-/Applications}
user_applications_directory=${LOOKSTEP_TEST_USER_APPLICATIONS_DIRECTORY:-${HOME:-}/Applications}
if [ -d "$system_applications_directory" ]; then
  system_applications_directory=$(CDPATH= cd -- "$system_applications_directory" && pwd -P) || fail "could not resolve $system_applications_directory."
fi
if [ -d "$user_applications_directory" ]; then
  user_applications_directory=$(CDPATH= cd -- "$user_applications_directory" && pwd -P) || fail "could not resolve $user_applications_directory."
fi

destination="$install_directory/LookSTEP.app"
for possible_copy in \
  "$system_applications_directory/LookSTEP.app" \
  "$user_applications_directory/LookSTEP.app"; do
  if [ "$possible_copy" != "$destination" ] && [ -e "$possible_copy" ]; then
    fail "another copy is already installed at $possible_copy. Remove that copy, or install to its parent directory, so Finder has only one LookSTEP preview extension."
  fi
done

require_command uname "uname is unavailable."
require_command sw_vers "this installer requires macOS."
require_command xcodebuild "install Xcode from Apple, open it once, and run this installer again."
require_command codesign "codesign is unavailable. Install Xcode's command-line components."
require_command ditto "ditto is unavailable."
require_command lipo "lipo is unavailable. Install Xcode's command-line components."

if command -v brew >/dev/null 2>&1; then
  brew_command=$(command -v brew)
elif [ -x /opt/homebrew/bin/brew ]; then
  brew_command=/opt/homebrew/bin/brew
else
  fail "install Homebrew from https://brew.sh/ and run this installer again."
fi

machine_architecture=$(uname -m)
if [ "$machine_architecture" != arm64 ]; then
  if command -v sysctl >/dev/null 2>&1 && [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
    fail "Terminal is running through Rosetta. Reopen Terminal normally and try again."
  fi
  fail "LookSTEP requires an Apple Silicon Mac."
fi

macos_version=$(sw_vers -productVersion)
macos_major=${macos_version%%.*}
case "$macos_major" in
  ''|*[!0-9]*) fail "could not determine the macOS version." ;;
esac
[ "$macos_major" -ge 26 ] || fail "LookSTEP requires macOS 26 or later; this Mac is running $macos_version."

if ! xcodebuild -version >/dev/null 2>&1; then
  fail "Xcode is not ready. Open Xcode once, finish its setup, and run this installer again."
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  fail "Xcode has unfinished setup tasks. Open Xcode once, finish its setup, and run this installer again."
fi

homebrew_prefix=$("$brew_command" --prefix 2>/dev/null) || fail "Homebrew is not ready. Run 'brew doctor' and try again."

if ! occt_root=$("$brew_command" --prefix opencascade 2>/dev/null); then
  if [ ! -t 0 ]; then
    fail "Open CASCADE Technology is required. Run 'brew install opencascade', then try again."
  fi
  printf '\nOpen CASCADE Technology is required. Install it with Homebrew now? [Y/n] '
  IFS= read -r answer || answer=n
  case "$answer" in
    ''|y|Y|yes|YES)
      note "Installing Open CASCADE Technology"
      "$brew_command" install opencascade || fail "Homebrew could not install opencascade."
      ;;
    *)
      fail "Open CASCADE Technology is required."
      ;;
  esac
  occt_root=$("$brew_command" --prefix opencascade 2>/dev/null) || fail "Homebrew installed opencascade but its prefix could not be found."
fi

HOMEBREW_PREFIX="$homebrew_prefix" OCCT_ROOT="$occt_root" BREW_COMMAND="$brew_command" "$dependency_validator"

note "Building LookSTEP"
printf 'This can take several minutes on the first run.\n'
build_directory=$(mktemp -d "$temporary_root/lookstep-install-build.XXXXXX") || fail "could not create a temporary build directory."
built_app="$build_directory/Build/Products/Release/LookSTEP.app"
built_preview_extension="$built_app/Contents/PlugIns/StepLookPreview.appex"

if ! xcodebuild \
  -quiet \
  -project "$project_path" \
  -scheme LookSTEP \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_directory" \
  "OCCT_ROOT=$occt_root" \
  "HOMEBREW_PREFIX=$homebrew_prefix" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build; then
  fail "the Release build failed. Review the Xcode errors above."
fi

note "Verifying the Release build"
verify_app "$built_app"

staging_directory=$(mktemp -d "$install_directory/.lookstep-install.XXXXXX") || fail "could not create a safe staging directory in $install_directory."
staged_app="$staging_directory/LookSTEP.app"
ditto "$built_app" "$staged_app" || fail "could not copy the verified build into the installation staging area."
verify_app "$staged_app"

backup_path=
if [ -e "$destination" ] || [ -L "$destination" ]; then
  : "${HOME:?HOME is required to back up the installed app}"
  trash_directory="$HOME/.Trash"
  mkdir -p -- "$trash_directory" || fail "could not open the Trash for the existing LookSTEP app."
  timestamp=$(date '+%Y%m%d-%H%M%S')
  backup_path="$trash_directory/LookSTEP-before-install-$timestamp-$$.app"
  note "Moving the previous LookSTEP to Trash"
  mv -- "$destination" "$backup_path" || fail "could not move the previous LookSTEP app to Trash."
fi

note "Installing LookSTEP in $install_directory"
if ! mv -- "$staged_app" "$destination"; then
  if [ -n "$backup_path" ] && [ -e "$backup_path" ]; then
    mv -- "$backup_path" "$destination" || true
  fi
  fail "could not install LookSTEP. The previous copy was restored when possible."
fi

if [ "$open_after_install" -eq 1 ]; then
  require_command open "LookSTEP was installed, but the macOS open command is unavailable."
  open -g "$destination" ||
    printf 'Warning: LookSTEP was installed but could not be opened automatically. Open it once from Applications.\n' >&2
fi

preview_extension="$destination/Contents/PlugIns/StepLookPreview.appex"
# Read the identifier from the installed bundle rather than hardcoding it. The
# bundle prefix is a build setting (PRODUCT_BUNDLE_PREFIX) and changes when the
# shipping identity is settled. If it cannot be read, fall through and register
# unconditionally, which is the safe direction.
preview_extension_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - \
    "$preview_extension/Contents/Info.plist" 2>/dev/null
) || preview_extension_identifier=""
if command -v pluginkit >/dev/null 2>&1; then
  pluginkit -r "$built_preview_extension" >/dev/null 2>&1 || true

  # Xcode and other build tools can leave development copies registered after
  # their temporary directories disappear. Finder is then free to select stale
  # or Debug code instead of the installed Release extension. Remove every
  # competing provider for this exact identifier before refreshing the one
  # verified above.
  if [ -n "$preview_extension_identifier" ]; then
    pluginkit -m -A -D -v -i "$preview_extension_identifier" 2>/dev/null |
      awk -F '\t' 'NF { print $NF }' |
      while IFS= read -r discovered_preview_extension; do
        case "$discovered_preview_extension" in
          /*)
            if [ "$discovered_preview_extension" != "$preview_extension" ]; then
              pluginkit -r "$discovered_preview_extension" >/dev/null 2>&1 || true
            fi
            ;;
        esac
      done
  fi

  if ! pluginkit -a "$preview_extension" >/dev/null 2>&1; then
    printf 'Warning: Finder may need a moment to discover the LookSTEP preview extension.\n' >&2
  elif [ -n "$preview_extension_identifier" ] &&
    ! pluginkit -m -A -D -v -i "$preview_extension_identifier" 2>/dev/null |
      grep -Fq "$preview_extension"; then
    printf 'Warning: Finder did not report the installed LookSTEP preview extension yet.\n' >&2
  fi
fi

note "LookSTEP is installed"
printf 'Select a .step or .stp file in Finder and press Spacebar.\n'
if [ -n "$backup_path" ]; then
  printf 'The previous app is recoverable from: %s\n' "$backup_path"
fi
