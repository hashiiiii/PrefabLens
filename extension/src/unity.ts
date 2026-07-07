// Unity がテキストシリアライズ(UnityYAML)する拡張子。unityyamlmerge の対象と同じ集合。
// .meta(!u! ドキュメント形式でない)と .asmdef 等の JSON は対象外。
const UNITY_PATH =
  /\.(prefab|unity|asset|mat|anim|controller|overrideController|physicMaterial|physicsMaterial2D|playable|mask|brush|flare|fontsettings|guiskin|giparams|renderTexture|spriteatlas|spriteatlasv2|terrainlayer|mixer|shadervariants|preset|signal|lighting|scenetemplate)$/i;

/** content の検出と background のプリフェッチが同じ判定を共有する。 */
export function isUnityPath(path: string): boolean {
  return UNITY_PATH.test(path);
}
