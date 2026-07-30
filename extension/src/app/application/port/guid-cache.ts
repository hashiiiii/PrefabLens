export type GuidCachePort = {
  load(repo: string): Promise<Record<string, string>>;
  save(repo: string, entries: Record<string, string>): Promise<void>;
};
