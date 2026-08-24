# SOOM architecture

이 문서는 공개 저장소의 기본 제품 경계인 **로컬 녹화 + 선택적 OpenAI
BYOK TaskSpec**을 설명합니다. 문서에서 `현재`는 소스에 구현된 경로를 뜻하며,
상용 수준의 신뢰성이나 공개 릴리스 검증까지 끝났다는 뜻은 아닙니다. 검증 상태와
출시 기준은 [`TESTING.md`](TESTING.md), 우선순위는
[`ROADMAP.md`](ROADMAP.md)를 기준으로 판단합니다.

## 제품 경계

기본 앱은 다음 순서로 동작합니다.

```text
사용자 선택
  -> 로컬 화면/카메라/오디오/입력 활동 캡처
  -> 재생 가능한 recording.mp4 확정
  -> recorded 상태로 세션 보존
  -> (선택: 사용자가 저장한 OpenAI API 키가 있을 때)
       로컬 helper -> OpenAI transcription/Responses API
       -> TaskSpec + Markdown + 근거 이미지 내보내기
```

이 경계에서 지켜야 할 핵심 규칙은 다음과 같습니다.

- 계정, SOOM 서버, OpenAI API 키 없이 로컬 녹화가 가능해야 합니다.
- AI 처리의 실패, 취소, 네트워크 단절은 확정된 녹화 파일을 실패 상태로
  되돌리거나 삭제해서는 안 됩니다.
- 입력 모니터링은 근거를 보강하는 선택 기능이며 미허용 상태에서도 화면과
  음성 녹화가 계속되어야 합니다.
- 원시 키 문자, 영상, 시스템 오디오, facecam 픽셀, 절대 프로젝트 경로와
  소스 코드는 TaskSpec 요청에 포함하지 않습니다.
- `share-web/`과 `transcoder/`는 실험적 self-hosted 코드입니다. 공개 로컬 앱은
  `hostedShareEnabled = false`이며 이 경로를 사용자에게 제공하지 않습니다.
- Codex/Claude Code 자동 실행, 원격 라이브 공유, 팀 계정과 영상 편집은 현재
  제품 경계 밖입니다.

## 저장소 구조

| 경로 | 책임 | 기본 앱과의 관계 |
| --- | --- | --- |
| `Sources/ShowTellCore/` | 세션·TaskSpec 모델, 좌표 변환, 입력 정제, 미디어 타임라인, 신뢰성 정책 | 네트워크와 UI에 독립적인 규칙 |
| `Sources/ShowTellApp/` | SwiftUI/AppKit UI, 권한, 캡처, writer, 세션 저장·복구, helper 실행 | macOS 앱 실행 파일 |
| `Sources/ShowTellShare/` | 네트워크 전송용 안전 DTO와 실험적 업로드 client | 공개 빌드에서 비활성 |
| `worker/` | 세션 검증, 전사, 근거 선택, Responses API, TaskSpec 검증·내보내기 | 앱에 arm64 helper로 포함 |
| `schemas/` | `TaskSpec.v1` JSON Schema 원본 | 모델 출력과 로컬 검증의 계약 |
| `Tests/` 및 `worker/test/` | 순수 Swift 정책·좌표·타임라인·privacy 및 worker 회귀 테스트 | CI의 자동 검증 대상 |
| `share-web/`, `transcoder/` | 선택적 공유 페이지와 미디어 처리 실험 | 별도 배포·별도 보안 경계 |
| `scripts/` | 앱 번들 생성, 서명, notarization, 공개 릴리스 gate | maintainer용 배포 도구 |

현재 `ShowTellApp`은 `AppModel`이 많은 orchestration 책임을 갖습니다. 이는 작은
MVP에는 유용하지만 capture, persistence, worker, UI state를 독립적으로 테스트하기
어렵게 만듭니다. actor/service 분리는 호환성을 유지하는 다음 단계이며, 아직 완료된
구조로 문서화하지 않습니다.

## 런타임 구성요소

