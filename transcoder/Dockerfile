FROM oven/bun:1.3.5-debian AS base

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json tsconfig.json ./
RUN bun install --production
COPY src ./src

ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=20s --timeout=3s --start-period=10s --retries=3 \
  CMD bun -e "const r=await fetch('http://127.0.0.1:8080/healthz');if(!r.ok)process.exit(1)"

CMD ["bun", "src/index.ts"]
