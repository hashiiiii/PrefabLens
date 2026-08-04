// These helpers read static fixture files next to the site demo page (no GitHub, no chrome.*).

export function createFixtureFetchBytes(): (url: string) => Promise<Uint8Array<ArrayBuffer>> {
  return async (url) => {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
  };
}

// build.mjs generates this guid → asset path map from the fixture .meta files.
export async function loadFixtureGuidIndex(): Promise<Map<string, string>> {
  const body = (await (await fetch("fixtures/guids.json")).json()) as Record<string, string>;
  return new Map(Object.entries(body));
}

export function createFixtureSourceFetch(
  fetchBytes: (url: string) => Promise<Uint8Array<ArrayBuffer>>,
): (side: "before" | "after", path: string) => Promise<Uint8Array> {
  // A missing source fixture degrades to the unmerged diff, like the extension does.
  return (side, path) => fetchBytes(`fixtures/${side}/${path}`).catch(() => new Uint8Array());
}
