import { type SignInFailure, signIn } from "../../application/auth/sign-in";
import { createGithubAuth, createMessenger, createTokenStore } from "../../container";
import { targetKey } from "../../domain/diff/fn/target-key";
import type { AuthError, GuidResolvedPush } from "../../domain/diff/types";
import { renderSignIn, renderSignInPending } from "../internal/render";
import { mountGlobalBar, type Toggle } from "../internal/toggle";
import type { View } from "../internal/view-mode";
import {
  applyExternal,
  clearOverrides,
  emptyViewState,
  onDefaultChange,
  setDefault,
  type ViewStateData,
} from "../internal/view-state";
import { type FileEntry, parseDiffUrl, parsePrPage, scanUnityFiles } from "./detect";
import { fillDeviceCode } from "./device-page";
import { flushAuthRetries } from "./overlay/auth-retries";
import { attachFileView, type FileView } from "./overlay/file-view";
import { applyGuidResolvedPush, pruneDisconnectedViews, type ViewRegistry, viewKey } from "./overlay/views";

const ERROR_TEXT: Record<AuthError, string> = {
  "access-token-missing": "Please sign in with GitHub to view semantic diffs.",
  "auth-failed": "GitHub authentication did not work. Please sign in again.",
};

const SIGN_IN_FAILURE_TEXT: Record<SignInFailure, string> = {
  denied: "Authorization was denied. Please try again.",
  expired: "The code expired. Please try again.",
  failed: "Sign-in did not work. Please try again.",
};

const views: ViewRegistry = new Map();

const appliers = new Set<FileView>();
let globalToggle: Toggle | undefined;
let currentPage = ""; // drop overrides when leaving this diff page
let prefetchedPr = ""; // prefetch once per PR across conversation + files tabs

// SPA navigation can remove the DOM behind an applier.
function liveAppliers(): Set<FileView> {
  for (const a of appliers) if (!a.header.isConnected) appliers.delete(a);
  return appliers;
}

// Auth-blocked panels: retry all when a token lands
const authRetries = new Set<() => void>();

const messenger = createMessenger();
const tokenStore = createTokenStore();
const auth = createGithubAuth();
const signInState = { inFlight: false };
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
// _blank: Open in a new tab
// noopener: Prevent the opened tab from accessing the original tab
const openTab = (url: string) => void window.open(url, "_blank", "noopener");
const now = () => Date.now();

const persistView = async (view: View): Promise<void> => {
  try {
    await chrome.storage.local.set({ viewMode: view });
  } catch {
    // A storage failure must not disable the current page.
  }
};

// Auth-error panel: device flow. Failures land back here for retry.
async function signInPanel(root: ShadowRoot, message: string): Promise<void> {
  await renderSignIn(root, message);
  for await (const event of signIn(auth, tokenStore, fetch, sleep, now, signInState)) {
    if (event.status === "pending") {
      renderSignInPending(root, event.userCode, event.verificationUri);
      openTab(event.verificationUri);
    } else if (event.status === "failed") {
      await signInPanel(root, SIGN_IN_FAILURE_TEXT[event.reason]);
      return;
    }
    // ok: accessToken storage.onChanged retries auth-blocked panels
  }
}

function attach(viewState: ViewStateData): void {
  const prPage = parsePrPage(location.pathname);
  if (prPage) {
    const prKey = targetKey(prPage.owner, prPage.repo, { kind: "pull", prNumber: prPage.prNumber });
    if (prKey !== prefetchedPr) {
      prefetchedPr = prKey;
      // Fire-and-forget. If prefetch fails, the manual toggle stays available.
      void messenger.prefetch({ type: "prefetch", ...prPage });
    }
  }
  const page = parseDiffUrl(location.pathname);
  if (!page) return;
  const key = targetKey(page.owner, page.repo, page.target);
  if (key !== currentPage) {
    currentPage = key;
    clearOverrides(viewState);
  }
  // A body remount disconnects the host but keeps its marked header. Reattach the
  // host before pruning so the view stays registered for its pending push.
  for (const a of liveAppliers()) a.sync();
  // React virtualization can disconnect both the header and host. Drop those view
  // references after live file views have reattached their hosts.
  pruneDisconnectedViews(views);
  const entries = scanUnityFiles(document);
  const first = entries[0];
  if (first) ensureGlobalToggle(viewState, first);
  for (const entry of entries) {
    const fileView = attachFileView(entry, page, messenger, viewState, views, authRetries, (root, error) => {
      void signInPanel(root, ERROR_TEXT[error]);
    });
    appliers.add(fileView);
  }
}

// Global bar must sit outside recycled react list items (classic: before .file, react: list root)
function ensureGlobalToggle(viewState: ViewStateData, first: FileEntry): void {
  if (globalToggle?.element.closest("[data-prefablens-global]")?.isConnected) return;
  const anchor = first.globalAnchor();
  if (!anchor?.parentElement) return;
  const bar = mountGlobalBar((view) => setDefault(viewState, view, persistView), viewState.def);
  anchor.before(bar.element);
  globalToggle = bar.toggle;
}

async function initDevicePage(): Promise<void> {
  const pending = await tokenStore.readPendingSignIn();
  if (pending) fillDeviceCode(document, pending, Date.now());
}

async function initDiffRuntime(): Promise<void> {
  let initial: View = "raw";
  try {
    const stored = await chrome.storage.local.get(["viewMode"]);
    if (stored.viewMode === "semantic") initial = "semantic";
  } catch {
    // A storage failure must not stop the current page.
  }
  const viewState = emptyViewState(initial);
  onDefaultChange(viewState, (view) => {
    globalToggle?.set(view);
    for (const a of liveAppliers()) a.apply(view);
  });
  // Cross-tab default sync. applyExternal ignores the originating tab's echo.
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    const next = changes.viewMode?.newValue;
    if (next === "raw" || next === "semantic") applyExternal(viewState, next);
    if (typeof changes.accessToken?.newValue === "string" && changes.accessToken.newValue) {
      // Token landed (this tab or elsewhere): retry every auth-blocked panel
      flushAuthRetries(authRetries);
    }
  });

  chrome.runtime.onMessage.addListener((msg: GuidResolvedPush) => {
    if (msg?.type !== "guidResolved") return;
    const view = views.get(viewKey(msg.owner, msg.repo, msg.target, msg.path));
    if (view) applyGuidResolvedPush(view, msg);
  });

  // SPA: MutationObserver + 50ms debounce follows lazy loads and stays under the
  // ~100ms sluggish threshold. Scans are fetch-free (~0.75ms), so storms stay cheap.
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

async function init(): Promise<void> {
  // The device activation page opens in a new tab.
  // The PR (pull request) tab already starts the main runtime.
  // This tab's only job is to fill in the activation code.
  // If you use soft navigation, it does not reload this script.
  // All other pages also start the runtime, but do nothing until on a diff or PR URL.
  if (location.pathname === "/login/device") {
    await initDevicePage();
    return;
  }
  await initDiffRuntime();
}

void init();
