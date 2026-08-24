#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/outputs"
rollback_root="$output_root/rollback"
app_root="$output_root/SOOM.app"
archive_path="$output_root/SOOM-macOS-arm64.zip"

latest_rollback="$(find "$rollback_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
    | xargs -0 stat -f '%m|%N' 2>/dev/null \
    | sort -t'|' -k1,1nr \
    | head -1 \
    | cut -d'|' -f2-)"

if [[ -z "$latest_rollback" || "$latest_rollback" != "$rollback_root/"* ]]; then
    echo "error: 복원할 이전 SOOM 빌드가 없습니다." >&2
    exit 2
fi

pkill -x SOOM 2>/dev/null || true
rm -rf "$app_root"
ditto "$latest_rollback/SOOM.app" "$app_root"
cp "$latest_rollback/SOOM-macOS-arm64.zip" "$archive_path"
codesign --verify --deep --strict --verbose=2 "$app_root"
open -n "$app_root"
echo "$app_root"
