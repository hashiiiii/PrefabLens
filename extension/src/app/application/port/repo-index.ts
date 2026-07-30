export type RepoIndexPort = {
  loadGuids(repo: string): Promise<Record<string, string>>;
  saveGuids(repo: string, entries: Record<string, string>): Promise<void>;
  loadIndex(repo: string): Promise<{ treeSha: string; guids: Record<string, string> } | undefined>;
  saveIndex(repo: string, index: { treeSha: string; guids: Record<string, string> }): Promise<void>;
};
