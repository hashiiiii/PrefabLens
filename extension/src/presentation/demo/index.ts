// Live demo for site/extension.html: real renderer + toggle, wired like the
// content script but through createDemo* factories (fixtures instead of GitHub).
// Bundled as dist/demo.js via `node build.mjs --demo`; fixtures via
// data-before/data-after URLs (empty side = CLI empty-side semantics).

import { getLocalDiff } from "../../application/diff/get-local-diff";
import { must } from "../../domain/must";
import {
  createDemoDiffer,
  createDemoFetchBytes,
  createDemoFetchSource,
  loadFixtureGuidIndex,
} from "../../infrastructure/container";
import type { View } from "../content/overlay/view-mode";
import {
  defaultView,
  effectiveView,
  emptyViewState,
  onDefaultChange,
  setDefault,
  setOverride,
} from "../content/overlay/view-state";
import { injectPageStyles, mountToggle } from "../content/toggle";
import { render, renderError, renderLoading } from "../renderer/render";

type DemoLocals = {
  differ: Awaited<ReturnType<typeof createDemoDiffer>>;
  index: Awaited<ReturnType<typeof loadFixtureGuidIndex>>;
  fetchBytes: ReturnType<typeof createDemoFetchBytes>;
  fetchSource: ReturnType<typeof createDemoFetchSource>;
};

function attachFile(header: HTMLElement, locals: DemoLocals, initial: View): (view: View) => void {
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
    const { differ, index, fetchBytes, fetchSource } = locals;
    getLocalDiff(differ, index, fetchBytes, fetchSource, header.dataset.before, header.dataset.after)
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

  const differ = await createDemoDiffer();
  const index = await loadFixtureGuidIndex();
  const fetchBytes = createDemoFetchBytes();
  const fetchSource = createDemoFetchSource();
  const locals: DemoLocals = { differ, index, fetchBytes, fetchSource };
  // Semantic by default, like the extension once the user has picked it; the
  // demo has no chrome.storage, so persistence is a no-op.
  const state = emptyViewState("semantic");
  const persist = (): void => {};
  const appliers: Array<(view: View) => void> = [];
  onDefaultChange(state, (view) => {
    for (const apply of appliers) apply(view);
  });

  // Global bar above the first Unity file, same anchor rule as the content script.
  const firstFile = must(headers[0]?.closest(".file"));
  const bar = document.createElement("div");
  bar.setAttribute("data-prefablens-global", "");
  const label = document.createElement("span");
  label.className = "prefablens-eyebrow";
  label.textContent = "PrefabLens";
  const globalToggle = mountToggle((view) => setDefault(state, view, persist), defaultView(state));
  bar.append(label, globalToggle.element);
  firstFile.before(bar);
  onDefaultChange(state, (view) => globalToggle.set(view));

  for (const header of headers) {
    const path = header.dataset.path ?? "";
    const show = attachFile(header, locals, effectiveView(state, path));
    const toggle = mountToggle(
      (view) => {
        setOverride(state, path, view); // a click overrides just this file
        show(view);
      },
      effectiveView(state, path),
    );
    header.append(toggle.element);
    appliers.push((view) => {
      toggle.set(view);
      show(view);
    });
  }
}

void main();
