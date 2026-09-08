import type { StorageArea } from "./storage-area";

export type MergeStore = {
  load(id: string): Promise<Record<string, string>>;
  save(id: string, entries: Record<string, string>): Promise<void>;
};

// Repository instances can share storage keys, so their writes must share a queue.
const pendingWrites = new WeakMap<StorageArea, Map<string, Promise<void>>>();

// `prefix:id` slot: save merges into stored instead of replacing (writers only add keys).
// Failures propagate. Each call site decides if a lost write is fatal or if the code continues past it.
export function createMergeStore(area: StorageArea, prefix: string): MergeStore {
  const pending = pendingWrites.get(area) ?? new Map<string, Promise<void>>();
  pendingWrites.set(area, pending);
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
      const key = keyOf(id);
      const write = (pending.get(key) ?? Promise.resolve())
        // A failed save still releases the key; its caller receives the original error below.
        .catch(() => {})
        .then(async () => {
          await area.set({ [key]: { ...(await load(id)), ...entries } });
        });
      pending.set(key, write);
      try {
        await write;
      } finally {
        // An older save must not remove a newer save's place in the queue.
        if (pending.get(key) === write) pending.delete(key);
      }
    },
  };
}
