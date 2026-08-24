export function jsonBody<T>(request: Request): Promise<T> {
  const type = request.headers.get("content-type") ?? "";
  if (!type.includes("application/json")) throw new Error("JSON body required");
  return request.json() as Promise<T>;
}

export function clampInteger(value: unknown, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, Math.round(Number(value) || 0)));
}

export function safeObjectName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._/-]/g, "-").replace(/\.{2,}/g, ".").slice(0, 180);
}

export function requestOrigin(request: Request): string {
  const url = new URL(request.url);
  return `${url.protocol}//${url.host}`;
}
