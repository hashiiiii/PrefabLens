import type { DiffRepository } from "../../domain/diff/diff-repository";
import { parseGuidFromMeta } from "../../domain/diff/fn/parse-guid-from-meta";
import { targetKey } from "../../domain/diff/fn/target-key";
import type { DiffTarget } from "../../domain/diff/types";
import { err, ok, type Result } from "../../domain/result";
import type { DiffContext, DiffOutcome, DiffSession } from "../diff/create-diff-session";
import type { DifferGateway } from "../gateway/differ";
import {
  type ChangedFile,
  type GithubFailure,
  type GithubGateway,
  isRateLimited,
  type RefPair,
} from "../gateway/github";

const EMPTY = new Uint8Array(0);
const TOO_LARGE_BYTES = 25 * 1024 * 1024; // over 25MB renders on click
const MAX_CONCURRENT_META_FETCHES = 8;

type BlobClient = Pick<GithubGateway, "getBlobRaw" | "getFileAtRef">;
type MetaFetcher = (path: string, side: "base" | "head") => Promise<Result<string | null, GithubFailure>>;

// Prefer blob-sha when known (#110); 404 (force push) falls back to path+ref
export function getBlob(
  session: DiffSession,
  client: BlobClient,
  owner: string,
  repo: string,
  path: string,
  sha: string,
  blobSha?: string,
): Promise<Result<Uint8Array | null, GithubFailure>> {
  // blob sha never collides with `${sha}:${path}`
  return session.blobs.get(blobSha ?? `${sha}:${path}`, async () => {
    if (!blobSha) return client.getFileAtRef(owner, repo, path, sha);
    const raw = await client.getBlobRaw(owner, repo, blobSha);
    if (!raw.ok) return raw;
    if (raw.value) return ok(raw.value);
    return client.getFileAtRef(owner, repo, path, sha);
  });
}

// Before/after blobs; status/previousPath follow the files API
export async function getPair(
  session: DiffSession,
  client: BlobClient,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
): Promise<Result<[Uint8Array, Uint8Array], GithubFailure>> {
  const file = ctx.files.find((f) => f.path === path);
  const status = file?.status ?? "modified";
  const beforePath = file?.previousPath ?? path;
  // files API sha is head blob, except removed where it is the base blob
  const beforeBlob = status === "removed" ? file?.sha : ctx.baseShas?.get(beforePath);
  const afterBlob = status === "removed" ? undefined : file?.sha;
  const fetchSide = async (p: string, ref: string, blob?: string): Promise<Result<Uint8Array, GithubFailure>> => {
    const bytes = await getBlob(session, client, owner, repo, p, ref, blob);
    if (!bytes.ok) return bytes;
    return ok(bytes.value ?? EMPTY);
  };
  if (status === "added") {
    const after = await fetchSide(path, ctx.refs.headSha, afterBlob);
    if (!after.ok) return after;
    return ok([EMPTY, after.value]);
  }
  if (status === "removed") {
    const before = await fetchSide(beforePath, ctx.refs.baseSha, beforeBlob);
    if (!before.ok) return before;
    return ok([before.value, EMPTY]);
  }
  const [before, after] = await Promise.all([
    fetchSide(beforePath, ctx.refs.baseSha, beforeBlob),
    fetchSide(path, ctx.refs.headSha, afterBlob),
  ]);
  if (!before.ok) return before;
  if (!after.ok) return after;
  return ok([before.value, after.value]);
}

// guid→path from .meta files changed in the PR (removed → base side).
// Cap 8 concurrent fetches to avoid GitHub secondary rate limits.
async function createGuidIndex(
  files: ChangedFile[],
  fetchMeta: MetaFetcher,
): Promise<Result<Map<string, string>, GithubFailure>> {
  const index = new Map<string, string>();
  const metas = files.filter((f) => f.path.endsWith(".meta"));

  const indexOne = async (f: ChangedFile): Promise<GithubFailure | null> => {
    const side = f.status === "removed" ? "base" : "head";
    // Only rate limits propagate: swallowing them would cache a degraded index for the SW's lifetime
    const text = await fetchMeta(f.path, side);
    if (!text.ok) {
      if (isRateLimited(text.error)) return text.error;
      return null; // non-rate-limit → skip this meta
    }
    if (!text.value) return null;
    const guid = parseGuidFromMeta(text.value);
    if (guid) index.set(guid, f.path.slice(0, -".meta".length));
    return null;
  };

  for (let i = 0; i < metas.length; i += MAX_CONCURRENT_META_FETCHES) {
    const chunk = metas.slice(i, i + MAX_CONCURRENT_META_FETCHES);
    const failures = await Promise.all(chunk.map(indexOne));
    const rateLimited = failures.find((f): f is GithubFailure => f !== null && isRateLimited(f));
    if (rateLimited) return err(rateLimited);
  }

  return ok(index);
}

