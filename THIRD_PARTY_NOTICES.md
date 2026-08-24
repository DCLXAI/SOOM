# Third-party notices

SOOM is distributed under Apache-2.0, but it uses software made available under
other licenses. Each dependency remains governed by its own license and
copyright notices.

This file is a human-maintained summary of direct dependencies in the source
tree. It is **not** a substitute for the complete machine-generated license and
SBOM inventory that must accompany each binary or container release.

## macOS app and AI worker

| Component | Declared license | Use |
| --- | --- | --- |
| [Bun](https://bun.sh/) | MIT and bundled third-party notices | Compiled TypeScript worker runtime and development tool |
| [OpenAI JavaScript SDK](https://github.com/openai/openai-node) | Apache-2.0 | BYOK API client |
| [Ajv](https://ajv.js.org/) | MIT | TaskSpec JSON Schema validation |
| [TypeScript](https://www.typescriptlang.org/) | Apache-2.0 | Worker type checking and build tooling |

The macOS target links system frameworks supplied by Apple. Those frameworks are
not redistributed as project source dependencies.

## Optional share web application

| Component | Declared license | Use |
| --- | --- | --- |
| [React](https://react.dev/) and React DOM | MIT | Share user interface |
| [Drizzle ORM](https://orm.drizzle.team/) | Apache-2.0 | Database access |
| [Vinext](https://github.com/cloudflare/vinext) | MIT | Web application framework adapter |
| [Vite](https://vite.dev/) | MIT | Web build tooling |
| [Cloudflare Wrangler](https://github.com/cloudflare/workers-sdk) | MIT OR Apache-2.0 | Development and deployment tooling |
| [Tailwind CSS](https://tailwindcss.com/) | MIT | CSS build tooling |

## Optional transcoder

| Component | Declared license | Use |
| --- | --- | --- |
| [Bun](https://bun.sh/) | MIT and bundled third-party notices | Service runtime |
| [FFmpeg](https://ffmpeg.org/) | LGPL/GPL depending on build configuration | Media probing and transcoding |
| [TypeScript](https://www.typescriptlang.org/) | Apache-2.0 | Type checking |

FFmpeg licensing depends on enabled codecs and build flags. A transcoder image
must not be published until its exact `ffmpeg -version`/`ffmpeg -L` output has
been reviewed and all corresponding license text, notices, and source-offer
obligations have been satisfied. In particular, builds using GPL components
such as `libx264` are not equivalent to an LGPL-only build.

## Release requirement

For every release, generate an SPDX or CycloneDX SBOM from the exact app and
container inputs, collect dependency license texts, compare the result with
this summary, and place the resulting notices beside the downloadable artifact.
Unidentified, non-redistributable, or incompatible dependencies block release.

If a required attribution is missing, please report it through the process in
[`SECURITY.md`](SECURITY.md) or open a non-sensitive documentation issue.
