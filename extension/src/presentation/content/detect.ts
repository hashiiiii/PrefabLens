import type { DiffTarget } from "../../domain/diff/types";
import { isUnityPath } from "../../domain/unity/fn/is-unity-path";
import { must } from "../../internal/must";

export type FileEntry = {
  path: string;
  header: HTMLElement; // toggle mount + data-prefablens marker
  attachHost(host: HTMLElement): void; // insert semantic host at the layout's spot
  setRawHidden(hidden: boolean): void; // idempotent; re-resolves live DOM each call
  collapsed(): boolean; // github file collapse (react chevron)
  globalAnchor(): Element | null; // element the global bar inserts before
};

export type DiffPage = { owner: string; repo: string; target: DiffTarget };

// Tolerate bare % in pathnames — throwing here would kill the whole page scan
function decodeRef(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

// Diff pages we can serve. Compare is same-repo three-dot only (fork owner:branch needs a second repo).
export function parseDiffUrl(pathname: string): DiffPage | null {
  // files: any suffix. changes (react): bare tab or A..B range only.
  const pr =
    /^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/(?:files(?:\/|$)|changes(?:\/[\da-f]{7,40}\.\.[\da-f]{7,40})?\/?$)/.exec(
      pathname,
    );
  if (pr) return { owner: must(pr[1]), repo: must(pr[2]), target: { kind: "pull", prNumber: Number(must(pr[3])) } };
  // /commit/SHA, classic /commits/SHA, react /changes/SHA — one commit vs parent
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

// Any PR tab (prefetch trigger); unlike parseDiffUrl this is not diff-page-only
export function parsePrPage(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)(\/|$)/.exec(pathname);
  return m ? { owner: must(m[1]), repo: must(m[2]), prNumber: Number(must(m[3])) } : null;
}

// Classic Files changed DOM; no match → empty array
function scanClassic(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const header of root.querySelectorAll<HTMLElement>(".file-header[data-path]")) {
    // Marked = already wired; its appliers keep serving it, so skip the rebuild
    if (header.hasAttribute("data-prefablens")) continue;
    const path = header.dataset.path;
    if (!path || !isUnityPath(path)) continue;
    const container = header.closest(".file");
    const content = container?.querySelector<HTMLElement>(".js-file-content") ?? null;
    if (!content) continue;
    out.push({
      path,
      header,
      attachHost(host) {
        // Opt into Details--on CSS the way .js-file-content does
        host.classList.add("Details-content--hidden");
        content.after(host);
      },
      setRawHidden(hidden) {
        content.style.display = hidden ? "none" : "";
      },
      collapsed: () => false, // Details--on CSS hides collapsed content without our help
      globalAnchor: () => container,
    });
  }
  return out;
}

const BIDI_MARKS = /[‎‏]/g;

// React has no path attribute: header text (+ LRM marks); renames hide "OLD renamed to NEW"
function filePathFromReactHeader(header: HTMLElement): string | null {
  const code = header.querySelector('[class*="file-name"] code');
  if (!code) return null;
  const renamed = code.querySelector("span.sr-only")?.textContent?.split(" renamed to ", 2)[1];
  const text = (renamed ?? code.textContent ?? "").replace(BIDI_MARKS, "").trim();
  return text || null;
}

// React remounts strip inline styles; debounced rescan is ~200ms late and flashes raw.
// Document rule keyed on setRawHidden's marker hides a fresh body before first paint.
// Targets the body's own classes, not "everything but the header": drift degrades to a flash, never a hidden header.
function ensureReactRawHideStyle(doc: Document): void {
  if (doc.head.querySelector("style[data-prefablens-hide-rule]")) return;
  const style = doc.createElement("style");
  style.setAttribute("data-prefablens-hide-rule", "");
  style.textContent = "[data-prefablens-raw-hidden] > .border.rounded-bottom-2 { display: none !important; }";
  doc.head.append(style);
}

// React diff UI: hashed CSS modules → role/id + class-prefix anchors; body class is unstable
function scanReact(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const region of root.querySelectorAll<HTMLElement>('div[role="region"][id^="diff-"]')) {
    const header = region.querySelector<HTMLElement>('[class*="diff-file-header"]');
    // Marked = already wired: skip before the header text walk — this loop runs
    // on every mutation tick over every diff region, Unity or not
    if (!header || header.hasAttribute("data-prefablens")) continue;
    const path = filePathFromReactHeader(header);
    if (!path || !isUnityPath(path)) continue;
    // Region child that contains the header (normally diffHeaderWrapper)
    const headerBlock = (): Element => {
      let el: Element = header;
      while (el.parentElement && el.parentElement !== region) el = el.parentElement;
      return el;
    };
    out.push({
      path,
      header,
      attachHost(host) {
        // Card frame lives on the body here; recreate chrome on the host when body is hidden
        host.style.cssText =
          "border: 1px solid var(--borderColor-default, #d1d9e0); border-radius: 0 0 6px 6px; background: var(--bgColor-default, #ffffff);";
        headerBlock().after(host);
      },
      setRawHidden(hidden) {
        region.toggleAttribute("data-prefablens-raw-hidden", hidden);
        if (hidden) ensureReactRawHideStyle(region.ownerDocument);
        // Inline fallback for markup the CSS rule misses. Resolve the block once
        // per call (not per child) — React can reparent between calls, not during one.
        const block = headerBlock();
        for (const child of region.children) {
          if (child === block || child.hasAttribute("data-prefablens-view")) continue;
          (child as HTMLElement).style.display = hidden ? "none" : "";
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
      globalAnchor: () => region.closest('[data-testid="progressive-diffs-list"]') ?? region.parentElement,
    });
  }
  return out;
}

// Always run both: one matches, the other yields []; no layout probe (survives A/B flips).
// Returns only headers not yet marked data-prefablens — attached files stay served
// by their existing appliers.
export function scanUnityFiles(root: ParentNode): FileEntry[] {
  return [...scanClassic(root), ...scanReact(root)];
}