// Per-kind: refs + changed-file discovery; everything downstream is target-agnostic
async function loadRefsAndFiles(
  client: GithubGateway,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<Result<{ refs: RefPair; files: ChangedFile[] }, GithubFailure>> {
  if (target.kind === "pull") {
    const [refs, files] = await Promise.all([
      client.getPrRefs(owner, repo, target.prNumber),
      client.listPrFiles(owner, repo, target.prNumber),
    ]);
    if (!refs.ok) return refs;
    if (!files.ok) return files;
    return ok({ refs: refs.value, files: files.value });
  }
  if (target.kind === "commit") {
    const commit = await client.getCommit(owner, repo, target.sha);
    if (!commit.ok) return commit;
    // Root commit: before side is never fetched; own sha as baseSha keeps tree lookups harmless
    return ok({
      refs: { baseSha: commit.value.parentSha ?? commit.value.sha, headSha: commit.value.sha },
      files: commit.value.files,
    });
  }
  const [cmp, headSha] = await Promise.all([
    client.compareRefs(owner, repo, target.base, target.head),
    // Cache keys need an immutable sha; compare commits truncate at 250 so last ≠ always head
    client.resolveRefSha(owner, repo, target.head),
  ]);
  if (!cmp.ok) return cmp;
  if (!headSha.ok) return headSha;
  return ok({ refs: { baseSha: cmp.value.mergeBaseSha, headSha: headSha.value }, files: cmp.value.files });
}

export function getContext(
  session: DiffSession,
  client: GithubGateway,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<Result<DiffContext, GithubFailure>> {
  return session.contexts.get(targetKey(owner, repo, target), async () => {
    const loaded = await loadRefsAndFiles(client, owner, repo, target);
    if (!loaded.ok) return loaded;
    const { refs, files } = loaded.value;
    const bySha = new Map(files.map((f) => [f.path, f.sha]));
    const [guidIndex, tree] = await Promise.all([
      createGuidIndex(files, async (path, side) => {
        // files API sha matches the side createGuidIndex reads (head, or base for removed metas)
        const bytes = await getBlob(
          session,
          client,
          owner,
          repo,
          path,
          side === "base" ? refs.baseSha : refs.headSha,
          bySha.get(path),
        );
        if (!bytes.ok) return bytes;
        return ok(bytes.value ? new TextDecoder().decode(bytes.value) : null);
      }),
      // Only rate limits propagate; anything else → null → contents-api fallback
      client.listBlobShas(owner, repo, refs.baseSha),
    ]);
    if (!guidIndex.ok) return guidIndex;
    let baseShas: Map<string, string> | null = null;
    if (tree.ok) {
      baseShas = tree.value.truncated ? null : tree.value.byPath;
    } else if (isRateLimited(tree.error)) {
      return tree;
    }
    return ok({ refs, files, guidIndex: guidIndex.value, baseShas });
  });
}

// Raw sha-keyed diff only; resolution/source merge stay out (Code Search improves later)
async function computeDiff(
  getDiffer: () => Promise<DifferGateway>,
  session: DiffSession,
  client: GithubGateway,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  force: boolean,
): Promise<DiffOutcome> {
  // Missing from listing (files API caps at 3000) → treat as modified; 404 side → EMPTY
  const pair = await getPair(session, client, ctx, owner, repo, path);
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
  getDiffer: () => Promise<DifferGateway>,
  diffStore: DiffRepository,
  session: DiffSession,
  client: GithubGateway,
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
