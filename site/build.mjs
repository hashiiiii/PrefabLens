// Demo-site build. Everything visitors see is produced by the real product code:
// the CLI binary renders the report and terminal tree, the extension renderer is
// bundled as-is for the mock PR page, and git provides the raw diffs. Run
// `zig build && zig build wasm` first.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ansiToHtml } from "./src/ansi.mjs";

// The site has no package of its own: the only build dependency is esbuild,
// borrowed from the extension package (run `pnpm install` in extension/ first).
const { build } = createRequire(new URL("../extension/package.json", import.meta.url))("esbuild");

const SITE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SITE, "..");
const BIN = join(ROOT, "zig-out", "bin", process.platform === "win32" ? "prefablens.exe" : "prefablens");
const WASM = join(ROOT, "zig-out", "bin", "prefablens.wasm");
const FIXTURES = join(SITE, "fixtures");
const DIST = join(SITE, "dist");

// Mirror of the UnityYAML extension gate in cli/src/unity_path.zig (and the
// extension's detect.ts): only these paths get semantic views; .meta and other
// files keep GitHub's plain diff in the mock.
const UNITY_EXTENSIONS = [
  ".prefab", ".unity", ".asset", ".mat", ".anim", ".controller",
  ".overridecontroller", ".physicmaterial", ".physicsmaterial2d", ".playable",
  ".mask", ".brush", ".flare", ".fontsettings", ".guiskin", ".giparams",
  ".rendertexture", ".spriteatlas", ".spriteatlasv2", ".terrainlayer",
  ".mixer", ".shadervariants", ".preset", ".signal", ".lighting", ".scenetemplate",
];
const isUnityPath = (path) => UNITY_EXTENSIONS.some((ext) => path.toLowerCase().endsWith(ext));

function assertBuilt(path, hint) {
  if (!existsSync(path)) throw new Error(`${path} not found — run \`${hint}\` first`);
}

function git(cwd, ...args) {
  return execFileSync("git", ["-c", "user.name=demo", "-c", "user.email=demo@example.com", ...args], {
    cwd,
    encoding: "utf8",
  });
}

/** Builds the demo repo: main holds fixtures/before, the worktree fixtures/after.
 *  One ref vs worktree is exactly `prefablens main` semantics (cli/src/input.zig). */
function makeDemoRepo() {
  const repo = mkdtempSync(join(tmpdir(), "prefablens-site-"));
  git(repo, "init", "-q", "-b", "main");
  cpSync(join(FIXTURES, "before"), repo, { recursive: true });
  git(repo, "add", "-A");
  git(repo, "commit", "-q", "-m", "before");
  // Swap the worktree to the after state: deletions of tracked files show up in
  // `git diff main` on their own; added files need intent-to-add to be listed.
  for (const entry of readdirSync(repo)) if (entry !== ".git") rmSync(join(repo, entry), { recursive: true });
  cpSync(join(FIXTURES, "after"), repo, { recursive: true });
  git(repo, "add", "-A", "-N");
  return repo;
}

/** Changed files as {before, after} path pairs (null on the added/removed side),
 *  from `git diff --name-status` with rename detection, GitHub-like order. */
function changedFiles(repo) {
  const files = [];
  for (const line of git(repo, "diff", "--name-status", "-M", "main").trimEnd().split("\n")) {
    const [st, a, b] = line.split("\t");
    if (st.startsWith("R")) files.push({ before: a, after: b });
    else if (st === "A") files.push({ before: null, after: a });
    else if (st === "D") files.push({ before: a, after: null });
    else files.push({ before: a, after: a });
  }
  return files.sort((x, y) => (x.after ?? x.before).localeCompare(y.after ?? y.before));
}

