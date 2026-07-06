// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { parsePrUrl, scanUnityFiles } from './detect';

const FIXTURE = `
  <div class="file">
    <div class="file-header" data-path="Assets/Foo.prefab"><div class="file-actions"></div></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="Assets/Scenes/Main.unity"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="Assets/Data/Config.asset"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="src/main.cs"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file-header" data-path="Assets/Orphan.prefab"></div>
`;

describe('parsePrUrl', () => {
  it('matches the PR files tab', () => {
    expect(parsePrUrl('/owner/repo/pull/42/files')).toEqual({ owner: 'owner', repo: 'repo', prNumber: 42 });
    expect(parsePrUrl('/owner/repo/pull/42/files/abc123')).toEqual({ owner: 'owner', repo: 'repo', prNumber: 42 });
  });
  it('rejects other pages', () => {
    expect(parsePrUrl('/owner/repo/pull/42')).toBeNull();
    expect(parsePrUrl('/owner/repo/blob/main/a.prefab')).toBeNull();
  });
});

describe('scanUnityFiles', () => {
  it('finds .prefab/.unity/.asset containers and skips other files', () => {
    document.body.innerHTML = FIXTURE;
    const entries = scanUnityFiles(document);
    expect(entries.map((e) => e.path)).toEqual(['Assets/Foo.prefab', 'Assets/Scenes/Main.unity', 'Assets/Data/Config.asset']);
    expect(entries[0]!.content.classList.contains('js-file-content')).toBe(true);
  });

  it('is harmless when the expected structure is missing (defensive selectors)', () => {
    document.body.innerHTML = '<div>totally different markup</div>';
    expect(scanUnityFiles(document)).toEqual([]);
  });
});
