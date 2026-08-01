import type { RepoGuidIndex } from "../../domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { createMergeStore } from "./merge-store";

type Area = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export function createChromeRepoIndexRepository(area: Area): RepoIndexRepository {
  const metaGuids = createMergeStore(area, "metaGuids");
  return {
    loadGuids: (repo) => metaGuids.load(repo),
    saveGuids: (repo, entries) => metaGuids.save(repo, entries).catch(() => {}),
    async loadIndex(repo) {
      const key = `guidIndex:${repo}`;
      const stored = await area.get([key]);
      return stored[key] as RepoGuidIndex | undefined;
    },
    async saveIndex(repo, index) {
      await area.set({ [`guidIndex:${repo}`]: index }).catch(() => {});
    },
  };
}
