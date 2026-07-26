#!/bin/sh

# Bundle the complete non-system dynamic-library closure rooted at an OCCT
# executable. Xcode and CMake run this after linking and before sealing the
# containing bundle.

set -eu

bundle_log_prefix=${BUNDLE_LOG_PREFIX:-LookSTEP OCCT bundling}
bundle_manifest_name=${BUNDLE_MANIFEST_NAME:-.steplook-bundled-dylibs}

fail() {
    printf 'error: %s: %s\n' "$bundle_log_prefix" "$*" >&2
    exit 1
}

note() {
    printf '%s: %s\n' "$bundle_log_prefix" "$*"
}

case "$bundle_manifest_name" in
    ''|*/*|.|..) fail "BUNDLE_MANIFEST_NAME must be a safe file name" ;;
esac

command -v otool >/dev/null 2>&1 || fail "otool is unavailable. Install the Xcode command-line tools."
command -v install_name_tool >/dev/null 2>&1 || fail "install_name_tool is unavailable. Install the Xcode command-line tools."
command -v codesign >/dev/null 2>&1 || fail "codesign is unavailable. Install the Xcode command-line tools."

: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
: "${EXECUTABLE_PATH:?EXECUTABLE_PATH is required}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is required}"

occt_root=${OCCT_ROOT:-/opt/homebrew/opt/opencascade}
occt_lib_dir="$occt_root/lib"
service_binary="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
frameworks_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
resources_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
manifest_path="$resources_dir/$bundle_manifest_name"
bundle_rpath='@executable_path/../Frameworks'
script_dir=$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd -P) || fail "could not locate the Scripts directory"
repository_root=$(/usr/bin/dirname "$script_dir")
third_party_summary="$repository_root/THIRD_PARTY.md"
third_party_notices="$repository_root/ThirdPartyNotices"
dependency_validator="$script_dir/validate_homebrew_dependencies.sh"

[ -x "$service_binary" ] || fail "linked service executable not found at $service_binary"
[ -d "$occt_lib_dir" ] || fail "OpenCascade libraries not found at $occt_lib_dir. Install opencascade with Homebrew or set OCCT_ROOT."
[ -f "$third_party_summary" ] || fail "third-party summary not found at $third_party_summary"
[ -d "$third_party_notices" ] || fail "third-party notices not found at $third_party_notices"
[ -x "$dependency_validator" ] || fail "dependency validator not found at $dependency_validator"

if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    homebrew_prefix=$HOMEBREW_PREFIX
else
    case "$occt_root" in
        */opt/*) homebrew_prefix=${occt_root%/opt/*} ;;
        *) fail "set HOMEBREW_PREFIX when OCCT_ROOT is outside Homebrew's opt directory" ;;
    esac
fi

case "$occt_root" in
    "$homebrew_prefix"/*) ;;
    *) fail "OCCT_ROOT ($occt_root) is not inside HOMEBREW_PREFIX ($homebrew_prefix)" ;;
esac

HOMEBREW_PREFIX="$homebrew_prefix" OCCT_ROOT="$occt_root" "$dependency_validator"

work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/steplook-dylibs.XXXXXX") || fail "could not create a temporary directory"
cleanup() {
    if [ -n "${work_dir:-}" ] && [ -d "$work_dir" ]; then
        /bin/rm -rf "$work_dir"
    fi
}
trap cleanup EXIT HUP INT TERM

queue_path="$work_dir/queue"
names_dir="$work_dir/names"
stage_dir="$work_dir/Frameworks"
new_manifest="$work_dir/manifest"
/bin/mkdir -p "$names_dir" "$stage_dir"
: > "$queue_path"
: > "$new_manifest"

list_dependencies() {
    /usr/bin/otool -L "$1" | /usr/bin/sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p'
}

normalize_existing_path() {
    candidate=$1
    [ -f "$candidate" ] || return 1
    candidate_dir=$(/usr/bin/dirname "$candidate")
    candidate_name=$(/usr/bin/basename "$candidate")
    physical_dir=$(cd "$candidate_dir" && /bin/pwd -P) || return 1
    printf '%s/%s\n' "$physical_dir" "$candidate_name"
}

# Print the source for a dependency that must be bundled. Return 1 for a
# macOS-provided dependency and 2 for a non-system dependency we cannot resolve.
resolve_dependency() {
    owner=$1
    dependency=$2
    dependency_name=$(/usr/bin/basename "$dependency")

    case "$dependency" in
        /System/*|/usr/lib/*)
            return 1
            ;;
        @rpath/*)
            if resolved=$(normalize_existing_path "$occt_lib_dir/$dependency_name"); then
                printf '%s\n' "$resolved"
                return 0
            fi
            owner_dir=$(/usr/bin/dirname "$owner")
            if resolved=$(normalize_existing_path "$owner_dir/$dependency_name"); then
                printf '%s\n' "$resolved"
                return 0
            fi
            return 2
            ;;
        @loader_path/*)
            owner_dir=$(/usr/bin/dirname "$owner")
            relative_path=${dependency#@loader_path/}
            if resolved=$(normalize_existing_path "$owner_dir/$relative_path"); then
                printf '%s\n' "$resolved"
                return 0
            fi
            return 2
            ;;
        @executable_path/*)
            executable_dir=$(/usr/bin/dirname "$service_binary")
            relative_path=${dependency#@executable_path/}
            if resolved=$(normalize_existing_path "$executable_dir/$relative_path"); then
                printf '%s\n' "$resolved"
                return 0
            fi
            return 2
            ;;
        /*)
            case "$dependency" in
                "$homebrew_prefix"/*)
                    if resolved=$(normalize_existing_path "$dependency"); then
                        printf '%s\n' "$resolved"
                        return 0
                    fi
                    return 2
                    ;;
                *)
                    return 2
                    ;;
            esac
            ;;
        *)
            return 2
            ;;
    esac
}

enqueue_library() {
    source_path=$1
    library_name=$(/usr/bin/basename "$source_path")
    marker_path="$names_dir/$library_name"

    case "$library_name" in
        *.dylib) ;;
        *) fail "unsupported non-system dependency $source_path" ;;
    esac

    if [ -f "$marker_path" ]; then
        existing_source=$(/bin/cat "$marker_path")
        if /usr/bin/cmp -s "$existing_source" "$source_path"; then
            return 0
        fi
        fail "two different libraries use the filename $library_name: $existing_source and $source_path"
    fi

    printf '%s\n' "$source_path" > "$marker_path"
    printf '%s\n' "$source_path" >> "$queue_path"
}

# Only direct OCCT dependencies seed the closure. Dependencies of those files
# may come from other Homebrew formulae and are recursively included below.
seed_count=0
while IFS= read -r dependency; do
    dependency_name=$(/usr/bin/basename "$dependency")
    if source_path=$(normalize_existing_path "$occt_lib_dir/$dependency_name"); then
        enqueue_library "$source_path"
        seed_count=$((seed_count + 1))
    fi
done <<EOF
$(list_dependencies "$service_binary")
EOF

[ "$seed_count" -gt 0 ] || fail "the service executable does not link any libraries from $occt_lib_dir; place this build phase after the link step"

queue_index=1
while :; do
    source_path=$(/usr/bin/sed -n "${queue_index}p" "$queue_path")
    [ -n "$source_path" ] || break

    while IFS= read -r dependency; do
        if resolved=$(resolve_dependency "$source_path" "$dependency"); then
            enqueue_library "$resolved"
        else
            resolution_status=$?
            if [ "$resolution_status" -ne 1 ]; then
                fail "cannot resolve non-system dependency $dependency required by $source_path"
            fi
        fi
    done <<EOF
$(list_dependencies "$source_path")
EOF

    queue_index=$((queue_index + 1))
done

# Copy every library before rewriting so @rpath dependencies can be checked
# against the complete staged closure.
while IFS= read -r source_path; do
    library_name=$(/usr/bin/basename "$source_path")
    /bin/cp -pL "$source_path" "$stage_dir/$library_name" || fail "could not copy $source_path"
    /bin/chmod u+w "$stage_dir/$library_name"
    # Homebrew bottles may be pre-signed. Remove that signature before
    # install_name_tool edits so the build does not emit a warning for every
    # intentional Mach-O rewrite; the finalized copy is signed below.
    if /usr/bin/codesign --display "$stage_dir/$library_name" >/dev/null 2>&1; then
        /usr/bin/codesign --remove-signature "$stage_dir/$library_name" \
            || fail "could not remove the source signature from $library_name"
    fi
    printf '%s\n' "$library_name" >> "$new_manifest"
done < "$queue_path"

rewrite_dependencies() {
    binary=$1
    dylib_id=''
    if id_output=$(/usr/bin/otool -D "$binary" 2>/dev/null); then
        dylib_id=$(printf '%s\n' "$id_output" | /usr/bin/sed -n '2p')
    fi

    while IFS= read -r dependency; do
        [ "$dependency" = "$dylib_id" ] && continue
        dependency_name=$(/usr/bin/basename "$dependency")
        if [ -f "$stage_dir/$dependency_name" ]; then
            desired_path="@rpath/$dependency_name"
            if [ "$dependency" != "$desired_path" ]; then
                /usr/bin/install_name_tool -change "$dependency" "$desired_path" "$binary" || fail "could not rewrite $dependency in $binary"
            fi
        fi
    done <<EOF
$(list_dependencies "$binary")
EOF
}

while IFS= read -r source_path; do
    library_name=$(/usr/bin/basename "$source_path")
    staged_library="$stage_dir/$library_name"
    /usr/bin/install_name_tool -id "@rpath/$library_name" "$staged_library" || fail "could not set the install name for $library_name"
    rewrite_dependencies "$staged_library"
done < "$queue_path"

rewrite_dependencies "$service_binary"

list_rpaths() {
    /usr/bin/otool -l "$1" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" { reading = 1; next }
        reading && $1 == "path" { print $2; reading = 0 }
    '
}

while IFS= read -r existing_rpath; do
    case "$existing_rpath" in
        "$homebrew_prefix"/*)
            /usr/bin/install_name_tool -delete_rpath "$existing_rpath" "$service_binary" || fail "could not remove Homebrew runpath $existing_rpath"
            ;;
    esac
done <<EOF
$(list_rpaths "$service_binary")
EOF

if ! list_rpaths "$service_binary" | /usr/bin/grep -Fqx "$bundle_rpath"; then
    /usr/bin/install_name_tool -add_rpath "$bundle_rpath" "$service_binary" || fail "could not add the bundled-library runpath"
fi

# No bundled binary may retain an absolute Homebrew dependency.
validate_binary() {
    binary=$1
    if list_dependencies "$binary" | /usr/bin/grep -F "$homebrew_prefix/" >/dev/null; then
        fail "$binary still contains an absolute Homebrew dependency"
    fi
}

validate_binary "$service_binary"
while IFS= read -r source_path; do
    validate_binary "$stage_dir/$(/usr/bin/basename "$source_path")"
done < "$queue_path"

signing_identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}
case "$signing_identity" in
    ''|"Don't Code Sign") signing_identity='-' ;;
esac

while IFS= read -r source_path; do
    library_name=$(/usr/bin/basename "$source_path")
    staged_library="$stage_dir/$library_name"
    /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$staged_library" || fail "could not sign $library_name"
    /usr/bin/codesign --verify --strict "$staged_library" || fail "signature verification failed for $library_name"
done < "$queue_path"

/bin/mkdir -p "$frameworks_dir" "$resources_dir"
# Frameworks may contain only code because Xcode validates every item there as
# signable code. Also remove the original LookSTEP-era location when a caller
# uses a product-specific manifest name.
/bin/rm -f "$frameworks_dir/.steplook-bundled-dylibs" "$frameworks_dir/$bundle_manifest_name"
if [ -f "$manifest_path" ]; then
    while IFS= read -r old_library_name; do
        case "$old_library_name" in
            ''|*/*|.|..) fail "unsafe entry in existing bundle manifest: $old_library_name" ;;
            *.dylib) /bin/rm -f "$frameworks_dir/$old_library_name" ;;
            *) fail "unexpected entry in existing bundle manifest: $old_library_name" ;;
        esac
    done < "$manifest_path"
fi

while IFS= read -r source_path; do
    library_name=$(/usr/bin/basename "$source_path")
    /bin/cp -p "$stage_dir/$library_name" "$frameworks_dir/$library_name" || fail "could not install $library_name in the XPC bundle"
    /usr/bin/codesign --verify --strict "$frameworks_dir/$library_name" || fail "installed signature verification failed for $library_name"
done < "$queue_path"
/bin/cp "$new_manifest" "$manifest_path"

# Ship the exact notices beside the code that uses the bundled libraries. This
# directory is owned by this build phase, so replacing it also removes stale
# notices after dependency upgrades.
/bin/cp "$third_party_summary" "$resources_dir/THIRD_PARTY.md" || fail "could not copy THIRD_PARTY.md into the XPC bundle"
/bin/rm -rf "$resources_dir/ThirdPartyNotices"
/usr/bin/ditto "$third_party_notices" "$resources_dir/ThirdPartyNotices" || fail "could not copy ThirdPartyNotices into the XPC bundle"

library_count=$(/usr/bin/wc -l < "$new_manifest" | /usr/bin/tr -d ' ')
note "bundled and signed $library_count libraries and copied their notices"
