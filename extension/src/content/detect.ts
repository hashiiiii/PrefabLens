import { isUnityPath } from "../unity";

export type FileEntry = { path: string; header: HTMLElement; content: HTMLElement };

export function parsePrUrl(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  // files: any suffix (ranges render inline). changes (react ui): bare tab or A..B range only —
  // a single sha under /changes/ is the commit view, which this extension does not handle yet.
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/(?:files(?:\/|$)|changes(?:\/[\da-f]{7,40}\.\.[\da-f]{7,40})?\/?$)/.exec(
    pathname,
  );
  return m ? { owner: m[1]!, repo: m[2]!, prNumber: Number(m[3]!) } : null;
}

/** Matches any PR tab (the prefetch trigger). Different role from the files-only parsePrUrl. */
export function parsePrPage(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)(\/|$)/.exec(pathname);
  return m ? { owner: m[1]!, repo: m[2]!, prNumber: Number(m[3]!) } : null;
}

// Defensively searches GitHub's Files changed (classic DOM). If it doesn't match, ends harmlessly with an empty array.
export function scanUnityFiles(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const header of root.querySelectorAll<HTMLElement>(".file-header[data-path]")) {
    const path = header.dataset.path;
    if (!path || !isUnityPath(path)) continue;
    const container = header.closest(".file");
    const content = container?.querySelector<HTMLElement>(".js-file-content") ?? null;
    if (!content) continue;
    out.push({ path, header, content });
  }
  return out;
}
