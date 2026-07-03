// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';
import { createToggle } from './toggle';

describe('createToggle', () => {
  it('starts on Raw and reports selection changes', () => {
    const onSelect = vi.fn();
    const toggle = createToggle(onSelect);
    document.body.append(toggle);
    const [raw, semantic] = [...toggle.querySelectorAll('button')];
    expect(raw!.getAttribute('aria-pressed')).toBe('true');
    semantic!.click();
    expect(onSelect).toHaveBeenCalledWith('semantic');
    expect(semantic!.getAttribute('aria-pressed')).toBe('true');
    expect(raw!.getAttribute('aria-pressed')).toBe('false');
    raw!.click();
    expect(onSelect).toHaveBeenLastCalledWith('raw');
  });
});
