// Live demo for site/extension.html: real renderer + toggle, wired like the
// content script but through createDemoApp (fixtures instead of GitHub).
// Bundled as dist/demo.js via `node build.mjs --demo`; fixtures via
// data-before/data-after URLs (empty side = CLI empty-side semantics).

import { must } from "../../domain/must";
import { createDemoApp, type DemoApp } from "../../infrastructure/container";
import type { View } from "../content/overlay/view-mode";
import { createViewState } from "../content/overlay/view-state";
import { createToggle, injectPageStyles } from "../content/toggle";
import { render, renderError, renderLoading } from "../renderer/render";

function attachFile(header: HTMLElement, app: DemoApp, initial: View): (view: View) => void {
  // Non-null: site/build.mjs always nests the header in a .file with a .js-file-content sibling.
  const content = must(header.parentElement?.querySelector<HTMLElement>(".js-file-content"));
  let host: HTMLDivElement | undefined;
  let root: ShadowRoot | undefined;
  let rendered = false;

  const show = (view: View): void => {
    if (view === "raw") {
      content.style.display = "";
      if (host) host.style.display = "none";
      return;
    }
    content.style.display = "none";
    if (!host || !root) {
      host = document.createElement("div");
      host.setAttribute("data-prefablens-view", "");
      // Same Primer class as .js-file-content: the collapse chevron toggles
      // Details--on on .file, and the host must opt into that CSS itself.
      host.classList.add("Details-content--hidden");
      root = host.attachShadow({ mode: "open" });
      content.after(host);
    }
    host.style.display = "";
    if (rendered) return; // fixtures are static: render each file once
    rendered = true;
    const target = root;
    renderLoading(target);
    app
      .computeLocalDiff(header.dataset.before, header.dataset.after)
      .then((diff) => render(target, diff))
      .catch((err) => renderError(target, String(err)));
  };

  show(initial);
  return show;
}

async function main(): Promise<void> {
  injectPageStyles();

  // The collapse chevrons work on every file, Unity or not (GitHub behavior).
  for (const button of document.querySelectorAll(".file-collapse")) {
    button.addEventListener("click", () => {
      button.closest(".file")?.classList.toggle("Details--on");
      button.closest(".file")?.classList.toggle("open");
    });
  }

  const headers = [...document.querySelectorAll<HTMLElement>(".file-header[data-before]")];
  if (!headers.length) return;

  const app = await createDemoApp();
  // Semantic by default, like the extension once the user has picked it; the
  // demo has no chrome.storage, so persistence is a no-op.
  const state = createViewState("semantic", () => {});
  const appliers: Array<(view: View) => void> = [];
  state.onDefaultChange((view) => {
    for (const apply of appliers) apply(view);
  });

  // Global bar above the first Unity file, same anchor rule as the content script.
  const firstFile = must(headers[0]?.closest(".file"));
  const bar = document.createElement("div");
  bar.setAttribute("data-prefablens-global", "");
  const label = document.createElement("span");
  label.className = "prefablens-eyebrow";
  label.textContent = "PrefabLens";
  const globalToggle = createToggle((view) => state.setDefault(view), state.defaultView());
  bar.append(label, globalToggle.element);
  firstFile.before(bar);
  state.onDefaultChange((view) => globalToggle.set(view));

  for (const header of headers) {
    const path = header.dataset.path ?? "";
    const show = attachFile(header, app, state.effective(path));
    const toggle = createToggle((view) => {
      state.setOverride(path, view); // a click overrides just this file
      show(view);
    }, state.effective(path));
    header.append(toggle.element);
    appliers.push((view) => {
      toggle.set(view);
      show(view);
    });
  }
}

void main();
