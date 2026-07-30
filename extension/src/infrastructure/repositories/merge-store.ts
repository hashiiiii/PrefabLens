// Needed subset of chrome.storage.local (tests swap in a fake)
type Area = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export type MergeStore = {
  load(id: string): Promise<Record<string, string>>;
  save(id: string, entries: Record<string, string>): Promise<void>;
};

// `prefix:id` slot: save merges into stored instead of replacing (writers only add keys).
// Failures propagate — each call site decides if a lost write is fatal or quota to continue past.
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
