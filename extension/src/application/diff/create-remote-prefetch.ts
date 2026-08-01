import type { PrefetchRequest } from "../../domain/diff/types";
import type { MessengerPort } from "../port/messenger";

// Fire-and-forget: manual toggle stays available if prefetch fails
export function createRemotePrefetch(messenger: MessengerPort, req: PrefetchRequest): Promise<void> {
  return messenger.prefetch(req).catch(() => {});
}
