import {
  type AuthError,
  type BackgroundError,
  type GuidResolvedPush,
  isAuthError,
  type MessengerGateway,
} from "../../../application/gateway/messenger";
import { targetKey } from "../../../domain/diff/fn/target-key";
import { unresolvedRemaining } from "../../../domain/diff/fn/unresolved-remaining";
import type { DiffV2 } from "../../../domain/diff/types";
import { createFileViewController } from "../../internal/file-view-controller";
import { render, renderError, renderLoading, renderTooLarge } from "../../internal/render";
import type { View } from "../../internal/view-mode";
import { effectiveView, setOverride, type ViewStateData } from "../../internal/view-state";
import type { DiffPage, FileEntry } from "../detect";

const ERROR_TEXT: Record<Exclude<BackgroundError, AuthError>, string> = {
  "rate-limited": "You reached the GitHub rate limit. Please wait, then try again.",
  "fetch-failed": "Could not get file contents from GitHub.",
  "diff-failed": "Could not make a semantic diff for this file.",
  "not-unity-yaml": "This file is not a Unity asset file in text format.",
};

const WATCHDOG_MS = 120_000;

export type FileStatus = "idle" | "loading" | "auth-blocked" | "pending";

export type FileView = {
  key: string;
  path: string;
  header: HTMLElement;
  status: FileStatus;
  start(): void;
  apply(view: View): void;
  sync(): void;
  request(): Promise<void>;
  resolve(message: GuidResolvedPush): void;
  subscribeAuth(listener: (root: ShadowRoot, error: AuthError) => void): () => void;
  dispose(): void;
};

export type FileRegistry = Map<string, FileView>;

export function fileKey(page: DiffPage, path: string): string {
  return `${targetKey(page.owner, page.repo, page.target)}:${path}`;
}

export function createFileView(
  entry: FileEntry,
  page: DiffPage,
  messenger: MessengerGateway,
  viewState: ViewStateData,
): FileView {
  let root: ShadowRoot | undefined;
  let json: DiffV2 | undefined;
  let force = false;
  let watchdog: number | undefined;
  const authListeners = new Set<(root: ShadowRoot, error: AuthError) => void>();

  const controller = createFileViewController(
    effectiveView(viewState, entry.path),
    entry.setRawHidden,
    entry.attachHost,
    () => !entry.collapsed(),
  );

  const file: FileView = {
    key: fileKey(page, entry.path),
    path: entry.path,
    header: entry.header,
    status: "idle",
    start: controller.start,
    apply: controller.apply,
    sync: () => controller.sync(effectiveView(viewState, entry.path)),
    request: async () => {
      if (!root || file.status === "loading" || file.status === "pending") return;
      file.status = "loading";
      renderLoading(root);
      const response = await messenger.semanticDiff({
        type: "semanticDiff",
        owner: page.owner,
        repo: page.repo,
        target: page.target,
        path: entry.path,
        force,
      });
      if (response.ok) {
        json = response.json;
        file.status = response.pending ? "pending" : "idle";
        if (response.pending) armWatchdog();
        void render(root, response.json, {
          resolving: response.pending ? Math.max(unresolvedRemaining(response.json).length, 1) : 0,
        });
        return;
      }

      file.status = "idle";
      if (json) {
        await render(root, json, { incomplete: true });
        await file.request();
      } else if (response.error === "too-large") {
        await renderTooLarge(root, response.bytes);
        force = true;
        await file.request();
      } else if (isAuthError(response.error)) {
        file.status = "auth-blocked";
        for (const listener of authListeners) listener(root, response.error);
      } else {
        renderError(root, ERROR_TEXT[response.error]);
      }
    },
    resolve: (message) => {
      if (!root || !json) return;
      clearTimeout(watchdog);
      json = message.json ?? { ...json, resolved: { ...json.resolved, ...message.resolved } };
      if (message.done && message.status !== undefined && message.status !== "complete") {
        file.status = "idle";
        void render(root, json, { incomplete: true }).then(file.request);
        return;
      }
      file.status = message.done ? "idle" : "pending";
      if (!message.done) armWatchdog();
      void render(root, json, {
        resolving: message.done ? 0 : Math.max(unresolvedRemaining(json).length, 1),
      });
    },
    subscribeAuth: (listener) => {
      authListeners.add(listener);
      return () => authListeners.delete(listener);
    },
    dispose: () => clearTimeout(watchdog),
  };

  function armWatchdog(): void {
    clearTimeout(watchdog);
    watchdog = window.setTimeout(() => {
      if (!root || !json || file.status !== "pending") return;
      file.status = "idle";
      void render(root, json, { incomplete: true }).then(file.request);
    }, WATCHDOG_MS);
  }

  controller.subscribeSelection((view) => setOverride(viewState, entry.path, view));
  controller.subscribeSemantic((semanticRoot) => {
    root = semanticRoot;
    if (!json && file.status !== "loading" && file.status !== "pending") void file.request();
  });
  entry.header.setAttribute("data-prefablens", "");
  entry.header.append(controller.element);
  return file;
}
