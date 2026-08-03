import { describe, expect, it } from "vitest";
import { ok } from "../../domain/result";
import { createDiffSession } from "./create-diff-session";

describe("createDiffSession blob cache", () => {
  // A 100-file prefetch pushes ~200 blobs through the 32-slot cache. Without
  // LRU promotion, eviction follows insertion order. The cache then evicts the
  // blob that the user is about to read, and the next toggle downloads it again.
  it("keeps a recently used blob when the cache overflows", async () => {
    const session = createDiffSession();
    const computes: string[] = [];
    const get = (key: string) =>
      session.blobs.get(key, async () => {
        computes.push(key);
        return ok(new Uint8Array([1]));
      });
    for (let i = 1; i <= 32; i++) await get(`k${i}`);
    await get("k1"); // hit: promotes k1 ahead of k2 in eviction order
    await get("k33"); // overflow: evicts the least recently used (k2), not k1
    await get("k1");
    await get("k2");
    expect(computes.filter((k) => k === "k1")).toHaveLength(1); // still cached
    expect(computes.filter((k) => k === "k2")).toHaveLength(2); // evicted, recomputed
  });
});
