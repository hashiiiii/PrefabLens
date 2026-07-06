import { parsePrPage, parsePrUrl, scanUnityFiles, type FileEntry } from './detect';
import { createToggle, type Toggle, type View } from './toggle';
import { createViewState, type ViewState } from './viewstate';
import { render, renderError, renderLoading, renderTooLarge } from '../renderer/render';
import type { BackgroundError, PrefetchRequest, SemanticDiffRequest, SemanticDiffResponse } from '../types';

const ERROR_TEXT: Record<BackgroundError, string> = {
  'pat-missing': 'Set a GitHub token in the PrefabLens options page.',
  'auth-failed': 'GitHub authentication failed. Check your token in the PrefabLens options page.',
  'rate-limited': 'GitHub rate limit exceeded. Wait a while and toggle again.',
  'fetch-failed': 'Could not fetch file contents from GitHub.',
  'diff-failed': 'Could not compute a semantic diff for this file.',
};

// 全体切り替えの適用先: attach 済みファイルのトグル + 表示を外から駆動する
type Applier = { header: HTMLElement; apply(view: View): void };
const appliers = new Set<Applier>();
let globalToggle: Toggle | undefined;
let currentPr = ''; // 上書きは PR 滞在中のみ有効: PR が変わったら捨てる
let prefetchedPr = ''; // conversation タブ含む全 PR タブで 1 回だけプリフェッチを送る

function attach(state: ViewState): void {
  const page = parsePrPage(location.pathname);
  if (!page) return;
  const pageKey = `${page.owner}/${page.repo}#${page.prNumber}`;
  if (pageKey !== prefetchedPr) {
    prefetchedPr = pageKey;
    // fire-and-forget: 応答は待たず、失敗も無視(手動トグル経路が別に生きている)
    void (chrome.runtime.sendMessage({ type: 'prefetch', ...page } satisfies PrefetchRequest) as Promise<unknown>).catch(() => {});
  }
  const pr = parsePrUrl(location.pathname);
  if (!pr) return;
  const key = `${pr.owner}/${pr.repo}#${pr.prNumber}`;
  if (key !== currentPr) {
    currentPr = key;
    state.clearOverrides();
  }
  const entries = scanUnityFiles(document);
  if (entries.length) ensureGlobalToggle(state, entries[0]!);
  for (const entry of entries) attachToggle(state, pr, entry);
}

/** 最初の Unity ファイルの .file コンテナ直前に全体トグルを 1 つだけ注入する。
 *  ツールバー DOM は GitHub 側の変更が激しいため、確実に存在する .file を錨にする。 */
function ensureGlobalToggle(state: ViewState, first: FileEntry): void {
  if (globalToggle?.element.closest('[data-prefablens-global]')?.isConnected) return;
  const container = first.header.closest('.file');
  if (!container?.parentElement) return;
  const bar = document.createElement('div');
  bar.setAttribute('data-prefablens-global', '');
  bar.style.cssText = 'display:flex;align-items:center;gap:8px;margin:0 0 8px;font:12px system-ui;';
  const label = document.createElement('span');
  label.textContent = 'PrefabLens';
  const toggle = createToggle((view) => state.setDefault(view), state.defaultView());
  bar.append(label, toggle.element);
  container.before(bar);
  globalToggle = toggle;
}

function attachToggle(state: ViewState, pr: { owner: string; repo: string; prNumber: number }, entry: FileEntry): void {
  if (entry.header.hasAttribute('data-prefablens')) return;
  entry.header.setAttribute('data-prefablens', '');

  let host: HTMLElement | undefined;
  let requested = false;

  const show = (view: View): void => {
    if (view === 'raw') {
      entry.content.style.display = '';
      if (host) host.style.display = 'none';
      return;
    }
    entry.content.style.display = 'none';
    if (!host) {
      host = document.createElement('div');
      host.setAttribute('data-prefablens-view', '');
      host.attachShadow({ mode: 'open' });
      entry.content.after(host);
    }
    host.style.display = '';
    if (requested) return; // 成功結果のみファイル単位でキャッシュ(再トグルで再フェッチしない)
    const root = host.shadowRoot!;
    const request = (force?: boolean): void => {
      requested = true;
      renderLoading(root);
      void requestDiff({ type: 'semanticDiff', ...pr, path: entry.path, force }).then((res) => {
        if (res.ok) return render(root, res.json);
        requested = false; // エラーはキャッシュしない: 次回トグルで再フェッチさせる
        if (res.error === 'too-large') renderTooLarge(root, res.bytes, () => request(true));
        else renderError(root, ERROR_TEXT[res.error]);
      });
    };
    request();
  };

  const toggle = createToggle((view) => {
    state.setOverride(entry.path, view); // クリックはこのファイルだけの上書き
    show(view);
  }, state.effective(entry.path));
  entry.header.append(toggle.element);
  appliers.add({ header: entry.header, apply: (view) => { toggle.set(view); show(view); } });

  // 既定が semantic なら attach 時点で描画開始: 遅延ロードされたファイルもここを通るので
  // 「全体は semantic なのに後から来たファイルだけ raw」は起きない
  if (state.effective(entry.path) === 'semantic') show('semantic');
}

function requestDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse> {
  return (chrome.runtime.sendMessage(req) as Promise<SemanticDiffResponse>).catch(() => ({
    ok: false as const,
    error: 'fetch-failed' as const,
  }));
}

async function init(): Promise<void> {
  const stored = await chrome.storage.local.get(['viewMode']).catch(() => ({}) as Record<string, unknown>);
  const initial: View = stored['viewMode'] === 'semantic' ? 'semantic' : 'raw';
  const state = createViewState(
    initial,
    (view) => void chrome.storage.local.set({ viewMode: view }).catch(() => {}),
  );
  state.onDefaultChange((view) => {
    globalToggle?.set(view);
    for (const a of [...appliers]) {
      if (!a.header.isConnected) {
        appliers.delete(a); // SPA 遷移で死んだ DOM の掃除
        continue;
      }
      a.apply(view);
    }
  });
  // 他タブでの既定変更に追随(set 元タブのエコーは applyExternal 側で無視される)
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    const next = changes['viewMode']?.newValue;
    if (next === 'raw' || next === 'semantic') state.applyExternal(next);
  });

  // GitHub は SPA: 初回スキャン + MutationObserver で遅延ロード・タブ遷移に追従(200ms デバウンス)。
  attach(state);
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      attach(state);
    }, 200);
  }).observe(document.body, { childList: true, subtree: true });
}

void init();
