# SOOM open-source roadmap

SOOM의 공개 제품 목표는 Loom 전체를 복제하는 것이 아니라 다음 한 문장을 높은
신뢰도로 완성하는 것입니다.

> Mac에서 화면과 얼굴을 보여주며 설명을 녹화하고, 원본은 로컬에 안전하게 남긴
> 뒤, 사용자가 원할 때 자신의 OpenAI API 키로 한국어 TaskSpec을 만든다.

로드맵의 상태는 기능 수보다 **녹화 보존, 개인정보 경계, 재현 가능한 검증**을
우선합니다. 코드가 존재하는 것과 제품 완료를 구분합니다.

## 우선순위 정의

| 등급 | 의미 | 출시 정책 |
| --- | --- | --- |
| P0 | 데이터 손실, 무단 수집·전송, secret 노출, 실행 파일 신뢰, 재현 가능한 crash 등 제품 신뢰를 무너뜨리는 문제 | 공개 preview 전에 해결하고 자동/수동 증거를 남김 |
| P1 | 핵심 녹화·재생·TaskSpec 품질, 일반적인 hardware 변화, 접근성, 유지보수성 | stable 후보 전에 해결; preview에는 제한을 명시할 수 있음 |
| P2 | 생산성, 시각적 완성도, 확장 기능, 배포 편의 | 핵심 gate 이후 순차 제공 |

보안상 P0/P1 severity 판단은 [`SECURITY.md`](../SECURITY.md)를 우선합니다.

## Now: development snapshot

다음은 현재 소스에 구현된 경로입니다. 아래 목록은 notarized public release나 soak
통과를 의미하지 않습니다.

### Local recording

- macOS 15+ Apple Silicon 메뉴바 앱
- 전체 화면, 특정 윈도우, 사용자 지정 영역, camera-only, screenshot 선택 UI
- 3초 countdown, 최대 3분, stop/pause/resume/cancel, global hotkey
- 1080p/30fps 기본과 선택적 4K/30fps
- 화면 + 선택적 시스템 오디오, 별도 마이크, 원형 facecam, click pulse 합성
- source PTS 기반 공통 media timeline과 track start offset
- screen-only AI evidence frame과 최대 12장 선택 정책
- session manifest, 1초 health journal, 2초 writer fragment, local library/search
- disk/thermal/backpressure/A/V drift 경고와 display/sleep/device event 처리
- interrupted session 복구 시도와 Trash 기반 삭제

### Privacy and BYOK

- API 키 없이 local recording과 playback 가능
- Input Monitoring 미허용 시 `captureGap`을 남기고 녹화 계속
- capture boundary에서 raw character와 reversible printable key code 제거
- screen evidence에서 facecam 제외 및 legacy event privacy migration
- API 키의 Keychain 저장과 child stdin 전달
- microphone transcription, sanitized timeline, screen frames만 OpenAI로 전송
- strict TaskSpec JSON Schema, semantic/evidence 검증, atomic local export
- TaskSpec/API 실패 후 `recorded` 세션 유지와 재시도
- hosted Share UI와 network path는 공개 local build에서 비활성

### Project hygiene

- Apache-2.0 코드 라이선스와 별도 상표 정책
- privacy/security/contribution 문서
- Swift, worker, experimental share/transcoder CI와 CodeQL 설정
- Developer ID/notarization/checksum을 fail-closed로 요구하는 release script

## Next: public preview gate

다음 항목이 공개 preview의 실제 blocking queue입니다.

### P0 — 녹화를 잃지 않는다는 증명

- [ ] 100회 연속 실제 녹화 soak에서 app crash 0회
- [ ] 녹화 길이, capture mode, camera, pause, display 조합이 편향되지 않은
      재현 가능한 soak runner와 machine-readable 결과 artifact
- [ ] 녹화 시작/중간/finalizing 중 강제 종료 matrix와 재실행 복구 검증
- [ ] 복구 가능한 비정상 종료 세션의 성공률 99% 이상
- [ ] 복구 실패 시 원본/fragment를 보존하고 재시도 또는 안전한 수동 export 제공
- [ ] disk full, writer failure, helper crash와 전원/잠자기 경계에서 녹화와 TaskSpec
      상태가 섞이지 않는 fault-injection test
- [ ] 모든 media/session/result 파일의 0700/0600 권한 회귀 검사

### P0 — 개인정보와 공급망

- [ ] API 요청, export, diagnostic bundle, JSONL stderr/stdout에 synthetic password
      canary가 없는지 end-to-end 검사
- [ ] helper path, session symlink/path traversal, oversized bundle, malformed media에
      대한 adversarial test 유지
- [ ] 실제 proxy/network capture로 API key가 argv/environment에 없고 OpenAI 외
      destination에 요청하지 않음을 확인
- [ ] dependency license/SBOM 검토와 pinned release dependency provenance
- [ ] GitHub private vulnerability reporting, branch protection, least-privilege Actions
- [ ] 공개 source archive에 `.env`, Keychain material, session, output, signing material,
      nested repository metadata가 포함되지 않는 gate

### P0 — 공식 macOS artifact

- [ ] root Git history와 clean source release tag
- [ ] Developer ID Application + hardened runtime 서명
- [ ] Apple notarization ticket staple/validate와 Gatekeeper acceptance
- [ ] fresh Mac user account에서 download -> checksum -> launch -> TCC -> record 검증
- [ ] GitHub Release의 source/tag/archive/checksum이 동일 version과 commit을 가리킴
- [ ] ad-hoc/Apple Development build가 공식 archive 이름으로 배포되지 않는지 확인

