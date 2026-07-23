// Step 1 of 2:
// - Demo content comes from the real CLI, git, and extension demo bundle
// - Prereqs: `zig build && zig build wasm`, `pnpm run demo` (in extension/)
// - Writes: generated/ ({% fragment %}), public/ (Eleventy passthrough)
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SITE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SITE, "..");
const BIN = join(ROOT, "zig-out", "bin", process.platform === "win32" ? "prefablens.exe" : "prefablens");
const WASM = join(ROOT, "zig-out", "bin", "prefablens.wasm");
const DEMO = join(ROOT, "extension", "dist", "demo.js");
const FIXTURES = join(SITE, "fixtures");
const GENERATED = join(SITE, "generated");
const PUBLIC = join(SITE, "public");
const DIST = join(SITE, "dist");

const DEMO_FILES = [
  "Assets/Prefabs/Robot.prefab", // Landing page (raw vs semantic)
  "Assets/Prefabs/RobotVariant.prefab",
  "Assets/Scenes/Playground.unity",
  "Assets/Settings/Fixture.asset",
];

// ANSI SGR code -> site.css class
// see: https://ansi.tools/lookup
const ANSI_CLASSES = { 1: "b", 2: "dim", 31: "red", 32: "green", 33: "yellow" };

function assertBuilt(path, hint) {
  if (!existsSync(path)) throw new Error(`${path} not found — run \`${hint}\``);
}

function git(cwd, ...args) {
  return execFileSync("git", ["-c", "user.name=demo", "-c", "user.email=demo@example.com", ...args], {
    cwd,
    encoding: "utf8",
  });
}

function makeDemoRepo() {
  const repo = mkdtempSync(join(tmpdir(), "prefablens-site-"));
  git(repo, "init", "-q", "-b", "main");
  cpSync(join(FIXTURES, "before"), repo, { recursive: true });
  git(repo, "add", ...DEMO_FILES);
  git(repo, "commit", "-q", "-m", "before");
  cpSync(join(FIXTURES, "after"), repo, { recursive: true });
  return repo;
}

