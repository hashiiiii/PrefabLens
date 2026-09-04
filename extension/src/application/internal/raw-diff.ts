import type { DiffRepository } from "../../domain/diff/diff-repository";
import { assetPathFromMeta } from "../../domain/diff/fn/asset-path-from-meta";
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
const TOO_LARGE_BYTES = 25 * 1024 * 1024; // Files over 25MB render only on click.
const MAX_CONCURRENT_META_FETCHES = 8;
const utf8 = new TextDecoder();

type GithubBlobs = Pick<GithubGateway, "getBlobRaw" | "getFileAtRef">;
type MetaFetcher = (path: string, side: "base" | "head") => Promise<Result<string | null, GithubFailure>>;

// The blob sha wins when it is known (#110). On 404 (force push), the fetch uses path+ref instead.
export function getBlob(
  session: DiffSession,
  githubGateway: GithubBlobs,
  owner: string,
  repo: string,
  path: string,
  sha: string,
  blobSha?: string,
): Promise<Result<Uint8Array | null, GithubFailure>> {
  // blob sha never collides with `${sha}:${path}`
  return session.blobs.get(blobSha ?? `${sha}:${path}`, async () => {
    if (!blobSha) return githubGateway.getFileAtRef(owner, repo, path, sha);
    const raw = await githubGateway.getBlobRaw(owner, repo, blobSha);
    if (!raw.ok) return raw;
    if (raw.value) return ok(raw.value);
    return githubGateway.getFileAtRef(owner, repo, path, sha);
  });
}

// Before/after blobs. status/previousPath follow the files API.
export async function getPair(
  session: DiffSession,
  githubGateway: GithubBlobs,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
): Promise<Result<[Uint8Array, Uint8Array], GithubFailure>> {
  const file = ctx.files.find((f) => f.path === path);
  const beforePath = file?.previousPath ?? path;
  const fetchSide = async (p: string, ref: string, blob?: string): Promise<Result<Uint8Array, GithubFailure>> => {
    const bytes = await getBlob(session, githubGateway, owner, repo, p, ref, blob);
    if (!bytes.ok) return bytes;
    return ok(bytes.value ?? EMPTY);
  };
  switch (file?.status ?? "modified") {
    case "added": {
      const after = await fetchSide(path, ctx.refs.headSha, file?.sha);
      if (!after.ok) return after;
      return ok([EMPTY, after.value]);
    }
    case "removed": {
      // The files API sha is the head blob. For removed files, it is the base blob.
      const before = await fetchSide(beforePath, ctx.refs.baseSha, file?.sha);
      if (!before.ok) return before;
      return ok([before.value, EMPTY]);
    }
    default: {
      const [before, after] = await Promise.all([
        fetchSide(beforePath, ctx.refs.baseSha, ctx.baseShas?.get(beforePath)),
        fetchSide(path, ctx.refs.headSha, file?.sha),
      ]);
      if (!before.ok) return before;
      if (!after.ok) return after;
      return ok([before.value, after.value]);
    }
  }
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
    // Only rate limits propagate: a hidden rate limit caches a degraded index for the SW lifetime
    const text = await fetchMeta(f.path, side);
    if (!text.ok) {
      if (isRateLimited(text.error)) return text.error;
      return null; // A non-rate-limit failure skips this meta.
    }
    if (!text.value) return null;
    const guid = parseGuidFromMeta(text.value);
    if (guid) index.set(guid, assetPathFromMeta(f.path));
    return null;
  };

  for (let i = 0; i < metas.length; i += MAX_CONCURRENT_META_FETCHES) {
    const chunk = metas.slice(i, i + MAX_CONCURRENT_META_FETCHES);
    const failures = await Promise.all(chunk.map(indexOne));
    // indexOne discards every failure that is not a rate limit, so each non-null entry is a rate limit.
    const rateLimited = failures.find((f): f is GithubFailure => f !== null);
    if (rateLimited) return err(rateLimited);
  }

  return ok(index);
}