```text
                       macOS process: SOOM

  SwiftUI/AppKit UI  <----------------------------+
       |                                            |
       v                                            |
    AppModel -- permissions / source / lifecycle --+
       |
       +--> ScreenRecorder
       |      +--> ScreenCaptureKit: screen + system audio
       |      +--> AVFoundation: camera + microphone
       |      +--> CGEvent tap: optional non-text activity
       |      +--> MediaTimeline
       |      +--> CompositeMediaWriter
       |      +--> FrameCaptureManager
       |
       +--> SessionStore --> Application Support/SOOM/Sessions
       |                         |
       |                         +--> SessionRecoveryManager
       |
       +--> WorkerRunner --stdin: API key--> bundled soom-worker
                                             |
                                             +--> api.openai.com
                                             +--> local atomic export
```

### 권한과 소스 선택

`PermissionsManager`는 Screen Recording, Microphone, Camera, Input Monitoring
상태를 읽습니다. 녹화 시작 정책은 `LocalRecordingPolicy`에서 UI framework와
분리해 판정합니다.

- 화면 기반 모드: Screen Recording과 Microphone이 필요합니다.
- 카메라를 켠 모드: Camera도 필요합니다.
- Input Monitoring은 필요 조건이 아닙니다. 사용할 수 없으면
  `captureGap: inputMonitoringUnavailable`을 남깁니다.
- 현재 camera-only 구현도 `SCShareableContent`를 통해 소스를 준비하므로 Screen
  Recording 권한을 요구합니다. 직접 camera writer로 분리하는 작업은 `Next`입니다.

`CaptureSourcePicker`는 전체 디스플레이, 특정 윈도우, 사용자 지정 영역,
camera-only를 표현합니다. Screenshot은 동일한 ScreenCaptureKit 선택 흐름에서
별도의 정지 이미지를 만듭니다.

### 미디어 캡처와 합성

현재 캡처 흐름은 다음과 같습니다.

1. `SCStream`이 30fps 화면 프레임과 선택적 48kHz 시스템 오디오를 제공합니다.
2. `AVCaptureSession`이 facecam과 별도 마이크 sample buffer를 제공합니다.
3. `MediaTimeline`이 각 sample의 원본 PTS를 공통 session timeline으로 매핑하고
   pause 구간과 불연속을 압축합니다.
4. `CompositeMediaWriter`가 화면, 원형 facecam, click pulse를 H.264 Rec.709
   canvas에 합성합니다. 품질 profile은 1080p/30fps 또는 4K/30fps입니다.
5. 화면, 시스템 오디오, 마이크는 각각 실시간 writer에 기록됩니다. writer에는
   2초 movie fragment interval이 설정됩니다.
6. 종료 후 `RecordingFinalizer`가 공통 track offset을 사용해 영상, 시스템
   오디오, 마이크를 `recording.mp4`로 합칩니다.

Facecam과 click pulse가 포함된 영상은 사람에게 보여주는 원본입니다. AI 근거
프레임은 합성 전 ScreenCaptureKit 화면 buffer에서 만들기 때문에 facecam을
포함하지 않습니다. camera-only 세션에는 현재 AI 화면 근거 프레임이 없습니다.

`MediaTimeline`과 fragment 설정은 신뢰성 기반을 구현한 것이지, A/V sync 100ms
목표나 비정상 종료 복구율을 이미 입증한 것은 아닙니다. 이 수치는 실제 장비 soak와
forced-termination matrix를 통과해야만 릴리스 근거로 사용할 수 있습니다.

### 입력 이벤트와 좌표

`InputEventMonitor`는 선택된 화면 영역 안의 pointer, scroll, keyboard activity,
modifier를 기록합니다. 활성 앱 이름과 bundle identifier는 남길 수 있지만 현재
신규 per-event capture에서 window title은 수집하지 않습니다. 다만 사용자가 특정
윈도우를 직접 선택하면 그 source의 앱/윈도우 이름이 session `captureLabel`에
남을 수 있으며, 이 label은 OpenAI payload와 support bundle에서 제외됩니다.

개인정보 경계는 capture callback에서 적용됩니다.

- printable character와 이를 역추적할 수 있는 virtual key code는
  `events.ndjson`에 도달하기 전에 제거합니다.
