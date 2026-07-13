import type { DiffV2 } from "../types";

/** Host-side resolution seam. Attaches with the same scoping rule as core's "resolved".
 *  Lives apart from guids.ts so the site demo bundle (src/demo.ts) can import it
 *  without pulling the GitHub client (whose module init needs the build-time
 *  __API_BASE__ define). */
export function applyResolved(diff: DiffV2, index: Map<string, string>): DiffV2 {
  const resolved: Record<string, string> = {};
  for (const g of diff.unresolvedGuids) {
    const path = index.get(g);
    if (path !== undefined) resolved[g] = path;
  }
  return { ...diff, resolved };
}
