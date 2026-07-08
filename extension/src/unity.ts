// Extensions that Unity text-serializes (UnityYAML). Same set as unityyamlmerge targets.
// Excludes .meta (not !u! document format) and JSON like .asmdef.
const UNITY_PATH =
  /\.(prefab|unity|asset|mat|anim|controller|overrideController|physicMaterial|physicsMaterial2D|playable|mask|brush|flare|fontsettings|guiskin|giparams|renderTexture|spriteatlas|spriteatlasv2|terrainlayer|mixer|shadervariants|preset|signal|lighting|scenetemplate)$/i;

/** Content detection and background prefetch share the same check. */
export function isUnityPath(path: string): boolean {
  return UNITY_PATH.test(path);
}
