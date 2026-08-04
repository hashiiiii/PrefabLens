import type { DiffV2, GuidResolvedPush } from "../types";

// One rule for the two-stage resolution protocol: the final push replaces json
// (updateSources can reshape the tree); an intermediate push only adds names.
export function mergeResolvedPush(current: DiffV2, msg: GuidResolvedPush): DiffV2 {
  return msg.json ?? { ...current, resolved: { ...current.resolved, ...msg.resolved } };
}
