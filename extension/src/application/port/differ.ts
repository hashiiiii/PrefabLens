import type { DiffV2 } from "../../domain/diff/types";
import type { Result } from "../_result";

export type DiffFailure = { kind: "diff-failed"; message: string };

export type DifferPort = {
  diff(before: Uint8Array, after: Uint8Array): Result<DiffV2, DiffFailure>;
  diffWithAssets(before: Uint8Array, after: Uint8Array, assets: Map<string, Uint8Array>): Result<DiffV2, DiffFailure>;
  isUnityYaml(bytes: Uint8Array): boolean;
};
