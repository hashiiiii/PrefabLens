import { createViewHost } from "./render";
import { mountToggle } from "./toggle";
import type { ViewMode } from "./view-mode";

export type FileViewController = {
  element: HTMLElement;
  start(): void;
  setView(view: ViewMode): void;
  update(view: ViewMode): void;
  subscribeSelection(listener: (view: ViewMode) => void): () => void;
  subscribeSemantic(listener: (root: ShadowRoot) => void): () => void;
};

export function createFileViewController(
  initial: ViewMode,
  setRawHidden: (hidden: boolean) => void,
  attachHost: (host: HTMLDivElement) => void,
  semanticVisible: () => boolean,
): FileViewController {
  let host: HTMLDivElement | undefined;
  let root: ShadowRoot | undefined;
  let started = false;
  const selectionListeners = new Set<(view: ViewMode) => void>();
  const semanticListeners = new Set<(root: ShadowRoot) => void>();

  const ensureHost = (): { host: HTMLDivElement; root: ShadowRoot } => {
    if (!host || !root) {
      const created = createViewHost();
      host = created.host;
      root = created.root;
    }
    if (!host.isConnected) attachHost(host);
    return { host, root };
  };

  const update = (view: ViewMode): void => {
    if (view === "raw") {
      setRawHidden(false);
      if (host) {
        if (!host.isConnected) attachHost(host);
        host.style.display = "none";
      }
      return;
    }
    const current = ensureHost();
    setRawHidden(true);
    current.host.style.display = semanticVisible() ? "" : "none";
  };

  const activate = (view: ViewMode): void => {
    update(view);
    if (view === "semantic") {
      const semanticRoot = ensureHost().root;
      for (const listener of semanticListeners) listener(semanticRoot);
    }
  };

  const toggle = mountToggle(initial);
  toggle.subscribe((view) => {
    for (const listener of selectionListeners) listener(view);
    activate(view);
  });

  return {
    element: toggle.element,
    start: () => {
      if (started) return;
      started = true;
      activate(initial);
    },
    setView: (view) => {
      toggle.set(view);
      activate(view);
    },
    update,
    subscribeSelection: (listener) => {
      selectionListeners.add(listener);
      return () => selectionListeners.delete(listener);
    },
    subscribeSemantic: (listener) => {
      semanticListeners.add(listener);
      return () => semanticListeners.delete(listener);
    },
  };
}
