// Demo-site build. Everything visitors see is produced by the real product code:
// the CLI binary renders the report and terminal tree, the extension renderer is
// bundled as-is for the mock PR page, and git provides the raw diffs. Run
// `zig build && zig build wasm` first.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { ansiToHtml } from "./src/ansi.mjs";

const SITE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SITE, "..");
const BIN = join(ROOT, "zig-out", "bin", process.platform === "win32" ? "prefablens.exe" : "prefablens");
const WASM = join(ROOT, "zig-out", "bin", "prefablens.wasm");
const TESTDATA = join(ROOT, "core", "src", "testdata");
const DIST = join(SITE, "dist");

// Demo-repo layout: fixture pairs from the test corpus placed at Unity-project
// paths, plus one non-Unity file to show the tools leave it alone.
const FIXTURES = [
  { repoPath: "Assets/Cylinder.prefab", before: "cylinder_before.prefab", after: "cylinder_after.prefab" },
  { repoPath: "Assets/Materials/Rock.mat", before: "material_before.mat", after: "material_after.mat" },
  { repoPath: "Assets/Animations/Player.controller", before: "animator_before.controller", after: "animator_after.controller" },
];
const README_BEFORE = "# Demo Project\n\nFixture assets for the PrefabLens demo.\n";
const README_AFTER = `${README_BEFORE}\nTuned the cylinder physics and the rock material.\n`;

function assertBuilt(path, hint) {
  if (!existsSync(path)) throw new Error(`${path} not found — run \`${hint}\` first`);
}

function git(cwd, ...args) {
  return execFileSync("git", ["-c", "user.name=demo", "-c", "user.email=demo@example.com", ...args], {
    cwd,
    encoding: "utf8",
  });
}

/** Builds the demo repo: main holds the before state, the worktree the after state.
 *  One ref vs worktree is exactly `prefablens main` semantics (cli/src/input.zig). */
function makeDemoRepo() {
  const repo = mkdtempSync(join(tmpdir(), "prefablens-site-"));
  git(repo, "init", "-q", "-b", "main");
  writeFileSync(join(repo, "README.md"), README_BEFORE);
  for (const f of FIXTURES) {
    mkdirSync(dirname(join(repo, f.repoPath)), { recursive: true });
    cpSync(join(TESTDATA, f.before), join(repo, f.repoPath));
  }
  git(repo, "add", "-A");
  git(repo, "commit", "-q", "-m", "before");
  writeFileSync(join(repo, "README.md"), README_AFTER);
  for (const f of FIXTURES) cpSync(join(TESTDATA, f.after), join(repo, f.repoPath));
  return repo;
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
  const stat = `<span class="added">+${added}</span> <span class="removed">−${removed}</span>`;
  return { table: `<table class="diff-table">${rows.join("")}</table>`, stat };
}

function inject(html, token, replacement) {
  const needle = `<!--{{${token}}}-->`;
  if (!html.includes(needle)) throw new Error(`token ${needle} not found`);
  return html.replace(needle, replacement);
}

assertBuilt(BIN, "zig build");
assertBuilt(WASM, "zig build wasm");
rmSync(DIST, { recursive: true, force: true });
mkdirSync(join(DIST, "fixtures"), { recursive: true });

const repo = makeDemoRepo();
try {
  // CLI outputs: the --open report page, and the tree view (--color because
  // stdout is a pipe here; a terminal gets color automatically).
  const report = execFileSync(BIN, ["--html", "main"], { cwd: repo, encoding: "utf8" });
  const tree = execFileSync(BIN, ["--color", "main"], { cwd: repo, encoding: "utf8" });

  writeFileSync(join(DIST, "cli-report.html"), report);
  let cli = readFileSync(join(SITE, "static", "cli.html"), "utf8");
  cli = inject(cli, "TERMINAL", ansiToHtml(tree.trimEnd()));
  writeFileSync(join(DIST, "cli.html"), cli);

  let extension = readFileSync(join(SITE, "static", "extension.html"), "utf8");
  for (const path of [...FIXTURES.map((f) => f.repoPath), "README.md"]) {
    const unified = git(repo, "diff", "main", "--", path);
    const { table, stat } = diffTable(unified);
    extension = inject(extension, `DIFF:${path}`, table);
    extension = inject(extension, `STAT:${path}`, stat);
  }
  writeFileSync(join(DIST, "extension.html"), extension);

  // Smoke asserts: a palette or renderer change must fail the build, not ship a
  // silently broken page.
  if (!report.includes("pl-")) throw new Error("CLI report lost its pl- classes");
  for (const f of FIXTURES) if (!report.includes(f.repoPath)) throw new Error(`report is missing ${f.repoPath}`);
  if (!ansiToHtml(tree).includes("<span")) throw new Error("tree output lost its ANSI colors");
  for (const page of [cli, extension]) if (page.includes("{{")) throw new Error("unreplaced template token");
} finally {
  rmSync(repo, { recursive: true, force: true });
}

for (const f of FIXTURES) {
  cpSync(join(TESTDATA, f.before), join(DIST, "fixtures", f.before));
  cpSync(join(TESTDATA, f.after), join(DIST, "fixtures", f.after));
}
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
