#!/bin/sh

set -eu

usage() {
    printf '%s\n' \
        "Usage: Scripts/check_signing_readiness.sh [--require-developer-id]" \
        "" \
        "Checks whether the active user keychain contains a code-signing" \
        "certificate paired with its private key. The optional flag requires" \
        "a Developer ID Application identity for notarized distribution."
}

require_developer_id=0
case "${1:-}" in
    "")
        ;;
    --require-developer-id)
        require_developer_id=1
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 64
fi

if ! identity_output=$(
    /usr/bin/security find-identity -v -p codesigning 2>&1
); then
    printf '%s\n' \
        "Signing preflight could not read the active user keychain:" \
        "$identity_output" >&2
    exit 1
fi

printf '%s\n' "$identity_output"

valid_count=$(
    printf '%s\n' "$identity_output" |
        /usr/bin/awk '/valid identities found$/ { print $1; exit }'
)
valid_count=${valid_count:-0}

if [ "$valid_count" -eq 0 ]; then
    printf '%s\n' \
        "" \
        "No usable signing identity is installed." \
        "A downloaded certificate alone is insufficient; Keychain Access must" \
        "show the certificate with its matching private key nested beneath it." \
        "" \
        "Fix:" \
        "1. Open Xcode > Settings > Accounts." \
        "2. Select your Apple ID and team, then Manage Certificates." \
        "3. Create Apple Development, or import the certificate on the Mac" \
        "   that created its certificate-signing request." \
        "4. Run this preflight again." >&2
    exit 2
fi

if [ "$require_developer_id" -eq 1 ] &&
    ! printf '%s\n' "$identity_output" |
        /usr/bin/grep -Fq '"Developer ID Application:'; then
    printf '%s\n' \
        "" \
        "A code-signing identity exists, but notarized distribution requires a" \
        "Developer ID Application identity from the paid Apple Developer Program." \
        "Apple Development is sufficient for local QA, not notarized distribution." >&2
    exit 3
fi

if [ "$require_developer_id" -eq 1 ]; then
    printf '%s\n' "Signing preflight passed for notarized distribution."
else
    printf '%s\n' "Signing preflight passed for local Apple-signed QA."
fi
