import { isUnityPath } from "../unity";

export type FileEntry = { path: string; header: HTMLElement; content: HTMLElement };

export function parsePrUrl(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/files(\/|$)/.exec(pathname);
  return m ? { owner: m[1]!, repo: m[2]!, prNumber: Number(m[3]!) } : null;
}

/** PR のどのタブでもマッチする(プリフェッチ起点)。files 限定の parsePrUrl とは役割が違う。 */
export function parsePrPage(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)(\/|$)/.exec(pathname);
  return m ? { owner: m[1]!, repo: m[2]!, prNumber: Number(m[3]!) } : null;
}

// GitHub の Files changed(クラシック DOM)を防御的に探す。合わなければ空配列で無害に終わる。
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
