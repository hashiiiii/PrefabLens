import type { DiffV2 } from "./types";

// Host-side "resolved" attach (same scoping as core). Separate from guids.ts so
// the site demo (src/demo.ts) can import without pulling GithubClient / __API_BASE__.
export function applyResolved(diff: DiffV2, index: Map<string, string>): DiffV2 {
  const resolved: Record<string, string> = {};
  for (const g of diff.unresolvedGuids) {
    const path = index.get(g);
    if (path !== undefined) resolved[g] = path;
  }
  return { ...diff, resolved };
}
