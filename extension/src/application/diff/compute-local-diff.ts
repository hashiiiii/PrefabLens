import { applyResolved } from "../../domain/diff/resolved";
import type { DiffV2 } from "../../domain/diff/types";
import type { DifferPort } from "../port/differ";

export type ComputeLocalDiffDeps = {
  differ: DifferPort;
  index: Map<string, string>; // guid → asset path, the demo's stand-in for the repo index
  fetchBytes(url: string): Promise<Uint8Array<ArrayBuffer>>; // rejects on HTTP error
  fetchSource(side: "before" | "after", path: string): Promise<Uint8Array>; // missing → empty
};

export type ComputeLocalDiff = (beforeUrl: string | undefined, afterUrl: string | undefined) => Promise<DiffV2>;

const MAX_SOURCE_ROUNDS = 3; // same cap as the background pipeline

// Guid resolution like the background pipeline: applyResolved + mergeSources
// loop, but source prefabs come from fixture URLs instead of the GitHub API.
export function createComputeLocalDiff(deps: ComputeLocalDiffDeps): ComputeLocalDiff {
  const { differ, index } = deps;
  // Empty side = CLI empty-side semantics (added/removed fixtures)
  const side = (url: string | undefined): Promise<Uint8Array> =>
    url ? deps.fetchBytes(url) : Promise.resolve(new Uint8Array());
  return async function computeLocalDiff(beforeUrl, afterUrl) {
    const [before, after] = await Promise.all([side(beforeUrl), side(afterUrl)]);
    let diff = applyResolved(differ.diff(before, after), index);
    const assets = new Map<string, Uint8Array>();
    for (let round = 0; round < MAX_SOURCE_ROUNDS; round++) {
      const needed = (diff.neededSources ?? []).filter((s) => !assets.has(s.guid));
      if (!needed.length) break;
      let progressed = false;
      for (const s of needed) {
        const path = diff.resolved?.[s.guid];
        if (path === undefined) continue;
        // A missing source degrades to the diff at this point, like the extension.
        const bytes = await deps.fetchSource(s.side, path);
        if (!bytes.length) continue;
        assets.set(s.guid, bytes);
        progressed = true;
      }
      if (!progressed) break;
      diff = applyResolved(differ.diffWithAssets(before, after, assets), index);
    }
    return diff;
  };
}
