import type { GuidRepository } from "../../domain/guid/guid-repository";
import { createMergeStore } from "./merge-store";

type Area = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export function createChromeGuidRepository(area: Area): GuidRepository {
  return createMergeStore(area, "guids");
}
