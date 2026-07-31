import type { DiffCachePort } from "../port/diff-cache";
import type { DifferPort } from "../port/differ";
import type { GithubPort } from "../port/github";
import type { DiffContext, DiffOutcome, DiffSession } from "./_diff-session";
import { fetchPair } from "./_fetch-blobs";

const TOO_LARGE_BYTES = 25 * 1024 * 1024; // over 25MB renders on click

// Raw sha-keyed diff only; resolution/mergeSources stay out (Code Search improves later)
async function computeDiff(
  getDiffer: () => Promise<DifferPort>,
  session: DiffSession,
  client: GithubPort,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  force: boolean,
): Promise<DiffOutcome> {
  // Missing from listing (files API caps at 3000) → treat as modified; 404 side → EMPTY
  const pair = await fetchPair(session, client, ctx, owner, repo, path);
  if (!pair.ok) return { ok: false, error: pair.error.kind };
  const [before, after] = pair.value;
  if (!force && before.length + after.length > TOO_LARGE_BYTES) {
    return { ok: false, error: "too-large", bytes: before.length + after.length };
  }
  const differ = await getDiffer();
  // Prefilter passed, but some .asset files are binary regardless of ForceText
  if (!differ.isUnityYaml(before) && !differ.isUnityYaml(after)) {
    return { ok: false, error: "not-unity-yaml" };
  }
  const result = differ.diff(before, after);
  if (!result.ok) return { ok: false, error: "diff-failed" };
  return { ok: true, json: result.value };
}

// Sha-keyed: a push produces a new key (no invalidation)
export function getDiff(
  getDiffer: () => Promise<DifferPort>,
  diffStore: DiffCachePort,
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
    const stored = await diffStore.load(key); // prior SW life
    if (stored) return { ok: true, json: stored };
    const outcome = await computeDiff(getDiffer, session, client, ctx, owner, repo, path, force);
    if (outcome.ok) void diffStore.save(key, outcome.json);
    return outcome;
  });
}
