import { expect, it } from "vitest";
import type { SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";
import type { MessengerPort } from "../port/messenger";
import { getRemoteSemanticDiff } from "./get-remote-semantic-diff";

const REQ: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "Assets/Foo.prefab",
};

const OK: SemanticDiffResponse = {
  ok: true,
  json: { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] },
};

function messenger(semanticDiff: MessengerPort["semanticDiff"]): MessengerPort {
  return { semanticDiff, prefetch: async () => {} };
}

it("passes the request through and returns the background response", async () => {
  const seen: SemanticDiffRequest[] = [];
  const result = await getRemoteSemanticDiff(
    messenger(async (req) => {
      seen.push(req);
      return OK;
    }),
    REQ,
  );
  expect(result).toEqual(OK);
  expect(seen).toEqual([REQ]);
});

it("maps a lost channel (rejection) to fetch-failed instead of throwing", async () => {
  // chrome.runtime.sendMessage rejects when the SW restarts mid-flight
  const result = await getRemoteSemanticDiff(
    messenger(async () => {
      throw new Error("channel closed");
    }),
    REQ,
  );
  expect(result).toEqual({ ok: false, error: "fetch-failed" });
});
