import { describe, expect, it } from "vitest";
import { err, ok } from "../../domain/result";
import { createDiffSession } from "../create-diff-session";
import type { ChangedFile } from "../port/github";
import { createPrPrefetch } from "./create-pr-prefetch";
import { DIFF, makeFakes, REQ, resolveFully } from "./diff-test-fakes";

describe("prefetch", () => {
  it("precomputes diffs so a later toggle serves without new blob fetches", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, client } = makeFakes();
    const session = createDiffSession();
    await createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, session, {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled(); // prefetch doesn't touch the 10 req/min Code Search
    const fetchesAfterPrefetch = client.getFileAtRef.mock.calls.length;
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      session,
      REQ,
    );
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetchesAfterPrefetch); // no blob re-fetch
  });

  it("persists prefetched diffs to the diff store (sw restart survival)", async () => {
    const { tokenStore, makeClient, getDiffer, diffStore, repoIndexStore } = makeFakes();
    await createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, createDiffSession(), {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    });
    expect(diffStore.save).toHaveBeenCalledWith("base-sha:head-sha:Assets/Foo.prefab", DIFF);
  });

  it("serves a diff persisted by a previous worker from the store", async () => {
    // The SW dies after 30 seconds: a result prefetched in a prior life must be recoverable via storage.session
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, client } = makeFakes();
    diffStore.data["base-sha:head-sha:Assets/Foo.prefab"] = DIFF; // seeded as if saved by a prior SW life
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).not.toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "base-sha");
  });

  it("prefetches only unity files and caps at 100", async () => {
    const files: ChangedFile[] = Array.from({ length: 120 }, (_, i) => ({
      path: `Assets/F${i}.prefab`,
      status: "modified",
    }));
    files.push({ path: "README.md", status: "modified" });
    const { tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, client } = makeFakes({ files });
    await createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, createDiffSession(), {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    });
    const paths = new Set(client.getFileAtRef.mock.calls.map((c) => c[2]));
    expect(paths.has("README.md")).toBe(false);
    expect(paths.size).toBe(100); // cut off at the cap
  });

  it("skips oversized files without caching them", async () => {
    const big = new Uint8Array(13 * 1024 * 1024);
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, client } = makeFakes();
    client.getFileAtRef.mockResolvedValue(ok(big));
    const session = createDiffSession();
    await createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, session, {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    });
    expect(diffStore.save).not.toHaveBeenCalled();
    // A later manual toggle still shows the too-large gate as before
    expect(
      await resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ),
    ).toEqual({ ok: false, error: "too-large", bytes: big.length * 2 });
  });

  it("aborts silently on rate limit instead of surfacing an error", async () => {
    // 12 unity files: ignoring the rate limit would fetch all of them
    const files: ChangedFile[] = Array.from({ length: 12 }, (_, i) => ({
      path: `Assets/F${i}.prefab`,
      status: "modified",
    }));
    const { tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, client } = makeFakes({ files });
    client.getFileAtRef.mockResolvedValue(err({ kind: "rate-limited" as const }) as never);
    await expect(
      createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, createDiffSession(), {
        type: "prefetch",
        owner: "o",
        repo: "r",
        prNumber: 1,
      }),
    ).resolves.toBeUndefined();
    // The abort is observable: nothing was cached and only the first chunk was attempted
    expect(diffStore.save).not.toHaveBeenCalled();
    const attempted = new Set(client.getFileAtRef.mock.calls.map((c) => c[2]));
    expect(attempted.size).toBeLessThanOrEqual(4); // PREFETCH_CONCURRENCY
  });

  it("returns without network when the access token is missing", async () => {
    const { tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, client } = makeFakes({
      accessToken: undefined,
    });
    await createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, createDiffSession(), {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });
});
