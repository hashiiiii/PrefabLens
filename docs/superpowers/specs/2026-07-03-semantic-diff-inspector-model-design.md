# PrefabLens 意味的 diff の Inspector メンタルモデル準拠 — 設計

> **ステータス:** 承認済み(2026-07-03)。レビュー反映: 表示次元とインデントの厳密対応(components セクション)、added オブジェクトのコンポーネント全列挙+折りたたみ。
>
> **前提:** 親仕様 `docs/superpowers/specs/2026-06-29-unity-prefab-diff-design.md` と Phase 2 設計 `docs/superpowers/specs/2026-07-03-prefablens-phase2-chrome-design.md` の上に立つ改善。アーキテクチャの型(core が意味変換・レンダラーは dumb)は親仕様を踏襲する。

## 背景と目標

Phase 2 のウォーキングスケルトンは UnityYAML の**ドキュメント構造**をそのまま diff として表示しており、Unity エンジニアのメンタルモデルと乖離している。検証 PR([unity-yaml-playground#1](https://github.com/hashiiiii/unity-yaml-playground/pull/1))で確認された具体的な乖離:

1. **fileID の羅列**: `m_Children[3]: + #4021899057343478380` — 「Plane の下に Cylinder Variant が配置された」ことが読み取れない。
2. **document type の露出**: `PrefabInstance` という型名で表示される。開発者はこの型を知らない。`Cylinder Variant` という名前で見えるべき。
3. **平坦な表示**: PrefabInstance が階層外(loose)に落ち、Hierarchy のような階層構造にならない。
4. **生プロパティパス**: `m_Modification.m_Modifications[0].value: 0.41646004 → 1` — Inspector 風に「Cylinder の Transform の Position.x が 0.41646004 → 1」と読めるべき。
5. **プレースホルダーの露出**: stripped Transform(Unity 内部の参照橋渡し)が diff に出る。

**原則: UnityEditor の Hierarchy / Inspector から得られる情報に置き換え、それ以上の情報は載せない。**生 YAML が見たいときは既存の `[Raw | Semantic]` トグルで GitHub 既定の diff に戻れる。

### 根本原因(現行コード)

- `tree.zig`: `m_GameObject` を持たないドキュメントは loose 行き。PrefabInstance(classID 1001)は `m_Modification.m_TransformParent` で親を持つがこの経路を見ていない。
- `parser.zig`: アンカー行の ` stripped` サフィックスを無視し、通常ドキュメントとして扱う。
- `diff.zig` の `diffSeq`: `m_Modifications` を配列インデックスで比較する。この配列は実際には `(target, propertyPath)` をキーとする順序不定の override 集合であり、インデックスに意味がない。
- humanize 層が存在しない: `m_LocalPosition` がそのまま出る。

## 表示イメージ(承認済みモック)

検証 PR に対する理想の出力:

```
Assets/Plane.prefab
▾ ~ Plane
  ▾ + Cylinder Variant   ‹Prefab›
      components
        ▾ Transform
            Position: (2.03, 3.63, 1.12)
  ▾ ~ Cylinder           ‹Prefab›
      components
        ▾ ~ Transform
            Position.x: 0.41646 → 1

Assets/Cylinder.prefab
▾ ~ Cylinder
    components
      ▾ ~ Transform
          Position.x: 0.64596 → 1
      ▸ + Cylinder1   ‹Script›

Assets/Cylinder Variant.prefab (新規)
▾ + Cylinder Variant   ‹Prefab›
    components
      ▾ Transform
          Scale.y: 2
```

### 表示次元の規則(インデントと意味の厳密対応)

表示は 3 つの次元(オブジェクト階層 / コンポーネント / プロパティ)を持ち、**どのインデントに何の次元が来るかを一意にする**。オブジェクト行とコンポーネント行が同じインデントに並ぶことは構造的に起きない。

- オブジェクト行の直下に置けるのは **`components` セクション(固定 1 行、muted 表示)** と **子オブジェクト行** のみ。並び順は components セクションが先、子オブジェクトが後で固定。
- コンポーネント行(および PrefabInstance の override グループ行)は必ず `components` セクションの直下。
- プロパティ行は必ずコンポーネント行の下。
- `components` セクションは小さく淡色のラベルとして描画し、階層ノードと誤読させない(HTML では Inspector パネル風の弱い区切り。CLI ではラベル行)。
- 変更のあるコンポーネントが 1 つも無いオブジェクトでは `components` セクション自体を出さない。

## §1 表示モデルと JSON スキーマ v2

スキーマ名を `prefablens.diff.v2` に上げる。v1 との互換レイヤーは持たない(利用者は自プロダクトのみ)。

### ノード種別

`gameObject`(既存)に加えて `prefabInstance` を追加:

```
PrefabInstanceDiff = {
  kind: 'prefabInstance',
  fileId: string,
  name: string,                  // §3 のフォールバックチェーンで決定(core は第1候補まで)
  status: Status,
  sourceGuid: string,            // m_SourcePrefab の guid。レンダラーが resolved でパス表示
  overrides: OverrideDiff[],     // (target, propertyPath) キーで diff 済み
  children: (GameObjectDiff | PrefabInstanceDiff)[],
}

OverrideDiff = {
  group: string,                 // propertyPath 先頭からの固定テーブル: m_LocalPosition/m_LocalRotation/m_LocalScale → "Transform"、m_Name/m_IsActive 等 GameObject 系 → "GameObject"、不明は "Overrides"
  label: string,                 // humanize 済み("Position.x")
  status: Status,
  before: FieldValue,
  after: FieldValue,
}
```

- `GameObjectDiff.children` にも `PrefabInstanceDiff` が混ざれる(Hierarchy と同じ)。
- `FieldDiff.path` は humanize 済み表示名に置き換える。**生パスは v2 では持たない**(Raw トグルが逃げ道)。
- `roots` / `loose` の 2 分割は据え置き(ScriptableObject `.asset` は引き続き loose)。PrefabInstance は loose から `roots` 配下の階層ノードへ移る。

### PrefabInstance の status 別表示規則

override は常に `group`(疑似コンポーネント)単位で `components` セクション配下に描画する。プロパティがコンポーネント層に直接現れることはない(表示次元の規則)。

- **added**: 全 `m_Modifications` は「新規配置時の初期 override」。`components › Transform` 配下の配置サマリに縮約する:
  - `m_LocalPosition.x/y/z` が揃っていれば `Position: (x, y, z)` に合成。
  - **デフォルト配置値は省略**: ゼロベクトル Position、identity Rotation(`(0,0,0,1)`)、unit Scale。加えて `m_LocalEulerAnglesHint`、`m_Name`(ノード名に吸収)も出さない(例: 検証 PR の新規 `Cylinder Variant.prefab` は `Transform › Scale.y: 2` のみになる)。
  - 上記以外の override はそのまま humanize して所属 `group` 配下に表示。
- **modified**: 変更された override のみを `group` ごとにまとめ、`components › ~ Transform › Position.x: old → new` の形で表示。
- **removed**: ノード名と status のみ(中身の列挙はしない)。

※ added な PrefabInstance はソース prefab が PR 外で読めないため、実際のコンポーネント一覧は列挙できない。override が示す疑似コンポーネントのみが `components` 配下に並ぶ。

### added な GameObject(新規 prefab ファイル含む)の表示規則

Inspector で見える情報のうち「アタッチされているコンポーネント一覧」を必ず出す。表示爆発は折りたたみで防ぐ:

- `components` セクションにコンポーネントを**全列挙**(名前は §3 で解決)。
- 各コンポーネントカードは**デフォルト閉じ**。開くと Inspector 相当の全プロパティ(非表示テーブル適用後・humanize 済みの初期値)が見える。
- 開閉のデフォルト規則: **added なコンポーネントカード(=初期値のフル列挙)は閉、modified なカード(=diff を含む)は開**。所属オブジェクトの status には依らない(modified なオブジェクトに追加されたコンポーネントも閉)。例外として added PrefabInstance の override カードは縮約サマリのみで軽いため開。

## §2 core パイプラインの変更

変換ロジックはすべて Zig core に置く。CLI / 拡張のレンダラーは v2 スキーマへの追従のみで、マッピングテーブルを持たない。

### 2.1 parser.zig — stripped 検出

アンカー行の ` stripped` サフィックスを検出し `Document.stripped: bool` を追加する。

### 2.2 diff.zig — override のキー化

- classID 1001 の `m_Modification.m_Modifications` は `diffSeq`(インデックス比較)を通さず、`(target.fileID, propertyPath)` をキーとするマップ比較に切り替える。`DocDiff` に `overrides: []OverrideDiff` を追加。
- stripped ドキュメントは field diff の対象から除外する(存在と参照解決には使う)。
- **added ドキュメントにも fields を出す**: 現行は added の `fields` が空だが、added な GameObject のコンポーネント初期値表示(§1)のため、after 側の body を added 状態の FieldDiff として平坦化して出す(非表示テーブル・humanize は 2.4 で適用)。removed は従来通り中身を列挙しない。

### 2.3 tree.zig — PrefabInstance の階層ノード化

- 親解決: `m_Modification.m_TransformParent` → その Transform の GameObject の子として配置。
  - `{fileID: 0}` ならルート。
  - stripped Transform を指す場合は、その `m_PrefabInstance` を辿って**親 PrefabInstance ノード**の子にする(ネストした instance)。
- stripped Transform はコンポーネント・children のいずれにも出さない。
- **構造 diff の抑制**: Transform の `m_Children.*` と GameObject の `m_Component.*` の生 field diff を落とす。構造変更(子の追加/削除、コンポーネント追加/削除)は木のノード status そのもので表現される。

### 2.4 inspector.zig(新規)— フィルタと humanize

**非表示フィールドテーブル**(Inspector に出ないもの):
`m_ObjectHideFlags`, `m_CorrespondingSourceObject`, `m_PrefabInstance`, `m_PrefabAsset`, `m_GameObject`, `m_Father`, `m_Children`, `m_Component`, `m_LocalEulerAnglesHint`, `m_EditorHideFlags`, `m_EditorClassIdentifier`, `serializedVersion`, `m_RootOrder`

**表示名変換**(2 段):
1. 固定テーブル: `m_LocalPosition`→`Position`, `m_LocalRotation`→`Rotation`, `m_LocalScale`→`Scale`, `m_Name`→`Name`, `m_IsActive`→`Active`, `m_Enabled`→`Enabled`, `m_TagString`→`Tag`, `m_Layer`→`Layer` など主要ビルトイン。
2. 汎用規則: `m_` プレフィックス除去 + Unity の `ObjectNames.NicifyVariableName` 相当(先頭大文字化、camelCase 境界に空白: `maxHp` → `Max Hp`)。

### 2.5 json.zig / レンダラー追従

- `prefablens.diff.v2` を出力。`prefabInstance` ノード、`sourceGuid`、humanize 済み `path` / `label`。
- extension `types.ts` / `render.ts`: v2 型と `prefabInstance` 描画(`‹Prefab: パス›` バッジ、`resolved` による名前・パス補完)。`components` セクション(muted ラベル)と開閉デフォルト(§1: フル列挙は閉、diff を含むカードは開)を実装。
- CLI `render_tree.zig` / `render_html.zig`: 同様の追従。テキスト出力に折りたたみは無いので CLI は全展開で出す(`components` はラベル行)。

## §3 名前解決フォールバックチェーン

| 対象 | 第 1 候補 | 第 2 候補 | 最終フォールバック |
|---|---|---|---|
| PrefabInstance 名 | `m_Name` override(after 優先。core 内で完結) | `resolved[sourceGuid]` のファイル名 stem(レンダラー) | `Prefab Instance` |
| MonoBehaviour 表示名 | `resolved[scriptGuid]` の .cs ファイル名 stem(レンダラー) | `m_EditorClassIdentifier` 末尾セグメント(`Assembly-CSharp::Cylinder1` → `Cylinder1`。core で抽出し JSON に含める) | `MonoBehaviour` |
| ‹Prefab› バッジ | `resolved[sourceGuid]` のフルパス | バッジのみ(guid は出さない) | 同左 |

- Unity は PrefabInstance 配置時にほぼ必ず `m_Name` override を書き出すため、第 1 候補でほとんど解決できる(検証 PR では両 instance とも該当)。
- guid 解決のスコープ自体(PR 外 `.meta` の取得、Code Search API)は Phase 2 の延期リスト通り**本改善でもスコープ外**。差し込み口(`resolved` マップ)は既存のまま。

## §4 エッジケースと非目標

### エッジケース

- **変更が非表示フィールドのみ**(例: `m_LocalEulerAnglesHint` だけ変化): コンポーネント/オブジェクトごと折りたたまれ、結果として「No semantic changes」になる。Inspector 上何も変わっていないので**正しい挙動**。
- **`m_Children` の並べ替えのみ**(Hierarchy 順序変更): 検出しない(YAGNI。将来必要になれば順序 diff を足す)。
- **`m_AddedGameObjects` / `m_AddedComponents` / `m_RemovedComponents` / `m_RemovedGameObjects` が非空**: 完全展開はスコープ外。`Added Components (2)` のような要約 1 行を出し、情報が黙って消えることは避ける。
- **`.unity`(Scene)**: PrefabInstance は scene に頻出するため、本改善はそのまま効く(専用処理なし)。
- **`m_TransformParent` が dangling**(参照先ドキュメントが存在しない): ルート扱い。

### 非目標(スコープ外)

- ソース prefab の中身を読んだ override target の名前解決(PR 外ファイル取得が必要。guid 解決強化と同じ路線で後続)。
- v1 スキーマとの互換維持。
- 順序変更の検出、`m_AddedComponents` 等の完全展開。

## §5 テスト計画

- **parser**: ` stripped` サフィックス検出(あり/なし/末尾空白)。
- **diff**: override のキー化 — 追加/削除/値変更/順序入れ替え(順序が変わっただけなら diff なし)。added ドキュメントの fields 平坦化。
- **tree**: PrefabInstance のルート配置・GameObject 子配置・ネスト instance(stripped 経由の親解決)、stripped の非表示、`m_Children`/`m_Component` 抑制。
- **inspector**: 固定テーブル、Nicify 規則(`maxHp`→`Max Hp`)、非表示テーブル。
- **json**: v2 スキーマのスナップショット。
- **extension**: `render.ts` の v2 描画、`resolved` 補完(名前・‹Prefab› バッジ・Script 名)、表示次元の規則(オブジェクト行直下は components セクションと子オブジェクトのみ)、開閉デフォルト。
- **E2E fixture**: 検証 PR(unity-yaml-playground#1)の `Plane.prefab` / `Cylinder.prefab` / `Cylinder Variant.prefab` をそのまま fixture 化し、承認済みモックと同じ構造が出ることを確認。