// Per-kind: refs and changed-file discovery. Everything downstream is target-agnostic.
async function loadRefsAndFiles(
  githubGateway: GithubGateway,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<Result<{ refs: RefPair; files: ChangedFile[] }, GithubFailure>> {
  if (target.kind === "pull") {
    const [refs, files] = await Promise.all([
      githubGateway.getPrRefs(owner, repo, target.prNumber),
      githubGateway.listPrFiles(owner, repo, target.prNumber),
    ]);
    if (!refs.ok) return refs;
    if (!files.ok) return files;
    return ok({ refs: refs.value, files: files.value });
  }
  if (target.kind === "commit") {
    const commit = await githubGateway.getCommit(owner, repo, target.sha);
    if (!commit.ok) return commit;
    // Root commit: the before side is never fetched. Its own sha as baseSha keeps tree lookups harmless.
    return ok({
      refs: { baseSha: commit.value.parentSha ?? commit.value.sha, headSha: commit.value.sha },
      files: commit.value.files,
    });
  }
  const [cmp, headSha] = await Promise.all([
    githubGateway.compareRefs(owner, repo, target.base, target.head),
    // Cache keys need an immutable sha. Compare commits truncate at 250, so the last one is not always the head.
    githubGateway.resolveRefSha(owner, repo, target.head),
  ]);
  if (!cmp.ok) return cmp;
  if (!headSha.ok) return headSha;
  return ok({ refs: { baseSha: cmp.value.mergeBaseSha, headSha: headSha.value }, files: cmp.value.files });
}

export function getContext(
  session: DiffSession,
  githubGateway: GithubGateway,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<Result<DiffContext, GithubFailure>> {
  return session.contexts.get(targetKey(owner, repo, target), async () => {
    const loaded = await loadRefsAndFiles(githubGateway, owner, repo, target);
    if (!loaded.ok) return loaded;
    const { refs, files } = loaded.value;
    const bySha = new Map(files.map((f) => [f.path, f.sha]));
    const [guidIndex, tree] = await Promise.all([
      createGuidIndex(files, async (path, side) => {
        // files API sha matches the side createGuidIndex reads (head, or base for removed metas)
        const bytes = await getBlob(
          session,
          githubGateway,
          owner,
          repo,
          path,
          side === "base" ? refs.baseSha : refs.headSha,
          bySha.get(path),
        );
        if (!bytes.ok) return bytes;
        return ok(bytes.value ? utf8.decode(bytes.value) : null);
      }),
      // Only rate limits propagate. Anything else becomes null, and the contents API applies instead.
      githubGateway.listBlobShas(owner, repo, refs.baseSha),
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

// Raw sha-keyed diff only. Resolution and the source merge stay out (Code Search improves later).
async function computeDiff(
  getDiffer: () => Promise<DifferGateway>,
  session: DiffSession,
  githubGateway: GithubGateway,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  force: boolean,
): Promise<DiffOutcome> {
  // The memoized wasm load compiles while the blobs download, not after them.
  const differPromise = getDiffer();
  differPromise.catch(() => {}); // Early returns below skip the await. The later await still surfaces the error.
  // A file missing from the listing (the files API caps at 3000) is treated as modified. A 404 side becomes EMPTY.
  const pair = await getPair(session, githubGateway, ctx, owner, repo, path);
  if (!pair.ok) return { ok: false, error: pair.error.kind };
  const [before, after] = pair.value;
  if (!force && before.length + after.length > TOO_LARGE_BYTES) {
    return { ok: false, error: "too-large", bytes: before.length + after.length };
  }
  const differ = await differPromise;
  // Prefilter passed, but some .asset files are binary regardless of ForceText
  if (!differ.isUnityYaml(before) && !differ.isUnityYaml(after)) {
    return { ok: false, error: "not-unity-yaml" };
  }
  const result = differ.diff(before, after);
  if (!result.ok) return { ok: false, error: "diff-failed" };
  return { ok: true, json: result.value };
}

// Sha-keyed: a push produces a new key (no invalidation)
export async function getDiff(
  getDiffer: () => Promise<DifferGateway>,
  diffRepository: DiffRepository,
  session: DiffSession,
  githubGateway: GithubGateway,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  force: boolean,
): Promise<DiffOutcome> {
  const key = diffCacheKey(ctx, path);
  const stored = await diffRepository.load(key);
  if (stored) return { ok: true, json: stored };
  return session.diffs.get(key, async (): Promise<DiffOutcome> => {
    const outcome = await computeDiff(getDiffer, session, githubGateway, ctx, owner, repo, path, force);
    if (outcome.ok) await diffRepository.save(key, outcome.json);
    return outcome;
  });
}

export function diffCacheKey(ctx: DiffContext, path: string): string {
  return `${ctx.refs.baseSha}:${ctx.refs.headSha}:${path}`;
}
