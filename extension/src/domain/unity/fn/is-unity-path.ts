// UnityYAML extensions (same set as unityyamlmerge / Unity.gitattributes):
// https://github.com/gitattributes/gitattributes/blob/master/Unity.gitattributes
// Excludes .meta and JSON (.asmdef). Prefilter only — content truth is wasm isUnityYaml.
const UNITY_PATH =
  /\.(prefab|unity|asset|mat|anim|controller|overrideController|physicMaterial|physicsMaterial2D|playable|mask|brush|flare|fontsettings|guiskin|giparams|renderTexture|spriteatlas|spriteatlasv2|terrainlayer|mixer|shadervariants|preset|signal|lighting|scenetemplate)$/i;

// Shared by content detection and background prefetch.
export function isUnityPath(path: string): boolean {
  return UNITY_PATH.test(path);
}
