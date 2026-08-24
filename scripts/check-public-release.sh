#!/bin/zsh

# Validate the source tree by default. Add --release only after producing the
# final Developer ID signed and notarized artifacts in outputs/.

emulate -LR zsh
setopt nounset pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="check"
skip_tests=0
failures=()

usage() {
    cat <<'EOF'
Usage: scripts/check-public-release.sh [--skip-tests] [--release]

  (no flag)     Validate public source structure, then run every test/lint gate.
  --skip-tests  Validate structure only. Intended for the dedicated CI job.
  --release     Run all source gates and additionally require a Developer ID
                signature, hardened runtime, notarization ticket, Gatekeeper
                acceptance, archive shape, and matching checksums.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --skip-tests)
            skip_tests=1
            ;;
        --release)
            mode="release"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "error: unknown argument: $argument"
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$mode" == "release" && "$skip_tests" == 1 ]]; then
    print -u2 "error: --release cannot be combined with --skip-tests"
    exit 2
fi

pass() {
    print "  PASS  $1"
}

fail() {
    local message="$1"
    print -u2 "  FAIL  $message"
    failures+=("$message")
}

section() {
    print
    print "== $1 =="
}

run_step() {
    local label="$1"
    shift
    print -r -- "-- $label"
    if "$@"; then
        pass "$label"
    else
        local task_exit=$?
        fail "$label (exit $task_exit)"
    fi
}

require_file() {
    local relative_path="$1"
    if [[ -f "$repo_root/$relative_path" ]]; then
        pass "$relative_path exists"
    else
        fail "$relative_path is missing"
    fi
}

require_command() {
    local command_name="$1"
    if command -v "$command_name" >/dev/null 2>&1; then
        pass "$command_name is available"
    else
        fail "$command_name is required"
    fi
}

check_worker() {
    cd "$repo_root/worker" || return 1
    bun install --frozen-lockfile \
        && bun audit \
        && bun run typecheck \
        && bun test \
        && bun run build
}

check_share_web() {
    cd "$repo_root/share-web" || return 1
    npm ci \
        && npm run typecheck \
        && npm audit --omit=dev \
        && npm run lint \
        && npm test
}

check_transcoder() {
    cd "$repo_root/transcoder" || return 1
    bun install --frozen-lockfile \
        && bun audit \
        && bun run check
}

check_swift() {
    cd "$repo_root" || return 1
    swift test --parallel
}

section "Required public files"
for required in \
    VERSION \
    LICENSE \
    TRADEMARKS.md \
    README.md \
    CONTRIBUTING.md \
    CODE_OF_CONDUCT.md \
    SECURITY.md \
    PRIVACY.md \
    THIRD_PARTY_NOTICES.md \
    CHANGELOG.md \
    .gitignore \
    .github/workflows/ci.yml \
    .github/workflows/codeql.yml \
    .github/dependabot.yml \
    worker/bun.lock \
    share-web/package-lock.json \
    transcoder/bun.lock; do
    require_file "$required"
done

section "Version and manifests"
version=""
if [[ -f "$repo_root/VERSION" ]]; then
    version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
fi

