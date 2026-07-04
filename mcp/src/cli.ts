import { spawn } from 'node:child_process';
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

/** env PREFABLENS_CLI → キャッシュ → GitHub Releases の順で CLI を確保する。 */
export async function ensureCli(version: string): Promise<string> {
  const manual = process.env['PREFABLENS_CLI'];
  if (manual !== undefined && manual !== '' && existsSync(manual)) return manual;
  const dest = cachePath(version, process.platform, homedir());
  if (existsSync(dest)) return dest;
  const url = downloadUrl(version, releaseAssetName(process.platform, process.arch));
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download failed: HTTP ${res.status} for ${url}`);
  installFromZip(new Uint8Array(await res.arrayBuffer()), dest, process.platform);
  return dest;
}

export interface CliResult {
  code: number;
  stdout: string;
  stderr: string;
}

export function runCli(cliPath: string, args: string[], cwd: string): Promise<CliResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cliPath, args, { cwd });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c: Buffer) => { stdout += c; });
    child.stderr.on('data', (c: Buffer) => { stderr += c; });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}
