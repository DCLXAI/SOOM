# SOOM — Show it. Say it. Ship it.

SOOM은 macOS 메뉴바에서 최대 3분 동안 화면, webcam, 시스템 오디오, 마이크와
선택적 입력 활동을 로컬에 기록하는 Apple Silicon용 MVP입니다. 사용자가 원하면
자신의 OpenAI API 키(BYOK)로 실시간 자막과 `TaskSpec`/`AGENT_TASK.md`를 만들 수
있습니다. API 키, SOOM 계정과 hosted server는 녹화에 필요하지 않습니다.

## 오픈소스 경계

공개 제품의 기본 경계는 **Local Only 녹화 + 선택적 OpenAI BYOK TaskSpec**입니다.
로컬 녹화는 SOOM 계정이나 hosted server 없이 동작해야 하며, `share-web/`과
`transcoder/`는 기본 앱이 접속하지 않는 실험적 self-hosted 구성요소입니다.

- 라이선스: [Apache-2.0](LICENSE), 제품명·로고는 [별도 상표 정책](TRADEMARKS.md)
- 기여: [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- 개인정보: [PRIVACY.md](PRIVACY.md)
- 보안 신고: [SECURITY.md](SECURITY.md)
- 배포 의존성: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- 변경 이력: [CHANGELOG.md](CHANGELOG.md)
- 구조와 신뢰 경계: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 공개 로드맵: [docs/ROADMAP.md](docs/ROADMAP.md)
- 테스트·릴리스 증거: [docs/TESTING.md](docs/TESTING.md)

현재 소스는 공개 릴리스 gate를 통과하기 전의 development snapshot입니다. 공식
binary는 Developer ID 서명, notarization, Gatekeeper, checksum 검증을 모두 통과한
GitHub Release 자산만을 의미합니다.

## 사용자 흐름

1. 앱을 열고 화면 녹화와 마이크 권한을 허용합니다. facecam을 켤 때만 카메라
   권한이 추가로 필요합니다. 입력 모니터링과 OpenAI API 키는 선택 사항입니다.
2. 녹화 준비 화면에서 디스플레이, facecam, 프로젝트·내보내기 폴더를 확인합니다.
   카메라는 시작 전에 실제 영상으로 미리 볼 수 있습니다. API 키를 저장한
   사용자는 실시간 AI 자막을 별도로 켤 수 있습니다.
3. `녹화 시작` 또는 `⌥⌘R`을 누르면 3초 카운트다운 뒤 녹화가 시작됩니다. 이동 가능한 원형 webcam bubble을 띄운 채 화면을 가리키고 수정사항을 말합니다.
4. 흰색 컨트롤 바에서 실시간 마이크 레벨을 확인하고 저장·종료, 일시정지·재개, 취소·삭제 중 하나를 선택합니다. 3분이 되면 자동 종료됩니다.
5. 모든 원본은 Mac 안에 남고, 재생 가능한 영상이 먼저 `recorded` 상태로
   확정됩니다. OpenAI 처리 실패나 API 키 부재는 이 녹화를 실패로 바꾸지 않습니다.
6. API 키가 있으면 종료 직후 또는 나중에 한국어 TaskSpec을 만들 수 있습니다.
   작업의 근거 시간을 누르면 영상이 해당 순간으로 이동합니다.
7. `Codex / Claude Code용 작업 복사`로 TaskSpec과 로컬 원본 영상 경로를
   전달합니다. 에이전트 자동 실행은 현재 범위에 포함하지 않습니다.

현재 camera-only mode도 소스 준비 과정에서 ScreenCaptureKit을 사용하므로 화면
녹화 권한이 필요합니다. 이 불필요한 의존성을 제거하는 direct camera writer는
[로드맵](docs/ROADMAP.md)의 다음 단계입니다.

## 산출물

원본 세션은 `~/Library/Application Support/SOOM/Sessions/<session-id>/`에 보존됩니다. 이전 ShowTell AI의 실패 세션도 재처리를 위해 계속 탐색합니다.

```text
session.json
journal.json
diagnostics.ndjson
events.ndjson
screen-system.mp4     # 합성 video intermediate
system-audio.m4a
recording.mp4          # 화면 + 원형 facecam + 시스템 오디오 + 마이크
microphone.m4a
frames/                 # screen-only AI evidence
transcript.json
taskspec.json
taskspec.md
AGENT_TASK.md
```

선택한 내보내기 폴더에는 충돌 없는 세션 디렉터리로 다음 파일만 저장됩니다.

```text
taskspec.json
taskspec.md
AGENT_TASK.md
evidence/*.jpg
```

원본 영상과 입력 이벤트 로그는 자동 내보내지 않습니다. 결과 화면에서 원본 영상을
재생하거나 세션 폴더를 열 수 있으며, Agent 작업을 복사할 때 로컬
`recording.mp4` 경로가 ground truth로 함께 붙습니다.

## 녹화 신뢰성 기반과 검증 상태

- 2초 단위 fragmented MP4/M4A와 1초 heartbeat `journal.json`을 기록합니다.
- 프로세스 비정상 종료 후 다음 실행에서 미디어 조각을 병합하고 근거 프레임 index를 복구합니다.
- 화면·마이크 마지막 timestamp와 100ms 초과 sync drift, writer drop, 디스크·thermal 상태를 기록합니다.
- 디스플레이 분리, 마이크 분리, 잠자기 진입 시 녹화를 안전하게 마감합니다. 카메라는 재연결을 시도합니다.
- 기본 품질은 1080p/30fps이고 설정에서 4K/30fps를 선택할 수 있습니다.
- 녹화 보관함에서 세션 검색, 재열기, AI 재처리와 휴지통 삭제를 지원합니다.
- 진단 동의 시에만 media·transcript·키 입력이 제외된 support bundle을 만들 수 있습니다.
- 새 빌드 전 최근 서명 빌드 3개를 `outputs/rollback/`에 보관하며 `scripts/restore-previous-build.sh`로 복원합니다.

위 항목은 현재 구현된 방어 장치입니다. 아직 동일 release candidate에서 연속
100회 녹화, 비정상 종료 복구율 99%, 최종 A/V sync 100ms 이하와 stop 후 2초
결과 표시를 입증한 공개 test report는 아닙니다. 이 수치를 통과하기 전에는
development snapshot이며, 측정 방법과 gate는 [docs/TESTING.md](docs/TESTING.md)에
정의합니다.

## 개인정보 경계

- 원시 키 문자와 printable virtual key code는 capture callback에서 제거되어 신규
  `events.ndjson`에도 저장되지 않습니다.
- 로컬 event와 AI 타임라인에는 타이핑 구간·개수와 안전한 단축키·특수키만
  남습니다. 구버전 세션은 시작 시 fail-closed privacy migration을 거칩니다.
- OpenAI 요청에는 MP4, 시스템 오디오, 원시 키 문자, 프로젝트 절대 경로, 소스 파일을 넣지 않습니다.
- OpenAI 요청은 마이크 전사, 정제된 이벤트, 최대 12장 근거 프레임, 프로젝트명·branch·HEAD만 사용합니다.
- API 키는 macOS Keychain의 `WhenUnlockedThisDeviceOnly` 항목에 저장되고 helper의
  argv나 환경변수가 아닌 일회성 stdin pipe로 전달됩니다.
- webcam 영상은 표정 분석에 사용하지 않으며 Loom 스타일 원본 설명 영상에만 합성됩니다.
- 실시간 자막을 켜면 마이크 PCM만 `gpt-live-transcribe` Realtime 세션에 전송합니다. 화면·webcam·시스템 오디오·키 입력은 Realtime 세션에 전송하지 않습니다.
- Realtime 연결 실패는 로컬 녹화나 종료 후 TaskSpec 생성을 중단시키지 않습니다.
- 녹화 취소는 전체 세션을 macOS 휴지통으로 이동합니다.
- 저장 방식의 초기값은 항상 `Local Only`이며 이 모드에서는 공유 서버 요청이 발생하지 않습니다.

## 실험적 self-hosted 공유 코드

`share-web/`과 `transcoder/`에는 self-hosted 공유를 실험하기 위한 코드가 있지만,
공개 local-first 앱에서는 `hostedShareEnabled = false`로 네트워크와 UI가 모두
비활성화되어 있습니다. 이 코드는 multi-user authorization, tenant isolation,
완전 삭제·backup retention, abuse/rate limit과 운영 대응이 검증되지 않았으므로
상용 hosted service 또는 기본 제품 기능으로 간주하면 안 됩니다.

별도 운영자가 이 구성요소를 배포할 경우 독립적인 data controller로서 개인정보
정책, 보안 연락처, retention/deletion과 subprocessors를 직접 정의해야 합니다.

## AI 계약

- 실시간 자막: Realtime API `gpt-live-transcribe`, 24 kHz PCM, server VAD, 한국어·영어
- 전사: `whisper-1`, `verbose_json`, word timestamps
- 이해: Responses API `gpt-5.6`, `reasoning.effort: medium`, `store: false`
- 이미지: 최대 12장, `detail: original`
- 출력: `schemas/TaskSpec.v1.json` strict Structured Output 및 로컬 AJV 재검증
- 일시적 API 오류: 최대 2회 지수 backoff 재시도

## 개발 및 빌드

요구사항: macOS 15+, Apple Silicon, Swift 6 toolchain, Bun 1.3+. Apple 서명 인증서를 생성하려면 전체 Xcode와 Apple Developer 계정이 필요합니다.

```bash
swift build
swift test

cd worker
bun install --frozen-lockfile
bun audit
bun run typecheck
bun test
cd ..

cd share-web
npm ci
npm run typecheck
npm audit --omit=dev
npm run lint
npm test
cd ..

cd transcoder
bun install --frozen-lockfile
bun audit
bun run check
cd ..

SIGNING_MODE=adhoc scripts/build-app.sh
```

로컬 빌드 결과는 `outputs/SOOM.app`과
`outputs/SOOM-macOS-arm64-LOCAL-ONLY.zip`입니다. 로컬 archive는 공개 배포용
Developer ID/notarization 검증을 통과하지 않았음을 파일명으로 명시합니다.
검증된 공개 빌드만 `outputs/SOOM-macOS-arm64.zip`과 원자적으로 갱신된
`outputs/SHA256SUMS.txt`를 만듭니다.

### Apple 코드 서명

`scripts/build-app.sh`의 자동 모드는 Apple Development 또는 SOOM 로컬 개발
인증서만 선택합니다. Developer ID는 공개 릴리스 모드에서 명시적으로 선택해야
하며 notarization 없이는 실패합니다. 인증서가 없을 때 자동으로 ad-hoc 서명으로
내려가지 않으므로 배포 파일이 실수로 미서명되는 것을 막습니다.

```bash
# 설치 상태 확인
scripts/signing-status.sh

# 로컬 개발: 같은 인증서와 bundle ID를 유지해 TCC 권한 식별을 안정화
SIGNING_MODE=development scripts/build-app.sh

# 인증서가 없는 환경에서만 명시적으로 사용하는 임시 빌드
SIGNING_MODE=adhoc scripts/build-app.sh
```

앱은 카메라·마이크 entitlement로, 포함된 Bun worker는 JIT에 필요한 최소 entitlement로 각각 서명됩니다. helper를 먼저 서명한 뒤 앱을 서명하며, 마지막에 `codesign --verify --deep --strict`를 수행합니다.

Developer ID 배포물을 notarize하려면 먼저 자격 증명을 Keychain 프로필로 저장한 뒤 다음처럼 빌드합니다. 비밀번호나 API 키는 프로젝트 파일이나 빌드 명령에 저장하지 않습니다.

```bash
xcrun notarytool store-credentials soom-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID"

SIGNING_MODE=developer-id \
NOTARIZE=1 \
NOTARY_PROFILE=soom-notary \
scripts/build-app.sh
```

Developer ID 공개 빌드는 `NOTARIZE=1`과 `NOTARY_PROFILE` 없이는 시작되지
않습니다. 성공 시 notary ticket을 앱에 staple하고 ZIP을 다시 만든 뒤 Gatekeeper
평가와 SHA-256 생성을 수행합니다. 마지막으로 전체 소스·테스트·서명·ticket·checksum
gate를 실행합니다.

```bash
scripts/check-public-release.sh --release
```

## 이번 공개 MVP에서 제외한 것

Claude Code/Codex 자동 실행, 소스 분석, hosted/WebRTC share, 팀 계정·폴더,
브라우저 영상 편집, 얼굴 표정 분석은 포함하지 않습니다. 현재 경계는
Local Record → optional Facecam/Live Captions → optional BYOK Korean TaskSpec →
local Agent handoff입니다.
