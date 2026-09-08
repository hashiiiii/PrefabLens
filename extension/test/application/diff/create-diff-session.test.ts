import { describe, expect, it } from "vitest";
import { createDiffSession, type DiffContext } from "../../../src/application/diff/create-diff-session";
import type { GithubFailure } from "../../../src/application/gateway/github";
import { err, ok, type Result } from "../../../src/domain/result";

const failures = ["rejects", "returns a failure"] as const;

async function failRequest<T>(
  request: PromiseWithResolvers<Result<T, GithubFailure>>,
  failure: (typeof failures)[number],
) {
  if (failure === "rejects") {
    request.reject(new Error("fetch failed"));
    await expect(request.promise).rejects.toThrow("fetch failed");
  } else {
    request.resolve(err({ kind: "fetch-failed" }));
    await expect(request.promise).resolves.toEqual({ ok: false, error: { kind: "fetch-failed" } });
  }
}

const context: DiffContext = {
  refs: { baseSha: "base", headSha: "head" },
  files: [],
  guidIndex: new Map(),
  baseShas: new Map(),
};

describe("createDiffSession", () => {
  it.each(failures)("preserves the refreshed context when an expired request %s", async (failure) => {
    let now = 0;
    const session = createDiffSession(() => now);
    const request = Promise.withResolvers<Result<DiffContext, GithubFailure>>();
    const expired = session.contexts.get("context", () => request.promise);

    // A refresh can finish while the expired request still waits on the network.
    now = 60_001;
    const refreshed = session.contexts.get("context", async () => ok(context));
    expect(refreshed).not.toBe(expired);
    await expect(refreshed).resolves.toEqual({ ok: true, value: context });

    await failRequest(request, failure);

    expect(session.contexts.get("context", async () => ok(context))).toBe(refreshed);
  });

  it.each(failures)("preserves the replacement blob when an evicted request %s", async (failure) => {
    const session = createDiffSession();
    const request = Promise.withResolvers<Result<Uint8Array | null, GithubFailure>>();
    const evicted = session.blobs.get("blob", () => request.promise);

    // Filling the 32-entry cache evicts the pending request without settling it.
    for (let index = 0; index < 32; index++) {
      await session.blobs.get(`other-${index}`, async () => ok(null));
    }
    const bytes = new Uint8Array([1, 2, 3]);
    const replacement = session.blobs.get("blob", async () => ok(bytes));
    expect(replacement).not.toBe(evicted);
    await expect(replacement).resolves.toEqual({ ok: true, value: bytes });

    await failRequest(request, failure);

    expect(session.blobs.get("blob", async () => ok(null))).toBe(replacement);
  });

  it.each(failures)("retries when the current request %s", async (failure) => {
    const session = createDiffSession();
    const request = Promise.withResolvers<Result<DiffContext, GithubFailure>>();
    const failed = session.contexts.get("context", () => request.promise);

    // The ownership check must still remove a failure that has no replacement.
    await failRequest(request, failure);

    const retry = session.contexts.get("context", async () => ok(context));
    expect(retry).not.toBe(failed);
    await expect(retry).resolves.toEqual({ ok: true, value: context });
    expect(session.contexts.get("context", async () => ok(context))).toBe(retry);
  });
});
