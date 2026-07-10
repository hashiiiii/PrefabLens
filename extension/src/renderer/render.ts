import type { ComponentDiff, DiffV2, FieldValue, NodeDiff, OverrideDiff, Status } from "../types";
import { ALERT, CHECK, CHEVRON, CUBE, GEAR } from "./icons";
import { STYLES } from "./styles";

// Unchanged rows carry no chip: the absence of a badge is the "unchanged" signal.
const BADGE: Record<Exclude<Status, "unchanged">, string> = { added: "+", removed: "−", modified: "~" };

export function detectTheme(doc: Document): "light" | "dark" {
  const mode = doc.documentElement.getAttribute("data-color-mode");
  if (mode === "dark") return "dark";
  if (mode === "light") return "light";
  return doc.defaultView?.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function render(root: ShadowRoot, diff: DiffV2, opts?: { resolving?: number }): void {
  const container = mount(root);
  // Resolving indicator: the diff body is correct from the start, only reference names fill in later
  if (opts?.resolving) {
    const busy = note("pl-resolving", `Resolving ${opts.resolving} reference(s)…`);
    const spin = document.createElement("span");
    spin.className = "pl-spinner";
    busy.prepend(spin);
    container.append(busy);
  }
  for (const node of diff.roots) container.append(renderNode(node, diff));
  const loose = diff.loose.map((c) => renderComponent(c, diff));
  if (loose.length) container.append(componentsSection(loose));
  if (!diff.roots.length && !diff.loose.length) {
    container.append(note("pl-empty", "No semantic changes", CHECK));
  }
}

export function renderError(root: ShadowRoot, message: string): void {
  mount(root).append(note("pl-error", message, ALERT));
}

// Deterministic tree-shaped placeholder: [indent level, name-bar width %]
const SKELETON_ROWS: Array<[number, number]> = [
  [0, 40],
  [1, 55],
  [2, 35],
  [1, 60],
  [0, 30],
];

export function renderLoading(root: ShadowRoot): void {
  const box = document.createElement("div");
  box.className = "pl-skeleton";
  box.setAttribute("role", "status");
  box.setAttribute("aria-label", "Computing semantic diff…");
  box.setAttribute("aria-busy", "true");
  for (const [indent, width] of SKELETON_ROWS) {
    const row = document.createElement("div");
    row.className = "pl-skel-row";
    row.style.setProperty("--pl-indent", String(indent));
    const icon = document.createElement("span");
    icon.className = "pl-skel-icon";
    const bar = document.createElement("span");
    bar.className = "pl-skel-bar";
    bar.style.setProperty("--pl-w", `${width}%`);
    row.append(icon, bar);
    box.append(row);
  }
  mount(root).append(box);
}

/** Over-25MB guard: doesn't auto-render, waits for an explicit click. */
export function renderTooLarge(root: ShadowRoot, bytes: number, onRender: () => void): void {
  const container = mount(root);
  const button = document.createElement("button");
  button.type = "button";
  button.className = "pl-render";
  button.textContent = "Render anyway";
  button.addEventListener("click", onRender);
  container.append(note("pl-empty", `Large file (${Math.round(bytes / (1024 * 1024))} MB).`, ALERT), button);
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

function note(className: string, text: string, icon?: string): HTMLElement {
  const div = document.createElement("div");
  div.className = `pl-note ${className}`;
  if (icon) div.append(glyph(icon, "pl-note-icon"));
  const span = document.createElement("span");
  span.textContent = text;
  div.append(span);
  return div;
}

function glyph(markup: string, className: string): HTMLElement {
  const span = document.createElement("span");
  span.className = className;
  span.innerHTML = markup; // static constants from icons.ts only
  return span;
}

function summaryRow(status: Status, icon: string, iconClass: string, name: string, meta?: string): HTMLElement {
  const summary = document.createElement("summary");
  summary.className = "pl-row";
  summary.append(glyph(CHEVRON, "pl-chevron"), glyph(icon, iconClass));
  const label = document.createElement("span");
  label.className = "pl-name";
  label.textContent = name;
  if (meta) {
    const m = document.createElement("span");
    m.className = "pl-script";
    m.textContent = meta;
    label.append(m);
  }
  summary.append(label);
  if (status !== "unchanged") {
    const badge = document.createElement("span");
    badge.className = "pl-badge";
    badge.textContent = BADGE[status];
    summary.append(badge);
  }
  return summary;
}

/** Appends kids into the details, or marks the summary as a leaf when there are none. */
function finish(details: HTMLDetailsElement, summary: HTMLElement, kids: HTMLElement): HTMLDetailsElement {
  details.append(summary);
  if (kids.childElementCount) details.append(kids);
  else summary.classList.add("pl-leaf");
  return details;
}

function kidsBox(): HTMLElement {
  const div = document.createElement("div");
  div.className = "pl-kids";
  return div;
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
  const isPrefab = node.kind === "prefabInstance";
  const details = openDetails(isPrefab ? "pl-pi" : "pl-go", node.status);
  let meta: string | undefined;
  if (node.kind === "prefabInstance") {
    const p = node.sourceGuid ? diff.resolved?.[node.sourceGuid] : undefined;
    meta = p ? `‹Prefab: ${p}›` : "‹Prefab›";
  }
  const summary = summaryRow(
    node.status,
    CUBE,
    isPrefab ? "pl-icon pl-icon-prefab" : "pl-icon",
    nodeName(node, diff),
    meta,
  );

  const kids = kidsBox();
  // Display-hierarchy rule: component/override cards live only under the components section.
  const cards: HTMLElement[] = [];
  if (node.kind === "prefabInstance") cards.push(...renderOverrideGroups(node.overrides, diff));
  cards.push(...node.components.map((c) => renderComponent(c, diff)));
  if (cards.length) kids.append(componentsSection(cards));
  for (const child of node.children) kids.append(renderNode(child, diff));
  return finish(details, summary, kids);
}

/** Components fold as their own group one level below the object row, so cube rows
 *  alone form the hierarchy spine (Unity puts components in the Inspector, not the tree). */
function componentsSection(cards: HTMLElement[]): HTMLElement {
  const details = document.createElement("details");
  details.open = true;
  details.className = "pl-components";
  const summary = document.createElement("summary");
  summary.className = "pl-components-label";
  summary.append(glyph(CHEVRON, "pl-chevron"));
  const label = document.createElement("span");
  label.textContent = `components (${cards.length})`;
  summary.append(label);
  const kids = kidsBox();
  kids.append(...cards);
  details.append(summary, kids);
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
    const kids = kidsBox();
    for (const r of rows) kids.append(fieldRow(r.label, r.status, r.before, r.after, diff));
    return finish(el, summaryRow(status, GEAR, "pl-icon", name), kids);
  });
}

function renderComponent(c: ComponentDiff, diff: DiffV2): HTMLElement {
  const details = openDetails("pl-comp", c.status);
  const resolved = c.scriptGuid ? diff.resolved?.[c.scriptGuid] : undefined;
  const display = resolved ? stem(resolved) : (c.className ?? c.typeName);
  const summary = summaryRow(c.status, GEAR, "pl-icon", display, c.scriptGuid ? "‹Script›" : undefined);
  const kids = kidsBox();
  for (const f of c.fields) kids.append(fieldRow(f.path, f.status, f.before, f.after, diff));
  return finish(details, summary, kids);
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
