import { describe, expect, it } from "vitest";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import { createChromeRepoIndexRepository } from "../../../src/infrastructure/clients/chrome-repo-index-client";
import { MemoryStorageArea } from "../../support/memory-storage-area";

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

  it("keeps all metadata GUIDs from concurrent saves", async () => {
    const area = new MemoryStorageArea({ "metaGuids:api/o/r": { sha0: "g0" } });
    const repoIndex = createChromeRepoIndexRepository(area);

    // Concurrent diffs can discover different metadata entries for the same repository.
    await Promise.all([
      repoIndex.saveGuids("api/o/r", { sha1: "g1" }),
      repoIndex.saveGuids("api/o/r", { sha2: "g2" }),
      createChromeRepoIndexRepository(area).saveGuids("api/o/r", { sha3: "g3" }),
    ]);

    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha0: "g0", sha1: "g1", sha2: "g2", sha3: "g3" });
  });

  it("saves queued metadata GUIDs after an ignored capacity failure", async () => {
    const repoIndex = createChromeRepoIndexRepository(new MemoryStorageArea({}, 100));

    // Metadata caching stays best effort, but a failed write must not discard later additions.
    await expect(
      Promise.all([
        repoIndex.saveGuids("api/o/r", { oversized: "x".repeat(100) }),
        repoIndex.saveGuids("api/o/r", { sha1: "g1" }),
      ]),
    ).resolves.toEqual([undefined, undefined]);
    expect(await repoIndex.loadGuids("api/o/r")).toEqual({ sha1: "g1" });
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
