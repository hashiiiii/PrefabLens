import { describe, expect, it } from "vitest";
import { createMergeStore } from "../../../src/infrastructure/internal/merge-store";
import { MemoryStorageArea } from "../../support/memory-storage-area";

describe("createMergeStore", () => {
  it.each(["repository IDs", "prefixes", "storage areas"])("keeps different %s independent", async (difference) => {
    const area = new MemoryStorageArea();
    const busy = createMergeStore(area, "guids");
    const independent = createMergeStore(
      difference === "storage areas" ? new MemoryStorageArea() : area,
      difference === "prefixes" ? "metaGuids" : "guids",
    );
    const independentId = difference === "repository IDs" ? "api/o/second" : "api/o/r";
    const completed: string[] = [];

    // One busy map must not make an unrelated save wait for its whole backlog.
    const backlog = Array.from({ length: 5 }, (_, index) =>
      busy.save("api/o/r", { [`g${index}`]: `Assets/${index}.cs` }).then(() => completed.push("busy")),
    );
    await Promise.all([
      ...backlog,
      independent.save(independentId, { other: "Assets/Other.cs" }).then(() => completed.push("independent")),
    ]);

    expect(completed.indexOf("independent")).toBeLessThan(completed.lastIndexOf("busy"));
    expect(await independent.load(independentId)).toEqual({ other: "Assets/Other.cs" });
  });

  it("keeps a later save behind writes that are still pending", async () => {
    const store = createMergeStore(new MemoryStorageArea(), "guids");
    const first = store.save("api/o/r", { g1: "Assets/A.cs" });
    const second = store.save("api/o/r", { g2: "Assets/B.cs" });
    await first;

    // Completing an older save must not release the key while a newer save still owns it.
    await Promise.all([second, store.save("api/o/r", { g3: "Assets/C.cs" })]);

    expect(await store.load("api/o/r")).toEqual({ g1: "Assets/A.cs", g2: "Assets/B.cs", g3: "Assets/C.cs" });
  });
});
