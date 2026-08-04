import type { GuidRepository } from "../../domain/guid/guid-repository";
import { createMergeStore } from "./merge-store";
import type { StorageArea } from "./storage-area";

export function createChromeGuidClient(area: StorageArea): GuidRepository {
  return createMergeStore(area, "guids");
}
