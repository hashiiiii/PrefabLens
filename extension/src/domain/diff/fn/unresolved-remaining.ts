import type { DiffV2 } from "../types";

// Guids still lacking a name — shared by handler, resolution, and the content indicator.
// Object.hasOwn: guids are arbitrary strings ("constructor" must not hit Object.prototype).
export function unresolvedRemaining(json: Pick<DiffV2, "unresolvedGuids" | "resolved">): string[] {
  return json.unresolvedGuids.filter((g) => !Object.hasOwn(json.resolved ?? {}, g));
}
