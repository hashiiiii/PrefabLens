import { parsePrUrl, scanUnityFiles, type FileEntry } from './detect';
import { createToggle } from './toggle';
import { render, renderError, renderLoading, renderTooLarge } from '../renderer/render';
import type { BackgroundError, SemanticDiffRequest, SemanticDiffResponse } from '../types';

const ERROR_TEXT: Record<BackgroundError, string> = {
  'pat-missing': 'Set a GitHub token in the PrefabLens options page.',
  'auth-failed': 'GitHub authentication failed. Check your token in the PrefabLens options page.',
  'rate-limited': 'GitHub rate limit exceeded. Wait a while and toggle again.',
  'fetch-failed': 'Could not fetch file contents from GitHub.',
  'diff-failed': 'Could not compute a semantic diff for this file.',
};

function attach(): void {
  const pr = parsePrUrl(location.pathname);
  if (!pr) return;
  for (const entry of scanUnityFiles(document)) attachToggle(pr, entry);
}

function attachToggle(pr: { owner: string; repo: string; prNumber: number }, entry: FileEntry): void {
  if (entry.header.hasAttribute('data-prefablens')) return;
  entry.header.setAttribute('data-prefablens', '');

  let host: HTMLElement | undefined;
  let requested = false;

  const toggle = createToggle((view) => {
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
    const request = (force?: boolean) => {
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
  });
  entry.header.append(toggle.element);
}

function requestDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse> {
  return (chrome.runtime.sendMessage(req) as Promise<SemanticDiffResponse>).catch(() => ({
    ok: false as const,
    error: 'fetch-failed' as const,
  }));
}

// GitHub は SPA: 初回スキャン + MutationObserver で遅延ロード・タブ遷移に追従(200ms デバウンス)。
attach();
let scheduled = false;
new MutationObserver(() => {
  if (scheduled) return;
  scheduled = true;
  setTimeout(() => {
    scheduled = false;
    attach();
  }, 200);
}).observe(document.body, { childList: true, subtree: true });