- Command/Control allowlist shortcut과 non-text control key만 정규화한 이름으로
  남깁니다.
- Option-only 입력은 문자 내용 없이 typing activity count로만 표현합니다.
- 구버전 세션은 앱 시작 시 fail-closed migration을 거쳐 원시 문자와 window
  title을 제거합니다. 해석할 수 없는 NDJSON line은 보존하지 않습니다.
- 선택 영역 밖 pointer는 경계에 clamp하여 거짓 클릭을 만들지 않고 버립니다.

화면 좌표는 global point, display-local point, top-left normalized coordinate,
capture pixel을 구분합니다. Retina와 외부 디스플레이 변환은 core unit test
대상이지만, 전체 다중 모니터 matrix는 실제 Mac 검증이 별도로 필요합니다.

## 세션과 상태 모델

### 앱 상태

주요 happy path는 다음과 같습니다.

```text
setup -> idle -> selecting -> countdown -> recording <-> paused
       -> finalizing -> recorded
       -> (BYOK 요청 시) processing -> complete
                              | 실패/취소
                              +----------> recorded
```

`recorded`는 재생 가능한 로컬 미디어가 확정되었지만 TaskSpec은 선택적으로 남아
있는 상태입니다. `completed`는 TaskSpec까지 세션에 저장된 상태입니다.
TaskSpec 실패를 앱 전체의 `failed`로 바꾸지 않는 것이 local-first invariant입니다.

앱 종료 요청도 같은 경계를 따릅니다.

- 녹화 중: 사용자 확인 뒤 TaskSpec 없이 먼저 미디어를 확정합니다.
- finalizing 중: 제한된 시간 동안 확정을 기다립니다.
- TaskSpec 처리 중: helper를 취소해도 이미 저장한 영상은 유지합니다.
- recorded/completed: 즉시 종료할 수 있습니다.

### 세션 번들

기본 위치는
`~/Library/Application Support/SOOM/Sessions/<session-id>/`입니다. 세션 디렉터리는
`0700`, 민감한 파일은 `0600`을 목표로 합니다.

```text
session.json             manifest, state, coordinate/timebase metadata
journal.json             heartbeat, health counters, recovery state
diagnostics.ndjson       opt-in, content-free operational records
events.ndjson            already-redacted local event stream
screen-system.mp4        intermediate composite video
system-audio.m4a         intermediate system audio
microphone.m4a           narration used for optional transcription
recording.mp4            finalized human-viewable recording
frames/index.json        evidence candidates
frames/*.jpg             screen-only evidence
transcript.json          optional BYOK result
taskspec.json            optional BYOK result
taskspec.md              optional human-readable result
AGENT_TASK.md            optional Codex/Claude Code handoff
```

`SessionStore`는 manifest, journal, frame index를 temporary file 뒤 replace하는 방식으로
갱신하고 event log를 checkpoint합니다. 취소·삭제는 세션 전체를 macOS Trash로
보냅니다.

`SessionRecoveryManager`는 clean shutdown이 없는 세션에서 finalized media 또는
AVAssetWriter sideband fragment 후보를 찾고, 재합성 후 playable duration과 근거
프레임을 검사합니다. 성공 시 `recorded`, 실패 시 `failed`로 남깁니다. 현재 방식은
복구 로직이 존재한다는 뜻이며, 99% 복구율 보장은 아닙니다.

## 선택적 BYOK TaskSpec 경계

### 키와 process 경계

OpenAI API 키는 macOS Keychain의 `WhenUnlockedThisDeviceOnly` 접근성으로
저장됩니다. 앱은 bundled `soom-worker`를 HTTP server 없이 child process로
실행합니다.

- 고정 command: `soom-worker process --session <path> --export <path>`
- API 키: argv와 child environment가 아니라 일회성 stdin pipe
- child environment: 제한된 `PATH`, `TMPDIR`, `LANG`, pipe protocol flag
- stdout: `progress`, `complete`, `error` JSON Lines
- stderr: UI에 표시하지 않는 제한된 operational diagnostics
- Release build: 앱 bundle 안의 helper만 허용; 임의 helper override는 DEBUG 전용

