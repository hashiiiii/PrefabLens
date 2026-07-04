import { expect, test } from 'vitest';
import { buildArgs, truncateTree } from './diff.js';

test('buildArgs: tree + working-tree comparison', () => {
  expect(buildArgs({ path: 'A.prefab', before: 'HEAD', format: 'tree' })).toEqual([
    '--no-color', '--project', '.', '--git', 'HEAD', 'A.prefab',
  ]);
});

test('buildArgs: json + two refs', () => {
  expect(buildArgs({ path: 'A.prefab', before: 'main', after: 'HEAD', format: 'json' })).toEqual([
    '--json', '--project', '.', '--git', 'main', 'HEAD', 'A.prefab',
  ]);
});

test('truncateTree passes short text through', () => {
  expect(truncateTree('short')).toBe('short');
});

test('truncateTree truncates long text and appends a note', () => {
  const out = truncateTree('x'.repeat(60_000));
  expect(out.startsWith('x'.repeat(100))).toBe(true);
  expect(out.length).toBeLessThan(50_100);
  expect(out).toContain('[truncated: 60000 chars total]');
});