function escapeHtml(text) {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

/** GitHub-style diff table from `git diff` unified output: hunk header rows plus
 *  add/del/context rows with old/new line-number gutters. */
function diffTable(unified) {
  const rows = [];
  let added = 0;
  let removed = 0;
  let oldN = 0;
  let newN = 0;
  let inHunk = false;
  for (const line of unified.split("\n")) {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (hunk) {
      inHunk = true;
      oldN = Number(hunk[1]);
      newN = Number(hunk[2]);
      rows.push(`<tr class="hunk"><td colspan="2"></td><td class="code">${escapeHtml(line)}</td></tr>`);
      continue;
    }
    if (!inHunk || line === "\\ No newline at end of file") continue;
    if (line.startsWith("+")) {
      added += 1;
      rows.push(`<tr class="add"><td class="num"></td><td class="num">${newN++}</td><td class="code">+${escapeHtml(line.slice(1))}</td></tr>`);
    } else if (line.startsWith("-")) {
      removed += 1;
      rows.push(`<tr class="del"><td class="num">${oldN++}</td><td class="num"></td><td class="code">-${escapeHtml(line.slice(1))}</td></tr>`);
    } else if (line.startsWith(" ") || line === "") {
      rows.push(`<tr><td class="num">${oldN++}</td><td class="num">${newN++}</td><td class="code"> ${escapeHtml(line.slice(1))}</td></tr>`);
    }
  }
  const body = rows.length
    ? `<table class="diff-table">${rows.join("")}</table>`
    : '<p class="hint file-empty">File renamed without changes.</p>';
  const stat = `<span class="added">+${added}</span> <span class="removed">−${removed}</span>`;
  return { table: body, stat };
}

const COLLAPSE_BUTTON =
  '<button type="button" class="file-collapse" aria-label="Collapse file">' +
  '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
  '<path d="M6.22 3.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L9.94 8 6.22 4.28a.75.75 0 0 1 0-1.06Z"/></svg></button>';

/** One GitHub-style file container. Unity files carry data-before/data-after
 *  fixture URLs; demo.js turns exactly those into semantic views. */
function fileSection(repo, file) {
  const path = file.after ?? file.before;
  const renamed = file.before !== null && file.after !== null && file.before !== file.after;
  const args = ["diff", "-M", "main", "--"];
  args.push(file.before ?? file.after);
  if (renamed) args.push(file.after);
  const { table, stat } = diffTable(git(repo, ...args));
  const label = renamed ? `${escapeHtml(file.before)} → ${escapeHtml(path)}` : escapeHtml(path);
  const sources = isUnityPath(path)
    ? ` data-before="${file.before ? `fixtures/before/${escapeHtml(file.before)}` : ""}"` +
      ` data-after="${file.after ? `fixtures/after/${escapeHtml(file.after)}` : ""}"`
    : "";
  return `      <div class="file js-details-container Details Details--on open">
        <div class="file-header" data-path="${escapeHtml(path)}"${sources}>
          ${COLLAPSE_BUTTON}
          <span class="file-info">${label}</span>
          <span class="file-stat">${stat}</span>
        </div>
        <div class="js-file-content Details-content--hidden">${table}</div>
      </div>`;
}

function inject(html, token, replacement) {
  const needle = `<!--{{${token}}}-->`;
  if (!html.includes(needle)) throw new Error(`token ${needle} not found`);
  return html.replace(needle, replacement);
}

assertBuilt(BIN, "zig build");
assertBuilt(WASM, "zig build wasm");
rmSync(DIST, { recursive: true, force: true });
mkdirSync(DIST, { recursive: true });

const repo = makeDemoRepo();
let report;
let tree;
let extension;
try {
  // CLI outputs: the --open report page, and the tree view (--color because
  // stdout is a pipe here; a terminal gets color automatically).
  report = execFileSync(BIN, ["--html", "main"], { cwd: repo, encoding: "utf8" });
  tree = execFileSync(BIN, ["--color", "main"], { cwd: repo, encoding: "utf8" });

  const files = changedFiles(repo);
  extension = readFileSync(join(SITE, "static", "extension.html"), "utf8");
  extension = inject(extension, "FILECOUNT", String(files.length));
  extension = inject(extension, "FILES", files.map((f) => fileSection(repo, f)).join("\n\n"));

  // Smoke asserts: a palette or renderer change must fail the build, not ship a
  // silently broken page.
  if (!report.includes("pl-")) throw new Error("CLI report lost its pl- classes");
  if (!report.includes("Robot.prefab")) throw new Error("report is missing Robot.prefab");
  if (!ansiToHtml(tree).includes("<span")) throw new Error("tree output lost its ANSI colors");
  if (files.length < 20) throw new Error(`expected the full fixture PR, got ${files.length} files`);
} finally {
  rmSync(repo, { recursive: true, force: true });
}

writeFileSync(join(DIST, "cli-report.html"), report);
let cli = readFileSync(join(SITE, "static", "cli.html"), "utf8");
cli = inject(cli, "TERMINAL", ansiToHtml(tree.trimEnd()));
writeFileSync(join(DIST, "cli.html"), cli);
writeFileSync(join(DIST, "extension.html"), extension);
for (const page of [cli, extension]) if (page.includes("{{")) throw new Error("unreplaced template token");

cpSync(join(FIXTURES, "before"), join(DIST, "fixtures", "before"), { recursive: true });
cpSync(join(FIXTURES, "after"), join(DIST, "fixtures", "after"), { recursive: true });
cpSync(WASM, join(DIST, "prefablens.wasm"));
for (const file of ["index.html", "site.css", "favicon.svg"]) cpSync(join(SITE, "static", file), join(DIST, file));

await build({
  entryPoints: { demo: join(SITE, "src", "demo.ts") },
  bundle: true,
  format: "iife",
  target: "chrome120",
  minify: true,
  outdir: DIST,
});

assertBuilt(join(DIST, "demo.js"), "esbuild bundle");
console.log(`site built at ${DIST}`);
