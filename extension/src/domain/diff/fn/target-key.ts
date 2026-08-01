import type { DiffTarget } from "../types";

// Stable identity within a repo — context caches and view keys derive from it.
export function targetKey(owner: string, repo: string, target: DiffTarget): string {
  const suffix =
    target.kind === "pull"
      ? `#${target.prNumber}`
      : target.kind === "commit"
        ? `@${target.sha}`
        : `@${target.base}...${target.head}`;
  return `${owner}/${repo}${suffix}`;
}
