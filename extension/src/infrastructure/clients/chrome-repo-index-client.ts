import type { RepoGuidIndex } from "../../domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { createMergeStore } from "./merge-store";
import type { StorageArea } from "./storage-area";

export function createChromeRepoIndexClient(area: StorageArea): RepoIndexRepository {
  const metaGuids = createMergeStore(area, "metaGuids");
  const indexKey = (repo: string): string => `guidIndex:${repo}`;
  return {
    loadGuids: (repo) => metaGuids.load(repo),
    saveGuids: (repo, entries) => metaGuids.save(repo, entries).catch(() => {}),
    async loadIndex(repo) {
      const stored = await area.get([indexKey(repo)]);
      return stored[indexKey(repo)] as RepoGuidIndex | undefined;
    },
    async saveIndex(repo, index) {
      await area.set({ [indexKey(repo)]: index }).catch(() => {});
    },
  };
}
