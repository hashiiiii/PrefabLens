// Accepts only the needed subset of chrome.storage.local (so tests can swap in a fake)
type Area = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export type MergeStore = {
  load(id: string): Promise<Record<string, string>>;
  save(id: string, entries: Record<string, string>): Promise<void>;
};

/** A `prefix:id` storage slot holding a string record, where save merges entries into
 *  what is stored instead of replacing it (writers only ever add keys, so a stale read
 *  loses nothing but the other writer's additions). Failures propagate: each call site
 *  decides whether a lost write is fatal or a quota overflow to continue past. */
export function createMergeStore(area: Area, prefix: string): MergeStore {
  const keyOf = (id: string): string => `${prefix}:${id}`;
  return {
    async load(id) {
      const key = keyOf(id);
      const stored = await area.get([key]);
      return (stored[key] as Record<string, string> | undefined) ?? {};
    },
    async save(id, entries) {
      const key = keyOf(id);
      const stored = await area.get([key]);
      await area.set({ [key]: { ...(stored[key] as Record<string, string> | undefined), ...entries } });
    },
  };
}
