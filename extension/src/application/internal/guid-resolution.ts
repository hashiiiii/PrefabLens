import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { DiffSession } from "../diff/create-diff-session";
import { type GithubGateway, isRateLimited } from "../gateway/github";

const MAX_SEARCHES = 10; // Code Search permits 10 authenticated requests each minute, so one response must not use more.

export type GuidResolution = {
  resolved: Record<string, string>;
  rateLimited: boolean;
};

export async function resolveGuids(
  guidRepository: GuidRepository,
  session: DiffSession,
  githubGateway: Pick<GithubGateway, "searchMetaByGuid">,
  owner: string,
  repo: string,
  repoKey: string,
  guids: string[],
): Promise<GuidResolution> {
  if (!guids.length) return { resolved: {}, rateLimited: false };
  const cached = await guidRepository.load(repoKey);
  const resolved: Record<string, string> = {};
  const unknown: string[] = [];
  for (const guid of guids) {
    // GUID values are untrusted keys, so inherited properties are not cache entries.
    const hit = Object.hasOwn(cached, guid) ? cached[guid] : undefined;
    if (hit !== undefined) resolved[guid] = hit;
    else unknown.push(guid);
  }
  const searchable = unknown.filter((guid) => !session.misses.has(`${repoKey}:${guid}`));
  const found: Record<string, string> = {};
  let rateLimited = false;
  for (const guid of searchable.slice(0, MAX_SEARCHES)) {
    const key = `${repoKey}:${guid}`;
    const pathResult = await session.searches.get(key, () => githubGateway.searchMetaByGuid(owner, repo, guid));
    if (!pathResult.ok) {
      if (isRateLimited(pathResult.error)) {
        rateLimited = true;
        break;
      }
      session.misses.add(key);
      continue;
    }
    if (pathResult.value) resolved[guid] = found[guid] = pathResult.value;
    else session.misses.add(key);
  }
  if (Object.keys(found).length) await guidRepository.save(repoKey, found);
  return { resolved, rateLimited };
}