if [[ "$version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$' ]]; then
    pass "VERSION is valid SemVer ($version)"
else
    fail "VERSION must contain one SemVer value"
fi

if /usr/bin/plutil -lint "$repo_root/scripts/Info.plist" >/dev/null; then
    pass "scripts/Info.plist is valid"
else
    fail "scripts/Info.plist is invalid"
fi

plist_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$repo_root/scripts/Info.plist" 2>/dev/null || true)"
build_number="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$repo_root/scripts/Info.plist" 2>/dev/null || true)"

if [[ -n "$version" && "$plist_version" == "$version" ]]; then
    pass "VERSION matches CFBundleShortVersionString"
else
    fail "VERSION ($version) does not match CFBundleShortVersionString ($plist_version)"
fi

if [[ "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    pass "CFBundleVersion is a positive integer ($build_number)"
else
    fail "CFBundleVersion must be a positive integer"
fi

if [[ -n "$version" ]] && grep -Fq "## [$version]" "$repo_root/CHANGELOG.md"; then
    pass "CHANGELOG contains version $version"
else
    fail "CHANGELOG does not contain version $version"
fi

if command -v node >/dev/null 2>&1; then
    if (
        cd "$repo_root/share-web" || exit 1
        node -e '
          const manifest = require("./package.json");
          const lock = require("./package-lock.json");
          const root = lock.packages?.[""];
          if (lock.name !== manifest.name || root?.name !== manifest.name ||
              lock.version !== manifest.version || root?.version !== manifest.version) {
            console.error("share-web package.json and package-lock.json metadata differ");
            process.exit(1);
          }
        '
    ); then
        pass "share-web package metadata matches its lockfile"
    else
        fail "share-web package metadata does not match its lockfile"
    fi

    if node -e '
      for (const path of process.argv.slice(1)) {
        const manifest = require(path);
        if (manifest.private !== true) {
          console.error(`${path} must remain private; VERSION governs the app release`);
          process.exitCode = 1;
        }
      }
    ' \
        "$repo_root/worker/package.json" \
        "$repo_root/share-web/package.json" \
        "$repo_root/transcoder/package.json"; then
        pass "internal JavaScript packages are marked private"
    else
        fail "internal JavaScript packages must be marked private"
    fi
else
    fail "node is required to validate package metadata"
fi

for bun_component in worker transcoder; do
    package_name="$(
        node -e 'console.log(require(process.argv[1]).name)' \
            "$repo_root/$bun_component/package.json" 2>/dev/null || true
    )"
    if [[ -n "$package_name" ]] \
        && grep -Fq '"name": "'"$package_name"'"' "$repo_root/$bun_component/bun.lock"; then
        pass "$bun_component package name matches its lockfile"
    else
        fail "$bun_component package name does not match its lockfile"
    fi
done

section "Repository hygiene"
if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_root="$(git -C "$repo_root" rev-parse --show-toplevel)"
    if [[ "$git_root" == "$repo_root" ]]; then
        pass "repository root is the Git root"
    else
        fail "Git root is $git_root, expected $repo_root"
    fi

    forbidden_tracked=()
    while IFS= read -r tracked_path; do
        [[ -z "$tracked_path" ]] && continue
        case "$tracked_path" in
            .env.example|*/.env.example)
                ;;
            .DS_Store|*/.DS_Store|.build/*|.swiftpm/*|DerivedData/*|*/DerivedData/*|*/node_modules/*|worker/dist/*|share-web/.next/*|share-web/.vinext/*|share-web/dist/*|share-web/out/*|share-web/.wrangler/*|*/.openai/hosting.json|share-web/coverage/*|transcoder/dist/*|coverage/*|outputs/*|work/*|*.xcuserstate|*.dSYM/*|*.crash|.env|.env.*|*/.env|*/.env.*|*.pem|*.p12|*.cer|*.provisionprofile)
                forbidden_tracked+=("$tracked_path")
                ;;
        esac
    done < <(git -C "$repo_root" ls-files)

    if (( ${#forbidden_tracked[@]} == 0 )); then
        pass "no generated, credential, session, or artifact paths are tracked"
    else
        fail "forbidden tracked paths: ${(j:, :)forbidden_tracked}"
    fi

    gitlinks="$(git -C "$repo_root" ls-files --stage | awk '$1 == "160000" { print $4 }')"
    if [[ -z "$gitlinks" ]]; then
        pass "no embedded Git repositories are staged as submodules"
    else
        fail "unexpected Git submodules: ${(j:, :)${(f)gitlinks}}"
    fi

    secret_matches="$(
        git -C "$repo_root" grep -IEn \
            '(sk-[A-Za-z0-9_-]{20,}|-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----)' \
            -- . ':!scripts/check-public-release.sh' 2>/dev/null || true
    )"
    if [[ -z "$secret_matches" ]]; then
        pass "tracked-source secret canary found no obvious private key or API key"
    else
        fail "tracked-source secret canary found a possible credential"
    fi
else
    fail "repository root is not initialized as a Git repository"
fi

nested_repositories="$(
    find "$repo_root" \
        \( -path "$repo_root/.build" \
           -o -path "$repo_root/outputs" \
           -o -path "$repo_root/work" \
           -o -name node_modules \) -prune \
        -o -mindepth 2 -name .git \( -type d -o -type f \) -print
)"
if [[ -z "$nested_repositories" ]]; then
    pass "no nested Git metadata exists"
else
    nested_relative="${nested_repositories//$repo_root\//}"
    fail "nested Git metadata must be flattened before publication: ${(j:, :)${(f)nested_relative}}"
fi

section "Tooling"
require_command swift
require_command bun
require_command node
require_command npm

if [[ "$skip_tests" == 0 ]]; then
    section "Build, lint, and tests"
    run_step "Swift tests" check_swift
    run_step "AI worker build, type-check, and tests" check_worker
    run_step "Share web lint, build, and tests" check_share_web
    run_step "Transcoder type-check" check_transcoder
else
    print "  SKIP  build, lint, and tests (--skip-tests)"
fi

if [[ "$mode" == "release" ]]; then
    section "Signed and notarized release artifacts"
    app_path="$repo_root/outputs/SOOM.app"
    archive_path="$repo_root/outputs/SOOM-macOS-arm64.zip"
    checksum_path="$repo_root/outputs/SHA256SUMS.txt"

    if [[ -d "$app_path" ]]; then
        pass "SOOM.app exists"
    else
        fail "outputs/SOOM.app is missing"
    fi
    if [[ -f "$archive_path" ]]; then
        pass "SOOM-macOS-arm64.zip exists"
    else
        fail "outputs/SOOM-macOS-arm64.zip is missing"
    fi
    if [[ -f "$checksum_path" ]]; then
        pass "SHA256SUMS.txt exists"
    else
        fail "outputs/SHA256SUMS.txt is missing"
    fi

    if [[ -d "$app_path" ]]; then
        artifact_version="$(
            /usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
                "$app_path/Contents/Info.plist" 2>/dev/null || true
        )"
        artifact_signing_mode="$(
            /usr/bin/plutil -extract SOOMSigningMode raw -o - \
                "$app_path/Contents/Info.plist" 2>/dev/null || true
        )"
        if [[ "$artifact_version" == "$version" ]]; then
            pass "artifact version matches VERSION"
        else
            fail "artifact version ($artifact_version) does not match VERSION ($version)"
        fi
        if [[ "$artifact_signing_mode" == "developer-id" ]]; then
            pass "artifact declares Developer ID release mode"
        else
            fail "artifact declares non-release signing mode ($artifact_signing_mode)"
        fi

        for legal_name in LICENSE TRADEMARKS.md THIRD_PARTY_NOTICES.md; do
            legal_path="$app_path/Contents/Resources/Legal/$legal_name"
            if [[ -f "$legal_path" ]] && cmp -s "$repo_root/$legal_name" "$legal_path"; then
                pass "artifact embeds current $legal_name"
            else
                fail "artifact does not embed current $legal_name"
            fi
        done

        run_step "codesign strict verification" \
            /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
        run_step "helper codesign strict verification" \
            /usr/bin/codesign --verify --strict --verbose=2 \
                "$app_path/Contents/Helpers/soom-worker"

        signature_info="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
        if print -r -- "$signature_info" | grep -q '^Authority=Developer ID Application:'; then
            pass "artifact uses a Developer ID Application certificate"
        else
            fail "artifact is not signed with Developer ID Application"
        fi
        if print -r -- "$signature_info" | grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$'; then
            pass "artifact has an Apple TeamIdentifier"
        else
            fail "artifact has no valid Apple TeamIdentifier"
        fi
        if print -r -- "$signature_info" | grep -Eq 'flags=.*\(runtime\)'; then
            pass "artifact enables hardened runtime"
        else
            fail "artifact does not enable hardened runtime"
        fi

        helper_signature_info="$(
            /usr/bin/codesign -dv --verbose=4 \
                "$app_path/Contents/Helpers/soom-worker" 2>&1 || true
        )"
        app_team="$(print -r -- "$signature_info" | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
        helper_team="$(print -r -- "$helper_signature_info" | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
        if [[ -n "$app_team" && "$helper_team" == "$app_team" ]]; then
            pass "app and helper use the same Apple team"
        else
            fail "app and helper Apple teams differ"
        fi

        run_step "notarization ticket validation" \
            /usr/bin/xcrun stapler validate "$app_path"
        run_step "Gatekeeper assessment" \
            /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
    fi

    if [[ -f "$archive_path" ]]; then
        if /usr/bin/unzip -Z1 "$archive_path" | grep -q '^SOOM.app/Contents/MacOS/SOOM$'; then
            pass "archive contains the expected app bundle"
        else
            fail "archive does not contain SOOM.app at its root"
        fi
    fi

    if [[ -f "$checksum_path" ]]; then
        if awk '{ print $2 }' "$checksum_path" | grep -Fxq 'outputs/SOOM-macOS-arm64.zip'; then
            pass "checksum manifest lists the macOS archive"
        else
            fail "checksum manifest does not list outputs/SOOM-macOS-arm64.zip"
        fi
        run_step "SHA-256 checksum verification" \
            /bin/zsh -c "cd ${(q)repo_root} && /usr/bin/shasum -a 256 -c outputs/SHA256SUMS.txt"
    fi
fi

section "Result"
if (( ${#failures[@]} > 0 )); then
    print -u2 "Public-release readiness failed with ${#failures[@]} issue(s):"
    for failure_message in "${failures[@]}"; do
        print -u2 "  - $failure_message"
    done
    exit 1
fi

if [[ "$mode" == "release" ]]; then
    print "SOOM public release is source-verified, signed, notarized, and checksum-verified."
else
    print "SOOM public source tree is ready for review. No artifact was signed or published."
fi
