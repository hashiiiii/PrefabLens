import type { View } from './toggle';

export type ViewState = {
  defaultView(): View;
  effective(path: string): View;
  setOverride(path: string, view: View): void;
  clearOverrides(): void;
  setDefault(view: View): void;
  applyExternal(view: View): void;
  onDefaultChange(fn: (view: View) => void): void;
};

/** 既定モード(永続)+ ページ滞在中のファイル単位上書き。全体切り替えは上書きを必ずリセットする。 */
export function createViewState(initial: View, persist: (view: View) => void): ViewState {
  let def = initial;
  const overrides = new Map<string, View>();
  const listeners: Array<(view: View) => void> = [];
  const change = (view: View): void => {
    def = view;
    overrides.clear();
    for (const fn of listeners) fn(view);
  };
  return {
    defaultView: () => def,
    effective: (path) => overrides.get(path) ?? def,
    setOverride: (path, view) => void overrides.set(path, view),
    clearOverrides: () => overrides.clear(),
    setDefault: (view) => {
      if (view === def) {
        // 同値クリックでも「全体を押したら必ず全部揃う」: 上書きを消して再適用し、storage には書かない
        if (overrides.size) change(view);
        return;
      }
      change(view);
      persist(view);
    },
    // storage.onChanged は set 元のタブでも発火するため、同値は無視して永続化もしない
    applyExternal: (view) => {
      if (view !== def) change(view);
    },
    onDefaultChange: (fn) => void listeners.push(fn),
  };
}
