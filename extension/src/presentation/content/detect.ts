import type { DiffTarget } from "../../domain/diff/types";
import { isUnityPath } from "../../domain/unity/fn/is-unity-path";
import { must } from "../../internal/must";

export type FileEntry = {
  path: string;
  header: HTMLElement;
  attachHost(host: HTMLElement): void;
  setRawHidden(hidden: boolean): void; // idempotent: re-resolves the live DOM on each call
  collapsed(): boolean; // github file collapse (react chevron)
};

export type DiffPage = { owner: string; repo: string; target: DiffTarget };

// A bare % in a path must not stop the entire page scan.
function decodeRef(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

const BIDI_MARKS = /[‎‏]/g;
const REACT_LIST_SELECTOR = '[data-testid="virtualized-diffs-list"], [data-testid="progressive-diffs-list"]';

function classicGlobalAnchor(root: ParentNode, fallback: Element): Element {
  const firstFile = root.querySelector<HTMLElement>(".file-header[data-path]")?.closest(".file");
  if (!firstFile) return fallback;
  const list = firstFile.closest(".js-diff-progressive-container");
  if (!list) return firstFile;

  let anchor: Element = firstFile;
  while (anchor.parentElement && anchor.parentElement !== list) anchor = anchor.parentElement;
  return anchor;
}

export function findGlobalAnchor(root: ParentNode): Element | null {
  const classicUnity = [...root.querySelectorAll<HTMLElement>(".file-header[data-path]")].find((header) => {
    const path = header.dataset.path;
    return path !== undefined && isUnityPath(path);
  });
  const classicFile = classicUnity?.closest(".file");
  if (classicFile) return classicGlobalAnchor(root, classicFile);

  const reactList = root.querySelector(REACT_LIST_SELECTOR);
  if (!reactList) return null;
  const hasUnity = [...root.querySelectorAll<HTMLAnchorElement>('a[href^="#diff-"]')].some((link) => {
    const path = (link.querySelector("code")?.textContent ?? link.textContent ?? "").replace(BIDI_MARKS, "").trim();
    return isUnityPath(path);
  });
  return hasUnity ? reactList : null;
}

// Diff pages we can serve. Compare is same-repo three-dot only (fork owner:branch needs a second repo).
export function parseDiffUrl(pathname: string): DiffPage | null {
  // files: any suffix. changes (react): bare tab or A..B range only.
  const pr =
    /^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/(?:files(?:\/|$)|changes(?:\/[\da-f]{7,40}\.\.[\da-f]{7,40})?\/?$)/.exec(
      pathname,
    );
  if (pr) return { owner: must(pr[1]), repo: must(pr[2]), target: { kind: "pull", prNumber: Number(must(pr[3])) } };
  // /commit/SHA, classic /commits/SHA, react /changes/SHA: one commit vs parent
  const commit = /^\/([^/]+)\/([^/]+)\/(?:pull\/\d+\/(?:commits|changes)|commit)\/([\da-f]{7,40})\/?$/.exec(pathname);
  if (commit)
    return { owner: must(commit[1]), repo: must(commit[2]), target: { kind: "commit", sha: must(commit[3]) } };
  const compare = /^\/([^/]+)\/([^/]+)\/compare\/(.+?)\.\.\.(.+?)\/?$/.exec(pathname);
  if (compare) {
    const base = decodeRef(must(compare[3]));
    const head = decodeRef(must(compare[4]));
    if (base.includes(":") || head.includes(":")) return null;
    return { owner: must(compare[1]), repo: must(compare[2]), target: { kind: "compare", base, head } };
  }
  return null;
}

// Any PR tab (prefetch trigger). Unlike parseDiffUrl, this is not diff-page-only.
export function parsePrPage(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)(\/|$)/.exec(pathname);
  return m ? { owner: must(m[1]), repo: must(m[2]), prNumber: Number(must(m[3])) } : null;
}

