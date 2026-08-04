// The static fixture files next to the site demo page. The demo reads these
// files instead of the GitHub API (no GitHub, no chrome.*).
export type FixturesGateway = {
  fetchBytes(url: string): Promise<Uint8Array<ArrayBuffer>>;
  fetchSource(side: "before" | "after", path: string): Promise<Uint8Array>;
  loadGuidIndex(): Promise<Map<string, string>>;
};
