#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/outputs"
app_root="$output_root/SOOM.app"
public_archive_path="$output_root/SOOM-macOS-arm64.zip"
local_archive_path="$output_root/SOOM-macOS-arm64-LOCAL-ONLY.zip"
checksum_path="$output_root/SHA256SUMS.txt"
rollback_root="$output_root/rollback"
app_entitlements="$repo_root/scripts/SOOM.entitlements"
worker_entitlements="$repo_root/scripts/SOOMWorker.entitlements"
signing_mode="${SIGNING_MODE:-auto}"
requested_identity="${SIGNING_IDENTITY:-}"
notarize="${NOTARIZE:-0}"
notary_profile="${NOTARY_PROFILE:-}"

installed_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
local_identity_name="SOOM Local Development"
local_identity_sha="$(security find-certificate -c "$local_identity_name" -a -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | awk '/^SHA-1 hash:/ { print $3; exit }')"

first_identity() {
    local prefix="$1"
    printf '%s\n' "$installed_identities" | awk -F'"' -v prefix="$prefix" '$2 ~ "^" prefix { print $2; exit }'
}

if [[ -n "$requested_identity" ]]; then
    if [[ "$requested_identity" == "$local_identity_name" && -n "$local_identity_sha" ]]; then
        signing_identity="$local_identity_sha"
    else
        signing_identity="$requested_identity"
    fi
    if ! printf '%s\n' "$installed_identities" | grep -Fq "\"$requested_identity\"" \
        && [[ "$requested_identity" != "$local_identity_name" || -z "$local_identity_sha" ]]; then
        echo "error: SIGNING_IDENTITY가 Keychain의 유효한 코드 서명 인증서와 일치하지 않습니다: $signing_identity" >&2
        exit 2
    fi
elif [[ "$signing_mode" == "developer-id" ]]; then
    signing_identity="$(first_identity 'Developer ID Application:')"
elif [[ "$signing_mode" == "development" ]]; then
    signing_identity="$(first_identity 'Apple Development:')"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$local_identity_sha"
    fi
elif [[ "$signing_mode" == "adhoc" ]]; then
    signing_identity="-"
elif [[ "$signing_mode" == "auto" ]]; then
    # Automatic builds are always local builds. A public Developer ID release
    # must be selected explicitly so it cannot skip notarization by accident.
    signing_identity="$(first_identity 'Apple Development:')"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$local_identity_sha"
    fi
    if [[ -z "$signing_identity" && "${ALLOW_ADHOC:-0}" == "1" ]]; then
        signing_identity="-"
    fi
else
    echo "error: SIGNING_MODE는 auto, development, developer-id, adhoc 중 하나여야 합니다." >&2
    exit 2
fi

if [[ -z "$signing_identity" ]]; then
    echo "error: 사용할 수 있는 코드 서명 인증서가 없습니다." >&2
    echo "       Xcode > Settings > Accounts > Manage Certificates에서 Apple Development 인증서를 생성하거나" >&2
    echo "       Apple Developer에서 Developer ID Application 인증서를 설치하세요." >&2
    echo "       임시 로컬 빌드만 필요하면 SIGNING_MODE=adhoc을 명시하세요." >&2
    exit 2
fi

if [[ "$signing_identity" == "-" ]]; then
    signing_kind="adhoc"
elif [[ "$signing_identity" == Developer\ ID\ Application:* ]]; then
    signing_kind="developer-id"
elif [[ -n "$local_identity_sha" && "$signing_identity" == "$local_identity_sha" ]]; then
    signing_kind="local-development"
else
    signing_kind="development"
fi

if [[ "$signing_kind" == "developer-id" ]]; then
    if [[ "$notarize" != "1" ]]; then
        echo "error: Developer ID 빌드는 공개 릴리스이므로 NOTARIZE=1이 필수입니다." >&2
        echo "       로컬 테스트에는 SIGNING_MODE=development를 사용하세요." >&2
        exit 2
    fi
    if [[ -z "$notary_profile" ]]; then
        echo "error: Developer ID 릴리스에는 NOTARY_PROFILE Keychain 프로필이 필요합니다." >&2
        exit 2
    fi
    archive_path="$public_archive_path"
else
    if [[ "$notarize" == "1" ]]; then
        echo "error: notarization은 Developer ID Application 공개 릴리스에서만 사용할 수 있습니다." >&2
        exit 2
    fi
    archive_path="$local_archive_path"
fi

