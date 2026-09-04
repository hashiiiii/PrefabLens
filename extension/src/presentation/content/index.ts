import { type SignInFailure, signIn } from "../../application/auth/sign-in";
import type { AuthError, GuidResolvedPush } from "../../application/gateway/messenger";
import { createAuthRepository, createGithubAuthGateway, createMessengerGateway } from "../../container";
import { targetKey } from "../../domain/diff/fn/target-key";
import { renderSignIn, renderSignInPending } from "../internal/render";
import { mountGlobalBar, type Toggle } from "../internal/toggle";
import type { ViewMode } from "../internal/view-mode";
import { createViewState, type ViewState } from "../internal/view-state";
import { type DiffPage, findGlobalAnchor, parseDiffUrl, parsePrPage, scanUnityFiles } from "./detect";
import { fillDeviceCode } from "./device-page";
import { createFileView, type FileRegistry, fileKey } from "./overlay/file-view";

const ERROR_TEXT: Record<AuthError, string> = {
  "access-token-missing": "Please sign in with GitHub to view semantic diffs.",
  "auth-failed": "GitHub authentication did not work. Please sign in again.",
};

const SIGN_IN_FAILURE_TEXT: Record<SignInFailure, string> = {
  denied: "Authorization was denied. Please try again.",
  expired: "The code expired. Please try again.",
  failed: "Sign-in did not work. Please try again.",
};

const files: FileRegistry = new Map();
let globalToggle: Toggle | undefined;
let currentPage = ""; // drop overrides when leaving this diff page
let prefetchedPr = ""; // prefetch once per PR across conversation + files tabs

function updateFiles(): FileRegistry {
  for (const [key, file] of files) {
    if (file.header.isConnected) file.update();
    else {
      file.dispose();
      files.delete(key);
    }
  }
  return files;
}

const messengerGateway = createMessengerGateway();
const authRepository = createAuthRepository();
const githubAuthGateway = createGithubAuthGateway();
const signInState = { inFlight: false };
// _blank: Open in a new tab
// noopener: Prevent the opened tab from accessing the original tab
const openTab = (url: string) => void window.open(url, "_blank", "noopener");
const now = () => Date.now();

const saveViewMode = async (view: ViewMode): Promise<void> => {
  try {
    await chrome.storage.local.set({ viewMode: view });
  } catch {
    // A storage failure must not disable the current page.
  }
};

// Auth-error panel: device flow. Failures land back here for retry.
async function signInPanel(root: ShadowRoot, message: string): Promise<void> {
  await renderSignIn(root, message);
  for await (const event of signIn(githubAuthGateway, authRepository, now, signInState)) {
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

function attach(viewState: ViewState): void {
  const prPage = parsePrPage(location.pathname);
  if (prPage) {
    const prKey = targetKey(prPage.owner, prPage.repo, { kind: "pull", prNumber: prPage.prNumber });
    if (prKey !== prefetchedPr) {
      prefetchedPr = prKey;
      void messengerGateway.prefetch({ type: "prefetch", ...prPage });
    }
  }

  const page = parseDiffUrl(location.pathname);
  if (!page) return;

  const key = targetKey(page.owner, page.repo, page.target);
  if (key !== currentPage) {
    currentPage = key;
    viewState.clearFiles();
  }

  updateFiles();

  const globalAnchor = findGlobalAnchor(document);
  if (globalAnchor) ensureGlobalToggle(viewState, globalAnchor);
  const entries = scanUnityFiles(document);
  for (const entry of entries) {
    const file = createFileView(entry, page, messengerGateway, viewState);
    file.subscribeAuth((root, error) => {
      void signInPanel(root, ERROR_TEXT[error]);
    });
    files.set(file.key, file);
    file.start();
  }
}

// The global bar stays outside the recycled rows from GitHub.
function ensureGlobalToggle(viewState: ViewState, anchor: Element): void {
  if (globalToggle?.element.closest("[data-prefablens-global]")?.isConnected) return;
  if (!anchor.parentElement) return;
  const bar = mountGlobalBar(viewState.page);
  bar.toggle.subscribe((view) => viewState.savePage(view));
  anchor.before(bar.element);
  globalToggle = bar.toggle;
}

async function init(): Promise<void> {
  // The device activation page opens in a new tab.
  // The PR (pull request) tab already starts the main runtime.
  // This tab's only job is to fill in the activation code.
  // If you use soft navigation, it does not reload this script.
  // All other pages also start the runtime, but do nothing until on a diff or PR URL.
  if (location.pathname === "/login/device") {
    const pending = await authRepository.loadPendingSignIn();
    if (pending) fillDeviceCode(document, pending, Date.now());
    return;
  }

  let initial: ViewMode = "raw";
  try {
    const stored = await chrome.storage.local.get(["viewMode"]);
    if (stored.viewMode === "semantic") initial = "semantic";
  } catch {
    // A storage failure must not stop the current page.
  }

  const viewState = createViewState(initial, saveViewMode);

  viewState.subscribe((view) => {
    globalToggle?.set(view);
    for (const file of updateFiles().values()) file.setView(view);
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    const next = changes.viewMode?.newValue;
    if (next === "raw" || next === "semantic") viewState.setPage(next);
    if (typeof changes.accessToken?.newValue === "string") {
      for (const file of updateFiles().values()) {
        if (file.status === "auth-blocked" && viewState.getFile(file.path) === "semantic") {
          void file.loadDiff();
        }
      }
    }
  });

  chrome.runtime.onMessage.addListener((msg: GuidResolvedPush) => {
    if (msg?.type !== "guidResolved") return;
    const page: DiffPage = { owner: msg.owner, repo: msg.repo, target: msg.target };
    files.get(fileKey(page, msg.path))?.setResolved(msg);
  });

  attach(viewState);

  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    // If React replaces a complete file during a scroll, reattach before the browser paints the raw body.
    queueMicrotask(() => {
      scheduled = false;
      attach(viewState);
    });
  }).observe(document.body, { childList: true, subtree: true });
}

void init();
