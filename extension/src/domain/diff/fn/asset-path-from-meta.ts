// The asset for "Foo.prefab.meta" is "Foo.prefab". Callers pass only paths
// that end with ".meta".
export function assetPathFromMeta(metaPath: string): string {
  return metaPath.slice(0, -".meta".length);
}
