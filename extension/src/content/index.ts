import { render, renderError, renderLoading, renderTooLarge } from "../renderer/render";
import type {
  BackgroundError,
  DiffV2,
  GuidResolvedPush,
  PrefetchRequest,
  SemanticDiffRequest,
  SemanticDiffResponse,
} from "../types";
import { type FileEntry, parsePrPage, parsePrUrl, scanUnityFiles } from "./detect";
import { createToggle, type Toggle, type View } from "./toggle";
import { createViewState, type ViewState } from "./viewstate";

const ERROR_TEXT: Record<BackgroundError, string> = {
  "pat-missing": "Sign in with GitHub in the PrefabLens options page.",
  "auth-failed": "GitHub authentication failed. Sign in again in the PrefabLens options page.",
  "rate-limited": "GitHub rate limit exceeded. Wait a while and toggle again.",
  "fetch-failed": "Could not fetch file contents from GitHub.",
  "diff-failed": "Could not compute a semantic diff for this file.",
};

// path → render target. When a push (guidResolved) arrives, merge resolved and re-render
const views = new Map<string, { root: ShadowRoot; json: DiffV2 }>();

function countUnresolved(json: DiffV2): number {
  return json.unresolvedGuids.filter((g) => !Object.hasOwn(json.resolved ?? {}, g)).length;
}

// Targets of the global switch: drives the toggle + display of already-attached files from outside
type Applier = { header: HTMLElement; apply(view: View): void };
const appliers = new Set<Applier>();
let globalToggle: Toggle | undefined;
let currentPr = ""; // overrides are valid only while on the PR: discard when the PR changes
let prefetchedPr = ""; // send prefetch just once across all PR tabs, including the conversation tab

function attach(state: ViewState): void {
  const page = parsePrPage(location.pathname);
  if (!page) return;
  const pageKey = `${page.owner}/${page.repo}#${page.prNumber}`;
  if (pageKey !== prefetchedPr) {
    prefetchedPr = pageKey;
    // fire-and-forget: don't wait on the response, ignore failures (the manual-toggle path is separately alive)
    void (
      chrome.runtime.sendMessage({ type: "prefetch", ...page } satisfies PrefetchRequest) as Promise<unknown>
    ).catch(() => {});
  }
  const pr = parsePrUrl(location.pathname);
  if (!pr) return;
  const key = `${pr.owner}/${pr.repo}#${pr.prNumber}`;
  if (key !== currentPr) {
    currentPr = key;
    state.clearOverrides();
    // Crossing PRs also drops references to dead DOM (prevents a soft leak)
    for (const a of [...appliers]) if (!a.header.isConnected) appliers.delete(a);
    for (const [k, v] of views) if (!v.root.host.isConnected) views.delete(k); // not only ignore late pushes to views killed by navigation, but also cut the reference
  }
  const entries = scanUnityFiles(document);
  if (entries.length) ensureGlobalToggle(state, entries[0]!);
  for (const entry of entries) attachToggle(state, pr, entry);
}

/** Injects exactly one global toggle right before the first Unity file's .file container.
 *  The toolbar DOM changes heavily on GitHub's side, so anchor on the reliably-present .file. */
function ensureGlobalToggle(state: ViewState, first: FileEntry): void {
  if (globalToggle?.element.closest("[data-prefablens-global]")?.isConnected) return;
  const container = first.header.closest(".file");
  if (!container?.parentElement) return;
  const bar = document.createElement("div");
  bar.setAttribute("data-prefablens-global", "");
  const label = document.createElement("span");
  label.className = "prefablens-eyebrow";
  label.textContent = "PrefabLens";
  const toggle = createToggle((view) => state.setDefault(view), state.defaultView());
  bar.append(label, toggle.element);
  container.before(bar);
  globalToggle = toggle;
}

