import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { zipSync } from 'fflate';
import { afterAll, expect, test } from 'vitest';
import { binaryName, cachePath, downloadUrl, installFromZip, releaseAssetName, runCli } from './cli.js';

const dir = mkdtempSync(path.join(tmpdir(), 'prefablens-cli-test-'));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

test('releaseAssetName maps platform/arch to the four release zips', () => {
  expect(releaseAssetName('win32', 'x64')).toBe('prefablens-windows-x64.zip');
  expect(releaseAssetName('darwin', 'arm64')).toBe('prefablens-macos-arm64.zip');
  expect(releaseAssetName('darwin', 'x64')).toBe('prefablens-macos-x64.zip');
  expect(releaseAssetName('linux', 'x64')).toBe('prefablens-linux-x64.zip');
});

test('downloadUrl points at the tagged GitHub release', () => {
  expect(downloadUrl('0.1.0', 'prefablens-macos-arm64.zip')).toBe(
    'https://github.com/hashiiiii/PrefabLens/releases/download/v0.1.0/prefablens-macos-arm64.zip',
  );
});

test('binaryName appends .exe only on windows', () => {
  expect(binaryName('win32')).toBe('prefablens.exe');
  expect(binaryName('darwin')).toBe('prefablens');
});

test('cachePath is versioned under <home>/.cache/prefablens', () => {
  expect(cachePath('0.1.0', 'linux', '/home/u')).toBe(
    path.join('/home/u', '.cache', 'prefablens', '0.1.0', 'prefablens'),
  );
});

test('installFromZip extracts the binary atomically and marks it executable', () => {
  const zip = zipSync({ prefablens: new TextEncoder().encode('#!/bin/sh\necho ok\n') });
  const dest = path.join(dir, 'v1', 'prefablens');
  installFromZip(zip, dest, 'linux');
  expect(readFileSync(dest, 'utf8')).toContain('echo ok');
  expect(statSync(dest).mode & 0o111).not.toBe(0);
});

test('installFromZip rejects a zip without the expected binary', () => {
  const zip = zipSync({ other: new Uint8Array([1]) });
  expect(() => installFromZip(zip, path.join(dir, 'v2', 'prefablens'), 'linux')).toThrow('not found');
});

test('runCli captures stdout and exit code', async () => {
  const res = await runCli('git', ['--version'], process.cwd());
  expect(res.code).toBe(0);
  expect(res.stdout).toContain('git version');
});
