export const TREE_CHAR_LIMIT = 50_000;

export interface DiffArgs {
  path: string;
  before: string;
  after?: string;
  format: 'tree' | 'json';
}

/** CLI 引数を組み立てる。--project . で cwd(= projectRoot)起点の .meta 走査による guid 解決を効かせる。 */
export function buildArgs(a: DiffArgs): string[] {
  const flags = a.format === 'json' ? ['--json'] : ['--no-color'];
  const refs = a.after === undefined ? [a.before] : [a.before, a.after];
  return [...flags, '--project', '.', '--git', ...refs, a.path];
}

/** LLM コンテキスト保護。tree 出力のみ対象(json は機械処理用途なので呼び出し側が使わない)。 */
export function truncateTree(text: string, limit = TREE_CHAR_LIMIT): string {
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}\n[truncated: ${text.length} chars total]\n`;
}
