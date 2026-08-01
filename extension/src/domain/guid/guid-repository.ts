import type { GuidMap } from "./guid-map";

export type GuidRepository = {
  load(repo: string): Promise<GuidMap>;
  save(repo: string, entries: GuidMap): Promise<void>;
};
