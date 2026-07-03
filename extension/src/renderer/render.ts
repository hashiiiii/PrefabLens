import type { ComponentDiff, DiffV1, FieldValue, GameObjectDiff, Status } from '../types';

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
  .pl-error { color: var(--pl-removed); }
`;

const BADGE: Record<Status, string> = { added: '+', removed: '−', modified: '~', unchanged: ' ' };

export function detectTheme(doc: Document): 'light' | 'dark' {
  const mode = doc.documentElement.getAttribute('data-color-mode');
  if (mode === 'dark') return 'dark';
  if (mode === 'light') return 'light';
  return doc.defaultView?.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export function render(root: ShadowRoot, diff: DiffV1): void {
  const container = mount(root);
  const doc = container.ownerDocument;
  for (const go of diff.roots) container.append(renderGameObject(doc, go, diff));
  for (const c of diff.loose) container.append(renderComponent(doc, c, diff));
  if (!diff.roots.length && !diff.loose.length) {
    container.append(note(doc, 'pl-empty', 'No semantic changes'));
  }
}

export function renderError(root: ShadowRoot, message: string): void {
  const container = mount(root);
  container.append(note(container.ownerDocument, 'pl-error', message));
}

export function renderLoading(root: ShadowRoot): void {
  const container = mount(root);
  container.append(note(container.ownerDocument, 'pl-loading', 'Computing semantic diff…'));
}

function mount(root: ShadowRoot): HTMLElement {
  root.replaceChildren();
  const doc = root.host.ownerDocument;
  const style = doc.createElement('style');
  style.textContent = STYLES;
  const container = doc.createElement('div');
  container.className = `pl-root pl-${detectTheme(doc)}`;
  root.append(style, container);
  return container;
}

function note(doc: Document, className: string, text: string): HTMLElement {
  const p = doc.createElement('p');
  p.className = className;
  p.textContent = text;
  return p;
}

function renderGameObject(doc: Document, go: GameObjectDiff, diff: DiffV1): HTMLElement {
  const details = openDetails(doc, 'pl-go', go.status);
  details.append(summaryLine(doc, go.status, go.name));
  for (const c of go.components) details.append(renderComponent(doc, c, diff));
  for (const child of go.children) details.append(renderGameObject(doc, child, diff));
  return details;
}

function renderComponent(doc: Document, c: ComponentDiff, diff: DiffV1): HTMLElement {
  const details = openDetails(doc, 'pl-comp', c.status);
  const summary = summaryLine(doc, c.status, c.typeName);
  if (c.scriptGuid) {
    const script = doc.createElement('span');
    script.className = 'pl-script';
    script.textContent = diff.resolved?.[c.scriptGuid] ?? `guid:${c.scriptGuid}`;
    summary.append(script);
  }
  details.append(summary);
  for (const f of c.fields) {
    const row = doc.createElement('div');
    row.className = `pl-field pl-${f.status}`;
    const path = doc.createElement('span');
    path.className = 'pl-path';
    path.textContent = f.path;
    row.append(path);
    row.append(valueSpan(doc, 'pl-before', f.before, diff));
    const arrow = doc.createElement('span');
    arrow.className = 'pl-arrow';
    arrow.textContent = '→';
    row.append(arrow);
    row.append(valueSpan(doc, 'pl-after', f.after, diff));
    details.append(row);
  }
  return details;
}

function openDetails(doc: Document, kind: string, status: Status): HTMLDetailsElement {
  const details = doc.createElement('details');
  details.open = true;
  details.className = `${kind} pl-${status}`;
  return details;
}

function summaryLine(doc: Document, status: Status, text: string): HTMLElement {
  const summary = doc.createElement('summary');
  const badge = doc.createElement('span');
  badge.className = 'pl-badge';
  badge.textContent = BADGE[status];
  const label = doc.createElement('span');
  label.textContent = text;
  summary.append(badge, label);
  return summary;
}

function valueSpan(doc: Document, className: string, value: FieldValue, diff: DiffV1): HTMLElement {
  const span = doc.createElement('span');
  span.className = className;
  span.textContent = formatValue(value, diff);
  return span;
}

function formatValue(value: FieldValue, diff: DiffV1): string {
  if (value === null) return '—';
  if (typeof value === 'string') return value;
  const { fileId, guid } = value.ref;
  if (guid === null) return `#${fileId}`; // ローカル参照
  return diff.resolved?.[guid] ?? `guid:${guid}`; // 外部参照(未解決は生 guid のまま)
}
