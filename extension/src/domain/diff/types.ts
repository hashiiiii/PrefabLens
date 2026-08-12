// prefablens.diff.v2 (1:1 with the output of core/src/json.zig)
export type Status = "added" | "removed" | "modified" | "unchanged";

export type RefValue = { ref: { fileId: string; guid: string | null; type: number | null } };
export type FieldValue = string | RefValue | null;

export type FieldDiff = { path: string; status: Status; before: FieldValue; after: FieldValue };

export type OverrideDiff = {
  group: string; // "Transform" | "GameObject" | "Overrides"
  label: string; // already humanized ("Position.x")
  status: Status;
  before: FieldValue;
  after: FieldValue;
};

export type ComponentDiff = {
  kind: "component";
  fileId: string;
  classId: number;
  typeName: string;
  scriptGuid: string | null;
  className: string | null;
  status: Status;
  fields: FieldDiff[];
};

export type GameObjectDiff = {
  kind: "gameObject";
  fileId: string;
  name: string;
  status: Status;
  overrides: OverrideDiff[];
  components: ComponentDiff[];
  children: NodeDiff[];
};

export type PrefabInstanceDiff = {
  kind: "prefabInstance";
  fileId: string;
  name: string;
  status: Status;
  sourceGuid: string | null;
  overrides: OverrideDiff[];
  components: ComponentDiff[];
  children: NodeDiff[];
};

export type NodeDiff = GameObjectDiff | PrefabInstanceDiff;

// A source prefab whose content core requests. side is the ref to fetch
// (added instance -> after/head, removed instance -> before/base).
export type NeededSource = { guid: string; side: "before" | "after" };

export type DiffV2 = {
  schema: "prefablens.diff.v2";
  unresolvedGuids: string[];
  neededSources?: NeededSource[]; // omitted when empty (additive)
  resolved?: Record<string, string>; // attached by the host side (applyResolved)
  roots: NodeDiff[];
  loose: ComponentDiff[];
};

// The canonical empty diff. The schema literal is a wire contract with
// core/src/json.zig. Fixtures spread this object and do not restate it.
export function emptyDiff(): DiffV2 {
  return { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] };
}

export type DiffErrorV1 = { schema: "prefablens.error.v1"; error: string };

// Which diff page a request is for. Every kind shares the blob/diff pipeline. Only
// the refs + changed-file discovery differs (PR API / commit API / compare API).
export type DiffTarget =
  | { kind: "pull"; prNumber: number }
  | { kind: "commit"; sha: string }
  | { kind: "compare"; base: string; head: string };
