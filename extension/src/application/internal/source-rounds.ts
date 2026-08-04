import type { DiffV2, NeededSource, ResolutionStatus } from "../../domain/diff/types";
import type { DifferGateway } from "../gateway/differ";

export const MAX_SOURCE_ROUNDS = 3; // re-diff cap for nested sources (independent of core's depth cap of 8)

// skip: this source cannot be fetched now — degrade without it.
// abort: stop all rounds and report why (rate limit / hard failure).
export type FetchedSource = { bytes: Uint8Array } | { skip: true } | { abort: ResolutionStatus };

// Fetch neededSources via resolved path and re-diff with assets; failure
// degrades to the current diff instead of dropping it. One loop for the
// background pipeline and the site demo — only the fetch and re-resolve differ.
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
      // Binary-serialized sources are a no-op re-diff — don't count as progress
      if (!differ.isUnityYaml(fetched.bytes)) continue;
      assets.set(s.guid, fetched.bytes);
      progressed = true;
    }
    if (!progressed) break;
    const mergedResult = differ.diffWithAssets(before, after, assets);
    if (!mergedResult.ok) return { json: current, status: "failed" }; // merge failure degrades to current result
    // Merging surfaces new external refs inside the source, so resolve again
    const next = await reResolve(mergedResult.value);
    rateLimited ||= next.rateLimited;
    current = next.json;
  }
  return { json: current, status: rateLimited ? "rateLimited" : "complete" };
}
