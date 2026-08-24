import { describe, expect, test } from "bun:test";
import { isTransient, withRetry } from "../src/retry";

describe("API retry policy", () => {
  test("401 fails immediately", async () => {
    let attempts = 0;
    await expect(
      withRetry(
        async () => {
          attempts += 1;
          throw Object.assign(new Error("unauthorized"), { status: 401 });
        },
        { sleep: async () => undefined },
      ),
    ).rejects.toThrow("unauthorized");
    expect(attempts).toBe(1);
  });

  test.each([429, 500, 503])("status %d retries twice", async (status) => {
    let attempts = 0;
    const result = await withRetry(
      async () => {
        attempts += 1;
        if (attempts < 3) throw Object.assign(new Error("transient"), { status });
        return "ok";
      },
      { sleep: async () => undefined },
    );
    expect(result).toBe("ok");
    expect(attempts).toBe(3);
  });

  test("network timeout is transient", () => {
    expect(isTransient(new Error("request timed out"))).toBe(true);
  });
});
