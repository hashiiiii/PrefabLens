import { describe, expect, it } from 'vitest';
import { applyResolved, buildGuidIndex, parseGuidFromMeta } from './guids';
import { RateLimitError } from './client';
import type { DiffV2 } from '../types';

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

  it('propagates rate limits instead of degrading the index silently', async () => {
    // 握りつぶすと劣化インデックスが SW 生存期間キャッシュされ、再トグルでも直らない
    await expect(
      buildGuidIndex(files, async () => {
        throw new RateLimitError('limited');
      }),
    ).rejects.toBeInstanceOf(RateLimitError);
  });

  it('bounds concurrent fetches to 8 even with many changed metas', async () => {
    const manyFiles = Array.from({ length: 20 }, (_, i) => ({
      path: `Assets/Scripts/File${i}.cs.meta`,
      status: 'modified',
    }));
    let inFlight = 0;
    let maxInFlight = 0;
    const index = await buildGuidIndex(manyFiles, async (path, _side) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 0));
      inFlight--;
      const i = path.match(/File(\d+)\.cs\.meta/)![1];
      return `guid: g${i}\n`;
    });
    expect(maxInFlight).toBeLessThanOrEqual(8);
    expect(index.size).toBe(20);
  });
});

describe('applyResolved', () => {
  const diff: DiffV2 = {
    schema: 'prefablens.diff.v2',
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
