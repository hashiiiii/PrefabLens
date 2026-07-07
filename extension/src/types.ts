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

// Source prefab whose content core asks to be supplied. side is the ref to fetch
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

export type DiffErrorV1 = { schema: "prefablens.error.v1"; error: string };

// content ↔ background messages (chrome.runtime only serializes JSON)
export type SemanticDiffRequest = {
  type: "semanticDiff";
  owner: string;
  repo: string;
  prNumber: number;
  path: string;
  force?: boolean; // render past the 25MB guard ("Render anyway" click)
};

export type PrefetchRequest = { type: "prefetch"; owner: string; repo: string; prNumber: number };
export type BackgroundRequest = SemanticDiffRequest | PrefetchRequest;

export type BackgroundError = "pat-missing" | "auth-failed" | "rate-limited" | "fetch-failed" | "diff-failed";

export type SemanticDiffResponse =
  | { ok: true; json: DiffV2; pending?: boolean }
  | { ok: false; error: BackgroundError }
  | { ok: false; error: "too-large"; bytes: number };

// Async push from background → content (the second stage of the two-stage response).
export type GuidResolvedPush = {
  type: "guidResolved";
  owner: string;
  repo: string;
  prNumber: number;
  path: string;
  resolved: Record<string, string>;
  json?: DiffV2; // carried on the final push when mergeSources updated the structure (content replaces the view)
  done: boolean; // when true, resolution is finished (sent even with empty resolved = the cue to turn off the indicator)
};