function changedFiles(repo) {
  const files = [];
  for (const line of git(repo, "diff", "--name-status", "-M", "main").trimEnd().split("\n")) {
    const [st, a, b] = line.split("\t");
    // $ git diff --name-status -M main
    // M       Assets/Fixtures/Fixture.shadervariants
    // R090    Assets/Fixtures/Fixture.terrainlayer    Assets/Fixtures/Ground.terrainlayer
    // R100    Assets/Fixtures/Fixture.terrainlayer.meta       Assets/Fixtures/Ground.terrainlayer.meta
    // A       Assets/Fixtures/Added.anim
    // D       Assets/Fixtures/Doomed.mat
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

function ansiToHtml(text) {
  let out = "";
  const activeAnsiClasses = new Set();
  // "\x1b[32m+\x1b[0m Cylinder" -> ["", "\x1b[32m", "+", "\x1b[0m", " Cylinder"]
  for (const part of text.split(/(\x1b\[[0-9;]*m)/)) {
    // ""          -> null
    // "\x1b[32m"  -> ["\x1b[32m", "32"]
    // "+"         -> null
    // "\x1b[0m"   -> ["\x1b[0m", "0"]
    // " Cylinder" -> null
    const sgr = /^\x1b\[([0-9;]*)m$/.exec(part);
    if (!sgr) {
      // skip "" parts
      if (!part) continue;
      const escaped = escapeHtml(part);
      out += activeAnsiClasses.size
        ? `<span class="${[...activeAnsiClasses].join(" ")}">${escaped}</span>`
        : escaped;
      continue;
    }
    for (const code of (sgr[1] === "" ? "0" : sgr[1]).split(";")) {
      if (code === "0") activeAnsiClasses.clear();
      else if (code in ANSI_CLASSES) activeAnsiClasses.add(ANSI_CLASSES[code]);
      else throw new Error(`unsupported SGR code: ${code}`);
    }
  }
  return out;
}

// Unified `git diff` → GitHub-style table (hunk + add/del/context + line gutters)
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

// One GitHub-style file block; data-before/after URLs for demo.js (DEMO_FILES only)
function fileSection(repo, file) {
  const path = file.after ?? file.before;
  const renamed = file.before !== null && file.after !== null && file.before !== file.after;
  const args = ["diff", "-M", "main", "--"];
  args.push(file.before ?? file.after);
  if (renamed) args.push(file.after);
  const { table, stat } = diffTable(git(repo, ...args));
  const label = renamed ? `${escapeHtml(file.before)} → ${escapeHtml(path)}` : escapeHtml(path);
  const sources =
    ` data-before="${file.before ? `fixtures/before/${escapeHtml(file.before)}` : ""}"` +
    ` data-after="${file.after ? `fixtures/after/${escapeHtml(file.after)}` : ""}"`;
  return `      <div class="file js-details-container Details Details--on open">
        <div class="file-header" data-path="${escapeHtml(path)}"${sources}>
          ${COLLAPSE_BUTTON}
          <span class="file-info">${label}</span>
          <span class="file-stat">${stat}</span>
        </div>
        <div class="js-file-content Details-content--hidden">${table}</div>
      </div>`;
}

// Fixture .meta → guid index (stand-in for extension; same rule as guids.ts / resolve.zig)
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

function clean() {
  rmSync(GENERATED, { recursive: true, force: true });
  mkdirSync(GENERATED, { recursive: true });
  // Eleventy leaves stale dist/ files; step 1 owns the clean slate
  rmSync(DIST, { recursive: true, force: true });
  // public/ mixes committed + generated assets — delete only what we own
  for (const entry of ["hero-report.html", "cli-report.html", "demo.js", "prefablens.wasm", "fixtures"]) {
    rmSync(join(PUBLIC, entry), { recursive: true, force: true });
  }
}

function generateFragments(repo) {
  // CLI outputs (guids resolve via fixture .meta; no --project needed):
  // - --html: full report (+ hero single-file)
  // - --color: tree (forced; stdout is a pipe here)
  const report = execFileSync(BIN, ["--html", "main"], { cwd: repo, encoding: "utf8" });
  const tree = execFileSync(BIN, ["--color", "main"], { cwd: repo, encoding: "utf8" });
  const heroReport = execFileSync(BIN, ["--html", "main", DEMO_FILES[0]], { cwd: repo, encoding: "utf8" });
  const files = changedFiles(repo);
  const heroDiff = diffTable(git(repo, "diff", "main", "--", DEMO_FILES[0]));

  // Smoke asserts — fail the build instead of shipping a broken page
  if (!report.includes("pl-")) throw new Error("CLI report lost its pl- classes");
  if (!heroReport.includes("Rigidbody")) throw new Error("hero report is missing the Robot diff");
  if (!heroReport.includes("Assets/Scripts/FixtureBehaviour.cs")) throw new Error("hero report lost guid resolution");
  if (tree.includes("unresolved")) throw new Error("tree output has unresolved guid references");
  // Built-ins (meshes, Default-Material) must be "<name> (built-in)", not raw hex
  if (!report.includes("(built-in)")) throw new Error("report lost built-in ref names");
  if (report.includes("guid:0000000000000000")) throw new Error("report shows raw built-in guids");
  if (!ansiToHtml(tree).includes("<span")) throw new Error("tree output lost its ANSI colors");
  const paths = files.map((f) => f.after ?? f.before);
  if (paths.join("\n") !== DEMO_FILES.join("\n")) {
    throw new Error(`demo files drifted from DEMO_FILES:\n${paths.join("\n")}`);
  }

  writeFileSync(join(GENERATED, "hero-diff.html"), heroDiff.table);
  const prMeta = `<p class="pr-meta">${files.length} commits into <span class="branch">main</span> from <span class="branch">feat/robot-rebalance</span></p>`;
  writeFileSync(join(GENERATED, "pr-files.html"), `${prMeta}\n${files.map((f) => fileSection(repo, f)).join("\n\n")}`);
  writeFileSync(
    join(GENERATED, "terminal.html"),
    `<span class="prompt">$</span> prefablens main\n${ansiToHtml(tree.trimEnd())}`,
  );

  return { report, heroReport };
}

function publish(report, heroReport) {
  writeFileSync(join(PUBLIC, "hero-report.html"), heroReport);
  writeFileSync(join(PUBLIC, "cli-report.html"), report);
  cpSync(join(FIXTURES, "before"), join(PUBLIC, "fixtures", "before"), { recursive: true });
  cpSync(join(FIXTURES, "after"), join(PUBLIC, "fixtures", "after"), { recursive: true });
  // Stand-in for the extension's GitHub guid index (demo.js fetches by path)
  writeFileSync(join(PUBLIC, "fixtures", "guids.json"), JSON.stringify(guidIndex("after"), null, 2));
  cpSync(WASM, join(PUBLIC, "prefablens.wasm"));
  cpSync(DEMO, join(PUBLIC, "demo.js"));
  console.log(`fragments in ${GENERATED}, assets in ${PUBLIC}`);
}

function main() {
  assertBuilt(BIN, "zig build");
  assertBuilt(WASM, "zig build wasm");
  assertBuilt(DEMO, "pnpm run demo (in extension/)");

  clean();

  const repo = makeDemoRepo();
  let report;
  let heroReport;
  try {
    ({ report, heroReport } = generateFragments(repo));
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }

  publish(report, heroReport);
}

main();
