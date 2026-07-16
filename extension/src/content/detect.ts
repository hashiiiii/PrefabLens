import { isUnityPath } from "../unity";

export type FileEntry = {
  path: string;
  header: HTMLElement; // toggle mount point + data-prefablens marker
  attachHost(host: HTMLElement): void; // insert the semantic-view host at the layout's spot
  setRawHidden(hidden: boolean): void; // idempotent, re-resolves live DOM every call
  collapsed(): boolean; // github-level file collapse state (react ui chevron)
  globalAnchor(): Element | null; // element the global bar is inserted before
};

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
function scanClassic(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const header of root.querySelectorAll<HTMLElement>(".file-header[data-path]")) {
    const path = header.dataset.path;
    if (!path || !isUnityPath(path)) continue;
    const container = header.closest(".file");
    const content = container?.querySelector<HTMLElement>(".js-file-content") ?? null;
    if (!content) continue;
    out.push({
      path,
      header,
      attachHost(host) {
        // Same Primer class github puts on .js-file-content: the chevron / Viewed collapse
        // only toggles Details--on on .file, so the host must opt into that CSS itself
        host.classList.add("Details-content--hidden");
        content.after(host);
      },
      setRawHidden(hidden) {
        content.style.display = hidden ? "none" : "";
      },
      collapsed: () => false, // the Details--on CSS contract hides collapsed content without our help
      globalAnchor: () => container,
    });
  }
  return out;
}

const BIDI_MARKS = /[‎‏]/g;

/** The react ui has no path attribute: the path only exists as header text wrapped in
 *  LRM marks, and renames add a visually hidden "OLD renamed to NEW" span. */
function reactPath(header: HTMLElement): string | null {
  const code = header.querySelector('[class*="file-name"] code');
  if (!code) return null;
  const renamed = code.querySelector("span.sr-only")?.textContent?.split(" renamed to ", 2)[1];
  const text = (renamed ?? code.textContent ?? "").replace(BIDI_MARKS, "").trim();
  return text || null;
}

// GitHub's react diff UI (login-gated rollout). Class names are hashed CSS modules, so
// anchors are role/id plus class-prefix matches; the body is "any region child that isn't
// the header block", because its class is unstable and react recreates it constantly.
function scanReact(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const region of root.querySelectorAll<HTMLElement>('div[role="region"][id^="diff-"]')) {
    const header = region.querySelector<HTMLElement>('[class*="diff-file-header"]');
    if (!header) continue;
    const path = reactPath(header);
    if (!path || !isUnityPath(path)) continue;
    // The region child containing the header (normally the diffHeaderWrapper)
    const headerBlock = (): Element => {
      let el: Element = header;
      while (el.parentElement && el.parentElement !== region) el = el.parentElement;
      return el;
    };
    out.push({
      path,
      header,
      attachHost: (host) => headerBlock().after(host),
      setRawHidden(hidden) {
        for (const child of region.children) {
          if (child === headerBlock() || child.hasAttribute("data-prefablens-view")) continue;
          (child as HTMLElement).style.display = hidden ? "none" : "";
        }
      },
      // React swaps the chevron octicon per state; a collapsed file shows chevron-right
      collapsed: () => headerBlock().querySelector(".octicon-chevron-right") !== null,
      globalAnchor: () => region.closest('[data-testid="progressive-diffs-list"]') ?? region.parentElement,
    });
  }
  return out;
}

// Both scanners always run: on any given page one matches and the other yields [] harmlessly,
// so no layout probe is needed (and a mid-rollout A/B flip can't strand us).
export function scanUnityFiles(root: ParentNode): FileEntry[] {
  return [...scanClassic(root), ...scanReact(root)];
}
