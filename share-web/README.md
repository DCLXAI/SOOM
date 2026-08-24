# SOOM Share

SOOM Mac Recorder가 명시적으로 `Share`로 선택한 녹화만 업로드하는 공유 서비스입니다. 기본 녹화 모드는 `Local Only`입니다.

## Product flow

1. Recorder가 `POST /api/uploads`로 기본 비공개 링크와 multipart upload를 생성합니다.
2. MP4를 8MB part로 R2에 resumable upload하고 transcript/TaskSpec을 D1에 연결합니다.
3. durable processing job을 transcoder가 claim해 Web MP4, HLS, thumbnail, waveform, WebVTT를 생성합니다.
4. `/s/:slug`에서 반응형 플레이어, 자막 검색, TaskSpec evidence, 시점 링크, 댓글·반응·analytics를 제공합니다.

## Runtime configuration

- D1 binding: `DB`
- R2 binding: `MEDIA`
- secret `SOOM_UPLOAD_TOKEN`: Recorder와 transcoder 인증
- secret `SOOM_SHARE_SECRET`: password access cookie 서명

`SOOM_UPLOAD_TOKEN`은 Mac 앱의 Share 서버 설정에서 Keychain에 저장합니다. 공개 범위는 private/public/password, 만료는 없음/1/7/30일, 다운로드 허용은 별도 opt-in입니다.

## Local development

```bash
SOOM_UPLOAD_TOKEN=local-token SOOM_SHARE_SECRET=local-secret npm run dev
npm test
```

Transcoding worker는 상위 `transcoder/`에서 실행합니다.