product_version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/scripts/Info.plist")"
if [[ "$product_version" != "$plist_version" ]]; then
    echo "error: VERSION($product_version)과 Info.plist($plist_version)의 버전이 다릅니다." >&2
    exit 2
fi

cd "$repo_root/worker"
bun install --frozen-lockfile
bun run build

cd "$repo_root"
swift build -c release --arch arm64
swift "$repo_root/scripts/generate-app-icon.swift"

if [[ -d "$app_root" && -f "$archive_path" ]]; then
    previous_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_root/Contents/Info.plist" 2>/dev/null || echo unknown)"
    previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_root/Contents/Info.plist" 2>/dev/null || echo unknown)"
    rollback_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    rollback_directory="$rollback_root/${previous_version}-${previous_build}-${rollback_stamp}"
    mkdir -p "$rollback_directory"
    ditto "$app_root" "$rollback_directory/SOOM.app"
    cp "$archive_path" "$rollback_directory/$(basename "$archive_path")"
    find "$rollback_root" -mindepth 1 -maxdepth 1 -type d -print0 \
        | xargs -0 stat -f '%m|%N' \
        | sort -t'|' -k1,1nr \
        | tail -n +4 \
        | cut -d'|' -f2- \
        | while IFS= read -r expired_rollback; do
            [[ "$expired_rollback" == "$rollback_root/"* ]] && rm -rf "$expired_rollback"
        done
fi

rm -rf "$app_root"
rm -f "$archive_path"
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Helpers" "$app_root/Contents/Resources"
mkdir -p "$app_root/Contents/Resources/Legal"
cp "$repo_root/.build/arm64-apple-macosx/release/SOOM" "$app_root/Contents/MacOS/SOOM"
cp "$repo_root/worker/dist/soom-worker" "$app_root/Contents/Helpers/soom-worker"
cp "$repo_root/schemas/TaskSpec.v1.json" "$app_root/Contents/Resources/TaskSpec.v1.json"
cp "$repo_root/scripts/SOOM.icns" "$app_root/Contents/Resources/SOOM.icns"
cp "$repo_root/scripts/Info.plist" "$app_root/Contents/Info.plist"
cp "$repo_root/LICENSE" "$app_root/Contents/Resources/Legal/LICENSE"
cp "$repo_root/TRADEMARKS.md" "$app_root/Contents/Resources/Legal/TRADEMARKS.md"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$app_root/Contents/Resources/Legal/THIRD_PARTY_NOTICES.md"
chmod 755 "$app_root/Contents/MacOS/SOOM" "$app_root/Contents/Helpers/soom-worker"

/usr/libexec/PlistBuddy -c "Add :SOOMSigningMode string $signing_kind" "$app_root/Contents/Info.plist"

signing_options=(--force --options runtime --sign "$signing_identity")
if [[ "$signing_identity" == Developer\ ID\ Application:* ]]; then
    signing_options+=(--timestamp)
else
    signing_options+=(--timestamp=none)
fi

codesign "${signing_options[@]}" --entitlements "$worker_entitlements" "$app_root/Contents/Helpers/soom-worker"
codesign "${signing_options[@]}" --entitlements "$app_entitlements" "$app_root"
codesign --verify --strict --verbose=2 "$app_root/Contents/Helpers/soom-worker"
codesign --verify --deep --strict --verbose=2 "$app_root"

if [[ "$signing_kind" == "local-development" ]]; then
    echo "Signing identity: $local_identity_name ($signing_identity)"
else
    echo "Signing identity: $signing_identity"
fi
codesign --display --verbose=4 "$app_root" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Runtime Version)='

ditto -c -k --sequesterRsrc --keepParent "$app_root" "$archive_path"

if [[ "$signing_kind" == "developer-id" ]]; then
    xcrun notarytool submit "$archive_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_root"
    xcrun stapler validate "$app_root"
    rm -f "$archive_path"
    ditto -c -k --sequesterRsrc --keepParent "$app_root" "$archive_path"
    spctl --assess --type execute --verbose=4 "$app_root"

    checksum_temp="$(mktemp "$output_root/.SHA256SUMS.txt.XXXXXX")"
    archive_checksum="$(shasum -a 256 "$archive_path" | awk '{ print $1 }')"
    printf '%s  outputs/%s\n' "$archive_checksum" "$(basename "$archive_path")" > "$checksum_temp"
    mv "$checksum_temp" "$checksum_path"
    echo "Public release checksum: $checksum_path"
else
    echo "LOCAL BUILD ONLY: this archive is not Developer ID notarized and must not be published." >&2
fi

echo "$app_root"
echo "$archive_path"
