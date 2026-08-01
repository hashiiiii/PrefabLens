import { describe, expect, it } from "vitest";
import { err, ok } from "../../domain/result";
import { isRateLimited } from "../port/github";
import { createGuidIndex } from "./create-guid-index";

const META = `fileFormatVersion: 2
guid: 1234567890abcdef1234567890abcdef
MonoImporter:
  serializedVersion: 2`;

describe("createGuidIndex", () => {
  const files = [
    { path: "Assets/Scripts/Player.cs", status: "modified" },
    { path: "Assets/Scripts/Player.cs.meta", status: "modified" },
    { path: "Assets/Old.cs.meta", status: "removed" },
  ];

  it("indexes changed .meta files, reading removed metas from the base side", async () => {
    const fetched: Array<[string, string]> = [];
    const indexResult = await createGuidIndex(files, async (path, side) => {
      fetched.push([path, side]);
      if (path === "Assets/Scripts/Player.cs.meta") return ok(META);
      if (path === "Assets/Old.cs.meta") return ok("guid: oldguid\n");
      return ok(null);
    });
    expect(indexResult.ok).toBe(true);
    if (!indexResult.ok) return;
    const index = indexResult.value;
    expect(index.get("1234567890abcdef1234567890abcdef")).toBe("Assets/Scripts/Player.cs");
    expect(index.get("oldguid")).toBe("Assets/Old.cs");
    expect(fetched).toContainEqual(["Assets/Scripts/Player.cs.meta", "head"]);
    expect(fetched).toContainEqual(["Assets/Old.cs.meta", "base"]);
    expect(fetched).toHaveLength(2); // does not fetch anything but .meta
  });

  it("skips metas that fail to fetch or parse", async () => {
    const indexResult = await createGuidIndex(files, async () => err({ kind: "fetch-failed" as const }));
    expect(indexResult.ok).toBe(true);
    if (!indexResult.ok) return;
    expect(indexResult.value.size).toBe(0);
  });

  it("propagates rate limits instead of degrading the index silently", async () => {
    // Swallowing would cache a degraded index for the SW's lifetime, and re-toggling would not fix it
    const result = await createGuidIndex(files, async () => err({ kind: "rate-limited" as const }));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(isRateLimited(result.error)).toBe(true);
  });

  it("bounds concurrent fetches to 8 even with many changed metas", async () => {
    const manyFiles = Array.from({ length: 20 }, (_, i) => ({
      path: `Assets/Scripts/File${i}.cs.meta`,
      status: "modified",
    }));
    let inFlight = 0;
    let maxInFlight = 0;
    const indexResult = await createGuidIndex(manyFiles, async (path, _side) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 0));
      inFlight--;
      const i = path.match(/File(\d+)\.cs\.meta/)?.[1];
      return ok(`guid: g${i}\n`);
    });
    expect(maxInFlight).toBeLessThanOrEqual(8);
    expect(indexResult.ok).toBe(true);
    if (!indexResult.ok) return;
    expect(indexResult.value.size).toBe(20);
  });
});
