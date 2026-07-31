import { parseGuidFromMeta } from "../../domain/diff/meta-guid";
import { type ChangedFile, isRateLimited } from "../port/github";

export type MetaFetcher = (path: string, side: "base" | "head") => Promise<string | null>;

const MAX_CONCURRENT_META_FETCHES = 8;

// guid→path from .meta files changed in the PR (removed → base side).
// Cap 8 concurrent fetches to avoid GitHub secondary rate limits.
export async function buildGuidIndex(files: ChangedFile[], fetchMeta: MetaFetcher): Promise<Map<string, string>> {
  const index = new Map<string, string>();
  const metas = files.filter((f) => f.path.endsWith(".meta"));

  const indexOne = async (f: ChangedFile): Promise<void> => {
    const side = f.status === "removed" ? "base" : "head";
    // Only rate limits propagate: swallowing them would cache a degraded index for the SW's lifetime
    const text = await fetchMeta(f.path, side).catch((err) => {
      if (isRateLimited(err)) throw err;
      return null;
    });
    if (!text) return;
    const guid = parseGuidFromMeta(text);
    if (guid) index.set(guid, f.path.slice(0, -".meta".length));
  };

  for (let i = 0; i < metas.length; i += MAX_CONCURRENT_META_FETCHES) {
    const chunk = metas.slice(i, i + MAX_CONCURRENT_META_FETCHES);
    await Promise.all(chunk.map(indexOne));
  }

  return index;
}
