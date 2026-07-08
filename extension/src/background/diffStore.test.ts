import { describe, expect, it, vi } from "vitest";
import type { DiffV2 } from "../types";
import { createSessionDiffStore } from "./diffStore";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] };

// A fake that mimics only the needed subset of chrome.storage.session with a Map. set reproduces overflow via failWhen.
function fakeArea(failWhen?: () => boolean) {
  const data = new Map<string, unknown>();
  const area = {
    data,
    get: vi.fn(async (keys: string | string[] | null) => {
      if (keys === null) return Object.fromEntries(data);
      const list = Array.isArray(keys) ? keys : [keys];
      const out: Record<string, unknown> = {};
      for (const k of list) if (data.has(k)) out[k] = data.get(k);
      return out;
    }),
    set: vi.fn(async (items: Record<string, unknown>) => {
      if (failWhen?.()) throw new Error("QUOTA_BYTES quota exceeded");
      for (const [k, v] of Object.entries(items)) data.set(k, v);
    }),
    remove: vi.fn(async (keys: string | string[]) => {
      for (const k of Array.isArray(keys) ? keys : [keys]) data.delete(k);
    }),
  };
  return area;
}

describe("createSessionDiffStore", () => {
  it("round-trips a diff under the diff: prefix", async () => {
    const area = fakeArea();
    const store = createSessionDiffStore(area);
    await store.save("base:head:Assets/Foo.prefab", DIFF);
    expect(area.data.get("diff:base:head:Assets/Foo.prefab")).toEqual(DIFF);
    expect(await store.load("base:head:Assets/Foo.prefab")).toEqual(DIFF);
  });

  it("returns undefined for a missing key", async () => {
    const store = createSessionDiffStore(fakeArea());
    expect(await store.load("nope")).toBeUndefined();
  });

  it("skips diffs larger than the session budget without touching storage", async () => {
    // Leave large ones to the memory cache only (session is only 10MB)
    const area = fakeArea();
    const store = createSessionDiffStore(area);
    const big: DiffV2 = { ...DIFF, unresolvedGuids: [" ".repeat(600 * 1024)] };
    await store.save("k", big);
    expect(area.set).not.toHaveBeenCalled();
  });

  it("flushes stale diff entries and retries once when the quota overflows", async () => {
    // Prevents the permanent degradation where, once full, every SW restart recomputes everything:
    // on overflow, wipe the accumulated diffs and rewrite once
    const area = fakeArea(); // the default set succeeds. Only the first is made to overflow below
    // Seed existing diff entries and one unrelated key
    area.data.set("diff:old1", DIFF);
    area.data.set("diff:old2", DIFF);
    area.data.set("viewMode", "semantic"); // don't delete anything but diff:
    const store = createSessionDiffStore(area);

    // The first set overflows → flush → retry (the default set) succeeds
    area.set.mockImplementationOnce(async () => {
      throw new Error("quota exceeded");
    });
    await store.save("new", DIFF);

    expect(area.remove).toHaveBeenCalledWith(["diff:old1", "diff:old2"]); // wipe only diff:
    expect(area.data.has("viewMode")).toBe(true); // keep unrelated keys
    expect(area.data.get("diff:new")).toEqual(DIFF); // the retry wrote it
    expect(area.set).toHaveBeenCalledTimes(2); // just 1 overflow + 1 retry (pins against a regression to looping)
  });

  it("gives up quietly if the retry also fails", async () => {
    // Still unwritable after flush (a single diff over quota): continue with the memory cache, don't throw
    const area = fakeArea(() => true); // always overflows
    const store = createSessionDiffStore(area);
    await expect(store.save("k", DIFF)).resolves.toBeUndefined();
  });
});
