# Merge strategy performance investigation

Issue: [#467](https://github.com/hashiiiii/PrefabLens/issues/467).

Measurements used macOS 27.0.1 on arm64, 32 GiB RAM, Git 2.54.0 (Apple Git-157), and Zig 0.17.0 ReleaseFast builds.
The baseline was `9f840447c9b81137174f5930d532600f9603e158`.
The reporter's PrefabLens version and Windows repository were unavailable; these are local reproductions, not measurements of that environment.
The tables record the initial performance changes at `9469fefc24241878e7a254c890b522cb43bd86cc`; they do not include the subsequent replay-input and per-file allocation changes.

## Confirmed causes

`setup-merge` sets `pull.twohead=prefablens` by default.
Git's sequencer also reads this setting when replaying commits.
A five-commit rebase launched five strategies; a five-commit cherry-pick also launched five.
A revert launched none.
Git v2.50.1 has the same selection logic and an internal revert execution path in [sequencer.c](https://github.com/git/git/blob/v2.50.1/sequencer.c).

A separate replay check edited the same text file in consecutive commits.
PrefabLens stopped at the second commit with a conflict; `ort` completed successfully.
The trace's explicit base differed from the base recomputed by the strategy.
Replay-input handling has since been corrected: the strategy preserves Git's supplied bases, including the empty-tree base of a root pick and the index-tree Ours of `--no-commit`.
The repeated-edit regression and exclusion of unpicked ancestor changes are covered by `zig build test-merge-strategy -- replay`.
The optional `ort` configuration remains available; normal setup continues to enable the PrefabLens strategy.

Each strategy eagerly read all asset versions into `Candidate.blobs`, including unchanged files.
A repository with 768 unchanged assets, each containing a 4 MiB scalar, retained 3,221,313,898 bytes of blob content.
Sampling the strategy process measured 3,284,189,184 bytes of resident memory.
This reproduces several GiB of memory usage without a single large changed file.

Asset classification also ran a complete three-way merge with identical inputs for every unique asset blob.
With 1,001 unchanged assets containing 2,000 scalar fields each, temporary diagnostic timers measured 28,457 ms in classification.
The complete invocation took 29.626 seconds.
These timers were excluded from the final builds.

Candidate selection searched each tree's entry array separately for every path.
With 10,000 unchanged assets and their metadata files, the selection phase took 790 ms.
The equivalent phase took 51 ms with 1,001 assets.
Snapshot path indexes remove these repeated linear searches.

## Configuration precedence

Git's sequencer selects the first `pull.twohead` value, whereas ordinary merge can use a later value.
A local `ort` setting did not prevent rebase from invoking the global PrefabLens strategy in a real Git test.
An included configuration file can similarly preserve PrefabLens after the containing file changes to `ort`.

`setup-merge --no-strategy` replaces all values in its selected configuration file with `ort`.
It checks setting origins before writing attributes or configuration.
It rejects earlier inherited PrefabLens strategies and PrefabLens entries in included files within the selected scope.
The diagnostic identifies the command for inspecting those origins.
Driver and mergetool configuration remain available without the strategy script.

## Before and after

Each case uses three measured runs with Git tracing enabled.
Elapsed values are medians.
RSS values are medians of each invocation's sampled peak, not the sum of child-process memory.
On macOS, the benchmark samples `proc_pid_rusage(..., RUSAGE_INFO_V4)` every 5 ms.
RSS sampling can miss shorter peaks.

| Direct strategy workload | Before (s) | After (s) | Before RSS (MiB) | After RSS (MiB) |
| --- | ---: | ---: | ---: | ---: |
| 768 unchanged assets, 4 MiB scalar each | 7.308 | 0.558 | 3132.016 | 5.375 |
| 1,001 unchanged assets, 2,000 fields each | 30.070 | 0.709 | 153.453 | 6.797 |
| 10,000 unchanged assets, 50 fields each | 4.905 | 3.109 | 40.562 | 39.453 |

| Five-commit rebase | Median (s) | External strategy calls | Driver calls |
| --- | ---: | ---: | ---: |
| Before, PrefabLens strategy | 3.054 | 5 | 5 |
| After, PrefabLens strategy | 2.456 | 5 | 5 |
| After, `--no-strategy` | 0.068 | 0 | 1 |

Elapsed samples in run order:

| Workload | Binary / operation | Samples (s) |
| --- | --- | --- |
| memory | before / strategy | 7.338, 6.767, 7.308 |
| memory | after / strategy | 0.594, 0.558, 0.541 |
| classification | before / strategy | 30.070, 41.219, 29.523 |
| classification | after / strategy | 0.686, 0.709, 0.730 |
| paths | before / strategy | 5.327, 4.905, 4.832 |
| paths | after / strategy | 3.123, 3.109, 3.067 |
| rebase | before / rebase | 3.099, 3.054, 2.943 |
| rebase | after / rebase | 2.456, 2.439, 2.456 |
| rebase | after / driver-only | 0.068, 0.068, 0.067 |

An existing local Unity merge fixture stayed near 2.3 seconds (2.287 seconds before, 2.251 seconds after).
All six runs returned the expected conflict status, with identical index and working-file digests.
This case checks compatibility while preserving existing conflicts.

```text
index_sha256: 6fd8deee9e587b7914b59ff36b34ddb40e9f53f0879f110f56aa281bcb876cba
worktree_sha256: 284329adbee128d0cfe048d5b6dd4bbf3d2bf6d40624eb6fdc621d5ba3d3f3ff
```


The fixture changes a separate text file in each feature commit.
Both branches also change different scalar fields in one small prefab, exercising the real merge driver.
The benchmark checks the merged prefab, replayed commit count, and every feature text file.

Unchanged assets are skipped only when schema and identity evidence remain unchanged.
Script, assembly, or uncertain metadata changes still trigger repository-wide inspection to preserve semantic validation.
These results do not establish a memory ceiling for merges requiring many asset bodies.

## Reproduction

Build the baseline and this branch with `mise exec -- zig build -Doptimize=ReleaseFast -j2` in separate checkouts.
Pass the resulting native executables to the benchmark; it copies each executable beside the real strategy script.
All repositories and Git configuration changes stay in a temporary directory.
The JSON output retains every sample and invocation count.
The benchmark supports macOS and Linux with Python 3.9 or later.

```sh
python3 e2e/merge_strategy_benchmark.py \
  --before /path/to/before/prefablens --after /path/to/after/prefablens \
  --files 768 --fields 0 --padding 4194304 --operations strategy \
  --output /tmp/merge-memory.json

python3 e2e/merge_strategy_benchmark.py \
  --before /path/to/before/prefablens --after /path/to/after/prefablens \
  --files 1001 --fields 2000 --operations strategy \
  --output /tmp/merge-classification.json

python3 e2e/merge_strategy_benchmark.py \
  --before /path/to/before/prefablens --after /path/to/after/prefablens \
  --files 10000 --fields 50 --operations strategy \
  --output /tmp/merge-paths.json

python3 e2e/merge_strategy_benchmark.py \
  --before /path/to/before/prefablens --after /path/to/after/prefablens \
  --files 1002 --fields 50 --operations rebase driver-only \
  --output /tmp/merge-rebase.json
```

The `driver-only` case runs the new binary's actual `setup-merge --no-strategy` command before measuring rebase.
It starts from an existing local PrefabLens strategy setting.
