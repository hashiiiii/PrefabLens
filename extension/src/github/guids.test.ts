import { describe, expect, it } from 'vitest';
import { applyResolved, buildGuidIndex, parseGuidFromMeta } from './guids';
import type { DiffV1 } from '../types';

const META = `fileFormatVersion: 2
guid: 1234567890abcdef1234567890abcdef
MonoImporter:
  serializedVersion: 2`;

describe('parseGuidFromMeta', () => {
  it('extracts the guid line', () => {
    expect(parseGuidFromMeta(META)).toBe('1234567890abcdef1234567890abcdef');
  });
  it('returns undefined when absent', () => {
    expect(parseGuidFromMeta('fileFormatVersion: 2\n')).toBeUndefined();
  });
});

describe('buildGuidIndex', () => {
  const files = [
    { path: 'Assets/Scripts/Player.cs', status: 'modified' },
    { path: 'Assets/Scripts/Player.cs.meta', status: 'modified' },
    { path: 'Assets/Old.cs.meta', status: 'removed' },
  ];

  it('indexes changed .meta files, reading removed metas from the base side', async () => {
    const fetched: Array<[string, string]> = [];
    const index = await buildGuidIndex(files, async (path, side) => {
      fetched.push([path, side]);
      if (path === 'Assets/Scripts/Player.cs.meta') return META;
      if (path === 'Assets/Old.cs.meta') return 'guid: oldguid\n';
      return null;
    });
    expect(index.get('1234567890abcdef1234567890abcdef')).toBe('Assets/Scripts/Player.cs');
    expect(index.get('oldguid')).toBe('Assets/Old.cs');
    expect(fetched).toContainEqual(['Assets/Scripts/Player.cs.meta', 'head']);
    expect(fetched).toContainEqual(['Assets/Old.cs.meta', 'base']);
    expect(fetched).toHaveLength(2); // .meta 以外は fetch しない
  });

  it('skips metas that fail to fetch or parse', async () => {
    const index = await buildGuidIndex(files, async () => {
      throw new Error('boom');
    });
    expect(index.size).toBe(0);
  });
});

describe('applyResolved', () => {
  const diff: DiffV1 = {
    schema: 'prefablens.diff.v1',
    unresolvedGuids: ['aaa', 'bbb'],
    roots: [],
    loose: [],
  };

  it('attaches only referenced-and-resolvable guids (scoped like core)', () => {
    const index = new Map([
      ['aaa', 'Assets/A.cs'],
      ['zzz', 'Assets/Z.cs'],
    ]);
    const out = applyResolved(diff, index);
    expect(out.resolved).toEqual({ aaa: 'Assets/A.cs' }); // bbb 未解決、zzz は参照外
    expect(out).not.toBe(diff); // 入力は破壊しない
    expect(diff.resolved).toBeUndefined();
  });
});
