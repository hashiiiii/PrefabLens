import { createViewHost } from "./render";
import { mountToggle } from "./toggle";
import type { View } from "./view-mode";

export type FileViewController = {
  element: HTMLElement;
  apply(view: View): void;
  sync(view: View): void;
};

export function createFileViewController(
  initial: View,
  onSelect: (view: View) => void,
  setRawHidden: (hidden: boolean) => void,
  attachHost: (host: HTMLDivElement) => void,
  semanticVisible: () => boolean,
  onSemantic: (root: ShadowRoot) => void,
): FileViewController {
  let host: HTMLDivElement | undefined;
  let root: ShadowRoot | undefined;

  const ensureHost = (): { host: HTMLDivElement; root: ShadowRoot } => {
    if (!host || !root) {
      const created = createViewHost();
      host = created.host;
      root = created.root;
    }
    if (!host.isConnected) attachHost(host);
    return { host, root };
  };

  const sync = (view: View): void => {
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

  const activate = (view: View): void => {
    sync(view);
    if (view === "semantic") onSemantic(ensureHost().root);
  };

  const toggle = mountToggle((view) => {
    onSelect(view);
    activate(view);
  }, initial);

  activate(initial);
  return {
    element: toggle.element,
    apply: (view) => {
      toggle.set(view);
      activate(view);
    },
    sync,
  };
}
