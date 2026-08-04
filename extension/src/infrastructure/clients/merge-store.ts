import type { StorageArea } from "./storage-area";

export type MergeStore = {
  load(id: string): Promise<Record<string, string>>;
  save(id: string, entries: Record<string, string>): Promise<void>;
};

// `prefix:id` slot: save merges into stored instead of replacing (writers only add keys).
// Failures propagate. Each call site decides if a lost write is fatal or if the code continues past it.
export function createMergeStore(area: StorageArea, prefix: string): MergeStore {
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
