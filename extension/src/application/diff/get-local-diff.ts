import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import type { DiffV2 } from "../../domain/diff/types";
import { ok, type Result } from "../../domain/result";
import type { DifferGateway, DiffFailure } from "../gateway/differ";
import { mergeSourceRounds } from "../internal/source-rounds";

// Guid resolution works like the background pipeline: applyResolved and the
// shared source re-merge loop. But the source prefabs come from fixture URLs,
// not from the GitHub API.
export async function getLocalDiff(
  differ: DifferGateway,
  index: Map<string, string>,
  fetchBytes: (url: string) => Promise<Uint8Array<ArrayBuffer>>,
  fetchSource: (side: "before" | "after", path: string) => Promise<Uint8Array>,
  beforeUrl: string | undefined,
  afterUrl: string | undefined,
): Promise<Result<DiffV2, DiffFailure>> {
  // An empty side follows the CLI empty-side semantics (added/removed fixtures)
  const side = (url: string | undefined): Promise<Uint8Array> =>
    url ? fetchBytes(url) : Promise.resolve(new Uint8Array());
  const [before, after] = await Promise.all([side(beforeUrl), side(afterUrl)]);
  const first = differ.diff(before, after);
  if (!first.ok) return first;
  const merged = await mergeSourceRounds(
    differ,
    before,
    after,
    applyResolved(first.value, index),
    async (s, path) => {
      // A missing source degrades to the diff at this point, like the extension.
      const bytes = await fetchSource(s.side, path);
      return bytes.length ? { bytes } : { skip: true };
    },
    (json) => Promise.resolve({ json: applyResolved(json, index), rateLimited: false }),
  );
  return ok(merged.json);
}
