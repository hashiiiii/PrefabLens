import type { DiffV2, NeededSource } from "../../domain/diff/types";
import type { DifferGateway } from "../gateway/differ";
import type { ResolutionStatus } from "../gateway/messenger";

export const MAX_SOURCE_ROUNDS = 3; // Re-diff cap for nested sources. Core has a separate depth cap of 8.

// skip: this source cannot be fetched now. The loop degrades without it.
// abort: the loop stops all rounds and reports the cause (rate limit or hard failure).
export type FetchedSource = { bytes: Uint8Array } | { skip: true } | { abort: ResolutionStatus };

// The loop fetches neededSources via the resolved path and re-diffs with
// the assets. A failure degrades to the current diff and does not drop it.
// The background pipeline and the site demo share this one loop. Only the
// fetch and the re-resolve differ.
export async function mergeSourceRounds(
  differ: DifferGateway,
  before: Uint8Array,
  after: Uint8Array,
  first: DiffV2,
  fetchSource: (source: NeededSource, resolvedPath: string) => Promise<FetchedSource>,
  reResolve: (json: DiffV2) => Promise<{ json: DiffV2; rateLimited: boolean }>,
): Promise<{ json: DiffV2; status: ResolutionStatus }> {
  const assets = new Map<string, Uint8Array>();
  let current = first;
  let rateLimited = false;
  for (let round = 0; round < MAX_SOURCE_ROUNDS; round++) {
    const needed = (current.neededSources ?? []).filter((s) => !assets.has(s.guid));
    if (!needed.length) break;
    let progressed = false;
    for (const s of needed) {
      const path = current.resolved?.[s.guid];
      if (path === undefined) continue;
      const fetched = await fetchSource(s, path);
      if ("abort" in fetched) return { json: current, status: fetched.abort };
      if ("skip" in fetched) continue;
      // Binary-serialized sources make the re-diff a no-op, so they do not count as progress.
      if (!differ.isUnityYaml(fetched.bytes)) continue;
      assets.set(s.guid, fetched.bytes);
      progressed = true;
    }
    if (!progressed) break;
    const mergedResult = differ.diffWithAssets(before, after, assets);
    if (!mergedResult.ok) return { json: current, status: "failed" }; // A merge failure degrades to the current diff.
    // New external refs appear after the merge, so the loop resolves again.
    const next = await reResolve(mergedResult.value);
    rateLimited ||= next.rateLimited;
    current = next.json;
  }
  return { json: current, status: rateLimited ? "rateLimited" : "complete" };
}
