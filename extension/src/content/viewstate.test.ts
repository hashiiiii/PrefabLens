import { describe, expect, it, vi } from 'vitest';
import { createViewState } from './viewstate';

describe('createViewState', () => {
  it('resolves effective view as override-or-default', () => {
    const state = createViewState('raw', vi.fn());
    expect(state.effective('a.prefab')).toBe('raw');
    state.setOverride('a.prefab', 'semantic');
    expect(state.effective('a.prefab')).toBe('semantic');
    expect(state.effective('b.prefab')).toBe('raw'); // 上書きは対象ファイルだけ
  });

  it('setDefault persists, clears overrides, and notifies listeners', () => {
    // 「全体を押したら必ず全ファイルが揃う」の核: 個別上書きは全体トグルでリセットされる
    const persist = vi.fn();
    const state = createViewState('raw', persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setOverride('a.prefab', 'raw');
    state.setDefault('semantic');
    expect(persist).toHaveBeenCalledWith('semantic');
    expect(listener).toHaveBeenCalledWith('semantic');
    expect(state.effective('a.prefab')).toBe('semantic'); // 上書きは消えている
  });

  it('setDefault is a no-op when the view is unchanged', () => {
    // 冪等性: 同値の再設定で上書きが消えたり storage 書き込みが走ったりしない
    const persist = vi.fn();
    const state = createViewState('semantic', persist);
    state.setOverride('a.prefab', 'raw');
    state.setDefault('semantic');
    expect(persist).not.toHaveBeenCalled();
    expect(state.effective('a.prefab')).toBe('raw');
  });

  it('applyExternal updates without persisting (storage.onChanged echo)', () => {
    // storage.onChanged は set した本人のタブでも発火する: 再永続化すると無限ループになる
    const persist = vi.fn();
    const state = createViewState('raw', persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.applyExternal('semantic');
    expect(state.defaultView()).toBe('semantic');
    expect(persist).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith('semantic');
    listener.mockClear();
    state.applyExternal('semantic'); // 同値エコーは無視
    expect(listener).not.toHaveBeenCalled();
  });

  it('clearOverrides drops per-file overrides only', () => {
    const state = createViewState('semantic', vi.fn());
    state.setOverride('a.prefab', 'raw');
    state.clearOverrides();
    expect(state.effective('a.prefab')).toBe('semantic');
    expect(state.defaultView()).toBe('semantic');
  });
});
