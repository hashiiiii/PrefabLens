import type { StorageArea } from "./storage-area";

export type MergeStore = {
  load(id: string): Promise<Record<string, string>>;
  save(id: string, entries: Record<string, string>): Promise<void>;
};

// `prefix:id` slot: save merges into stored instead of replacing (writers only add keys).
// Failures propagate. Each call site decides if a lost write is fatal or if the code continues past it.
export function createMergeStore(area: StorageArea, prefix: string): MergeStore {
  const keyOf = (id: string): string => `${prefix}:${id}`;
  const load = async (id: string): Promise<Record<string, string>> => {
    const key = keyOf(id);
    const stored = await area.get([key]);
    // This store owns its prefixed keys and saves only GUID or metadata maps with string values.
    return (stored[key] as Record<string, string> | undefined) ?? {};
  };
  return {
    load,
    async save(id, entries) {
      await area.set({ [keyOf(id)]: { ...(await load(id)), ...entries } });
    },
  };
}
