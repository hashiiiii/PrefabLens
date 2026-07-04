import { originOf } from '../github/client';

export type ChromeGhes = {
  permissions: { request(p: { origins: string[] }): Promise<boolean> };
  scripting: {
    registerContentScripts(scripts: object[]): Promise<void>;
    unregisterContentScripts(filter: { ids: string[] }): Promise<void>;
  };
};

const ID = 'prefablens-ghes';

/** baseUrl が GHES を指すときの content script 注入対象。match pattern はポート不可(ポートなしは全ポート一致)。 */
export function ghesOrigins(baseUrl: string): string[] | null {
  if (!baseUrl) return null;
  const origin = originOf(baseUrl);
  if (origin === 'https://github.com') return null;
  const u = new URL(origin);
  return [`${u.protocol}//${u.hostname}/*`];
}

/** Save クリック(user gesture)内で呼ぶ: 権限要求 → content script 動的登録。登録は永続なので起動時処理は不要。
 *  permissions.request は gesture 失効を避けるため他の await より先に呼ぶ。 */
export async function applyGhes(baseUrl: string, c: ChromeGhes): Promise<'ok' | 'declined'> {
  const origins = ghesOrigins(baseUrl); // 不正 URL はここで throw → 呼び出し側が 'failed' 扱い
  const granted = !origins || (await c.permissions.request({ origins }));
  await c.scripting.unregisterContentScripts({ ids: [ID] }).catch(() => {}); // 未登録だと reject する
  if (!origins) return 'ok';
  if (!granted) return 'declined';
  await c.scripting.registerContentScripts([{ id: ID, matches: origins, js: ['content.js'], runAt: 'document_idle' }]);
  return 'ok';
}
