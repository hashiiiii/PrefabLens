// Unity がテキストシリアライズ(UnityYAML)する拡張子。unityyamlmerge の対象と同じ集合。
// .meta(!u! ドキュメント形式でない)と .asmdef 等の JSON は対象外。
const UNITY_PATH =
  /\.(prefab|unity|asset|mat|anim|controller|overrideController|physicMaterial|physicsMaterial2D|playable|mask|brush|flare|fontsettings|guiskin|giparams|renderTexture|spriteatlas|spriteatlasv2|terrainlayer|mixer|shadervariants|preset|signal|lighting|scenetemplate)$/i;

export type FileEntry = { path: string; header: HTMLElement; content: HTMLElement };

export function parsePrUrl(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/files(\/|$)/.exec(pathname);
  return m ? { owner: m[1]!, repo: m[2]!, prNumber: Number(m[3]!) } : null;
}

// GitHub の Files changed(クラシック DOM)を防御的に探す。合わなければ空配列で無害に終わる。
export function scanUnityFiles(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const header of root.querySelectorAll<HTMLElement>('.file-header[data-path]')) {
    const path = header.dataset['path'];
    if (!path || !UNITY_PATH.test(path)) continue;
    const container = header.closest('.file');
    const content = container?.querySelector<HTMLElement>('.js-file-content') ?? null;
    if (!content) continue;
    out.push({ path, header, content });
  }
  return out;
}
