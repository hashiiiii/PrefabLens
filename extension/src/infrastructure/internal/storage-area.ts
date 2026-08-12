export type StorageArea = {
  get(keys: string | string[] | null): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export type StorageAreaWithRemove = StorageArea & {
  remove(keys: string | string[]): Promise<void>;
};
