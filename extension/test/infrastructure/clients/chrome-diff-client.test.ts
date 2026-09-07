import { describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../../../src/domain/diff/types";
import { createChromeDiffRepository } from "../../../src/infrastructure/clients/chrome-diff-client";
import { MemoryStorageArea } from "../../support/memory-storage-area";

const DIFF: DiffV2 = emptyDiff();

describe("createChromeDiffRepository", () => {
  it("returns no diff for a missing key", async () => {
    const area = new MemoryStorageArea();
    const diffs = createChromeDiffRepository(area);

    expect(await diffs.load("missing")).toBeUndefined();
  });

  it("stores and loads a diff", async () => {
    const area = new MemoryStorageArea();
    const diffs = createChromeDiffRepository(area);

    await diffs.save("base:head:Assets/Foo.prefab", DIFF);

    expect(await area.get("diff:base:head:Assets/Foo.prefab")).toEqual({
      "diff:base:head:Assets/Foo.prefab": DIFF,
    });
    expect(await diffs.load("base:head:Assets/Foo.prefab")).toEqual(DIFF);
  });

  it("skips a diff above the session budget", async () => {
    const area = new MemoryStorageArea();
    const diffs = createChromeDiffRepository(area);
    const big: DiffV2 = { ...DIFF, unresolvedGuids: [" ".repeat(600 * 1024)] };

    await diffs.save("large", big);

    expect(await diffs.load("large")).toBeUndefined();
    expect(await area.get(null)).toEqual({});
  });

  it("flushes stale diffs, preserves unrelated data, and stores the requested diff", async () => {
    const area = new MemoryStorageArea(
      {
        "diff:old1": DIFF,
        "diff:old2": DIFF,
        viewMode: "semantic",
      },
      JSON.stringify({ viewMode: "semantic", "diff:new": DIFF }).length,
    );
    const diffs = createChromeDiffRepository(area);

    await diffs.save("new", DIFF);

    expect(await diffs.load("old1")).toBeUndefined();
    expect(await diffs.load("old2")).toBeUndefined();
    expect(await diffs.load("new")).toEqual(DIFF);
    expect(await area.get(null)).toEqual({
      viewMode: "semantic",
      "diff:new": DIFF,
    });
  });

  it("resolves without persistence when the complete post-flush state exceeds capacity", async () => {
    const area = new MemoryStorageArea(
      {
        "diff:old": DIFF,
        viewMode: "semantic",
      },
      JSON.stringify({ viewMode: "semantic" }).length,
    );
    const diffs = createChromeDiffRepository(area);

    await expect(diffs.save("new", DIFF)).resolves.toBeUndefined();

    expect(await diffs.load("old")).toBeUndefined();
    expect(await diffs.load("new")).toBeUndefined();
    expect(await area.get(null)).toEqual({ viewMode: "semantic" });
  });
});
