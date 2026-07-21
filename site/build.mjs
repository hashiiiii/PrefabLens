// Demo-content build, step 1 of 2. Everything visitors see is produced by the
// real product code: the CLI binary renders the report and terminal tree, the
// extension's demo bundle powers the mock PR page, and git provides the raw
// diffs. Run `zig build && zig build wasm` and `pnpm run demo` (in extension/)
// first. Outputs land in generated/ (HTML fragments the .md pages import) and
// public/ (runtime assets VitePress copies verbatim); step 2 is `vitepress
// build` (see package.json "build").
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ansiToHtml } from "./src/ansi.mjs";

const SITE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SITE, "..");
const BIN = join(ROOT, "zig-out", "bin", process.platform === "win32" ? "prefablens.exe" : "prefablens");
const WASM = join(ROOT, "zig-out", "bin", "prefablens.wasm");
const DEMO = join(ROOT, "extension", "dist", "demo.js");
const FIXTURES = join(SITE, "fixtures");
const GENERATED = join(SITE, "generated");
const PUBLIC = join(SITE, "public");
const DIST = join(SITE, "dist");

// Mirror of the UnityYAML extension gate in cli/src/unity_path.zig (and
// extension/src/unity.ts): only these paths get semantic views; anything else
// (e.g. .meta) would keep GitHub's plain diff in the mock.
const UNITY_EXTENSIONS = [
  ".prefab", ".unity", ".asset", ".mat", ".anim", ".controller",
  ".overridecontroller", ".physicmaterial", ".physicsmaterial2d", ".playable",
  ".mask", ".brush", ".flare", ".fontsettings", ".guiskin", ".giparams",
  ".rendertexture", ".spriteatlas", ".spriteatlasv2", ".terrainlayer",
  ".mixer", ".shadervariants", ".preset", ".signal", ".lighting", ".scenetemplate",
];
const isUnityPath = (path) => UNITY_EXTENSIONS.some((ext) => path.toLowerCase().endsWith(ext));

// The demos show exactly these fixtures, top to bottom: .prefab, .unity, then
// .asset. The CLI orders its bulk output by path, which matches because the
// fixture folders sort the same way (Prefabs < Scenes < Settings) — moving or
// renaming a fixture must keep that true. The unchanged companions next to
// them (.meta, .cs, .mat) never appear in the diff; they exist so guid
// references resolve to asset paths, exactly like in a real Unity project.
const DEMO_FILES = [
  "Assets/Prefabs/Robot.prefab",
  "Assets/Prefabs/RobotVariant.prefab",
  "Assets/Scenes/Playground.unity",
  "Assets/Settings/Fixture.asset",
];
// Robot.prefab is the landing-page hero: a compact diff with modified, added,
// and removed components plus a child object.
const HERO_FILE = "Assets/Prefabs/Robot.prefab";

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
 *  from `git diff --name-status` with rename detection, in DEMO_FILES order. */
