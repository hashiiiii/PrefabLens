import { getPendingSignIn } from "../../application/auth/get-pending-sign-in";
import { type SignInState, signIn } from "../../application/auth/sign-in";
import { requestPrefetch } from "../../application/diff/request-prefetch";
import { requestSemanticDiff } from "../../application/diff/request-semantic-diff";
import { type BackgroundError, type GuidResolvedPush, targetKey, unresolvedRemaining } from "../../domain/diff/types";
import { must } from "../../domain/must";
import { createContentDeps } from "../../infrastructure/container";
import {
  render,
  renderError,
  renderLoading,
  renderSignIn,
  renderSignInPending,
  renderTooLarge,
} from "../renderer/render";
import { type DiffPage, type FileEntry, parseDiffUrl, parsePrPage, scanUnityFiles } from "./detect";
import { fillDeviceCode } from "./device-page";
import { createAuthRetries } from "./overlay/auth-retries";
import { createFileView } from "./overlay/file-view";
import type { View } from "./overlay/view-mode";
import { createViewState, type ViewState } from "./overlay/view-state";
import { createViewRegistry, type ViewEntry } from "./overlay/views";
import { createToggle, type Toggle } from "./toggle";

const ERROR_TEXT: Record<BackgroundError, string> = {
  "access-token-missing": "Sign in with GitHub to view semantic diffs.",
  "auth-failed": "GitHub authentication failed. Sign in again.",
  "rate-limited": "GitHub rate limit exceeded. Wait a while and toggle again.",
  "fetch-failed": "Could not fetch file contents from GitHub.",
  "diff-failed": "Could not compute a semantic diff for this file.",
  "not-unity-yaml": "This file is not a text-serialized Unity asset.",
};

// path → render target for guidResolved pushes
const views = createViewRegistry();

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
const authRetries = createAuthRetries();

const { messenger, tokenStore, signInDeps } = createContentDeps();
const signInState: SignInState = { inFlight: false };

// Auth-error panel: device flow; failures land back here for retry
function signInPanel(root: ShadowRoot, message: string): void {
  renderSignIn(root, message, () => {
    void signIn(signInDeps, signInState, {
      showPending: (userCode, verificationUri) =>
        renderSignInPending(root, userCode, verificationUri, () => void navigator.clipboard.writeText(userCode)),
      showFailure: (text) => signInPanel(root, text),
    });
  });
}

function attach(viewState: ViewState): void {
  const prPage = parsePrPage(location.pathname);
  if (prPage) {
    const prKey = targetKey(prPage.owner, prPage.repo, { kind: "pull", prNumber: prPage.prNumber });
    if (prKey !== prefetchedPr) {
      prefetchedPr = prKey;
      // Fire-and-forget; manual toggle stays available if prefetch fails
      void requestPrefetch(messenger, { type: "prefetch", ...prPage });
    }
  }
  const page = parseDiffUrl(location.pathname);
  if (!page) return;
  const key = targetKey(page.owner, page.repo, page.target);
  if (key !== currentPage) {
    currentPage = key;
    viewState.clearOverrides();
    views.pruneDisconnected(); // drop refs so late pushes can't revive dead views
  }
  // React virtualizes and discards off-screen DOM; prune every scan (also plugs classic soft leak)
  for (const a of [...appliers]) if (!a.header.isConnected) appliers.delete(a);
  const entries = scanUnityFiles(document);
  const first = entries[0];
  if (first) ensureGlobalToggle(viewState, first);
  for (const entry of entries) attachToggle(viewState, page, entry);
  // React remounts can undo inline hide under still-marked headers; sync is idempotent/fetch-free
  for (const a of appliers) a.sync();
}

// Global bar must sit outside recycled react list items (classic: before .file; react: list root)
function ensureGlobalToggle(viewState: ViewState, first: FileEntry): void {
  if (globalToggle?.element.closest("[data-prefablens-global]")?.isConnected) return;
  const anchor = first.globalAnchor();
  if (!anchor?.parentElement) return;
  const bar = document.createElement("div");
  bar.setAttribute("data-prefablens-global", "");
  const label = document.createElement("span");
  label.className = "prefablens-eyebrow";
  label.textContent = "PrefabLens";
  const toggle = createToggle((view) => viewState.setDefault(view), viewState.defaultView());
  bar.append(label, toggle.element);
  anchor.before(bar);
  globalToggle = toggle;
}

function attachToggle(viewState: ViewState, page: DiffPage, entry: FileEntry): void {
  if (entry.header.hasAttribute("data-prefablens")) return;
  entry.header.setAttribute("data-prefablens", "");
  const viewKey = `${targetKey(page.owner, page.repo, page.target)}:${entry.path}`;

  // Set by createHost before results.set so the push listener always has a real shadow root
  let shadow: ShadowRoot | undefined;

  // Transitions live in fileView.ts; here we bind them to DOM, runtime, and registries
  const fileView = createFileView({
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
    requestDiff: (force) =>
      requestSemanticDiff(messenger, {
        type: "semanticDiff",
        owner: page.owner,
        repo: page.repo,
        target: page.target,
        path: entry.path,
        force,
      }),
    results: {
      set: ({ json, retry }) => views.set(viewKey, { root: must(shadow), json, retry }),
      get: () => views.get(viewKey),
      armWatchdog: () => armWatchdog(must(views.get(viewKey))),
    },
    onAuthRetry: (retry) => authRetries.add(retry),
    effectiveView: () => viewState.effective(entry.path),
  });

  const toggle = createToggle((view) => {
    viewState.setOverride(entry.path, view); // per-file override
    fileView.show(view);
  }, viewState.effective(entry.path));
  entry.header.append(toggle.element);
  appliers.add({
    header: entry.header,
    apply: (view) => {
      toggle.set(view);
      fileView.show(view);
    },
    sync: () => fileView.sync(viewState.effective(entry.path)),
  });

  // Start semantic at attach so late-arriving files inherit a semantic global default
  if (viewState.effective(entry.path) === "semantic") fileView.show("semantic");
}

async function init(): Promise<void> {
  // Device page: only pre-fill the code the PR page issued
  if (location.pathname === "/login/device") {
    const pending = await getPendingSignIn(tokenStore);
    if (pending) fillDeviceCode(document, pending, Date.now());
    return;
  }

  const stored = await chrome.storage.local.get(["viewMode"]).catch(() => ({}) as Record<string, unknown>);
  const initial: View = stored.viewMode === "semantic" ? "semantic" : "raw";
  const viewState = createViewState(
    initial,
    (view) => void chrome.storage.local.set({ viewMode: view }).catch(() => {}),
  );
  viewState.onDefaultChange((view) => {
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
    if (next === "raw" || next === "semantic") viewState.applyExternal(next);
    if (typeof changes.accessToken?.newValue === "string" && changes.accessToken.newValue) {
      // Token landed (this tab or elsewhere): retry every auth-blocked panel
      authRetries.flush();
    }
  });

  // guidResolved: second-stage push from background; re-render if this view still exists
  chrome.runtime.onMessage.addListener((msg: GuidResolvedPush) => {
    if (msg?.type !== "guidResolved") return;
    const view = views.get(`${targetKey(msg.owner, msg.repo, msg.target)}:${msg.path}`);
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
