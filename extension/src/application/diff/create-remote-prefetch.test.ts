import { expect, it } from "vitest";
import type { PrefetchRequest } from "../../domain/diff/types";
import { createRemotePrefetch } from "./create-remote-prefetch";

const REQ: PrefetchRequest = { type: "prefetch", owner: "o", repo: "r", prNumber: 1 };

it("fires the prefetch and swallows channel failures", async () => {
  const seen: PrefetchRequest[] = [];
  const messenger = {
    semanticDiff: async () => ({ ok: false as const, error: "fetch-failed" as const }),
    prefetch: async (req: PrefetchRequest) => {
      seen.push(req);
      throw new Error("channel closed");
    },
  };
  // Fire-and-forget: manual toggle stays available if prefetch fails
  await expect(createRemotePrefetch(messenger, REQ)).resolves.toBeUndefined();
  expect(seen).toEqual([REQ]);
});
