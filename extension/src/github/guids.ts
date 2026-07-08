import type { DiffV2 } from "../types";
import { type PrFile, RateLimitError } from "./client";

/** Same rule as parseGuid in cli/src/resolve.zig: picks up "guid:" at the start of a line (after trim). */
export function parseGuidFromMeta(meta: string): string | undefined {
  for (const line of meta.split("\n")) {
    const t = line.trim();
    if (t.startsWith("guid:")) return t.slice("guid:".length).trim();
  }
  return undefined;
}

export type MetaFetcher = (path: string, side: "base" | "head") => Promise<string | null>;

/** Persistent cache of guid→asset path resolved via Code Search (repo key is `<apiBase>/<owner>/<repo>`).
 *  guid→path is stable, so no TTL. save merges. */
export type GuidCache = {
  load(repo: string): Promise<Record<string, string>>;
  save(repo: string, entries: Record<string, string>): Promise<void>;
};

const MAX_CONCURRENT_META_FETCHES = 8;

/** Builds a guid → asset path index only from .meta files changed in the PR. removed ones are read from the base side.
 *  Caps concurrent fetches at 8 (avoids GitHub secondary rate limits on large .meta changes). */
export async function buildGuidIndex(files: PrFile[], fetchMeta: MetaFetcher): Promise<Map<string, string>> {
  const index = new Map<string, string>();
  const metas = files.filter((f) => f.path.endsWith(".meta"));

  const indexOne = async (f: PrFile): Promise<void> => {
    const side = f.status === "removed" ? "base" : "head";
    // Only rate limits propagate: swallowing them would cache a degraded index for the SW's lifetime
    const text = await fetchMeta(f.path, side).catch((err) => {
      if (err instanceof RateLimitError) throw err;
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

/** Host-side resolution seam. Attaches with the same scoping rule as core's "resolved". */
export function applyResolved(diff: DiffV2, index: Map<string, string>): DiffV2 {
  const resolved: Record<string, string> = {};
  for (const g of diff.unresolvedGuids) {
    const path = index.get(g);
    if (path !== undefined) resolved[g] = path;
  }
  return { ...diff, resolved };
}
