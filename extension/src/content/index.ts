import { pollForToken, requestDeviceCode } from "../github/deviceFlow";
import { GITHUB_ORIGIN, type Instances } from "../github/hosts";
import {
  render,
  renderError,
  renderLoading,
  renderPatNeeded,
  renderSignIn,
  renderSignInPending,
  renderTooLarge,
} from "../renderer/render";
import {
  type BackgroundError,
  type DiffV2,
  type GuidResolvedPush,
  type OpenOptionsRequest,
  type PrefetchRequest,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  targetKey,
} from "../types";
import { must } from "../util/must";
import { createAuthRetries } from "./authRetries";
import { type DiffPage, type FileEntry, parseDiffUrl, parsePrPage, scanUnityFiles } from "./detect";
import { fillDeviceCode } from "./devicePage";
import { createSignIn, type PendingSignIn } from "./signin";
import { createToggle, type Toggle, type View } from "./toggle";
import { createViewRegistry, type ViewEntry } from "./views";
import { createViewState, type ViewState } from "./viewstate";

const ERROR_TEXT: Record<BackgroundError, string> = {
  "pat-missing": "Sign in with GitHub to view semantic diffs.",
  "auth-failed": "GitHub authentication failed. Sign in again.",
  "rate-limited": "GitHub rate limit exceeded. Wait a while and toggle again.",
  "fetch-failed": "Could not fetch file contents from GitHub.",
  "diff-failed": "Could not compute a semantic diff for this file.",
  "not-unity-yaml": "This file is not a text-serialized Unity asset.",
};

// path → render target. When a push (guidResolved) arrives, merge resolved and re-render
const views = createViewRegistry();

function countUnresolved(json: DiffV2): number {
  return json.unresolvedGuids.filter((g) => !Object.hasOwn(json.resolved ?? {}, g)).length;
}

// If the final push is lost (dropped tab message, killed service worker), flip the
// indicator to the retryable incomplete state instead of spinning forever.
const WATCHDOG_MS = 120_000;

function armWatchdog(view: ViewEntry): void {
  clearTimeout(view.watchdog);
  view.watchdog = window.setTimeout(
    () => render(view.root, view.json, { incomplete: { onRetry: view.retry } }),
    WATCHDOG_MS,
  );
}

// Targets of the global switch: drives the toggle + display of already-attached files from outside
type Applier = { header: HTMLElement; apply(view: View): void; sync(): void };
const appliers = new Set<Applier>();
let globalToggle: Toggle | undefined;
let currentPage = ""; // overrides are valid only while on the diff page: discard when it changes
let prefetchedPr = ""; // send prefetch just once across all PR tabs, including the conversation tab

// Files whose panels are stuck on an auth error: all retried once a token lands in storage.
const authRetries = createAuthRetries();

// The device flow (and its /login/device autofill) is github.com-only; enterprise instances use a PAT.
const onGithubCom = location.origin === GITHUB_ORIGIN;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const signIn = createSignIn({
  // Same-origin on github.com: the device flow needs no background relay and no extra permissions.
  requestDeviceCode: () => requestDeviceCode(fetch),
  pollForToken: (code) => pollForToken(fetch, sleep, code),
  savePending: (pending) => chrome.storage.local.set({ signin: pending }),
  clearPending: () => chrome.storage.local.remove("signin"),
  saveToken: (token) => chrome.storage.local.set({ pat: token }),
  openTab: (url) => void window.open(url, "_blank", "noopener"),
  now: () => Date.now(),
});

/** Auth-error panel driving the device flow; failures land back here so the user can retry. */
function signInPanel(root: ShadowRoot, message: string): void {
  if (!onGithubCom) {
    // No per-instance OAuth app exists, so the device flow cannot run here: steer to the PAT setting.
    renderPatNeeded(
      root,
      () => void chrome.runtime.sendMessage({ type: "openOptions" } satisfies OpenOptionsRequest).catch(() => {}),
    );
    return;
  }
  renderSignIn(root, message, () => {
    void signIn({
      showPending: (userCode, verificationUri) =>
        renderSignInPending(root, userCode, verificationUri, () => void navigator.clipboard.writeText(userCode)),
      showFailure: (text) => signInPanel(root, text),
    });
  });
}

