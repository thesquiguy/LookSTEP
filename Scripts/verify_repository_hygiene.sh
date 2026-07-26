#!/bin/bash

# Inspect tracked files plus untracked files that are not ignored—the exact
# commit-candidate set. Ignored local CAD fixtures and signing material are
# deliberately outside this verifier's read boundary.

set -u

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'error: repository hygiene: not inside a Git worktree\n' >&2
    exit 1
}
cd "$repository_root" || exit 1

failures=0

fail() {
    printf 'error: repository hygiene: %s\n' "$1" >&2
    failures=$((failures + 1))
}

is_commit_candidate() {
    git ls-files --cached --others --exclude-standard -- "$1" \
        | grep -F -x -q "$1"
}

while IFS= read -r -d '' tracked_path; do
    lowercase_path=$(printf '%s' "$tracked_path" | tr '[:upper:]' '[:lower:]')

    case "$lowercase_path" in
        testfiles/private/*)
            fail "private fixture path is tracked: $tracked_path"
            ;;
        build/*|*/build/*|deriveddata/*|*/deriveddata/*|*/xcuserdata/*|\
        *.profraw|*.profdata|*.xcresult|*.xcarchive|*.stlc|*.stepcache|\
        *.scenepkg)
            fail "generated build, coverage, or cache artifact is tracked: $tracked_path"
            ;;
        *.p12|*.pfx|*.cer|*.crt|*.der|*.key|*.pem|*.mobileprovision|\
        *.provisionprofile)
            fail "signing material is tracked: $tracked_path"
            ;;
        *.step|*.stp)
            case "$lowercase_path" in
                testfiles/redistributable/*)
                    provenance_path="TestFiles/Redistributable/PROVENANCE.md"
                    fixture_name=${tracked_path##*/}
                    if ! is_commit_candidate "$provenance_path"; then
                        fail "redistributable CAD fixture lacks tracked provenance: $tracked_path"
                    elif ! git grep -F -q -e "$fixture_name" -- "$provenance_path"; then
                        fail "CAD fixture is absent from its provenance register: $tracked_path"
                    fi
                    ;;
                *)
                    fail "CAD source is tracked outside TestFiles/Redistributable: $tracked_path"
                    ;;
            esac
            ;;
    esac

    case "$lowercase_path" in
        *.png|*.jpg|*.jpeg|*.gif|*.heic|*.tif|*.tiff|*.icns|*.svg)
            case "$tracked_path" in
                */*) asset_directory=${tracked_path%/*} ;;
                *) asset_directory=. ;;
            esac
            if ! is_commit_candidate "$asset_directory/PROVENANCE.md" \
               && ! is_commit_candidate "$asset_directory/ICON_PROVENANCE.md"; then
                fail "visual asset lacks a tracked directory provenance record: $tracked_path"
            fi
            ;;
    esac
done < <(git ls-files --cached --others --exclude-standard -z)

if team_hits=$(git grep --untracked -n -I -E \
    'DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}([;[:space:]]|$)|TeamIdentifier=[A-Z0-9]{10}([[:space:]]|$)' \
    -- . 2>/dev/null); then
    fail "literal Apple team identifier is tracked:
$team_hits"
fi

private_key_marker='BEGIN ''PRIVATE KEY'
if key_hits=$(git grep --untracked -n -I -F -e "$private_key_marker" -- . 2>/dev/null); then
    fail "private-key material is tracked:
$key_hits"
fi

if ((failures > 0)); then
    exit 1
fi

candidate_count=$(git ls-files --cached --others --exclude-standard \
    | wc -l | tr -d ' ')
printf 'Repository hygiene passed: %s commit-candidate files; ignored private files were not inspected\n' \
    "$candidate_count"
