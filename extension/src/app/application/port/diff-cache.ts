import type { DiffV2 } from "../../../types";

export type DiffCachePort = {
  load(key: string): Promise<DiffV2 | undefined>;
  save(key: string, json: DiffV2): Promise<void>;
};