### P1 — 핵심 품질 gate

- [ ] screen/microphone 최종 sync 오차가 모든 기준 session에서 100ms 이하
- [ ] click event와 evidence frame 정렬 오차 250ms 이하
- [ ] stop 요청 뒤 2초 이내에 playback 가능한 recorded 화면 표시
- [ ] mic-only, silent-system-audio, Bluetooth/USB device, external display, Retina
      scaling과 해상도 변경 matrix
- [ ] 25개 한국어/영어 web UI session, 50개 이상 기준 작업에서 완전 일치 80%
      이상, 환각 task 10% 이하
- [ ] VoiceOver label, keyboard-only flow, Dynamic Type 대안, reduced motion/contrast
      검증과 한국어·영어 localization 기반

완료 증거 형식은 [`TESTING.md`](TESTING.md)를 따릅니다. 수동으로 한 번 성공한
영상은 위 gate의 대체물이 아닙니다.

## Next: architecture hardening

preview gate와 병행하되 위험한 전면 재작성은 피합니다.

### P1 — 앱 경계 분리

- [ ] `AppModel`을 명시적 lifecycle reducer와 작은 actor/service로 분리
- [ ] `CaptureSession`, `MediaWriter`, `SessionRepository`, `TaskSpecProcessor`,
      `PermissionService` protocol 및 dependency injection
- [ ] UI process 오류가 active writer를 즉시 잃지 않도록 capture service/process
      격리의 비용과 entitlement를 prototype으로 검증
- [ ] Swift 6 strict-concurrency warning 0을 단계적으로 달성
- [ ] 상태 전이와 termination policy를 AppKit 없이 deterministically test

### P1 — capture/audio 개선

- [ ] camera-only를 direct AVFoundation writer로 만들어 불필요한 Screen Recording
      권한 제거
- [ ] microphone disconnect 후 안전한 동일/대체 device reconnect 정책
- [ ] opt-in voice processing, noise suppression와 automatic gain control을 원본
      충실도/latency와 비교 검증
- [ ] writer queue의 bounded backpressure 정책과 adaptive frame-rate/quality fallback
- [ ] 색상 공간, wide-gamut/HDR 입력의 SDR tone mapping과 text sharpness golden test
- [ ] final merge 없이도 즉시 재생할 수 있는 회복 가능한 container 전략 평가

### P1 — TaskSpec 신뢰성

- [ ] provider/model capability profile과 unavailable-model fallback을 명시
- [ ] 전송 전 payload preview 및 evidence 제외/포함 선택 UI
- [ ] token/image/오디오 예상 비용 표시와 rate-limit UX
- [ ] 한국어·영어 regression fixture set, semantic scorer, provenance coverage metric
- [ ] incomplete/refusal/timeout/401/429/5xx를 사용자 행동으로 연결하는 오류 분류
- [ ] schema version migration과 backward compatibility policy

## Later: stable product quality

### P2 — 배포와 운영

- [ ] opt-in signed update feed, staged rollout, rollback channel
- [ ] Homebrew Cask와 reproducible installation instructions
- [ ] release notes, migration notes, compatibility table와 public status page
- [ ] 사용자가 내용을 미리 확인하는 redacted support bundle UX
- [ ] 익명 telemetry가 정말 필요한지 먼저 결정하고, 필요할 때만 별도 consent와
      deletion/retention 정책을 설계

### P2 — UX와 workflow

- [ ] session tags, bulk retention, storage budget와 archive/export
- [ ] timeline transcript editing, evidence frame 교체, TaskSpec 수정·승인
- [ ] Codex/Claude Code handoff template customization
- [ ] AI 없이도 사람이 쓰는 영상 + notes export
- [ ] source와 project를 연결하되 절대 경로·소스 전송을 기본 금지하는 local index

## Later: 별도 제품/보안 경계

다음 기능은 로컬 MVP가 안정된 뒤 별도 threat model과 운영 책임 아래 다룹니다.

- hosted share link, account/team/workspace, comments와 analytics
- browser player, HLS/transcoding, retention/deletion worker
- WebRTC live share와 동료/AI 동시 참여
- Codex/Claude Code 자동 실행, repository edit/test/browser verification
- webcam 표정·감정 분석

`share-web/`과 `transcoder/`에 코드가 있다는 이유만으로 이 항목이 출시되었다고
표시하지 않습니다. multi-user authorization, tenant isolation, abuse/rate limits,
revocation, complete deletion, backup retention과 incident response를 검증한 뒤에만
기본 앱과 연결할 수 있습니다.

## 릴리스 단계의 Definition of Done

### Public preview

- P0 항목 0개 open
- preview에서 허용한 P1 제한이 README와 release notes에 명시됨
- 자동 CI green과 실제 Mac test report가 같은 release commit에 첨부됨
- Developer ID/notarization/Gatekeeper/checksum 검증 완료
- Local Only이 기본이며 API 키 없이 첫 녹화가 가능함

### Stable 1.0

- P0/P1 항목 0개 open
- 100-recording soak, 99% recovery, 100ms A/V sync, 2초 result latency를 동일한
  stable candidate에서 재검증
- TaskSpec benchmark가 80% complete-task 및 10% 이하 hallucination 기준 통과
- 접근성·localization·fresh-install·upgrade/rollback matrix 통과
- 지원 version, 보안 응답, privacy boundary와 breaking-change policy가 공개됨

새로운 기능은 이 기준을 낮추는 이유가 될 수 없습니다. 특히 hosted feature는
로컬 녹화의 안정성과 개인정보 경계를 먼저 증명한 뒤 진행합니다.
