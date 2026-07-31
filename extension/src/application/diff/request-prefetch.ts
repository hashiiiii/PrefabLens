import type { PrefetchRequest } from "../../domain/diff/types";
import type { MessengerPort } from "../port/messenger";

export type RequestPrefetchDeps = { messenger: MessengerPort };
export type RequestPrefetch = (req: PrefetchRequest) => Promise<void>;

// Fire-and-forget: manual toggle stays available if prefetch fails
export function createRequestPrefetch(deps: RequestPrefetchDeps): RequestPrefetch {
  return (req) => deps.messenger.prefetch(req).catch(() => {});
}
