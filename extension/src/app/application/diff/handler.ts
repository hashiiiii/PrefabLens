import type {
  GuidResolvedPush,
  PrefetchRequest,
  SemanticDiffRequest,
  SemanticDiffResponse,
} from "../../domain/diff/types";
import type { DiffCachePort } from "../port/diff-cache";
import type { DifferPort } from "../port/differ";
import type { GithubPort } from "../port/github";
import type { GuidCachePort } from "../port/guid-cache";
import type { RepoIndexPort } from "../port/repo-index";
import { createPrefetch } from "./prefetch";
import { createDiffEngine } from "./semantic-diff";

export type Deps = {
  getSettings(): Promise<{ accessToken?: string }>;
  makeClient(base: string, token: string, lane: "user" | "prefetch"): GithubPort;
  getDiffer(): Promise<DifferPort>;
  guidCache: GuidCachePort;
  diffStore: DiffCachePort;
  repoIndexStore: RepoIndexPort;
};

export type Handler = {
  semanticDiff(req: SemanticDiffRequest, push: (msg: GuidResolvedPush) => void): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};

export function createHandler(deps: Deps): Handler {
  const engine = createDiffEngine(deps);
  return {
    semanticDiff: (req, push) => engine.semanticDiff(req, push),
    prefetch: createPrefetch(engine),
  };
}
