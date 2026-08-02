import type { DiffRepository } from "../../domain/diff/diff-repository";
import type { DiffV2 } from "../../domain/diff/types";

const PREFIX = "diff:";
const MAX_BYTES = 512 * 1024; // storage.session is 10MB: leave large ones to memory cache only

// Needed subset of chrome.storage.session (tests swap in a fake)
type Area = {
  get(keys: string | string[] | null): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
  remove(keys: string | string[]): Promise<void>;
};

// Raw diffs in storage.session under a sha key across SW restarts.
// Quota overflow → wipe diffs and rewrite once; without this every SW restart recomputes forever.
export function createChromeDiffRepository(area: Area): DiffRepository {
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
          // Still unwritable after flush: continue with the memory cache
        });
      }
    },
  };
}

// Wipe only diff: keys (leaves unrelated session keys alone)
async function flushDiffs(area: Area): Promise<void> {
  const all = await area.get(null).catch(() => ({}));
  const keys = Object.keys(all).filter((k) => k.startsWith(PREFIX));
  if (keys.length) await area.remove(keys).catch(() => {});
}
