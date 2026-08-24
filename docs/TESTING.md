# SOOM testing and release evidence

SOOM 테스트의 목적은 “한 번 녹화가 됐다”를 보여주는 것이 아니라, 화면·음성·키
활동을 다루는 앱이 데이터를 잃거나 예상 밖으로 전송하지 않는다는 반복 가능한
증거를 만드는 것입니다.

이 문서는 현재 자동화된 검사와 아직 수동/추가 구현이 필요한 release gate를
구분합니다. 명령이 문서에 있다는 사실은 그 명령이 특정 release commit에서
성공했다는 증거가 아닙니다.

## 실패 우선순위

| 등급 | 예시 | 처리 |
| --- | --- | --- |
| P0 | 녹화 손실, 앱 crash, raw key/API key 유출, 무단 네트워크, 복구 불가, 잘못 서명된 공식 artifact | release 차단, 즉시 regression test 추가 |
| P1 | A/V sync >100ms, 잘못된 좌표·근거, 일반 device 변경 실패, 접근성 차단, 반복 TaskSpec 오해 | stable 차단; preview 제한은 명시 |
| P2 | 미세한 layout, 낮은 빈도의 편의 문제, 추가 workflow | 위험과 영향에 따라 예약 |

privacy/security failure는 사용자 수와 무관하게 P0로 올릴 수 있습니다.

## 빠른 로컬 검사

### Swift core와 share-safe DTO

```bash
swift test --parallel
```

현재 suite는 다음과 같은 순수 규칙을 다룹니다.

- Retina/display 좌표 변환과 선택 영역 포함 판정
- keyframe 우선순위
- sample PTS, pause/resume, discontinuity, stop freeze와 track offset
- raw character/key-code redaction, shortcut allowlist, legacy migration canary
- API-keyless finalization, 선택적 Input Monitoring, 종료 정책
- 저장 공간 preflight, journal/health model
- 기본 Local Only와 experimental share payload projection

SwiftPM test가 통과해도 ScreenCaptureKit, camera, microphone, TCC와
AVAssetWriter의 실제 장비 동작은 증명되지 않습니다.

### AI worker

```bash
cd worker
bun install --frozen-lockfile
bun audit
bun run typecheck
bun test
bun run build
```

worker suite는 network mock과 synthetic fixture만 사용해야 합니다. 기본 범위는
다음과 같습니다.

- strict CLI argument와 stdin secret protocol
- session realpath, symlink/path traversal, file/count/size 제한
- manifest/event/frame/JPEG/timeline validation
- transcript millisecond offset과 범위 제한
- raw key, window title, absolute path와 password canary redaction
- 12-frame selection, JSON Schema와 semantic/evidence provenance validation
- 401/429/5xx/timeout/retry와 malformed/incomplete response
- atomic internal/export output, stale staging cleanup, export-only failure
- TaskSpec Markdown와 Agent handoff rendering

실제 OpenAI 호출은 비용과 외부 변동성이 있으므로 기본 CI에 넣지 않습니다. 별도
manual integration job은 synthetic media와 maintainer의 제한된 secret을 사용하고,
응답 본문·transcript·API key를 artifact나 log로 저장하지 않아야 합니다.

### 실험적 hosted components

기본 macOS 앱이 사용하지 않더라도 공개 저장소의 코드 건전성을 위해 별도로
검사합니다.

```bash
cd share-web
npm ci
npm run typecheck
npm audit --omit=dev
npm run lint
npm test

cd ../transcoder
bun install --frozen-lockfile
bun audit
bun run check
```

이 검사가 green이어도 hosted service의 tenant isolation, 운영 retention, backup
deletion, abuse controls와 production readiness를 증명하지 않습니다.

### 통합 source gate

```bash
scripts/check-public-release.sh
```

이 명령은 source structure, version, repository hygiene와 위 test/lint/build 단계를
검사합니다. Developer ID artifact 검사는 다음의 별도 release mode입니다.

```bash
scripts/check-public-release.sh --release
```

`--release`는 실제 Developer ID signature, hardened runtime, notarization ticket,
Gatekeeper acceptance와 matching checksum이 있을 때만 사용합니다.

## CI 해석

GitHub Actions는 macOS Swift test/build, Linux worker, experimental share/transcoder,
public-source structure와 CodeQL을 독립 job으로 실행합니다.

- 모든 required job이 같은 commit SHA에서 성공해야 합니다.
- flaky rerun을 최초 실패 없이 green으로 보고하지 않습니다. 원인과 rerun 횟수를
  release evidence에 남깁니다.