function attach(state: ViewState): void {
  const prPage = parsePrPage(location.pathname);
  if (prPage) {
    const prKey = targetKey(prPage.owner, prPage.repo, { kind: "pull", prNumber: prPage.prNumber });
    if (prKey !== prefetchedPr) {
      prefetchedPr = prKey;
      // fire-and-forget: don't wait on the response, ignore failures (the manual-toggle path is separately alive)
      void (
        chrome.runtime.sendMessage({
          type: "prefetch",
          origin: location.origin,
          ...prPage,
        } satisfies PrefetchRequest) as Promise<unknown>
      ).catch(() => {});
    }
  }
  const page = parseDiffUrl(location.pathname);
  if (!page) return;
  const key = targetKey(page.owner, page.repo, page.target);
  if (key !== currentPage) {
    currentPage = key;
    state.clearOverrides();
    views.pruneDisconnected(); // not only ignore late pushes to views killed by navigation, but also cut the reference
  }
  // The react ui virtualizes the list and discards off-screen DOM continuously, so prune
  // dead appliers every scan, not just on PR change (also plugs the classic soft leak).
  for (const a of [...appliers]) if (!a.header.isConnected) appliers.delete(a);
  const entries = scanUnityFiles(document);
  const first = entries[0];
  if (first) ensureGlobalToggle(state, first);
  for (const entry of entries) attachToggle(state, page, entry);
  // Re-assert view state: react remounts diff bodies under still-marked headers, which
  // silently undoes the inline hide. All sync operations are idempotent and fetch-free.
  for (const a of appliers) a.sync();
}

/** Injects exactly one global toggle right before the first Unity file's layout anchor:
 *  the .file container on classic, the virtualized list root on the react ui (a bar inside
 *  a recycled list item would be discarded on scroll). */
function ensureGlobalToggle(state: ViewState, first: FileEntry): void {
  if (globalToggle?.element.closest("[data-prefablens-global]")?.isConnected) return;
  const anchor = first.globalAnchor();
  if (!anchor?.parentElement) return;
  const bar = document.createElement("div");
  bar.setAttribute("data-prefablens-global", "");
  const label = document.createElement("span");
  label.className = "prefablens-eyebrow";
  label.textContent = "PrefabLens";
  const toggle = createToggle((view) => state.setDefault(view), state.defaultView());
  bar.append(label, toggle.element);
  anchor.before(bar);
  globalToggle = toggle;
}

