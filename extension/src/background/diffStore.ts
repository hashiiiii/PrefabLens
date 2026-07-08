import type { DiffV2 } from "../types";

const PREFIX = "diff:";
const MAX_BYTES = 512 * 1024; // storage.session is 10MB: leave large ones to the memory cache only (recompute if the SW dies)

// Accepts only the needed subset of chrome.storage.session (so tests can swap in a fake)
type Area = {
  get(keys: string | string[] | null): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
  remove(keys: string | string[]): Promise<void>;
};

export type DiffStore = {
  load(key: string): Promise<DiffV2 | undefined>;
  save(key: string, json: DiffV2): Promise<void>;
};

/** Stores raw diffs in storage.session under a sha key, reusing them across SW restarts.
 *  On quota overflow, wipe the accumulated diffs and rewrite once: without this, once it fills up
 *  every SW restart thereafter recomputes everything and it silently degrades permanently (content is recomputable from the sha key). */
export function createSessionDiffStore(area: Area): DiffStore {
  return {
    async load(key) {
      const stored = await area.get(PREFIX + key);
      return stored[PREFIX + key] as DiffV2 | undefined;
    },
    async save(key, json) {
      if (JSON.stringify(json).length > MAX_BYTES) return;
      try {
        await area.set({ [PREFIX + key]: json });
      } catch {
        await flushDiffs(area);
        await area.set({ [PREFIX + key]: json }).catch(() => {
          // Still unwritable after flush (a single diff over quota, etc.): continue with the memory cache
        });
      }
    },
  };
}

/** Wipes only keys with the diff: prefix (keeps unrelated session keys like viewMode). */
async function flushDiffs(area: Area): Promise<void> {
  const all = await area.get(null).catch(() => ({}));
  const keys = Object.keys(all).filter((k) => k.startsWith(PREFIX));
  if (keys.length) await area.remove(keys).catch(() => {});
}