- dependency update PR도 전체 privacy와 bundle validation suite를 통과해야 합니다.
- fork PR에는 OpenAI/Apple signing secret을 제공하지 않습니다.
- CI green은 실제 TCC UI, camera/mic hardware, sleep/display disconnect와 notarized
  launch test를 대체하지 않습니다.

## 실제 Mac 기능 matrix

최소 두 종류의 Apple Silicon Mac과 fresh local user account를 권장합니다. 각 행은
OS version, hardware, SOOM commit, signing kind와 권한 초기 상태를 기록합니다.

| 영역 | 필수 scenario | 관찰할 결과 |
| --- | --- | --- |
| 설치 | fresh install, upgrade, 이전 privacy migration | launch, Keychain/TCC identity, session 보존 |
| 권한 | screen/mic 허용·거부·재허용, camera off/on, Input Monitoring 미허용 | 필요한 권한만 차단; Input Monitoring 없이 기본 녹화 |
| source | display, window, region, camera-only, screenshot | 올바른 픽셀·aspect·crop, black/duplicate frame 없음 |
| display | Retina, external display, scale/rotation/해상도 변화, disconnect | 좌표 정렬, 경고, 안전한 저장 |
| camera | built-in/USB, off, disconnect/reconnect, 이동/크기 변경 | 중복 bubble 없음, 화면 녹화 지속 또는 명시적 종료 |
| microphone | built-in/USB/Bluetooth, muted, disconnect, sample-rate 변화 | 음성 존재, 경고, 안전한 종료, sync 유지 |
| audio | system audio on/silent/unavailable, mic-only narration | 최종 MP4의 예상 track과 들리는 음성 |
| lifecycle | pause/resume, hotkey, UI stop, 3분 auto-stop, quit while recording/finalizing/processing | monotonic duration, local media 우선, double-stop 없음 |
| resources | disk warning/full, thermal pressure, writer backpressure | 사용자 경고, bounded drop, playable output 또는 보존된 recovery data |
| OS | sleep/wake, screen lock, fast user switch | safe finalize/recovery, 비밀 노출 없음 |
| library | search/open/reprocess/delete/Trash | 상태와 파일 일치, 실패 세션 보존 |
| BYOK | no key, valid key, cleared key, 401/429/5xx/timeout | recording 독립, 재시도 가능, secret 비노출 |

camera-only가 현재 Screen Recording 권한에 의존하는 것은 알려진 제한입니다. 해당
제약을 제거하기 전에는 matrix 결과에 이를 명시합니다.

## 100회 녹화 soak gate

공개 preview 전에 자동 또는 반자동 harness로 **동일 release candidate**를 100회
연속 검증합니다. 임의의 성공 사례를 합쳐 100으로 세지 않습니다.

### 권장 분포

- 40회: display, 30~180초, camera on/off, system audio on/silent
- 20회: window, 크기·위치 변화 포함
- 15회: custom region, Retina/external display 분산
- 10회: camera-only
- 10회: pause/resume 1~3회와 hotkey stop
- 5회: 4K/30fps, thermal/disk headroom 관찰

각 run은 다음 machine-readable record를 남깁니다. media, transcript, screen image,
absolute user path는 CI/public artifact에 넣지 않습니다.

```json
{
  "run": 1,
  "commit": "<sha>",
  "appVersion": "<version>",
  "hardware": "<model>",
  "macOS": "<version>",
  "captureMode": "display",
  "quality": "standard1080p",
  "durationMs": 60000,
  "playable": true,
  "hasVideo": true,
  "hasMicrophone": true,
  "maxAVSyncOffsetMs": 42,
  "droppedVideoFrames": 0,
  "stopToRecordedMs": 1260,
  "crashed": false
}
```

### 합격 기준

- app crash: 0/100
- playable final recording: 100/100
- 예상한 microphone track: 100/100
- 화면·마이크 sync absolute error: 모든 측정 session에서 100ms 이하
- stop -> recorded UI: 모든 일반 종료에서 2,000ms 이하
- privacy/network canary: 0건
- 실패한 run을 삭제하거나 동일 run number로 덮어쓰지 않음

2초 기준은 final MP4를 재생할 수 있는 결과 화면까지이며 TaskSpec 네트워크 시간은
포함하지 않습니다.

## 강제 종료와 복구 gate

복구율 분모는 **정상적으로 fragment와 journal을 만들 수 있었던 fault-injection
run**으로 고정합니다. 복구 불가능하도록 첫 frame 전에 죽인 run은 별도 분류하지만
숨기지 않습니다.

최소 injection point:

1. writer start 직후
2. 2초 fragment 전/후
3. 30초와 120초 녹화 중
4. pause 상태
5. stop 요청 직전
6. 각 writer `finishWriting` 중
7. final merge 중
8. TaskSpec helper 실행 중

