import { describe, expect, it } from "vitest";
import { createMergeStore } from "./mergeStore";

/** Real in-memory stand-in for chrome.storage.local: get/set operate on a plain record. */
function makeArea() {
  const data: Record<string, unknown> = {};
  return {
    data,
    async get(keys: string[]) {
      const out: Record<string, unknown> = {};
      for (const key of keys) if (Object.hasOwn(data, key)) out[key] = data[key];
      return out;
    },
    async set(items: Record<string, unknown>) {
      Object.assign(data, items);
    },
  };
}

describe("createMergeStore", () => {
  it("loads an empty record for a slot never written", async () => {
    const store = createMergeStore(makeArea(), "guids");
    expect(await store.load("api/o/r")).toEqual({});
  });

  it("round-trips entries under the prefixed key", async () => {
    const area = makeArea();
    const store = createMergeStore(area, "guids");
    await store.save("api/o/r", { g1: "Assets/A.cs" });
    expect(await store.load("api/o/r")).toEqual({ g1: "Assets/A.cs" });
    // The storage key is `prefix:id`, matching what background/index.ts stored before extraction.
    expect(area.data["guids:api/o/r"]).toEqual({ g1: "Assets/A.cs" });
  });

  it("save merges into the stored record instead of replacing it", async () => {
    const store = createMergeStore(makeArea(), "guids");
    await store.save("api/o/r", { g1: "Assets/A.cs" });
    await store.save("api/o/r", { g2: "Assets/B.mat" });
    // Both writes survive: the second save read the slot and spread the new entries over it.
    expect(await store.load("api/o/r")).toEqual({ g1: "Assets/A.cs", g2: "Assets/B.mat" });
  });

  it("a later save wins for the same guid", async () => {
    const store = createMergeStore(makeArea(), "guids");
    await store.save("api/o/r", { g1: "Assets/Old.cs" });
    await store.save("api/o/r", { g1: "Assets/New.cs" });
    expect(await store.load("api/o/r")).toEqual({ g1: "Assets/New.cs" });
  });

  it("keeps slots independent across prefixes and ids", async () => {
    const area = makeArea();
    // The two background stores (Code Search cache, whole-repo meta guids) share one area.
    const guids = createMergeStore(area, "guids");
    const metaGuids = createMergeStore(area, "metaGuids");
    await guids.save("api/o/r", { g1: "Assets/A.cs" });
    await metaGuids.save("api/o/r", { sha1: "g9" });
    await guids.save("api/o/other", { g2: "Assets/B.mat" });
    expect(await guids.load("api/o/r")).toEqual({ g1: "Assets/A.cs" });
    expect(await metaGuids.load("api/o/r")).toEqual({ sha1: "g9" });
    expect(await guids.load("api/o/other")).toEqual({ g2: "Assets/B.mat" });
  });

  it("propagates set failures so each call site chooses its own quota policy", async () => {
    // Real area whose writes always fail (quota overflow): save must not swallow it,
    // because repoIndexStore continues in memory while guidCache lets it propagate.
    const store = createMergeStore(
      {
        get: async () => ({}),
        set: async () => {
          throw new Error("quota");
        },
      },
      "guids",
    );
    await expect(store.save("api/o/r", { g1: "x" })).rejects.toThrow("quota");
  });
});
