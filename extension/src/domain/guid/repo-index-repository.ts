import type { GuidMap } from "./guid-map";
import type { RepoGuidIndex } from "./repo-guid-index";

export type RepoIndexRepository = {
  loadGuids(repo: string): Promise<GuidMap>;
  saveGuids(repo: string, entries: GuidMap): Promise<void>;
  loadIndex(repo: string): Promise<RepoGuidIndex | undefined>;
  saveIndex(repo: string, index: RepoGuidIndex): Promise<void>;
};
