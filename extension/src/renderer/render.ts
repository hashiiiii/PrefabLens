import type { ComponentDiff, DiffV2, FieldValue, NodeDiff, OverrideDiff, Status } from "../types";

const STYLES = `
  :host { all: initial; }
  .pl-root {
    --pl-fg: #1f2328; --pl-muted: #59636e; --pl-border: #d1d9e0;
    --pl-added: #1a7f37; --pl-removed: #cf222e; --pl-modified: #9a6700;
    font: 12px/1.5 ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    color: var(--pl-fg); padding: 8px 12px; display: block;
  }
  .pl-root.pl-dark {
    --pl-fg: #f0f6fc; --pl-muted: #9198a1; --pl-border: #3d444d;
    --pl-added: #3fb950; --pl-removed: #f85149; --pl-modified: #d29922;
  }
  details { margin: 2px 0; border-left: 1px solid var(--pl-border); padding-left: 10px; }
  summary { cursor: pointer; user-select: none; }
  .pl-badge { font-weight: 600; margin-right: 6px; }
  .pl-added > summary .pl-badge { color: var(--pl-added); }
  .pl-removed > summary .pl-badge { color: var(--pl-removed); }
  .pl-modified > summary .pl-badge { color: var(--pl-modified); }
  .pl-script { color: var(--pl-muted); margin-left: 6px; }
  .pl-field { padding-left: 14px; }
  .pl-field .pl-path { color: var(--pl-muted); margin-right: 6px; }
  .pl-before { color: var(--pl-removed); }
  .pl-after { color: var(--pl-added); }
  .pl-arrow { color: var(--pl-muted); margin: 0 4px; }
  .pl-empty, .pl-error, .pl-loading { color: var(--pl-muted); margin: 0; }
  .pl-resolving { color: var(--pl-muted); margin: 0 0 4px; }
  .pl-error { color: var(--pl-removed); }
  .pl-render { font: inherit; margin-top: 4px; padding: 1px 8px; border: 1px solid var(--pl-border); background: transparent; color: inherit; cursor: pointer; }
  .pl-components { border-left: 1px solid var(--pl-border); margin: 2px 0 2px 4px; padding-left: 8px; }
  .pl-components-label { color: var(--pl-muted); font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; user-select: none; }
`;

const BADGE: Record<Status, string> = { added: "+", removed: "−", modified: "~", unchanged: " " };

