import type { DiffRepository } from "../../domain/diff/diff-repository";
import type { DiffV2 } from "../../domain/diff/types";
import type { StorageAreaWithRemove } from "../internal/storage-area";

const PREFIX = "diff:";
const MAX_BYTES = 512 * 1024; // storage.session is 10MB: large diffs stay in the memory cache only.

// Raw diffs in storage.session under a sha key across SW restarts.
// On quota overflow, wipe the diffs and rewrite once. Without this, every SW restart recomputes forever.
export function createChromeDiffClient(area: StorageAreaWithRemove): DiffRepository {
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

// Wipe only diff: keys (unrelated session keys stay)
async function flushDiffs(area: StorageAreaWithRemove): Promise<void> {
  const all = await area.get(null).catch(() => ({}));
  const keys = Object.keys(all).filter((k) => k.startsWith(PREFIX));
  if (keys.length) await area.remove(keys).catch(() => {});
}
