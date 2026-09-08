import { describe, expect, it } from "vitest";
import { createChromeGuidRepository } from "../../../src/infrastructure/clients/chrome-guid-client";
import { MemoryStorageArea } from "../../support/memory-storage-area";

describe("createChromeGuidRepository", () => {
  it("returns an empty map for a repository without stored GUIDs", async () => {
    const guids = createChromeGuidRepository(new MemoryStorageArea());

    expect(await guids.load("api/o/r")).toEqual({});
  });

  it("merges new GUID paths with stored paths", async () => {
    const guids = createChromeGuidRepository(new MemoryStorageArea());

    await guids.save("api/o/r", { g0: "Assets/Stored.cs" });
    await guids.save("api/o/r", { g1: "Assets/A.cs" });

    expect(await guids.load("api/o/r")).toEqual({
      g0: "Assets/Stored.cs",
      g1: "Assets/A.cs",
    });
  });

  it("keeps GUID paths in separate repository maps", async () => {
    const guids = createChromeGuidRepository(new MemoryStorageArea());

    await guids.save("api/o/r", { g1: "Assets/A.cs" });
    await guids.save("api/o/second", { g3: "Assets/C.prefab" });

    expect(await guids.load("api/o/r")).toEqual({ g1: "Assets/A.cs" });
    expect(await guids.load("api/o/second")).toEqual({ g3: "Assets/C.prefab" });
  });

  it("replaces the stored path for the same GUID", async () => {
    const guids = createChromeGuidRepository(new MemoryStorageArea());

    await guids.save("api/o/r", { g1: "Assets/A.cs" });
    await guids.save("api/o/r", { g1: "Assets/New.cs" });

    expect(await guids.load("api/o/r")).toEqual({ g1: "Assets/New.cs" });
  });

  it("rejects a write when the complete next state exceeds capacity", async () => {
    const initial = { unrelated: "x".repeat(40) };
    const guids = createChromeGuidRepository(new MemoryStorageArea(initial, JSON.stringify(initial).length));

    await expect(guids.save("api/o/r", { g1: "Assets/A.cs" })).rejects.toThrow("quota exceeded");
  });
});
