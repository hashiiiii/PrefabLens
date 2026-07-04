import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { afterAll, beforeAll, expect, test } from 'vitest';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const cliPath = path.join(repoRoot, 'zig-out', 'bin', process.platform === 'win32' ? 'prefablens.exe' : 'prefablens');
const serverEntry = fileURLToPath(new URL('../dist/index.js', import.meta.url));
const testdata = path.join(repoRoot, 'core', 'src', 'testdata');

let fixtureRepo: string;
let client: Client;

function git(cwd: string, ...args: string[]): void {
  execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd });
}

function firstText(res: { content?: unknown }): string {
  const content = res.content as { type: string; text: string }[];
  return content[0]?.text ?? '';
}

beforeAll(async () => {
  fixtureRepo = mkdtempSync(path.join(tmpdir(), 'prefablens-mcp-'));
  cpSync(path.join(testdata, 'plane_before.prefab'), path.join(fixtureRepo, 'Plane.prefab'));
  git(fixtureRepo, 'init', '-q');
  git(fixtureRepo, 'add', '.');
  git(fixtureRepo, 'commit', '-q', '-m', 'init');
  cpSync(path.join(testdata, 'plane_after.prefab'), path.join(fixtureRepo, 'Plane.prefab'));

  client = new Client({ name: 'test', version: '0.0.0' });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    env: { PREFABLENS_CLI: cliPath, PATH: process.env['PATH'] ?? '' },
  }));
});

afterAll(async () => {
  await client.close();
  rmSync(fixtureRepo, { recursive: true, force: true });
});

test('prefab_diff returns the semantic tree for HEAD vs working tree', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', projectRoot: fixtureRepo },
  });
  expect(res.isError).toBeFalsy();
  // ゴールデン。実装後に実出力を目視確認してからピンする(既存 golden の流儀)。
  expect(firstText(res)).toBe([
    '  Plane',
    '  ~ Cylinder  <Prefab>',
    '      components',
    '        ~ Transform',
    '          ~ Position.x: 0.41646004 -> 1',
    '  + Cylinder Variant  <Prefab>',
    '      components',
    '        + Transform',
    '          + Position: (2.03, 3.63, 1.11797)',
    '',
  ].join('\n'));
});

test('prefab_diff format:"json" returns prefablens.diff.v2', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', projectRoot: fixtureRepo, format: 'json' },
  });
  expect(res.isError).toBeFalsy();
  const parsed = JSON.parse(firstText(res)) as { schema: string };
  expect(parsed.schema).toBe('prefablens.diff.v2');
});

test('prefab_diff rejects an empty path before reaching the cli', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: '', projectRoot: fixtureRepo },
  });
  expect(res.isError).toBe(true);
  expect(firstText(res)).toContain('Input validation error');
});

test('prefab_diff rejects an empty projectRoot before reaching the cli', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', projectRoot: '' },
  });
  expect(res.isError).toBe(true);
  expect(firstText(res)).toContain('Input validation error');
});

test('prefab_diff surfaces cli errors as tool errors', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', before: 'nosuchref', after: 'HEAD', projectRoot: fixtureRepo },
  });
  expect(res.isError).toBe(true);
  expect(firstText(res)).toContain("git show failed for 'nosuchref:Plane.prefab'");
});