export function detectTheme(doc: Document): "light" | "dark" {
  const mode = doc.documentElement.getAttribute("data-color-mode");
  if (mode === "dark") return "dark";
  if (mode === "light") return "light";
  return doc.defaultView?.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function render(root: ShadowRoot, diff: DiffV2, opts?: { resolving?: number }): void {
  const container = mount(root);
  // Resolving indicator (spec B4): the diff body is correct from the start, only reference names fill in later
  if (opts?.resolving) container.append(note("pl-resolving", `Resolving ${opts.resolving} reference(s)…`));
  for (const node of diff.roots) container.append(renderNode(node, diff));
  for (const c of diff.loose) container.append(renderComponent(c, diff));
  if (!diff.roots.length && !diff.loose.length) {
    container.append(note("pl-empty", "No semantic changes"));
  }
}

export function renderError(root: ShadowRoot, message: string): void {
  mount(root).append(note("pl-error", message));
}

export function renderLoading(root: ShadowRoot): void {
  mount(root).append(note("pl-loading", "Computing semantic diff…"));
}

/** Over-25MB guard (parent spec §5.7): doesn't auto-render, waits for an explicit click. */
export function renderTooLarge(root: ShadowRoot, bytes: number, onRender: () => void): void {
  const container = mount(root);
  const button = document.createElement("button");
  button.type = "button";
  button.className = "pl-render";
  button.textContent = "Render anyway";
  button.addEventListener("click", onRender);
  container.append(note("pl-empty", `Large file (${Math.round(bytes / (1024 * 1024))} MB).`), button);
}

function mount(root: ShadowRoot): HTMLElement {
  root.replaceChildren();
  const style = document.createElement("style");
  style.textContent = STYLES;
  const container = document.createElement("div");
  container.className = `pl-root pl-${detectTheme(document)}`;
  root.append(style, container);
  return container;
}

function note(className: string, text: string): HTMLElement {
  const p = document.createElement("p");
  p.className = className;
  p.textContent = text;
  return p;
}

function stem(path: string): string {
  const base = path.split("/").at(-1) ?? path;
  const dot = base.lastIndexOf(".");
  return dot > 0 ? base.slice(0, dot) : base;
}

function nodeName(node: NodeDiff, diff: DiffV2): string {
  if (node.name) return node.name;
  if (node.kind === "prefabInstance") {
    const p = node.sourceGuid ? diff.resolved?.[node.sourceGuid] : undefined;
    return p ? stem(p) : "Prefab Instance";
  }
  return "(GameObject)";
}

function renderNode(node: NodeDiff, diff: DiffV2): HTMLElement {
  const details = openDetails(node.kind === "prefabInstance" ? "pl-pi" : "pl-go", node.status);
  const summary = summaryLine(node.status, nodeName(node, diff));
  if (node.kind === "prefabInstance") {
    const badge = document.createElement("span");
    badge.className = "pl-script";
    const p = node.sourceGuid ? diff.resolved?.[node.sourceGuid] : undefined;
    badge.textContent = p ? `‹Prefab: ${p}›` : "‹Prefab›";
    summary.append(badge);
  }
  details.append(summary);

  // Display-hierarchy rule: component/override cards live only under the components section.
  const cards: HTMLElement[] = [];
  if (node.kind === "prefabInstance") cards.push(...renderOverrideGroups(node.overrides, diff));
  cards.push(...node.components.map((c) => renderComponent(c, diff)));
  if (cards.length) {
    const section = document.createElement("div");
    section.className = "pl-components";
    const label = document.createElement("div");
    label.className = "pl-components-label";
    label.textContent = "components";
    section.append(label, ...cards);
    details.append(section);
  }
  for (const child of node.children) details.append(renderNode(child, diff));
  return details;
}

function renderOverrideGroups(overrides: OverrideDiff[], diff: DiffV2): HTMLElement[] {
  const groups: { name: string; rows: OverrideDiff[] }[] = [];
  for (const ov of overrides) {
    const last = groups.at(-1);
    if (last && last.name === ov.group) last.rows.push(ov);
    else groups.push({ name: ov.group, rows: [ov] });
  }
  return groups.map(({ name, rows }) => {
    // The heading status: that status if uniform within the group, otherwise modified.
    const [first] = rows;
    const status = first && rows.every((r) => r.status === first.status) ? first.status : "modified";
    const el = openDetails("pl-comp", status);
    el.open = true; // override cards are always open (spec: light, just a collapsed summary)
    el.append(summaryLine(status, name));
    for (const r of rows) el.append(fieldRow(r.label, r.status, r.before, r.after, diff));
    return el;
  });
}

function renderComponent(c: ComponentDiff, diff: DiffV2): HTMLElement {
  const details = openDetails("pl-comp", c.status);
  const resolved = c.scriptGuid ? diff.resolved?.[c.scriptGuid] : undefined;
  const display = resolved ? stem(resolved) : (c.className ?? c.typeName);
  const summary = summaryLine(c.status, display);
  if (c.scriptGuid) {
    const script = document.createElement("span");
    script.className = "pl-script";
    script.textContent = "‹Script›";
    summary.append(script);
  }
  details.append(summary);
  for (const f of c.fields) details.append(fieldRow(f.path, f.status, f.before, f.after, diff));
  return details;
}

function fieldRow(label: string, status: Status, before: FieldValue, after: FieldValue, diff: DiffV2): HTMLElement {
  const row = document.createElement("div");
  row.className = `pl-field pl-${status}`;
  const path = document.createElement("span");
  path.className = "pl-path";
  path.textContent = label;
  row.append(path);
  // A structure summary row (before=after=null) has the count in its label and no value.
  if (before === null && after === null) return row;
  if (status === "modified") {
    row.append(valueSpan("pl-before", before, diff));
    const arrow = document.createElement("span");
    arrow.className = "pl-arrow";
    arrow.textContent = "→";
    row.append(arrow);
    row.append(valueSpan("pl-after", after, diff));
  } else if (status === "added") {
    row.append(valueSpan("pl-after", after, diff));
  } else if (status === "removed") {
    row.append(valueSpan("pl-before", before, diff));
  }
  return row;
}

function openDetails(kind: string, status: Status): HTMLDetailsElement {
  const details = document.createElement("details");
  details.open = true;
  details.className = `${kind} pl-${status}`;
  return details;
}

function summaryLine(status: Status, text: string): HTMLElement {
  const summary = document.createElement("summary");
  const badge = document.createElement("span");
  badge.className = "pl-badge";
  badge.textContent = BADGE[status];
  const label = document.createElement("span");
  label.textContent = text;
  summary.append(badge, label);
  return summary;
}

function valueSpan(className: string, value: FieldValue, diff: DiffV2): HTMLElement {
  const span = document.createElement("span");
  span.className = className;
  span.textContent = formatValue(value, diff);
  return span;
}

function formatValue(value: FieldValue, diff: DiffV2): string {
  if (value === null) return "—";
  if (typeof value === "string") return value;
  const { fileId, guid } = value.ref;
  if (guid === null) return `#${fileId}`; // local reference
  return diff.resolved?.[guid] ?? `guid:${guid}`; // external reference (unresolved stays a raw guid)
}
