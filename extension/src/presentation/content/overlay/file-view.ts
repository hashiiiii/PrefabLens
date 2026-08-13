import {
  type AuthError,
  type BackgroundError,
  isAuthError,
  type MessengerGateway,
} from "../../../application/gateway/messenger";
import { unresolvedRemaining } from "../../../domain/diff/fn/unresolved-remaining";
import { createFileViewController } from "../../internal/file-view-controller";
import { render, renderError, renderLoading, renderTooLarge } from "../../internal/render";
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
  let requested = false;

  const request = async (viewRoot: ShadowRoot, force?: boolean): Promise<void> => {
    requested = true;
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
          void request(viewRoot, force);
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
      await request(viewRoot, true);
    } else if (isAuthError(response.error)) {
      authRetries.add(() => {
        if (!requested && effectiveView(viewState, entry.path) === "semantic") void request(viewRoot);
      });
      showAuthError(viewRoot, response.error);
    } else {
      renderError(viewRoot, ERROR_TEXT[response.error]);
    }
  };

  const controller = createFileViewController(
    effectiveView(viewState, entry.path),
    entry.setRawHidden,
    entry.attachHost,
    () => !entry.collapsed(),
  );
  controller.subscribeSelection((view) => setOverride(viewState, entry.path, view));
  controller.subscribeSemantic((root) => {
    if (!requested) void request(root);
  });
  controller.start();
  entry.header.setAttribute("data-prefablens", "");
  entry.header.append(controller.element);

  return {
    header: entry.header,
    apply: controller.apply,
    sync: () => controller.sync(effectiveView(viewState, entry.path)),
  };
}
