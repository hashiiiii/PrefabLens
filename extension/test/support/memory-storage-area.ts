import type { StorageAreaWithRemove, StorageEntries } from "../../src/infrastructure/internal/storage-area";

// Capacity applies to the complete state so quota failures reflect the repository's writes.
export class MemoryStorageArea implements StorageAreaWithRemove {
  private values: StorageEntries;

  constructor(
    initial: StorageEntries = {},
    private readonly capacity = Number.POSITIVE_INFINITY,
  ) {
    this.values = { ...initial };
  }

  async get(keys: string | string[] | null): Promise<StorageEntries> {
    const selected = keys === null ? Object.keys(this.values) : Array.isArray(keys) ? keys : [keys];
    return Object.fromEntries(
      selected.filter((key) => Object.hasOwn(this.values, key)).map((key) => [key, this.values[key]]),
    );
  }

  async set(items: StorageEntries): Promise<void> {
    const next = { ...this.values, ...items };
    if (JSON.stringify(next).length > this.capacity) throw new Error("quota exceeded");
    this.values = next;
  }

  async remove(keys: string | string[]): Promise<void> {
    for (const key of Array.isArray(keys) ? keys : [keys]) delete this.values[key];
  }
}
