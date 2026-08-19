import { describe, expect, it } from "vitest";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import { createChromeRepoIndexRepository } from "../../../src/infrastructure/clients/chrome-repo-index-client";
import type { StorageArea } from "../../../src/infrastructure/internal/storage-area";

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

describe("createChromeRepoIndexRepository", () => {
  it("returns an empty metadata map for an unknown repository", async () => {
    const repoIndex = createChromeRepoIndexRepository(new MemoryStorageArea());

    expect(await repoIndex.loadGuids("api/o/r")).toEqual({});
  });

  it("merges metadata GUIDs from later saves", async () => {
    const repoIndex = createChromeRepoIndexRepository(new MemoryStorageArea());

    await repoIndex.saveGuids("api/o/r", { sha1: "g1" });
    await repoIndex.saveGuids("api/o/r", { sha2: "g2" });

    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha1: "g1", sha2: "g2" });
  });

  it("stores index data separately from metadata GUIDs", async () => {
    const repoIndex = createChromeRepoIndexRepository(new MemoryStorageArea());

    await repoIndex.saveGuids("api/o/r", { sha1: "g1" });
    await repoIndex.saveIndex("api/o/r", { treeSha: "tree-2", guids: { g2: "Assets/B.mat" } });

    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha1: "g1" });
    expect(await repoIndex.loadIndex("api/o/r")).toEqual({
      treeSha: "tree-2",
      guids: { g2: "Assets/B.mat" },
    });
  });

  it("ignores a failed metadata write and keeps the prior value", async () => {
    const initial = { "metaGuids:api/o/r": { sha1: "g1" } };
    const repoIndex = createChromeRepoIndexRepository(new MemoryStorageArea(initial, JSON.stringify(initial).length));

    await expect(repoIndex.saveGuids("api/o/r", { sha2: "g2" })).resolves.toBeUndefined();
    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha1: "g1" });
  });

  it("ignores a failed index write and keeps the prior value", async () => {
    const prior: RepoGuidIndex = { treeSha: "tree-1", guids: { g1: "Assets/A.cs" } };
    const initial = { "guidIndex:api/o/r": prior };
    const repoIndex = createChromeRepoIndexRepository(new MemoryStorageArea(initial, JSON.stringify(initial).length));

    await expect(
      repoIndex.saveIndex("api/o/r", {
        treeSha: "tree-2-that-exceeds-the-capacity",
        guids: { g2: "Assets/B.mat" },
      }),
    ).resolves.toBeUndefined();
    expect(await repoIndex.loadIndex("api/o/r")).toEqual({
      treeSha: "tree-1",
      guids: { g1: "Assets/A.cs" },
    });
  });
});
