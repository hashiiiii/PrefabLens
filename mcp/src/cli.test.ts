import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { zipSync } from 'fflate';
import { afterAll, expect, test } from 'vitest';
import {
  binaryName,
  cachePath,
  download,
  downloadUrl,
  expectedSha256,
  installFromZip,
  releaseAssetName,
  runCli,
  verifySha256,
} from './cli.js';

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
  // Windows のファイルシステムに unix の実行ビットは無い(実装も win32 では chmod しない)。
  if (process.platform !== 'win32') expect(statSync(dest).mode & 0o111).not.toBe(0);
});

test('installFromZip rejects a zip without the expected binary', () => {
  const zip = zipSync({ other: new Uint8Array([1]) });
  expect(() => installFromZip(zip, path.join(dir, 'v2', 'prefablens'), 'linux')).toThrow('not found');
});

// sha256("hello") の既知値。ツール(sha256sum)出力との一致を固定するため文字列リテラルでピンする。
const HELLO_SHA256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
const HELLO = new TextEncoder().encode('hello');

test('expectedSha256 parses sha256sum output lines', () => {
  const sums = `${HELLO_SHA256}  prefablens-macos-arm64.zip\naaaa  garbage\n${'0'.repeat(64)}  prefablens-linux-x64.zip\n`;
  expect(expectedSha256(sums, 'prefablens-macos-arm64.zip')).toBe(HELLO_SHA256);
  expect(expectedSha256(sums, 'prefablens-linux-x64.zip')).toBe('0'.repeat(64));
  expect(expectedSha256(sums, 'prefablens-windows-x64.zip')).toBeUndefined();
});

test('verifySha256 accepts a matching zip', () => {
  expect(() => verifySha256(HELLO, `${HELLO_SHA256}  asset.zip`, 'asset.zip')).not.toThrow();
});

test('verifySha256 rejects a tampered zip', () => {
  const tampered = new TextEncoder().encode('hellO');
  expect(() => verifySha256(tampered, `${HELLO_SHA256}  asset.zip`, 'asset.zip')).toThrow('checksum mismatch');
});

test('verifySha256 rejects a checksum file without the asset entry', () => {
  expect(() => verifySha256(HELLO, `${HELLO_SHA256}  other.zip`, 'asset.zip')).toThrow('no checksum entry');
});

test('runCli captures stdout and exit code', async () => {
  const res = await runCli('git', ['--version'], process.cwd());
  expect(res.code).toBe(0);
  expect(res.stdout).toContain('git version');
});

test('runCli kills a hung process and rejects after the timeout', async () => {
  // 実プロセス(60 秒 sleep する node)を 200ms タイムアウトで打ち切る。
  await expect(
    runCli(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], process.cwd(), 200),
  ).rejects.toThrow('timed out after 200ms');
});

test('runCli rejects on timeout even when a grandchild keeps stdio open', async () => {
  // SIGKILL が殺せるのは直接の子だけ。stdio を継承した孫がパイプを掴んだままだと
  // 'close' はパイプ全閉塞まで発火しないので、close を待たずに reject できることを確認する。
  const script =
    "const{spawn}=require('node:child_process');" +
    "spawn(process.execPath,['-e','setTimeout(()=>{},3000)'],{stdio:['ignore','inherit','inherit']});" +
    'setTimeout(()=>{},3000);';
  await expect(
    runCli(process.execPath, ['-e', script], process.cwd(), 200),
  ).rejects.toThrow('timed out after 200ms');
}, 2000);

test('runCli includes captured stderr in the timeout error', async () => {
  // ハング原因の手がかり(例: git の lock 待ち)を timeout エラーでも失わない。
  const script = "process.stderr.write('lock held');setTimeout(()=>{},3000);";
  await expect(
    runCli(process.execPath, ['-e', script], process.cwd(), 300),
  ).rejects.toThrow('lock held');
});

/** 実 HTTP サーバーを空きポートで起動し、テスト後に閉じるための最小ヘルパー。 */
async function withServer(
  handler: Parameters<typeof createServer>[1],
  run: (baseUrl: string) => Promise<void>,
): Promise<void> {
  const srv: Server = createServer(handler);
  await new Promise<void>((resolve) => srv.listen(0, '127.0.0.1', resolve));
  try {
    await run(`http://127.0.0.1:${(srv.address() as AddressInfo).port}`);
  } finally {
    srv.closeAllConnections();
    srv.close();
  }
}

test('download returns the response body bytes', async () => {
  await withServer(
    (_req, res) => res.end('zip-bytes'),
    async (base) => {
      const bytes = await download(`${base}/asset.zip`);
      expect(new TextDecoder().decode(bytes)).toBe('zip-bytes');
    },
  );
});

test('download surfaces HTTP errors with status and url', async () => {
  await withServer(
    (_req, res) => {
      res.statusCode = 404;
      res.end();
    },
    async (base) => {
      // ensureCli が「404 = SHA256SUMS 未同梱の旧リリース」だけを skip 対象にできるよう status を載せる。
      await expect(download(`${base}/missing.zip`)).rejects.toMatchObject({
        message: expect.stringContaining('download failed: HTTP 404'),
        status: 404,
      });
    },
  );
});

test('download rejects when the body stalls past the timeout', async () => {
  // ヘッダーは返すが body を完結させないサーバー。body 読み取り中の abort が
  // 'TypeError: terminated' 等に化けず timeout エラーに正規化されることを確認する。
  await withServer(
    (_req, res) => {
      res.writeHead(200, { 'content-length': '10' });
      res.write('abc');
    },
    async (base) => {
      await expect(download(`${base}/slow.zip`, 200)).rejects.toThrow('download timed out after 200ms');
    },
  );
});

test('download rejects when the server never responds within the timeout', async () => {
  // リクエストを受け付けるがレスポンスを一切書かない実サーバーでハングを再現する。
  await withServer(
    () => {},
    async (base) => {
      await expect(download(`${base}/hang.zip`, 200)).rejects.toThrow('download timed out after 200ms');
    },
  );
});
