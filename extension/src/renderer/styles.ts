/** Shadow-DOM stylesheet. Colors read Primer CSS variables (custom properties
 *  inherit through the shadow boundary on github.com, so every GitHub theme is
 *  followed automatically) and fall back to a built-in light/dark palette. */
export const STYLES = `
  :host { all: initial; }
  .pl-root {
    --pl-fg: var(--fgColor-default, #1f2328);
    --pl-muted: var(--fgColor-muted, #59636e);
    --pl-accent: var(--fgColor-accent, #0969da);
    --pl-hairline: var(--borderColor-muted, #d8dee4);
    --pl-hover: var(--bgColor-muted, #f6f8fa);
    --pl-skeleton: var(--bgColor-neutral-muted, rgba(129, 139, 152, 0.18));
    --pl-added: var(--fgColor-success, #1a7f37);
    --pl-removed: var(--fgColor-danger, #cf222e);
    --pl-modified: var(--fgColor-attention, #9a6700);
    --pl-added-bg: var(--bgColor-success-muted, #dafbe1);
    --pl-removed-bg: var(--bgColor-danger-muted, #ffebe9);
    --pl-modified-bg: var(--bgColor-attention-muted, #fff8c5);
    --pl-font: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
    --pl-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    font: 12px/1.5 var(--pl-font);
    color: var(--pl-fg); padding: 8px 12px; display: block;
  }
  .pl-root.pl-dark {
    --pl-fg: var(--fgColor-default, #f0f6fc);
    --pl-muted: var(--fgColor-muted, #9198a1);
    --pl-accent: var(--fgColor-accent, #4493f8);
    --pl-hairline: var(--borderColor-muted, #3d444d);
    --pl-hover: var(--bgColor-muted, #151b23);
    --pl-skeleton: var(--bgColor-neutral-muted, rgba(101, 108, 118, 0.25));
    --pl-added: var(--fgColor-success, #3fb950);
    --pl-removed: var(--fgColor-danger, #f85149);
    --pl-modified: var(--fgColor-attention, #d29922);
    --pl-added-bg: var(--bgColor-success-muted, rgba(46, 160, 67, 0.15));
    --pl-removed-bg: var(--bgColor-danger-muted, rgba(248, 81, 73, 0.15));
    --pl-modified-bg: var(--bgColor-attention-muted, rgba(187, 128, 9, 0.15));
  }
  details { margin: 0; }
  summary { list-style: none; }
  summary::-webkit-details-marker { display: none; }
  .pl-row {
    display: grid;
    grid-template-columns: 16px 18px 1fr auto;
    align-items: center;
    min-height: 24px;
    padding: 0 4px;
    border-radius: 4px;
    cursor: pointer;
    user-select: none;
  }
  .pl-row:hover { background: var(--pl-hover); }
  .pl-chevron {
    display: inline-flex; justify-content: center; align-items: center;
    color: var(--pl-muted); transition: transform 120ms ease;
  }
  details[open] > summary .pl-chevron { transform: rotate(90deg); }
  summary.pl-leaf { cursor: default; }
  summary.pl-leaf .pl-chevron { visibility: hidden; }
  .pl-icon { display: inline-flex; align-items: center; color: var(--pl-muted); }
  .pl-icon-prefab { color: var(--pl-accent); }
  .pl-name { min-width: 0; overflow-wrap: anywhere; }
  .pl-script { color: var(--pl-muted); margin-left: 6px; }
  .pl-badge {
    font: 600 11px/16px var(--pl-mono);
    min-width: 16px; text-align: center;
    border-radius: 4px; padding: 0 3px; margin-left: 8px;
  }
  details.pl-added > summary > .pl-badge { color: var(--pl-added); background: var(--pl-added-bg); }
  details.pl-removed > summary > .pl-badge { color: var(--pl-removed); background: var(--pl-removed-bg); }
  details.pl-modified > summary > .pl-badge { color: var(--pl-modified); background: var(--pl-modified-bg); }
  .pl-kids { margin-left: 11px; border-left: 1px solid var(--pl-hairline); padding-left: 8px; }
  .pl-components-label {
    display: grid; grid-template-columns: 16px 1fr; align-items: center;
    min-height: 22px; padding: 0 4px; border-radius: 4px;
    cursor: pointer; user-select: none;
    color: var(--pl-muted); font-size: 10px; font-weight: 600;
    text-transform: uppercase; letter-spacing: 0.6px;
  }
  .pl-components-label:hover { background: var(--pl-hover); }
  .pl-field {
    display: flex; align-items: center; flex-wrap: wrap; column-gap: 6px;
    min-height: 22px; padding: 0 4px 0 38px; border-radius: 4px;
    font-family: var(--pl-mono);
  }
  .pl-field:hover { background: var(--pl-hover); }
  .pl-path { color: var(--pl-muted); }
  .pl-before { color: var(--pl-removed); }
  .pl-after { color: var(--pl-added); }
  .pl-arrow { color: var(--pl-muted); }
  .pl-note { display: flex; align-items: center; gap: 6px; min-height: 24px; color: var(--pl-muted); }
  .pl-note-icon { display: inline-flex; align-items: center; }
  .pl-error { color: var(--pl-removed); }
  .pl-spinner {
    width: 12px; height: 12px; flex: none; border-radius: 50%;
    border: 2px solid var(--pl-hairline); border-top-color: var(--pl-muted);
    animation: pl-spin 1s linear infinite;
  }
  .pl-render {
    font: 500 12px/1 var(--pl-font);
    margin-top: 4px; padding: 5px 12px;
    border: 1px solid var(--pl-hairline); border-radius: 6px;
    background: transparent; color: var(--pl-fg); cursor: pointer;
  }
  .pl-render:hover { background: var(--pl-hover); }
  .pl-skel-row {
    display: flex; align-items: center; gap: 6px;
    min-height: 24px; padding-left: calc(var(--pl-indent) * 16px + 4px);
  }
  .pl-skel-icon { width: 14px; height: 14px; border-radius: 3px; flex: none; }
  .pl-skel-bar { height: 8px; border-radius: 4px; width: var(--pl-w); }
  .pl-skel-icon, .pl-skel-bar {
    background: linear-gradient(90deg, var(--pl-skeleton) 25%, var(--pl-hover) 45%, var(--pl-skeleton) 65%) 0 0 / 200% 100%;
    animation: pl-shimmer 1.4s linear infinite;
  }
  @keyframes pl-shimmer { to { background-position: -200% 0; } }
  @keyframes pl-spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) {
    .pl-chevron { transition: none; }
    .pl-skel-icon, .pl-skel-bar, .pl-spinner { animation: none; }
  }
`;
