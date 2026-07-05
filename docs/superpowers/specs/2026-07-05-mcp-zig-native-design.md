# PrefabLens MCP Zig ネイティブ化設計 — `prefablens mcp` サブコマンド

2026-07-05 ブレスト確定。TS 製 MCP ホスト(`mcp/`)を Zig 実装で置換し、`prefablens` CLI のサブコマンドとして同梱する。

## 決定の記録

- **動機**: TS/JS を保守言語から外したい(ユーザーは C# / Zig を選好)。当初の「C# にすれば性能が上がる」は誤解と確認済み — 現 TS ホストは薄いサブプロセスラッパーで、処理時間は Zig CLI + git が支配的。性能が実際に上がるのはインプロセス化(本設計)のみ。
- **検討して見送った選択肢**:
  - C# SDK 書き直し: 利用者に .NET 10 SDK を要求、性能は現状維持、NuGet/dnx 運用が新規発生
  - 別リポジトリ化(MCP ホスト or core submodule 分割): cut-release の 1 コミット lockstep と in-tree E2E golden を壊す。1 人 + エージェント体制では CI・リリース系を 2 セット飼うだけ
  - 汎用 Zig MCP SDK の切り出し: 別製品を抱えることになり、対象ユーザー(MCP を書く Zig 開発者)が PrefabLens のユーザー(Unity 開発者)と不一致。リポジトリ内最小実装に留める
  - Rust 全面移植: 「自分用ツールを磨く」方針により棚上げ。golden corpus は言語非依存なので、外部採用を狙う局面が来れば移植可能性は保存されている(コストは行数比例で増える点のみ留意)
- **サブコマンド方式(Z1)の根拠**: MCP は diff エンジンへの 3 つ目の入り口(argv/tree、argv/json、JSON-RPC)であり、core に変更はない = 責務の追加ではなく transport の追加。`ruff server` / `deno lsp` と同型。別バイナリ(Z2)にしても共有すべきは cli/src の応用層ほぼ全部で、コード分離にならない。Z1 → Z2 は将来も機械的に移行可能。
- monorepo 維持を再確認。

## ゴール

- `prefablens mcp` で MCP stdio サーバーが起動し、既存 TS ホストと**機能パリティ**(ツール定義・検証・truncate・エラー文言)を持つ
- 利用者の前提はバイナリ 1 個のみ(Node / npm / PREFABLENS_CLI が不要になる)
- 切り替え完了時に `mcp/`(TS)をリポジトリから削除

## 非目標

- HTTP transport / resources / prompts / progress / cancellation / 複数ツール
- 汎用 SDK 化(公開 API にしない。cli/src 内部実装)
- git 子プロセスのタイムアウト: **follow-up 候補として記録**。常駐サーバーで git がハングするとツール呼び出しが返らない(TS 版には 60 秒の runCli タイムアウトがあった)。初回スコープでは入れず、切り替え PR 後に input.zig の seam で判断
- npm publish の再開(本設計で恒久に不要となり、release.yml の publish ステップは削除)

## アーキテクチャ

- **場所**: `cli/src/mcp.zig`(サーバーループ + ハンドラ)。`main.zig` の引数処理に `mcp` サブコマンド分岐を追加(既存 `parseArgs` は diff 用のまま、サブコマンド判定はその手前)
- **transport**: stdio、改行区切りの JSON-RPC 2.0(MCP stdio 仕様)。stdin EOF で正常終了。stdout はプロトコル専用、診断は stderr のみ
- **実行モデル**: リクエストごとに arena を張り、tools/call の引数から既存パイプライン(input.zig の git 取得 → resolve.zig の guid 解決 → core diff → render_tree / JSON)を関数呼び出しで実行。**chdir はしない** — `projectRoot` は git 子プロセスの cwd と `.meta` 走査の基点として引数で貫通する(常駐プロセスでは呼び出しごとに projectRoot が変わり得るため)
- **並行性**: なし。1 リクエストずつ逐次処理(現 TS ホストも実質逐次。クライアントは応答を待つ)

## プロトコル表面

| メソッド | 応答 |
|---|---|
| `initialize` | バージョン交渉: クライアントの `protocolVersion` がサポートリスト内ならエコー、外なら既定版を返す。capabilities は `{"tools":{}}`、serverInfo は `{name:"prefablens", version:<CLI バージョン定数>}`。**CLI にバージョン定数は現存しないため PR 1 で新設**(`cli/src/main.zig` に `pub const version`。build.zig.zon は lockstep 外のまま) |
| `notifications/initialized` | 受信して無視(応答なし) |
| `ping` | `{}` |
| `tools/list` | `prefab_diff` 1 件(下記スキーマ)。静的 JSON |
| `tools/call` | 下記パリティ仕様 |
| 上記以外の request | JSON-RPC error `-32601`(method not found) |
| JSON として不正な行 | `-32700`(parse error、id は null) |
| 形式不正(jsonrpc/method 欠落等) | `-32600`(invalid request) |

- サポートするプロトコルバージョン: `2025-06-18`(既定)、`2025-03-26`、`2024-11-05`
- 通知(id なし)にはエラーも含め一切応答しない(JSON-RPC 2.0 準拠)

## `prefab_diff` パリティ仕様(TS 版 index.ts がソース・オブ・トゥルース)

- inputSchema(JSON Schema、zod 定義の忠実な変換):
  - `path` string 必須(空文字不可)— Asset path (.prefab/.unity/.asset), relative to projectRoot
  - `before` string 省略時 `"HEAD"` — Base git ref
  - `after` string 省略可 — 省略 = 作業ツリーと比較
  - `projectRoot` string 省略可(空文字不可)— 省略時はサーバープロセスの cwd
  - `format` `"tree" | "json"` 省略時 `"tree"`
- description は TS 版の文字列を逐語コピー
- 検証エラー(空 `path` / 空 `projectRoot` / 不正 `format` 等)は throw せず `isError: true` + `Input validation error: ...` テキスト(現クライアント観測挙動と同一)
- 成功: `format=tree` は 50,000 文字で truncate し `\n[truncated: N chars total]\n` を付加。`json` は素通し
- 失敗(git 参照不能等): `isError: true` + CLI が stderr に出すのと同じメッセージ(例 `git show failed for 'nosuchref:Plane.prefab'`)。メッセージを持たないエラーは `prefablens failed: <エラー名>` にフォールバック(TS 版の `prefablens exited with code N` に相当。インプロセス化で exit code は消滅)

## テスト戦略(モックなし)

- **ユニット**(`zig build test`): mcp.zig のループを fixed buffer の reader/writer で駆動。initialize 交渉(リスト内エコー / リスト外は既定版)/ tools/list の golden / 検証エラー各種 / unknown method / parse error / 通知に応答しないこと
- **E2E**(zig test 内): 実バイナリを `mcp` 引数で spawn し、テンポラリの実 git リポジトリ(server.test.ts と同じ plane fixture)相手に JSON-RPC を往復。**期待値は server.test.ts の golden(Plane tree 出力・diff.v2 schema・エラー文言)をそのまま移植** — TS→Zig のパリティ証明を兼ねる
- **手動**: 切り替え PR 前に `claude mcp add` で実クライアント(Claude Code)から prefab_diff を叩いて確認

## 移行計画(PR 2 本)

1. **PR 1(feat)**: `prefablens mcp` 実装 + ユニット + E2E。`mcp/` は無変更(併存期間中も既存ホストは動き続ける)
2. **PR 2(chore)**: 切り替え
   - `mcp/` ディレクトリ削除(TS テストごと)
   - ci.yml: mcp ジョブを削除し、**windows で `zig build test` + `zig build` を回すジョブに置換**(PR #20 で得た Windows カバレッジを維持)
   - release.yml: npm publish ステップ削除
   - cut-release スキル: バージョンソースは **5 のまま構成員交代**(`mcp/package.json` が抜け、`cli/src/main.zig` の version 定数が入る)。check-versions.sh を追随、確認手順から npm を削除
   - mcp/README.md 削除に伴い、セットアップ手順(`claude mcp add --scope user prefablens -- <path>/prefablens mcp`)を docs へ移設
   - ローカル登録の切り替え(旧: node dist/index.js + PREFABLENS_CLI env → 新: バイナリ直接)
- ロールバック: PR 2 の revert で TS ホストが完全復活(PR 1 と独立)

## 検証コマンド

- `zig build test`(mcp ユニット + E2E を含む全テスト)
- `zig build` + 手動 smoke: `printf '<initialize>\n<tools/list>\n' | zig-out/bin/prefablens mcp`
- CI 全ジョブ green(extension / perf は無関係だが回帰確認)
