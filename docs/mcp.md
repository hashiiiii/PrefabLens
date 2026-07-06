# PrefabLens MCP server

`prefablens mcp` は MCP stdio サーバーを起動する(ツールは `prefab_diff` 1 つ)。
ランタイム依存はない — CLI バイナリがそのままサーバーになる。diff は同一プロセス内で実行される。

## Setup (Claude Code)

```sh
claude mcp add --scope user prefablens -- /path/to/prefablens mcp
```

バイナリは [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases) の zip
(`SHA256SUMS` 付き)か、リポジトリで `zig build` して `zig-out/bin/prefablens` を使う。

## Tool: `prefab_diff`

| Parameter | Default | Description |
|---|---|---|
| `path` | (required) | UnityYAML asset path(`.prefab`/`.unity`/`.asset`/`.mat`/`.anim`/`.controller` など)、`projectRoot` 相対 |
| `before` | `HEAD` | Base git ref |
| `after` | working tree | Target git ref; omit to compare against the working tree |
| `projectRoot` | server cwd | Repository root (also the base for `.meta` guid resolution) |
| `format` | `tree` | `tree` = readable text (truncated at 50k chars), `json` = `prefablens.diff.v2` |

git ロジック・出力は CLI と共通(`--project <projectRoot> --git <before> [<after>] <path>` と等価)。
git 実行は 60 秒で打ち切られる(ハングした git が常駐サーバーを道連れにしない)。
