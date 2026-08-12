import { describe, expect, it } from "vitest";
import type { RepoGuidIndex } from "../../domain/guid/repo-guid-index";
import type { StorageArea } from "../internal/storage-area";
import { createChromeRepoIndexClient } from "./chrome-repo-index-client";

class MemoryStorageArea implements StorageArea {
  private values: Record<string, unknown>;

  constructor(
    initial: Record<string, unknown> = {},
    private readonly capacity = Number.POSITIVE_INFINITY,
  ) {
    this.values = { ...initial };
  }

  async get(keys: string | string[] | null): Promise<Record<string, unknown>> {
    const selected = keys === null ? Object.keys(this.values) : Array.isArray(keys) ? keys : [keys];
    return Object.fromEntries(selected.filter((key) => key in this.values).map((key) => [key, this.values[key]]));
  }

  async set(items: Record<string, unknown>): Promise<void> {
    const next = { ...this.values, ...items };
    if (JSON.stringify(next).length > this.capacity) throw new Error("quota exceeded");
    this.values = next;
  }
}

describe("createChromeRepoIndexClient", () => {
  it("stores metadata and index data in separate namespaces", async () => {
    const repoIndex = createChromeRepoIndexClient(new MemoryStorageArea());

    expect(await repoIndex.loadGuids("api/o/r")).toEqual({});
    const nextIndex: RepoGuidIndex = { treeSha: "tree-2", guids: { g2: "Assets/B.mat" } };

    await repoIndex.saveGuids("api/o/r", { sha1: "g1" });
    await repoIndex.saveGuids("api/o/r", { sha2: "g2" });
    await repoIndex.saveIndex("api/o/r", nextIndex);

    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha1: "g1", sha2: "g2" });
    expect(await repoIndex.loadIndex("api/o/r")).toEqual(nextIndex);
  });

  it("ignores a failed metadata write and keeps the prior value", async () => {
    const initial = { "metaGuids:api/o/r": { sha1: "g1" } };
    const repoIndex = createChromeRepoIndexClient(new MemoryStorageArea(initial, JSON.stringify(initial).length));

    await expect(repoIndex.saveGuids("api/o/r", { sha2: "g2" })).resolves.toBeUndefined();
    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha1: "g1" });
  });

  it("ignores a failed index write and keeps the prior value", async () => {
    const prior: RepoGuidIndex = { treeSha: "tree-1", guids: { g1: "Assets/A.cs" } };
    const initial = { "guidIndex:api/o/r": prior };
    const repoIndex = createChromeRepoIndexClient(new MemoryStorageArea(initial, JSON.stringify(initial).length));

    await expect(
      repoIndex.saveIndex("api/o/r", {
        treeSha: "tree-2-that-exceeds-the-capacity",
        guids: { g2: "Assets/B.mat" },
      }),
    ).resolves.toBeUndefined();
    expect(await repoIndex.loadIndex("api/o/r")).toEqual(prior);
  });
});
