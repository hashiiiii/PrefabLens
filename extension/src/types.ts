// prefablens.diff.v2 (core/src/json.zig の出力と 1:1)
export type Status = 'added' | 'removed' | 'modified' | 'unchanged';

export type RefValue = { ref: { fileId: string; guid: string | null; type: number | null } };
export type FieldValue = string | RefValue | null;

export type FieldDiff = { path: string; status: Status; before: FieldValue; after: FieldValue };

export type OverrideDiff = {
  group: string; // "Transform" | "GameObject" | "Overrides"
  label: string; // humanize 済み ("Position.x")
  status: Status;
  before: FieldValue;
  after: FieldValue;
};

export type ComponentDiff = {
  kind: 'component';
  fileId: string;
  classId: number;
  typeName: string;
  scriptGuid: string | null;
  className: string | null;
  status: Status;
  fields: FieldDiff[];
};

export type GameObjectDiff = {
  kind: 'gameObject';
  fileId: string;
  name: string;
  status: Status;
  components: ComponentDiff[];
  children: NodeDiff[];
};

export type PrefabInstanceDiff = {
  kind: 'prefabInstance';
  fileId: string;
  name: string;
  status: Status;
  sourceGuid: string | null;
  overrides: OverrideDiff[];
  components: ComponentDiff[];
  children: NodeDiff[];
};

export type NodeDiff = GameObjectDiff | PrefabInstanceDiff;

export type DiffV2 = {
  schema: 'prefablens.diff.v2';
  unresolvedGuids: string[];
  resolved?: Record<string, string>; // ホスト側(applyResolved)が付与
  roots: NodeDiff[];
  loose: ComponentDiff[];
};

export type DiffErrorV1 = { schema: 'prefablens.error.v1'; error: string };

// content ↔ background メッセージ(chrome.runtime は JSON 直列化のみ)
export type SemanticDiffRequest = {
  type: 'semanticDiff';
  owner: string;
  repo: string;
  prNumber: number;
  path: string;
};

export type BackgroundError = 'pat-missing' | 'auth-failed' | 'rate-limited' | 'fetch-failed' | 'diff-failed';

export type SemanticDiffResponse = { ok: true; json: DiffV2 } | { ok: false; error: BackgroundError };