function changedFiles(repo) {
  const files = [];
  for (const line of git(repo, "diff", "--name-status", "-M", "main").trimEnd().split("\n")) {
    const [st, a, b] = line.split("\t");
    if (st.startsWith("R")) files.push({ before: a, after: b });
    else if (st === "A") files.push({ before: null, after: a });
    else if (st === "D") files.push({ before: a, after: null });
    else files.push({ before: a, after: a });
  }
  const rank = (f) => DEMO_FILES.indexOf(f.after ?? f.before);
  return files.sort((x, y) => rank(x) - rank(y));
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

/** guid → asset path from the fixture .meta files — the demo's stand-in for the
 *  extension's repo guid index (same "guid:" line rule as parseGuidFromMeta in
 *  extension/src/github/guids.ts and cli/src/resolve.zig). */
function guidIndex(side) {
  const root = join(FIXTURES, side);
  const index = {};
  for (const entry of readdirSync(root, { recursive: true })) {
    const path = String(entry);
    if (!path.endsWith(".meta")) continue;
    const meta = readFileSync(join(root, path), "utf8");
    const guid = meta.split("\n").map((l) => l.trim()).find((l) => l.startsWith("guid:"));
    if (guid) index[guid.slice("guid:".length).trim()] = path.slice(0, -".meta".length).replaceAll("\\", "/");
  }
  return index;
}

assertBuilt(BIN, "zig build");
assertBuilt(WASM, "zig build wasm");
assertBuilt(DEMO, "pnpm run demo (in extension/)");
rmSync(GENERATED, { recursive: true, force: true });
mkdirSync(GENERATED, { recursive: true });
// Eleventy does not clean its output directory, so stale files from previous
// builds would ship; step 1 owns the clean slate.
rmSync(DIST, { recursive: true, force: true });
// public/ mixes committed assets (favicon.svg, images/) with generated ones,
// so remove only what this script owns instead of wiping the directory.
for (const entry of ["hero-report.html", "cli-report.html", "demo.js", "prefablens.wasm", "fixtures"]) {
  rmSync(join(PUBLIC, entry), { recursive: true, force: true });
}

const repo = makeDemoRepo();
let report;
let heroReport;
try {
  // CLI outputs: the --open report page, the tree view (--color because stdout
  // is a pipe here; a terminal gets color automatically), and the single-file
  // hero report the landing page frames next to the raw diff. Guid references
  // resolve against the fixture .meta files by default (no --project needed).
  report = execFileSync(BIN, ["--html", "main"], { cwd: repo, encoding: "utf8" });
  const tree = execFileSync(BIN, ["--color", "main"], { cwd: repo, encoding: "utf8" });
  heroReport = execFileSync(BIN, ["--html", "main", HERO_FILE], { cwd: repo, encoding: "utf8" });
  const files = changedFiles(repo);

  // Smoke asserts: a palette, renderer, or fixture change must fail the build,
  // not ship a silently broken page.
  if (!report.includes("pl-")) throw new Error("CLI report lost its pl- classes");
  if (!heroReport.includes("Rigidbody")) throw new Error("hero report is missing the Robot diff");
  if (!heroReport.includes("Assets/Scripts/FixtureBehaviour.cs")) throw new Error("hero report lost guid resolution");
  if (tree.includes("unresolved")) throw new Error("tree output has unresolved guid references");
  // Playground.unity references built-in meshes and Default-Material: those
  // must render as "<name> (built-in)", never as a raw 32-hex engine guid.
  if (!report.includes("(built-in)")) throw new Error("report lost built-in ref names");
  if (report.includes("guid:0000000000000000")) throw new Error("report shows raw built-in guids");
  if (!ansiToHtml(tree).includes("<span")) throw new Error("tree output lost its ANSI colors");
  const paths = files.map((f) => f.after ?? f.before);
  if (paths.join("\n") !== DEMO_FILES.join("\n")) {
    throw new Error(`demo files drifted from DEMO_FILES:\n${paths.join("\n")}`);
  }

  writeFileSync(join(GENERATED, "hero-diff.html"), diffTable(git(repo, "diff", "main", "--", HERO_FILE)).table);
  const prMeta = `<p class="pr-meta">${files.length} files changed, merging <span class="branch">feat/robot-rebalance</span> into <span class="branch">main</span></p>`;
  writeFileSync(join(GENERATED, "pr-files.html"), `${prMeta}\n${files.map((f) => fileSection(repo, f)).join("\n\n")}`);
  writeFileSync(
    join(GENERATED, "terminal.html"),
    `<span class="prompt">$</span> prefablens main\n${ansiToHtml(tree.trimEnd())}`,
  );
} finally {
  rmSync(repo, { recursive: true, force: true });
}

writeFileSync(join(PUBLIC, "hero-report.html"), heroReport);
writeFileSync(join(PUBLIC, "cli-report.html"), report);
cpSync(join(FIXTURES, "before"), join(PUBLIC, "fixtures", "before"), { recursive: true });
cpSync(join(FIXTURES, "after"), join(PUBLIC, "fixtures", "after"), { recursive: true });
// demo.js resolves guid references and fetches needed source prefabs by path
// through this index, standing in for the extension's GitHub-backed one.
writeFileSync(join(PUBLIC, "fixtures", "guids.json"), JSON.stringify(guidIndex("after"), null, 2));
cpSync(WASM, join(PUBLIC, "prefablens.wasm"));
cpSync(DEMO, join(PUBLIC, "demo.js"));

console.log(`fragments in ${GENERATED}, assets in ${PUBLIC}`);
