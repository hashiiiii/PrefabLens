import {
  type AuthError,
  type BackgroundError,
  isAuthError,
  type MessengerGateway,
} from "../../../application/gateway/messenger";
import { unresolvedRemaining } from "../../../domain/diff/fn/unresolved-remaining";
import { must } from "../../../internal/must";
import { createViewHost, render, renderError, renderLoading, renderTooLarge } from "../../internal/render";
import { mountToggle } from "../../internal/toggle";
import type { View } from "../../internal/view-mode";
import { effectiveView, setOverride, type ViewStateData } from "../../internal/view-state";
import type { DiffPage, FileEntry } from "../detect";
import { armViewWatchdog, type ViewRegistry, viewKey } from "./views";

const ERROR_TEXT: Record<Exclude<BackgroundError, AuthError>, string> = {
  "rate-limited": "You reached the GitHub rate limit. Please wait, then try again.",
  "fetch-failed": "Could not get file contents from GitHub.",
  "diff-failed": "Could not make a semantic diff for this file.",
  "not-unity-yaml": "This file is not a Unity asset file in text format.",
};

export type FileView = {
  header: HTMLElement;
  apply(view: View): void;
  sync(): void;
};

export function attachFileView(
  entry: FileEntry,
  page: DiffPage,
  messenger: MessengerGateway,
  viewState: ViewStateData,
  views: ViewRegistry,
  authRetries: Set<() => void>,
  showAuthError: (root: ShadowRoot, error: AuthError) => void,
): FileView {
  const key = viewKey(page.owner, page.repo, page.target, entry.path);
  let host: HTMLDivElement | undefined;
  let root: ShadowRoot | undefined;
  let requested = false;

  const syncView = (view: View): void => {
    if (view === "raw") {
      entry.setRawHidden(false);
      if (host && !host.isConnected) entry.attachHost(host);
      if (host) host.style.display = "none";
      return;
    }
    if (!host) return;
    entry.setRawHidden(true);
    if (!host.isConnected) entry.attachHost(host);
    host.style.display = entry.collapsed() ? "none" : "";
  };

  const request = async (force?: boolean): Promise<void> => {
    requested = true;
    const viewRoot = must(root);
    renderLoading(viewRoot);
    const response = await messenger.semanticDiff({
      type: "semanticDiff",
      owner: page.owner,
      repo: page.repo,
      target: page.target,
      path: entry.path,
      force,
    });
    if (response.ok) {
      const view = {
        root: viewRoot,
        json: response.json,
        retry: () => {
          requested = false;
          void request(force);
        },
      };
      views.set(key, view);
      if (response.pending) armViewWatchdog(view);
      void render(viewRoot, response.json, {
        resolving: response.pending ? Math.max(unresolvedRemaining(response.json).length, 1) : 0,
      });
      return;
    }

    requested = false;
    const prior = views.get(key);
    if (prior) {
      await render(viewRoot, prior.json, { incomplete: true });
      prior.retry();
      return;
    }
    if (response.error === "too-large") {
      await renderTooLarge(viewRoot, response.bytes);
      await request(true);
    } else if (isAuthError(response.error)) {
      authRetries.add(() => {
        if (!requested && effectiveView(viewState, entry.path) === "semantic") void request();
      });
      showAuthError(viewRoot, response.error);
    } else {
      renderError(viewRoot, ERROR_TEXT[response.error]);
    }
  };

  const show = (view: View): void => {
    if (view === "raw") {
      syncView(view);
      return;
    }
    if (!host) {
      const created = createViewHost();
      host = created.host;
      root = created.root;
      entry.attachHost(host);
    }
    syncView(view);
    if (!requested) void request();
  };

  const toggle = mountToggle(
    (view) => {
      setOverride(viewState, entry.path, view);
      show(view);
    },
    effectiveView(viewState, entry.path),
  );
  entry.header.setAttribute("data-prefablens", "");
  entry.header.append(toggle.element);

  const fileView: FileView = {
    header: entry.header,
    apply: (view) => {
      toggle.set(view);
      show(view);
    },
    sync: () => syncView(effectiveView(viewState, entry.path)),
  };
  if (effectiveView(viewState, entry.path) === "semantic") show("semantic");
  return fileView;
}