### worker 처리 순서

```text
realpath/symlink/size/schema validation
  -> microphone transcription with word timestamps
  -> transcript offset normalization
  -> already-redacted events -> sanitized timeline
  -> select at most 12 screen-only evidence frames
  -> Responses API strict JSON Schema
  -> schema + semantic/provenance validation
  -> atomic session result
  -> atomic export directory
```

worker는 세션 root 바깥 artifact, symbolic link, 과도한 file/event/image/audio
크기, 잘못된 JPEG와 timeline 범위를 거부합니다. 모델에는 project name, branch,
HEAD만 전달하고 `rootPath`는 null로 만듭니다. 응답의 session ID, evidence 시간,
frame allowlist와 TaskSpec 의미 제약을 다시 검증합니다.

OpenAI 요청은 사용자 Mac에서 `https://api.openai.com/v1`로 직접 전송됩니다.
현재 모델·비용·제공 지역의 가용성은 SOOM이 보장할 수 없으며, 공개 릴리스 전에
model profile과 오류 UX를 지속적으로 재검증해야 합니다.

내보내기는 staging directory에 JSON, Markdown, Agent handoff와 선택된 evidence만
쓴 뒤 최종 이름으로 rename합니다. 원본 영상, 오디오, event log는 자동 내보내지
않습니다. 내보내기 폴더 실패는 세션 내부 TaskSpec 성공과 분리됩니다.

## 신뢰 경계와 네트워크

| 경계 | 신뢰/데이터 | 현재 정책 |
| --- | --- | --- |
| macOS capture process | 화면, 카메라, 오디오, 입력 활동, 로컬 경로 | 사용자 선택과 TCC 권한 안에서만 동작 |
| local session bundle | 원본 media와 정제된 metadata | Application Support에 보존, 사용자 삭제 |
| bundled worker | microphone, transcript, sanitized timeline, screen evidence | bundle path와 크기를 fail-closed 검증 |
| OpenAI API | 사용자가 명시한 BYOK 처리 payload | 직접 연결, `store: false`; provider 약관은 별도 |
| local export | TaskSpec/Markdown/evidence | staging 뒤 atomic rename |
| experimental share stack | 업로드된 미디어와 metadata | 기본 앱에서 꺼져 있으며 production-ready로 간주하지 않음 |

기본 앱에 새로운 network destination을 추가하거나 capture payload를 넓히는 변경은
기능 추가가 아니라 trust-boundary 변경입니다. 별도 threat model, UI consent,
retention/deletion 정책, redaction test와 보안 검토 없이는 병합하지 않습니다.

## 진단과 배포

진단 저장은 opt-in입니다. support bundle은 sanitized manifest, journal,
content-free diagnostics와 crash report 개수만 포함합니다. media, transcript,
event log, raw `.ips`, absolute project path, safety identifier와 원문 오류를 포함하지
않습니다.

개발 빌드는 Apple Development 또는 명시적 ad-hoc 서명을 사용할 수 있습니다.
공식 binary는 Developer ID hardened runtime, notarization ticket, Gatekeeper 평가,
archive checksum을 모두 통과해야 합니다. 이 요건은 스크립트가 존재하는 것과 실제
공개 artifact가 검증되었다는 것을 구분합니다.

## 알려진 구조적 부채

다음 항목은 현재 구현된 기능처럼 해석하면 안 됩니다.

- `AppModel`의 orchestration 분리와 Swift 6 strict-concurrency 완료
- capture/writer를 앱 process와 격리하는 crash containment
- camera-only의 Screen Recording 비의존 경로
- 마이크 noise suppression, automatic gain control과 device reconnect
- 100회 실제 녹화 soak, 99% interrupted-session recovery, 100ms A/V sync 증명
- 전체 UI localization, VoiceOver, keyboard navigation, reduced-motion 검증
- 자동 업데이트, rollback channel과 Homebrew 배포
- production hosted sharing, 팀 계정, 댓글, analytics와 WebRTC live share

이 부채의 순서와 완료 조건은 [`ROADMAP.md`](ROADMAP.md)에 정의합니다.
