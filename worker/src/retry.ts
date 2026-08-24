export interface RetryOptions {
  retries?: number;
  baseDelayMs?: number;
  sleep?: (milliseconds: number) => Promise<void>;
}

export function statusOf(error: unknown): number | undefined {
  if (typeof error === "object" && error !== null && "status" in error) {
    const status = (error as { status?: unknown }).status;
    return typeof status === "number" ? status : undefined;
  }
  return undefined;
}

export function isTransient(error: unknown): boolean {
  const status = statusOf(error);
  if (status !== undefined) return status === 408 || status === 409 || status === 429 || status >= 500;
  if (error instanceof Error) {
    return /timeout|timed out|network|fetch failed|connection|ECONNRESET|ETIMEDOUT/i.test(error.message);
  }
  return false;
}

export async function withRetry<T>(operation: () => Promise<T>, options: RetryOptions = {}): Promise<T> {
  const retries = options.retries ?? 2;
  const baseDelayMs = options.baseDelayMs ?? 500;
  const sleep = options.sleep ?? ((milliseconds: number) => Bun.sleep(milliseconds));

  for (let attempt = 0; ; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      if (attempt >= retries || !isTransient(error)) throw error;
      await sleep(baseDelayMs * 2 ** attempt);
    }
  }
}
