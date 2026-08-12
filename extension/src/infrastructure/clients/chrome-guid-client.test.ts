import { describe, expect, it } from "vitest";
import type { StorageArea } from "../internal/storage-area";
import { createChromeGuidClient } from "./chrome-guid-client";

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

describe("createChromeGuidClient", () => {
  it("stores GUID paths by repository and merges later saves", async () => {
    const guids = createChromeGuidClient(new MemoryStorageArea());

    expect(await guids.load("api/o/r")).toEqual({});
    await guids.save("api/o/r", { g0: "Assets/Stored.cs" });
    await guids.save("api/o/r", { g1: "Assets/A.cs" });
    expect(await guids.load("api/o/r")).toEqual({
      g0: "Assets/Stored.cs",
      g1: "Assets/A.cs",
    });

    await guids.save("api/o/r", { g2: "Assets/B.mat" });
    expect(await guids.load("api/o/r")).toEqual({
      g0: "Assets/Stored.cs",
      g1: "Assets/A.cs",
      g2: "Assets/B.mat",
    });

    await guids.save("api/o/second", { g3: "Assets/C.prefab" });
    expect(await guids.load("api/o/second")).toEqual({ g3: "Assets/C.prefab" });
    await guids.save("api/o/r", { g1: "Assets/New.cs" });
    expect(await guids.load("api/o/r")).toEqual({
      g0: "Assets/Stored.cs",
      g1: "Assets/New.cs",
      g2: "Assets/B.mat",
    });
    expect(await guids.load("api/o/second")).toEqual({ g3: "Assets/C.prefab" });
  });

  it("rejects a write when the complete next state exceeds capacity", async () => {
    const initial = { unrelated: "x".repeat(40) };
    const guids = createChromeGuidClient(new MemoryStorageArea(initial, JSON.stringify(initial).length));

    await expect(guids.save("api/o/r", { g1: "Assets/A.cs" })).rejects.toThrow("quota exceeded");
  });
});
