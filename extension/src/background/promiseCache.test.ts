import { describe, expect, it, vi } from "vitest";
import { createPromiseCache } from "./promiseCache";

describe("createPromiseCache", () => {
  it("computes once per key and serves the cached promise afterwards", async () => {
    const compute = vi.fn(async () => "value");
    const cache = createPromiseCache<string>();
    expect(await cache.get("k", compute)).toBe("value");
    expect(await cache.get("k", compute)).toBe("value");
    expect(compute).toHaveBeenCalledTimes(1);
  });

  it("folds concurrent gets for the same key into one in-flight compute", async () => {
    // The handler caches store Promises exactly so that a prefetch and a manual
    // toggle racing on the same blob/diff key share a single fetch.
    let release!: (v: string) => void;
    const compute = vi.fn(
      () =>
        new Promise<string>((r) => {
          release = r;
        }),
    );
    const cache = createPromiseCache<string>();
    const [a, b] = [cache.get("k", compute), cache.get("k", compute)];
    release("v");
    expect(await Promise.all([a, b])).toEqual(["v", "v"]);
    expect(compute).toHaveBeenCalledTimes(1);
  });

  it("drops a rejected compute so the next get retries", async () => {
    // A transient network failure must not poison the cache for the SW lifetime.
    const compute = vi.fn().mockRejectedValueOnce(new Error("socket")).mockResolvedValue("ok");
    const cache = createPromiseCache<string>();
    await expect(cache.get("k", compute)).rejects.toThrow("socket");
    expect(await cache.get("k", compute)).toBe("ok");
    expect(compute).toHaveBeenCalledTimes(2);
  });

  it("keeps entries fresh within the ttl and recomputes after it elapses", async () => {
    // Mirrors the 60s PR-context cache: a push moves headSha, so staleness is time-bounded.
    vi.useFakeTimers();
    try {
      const compute = vi.fn(async () => "v");
      const cache = createPromiseCache<string>({ ttlMs: 60_000 });
      await cache.get("k", compute);
      vi.setSystemTime(Date.now() + 59_000);
      await cache.get("k", compute);
      expect(compute).toHaveBeenCalledTimes(1);
      vi.setSystemTime(Date.now() + 2_000); // 61 seconds total
      await cache.get("k", compute);
      expect(compute).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("evicts the oldest entry beyond max (insertion order)", async () => {
    // Blob bytes are capped at 32 entries; the first-inserted key goes first.
    const cache = createPromiseCache<string>({ max: 2 });
    const compute = vi.fn(async () => "v");
    await cache.get("a", compute);
    await cache.get("b", compute);
    await cache.get("c", compute); // evicts "a"
    await cache.get("b", compute); // still cached
    await cache.get("a", compute); // recomputed
    expect(compute).toHaveBeenCalledTimes(4);
  });

  it("drops settled values the retain policy rejects", async () => {
    // too-large diffs are dropped so a forced recompute can succeed later;
    // in-flight searches are dropped on settle so guidCache/misses take over.
    const compute = vi.fn(async () => "drop");
    const cache = createPromiseCache<string>({ retain: (v) => v !== "drop" });
    await cache.get("k", compute);
    await cache.get("k", compute);
    expect(compute).toHaveBeenCalledTimes(2);
  });

  it("keeps settled values the retain policy accepts", async () => {
    const compute = vi.fn(async () => "keep");
    const cache = createPromiseCache<string>({ retain: (v) => v === "keep" });
    await cache.get("k", compute);
    await cache.get("k", compute);
    expect(compute).toHaveBeenCalledTimes(1);
  });

  it("still folds concurrent gets while a retain-rejected compute is in flight", async () => {
    // The searches cache retains nothing, yet concurrent searches for the same
    // guid must fold into one request (protects the 10 req/min budget).
    let release!: (v: string) => void;
    const compute = vi.fn(
      () =>
        new Promise<string>((r) => {
          release = r;
        }),
    );
    const cache = createPromiseCache<string>({ retain: () => false });
    const [a, b] = [cache.get("k", compute), cache.get("k", compute)];
    release("v");
    expect(await Promise.all([a, b])).toEqual(["v", "v"]);
    expect(compute).toHaveBeenCalledTimes(1);
  });
});