각 run에서 앱을 다시 실행하고 다음을 검사합니다.

- interrupted session을 자동 발견하는가
- 원본과 sideband fragment를 삭제하지 않는가
- 복구된 `recording.mp4`가 playable이고 duration이 유효한가
- 복구된 session이 `recorded`로 열리고 TaskSpec을 선택적으로 다시 만들 수 있는가
- 복구 실패가 `failed`로 명시되며 재현 자료가 보존되는가
- raw key, media, transcript가 support bundle에 들어가지 않는가

합격 기준은 복구 가능한 세션 99% 이상 성공입니다. 최소 100개의 fault-injection
run이 없으면 99%라는 백분율을 release claim으로 사용하지 않습니다.

## A/V sync 측정

`journal.json`의 last-sample offset은 runtime 경고에 유용하지만 perceptual sync
증명의 전부가 아닙니다. 최종 `recording.mp4`에서 측정해야 합니다.

권장 fixture는 화면 flash와 동시에 speaker/microphone에 짧은 click을 발생시키는
합성 test signal입니다. 첫 event뿐 아니라 시작, 중간, 끝에서 offset을 측정하여
drift를 확인합니다.

- container track start time과 duration을 `ffprobe`로 기록
- audio waveform peak와 video flash PTS를 독립 분석
- pause/resume 전후, Bluetooth mic, 3분 session을 별도 분류
- absolute offset과 end-to-end drift 모두 100ms 이하
- 측정 script version과 raw numeric result를 release artifact에 포함

실제 사용자 media는 이 fixture로 사용하지 않습니다.

## 좌표와 evidence 검증

합성 화면에 알려진 target을 여러 display scale/position에 배치하고 pointer click을
자동 또는 수동으로 발생시킵니다.

- global -> display local -> normalized -> capture pixel 변환 오차를 측정
- 선택 영역 밖 click이 edge click으로 변조되지 않는지 확인
- click 전과 +350ms evidence frame의 timeline 차이를 확인
- evidence JPEG에 screen target은 있고 facecam pixel은 없는지 image assertion
- click와 연결된 근거 frame의 절대 시간 오차 250ms 이하

## TaskSpec 품질 평가

기준 corpus는 실제 비밀이 없는 synthetic 또는 명시적으로 공개 가능한 한국어·영어
web UI session 25개 이상으로 구성합니다. 최소 50개의 gold task에 다음 label을
둡니다.

- target
- change instruction
- 숫자/크기/간격
- responsive condition
- constraints와 acceptance criteria
- transcript/frame/click evidence provenance
- 명시되지 않은 hallucinated task

한 task는 위 필수 필드가 모두 맞을 때만 complete로 계산합니다. 부분 점수를
80% 성공으로 바꾸지 않습니다.

- complete task: 80% 이상
- hallucinated task: 10% 이하
- schema/semantic validation: 100%
- 존재하지 않는 frame/time evidence: 0건
- password/path/key canary leakage: 0건

model ID, prompt version, schema hash, 날짜, session list와 reviewer rubric을 함께
저장합니다. 모델 변경은 같은 holdout corpus를 다시 평가합니다.

## 개인정보와 secret canary

모든 network/export/diagnostic 변경에는 고유한 synthetic canary를 넣습니다.

```text
typed password: SOOM_TEST_PASSWORD_<uuid>
absolute path: /Users/example/SOOM_PRIVATE_<uuid>
API key shape: sk-test-SOOM_<uuid>
window title: Payroll-SOOM_<uuid>
```

검사 위치:

- `events.ndjson`, sanitized timeline
- worker request mock body와 serialized image metadata
- stdout/stderr와 app diagnostic log
- `taskspec.json`, Markdown, evidence export
- support bundle
- process argv/environment snapshot
- experimental share metadata fixture

허용 위치는 test fixture source뿐입니다. 실제 secret 형식을 사용하거나 real API key를
snapshot하지 않습니다.

## 공개 release evidence template

각 GitHub Release에는 다음 정보를 포함하거나 연결합니다.

```text
Version / tag / commit:
macOS and hardware matrix:
Swift tests:
Worker tests and compiled helper:
Experimental component checks:
100-recording soak artifact:
Forced-termination recovery result:
A/V sync max and method:
TaskSpec benchmark result:
Privacy canary result:
Developer ID identity/team:
Notarization submission and staple validation:
Gatekeeper result:
Archive SHA-256:
Known limitations:
```

`observed`, `not run`, `blocked`, `failed`를 구분합니다. target 수치나 과거 build의
성공을 현재 release의 observed result로 복사하지 않습니다.
