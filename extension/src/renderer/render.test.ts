// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import { detectTheme, render, renderError } from './render';
import type { DiffV1 } from '../types';

const DIFF: DiffV1 = {
  schema: 'prefablens.diff.v1',
  unresolvedGuids: ['def', 'ghi'],
  resolved: { def: 'Assets/Scripts/Sound.cs' },
  roots: [
    {
      kind: 'gameObject',
      fileId: '1',
      name: 'Player',
      status: 'modified',
      components: [
        {
          kind: 'component',
          fileId: '2',
          classId: 114,
          typeName: 'MonoBehaviour',
          scriptGuid: 'def',
          status: 'modified',
          fields: [
            { path: 'volume', status: 'modified', before: '0.5', after: '0.8' },
            { path: 'm_Target', status: 'modified', before: { ref: { fileId: '100', guid: null, type: null } }, after: { ref: { fileId: '0', guid: 'ghi', type: 2 } } },
            { path: 'newField', status: 'added', before: null, after: '1' },
          ],
        },
      ],
      children: [
        { kind: 'gameObject', fileId: '3', name: 'Weapon', status: 'added', components: [], children: [] },
      ],
    },
  ],
  loose: [],
};

function freshRoot(): ShadowRoot {
  const host = document.createElement('div');
  document.body.append(host);
  return host.attachShadow({ mode: 'open' });
}

describe('render', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
    document.documentElement.removeAttribute('data-color-mode');
  });

  it('renders the GameObject hierarchy with statuses', () => {
    const root = freshRoot();
    render(root, DIFF);
    const gos = root.querySelectorAll('details.pl-go');
    expect(gos).toHaveLength(2);
    expect(gos[0]!.querySelector('summary')!.textContent).toContain('Player');
    expect(gos[1]!.classList.contains('pl-added')).toBe(true);
  });

  it('shows field values as before → after and resolves script guids', () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector('.pl-root')!.textContent!;
    expect(text).toContain('volume');
    expect(text).toContain('0.5');
    expect(text).toContain('0.8');
    expect(text).toContain('Assets/Scripts/Sound.cs'); // resolved guid
  });

  it('falls back to the raw guid when unresolved and to #fileId for local refs', () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector('.pl-root')!.textContent!;
    expect(text).toContain('#100'); // local ref
    expect(text).toContain('ghi'); // unresolved guid stays visible
  });

  it('renders repo-controlled strings as text, never as markup', () => {
    const hostile: DiffV1 = {
      ...DIFF,
      roots: [{ kind: 'gameObject', fileId: '1', name: '<img src=x onerror=alert(1)>', status: 'added', components: [], children: [] }],
    };
    const root = freshRoot();
    render(root, hostile);
    expect(root.querySelector('img')).toBeNull();
    expect(root.textContent).toContain('<img src=x onerror=alert(1)>');
  });

  it('replaces previous content on re-render and shows an empty note for empty diffs', () => {
    const root = freshRoot();
    render(root, DIFF);
    render(root, { schema: 'prefablens.diff.v1', unresolvedGuids: [], roots: [], loose: [] });
    expect(root.querySelectorAll('details')).toHaveLength(0);
    expect(root.textContent).toContain('No semantic changes');
  });

  it('renderError shows a clean one-line message', () => {
    const root = freshRoot();
    renderError(root, 'Set a GitHub token in the PrefabLens options page.');
    expect(root.textContent).toContain('Set a GitHub token');
  });
});

describe('detectTheme', () => {
  it('follows html[data-color-mode]', () => {
    document.documentElement.setAttribute('data-color-mode', 'dark');
    expect(detectTheme(document)).toBe('dark');
    document.documentElement.setAttribute('data-color-mode', 'light');
    expect(detectTheme(document)).toBe('light');
  });
});