function attachToggle(state: ViewState, pr: { owner: string; repo: string; prNumber: number }, entry: FileEntry): void {
  if (entry.header.hasAttribute("data-prefablens")) return;
  entry.header.setAttribute("data-prefablens", "");
  const viewKey = `${pr.owner}/${pr.repo}#${pr.prNumber}:${entry.path}`;

  let host: HTMLElement | undefined;
  let requested = false;

  const show = (view: View): void => {
    if (view === "raw") {
      entry.content.style.display = "";
      if (host) host.style.display = "none";
      return;
    }
    entry.content.style.display = "none";
    if (!host) {
      host = document.createElement("div");
      host.setAttribute("data-prefablens-view", "");
      host.attachShadow({ mode: "open" });
      entry.content.after(host);
    }
    host.style.display = "";
    if (requested) return; // cache only successful results per file (re-toggle doesn't re-fetch)
    const root = host.shadowRoot!;
    const request = (force?: boolean): void => {
      requested = true;
      renderLoading(root);
      void requestDiff({ type: "semanticDiff", ...pr, path: entry.path, force }).then((res) => {
        if (res.ok) {
          views.set(viewKey, { root, json: res.json });
          // Always show it while pending: even if all names are resolved, source merging may remain
          return render(root, res.json, { resolving: res.pending ? Math.max(countUnresolved(res.json), 1) : 0 });
        }
        requested = false; // don't cache errors: let the next toggle re-fetch
        if (res.error === "too-large") renderTooLarge(root, res.bytes, () => request(true));
        else renderError(root, ERROR_TEXT[res.error]);
      });
    };
    request();
  };

  const toggle = createToggle((view) => {
    state.setOverride(entry.path, view); // a click overrides just this file
    show(view);
  }, state.effective(entry.path));
  entry.header.append(toggle.element);
  appliers.add({
    header: entry.header,
    apply: (view) => {
      toggle.set(view);
      show(view);
    },
  });

  // If the default is semantic, start rendering at attach time: lazy-loaded files also pass through here, so
  // "the global is semantic but a later-arriving file is raw" doesn't happen
  if (state.effective(entry.path) === "semantic") show("semantic");
}

function requestDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse> {
  return (chrome.runtime.sendMessage(req) as Promise<SemanticDiffResponse>).catch(() => ({
    ok: false as const,
    error: "fetch-failed" as const,
  }));
}

async function init(): Promise<void> {
  const stored = await chrome.storage.local.get(["viewMode"]).catch(() => ({}) as Record<string, unknown>);
  const initial: View = stored.viewMode === "semantic" ? "semantic" : "raw";
  const state = createViewState(initial, (view) => void chrome.storage.local.set({ viewMode: view }).catch(() => {}));
  state.onDefaultChange((view) => {
    globalToggle?.set(view);
    for (const a of [...appliers]) {
      if (!a.header.isConnected) {
        appliers.delete(a); // clean up DOM killed by an SPA navigation
        continue;
      }
      a.apply(view);
    }
  });
  // Follow default changes in other tabs (the echo to the originating set tab is ignored inside applyExternal)
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    const next = changes.viewMode?.newValue;
    if (next === "raw" || next === "semantic") state.applyExternal(next);
  });

  // guid resolution push from background (the second stage of the two-stage response): re-render if the matching view exists
  chrome.runtime.onMessage.addListener((msg: GuidResolvedPush) => {
    if (msg?.type !== "guidResolved") return;
    const view = views.get(`${msg.owner}/${msg.repo}#${msg.prNumber}:${msg.path}`);
    if (!view) return; // already navigated to a different PR, etc.: drop silently
    // The final push replaces json (mergeSources may change the structure), an intermediate push merges resolved
    view.json = msg.json ?? { ...view.json, resolved: { ...view.json.resolved, ...msg.resolved } };
    render(view.root, view.json, { resolving: msg.done ? 0 : Math.max(countUnresolved(view.json), 1) });
  });

  // GitHub is an SPA: an initial scan + MutationObserver follows lazy loading and tab navigation (200ms debounce).
  attach(state);
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      attach(state);
    }, 200);
  }).observe(document.body, { childList: true, subtree: true });
}

void init();
