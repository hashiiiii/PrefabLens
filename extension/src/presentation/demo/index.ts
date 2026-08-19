// Live demo for site/extension.html: real renderer + toggle, wired like the
// content script but through the demo container factories (fixtures instead
// of GitHub). Bundled as dist/demo.js via `node build.mjs --demo`. Fixtures
// come via data-before/data-after URLs (an empty side follows the CLI
// empty-side semantics).

import { getLocalDiff } from "../../application/diff/get-local-diff";
import type { DifferGateway } from "../../application/gateway/differ";
import type { FixturesGateway } from "../../application/gateway/fixtures";
import { createDemoDifferGateway, createFixturesGateway } from "../../container";
import { must } from "../../internal/must";
import { createFileViewController } from "../internal/file-view-controller";
import { render, renderError, renderLoading } from "../internal/render";
import { injectPageStyles, mountGlobalBar } from "../internal/toggle";
import type { ViewMode } from "../internal/view-mode";
import { createViewState } from "../internal/view-state";

function attachFile(
  header: HTMLElement,
  differ: DifferGateway,
  index: Map<string, string>,
  fetchBytes: FixturesGateway["fetchBytes"],
  fetchSource: FixturesGateway["fetchSource"],
  initial: ViewMode,
  onSelect: (view: ViewMode) => void,
): (view: ViewMode) => void {
  // Non-null: site/build.mjs always nests the header in a .file with a .js-file-content sibling.
  const content = must(header.parentElement?.querySelector<HTMLElement>(".js-file-content"));
  let rendered = false;

  const controller = createFileViewController(
    initial,
    (hidden) => {
      content.style.display = hidden ? "none" : "";
    },
    (host) => {
      // Same Primer class as .js-file-content: the collapse chevron toggles
      // Details--on on .file, and the host must opt into that CSS itself.
      host.classList.add("Details-content--hidden");
      content.after(host);
    },
    () => true,
  );
  controller.subscribeSelection(onSelect);
  controller.subscribeSemantic((root) => {
    if (rendered) return;
    rendered = true;
    renderLoading(root);
    void getLocalDiff(differ, index, fetchBytes, fetchSource, header.dataset.before, header.dataset.after)
      .then((result) => (result.ok ? render(root, result.value) : renderError(root, result.error.message)))
      .catch((error) => renderError(root, String(error)));
  });
  controller.start();

  header.append(controller.element);
  return controller.apply;
}

async function main(): Promise<void> {
  const headers = [...document.querySelectorAll<HTMLElement>(".file-header[data-before]")];
  if (!headers.length) return;

  const fixturesGateway = createFixturesGateway();
  const loadDiffer = createDemoDifferGateway(fixturesGateway.fetchBytes);
  const differ = await loadDiffer();
  const index = await fixturesGateway.loadGuidIndex();

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
  const state = createViewState("semantic", () => {});
  const appliers: Array<(view: ViewMode) => void> = [];
  state.subscribe((view) => {
    for (const apply of appliers) apply(view);
  });

  // Global bar above the first Unity file, same anchor rule as the content script.
  const firstFile = must(headers[0]?.closest(".file"));
  const bar = mountGlobalBar(state.page);
  bar.toggle.subscribe((view) => state.setDefault(view));
  firstFile.before(bar.element);
  state.subscribe((view) => bar.toggle.set(view));

  for (const header of headers) {
    const path = header.dataset.path ?? "";
    const apply = attachFile(
      header,
      differ,
      index,
      fixturesGateway.fetchBytes,
      fixturesGateway.fetchSource,
      state.resolve(path),
      (view) => state.setFile(path, view),
    );
    appliers.push(apply);
  }
}

void main();
