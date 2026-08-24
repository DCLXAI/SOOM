# SOOM privacy model

SOOM is designed as a local-first recorder. A recording must work without a
SOOM account, hosted SOOM service, or AI request. Bring-your-own-key (BYOK) AI
processing is optional and is initiated by the person using the Mac.

This document defines the **public-release data contract**. Development builds
must not be presented as privacy-complete until automated tests and the release
gate prove these invariants.

## Local Only is the baseline

In Local Only mode, SOOM writes the selected screen, microphone, optional system
audio, optional camera composite, event metadata, generated frames, and results
to the user's Mac. No SOOM-operated server is contacted. The user chooses when
to process, export, share, retain, or delete a session.

The app may contact Apple for operating-system services such as notarization or
update validation. An update channel, if enabled in a future release, must be
documented separately and must not receive recording content.

## Data stored on the Mac

Depending on enabled features, a session can contain:

- screen video and system audio;
- microphone audio;
- an optional face-camera composite in the human-viewable recording;
- click, scroll, modifier, special-key, application, and window metadata;
- screen-only evidence images;
- transcript, TaskSpec, Markdown handoff, and reliability journal; and
- optional local project name and Git revision metadata.

Raw character content is not part of the public-release event format. Typing is
represented as time ranges and counts; a small allowlist can identify shortcut
and special keys without recording the text that was typed.

Session files remain until the user deletes them or enables a future retention
policy. Deleting a local session moves the complete bundle to the macOS Trash so
the user controls final removal. Secure erasure cannot be guaranteed on APFS or
solid-state storage.

## Optional OpenAI BYOK processing

When the user chooses TaskSpec processing, SOOM uses the OpenAI API key stored
in that user's macOS Keychain. Requests go directly from the Mac to OpenAI; the
open-source project does not proxy, receive, or bill for the key.

The post-recording request may include:

- microphone audio for transcription;
- the resulting transcript with timestamps;
- redacted input-event summaries;
- a limited set of screen-only evidence frames; and
- project display name, Git branch, and commit identifier.

It must not include:

- the MP4 or system-audio track;
- face-camera pixels unless the user separately opts in to that exact transfer;
- raw typed characters;
- absolute project paths or source files; or
- unrelated process environment, Keychain contents, or diagnostics.

If optional live transcription is enabled, microphone audio is streamed to the
selected AI provider while recording. The UI must show that state continuously.
Turning it off must not stop local recording.

OpenAI processes BYOK requests under the terms and data controls associated with
the user's API account. Users should review OpenAI's current API privacy and
retention documentation before enabling processing. SOOM requests that model
responses not be stored when the API supports that control, but SOOM cannot
override a provider's legal obligations or account-level settings.

## Permission use

SOOM asks only for permissions required by the enabled capture mode:

| Permission | Purpose | Required when |
| --- | --- | --- |
| Screen & System Audio Recording | Capture a selected display, window, or region | Screen capture is enabled |
| Microphone | Record and optionally transcribe narration | Microphone is enabled |
| Camera | Show and record the face-camera bubble | Camera is enabled |
| Input Monitoring | Capture click, scroll, and non-text activity metadata | Enhanced input evidence is explicitly enabled |

Declining Camera or Input Monitoring must not prevent a basic screen and voice
recording. SOOM does not attempt to bypass macOS Secure Input or other operating
system privacy controls.

## Logs and diagnostics

Local operational logs may include stage names, timestamps, duration, model
identifier, request identifier, token usage, media health counters, and redacted
errors. They must exclude API keys, request bodies, prompts, transcripts, raw
input, image/video/audio data, and absolute project paths.

Diagnostic export is opt-in and previewable. Crash reporting and telemetry are
off unless a future build presents a separate consent choice. Any future
telemetry endpoint, processor, retention period, and deletion mechanism must be
documented before it is enabled.

## Optional share components

The `share-web` and `transcoder` directories are experimental self-hosted
components. They are not contacted by the Local Only recorder and are not part
of the default privacy boundary. A person or organization deploying them is a
separate data controller and must publish its own privacy policy, security
contact, retention schedule, deletion process, abuse controls, and subprocessors.

Do not describe a hosted deployment as private merely because a link is hard to
guess. Private sharing requires scoped authentication, revocation, expiration,
rate limiting, and deletion of all database and object-storage copies.

## User responsibilities

Screen and voice recordings frequently contain personal, confidential, or
regulated information. Record only material you are authorized to capture,
obtain consent from people whose voice or face is included, review evidence
frames before AI processing, and follow workplace and local recording laws.

## Privacy issues

Unexpected collection or transfer is a security vulnerability. Report it using
the private process in [`SECURITY.md`](SECURITY.md), not a public issue.
