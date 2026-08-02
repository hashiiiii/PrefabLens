// Repo-scoped identity for persistent caches (guid cache, repo index).
// Prefetch writes and serve-time reads must build the same key.
export function repoKey(apiBase: string, owner: string, repo: string): string {
  return `${apiBase}/${owner}/${repo}`;
}
