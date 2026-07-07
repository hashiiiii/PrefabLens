using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using UnityEditor;

namespace PrefabLens
{
    /// prefablens CLI の探索・ダウンロード・実行。git ロジックは全て CLI 側に置く(親仕様 §6.3)。
    public static class Cli
    {
        /// ダウンロードする CLI のバージョン(GitHub Releases のタグ v{Version} と一致させる)。
        public const string Version = "0.3.0";
        public const string CliPathPref = "PrefabLens.CliPath";

        /// CLI 実行の上限。CLI 内部の git タイムアウト(60 秒)より長く取り、git ハング時は
        /// CLI 自身の具体的なエラーを先に出させる。ここは Unity メインスレッド凍結の最終安全網。
        public const int RunTimeoutMs = 90_000;

        // ---- 純関数(EditMode テスト対象) ----

        public static string ReleaseAssetName(bool isWindows, bool isMac, bool isArm64)
        {
            if (isWindows)
                return "prefablens-windows-x64.zip";
            if (isMac)
                return isArm64 ? "prefablens-macos-arm64.zip" : "prefablens-macos-x64.zip";
            return "prefablens-linux-x64.zip";
        }

        public static string DownloadUrl(string version, string assetName) =>
            $"https://github.com/hashiiiii/PrefabLens/releases/download/v{version}/{assetName}";

        public static string[] BuildArgs(string assetPath) => new[] { "--git", "HEAD", assetPath, "--json" };

        /// ProcessStartInfo.Arguments 用の最小クオート(スペース入りアセットパス対策)。
        public static string QuoteArgs(string[] args)
        {
            var quoted = new string[args.Length];
            for (var i = 0; i < args.Length; i++)
                quoted[i] = "\"" + args[i].Replace("\"", "\\\"") + "\"";
            return string.Join(" ", quoted);
        }

        /// `sha256sum` 形式("<hex>  <name>"、バイナリモードは "<hex> *<name>")から
        /// assetName の行のハッシュを取り出す。見つからなければ null。
        public static string ParseSha256Sums(string sums, string assetName)
        {
            foreach (var raw in sums.Split('\n'))
            {
                var line = raw.Trim();
                var sep = line.IndexOf(' ');
                if (sep <= 0)
                    continue;
                var name = line.Substring(sep).Trim().TrimStart('*');
                if (name == assetName)
                    return line.Substring(0, sep);
            }
            return null;
        }

        public static string Sha256Hex(byte[] bytes)
        {
            using var sha = SHA256.Create();
            var sb = new StringBuilder();
            foreach (var b in sha.ComputeHash(bytes))
                sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        // ---- Editor 連携 ----

        public static string BinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "prefablens.exe" : "prefablens";

        /// 既定の配置先。cwd(= Unity プロジェクトルート)相対の Library 配下。
        public static string DefaultPath => Path.Combine("Library", "PrefabLens", Version, BinaryName);

        /// EditorPrefs の手動指定が最優先。無ければ既定の配置先。どちらも無ければ null。
        public static string Find()
        {
            var manual = EditorPrefs.GetString(CliPathPref, "");
            if (!string.IsNullOrEmpty(manual) && File.Exists(manual))
                return manual;
            return File.Exists(DefaultPath) ? DefaultPath : null;
        }

        /// GitHub Releases から取得して Library 配下に展開する。成功時は実行パス、失敗時は throw。
        public static string Download()
        {
            var asset = ReleaseAssetName(
                RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                RuntimeInformation.IsOSPlatform(OSPlatform.OSX),
                RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            );
            var url = DownloadUrl(Version, asset);
            var dir = Path.GetDirectoryName(DefaultPath);
            Directory.CreateDirectory(dir);

            try
            {
                EditorUtility.DisplayProgressBar("PrefabLens", $"Downloading {asset}…", 0.3f);
                using var http = new HttpClient();
                var bytes = http.GetByteArrayAsync(url).Result;
                VerifyChecksum(http, asset, bytes);
                using var zip = new ZipArchive(new MemoryStream(bytes));
                foreach (var entry in zip.Entries)
                {
                    // ZipFileExtensions(ExtractToFile)は netstandard で参照できないため手動コピー
                    var dest = Path.Combine(dir, entry.Name);
                    using var src = entry.Open();
                    using var dst = File.Create(dest);
                    src.CopyTo(dst);
                }
            }
            finally
            {
                EditorUtility.ClearProgressBar();
            }

            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                RunProcess("chmod", "+x \"" + DefaultPath + "\"", ".", RunTimeoutMs);
            return DefaultPath;
        }

        /// リリースの SHA256SUMS と zip を照合する。SHA256SUMS が無い(404 = v0.2.0 以前の
        /// リリース)場合のみスキップし、それ以外の取得失敗と不一致は throw。
        static void VerifyChecksum(HttpClient http, string assetName, byte[] zipBytes)
        {
            var res = http.GetAsync(DownloadUrl(Version, "SHA256SUMS")).Result;
            if (res.StatusCode == HttpStatusCode.NotFound)
                return;
            res.EnsureSuccessStatusCode();
            var want = ParseSha256Sums(res.Content.ReadAsStringAsync().Result, assetName);
            if (want == null)
                throw new InvalidOperationException($"SHA256SUMS has no entry for {assetName}");
            var got = Sha256Hex(zipBytes);
            if (!string.Equals(want, got, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"SHA256 mismatch for {assetName}: expected {want}, got {got}");
        }

        public struct Result
        {
            public int ExitCode;
            public string Stdout;
            public string Stderr;
            public bool TimedOut;
        }

        /// プロジェクトルートを cwd に CLI を実行する(--git は cwd のリポジトリを見る)。
        public static Result Run(string cliPath, string assetPath)
        {
            return RunProcess(cliPath, QuoteArgs(BuildArgs(assetPath)), Directory.GetCurrentDirectory(), RunTimeoutMs);
        }

        public static Result RunProcess(string file, string arguments, string workDir, int timeoutMs)
        {
            var psi = new ProcessStartInfo(file, arguments)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = workDir,
            };
            using var p = Process.Start(psi);
            // 双方向 ReadToEnd のデッドロックを避ける: 片方は async で読む
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs))
            {
                // ハングした CLI から Unity メインスレッドを守る。Kill 後も stdio を掴む
                // 孫プロセスが残ると Read タスクは完了しないため、読み残しは待たない。
                try
                {
                    p.Kill();
                }
                catch (InvalidOperationException)
                { /* タイムアウトと終了の競合 */
                }
                catch (System.ComponentModel.Win32Exception)
                { /* 既に終了処理中 */
                }
                return new Result
                {
                    ExitCode = -1,
                    Stdout = "",
                    Stderr = $"prefablens timed out after {timeoutMs / 1000}s and was killed",
                    TimedOut = true,
                };
            }
            return new Result
            {
                ExitCode = p.ExitCode,
                Stdout = stdout.Result,
                Stderr = stderr.Result,
            };
        }
    }
}
