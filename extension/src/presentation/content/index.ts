import { signIn } from "../../application/auth/sign-in";
import { createGithubAuth, createMessenger, createTokenStore } from "../../container";
import { targetKey } from "../../domain/diff/fn/target-key";
import { unresolvedRemaining } from "../../domain/diff/fn/unresolved-remaining";
import type { BackgroundError, GuidResolvedPush } from "../../domain/diff/types";
import { must } from "../../internal/must";
import {
  render,
  renderError,
  renderLoading,
  renderSignIn,
  renderSignInPending,
  renderTooLarge,
} from "../internal/render";
import { type DiffPage, type FileEntry, parseDiffUrl, parsePrPage, scanUnityFiles } from "./detect";
import { fillDeviceCode } from "./device-page";
import { addAuthRetry, emptyAuthRetries, flushAuthRetries } from "./overlay/auth-retries";
import { emptyFileView, type FileViewDeps, showFileView, syncFileView } from "./overlay/file-view";
import type { View } from "./overlay/view-mode";
import {
  applyExternal,
  clearOverrides,
  defaultView,
  effectiveView,
  emptyViewState,
  onDefaultChange,
  setDefault,
  setOverride,
  type ViewStateData,
} from "./overlay/view-state";
import { emptyViewRegistry, getView, pruneDisconnectedViews, setView, type ViewEntry } from "./overlay/views";
import { mountToggle, type Toggle } from "./toggle";

const ERROR_TEXT: Record<BackgroundError, string> = {
  "access-token-missing": "Sign in with GitHub to view semantic diffs.",
  "auth-failed": "GitHub authentication failed. Sign in again.",
  "rate-limited": "GitHub rate limit exceeded. Wait a while and toggle again.",
  "fetch-failed": "Could not fetch file contents from GitHub.",
  "diff-failed": "Could not compute a semantic diff for this file.",
  "not-unity-yaml": "This file is not a text-serialized Unity asset.",
};

// path → render target for guidResolved pushes
const views = emptyViewRegistry();

// Lost final push → flip to retryable incomplete instead of spinning forever
const WATCHDOG_MS = 120_000;

function armWatchdog(view: ViewEntry): void {
  clearTimeout(view.watchdog);
  view.watchdog = window.setTimeout(
    () => render(view.root, view.json, { incomplete: { onRetry: view.retry } }),
    WATCHDOG_MS,
  );
}

// Global switch targets: toggle + display for already-attached files
type Applier = { header: HTMLElement; apply(view: View): void; sync(): void };
const appliers = new Set<Applier>();
let globalToggle: Toggle | undefined;
let currentPage = ""; // drop overrides when leaving this diff page
let prefetchedPr = ""; // prefetch once per PR across conversation + files tabs

// Auth-blocked panels: retry all when a token lands
const authRetries = emptyAuthRetries();

const messenger = createMessenger();
const tokenStore = createTokenStore();
const auth = createGithubAuth();
const signInState = { inFlight: false };
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const openTab = (url: string) => void window.open(url, "_blank", "noopener");
const now = () => Date.now();

const persistView = (view: View): void => {
  void chrome.storage.local.set({ viewMode: view }).catch(() => {});
};

// Auth-error panel: device flow; failures land back here for retry
function signInPanel(root: ShadowRoot, message: string): void {
  renderSignIn(root, message, () => {
    void signIn(auth, tokenStore, fetch, sleep, openTab, now, signInState, {
      showPending: (userCode, verificationUri) =>
        renderSignInPending(root, userCode, verificationUri, () => void navigator.clipboard.writeText(userCode)),
      showFailure: (text) => signInPanel(root, text),
    });
  });
}

function attach(viewState: ViewStateData): void {
  const prPage = parsePrPage(location.pathname);
  if (prPage) {
    const prKey = targetKey(prPage.owner, prPage.repo, { kind: "pull", prNumber: prPage.prNumber });
    if (prKey !== prefetchedPr) {
      prefetchedPr = prKey;
      // Fire-and-forget; manual toggle stays available if prefetch fails
      void messenger.prefetch({ type: "prefetch", ...prPage }).catch(() => {});
    }
  }
  const page = parseDiffUrl(location.pathname);
  if (!page) return;
  const key = targetKey(page.owner, page.repo, page.target);
  if (key !== currentPage) {
    currentPage = key;
    clearOverrides(viewState);
  }
  // React virtualizes and discards off-screen DOM, so prune both registries on every
  // scan. This drops the DiffV2 and shadow root that a dead view pins, and it also
  // plugs the classic soft leak.
  pruneDisconnectedViews(views);
  for (const a of [...appliers]) if (!a.header.isConnected) appliers.delete(a);
  const entries = scanUnityFiles(document);
  const first = entries[0];
  if (first) ensureGlobalToggle(viewState, first);
  for (const entry of entries) attachToggle(viewState, page, entry);
  // React remounts can undo inline hide under still-marked headers; sync is idempotent/fetch-free
  for (const a of appliers) a.sync();
}

// Global bar must sit outside recycled react list items (classic: before .file; react: list root)
function ensureGlobalToggle(viewState: ViewStateData, first: FileEntry): void {
  if (globalToggle?.element.closest("[data-prefablens-global]")?.isConnected) return;
  const anchor = first.globalAnchor();
  if (!anchor?.parentElement) return;
  const bar = document.createElement("div");
  bar.setAttribute("data-prefablens-global", "");
  const label = document.createElement("span");
  label.className = "prefablens-eyebrow";
  label.textContent = "PrefabLens";
  const toggle = mountToggle((view) => setDefault(viewState, view, persistView), defaultView(viewState));
  bar.append(label, toggle.element);
  anchor.before(bar);
  globalToggle = toggle;
}

