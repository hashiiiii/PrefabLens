import { describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../../domain/diff/types";
import type { StorageAreaWithRemove } from "../internal/storage-area";
import { createChromeDiffClient } from "./chrome-diff-client";

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

describe("createChromeDiffClient", () => {
  it("round-trips a diff and returns no diff for a missing key", async () => {
    const area = new MemoryStorageArea();
    const store = createChromeDiffClient(area);

    expect(await store.load("missing")).toBeUndefined();

    await store.save("base:head:Assets/Foo.prefab", DIFF);

    expect(await area.get("diff:base:head:Assets/Foo.prefab")).toEqual({
      "diff:base:head:Assets/Foo.prefab": DIFF,
    });
    expect(await store.load("base:head:Assets/Foo.prefab")).toEqual(DIFF);
  });

  it("skips a diff above the session budget", async () => {
    const area = new MemoryStorageArea();
    const store = createChromeDiffClient(area);
    const big: DiffV2 = { ...DIFF, unresolvedGuids: [" ".repeat(600 * 1024)] };

    await store.save("large", big);

    expect(await store.load("large")).toBeUndefined();
    expect(await area.get(null)).toEqual({});
  });

  it("flushes stale diffs, preserves unrelated data, and stores the requested diff", async () => {
    const expectedState = {
      viewMode: "semantic",
      "diff:new": DIFF,
    };
    const area = new MemoryStorageArea(
      {
        "diff:old1": DIFF,
        "diff:old2": DIFF,
        viewMode: "semantic",
      },
      JSON.stringify(expectedState).length,
    );
    const store = createChromeDiffClient(area);

    await store.save("new", DIFF);

    expect(await store.load("old1")).toBeUndefined();
    expect(await store.load("old2")).toBeUndefined();
    expect(await store.load("new")).toEqual(DIFF);
    expect(await area.get(null)).toEqual(expectedState);
  });

  it("resolves without persistence when the complete post-flush state exceeds capacity", async () => {
    const unrelatedState = { viewMode: "semantic" };
    const area = new MemoryStorageArea(
      {
        "diff:old": DIFF,
        ...unrelatedState,
      },
      JSON.stringify(unrelatedState).length,
    );
    const store = createChromeDiffClient(area);

    await expect(store.save("new", DIFF)).resolves.toBeUndefined();

    expect(await store.load("old")).toBeUndefined();
    expect(await store.load("new")).toBeUndefined();
    expect(await area.get(null)).toEqual(unrelatedState);
  });
});
