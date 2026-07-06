export type View = 'raw' | 'semantic';

export type Toggle = { element: HTMLElement; set(view: View): void };

export function createToggle(onSelect: (view: View) => void, initial: View = 'raw'): Toggle {
  const wrap = document.createElement('span');
  wrap.setAttribute('data-prefablens-toggle', '');
  wrap.style.cssText = 'display:inline-flex;gap:0;margin-left:8px;vertical-align:middle;';

  const buttons: HTMLButtonElement[] = [];
  // set は表示のみ更新する: 全体適用時に onSelect(再フェッチ側)を巻き込まないため
  const select = (view: View): void => {
    for (const b of buttons) {
      const active = b.dataset['view'] === view;
      b.setAttribute('aria-pressed', String(active));
      b.style.fontWeight = active ? '600' : '400';
    }
  };
  const make = (view: View, label: string): HTMLButtonElement => {
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
  select(initial);
  return { element: wrap, set: select };
}