// Classic Files changed DOM. When nothing matches, the scan returns an empty array.
function scanClassic(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const header of root.querySelectorAll<HTMLElement>(".file-header[data-path]")) {
    // Marked headers already have active handlers, so rebuilding them would duplicate those handlers.
    if (header.hasAttribute("data-prefablens")) continue;
    const path = header.dataset.path;
    if (!path || !isUnityPath(path)) continue;
    const container = header.closest(".file");
    const content = container?.querySelector<HTMLElement>(".js-file-content") ?? null;
    if (!container || !content) continue;
    out.push({
      path,
      header,
      attachHost(host) {
        // The semantic host must collapse with GitHub's raw content.
        host.classList.add("Details-content--hidden");
        content.after(host);
      },
      setRawHidden(hidden) {
        content.style.display = hidden ? "none" : "";
      },
      collapsed: () => false, // Details--on CSS hides collapsed content without our help
    });
  }
  return out;
}

// React stores paths in header text with direction marks. Renamed files include hidden "OLD renamed to NEW" text.
function filePathFromReactHeader(header: HTMLElement): string | null {
  const code = header.querySelector('[class*="file-name"] code');
  if (!code) return null;
  const renamed = code.querySelector("span.sr-only")?.textContent?.split(" renamed to ", 2)[1];
  const text = (renamed ?? code.textContent ?? "").replace(BIDI_MARKS, "").trim();
  return text || null;
}

// React remounts discard inline styles. A document rule tied to the raw-hidden marker hides replacement bodies before the next scan.
// Match the body's classes so CSS changes cannot accidentally hide the header.
function ensureReactRawHideStyle(doc: Document): void {
  if (doc.head.querySelector("style[data-prefablens-hide-rule]")) return;
  const style = doc.createElement("style");
  style.setAttribute("data-prefablens-hide-rule", "");
  style.textContent = "[data-prefablens-raw-hidden] > .border.rounded-bottom-2 { display: none !important; }";
  doc.head.append(style);
}

// React diff UI: hashed CSS modules force role/id and class-prefix anchors. The body class is unstable.
function scanReact(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const region of root.querySelectorAll<HTMLElement>('div[role="region"][id^="diff-"]')) {
    const header = region.querySelector<HTMLElement>('[class*="diff-file-header"]');
    // Every DOM mutation scans all diff regions. Skip attached headers before walking their text again.
    if (!header || header.hasAttribute("data-prefablens")) continue;
    const path = filePathFromReactHeader(header);
    if (!path || !isUnityPath(path)) continue;
    const headerBlock = (): Element => {
      let el: Element = header;
      while (el.parentElement && el.parentElement !== region) el = el.parentElement;
      return el;
    };
    out.push({
      path,
      header,
      attachHost(host) {
        // Hiding the raw body also hides its border and background, so the semantic host needs the same frame.
        host.style.cssText =
          "border: 1px solid var(--borderColor-default, #d1d9e0); border-radius: 0 0 6px 6px; background: var(--bgColor-default, #ffffff);";
        headerBlock().after(host);
      },
      setRawHidden(hidden) {
        region.toggleAttribute("data-prefablens-raw-hidden", hidden);
        if (hidden) ensureReactRawHideStyle(region.ownerDocument);
        // Inline styles cover markup missed by the CSS rule.
        // React can reparent the header between calls, so each call must locate its current block.
        const block = headerBlock();
        for (const child of region.children) {
          if (child === block || child.hasAttribute("data-prefablens-view")) continue;
          if (child instanceof HTMLElement) child.style.display = hidden ? "none" : "";
        }
      },
      // Chevron octicon swap + DiffFileHeader-module__collapsed class
      collapsed: () => {
        const block = headerBlock();
        return (
          block.querySelector(".octicon-chevron-right") !== null ||
          block.querySelector('[class*="DiffFileHeader-module__collapsed"]') !== null
        );
      },
    });
  }
  return out;
}

// Run both scans so switching GitHub layouts does not disable detection.
// Marked headers keep their existing handlers; only unattached files are returned.
export function scanUnityFiles(root: ParentNode): FileEntry[] {
  return [...scanClassic(root), ...scanReact(root)];
}
