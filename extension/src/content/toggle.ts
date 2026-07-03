export type View = 'raw' | 'semantic';

export function createToggle(onSelect: (view: View) => void): HTMLElement {
  const wrap = document.createElement('span');
  wrap.setAttribute('data-prefablens-toggle', '');
  wrap.style.cssText = 'display:inline-flex;gap:0;margin-left:8px;vertical-align:middle;';

  const buttons: HTMLButtonElement[] = [];
  const select = (view: View) => {
    for (const b of buttons) {
      const active = b.dataset['view'] === view;
      b.setAttribute('aria-pressed', String(active));
      b.style.fontWeight = active ? '600' : '400';
    }
  };
  const make = (view: View, label: string) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = label;
    btn.dataset['view'] = view;
    btn.style.cssText =
      'font:11px system-ui;padding:1px 8px;border:1px solid #808080;background:transparent;color:inherit;cursor:pointer;';
    btn.addEventListener('click', () => {
      select(view);
      onSelect(view);
    });
    buttons.push(btn);
    return btn;
  };

  wrap.append(make('raw', 'Raw'), make('semantic', 'Semantic'));
  select('raw'); // 既定は Raw(GitHub 既定表示のまま)
  return wrap;
}
