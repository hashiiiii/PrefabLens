import type { DiffV2 } from "../types";

// Host-side "resolved" attachment with the same scoping as core. It stays in
// domain so the site demo can import it without GithubClient or __API_BASE__.
export function applyResolved(diff: DiffV2, index: Map<string, string>): DiffV2 {
  const resolved: Record<string, string> = {};
  for (const g of diff.unresolvedGuids) {
    const path = index.get(g);
    if (path !== undefined) resolved[g] = path;
  }
  return { ...diff, resolved };
}
