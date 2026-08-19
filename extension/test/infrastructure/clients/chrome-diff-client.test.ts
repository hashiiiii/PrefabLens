import { describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../../../src/domain/diff/types";
import { createChromeDiffRepository } from "../../../src/infrastructure/clients/chrome-diff-client";
import type { StorageAreaWithRemove } from "../../../src/infrastructure/internal/storage-area";

const DIFF: DiffV2 = emptyDiff();

class MemoryStorageArea implements StorageAreaWithRemove {
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

  async remove(keys: string | string[]): Promise<void> {
    const removed = new Set(Array.isArray(keys) ? keys : [keys]);
    this.values = Object.fromEntries(Object.entries(this.values).filter(([key]) => !removed.has(key)));
  }
}

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
