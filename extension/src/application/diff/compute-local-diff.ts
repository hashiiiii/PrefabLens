import { applyResolved } from "../../domain/diff/resolved";
import type { DiffV2 } from "../../domain/diff/types";
import type { DifferPort } from "../port/differ";

const MAX_SOURCE_ROUNDS = 3; // same cap as the background pipeline

// Guid resolution like the background pipeline: applyResolved + updateSources
// loop, but source prefabs come from fixture URLs instead of the GitHub API.
export async function computeLocalDiff(
  differ: DifferPort,
  index: Map<string, string>,
  fetchBytes: (url: string) => Promise<Uint8Array<ArrayBuffer>>,
  fetchSource: (side: "before" | "after", path: string) => Promise<Uint8Array>,
  beforeUrl: string | undefined,
  afterUrl: string | undefined,
): Promise<DiffV2> {
  // Empty side = CLI empty-side semantics (added/removed fixtures)
  const side = (url: string | undefined): Promise<Uint8Array> =>
    url ? fetchBytes(url) : Promise.resolve(new Uint8Array());
  const [before, after] = await Promise.all([side(beforeUrl), side(afterUrl)]);
  const first = differ.diff(before, after);
  if (!first.ok) throw new Error(first.error.message);
  let diff = applyResolved(first.value, index);
  const assets = new Map<string, Uint8Array>();
  for (let round = 0; round < MAX_SOURCE_ROUNDS; round++) {
    const needed = (diff.neededSources ?? []).filter((s) => !assets.has(s.guid));
    if (!needed.length) break;
    let progressed = false;
    for (const s of needed) {
      const path = diff.resolved?.[s.guid];
      if (path === undefined) continue;
      // A missing source degrades to the diff at this point, like the extension.
      const bytes = await fetchSource(s.side, path);
      if (!bytes.length) continue;
      assets.set(s.guid, bytes);
      progressed = true;
    }
    if (!progressed) break;
    const merged = differ.diffWithAssets(before, after, assets);
    if (!merged.ok) throw new Error(merged.error.message);
    diff = applyResolved(merged.value, index);
  }
  return diff;
}
