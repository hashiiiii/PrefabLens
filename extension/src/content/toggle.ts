export type View = "raw" | "semantic";

export type Toggle = { element: HTMLElement; set(view: View): void };

const FONT = `-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif`;

/** Page-level styles for the toggle and global bar. Colors read GitHub's Primer
 *  variables (always defined on github.com); fallbacks cover the e2e fixture. */
const PAGE_STYLES = `
  [data-prefablens-global] { display: flex; align-items: center; gap: 8px; margin: 0 0 8px; }
  [data-prefablens-global] .prefablens-seg { margin-left: 0; }
  .prefablens-eyebrow {
    font: 600 11px/1 ${FONT};
    letter-spacing: 0.6px; text-transform: uppercase;
    color: var(--fgColor-muted, #59636e);
  }
  .prefablens-seg {
    display: inline-flex; gap: 2px; padding: 2px; margin-left: 8px; vertical-align: middle;
    background: var(--bgColor-muted, #f6f8fa);
    border-radius: 6px;
  }
  .prefablens-seg button {
    font: 500 12px/20px ${FONT};
    padding: 0 10px; border: 1px solid transparent; border-radius: 4px;
    background: transparent; color: var(--fgColor-muted, #59636e); cursor: pointer;
  }
  .prefablens-seg button:hover { color: var(--fgColor-default, #1f2328); }
  .prefablens-seg button[aria-pressed="true"] {
    font-weight: 600;
    background: var(--bgColor-default, #ffffff);
    border-color: var(--borderColor-default, #d1d9e0);
    color: var(--fgColor-default, #1f2328);
  }
`;

/** Injects the page stylesheet once. The toggle lives in GitHub's DOM (not a shadow root). */
export function injectPageStyles(doc: Document = document): void {
  if (doc.head.querySelector("style[data-prefablens-style]")) return;
  const style = doc.createElement("style");
  style.setAttribute("data-prefablens-style", "");
  style.textContent = PAGE_STYLES;
  doc.head.append(style);
}

export function createToggle(onSelect: (view: View) => void, initial: View = "raw"): Toggle {
  injectPageStyles();
  const wrap = document.createElement("span");
  wrap.setAttribute("data-prefablens-toggle", "");
  wrap.className = "prefablens-seg";

  const buttons: HTMLButtonElement[] = [];
  // set updates only the display: to avoid pulling in onSelect (the re-fetch side) during a global apply.
  // The selected look is keyed entirely off aria-pressed in the injected CSS.
  const select = (view: View): void => {
    for (const b of buttons) b.setAttribute("aria-pressed", String(b.dataset.view === view));
  };
  const make = (view: View, label: string): HTMLButtonElement => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = label;
    btn.dataset.view = view;
    btn.addEventListener("click", () => {
      select(view);
      onSelect(view);
    });
    buttons.push(btn);
    return btn;
  };

  wrap.append(make("raw", "Raw"), make("semantic", "Semantic"));
  select(initial);
  return { element: wrap, set: select };
}
