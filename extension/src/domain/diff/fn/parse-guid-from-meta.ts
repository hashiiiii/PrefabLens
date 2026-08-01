// Same rule as parseGuid in cli/src/resolve.zig: "guid:" at line start after trim
export function parseGuidFromMeta(meta: string): string | undefined {
  for (const line of meta.split("\n")) {
    const t = line.trim();
    if (t.startsWith("guid:")) return t.slice("guid:".length).trim();
  }
  return undefined;
}
