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

  it('same-value setDefault still clears overrides without persisting', () => {
    // 「全体を押したら必ず全部揃う」: 既に押されている側をもう一度押しても上書きは消える。
    // storage への再書き込みだけはしない(onChanged エコーの無駄打ち防止)
    const persist = vi.fn();
    const state = createViewState('semantic', persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setOverride('a.prefab', 'raw');
    state.setDefault('semantic');
    expect(persist).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith('semantic');
    expect(state.effective('a.prefab')).toBe('semantic');
  });

  it('same-value setDefault with no overrides is a pure no-op', () => {
    // 上書きが無ければ通知も不要: appliers の全再適用を無駄に走らせない
    const persist = vi.fn();
    const state = createViewState('semantic', persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setDefault('semantic');
    expect(persist).not.toHaveBeenCalled();
    expect(listener).not.toHaveBeenCalled();
  });

  it('applyExternal updates without persisting (storage.onChanged echo)', () => {
    // storage.onChanged は set した本人のタブでも発火する: 再永続化すると無限ループになる
    const persist = vi.fn();
    const state = createViewState('raw', persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setOverride('a.prefab', 'raw');
    state.applyExternal('semantic');
    expect(state.effective('a.prefab')).toBe('semantic'); // 他タブ由来の切り替えでも全ファイルが揃う
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
