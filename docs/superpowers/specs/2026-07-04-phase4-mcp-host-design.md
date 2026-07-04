# PrefabLens Phase 4 設計 — AI / MCP ホスト(ウォーキングスケルトン)

- **日付**: 2026-07-04
- **ステータス**: ドラフト(ユーザーレビュー待ち)
- **親仕様**: `2026-06-29-unity-prefab-diff-design.md` §6.4・§7・§8
- **ユーザー決定(2026-07-04)**: 主ユースケースはローカルリポジトリのコーディングエージェント支援 / 配布は npm 公開 + npx 起動 / 出力はテキストツリー既定 + `format:"json"` で diff.v2 / 初回ツールは diff 1 つのみ / 実装は CLI サブプロセス方式(Editor ホストと同型)

Claude Code などのコーディングエージェントが、作業中の Unity リポジトリで prefab/scene の変更を意味的に理解できるようにする最小の縦切りを作る。MCP サーバは薄いラッパで、git 調達・guid 解決・描画はすべて既存 CLI 側(親仕様 §6.3 と同じ責務分割)。要約・リスク指摘は LLM 側の仕事であり、サーバは構造化された事実だけを返す(親仕様 §6.4)。

## スコープ

### 初回に入れる

1. **npm パッケージ `@hashiiiii/prefablens-mcp`**(`/mcp`、TypeScript + `@modelcontextprotocol/sdk`、stdio transport、bin `prefablens-mcp`)。利用者は `npx @hashiiiii/prefablens-mcp` を MCP クライアントに登録
2. **MCP ツール `prefab_diff`** 1 つ(下記インターフェイス)
3. **CLI の探索・自動取得**(Editor `Cli.cs` の TS 版)
4. **release.yml への npm publish 追加**(tag `v*` で zip アセットと同時に出す)

### 初回は延期

- 複数ファイル一括 diff / 変更アセット列挙ツール(git で代替可能)
- MCP resources・prompts 機能、要約プロンプトテンプレート
- PR/GitHub API 入力(Phase 2 相当の複雑さ)、Unity AI Agents 連携
- プラットフォーム別 npm パッケージ(optionalDependencies 方式)による初回ダウンロード排除

## バージョン規約

`mcp/package.json` の `version` が唯一のソース。npm パッケージの version = ダウンロードする CLI の Releases タグ(`v<version>`)。Editor の `Cli.Version` 定数と同じ規約で、サーバは実行時に自身の package.json を読む(定数の二重管理をしない)。

**cut-release スキルの bump 対象が 4 → 5 箇所になる**(`mcp/package.json` 追加)。`check-versions.sh` も更新する。

## MCP ツール: `prefab_diff`

| 引数 | 型 | 説明 |
|---|---|---|
| `path` | string(必須) | 対象アセット(.prefab/.unity/.asset)のパス。projectRoot 相対(絶対パスも可、CLI は cwd = projectRoot で実行される) |
| `before` | string、既定 `"HEAD"` | 比較元 git ref |
| `after` | string(省略可) | 比較先 git ref。省略時は作業ツリー |
| `projectRoot` | string(省略可) | リポジトリルート。省略時はサーバプロセスの cwd |
| `format` | `"tree"`(既定)\| `"json"` | tree = ANSI なしテキストツリー、json = diff.v2 |

実行コマンド: `prefablens --no-color --git <before> [<after>] <path>`(cwd = projectRoot)。`format:"json"` 時は `--no-color` の代わりに `--json`。guid 解決は CLI のローカル `.meta` 走査がそのまま働く。

ツール説明文には「Unity YAML アセットの意味的 diff を返す。生の YAML diff を読む代わりに使う」旨をエージェント向けに書く(発見性がこのホストの UI に相当する)。

## CLI の探索と取得

1. 環境変数 `PREFABLENS_CLI`(明示指定。テストでのローカルビルド注入にも使う)
2. キャッシュ `~/.cache/prefablens/<version>/prefablens(.exe)`(全 OS 統一でシンプルに)
3. 無ければ `https://github.com/hashiiiii/PrefabLens/releases/download/v<version>/<asset>.zip` を取得 → 展開 → unix は chmod +x

アセット名 4 種(`prefablens-{macos-arm64,macos-x64,linux-x64,windows-x64}.zip`)は Editor と同一の対応表。配置は一時ファイルに展開して rename する原子的書き込みとし、同時起動の二重ダウンロードはロックせず「後勝ちでも壊れない」ことで無害化する。

## エラーハンドリング

- **CLI 不在 + ダウンロード失敗**: ツールエラー(`isError: true`)。手動配置 + `PREFABLENS_CLI` 指定の案内文を含める(ネットワーク遮断環境の逃げ道)
- **CLI exit ≠ 0**: stderr をそのままツールエラーで返す(not a git repository / unknown ref 等は CLI のメッセージが既に具体的)
- **巨大出力ガード**: tree 出力が 50,000 文字を超えたら切り詰め、末尾に `[truncated: N chars total]` を付記(LLM コンテキスト保護。Chrome 版 25MB 入力ガードの出力側版)。`format:"json"` は機械処理用途なので切り詰めない

## テスト戦略(親仕様 §7)

- **単体(vitest)**: 純関数 — アセット名解決 / ダウンロード URL / CLI 引数組み立て / truncate。Editor の EditMode テストと同じ対象の TS 版
- **統合(vitest)**: MCP SDK のクライアントで stdio 接続し、fixture の git リポジトリに `prefab_diff` を実行 → 出力ゴールデン照合。CLI は `PREFABLENS_CLI` でローカルビルド(`zig-out/bin/prefablens`)を注入し、ネットワーク非依存
- **CI**: ci.yml に mcp ジョブ追加(zig build → typecheck + vitest)

## リリースパイプライン

release.yml(tag `v*`)に npm publish を追加:

- 既存 job 内で **zip アセットの `gh release create` 完了後**に publish(npm が参照する CLI タグの Releases が先に存在する、Phase 3 と同型の順序制約)
- 認証は **npm Trusted Publishing(OIDC)**(シークレット管理不要)。npmjs.com 側の Trusted Publisher 設定はユーザー作業 1 回
- publish 前に `mcp/package.json` の version と tag の一致を検証(不一致は fail)

## PR 分割

単一 PR(`feat/mcp-host`): `/mcp` パッケージ + release.yml/ci.yml 変更 + cut-release スキル更新。機能本体につきマージはユーザー確認。

## 未決事項(レビューで確認)

- npm パッケージ名: `@hashiiiii/prefablens-mcp` を仮置き(npm 上のスコープ確保状況はユーザー確認)
- npm Trusted Publishing の設定タイミング(初回 publish 前に npmjs.com 側の設定が必要)
