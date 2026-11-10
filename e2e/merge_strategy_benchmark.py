"""Compare real merge strategies in disposable Git repositories."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time


BASE = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n"
OURS = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n"
THEIRS = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n"
MERGED = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n"


def run(repo, env, *command):
    return subprocess.run(command, cwd=repo, env=env, capture_output=True, check=True).stdout.decode().strip()


def rss_reader():
    if platform.system() == "Darwin":
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]

        def read(pid):
            # rusage_info_v4 places ri_resident_size after the UUID and six uint64 fields.
            usage = (ctypes.c_uint64 * 64)()
            return usage[8] if lib.proc_pid_rusage(pid, 4, ctypes.byref(usage)) == 0 else 0

        return read
    if platform.system() == "Linux":
        def read(pid):
            try:
                for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                    if line.startswith("VmHWM:"):
                        return int(line.split()[1]) * 1024
            except FileNotFoundError:
                pass
            return 0

        return read
    raise RuntimeError("RSS sampling requires macOS or Linux")


def fixture(repo, env, args):
    repo.mkdir()
    (repo / "Assets").mkdir()
    (repo / "Notes").mkdir()
    git = lambda *argv: run(repo, env, "git", *argv)
    git("init", "-q", "-b", "main")
    for key, value in [("user.name", "Benchmark"), ("user.email", "benchmark@example.invalid"),
                       ("commit.gpgsign", "false"), ("core.hooksPath", ".git/no-hooks"),
                       ("core.attributesFile", os.devnull), ("gc.auto", "0"), ("maintenance.auto", "false")]:
        git("config", key, value)
    (repo / ".gitattributes").write_text("*.prefab merge=prefablens\n")
    fields = "".join(f"  m_Field{i}: {i}\n" for i in range(args.fields))
    if args.padding:
        fields += "  m_Padding: " + "x" * args.padding + "\n"
    for i in range(args.files):
        (repo / "Assets" / f"F{i:05}.prefab").write_text(f"--- !u!114 &1\nMonoBehaviour:\n  m_Id: {i}\n" + fields)
        (repo / "Assets" / f"F{i:05}.prefab.meta").write_text(f"fileFormatVersion: 2\nguid: {i + 1:032x}\n")
    (repo / "Assets/Changed.prefab").write_text(BASE)
    (repo / "Notes/develop.txt").write_text("base\n")
    git("add", ".")
    git("commit", "-qm", "base")
    git("switch", "-qc", "feature")
    for i in range(args.commits):
        (repo / "Notes" / f"feature-{i}.txt").write_text(f"feature {i}\n")
        if i == 0:
            (repo / "Assets/Changed.prefab").write_text(OURS)
        git("add", ".")
        git("commit", "-qm", f"feature {i}")
    git("branch", "feature-original")
    git("switch", "-qc", "develop", "main")
    (repo / "Notes/develop.txt").write_text("develop\n")
    (repo / "Assets/Changed.prefab").write_text(THEIRS)
    git("add", ".")
    git("commit", "-qm", "develop")
    git("switch", "-q", "feature")
    git("fsck", "--no-reflogs")


def measure(repo, env, command, trace, read_rss):
    started = time.perf_counter()
    peak = 0
    # Files keep subprocess output from blocking while RSS is sampled.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        with subprocess.Popen(command, cwd=repo, env=env | {"GIT_TRACE2_EVENT": str(trace)},
                              stdout=stdout, stderr=stderr) as child:
            while child.poll() is None:
                peak = max(peak, read_rss(child.pid))
                if time.perf_counter() - started > 180 or peak > 4 * 1024**3:
                    child.kill()
                    raise RuntimeError("Benchmark exceeded 180 seconds or 4 GiB RSS")
                time.sleep(0.005)
            elapsed = time.perf_counter() - started
            stderr.seek(0)
            if child.returncode:
                raise RuntimeError(f"{command}: exit {child.returncode}\n{stderr.read().decode()}")
    events = [json.loads(line) for line in trace.read_text().splitlines()]
    children = [event.get("argv", []) for event in events if event.get("event") == "child_start"]
    return {
        "seconds": elapsed,
        "sampled_command_rss_bytes": peak or None,
        "strategy_calls": sum("merge-prefablens" in argv and "--version" not in argv for argv in children),
        "driver_calls": sum(any("merge-driver" in arg for arg in argv) for argv in children),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--files", type=int, default=1001)
    parser.add_argument("--fields", type=int, default=50)
    parser.add_argument("--padding", type=int, default=0)
    parser.add_argument("--commits", type=int, default=5)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--operations", nargs="+", choices=["strategy", "rebase", "driver-only"],
                        default=["strategy", "rebase", "driver-only"])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() not in {"Darwin", "Linux"}:
        parser.error("Run this benchmark on macOS or Linux")
    if min(args.files, args.fields, args.padding) < 0 or min(args.commits, args.runs) < 1:
        parser.error("Counts must be nonnegative; commits and runs must be positive")
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_") and not key.startswith("PREFABLENS_MERGE_")}
    env |= {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "0", "GIT_ATTR_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "true"}
    rows = []
    read_rss = rss_reader()
    with tempfile.TemporaryDirectory(prefix="prefablens-merge-benchmark-") as scratch:
        root = Path(scratch)
        repo = root / "repo"
        fixture(repo, env, args)
        for label, executable in [("before", args.before), ("after", args.after)]:
            bindir = root / label
            bindir.mkdir()
            shutil.copy2(executable.resolve(), bindir / "prefablens")
            shutil.copy2(Path(__file__).resolve().parents[1] / "cli/bin/git-merge-prefablens", bindir)
            active = env | {"PATH": str(bindir) + os.pathsep + env["PATH"]}
            git = lambda *argv: run(repo, active, "git", *argv)
            for operation in args.operations:
                if label == "before" and operation == "driver-only":
                    continue
                for sample in range(args.runs):
                    git("reset", "--hard", "feature-original")
                    git("checkout", "-q", "-B", "feature", "feature-original")
                    git("config", "merge.prefablens.driver", "prefablens merge-driver %O %A %B %P %L")
                    git("config", "merge.prefablens.recursive", "text")
                    git("config", "pull.twohead", "prefablens")
                    if operation == "driver-only":
                        run(repo, active, str(bindir / "prefablens"), "setup-merge", "--no-strategy")
                    if operation == "strategy":
                        command = [str(bindir / "prefablens"), "merge-strategy", git("rev-parse", "main"),
                                   "--", git("rev-parse", "HEAD"), git("rev-parse", "develop")]
                    else:
                        command = ["git", "rebase", "develop"]
                    row = {"binary": label, "operation": operation, "sample": sample + 1}
                    row |= measure(repo, active, command, root / f"{label}-{operation}-{sample}.json", read_rss)
                    assert (repo / "Assets/Changed.prefab").read_text() == MERGED
                    if operation != "strategy":
                        assert git("rev-list", "--count", "develop..HEAD") == str(args.commits)
                        for i in range(args.commits):
                            assert (repo / "Notes" / f"feature-{i}.txt").read_text() == f"feature {i}\n"
                    rows.append(row)
                    print(json.dumps(row), flush=True)
    report = {"platform": platform.platform(), "git": run(None, env, "git", "--version"),
              "files": args.files, "fields": args.fields, "padding": args.padding,
              "commits": args.commits, "samples": rows}
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
