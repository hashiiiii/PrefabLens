import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { unzipSync } from 'fflate';

/** Editor の Cli.ReleaseAssetName と同じ対応表(release.yml のアセット 4 種)。 */
export function releaseAssetName(platform: NodeJS.Platform, arch: string): string {
  if (platform === 'win32') return 'prefablens-windows-x64.zip';
  if (platform === 'darwin') return arch === 'arm64' ? 'prefablens-macos-arm64.zip' : 'prefablens-macos-x64.zip';
  return 'prefablens-linux-x64.zip';
}

export function downloadUrl(version: string, assetName: string): string {
  return `https://github.com/hashiiiii/PrefabLens/releases/download/v${version}/${assetName}`;
}

export function binaryName(platform: NodeJS.Platform): string {
  return platform === 'win32' ? 'prefablens.exe' : 'prefablens';
}

export function cachePath(version: string, platform: NodeJS.Platform, home: string): string {
  return path.join(home, '.cache', 'prefablens', version, binaryName(platform));
}

/** temp に書いて rename する原子的配置。同時起動の二重ダウンロードは後勝ちで無害。 */
export function installFromZip(zipBytes: Uint8Array, dest: string, platform: NodeJS.Platform): void {
  const body = unzipSync(zipBytes)[binaryName(platform)];
  if (body === undefined) throw new Error(`${binaryName(platform)} not found in release zip`);
  mkdirSync(path.dirname(dest), { recursive: true });
  const tmp = `${dest}.tmp-${process.pid}`;
  writeFileSync(tmp, body);
  if (platform !== 'win32') chmodSync(tmp, 0o755);
  renameSync(tmp, dest);
}

/** ハング防止の上限。release zip は数 MB、CLI diff は通常 1 秒未満なので 60 秒は十分に保守的。 */
const TIMEOUT_MS = 60_000;

export async function download(url: string, timeoutMs = TIMEOUT_MS): Promise<Uint8Array> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    // status は呼び出し側の分岐用(404 = アセット不在)。message 文字列の解析に依存させない。
    if (!res.ok) throw Object.assign(new Error(`download failed: HTTP ${res.status} for ${url}`), { status: res.status });
    return new Uint8Array(await res.arrayBuffer());
  } catch (e) {
    // AbortSignal.timeout の reason は DOMException(name: TimeoutError)。ヘッダー待ちと body 読み取り中のどちらの abort もこれで捕捉できる。
    if (e instanceof DOMException && e.name === 'TimeoutError') {
      throw new Error(`download timed out after ${timeoutMs}ms for ${url}`);
    }
    throw e;
  }
}

/** sha256sum 形式(`‹64hex›  ‹filename›`、binary モードの `*` 前置も許容)から assetName の期待値を引く。 */
export function expectedSha256(sums: string, assetName: string): string | undefined {
  for (const line of sums.split('\n')) {
    const m = /^([0-9a-f]{64})\s+\*?(.+)$/.exec(line.trim());
    if (m !== null && m[2] === assetName) return m[1];
  }
  return undefined;
}

/** SHA256SUMS と照合する。エントリ欠落・ハッシュ不一致は throw(破損 zip を実行しない)。 */
export function verifySha256(zipBytes: Uint8Array, sums: string, assetName: string): void {
  const want = expectedSha256(sums, assetName);
  if (want === undefined) throw new Error(`no checksum entry for ${assetName} in SHA256SUMS`);
  const got = createHash('sha256').update(zipBytes).digest('hex');
  if (got !== want) throw new Error(`checksum mismatch for ${assetName}: expected ${want}, got ${got}`);
}

/**
 * env PREFABLENS_CLI → キャッシュ → GitHub Releases の順で CLI を確保する。
 * PREFABLENS_CLI が存在しないパスを指す場合はエラーにせず次の候補へフォールスルーする
 * (設定ミスでもキャッシュ/ダウンロードで動き続けることを優先)。
 */
export async function ensureCli(version: string): Promise<string> {
  const manual = process.env['PREFABLENS_CLI'];
  if (manual !== undefined && manual !== '' && existsSync(manual)) return manual;
  const dest = cachePath(version, process.platform, homedir());
  if (existsSync(dest)) return dest;
  const assetName = releaseAssetName(process.platform, process.arch);
  const zip = await download(downloadUrl(version, assetName));
  // SHA256SUMS を持たない旧リリース(v0.2.0 以前)= 404 のときだけ検証をスキップする。
  // タイムアウトや 5xx で黙ってスキップすると、チェックサムだけ妨害された場合に検証が無効化されるため伝播させる。
  let sums: string | undefined;
  try {
    sums = new TextDecoder().decode(await download(downloadUrl(version, 'SHA256SUMS')));
  } catch (e) {
    if ((e as { status?: unknown }).status !== 404) throw e;
    console.error(`prefablens-mcp: no SHA256SUMS for v${version}, skipping checksum verification`);
  }
  if (sums !== undefined) verifySha256(zip, sums, assetName);
  installFromZip(zip, dest, process.platform);
  return dest;
}

export interface CliResult {
  code: number;
  stdout: string;
  stderr: string;
}

export function runCli(cliPath: string, args: string[], cwd: string, timeoutMs = TIMEOUT_MS): Promise<CliResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cliPath, args, { cwd });
    let stdout = '';
    let stderr = '';
    // タイマー内で直接 reject する。'close' 待ちにすると、SIGKILL 後も stdio パイプを
    // 継承した孫プロセス(git 等)が掴んでいる間 'close' が発火せずハングしたままになる。
    const timer = setTimeout(() => {
      // すでに終了済みなら timeout 扱いにしない(exit と 'close' の隙間で発火したレース)。
      if (child.exitCode !== null || child.signalCode !== null) return;
      child.kill('SIGKILL');
      // 読み取り側ハンドルを閉じ、孫プロセスが残ってもイベントループを塞がないようにする。
      child.stdout.destroy();
      child.stderr.destroy();
      const hint = stderr.trim() === '' ? '' : `\nstderr: ${stderr.trim()}`;
      reject(new Error(`prefablens CLI timed out after ${timeoutMs}ms${hint}`));
    }, timeoutMs);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (c: string) => { stdout += c; });
    child.stderr.on('data', (c: string) => { stderr += c; });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}
