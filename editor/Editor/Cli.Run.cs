using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace PrefabLens
{
    // Run the CLI as a child process with timeout and cancellation.
    public static partial class Cli
    {
        /// Upper bound on CLI execution. Set longer than the CLI's internal git timeout (60s) so that on a git hang
        /// the CLI surfaces its own specific error first. This is the last-resort safety net against freezing the Unity main thread.
        public const int RunTimeoutMs = 90_000;

        /// Bare invocation = bulk mode: HEAD vs working tree, all changed Unity files,
        /// as a [{path, diff}] JSON array. A non-blank baseRef becomes the single ref
        /// operand, which the CLI parses as base ref vs working tree (still bulk mode).
        public static string[] BuildBulkArgs(string baseRef = null)
        {
            var r = baseRef?.Trim();
            return string.IsNullOrEmpty(r) ? new[] { "--json" } : new[] { r, "--json" };
        }

        /// Run bulk mode off the main thread. The callback is posted back through the
        /// caller's SynchronizationContext (Unity's main thread when called from the window).
        public static void RunBulkAsync(
            string cliPath,
            string baseRef,
            Action<Result> onDone,
            CancellationToken ct = default
        ) => RunAsync(cliPath, QuoteArgs(BuildBulkArgs(baseRef)), onDone, SynchronizationContext.Current, ct);

        public static void RunAsync(
            string file,
            string arguments,
            Action<Result> onDone,
            SynchronizationContext ctx,
            CancellationToken ct = default
        )
        {
            var workDir = Directory.GetCurrentDirectory();
            Task.Run(() =>
            {
                Result res;
                try
                {
                    res = RunProcess(file, arguments, workDir, RunTimeoutMs, ct);
                }
                catch (Exception e)
                {
                    // Process.Start failures (missing binary, permissions) become a Result
                    // so every failure reaches the window through one path.
                    res = new Result
                    {
                        ExitCode = -1,
                        Stdout = "",
                        Stderr = e.Message,
                    };
                }
                Post(ctx, () => onDone(res));
            });
        }

        /// Invoke on the captured context when there is one (Unity's main thread), directly otherwise.
        static void Post(SynchronizationContext ctx, Action action)
        {
            if (ctx != null)
                ctx.Post(_ => action(), null);
            else
                action();
        }

        /// Minimal quoting for ProcessStartInfo.Arguments (handles asset paths with spaces).
        public static string QuoteArgs(string[] args)
        {
            var quoted = new string[args.Length];
            for (var i = 0; i < args.Length; i++)
                quoted[i] = "\"" + args[i].Replace("\"", "\\\"") + "\"";
            return string.Join(" ", quoted);
        }

        public struct Result
        {
            public int ExitCode;
            public string Stdout;
            public string Stderr;
            public bool TimedOut;
            public bool Canceled;
        }

        public static Result RunProcess(
            string file,
            string arguments,
            string workDir,
            int timeoutMs,
            CancellationToken ct = default
        )
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
            // Cancellation kills the child like the timeout path does; WaitForExit then
            // returns promptly and the ct check below reports the run as canceled.
            using var reg = ct.Register(() =>
            {
                try
                {
                    p.Kill();
                }
                catch (InvalidOperationException)
                { /* race between cancel and exit */
                }
                catch (System.ComponentModel.Win32Exception)
                { /* already terminating */
                }
            });
            // Avoid a two-way ReadToEnd deadlock: read one side asynchronously
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs))
            {
                // Protect the Unity main thread from a hung CLI. If a grandchild process that holds stdio
                // survives the Kill, the Read tasks never complete, so don't wait for the remaining output.
                try
                {
                    p.Kill();
                }
                catch (InvalidOperationException)
                { /* race between timeout and exit */
                }
                catch (System.ComponentModel.Win32Exception)
                { /* already terminating */
                }
                return new Result
                {
                    ExitCode = -1,
                    Stdout = "",
                    Stderr = $"prefablens timed out after {timeoutMs / 1000}s and was killed",
                    TimedOut = true,
                };
            }
            if (ct.IsCancellationRequested)
            {
                // Same rationale as the timeout path: the child was killed, don't block on its pipes.
                return new Result
                {
                    ExitCode = -1,
                    Stdout = "",
                    Stderr = "prefablens run canceled",
                    Canceled = true,
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
