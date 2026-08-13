import type { GuidRepository } from "../../domain/guid/guid-repository";
import { createMergeStore } from "../internal/merge-store";
import type { StorageArea } from "../internal/storage-area";

export function createChromeGuidRepository(area: StorageArea): GuidRepository {
  return createMergeStore(area, "guids");
}
