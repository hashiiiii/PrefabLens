// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import { detectTheme, render, renderError } from './render';
import type { DiffV2 } from '../types';

const DIFF: DiffV2 = {
  schema: 'prefablens.diff.v2',
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
          className: null,
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

const INSTANCE: DiffV2 = {
  schema: 'prefablens.diff.v2',
  unresolvedGuids: ['aaa'],
  resolved: { aaa: 'Assets/Cylinder Variant.prefab' },
  roots: [
    {
      kind: 'gameObject',
      fileId: '1',
      name: 'Plane',
      status: 'unchanged',
      components: [],
      children: [
        {
          kind: 'prefabInstance',
          fileId: '1001',
          name: 'Cylinder Variant',
          status: 'added',
          sourceGuid: 'aaa',
          overrides: [
            { group: 'Transform', label: 'Position', status: 'added', before: null, after: '(2.03, 3.63, 1.12)' },
          ],
          components: [],
          children: [],
        },
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

  it('shows field values as before → after and resolves the component to its script stem', () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector('.pl-root')!.textContent!;
    expect(text).toContain('volume');
    expect(text).toContain('0.5');
    expect(text).toContain('0.8');
    expect(text).toContain('Sound'); // resolved guid → file stem, not the full path
    expect(text).toContain('‹Script›');
  });

  it('shows only the current value for added fields, without a before placeholder', () => {
    const root = freshRoot();
    render(root, DIFF);
    const rows = [...root.querySelectorAll('.pl-field')];
    const added = rows.find((r) => r.textContent!.includes('newField'))!;
    expect(added.textContent).toBe('newField1');
  });

  it('falls back to the raw guid when unresolved and to #fileId for local refs', () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector('.pl-root')!.textContent!;
    expect(text).toContain('#100'); // local ref
    expect(text).toContain('ghi'); // unresolved guid stays visible
  });

  it('renders repo-controlled strings as text, never as markup', () => {
    const hostile: DiffV2 = {
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
    render(root, { schema: 'prefablens.diff.v2', unresolvedGuids: [], roots: [], loose: [] });
    expect(root.querySelectorAll('details')).toHaveLength(0);
    expect(root.textContent).toContain('No semantic changes');
  });

  it('renderError shows a clean one-line message', () => {
    const root = freshRoot();
    renderError(root, 'Set a GitHub token in the PrefabLens options page.');
    expect(root.textContent).toContain('Set a GitHub token');
  });

  it('renders prefab instance with badge, components section and open override card', () => {
    const root = freshRoot();
    render(root, INSTANCE);
    const text = root.textContent ?? '';
    expect(text).toContain('Cylinder Variant');
    expect(text).toContain('‹Prefab: Assets/Cylinder Variant.prefab›');
    expect(text).toContain('components');
    expect(text).toContain('Transform');
    expect(text).toContain('Position');
    // override カードは開いている。
    const card = root.querySelector('.pl-components details') as HTMLDetailsElement;
    expect(card.open).toBe(true);
  });

  it('renders structural summary rows as label only, without a value placeholder', () => {
    const diff: DiffV2 = {
      schema: 'prefablens.diff.v2',
      unresolvedGuids: [],
      roots: [
        {
          kind: 'prefabInstance',
          fileId: '1001',
          name: 'Cylinder',
          status: 'modified',
          sourceGuid: null,
          overrides: [{ group: 'Overrides', label: 'Added Components (1)', status: 'added', before: null, after: null }],
          components: [],
          children: [],
        },
      ],
      loose: [],
    };
    const root = freshRoot();
    render(root, diff);
    const row = root.querySelector('.pl-field');
    expect(row?.textContent).toContain('Added Components (1)');
    expect(row?.textContent).not.toContain('—');
  });

  it('collapses added component cards but keeps modified ones open', () => {
    const root = freshRoot();
    const diff: DiffV2 = {
      schema: 'prefablens.diff.v2',
      unresolvedGuids: [],
      roots: [
        {
          kind: 'gameObject',
          fileId: '1',
          name: 'Cylinder',
          status: 'modified',
          components: [
            {
              kind: 'component', fileId: '8', classId: 114, typeName: 'MonoBehaviour',
              scriptGuid: null, className: 'Cylinder1', status: 'added',
              fields: [{ path: 'Enabled', status: 'added', before: null, after: '1' }],
            },
            {
              kind: 'component', fileId: '4', classId: 4, typeName: 'Transform',
              scriptGuid: null, className: null, status: 'modified',
              fields: [{ path: 'Position.x', status: 'modified', before: '0.64596', after: '1' }],
            },
          ],
          children: [],
        },
      ],
      loose: [],
    };
    render(root, diff);
    const cards = [...root.querySelectorAll('.pl-components > details')] as HTMLDetailsElement[];
    expect(cards).toHaveLength(2);
    expect(cards[0]!.open).toBe(false); // added Cylinder1 は閉
    expect(cards[0]!.textContent).toContain('Cylinder1'); // className フォールバック
    expect(cards[1]!.open).toBe(true); // modified Transform は開
  });

  it('falls back instance name to resolved source prefab stem', () => {
    const root = freshRoot();
    const diff: DiffV2 = {
      schema: 'prefablens.diff.v2',
      unresolvedGuids: ['bbb'],
      resolved: { bbb: 'Assets/Enemy.prefab' },
      roots: [
        {
          kind: 'prefabInstance', fileId: '1001', name: '', status: 'added',
          sourceGuid: 'bbb', overrides: [], components: [], children: [],
        },
      ],
      loose: [],
    };
    render(root, diff);
    expect(root.textContent).toContain('Enemy');
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
