import type { DiffV2 } from "../../domain/diff/types";

export class DiffError extends Error {}

export type DifferPort = {
  diff(before: Uint8Array, after: Uint8Array): DiffV2;
  diffWithAssets(before: Uint8Array, after: Uint8Array, assets: Map<string, Uint8Array>): DiffV2;
  isUnityYaml(bytes: Uint8Array): boolean;
};
