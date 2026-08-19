import { describe, expect, it } from "vitest";
import { createDiffSession } from "../../../src/application/diff/create-diff-session";
import { resolveGuids } from "../../../src/application/internal/guid-resolution";
import type { GuidRepository } from "../../../src/domain/guid/guid-repository";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";

class MemoryGuidRepository implements GuidRepository {
  constructor(private readonly cached: Record<string, Record<string, string>> = {}) {}

  async load(repo: string): Promise<Record<string, string>> {
    return this.cached[repo] ?? {};
  }

  async save(repo: string, entries: Record<string, string>): Promise<void> {
    this.cached[repo] = { ...this.cached[repo], ...entries };
  }
}

function searchRoutes(respond: (request: URL) => Response | Promise<Response>) {
  const requests: URL[] = [];
  const fetchRoute = (async (input: RequestInfo | URL) => {
    const request = new URL(String(input));
    requests.push(request);
    return respond(request);
  }) as typeof fetch;
  return { requests, client: createGithubGateway("https://api.github.test", "token", fetchRoute) };
}

describe("resolveGuids", () => {
  it("uses the persistent GUID cache before Code Search", async () => {
    const repository = new MemoryGuidRepository({
      "https://api.github.test:o/r": { cached: "Assets/Cached.prefab" },
    });
    const { client, requests } = searchRoutes(() => new Response(null, { status: 500 }));

    const result = await resolveGuids(
      repository,
      createDiffSession(),
      client,
      "o",
      "r",
      "https://api.github.test:o/r",
      ["cached"],
    );

    expect(result).toEqual({ resolved: { cached: "Assets/Cached.prefab" }, rateLimited: false });
    expect(requests).toHaveLength(0);
  });

  it("does not read Object.prototype values as cached GUIDs", async () => {
    const repository = new MemoryGuidRepository({
      "https://api.github.test:o/r": { other: "Assets/Other.prefab" },
    });
    const { client, requests } = searchRoutes(() => Response.json({ items: [{ path: "Assets/Sound.prefab.meta" }] }));

    const result = await resolveGuids(
      repository,
      createDiffSession(),
      client,
      "o",
      "r",
      "https://api.github.test:o/r",
      ["constructor"],
    );

    expect(result).toEqual({ resolved: { constructor: "Assets/Sound.prefab" }, rateLimited: false });
    expect(requests).toHaveLength(1);
  });

  it("stops after ten Code Search requests", async () => {
    const repository = new MemoryGuidRepository();
    const { client, requests } = searchRoutes(() => Response.json({ items: [{ path: "Assets/Sound.prefab.meta" }] }));

    const result = await resolveGuids(
      repository,
      createDiffSession(),
      client,
      "o",
      "r",
      "https://api.github.test:o/r",
      [
        "guid-0",
        "guid-1",
        "guid-2",
        "guid-3",
        "guid-4",
        "guid-5",
        "guid-6",
        "guid-7",
        "guid-8",
        "guid-9",
        "guid-10",
        "guid-11",
      ],
    );

    expect(requests).toHaveLength(10);
    expect(Object.keys(result.resolved)).toEqual([
      "guid-0",
      "guid-1",
      "guid-2",
      "guid-3",
      "guid-4",
      "guid-5",
      "guid-6",
      "guid-7",
      "guid-8",
      "guid-9",
    ]);
  });

  it("reports a Code Search rate limit without dropping resolved names", async () => {
    const repository = new MemoryGuidRepository();
    const { client, requests } = searchRoutes((request) => {
      if (request.searchParams.get("q")?.includes('"first"')) {
        return Response.json({ items: [{ path: "Assets/Sound.prefab.meta" }] });
      }
      return new Response(null, { status: 429, headers: { "retry-after": "1" } });
    });

    const result = await resolveGuids(
      repository,
      createDiffSession(),
      client,
      "o",
      "r",
      "https://api.github.test:o/r",
      ["first", "second", "third"],
    );

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
      return Response.json({ items: [{ path: "Assets/Sound.prefab.meta" }] });
    });
    const session = createDiffSession();

    const first = resolveGuids(repository, session, client, "o", "r", "https://api.github.test:o/r", ["shared"]);
    await routeStarted;
    const second = resolveGuids(repository, session, client, "o", "r", "https://api.github.test:o/r", ["shared"]);
    await Promise.resolve();
    releaseRoute();

    await expect(Promise.all([first, second])).resolves.toEqual([
      { resolved: { shared: "Assets/Sound.prefab" }, rateLimited: false },
      { resolved: { shared: "Assets/Sound.prefab" }, rateLimited: false },
    ]);
    expect(requests).toHaveLength(1);
  });
});
