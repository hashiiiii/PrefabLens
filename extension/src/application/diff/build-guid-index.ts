import { parseGuidFromMeta } from "../../domain/diff/meta-guid";
import { err, ok, type Result } from "../../domain/result";
import { type ChangedFile, type GithubFailure, isRateLimited } from "../port/github";

export type MetaFetcher = (path: string, side: "base" | "head") => Promise<Result<string | null, GithubFailure>>;

const MAX_CONCURRENT_META_FETCHES = 8;

// guid→path from .meta files changed in the PR (removed → base side).
// Cap 8 concurrent fetches to avoid GitHub secondary rate limits.
export async function buildGuidIndex(
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
