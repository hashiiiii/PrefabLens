import type { JsonValue } from "../../internal/json";

// Chrome storage serializes values as JSON; undefined object fields are omitted.
export type StorageEntries = Record<string, JsonValue | undefined>;

export type StorageArea = {
  get(keys: string | string[] | null): Promise<StorageEntries>;
  set(items: StorageEntries): Promise<void>;
};

export type StorageAreaWithRemove = StorageArea & {
  remove(keys: string | string[]): Promise<void>;
};
