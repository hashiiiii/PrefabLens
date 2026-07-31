import type { DiffCachePort } from "../port/diff-cache";
import type { DifferPort } from "../port/differ";
import type { GithubPort } from "../port/github";
import type { DiffContext, DiffOutcome, DiffSession } from "./_diff-session";
import { fetchPair } from "./_fetch-blobs";

const TOO_LARGE_BYTES = 25 * 1024 * 1024; // over 25MB renders on click

export type GetDiffDeps = {
  getDiffer(): Promise<DifferPort>;
  diffStore: DiffCachePort;
};

// Raw sha-keyed diff only; resolution/mergeSources stay out (Code Search improves later)
async function computeDiff(
  deps: GetDiffDeps,
  session: DiffSession,
  client: GithubPort,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  force: boolean,
): Promise<DiffOutcome> {
  // Missing from listing (files API caps at 3000) → treat as modified; 404 side → EMPTY
  const [before, after] = await fetchPair(session, client, ctx, owner, repo, path);
  if (!force && before.length + after.length > TOO_LARGE_BYTES) {
    return { ok: false, error: "too-large", bytes: before.length + after.length };
  }
  const differ = await deps.getDiffer();
  // Prefilter passed, but some .asset files are binary regardless of ForceText
  if (!differ.isUnityYaml(before) && !differ.isUnityYaml(after)) {
    return { ok: false, error: "not-unity-yaml" };
  }
  return { ok: true, json: differ.diff(before, after) };
}

// Sha-keyed: a push produces a new key (no invalidation)
export function getDiff(
  deps: GetDiffDeps,
  session: DiffSession,
  client: GithubPort,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  force: boolean,
): Promise<DiffOutcome> {
  const key = `${ctx.refs.baseSha}:${ctx.refs.headSha}:${path}`;
  return session.diffs.get(key, async (): Promise<DiffOutcome> => {
    const stored = await deps.diffStore.load(key); // prior SW life
    if (stored) return { ok: true, json: stored };
    const outcome = await computeDiff(deps, session, client, ctx, owner, repo, path, force);
    if (outcome.ok) void deps.diffStore.save(key, outcome.json);
    return outcome;
  });
}
