# Security policy

SOOM handles screen contents, voice, camera, input metadata, local paths, and an
optional user-provided API key. Treat any unexpected collection, transmission,
retention, or disclosure of that data as a security issue.

## Supported versions

Before the first stable release, security fixes are made on the default branch
and the most recent public preview only. Old development snapshots are not
supported. After a stable release, this table will list exact supported release
lines.

| Version | Supported |
| --- | --- |
| Default branch | Yes |
| Latest public preview | Yes |
| Older previews | No |

## Report a vulnerability privately

Do not open a public issue, discussion, or pull request containing vulnerability
details, secrets, private recordings, or personal data.

Use GitHub's **Security → Report a vulnerability** form for this repository. If
private vulnerability reporting has not yet been enabled, contact the
repository owner through the private contact address published on their GitHub
profile and ask for a secure reporting channel. Do not attach sensitive media
to the first message.

Include, when available:

- the affected version, commit, macOS version, and Mac model;
- whether the issue is in the local app, AI worker, share service, or
  transcoder;
- a minimal reproduction using synthetic data;
- expected and observed data flow;
- potential impact and whether exploitation is active; and
- a safe way for maintainers to contact you.

Encrypt sensitive follow-up material using a key agreed with the maintainer.
Never send an OpenAI key, Apple signing credential, real recording, or raw crash
dump unless it is strictly needed and the secure channel is confirmed.

## Response targets

These are targets rather than guarantees for a volunteer project:

- acknowledgement within 3 business days;
- initial severity and scope assessment within 7 business days;
- coordinated status updates at least every 14 days while a fix is active; and
- credit in the advisory unless the reporter requests anonymity.

The maintainers may ask you to delay public disclosure until a patch and safe
upgrade path are available. We will publish a GitHub Security Advisory for
issues that affect released software.

## High-priority examples

- API keys exposed outside Keychain or the intended provider process;
- raw keystrokes, face camera, video, audio, transcript, or absolute local paths
  leaving the Mac without explicit consent;
- a bypass of recording indicators or macOS permission expectations;
- code execution through session bundles, helper selection, update channels, or
  media parsing;
- access to another user's private share or inability to delete hosted media;
- signing, notarization, update, checksum, or release supply-chain compromise;
- logs or diagnostic bundles containing private content.

## Safe-harbor expectations

Good-faith research against software and infrastructure you own or have
explicit permission to test is welcome. Avoid privacy violations, service
degradation, persistence, social engineering, and accessing data that is not
yours. Stop after demonstrating the minimum impact and report it privately.
This policy does not authorize testing of OpenAI, Apple, Cloudflare, GitHub, or
other third-party systems.

## Release security

Official binary releases must pass `scripts/check-public-release.sh --release`.
That gate requires a Developer ID signature, hardened runtime, notarization
ticket, Gatekeeper acceptance, and verified checksums. Ad-hoc or Apple
Development builds are never official public releases.
