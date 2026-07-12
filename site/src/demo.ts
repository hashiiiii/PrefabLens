// Live demo for extension.html: the mock PR page runs the extension's real
// renderer, toggle, and WASM diff engine, wired the same way as
// extension/src/content/index.ts minus the GitHub API and auth layers.
// Diff inputs are fixture files served next to the page instead of API blobs.
import { createToggle, injectPageStyles, type View } from "../../extension/src/content/toggle";
import { createViewState } from "../../extension/src/content/viewstate";
import { render, renderError, renderLoading } from "../../extension/src/renderer/render";
import { createDiffer, type Differ } from "../../extension/src/wasm/differ";

const FILES: Record<string, { before: string; after: string }> = {
  "Assets/Cylinder.prefab": { before: "fixtures/cylinder_before.prefab", after: "fixtures/cylinder_after.prefab" },
  "Assets/Materials/Rock.mat": { before: "fixtures/material_before.mat", after: "fixtures/material_after.mat" },
  "Assets/Animations/Player.controller": {
    before: "fixtures/animator_before.controller",
    after: "fixtures/animator_after.controller",
  },
};

async function fetchBytes(url: string): Promise<Uint8Array> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

function attachFile(header: HTMLElement, path: string, differ: Differ, initial: View): (view: View) => void {
  const fixture = FILES[path]!;
  const content = header.parentElement!.querySelector<HTMLElement>(".js-file-content")!;
  let host: HTMLElement | undefined;
  let rendered = false;

  const show = (view: View): void => {
    if (view === "raw") {
      content.style.display = "";
      if (host) host.style.display = "none";
      return;
    }
    content.style.display = "none";
    if (!host) {
      host = document.createElement("div");
      host.setAttribute("data-prefablens-view", "");
      // Same Primer class as .js-file-content: the collapse chevron toggles
      // Details--on on .file, and the host must opt into that CSS itself.
      host.classList.add("Details-content--hidden");
      host.attachShadow({ mode: "open" });
      content.after(host);
    }
    host.style.display = "";
    if (rendered) return; // fixtures are static: render each file once
    rendered = true;
    const root = host.shadowRoot!;
    renderLoading(root);
    void Promise.all([fetchBytes(fixture.before), fetchBytes(fixture.after)])
      .then(([before, after]) => render(root, differ.diff(before, after)))
      .catch((err: unknown) => renderError(root, String(err)));
  };

  show(initial);
  return show;
}

async function main(): Promise<void> {
  injectPageStyles();

  // The collapse chevrons work on every file, Unity or not (GitHub behavior).
  for (const button of document.querySelectorAll<HTMLElement>(".file-collapse")) {
    button.addEventListener("click", () => {
      button.closest(".file")?.classList.toggle("Details--on");
      button.closest(".file")?.classList.toggle("open");
    });
  }

  const headers = [...document.querySelectorAll<HTMLElement>(".file-header[data-path]")].filter(
    (h) => h.dataset.path! in FILES,
  );
  if (!headers.length) return;

  const differ = await createDiffer(await fetchBytes("prefablens.wasm"));
  // Semantic by default, like the extension once the user has picked it; the
  // demo has no chrome.storage, so persistence is a no-op.
  const state = createViewState("semantic", () => {});
  const appliers: Array<(view: View) => void> = [];
  state.onDefaultChange((view) => {
    for (const apply of appliers) apply(view);
  });

  // Global bar above the first Unity file, same anchor rule as the content script.
  const firstFile = headers[0]!.closest(".file")!;
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
    const path = header.dataset.path!;
    const show = attachFile(header, path, differ, state.effective(path));
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
