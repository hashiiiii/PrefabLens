import { expect, it } from "vitest";
import type { PrefetchRequest } from "../../domain/diff/types";
import { createRequestPrefetch } from "./request-prefetch";

const REQ: PrefetchRequest = { type: "prefetch", owner: "o", repo: "r", prNumber: 1 };

it("fires the prefetch and swallows channel failures", async () => {
  const seen: PrefetchRequest[] = [];
  const request = createRequestPrefetch({
    messenger: {
      semanticDiff: async () => ({ ok: false, error: "fetch-failed" }),
      prefetch: async (req) => {
        seen.push(req);
        throw new Error("channel closed");
      },
    },
  });
  // Fire-and-forget: manual toggle stays available if prefetch fails
  await expect(request(REQ)).resolves.toBeUndefined();
  expect(seen).toEqual([REQ]);
});
