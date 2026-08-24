# SOOM Transcoder

`SOOM_SHARE_ORIGIN`과 `SOOM_UPLOAD_TOKEN`을 설정하고 `bun run start`로 실행합니다.
ffmpeg/ffprobe가 설치된 Linux 또는 macOS worker에서 D1 처리 큐를 claim하고 다음 자산을 R2에 저장합니다.

- 브라우저용 fast-start H.264/AAC MP4
- 4초 단위 HLS VOD playlist/segments
- JPEG thumbnail
- PNG waveform
- 한국어/영어 WebVTT captions

작업 lease가 만료되면 큐로 복귀하며 최대 네 번 시도한 뒤 실패 상태가 됩니다.

## Container deployment

`Dockerfile`에는 Bun, ffmpeg, health endpoint가 포함되어 있습니다. 항상 실행되는 container service에 다음 secret을 주입합니다.

- `SOOM_SHARE_ORIGIN=https://soom-share-ai.soonsooo.chatgpt.site`
- `SOOM_UPLOAD_TOKEN=<Sites와 같은 recorder token>`
- `SOOM_WORKER_ID=<배포별 고유 이름>`

`GET /healthz`는 liveness probe에 사용합니다. 네트워크 poll 실패는 프로세스를 종료하지 않고 5초 후 재시도하며, job 실패는 D1 queue의 재시도 횟수에 반영됩니다.
