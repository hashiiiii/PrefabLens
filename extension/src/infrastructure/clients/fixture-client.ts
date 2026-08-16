import type { FixturesGateway } from "../../application/gateway/fixtures";

// Reads static fixture files next to the site demo page (no GitHub, no chrome.*).
export function createFixturesGateway(): FixturesGateway {
  const fetchBytes = async (url: string): Promise<Uint8Array<ArrayBuffer>> => {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
  };
  return {
    fetchBytes,
    // A missing source fixture degrades to the unmerged diff, like the extension does.
    fetchSource: (side, path) => fetchBytes(`fixtures/${side}/${path}`).catch(() => new Uint8Array()),
    // build.mjs generates this guid → asset path map from the fixture .meta files.
    async loadGuidIndex() {
      const body = (await (await fetch("fixtures/guids.json")).json()) as Record<string, string>;
      return new Map(Object.entries(body));
    },
  };
}
