#!/bin/zsh
set -euo pipefail

echo "== Xcode =="
if [[ -d /Applications/Xcode.app ]]; then
    /usr/bin/xcode-select -p
    /usr/bin/xcodebuild -version
else
    echo "Xcode.app: 설치 필요"
fi

echo
echo "== Code signing identities =="
/usr/bin/security find-identity -v -p codesigning

echo
echo "== SOOM local development identity =="
local_identity_sha="$(/usr/bin/security find-certificate -c 'SOOM Local Development' -a -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | awk '/^SHA-1 hash:/ { print $3; exit }')"
if [[ -n "$local_identity_sha" ]]; then
    echo "SOOM Local Development: $local_identity_sha"
else
    echo "설치되지 않음"
fi

echo
echo "== Recommended build commands =="
echo "Local development: SIGNING_MODE=development scripts/build-app.sh"
echo "Temporary ad-hoc: SIGNING_MODE=adhoc scripts/build-app.sh"
echo "Public release: SIGNING_MODE=developer-id NOTARIZE=1 NOTARY_PROFILE=soom-notary scripts/build-app.sh"
echo "Final gate: scripts/check-public-release.sh --release"
