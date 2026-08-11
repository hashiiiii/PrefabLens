import { describe, expect, it } from "vitest";
import { createDiffSession } from "../../src/application/diff/create-diff-session";
import { resolveGuids } from "../../src/application/internal/guid-resolution";
import type { GuidRepository } from "../../src/domain/guid/guid-repository";
import { GithubClient } from "../../src/infrastructure/clients/github-client";

const REPO_KEY = "https://api.github.test:o/r";

class MemoryGuidRepository implements GuidRepository {
  readonly saves: Array<{ repo: string; entries: Record<string, string> }> = [];

  constructor(private readonly cached: Record<string, Record<string, string>> = {}) {}

  async load(repo: string): Promise<Record<string, string>> {
    return this.cached[repo] ?? {};
  }

  async save(repo: string, entries: Record<string, string>): Promise<void> {
    this.saves.push({ repo, entries });
    this.cached[repo] = { ...this.cached[repo], ...entries };
  }
}

function searchRoutes(respond: (request: URL, requestCount: number) => Response | Promise<Response>) {
  const requests: URL[] = [];
  const fetchRoute = (async (input: RequestInfo | URL) => {
    const request = new URL(String(input));
    requests.push(request);
    return respond(request, requests.length);
  }) as typeof fetch;
  return { requests, client: new GithubClient("https://api.github.test", "token", fetchRoute) };
}

function searchSuccess(): Response {
  return new Response(JSON.stringify({ items: [{ path: "Assets/Sound.prefab.meta" }] }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

describe("resolveGuids", () => {
  it("uses the persistent GUID cache before Code Search", async () => {
    const repository = new MemoryGuidRepository({ [REPO_KEY]: { cached: "Assets/Cached.prefab" } });
    const { client, requests } = searchRoutes(() => new Response(null, { status: 500 }));

    const result = await resolveGuids(repository, createDiffSession(), client, "o", "r", REPO_KEY, ["cached"]);

    expect(result).toEqual({ resolved: { cached: "Assets/Cached.prefab" }, rateLimited: false });
    expect(requests).toHaveLength(0);
  });

  it("does not read Object.prototype values as cached GUIDs", async () => {
    const repository = new MemoryGuidRepository({ [REPO_KEY]: { other: "Assets/Other.prefab" } });
    const { client, requests } = searchRoutes(() => searchSuccess());

    const result = await resolveGuids(repository, createDiffSession(), client, "o", "r", REPO_KEY, ["constructor"]);

    expect(result).toEqual({ resolved: { constructor: "Assets/Sound.prefab" }, rateLimited: false });
    expect(requests).toHaveLength(1);
  });

  it("stops after ten Code Search requests", async () => {
    const repository = new MemoryGuidRepository();
    const { client, requests } = searchRoutes(() => searchSuccess());
    const guids = Array.from({ length: 12 }, (_, index) => `guid-${index}`);

    const result = await resolveGuids(repository, createDiffSession(), client, "o", "r", REPO_KEY, guids);

    expect(requests).toHaveLength(10);
    expect(Object.keys(result.resolved)).toEqual(guids.slice(0, 10));
  });

  it("reports a Code Search rate limit without dropping resolved names", async () => {
    const repository = new MemoryGuidRepository();
    const { client, requests } = searchRoutes((_request, requestCount) =>
      requestCount === 1 ? searchSuccess() : new Response(null, { status: 429, headers: { "retry-after": "1" } }),
    );

    const result = await resolveGuids(repository, createDiffSession(), client, "o", "r", REPO_KEY, [
      "first",
      "second",
      "third",
    ]);

    expect(result).toEqual({ resolved: { first: "Assets/Sound.prefab" }, rateLimited: true });
    expect(requests).toHaveLength(2);
  });

  it("shares one concurrent Code Search request for the same GUID", async () => {
    let startRoute!: () => void;
    const routeStarted = new Promise<void>((resolve) => {
      startRoute = resolve;
    });
    let releaseRoute!: () => void;
    const routeReleased = new Promise<void>((resolve) => {
      releaseRoute = resolve;
    });
    const repository = new MemoryGuidRepository();
    const { client, requests } = searchRoutes(async () => {
      startRoute();
      await routeReleased;
      return searchSuccess();
    });
    const session = createDiffSession();

    const first = resolveGuids(repository, session, client, "o", "r", REPO_KEY, ["shared"]);
    await routeStarted;
    const second = resolveGuids(repository, session, client, "o", "r", REPO_KEY, ["shared"]);
    await Promise.resolve();
    releaseRoute();

    await expect(Promise.all([first, second])).resolves.toEqual([
      { resolved: { shared: "Assets/Sound.prefab" }, rateLimited: false },
      { resolved: { shared: "Assets/Sound.prefab" }, rateLimited: false },
    ]);
    expect(requests).toHaveLength(1);
  });
});
