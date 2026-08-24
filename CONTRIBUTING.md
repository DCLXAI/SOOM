# Contributing to SOOM

Thank you for helping make screen-to-task workflows dependable and private.
SOOM is a local-first macOS recorder; changes that weaken that boundary need an
explicit design and security review.

## Before you start

- Search existing issues and pull requests before opening duplicate work.
- Use an issue to discuss a large feature, capture-format change, new network
  destination, new permission, or schema-breaking change first.
- Never include recordings, transcripts, API keys, personal paths, signing
  certificates, provisioning profiles, or production credentials in an issue,
  fixture, log, or commit.
- Use synthetic or explicitly consented and redacted media in tests.

The default product scope is local recording plus optional bring-your-own-key
(BYOK) TaskSpec generation. The share web application and transcoder are
optional, separately deployed components and are not required for the local
recorder.

## Development requirements

- macOS 15 or newer on Apple Silicon
- Xcode with the Swift 6 toolchain
- Bun 1.3 or newer
- Node.js 22.13 or newer and npm
- An OpenAI API key only for manual BYOK integration tests

Do not put an API key in `.env`, shell history, test snapshots, screenshots, or
source code. The macOS app stores its user-provided key in Keychain.

## Set up and verify

```bash
swift test

cd worker
bun install --frozen-lockfile
bun run typecheck
bun test
cd ..

cd share-web
npm ci
npm run lint
npm test
cd ..

cd transcoder
bun install --frozen-lockfile
bun run check
cd ..
```

Run the complete public-source gate from the repository root before opening a
pull request:

```bash
scripts/check-public-release.sh
```

This command does not notarize or publish anything. Release maintainers run
`scripts/check-public-release.sh --release` only after building a Developer ID
signed, notarized artifact and generating its checksums.

`VERSION` and `CFBundleShortVersionString` are the macOS product release
version. The private `worker`, `share-web`, and `transcoder` package versions are
internal implementation versions and do not need to match the product version.

## Privacy and security invariants

A pull request must not silently change these guarantees:

- Recording works in Local Only mode without an account or hosted SOOM server.
- No raw character content is persisted or exported by default.
- Video, system audio, face camera, source files, and absolute project paths are
  not sent to an AI provider for TaskSpec generation.
- AI evidence uses screen-only frames by default. Sending a face-composited
  frame requires a separate, explicit user action.
- Only the user-selected provider receives BYOK data, and every network feature
  is visible and optional.
- Logs and diagnostics exclude API keys, prompts, transcripts, raw input, and
  media.

Tests should prove the relevant invariant whenever a change touches capture,
event collection, AI payload construction, export, logs, or networking. Read
[`PRIVACY.md`](PRIVACY.md) and [`SECURITY.md`](SECURITY.md) before working in
those areas.

## Code and schema changes

- Keep capture callbacks bounded; do not add unbounded media queues.
- Use one monotonic media timeline and test pause/resume and A/V alignment.
- Preserve backward readability of session bundles whenever practical.
- Treat `schemas/TaskSpec.v1.json` as the TaskSpec contract. A breaking change
  requires a new schema version, migration notes, fixtures, and a changelog
  entry.
- Keep Korean and English user-facing copy accessible and localizable.
- Prefer dependency injection and small actors/services over adding more state
  to the application model.

## Pull requests

Keep changes focused and include:

1. the user-visible outcome and motivation;
2. privacy, permission, storage, networking, and compatibility impact;
3. tests run and their exact results;
4. screenshots or short synthetic recordings for UI changes; and
5. a `CHANGELOG.md` entry for user-visible behavior.

By submitting a contribution, you agree that it is licensed under Apache-2.0
and that you have the right to submit it. Do not submit third-party code unless
its license is compatible and its attribution has been added to
`THIRD_PARTY_NOTICES.md`.

## Reporting sensitive problems

Do not open a public issue for a vulnerability or privacy leak. Follow the
private process in [`SECURITY.md`](SECURITY.md).
