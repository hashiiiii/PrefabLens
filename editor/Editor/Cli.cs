using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using UnityEditor;

namespace PrefabLens
{
    /// prefablens CLI の探索・ダウンロード・実行。git ロジックは全て CLI 側に置く(親仕様 §6.3)。
    public static class Cli
    {
        /// ダウンロードする CLI のバージョン(GitHub Releases のタグ v{Version} と一致させる)。
        public const string Version = "0.1.0";
        public const string CliPathPref = "PrefabLens.CliPath";

        // ---- 純関数(EditMode テスト対象) ----

        public static string ReleaseAssetName(bool isWindows, bool isMac, bool isArm64)
        {
            if (isWindows) return "prefablens-windows-x64.zip";
            if (isMac) return isArm64 ? "prefablens-macos-arm64.zip" : "prefablens-macos-x64.zip";
            return "prefablens-linux-x64.zip";
        }

        public static string DownloadUrl(string version, string assetName) =>
            $"https://github.com/hashiiiii/PrefabLens/releases/download/v{version}/{assetName}";

        public static string[] BuildArgs(string assetPath) =>
            new[] { "--git", "HEAD", assetPath, "--json" };

        /// ProcessStartInfo.Arguments 用の最小クオート(スペース入りアセットパス対策)。
        public static string QuoteArgs(string[] args)
        {
            var quoted = new string[args.Length];
            for (var i = 0; i < args.Length; i++)
                quoted[i] = "\"" + args[i].Replace("\"", "\\\"") + "\"";
            return string.Join(" ", quoted);
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
            if (!string.IsNullOrEmpty(manual) && File.Exists(manual)) return manual;
            return File.Exists(DefaultPath) ? DefaultPath : null;
        }

        /// GitHub Releases から取得して Library 配下に展開する。成功時は実行パス、失敗時は throw。
        public static string Download()
        {
            var asset = ReleaseAssetName(
                RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                RuntimeInformation.IsOSPlatform(OSPlatform.OSX),
                RuntimeInformation.ProcessArchitecture == Architecture.Arm64);
            var url = DownloadUrl(Version, asset);
            var dir = Path.GetDirectoryName(DefaultPath);
            Directory.CreateDirectory(dir);

            try
            {
                EditorUtility.DisplayProgressBar("PrefabLens", $"Downloading {asset}…", 0.3f);
                using (var http = new HttpClient())
                using (var zip = new ZipArchive(new MemoryStream(http.GetByteArrayAsync(url).Result)))
                {
                    foreach (var entry in zip.Entries)
                    {
                        // ZipFileExtensions(ExtractToFile)は netstandard で参照できないため手動コピー
                        var dest = Path.Combine(dir, entry.Name);
                        using (var src = entry.Open())
                        using (var dst = File.Create(dest))
                            src.CopyTo(dst);
                    }
                }
            }
            finally
            {
                EditorUtility.ClearProgressBar();
            }

            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                RunProcess("chmod", "+x \"" + DefaultPath + "\"", ".");
            return DefaultPath;
        }

        public struct Result
        {
            public int ExitCode;
            public string Stdout;
            public string Stderr;
        }

        /// プロジェクトルートを cwd に CLI を実行する(--git は cwd のリポジトリを見る)。
        public static Result Run(string cliPath, string assetPath)
        {
            return RunProcess(cliPath, QuoteArgs(BuildArgs(assetPath)), Directory.GetCurrentDirectory());
        }

        static Result RunProcess(string file, string arguments, string workDir)
        {
            var psi = new ProcessStartInfo(file, arguments)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = workDir,
            };
            using (var p = Process.Start(psi))
            {
                // 双方向 ReadToEnd のデッドロックを避ける: 片方は async で読む
                var stdout = p.StandardOutput.ReadToEndAsync();
                var stderr = p.StandardError.ReadToEndAsync();
                p.WaitForExit();
                return new Result { ExitCode = p.ExitCode, Stdout = stdout.Result, Stderr = stderr.Result };
            }
        }
    }
}
