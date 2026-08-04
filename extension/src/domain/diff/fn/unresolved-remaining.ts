import type { DiffV2 } from "../types";

const NONE: Record<string, string> = {};

// Guids that still lack a name. The handler, resolution, and the content indicator share this filter.
// Object.hasOwn: guids are arbitrary strings ("constructor" must not hit Object.prototype).
export function unresolvedRemaining(json: Pick<DiffV2, "unresolvedGuids" | "resolved">): string[] {
  const resolved = json.resolved ?? NONE;
  return json.unresolvedGuids.filter((g) => !Object.hasOwn(resolved, g));
}
