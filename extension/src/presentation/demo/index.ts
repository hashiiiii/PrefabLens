// Live demo for site/extension.html: real renderer + toggle, wired like the
// content script but through the demo container factories (fixtures instead
// of GitHub). Bundled as dist/demo.js via `node build.mjs --demo`. Fixtures
// come via data-before/data-after URLs (an empty side follows the CLI
// empty-side semantics).

import { getLocalDiff } from "../../application/diff/get-local-diff";
import type { DifferGateway } from "../../application/gateway/differ";
import type { FixturesGateway } from "../../application/gateway/fixtures";
import { createDemoDifferLoader, createFixtures } from "../../container";
import { must } from "../../internal/must";
import { createViewHost, render, renderError, renderLoading } from "../internal/render";
import { injectPageStyles, mountGlobalBar, mountToggle } from "../internal/toggle";
import type { View } from "../internal/view-mode";
import { effectiveView, emptyViewState, onDefaultChange, setDefault, setOverride } from "../internal/view-state";

type DemoLocals = {
  differ: DifferGateway;
  index: Map<string, string>;
  fixtures: FixturesGateway;
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
      ({ host, root } = createViewHost());
      // Same Primer class as .js-file-content: the collapse chevron toggles
      // Details--on on .file, and the host must opt into that CSS itself.
      host.classList.add("Details-content--hidden");
      content.after(host);
    }
    host.style.display = "";
    if (rendered) return; // fixtures are static: render each file once
    rendered = true;
    const target = root;
    renderLoading(target);
    const { differ, index, fixtures } = locals;
    getLocalDiff(differ, index, fixtures.fetchBytes, fixtures.fetchSource, header.dataset.before, header.dataset.after)
      .then((res) => (res.ok ? render(target, res.value) : renderError(target, res.error.message)))
      .catch((err) => renderError(target, String(err))); // unexpected rejections (missing fixture)
  };

  show(initial);
  return show;
}

async function main(): Promise<void> {
  const headers = [...document.querySelectorAll<HTMLElement>(".file-header[data-before]")];
  if (!headers.length) return;

  const fixtures = createFixtures();
  const loadDiffer = createDemoDifferLoader(fixtures.fetchBytes);
  const differ = await loadDiffer();
  const index = await fixtures.loadGuidIndex();
  const locals: DemoLocals = { differ, index, fixtures };

  injectPageStyles();
  // The collapse chevrons work on every file, Unity or not (GitHub behavior).
  for (const button of document.querySelectorAll(".file-collapse")) {
    button.addEventListener("click", () => {
      button.closest(".file")?.classList.toggle("Details--on");
      button.closest(".file")?.classList.toggle("open");
    });
  }

  // Semantic by default, like the extension after the user picks it. The
  // demo has no chrome.storage, so persistence is a no-op.
  const state = emptyViewState("semantic");
  const persist = (): void => {};
  const appliers: Array<(view: View) => void> = [];
  onDefaultChange(state, (view) => {
    for (const apply of appliers) apply(view);
  });

  // Global bar above the first Unity file, same anchor rule as the content script.
  const firstFile = must(headers[0]?.closest(".file"));
  const bar = mountGlobalBar((view) => setDefault(state, view, persist), state.def);
  firstFile.before(bar.element);
  onDefaultChange(state, (view) => bar.toggle.set(view));

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
