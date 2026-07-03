import { AuthError, apiBase, type GithubClient, type PrFile, type PrRefs } from '../github/client';
import { applyResolved, buildGuidIndex } from '../github/guids';
import { DiffError, type Differ } from '../wasm/differ';
import type { SemanticDiffRequest, SemanticDiffResponse } from '../types';

type ClientLike = Pick<GithubClient, 'getPrRefs' | 'listPrFiles' | 'getFileAtRef'>;

export type Deps = {
  getSettings(): Promise<{ pat?: string; baseUrl?: string }>;
  makeClient(base: string, token: string): ClientLike;
  getDiffer(): Promise<Differ>;
};

type PrContext = { refs: PrRefs; files: PrFile[]; guidIndex: Map<string, string> };

const EMPTY = new Uint8Array(0);

export function createHandler(deps: Deps): (req: SemanticDiffRequest) => Promise<SemanticDiffResponse> {
  // PR 単位のコンテキストキャッシュ(follow-up の repo+sha キャッシュの差し込み口)。
  // SW はいつ殺されてもよく、その場合は再取得するだけ。
  const contexts = new Map<string, Promise<PrContext>>();

  function loadContext(client: ClientLike, owner: string, repo: string, prNumber: number): Promise<PrContext> {
    const key = `${owner}/${repo}#${prNumber}`;
    let ctx = contexts.get(key);
    if (!ctx) {
      ctx = (async () => {
        const refs = await client.getPrRefs(owner, repo, prNumber);
        const files = await client.listPrFiles(owner, repo, prNumber);
        const guidIndex = await buildGuidIndex(files, async (path, side) => {
          const bytes = await client.getFileAtRef(owner, repo, path, side === 'base' ? refs.baseSha : refs.headSha);
          return bytes ? new TextDecoder().decode(bytes) : null;
        });
        return { refs, files, guidIndex };
      })();
      contexts.set(key, ctx);
      ctx.catch(() => contexts.delete(key)); // 失敗はキャッシュしない
    }
    return ctx;
  }

  return async function handle(req) {
    try {
      const settings = await deps.getSettings();
      if (!settings.pat) return { ok: false, error: 'pat-missing' };
      const client = deps.makeClient(apiBase(settings.baseUrl), settings.pat);
      const { refs, files, guidIndex } = await loadContext(client, req.owner, req.repo, req.prNumber);

      const file = files.find((f) => f.path === req.path);
      const status = file?.status ?? 'modified';
      const beforePath = file?.previousPath ?? req.path;

      const before =
        status === 'added' ? EMPTY : ((await client.getFileAtRef(req.owner, req.repo, beforePath, refs.baseSha)) ?? EMPTY);
      const after =
        status === 'removed' ? EMPTY : ((await client.getFileAtRef(req.owner, req.repo, req.path, refs.headSha)) ?? EMPTY);

      const differ = await deps.getDiffer();
      const json = differ.diff(before, after);
      return { ok: true, json: applyResolved(json, guidIndex) };
    } catch (err) {
      if (err instanceof AuthError) return { ok: false, error: 'auth-failed' };
      if (err instanceof DiffError) return { ok: false, error: 'diff-failed' };
      return { ok: false, error: 'fetch-failed' }; // raw エラーは応答に載せない
    }
  };
}