function attachToggle(viewState: ViewStateData, page: DiffPage, entry: FileEntry): void {
  if (entry.header.hasAttribute("data-prefablens")) return;
  entry.header.setAttribute("data-prefablens", "");
  const viewKey = `${targetKey(page.owner, page.repo, page.target)}:${entry.path}`;

  // Set by createHost before results.set so the push listener always has a real shadow root
  let shadow: ShadowRoot | undefined;

  // Transitions live in file-view.ts; here we bind them to DOM, runtime, and registries
  const fileState = emptyFileView();
  const fileDeps: FileViewDeps = {
    file: entry,
    createHost() {
      const host = document.createElement("div");
      host.setAttribute("data-prefablens-view", "");
      const root = host.attachShadow({ mode: "open" });
      shadow = root;
      return {
        attach: () => entry.attachHost(host),
        attached: () => host.isConnected,
        setVisible: (visible) => {
          host.style.display = visible ? "" : "none";
        },
        panel: {
          loading: () => renderLoading(root),
          diff: (json, resolving) => render(root, json, { resolving }),
          incomplete: (json, onRetry) => render(root, json, { incomplete: { onRetry } }),
          tooLarge: (bytes, onForce) => renderTooLarge(root, bytes, onForce),
          authError: (error) => signInPanel(root, ERROR_TEXT[error]),
          error: (error) => renderError(root, ERROR_TEXT[error]),
        },
      };
    },
    // Channel loss (SW restart, teardown) → fetch-failed; callers never see a rejection
    requestDiff: (force) =>
      messenger
        .semanticDiff({
          type: "semanticDiff",
          owner: page.owner,
          repo: page.repo,
          target: page.target,
          path: entry.path,
          force,
        })
        .catch(() => ({ ok: false as const, error: "fetch-failed" as const })),
    results: {
      set: ({ json, retry }) => setView(views, viewKey, { root: must(shadow), json, retry }),
      get: () => getView(views, viewKey),
      armWatchdog: () => armWatchdog(must(getView(views, viewKey))),
    },
    onAuthRetry: (retry) => addAuthRetry(authRetries, retry),
    effectiveView: () => effectiveView(viewState, entry.path),
  };

  const toggle = mountToggle(
    (view) => {
      setOverride(viewState, entry.path, view); // per-file override
      showFileView(fileState, fileDeps, view);
    },
    effectiveView(viewState, entry.path),
  );
  entry.header.append(toggle.element);
  appliers.add({
    header: entry.header,
    apply: (view) => {
      toggle.set(view);
      showFileView(fileState, fileDeps, view);
    },
    sync: () => syncFileView(fileState, fileDeps, effectiveView(viewState, entry.path)),
  });

  // Start semantic at attach so late-arriving files inherit a semantic global default
  if (effectiveView(viewState, entry.path) === "semantic") showFileView(fileState, fileDeps, "semantic");
}

async function init(): Promise<void> {
  // Device-page pre-fill: only the code this browser's PR page issued; storage
  // failure degrades to no pre-fill (the user pastes the code instead)
  if (location.pathname === "/login/device") {
    const pending = await tokenStore.readPendingSignIn().catch(() => undefined);
    if (pending) fillDeviceCode(document, pending, Date.now());
    return;
  }

  const stored = await chrome.storage.local.get(["viewMode"]).catch(() => ({}) as Record<string, unknown>);
  const initial: View = stored.viewMode === "semantic" ? "semantic" : "raw";
  const viewState = emptyViewState(initial);
  onDefaultChange(viewState, (view) => {
    globalToggle?.set(view);
    for (const a of [...appliers]) {
      if (!a.header.isConnected) {
        appliers.delete(a); // SPA navigation may have killed the DOM
        continue;
      }
      a.apply(view);
    }
  });
  // Cross-tab default sync; applyExternal ignores the originating tab's echo
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    const next = changes.viewMode?.newValue;
    if (next === "raw" || next === "semantic") applyExternal(viewState, next);
    if (typeof changes.accessToken?.newValue === "string" && changes.accessToken.newValue) {
      // Token landed (this tab or elsewhere): retry every auth-blocked panel
      flushAuthRetries(authRetries);
    }
  });

  // guidResolved: second-stage push from background; re-render if this view still exists
  chrome.runtime.onMessage.addListener((msg: GuidResolvedPush) => {
    if (msg?.type !== "guidResolved") return;
    const view = getView(views, `${targetKey(msg.owner, msg.repo, msg.target)}:${msg.path}`);
    if (!view) return; // navigated away: drop silently
    clearTimeout(view.watchdog);
    // Final push replaces json (mergeSources can reshape); intermediate merges resolved
    view.json = msg.json ?? { ...view.json, resolved: { ...view.json.resolved, ...msg.resolved } };
    if (msg.done && msg.status !== undefined && msg.status !== "complete") {
      // Gave up: keep arrived names, offer manual retry (#194)
      render(view.root, view.json, { incomplete: { onRetry: view.retry } });
      return;
    }
    if (!msg.done) armWatchdog(view);
    render(view.root, view.json, { resolving: msg.done ? 0 : Math.max(unresolvedRemaining(view.json).length, 1) });
  });

  // SPA: MutationObserver + 50ms debounce follows lazy loads without feeling sluggish
  // (~100ms threshold); scans are fetch-free/~0.75ms so storms stay cheap.
  attach(viewState);
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      attach(viewState);
    }, 50);
  }).observe(document.body, { childList: true, subtree: true });
}

void init();