function attachToggle(state: ViewState, page: DiffPage, entry: FileEntry): void {
  if (entry.header.hasAttribute("data-prefablens")) return;
  entry.header.setAttribute("data-prefablens", "");
  const viewKey = `${targetKey(page.owner, page.repo, page.target)}:${entry.path}`;

  let host: HTMLElement | undefined;
  let requested = false;

  // Display-only re-assert, never fetches: safe to run on every scan even while a panel
  // sits on an error (a fetching sync would silently hammer retries on rate limits).
  const sync = (view: View): void => {
    if (view === "raw") {
      entry.setRawHidden(false);
      if (host) host.style.display = "none";
      return;
    }
    if (!host) return; // semantic never rendered here: leave the raw diff alone
    entry.setRawHidden(true);
    if (!host.isConnected) entry.attachHost(host); // a react remount can drop the host together with the old body
    // Follow github's own collapse (react ui): the classic layout handles this via the
    // Details CSS class added in attachHost instead, where collapsed() is always false.
    host.style.display = entry.collapsed() ? "none" : "";
  };

  const show = (view: View): void => {
    if (view === "raw") {
      sync(view);
      return;
    }
    if (!host) {
      host = document.createElement("div");
      host.setAttribute("data-prefablens-view", "");
      host.attachShadow({ mode: "open" });
      entry.attachHost(host);
    }
    sync(view);
    if (requested) return; // cache only successful results per file (re-toggle doesn't re-fetch)
    const root = must(host.shadowRoot);
    const request = (force?: boolean): void => {
      requested = true;
      renderLoading(root);
      void requestDiff({
        type: "semanticDiff",
        origin: location.origin,
        owner: page.owner,
        repo: page.repo,
        target: page.target,
        path: entry.path,
        force,
      }).then((res) => {
        if (res.ok) {
          views.set(viewKey, {
            root,
            json: res.json,
            // Retry re-runs the whole request: the diff itself is cached, so this only
            // re-enters background resolution (requested must reset or request() no-ops).
            retry: () => {
              requested = false;
              request(force);
            },
          });
          if (res.pending) armWatchdog(must(views.get(viewKey)));
          // Always show it while pending: even if all names are resolved, source merging may remain
          return render(root, res.json, { resolving: res.pending ? Math.max(countUnresolved(res.json), 1) : 0 });
        }
        requested = false; // don't cache errors: let the next toggle re-fetch
        const view = views.get(viewKey);
        if (view) {
          // A failed retry must not wipe the diff the user is reading: keep the
          // tree and re-offer the retry affordance instead of a bare error panel.
          render(root, view.json, { incomplete: { onRetry: view.retry } });
          return;
        }
        if (res.error === "too-large") renderTooLarge(root, res.bytes, () => request(true));
        else if (res.error === "pat-missing" || res.error === "auth-failed") {
          authRetries.add(() => {
            // requested flips true on the first retry, so duplicate registrations no-op.
            if (!requested && state.effective(entry.path) === "semantic") request();
          });
          signInPanel(root, ERROR_TEXT[res.error]);
        } else renderError(root, ERROR_TEXT[res.error]);
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
    sync: () => sync(state.effective(entry.path)),
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
  // On the device-verification page the only job is pre-filling the code the PR page issued.
  // A GHES /login/device page never gets the autofill: the pending code was issued by github.com.
  if (location.pathname === "/login/device") {
    if (onGithubCom) {
      const stored = await chrome.storage.local.get(["signin"]).catch(() => ({}) as Record<string, unknown>);
      const pending = stored.signin as PendingSignIn | undefined;
      if (pending) fillDeviceCode(document, pending, Date.now());
    }
    return;
  }

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
    if (typeof changes.pat?.newValue === "string" && changes.pat.newValue) {
      // A token just landed (this tab's own flow or another surface): retry every auth-blocked panel.
      authRetries.flush();
    }
    // Same cue for enterprise instances: a PAT saved in the options page for this origin.
    const instances = changes.instances?.newValue as Instances | undefined;
    if (instances?.[location.origin]?.pat) authRetries.flush();
  });

  // guid resolution push from background (the second stage of the two-stage response): re-render if the matching view exists
  chrome.runtime.onMessage.addListener((msg: GuidResolvedPush) => {
    if (msg?.type !== "guidResolved") return;
    const view = views.get(`${targetKey(msg.owner, msg.repo, msg.target)}:${msg.path}`);
    if (!view) return; // already navigated to a different diff page, etc.: drop silently
    clearTimeout(view.watchdog);
    // The final push replaces json (mergeSources may change the structure), an intermediate push merges resolved
    view.json = msg.json ?? { ...view.json, resolved: { ...view.json.resolved, ...msg.resolved } };
    if (msg.done && msg.status !== undefined && msg.status !== "complete") {
      // The run gave up: keep the names that did arrive, offer a manual retry (#194).
      render(view.root, view.json, { incomplete: { onRetry: view.retry } });
      return;
    }
    if (!msg.done) armWatchdog(view);
    render(view.root, view.json, { resolving: msg.done ? 0 : Math.max(countUnresolved(view.json), 1) });
  });

  // GitHub is an SPA: an initial scan + MutationObserver follows lazy loading and tab navigation.
  // 50ms debounce keeps collapse/expand tracking under the ~100ms sluggishness threshold while
  // still batching mutation storms: a full scan pass measured ~0.75ms on a 21-file PR, so even
  // back-to-back rescans are negligible (the scan is fetch-free and idempotent).
  attach(state);
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      attach(state);
    }, 50);
  }).observe(document.body, { childList: true, subtree: true });
}

void init();
