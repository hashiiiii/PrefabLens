// Step 1 of 2:
// - Demo content comes from the real CLI, git, and extension demo bundle
// - Prereqs: `zig build && zig build wasm`, `pnpm run demo` (in extension/)
// - Writes: generated/raw-html/ ({% rawHtml %}), generated/pull-request.json (Liquid), generated/assets/ (passthrough)
// - public/ stays committed static files only (css, favicon, images)
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
const ASSETS = join(GENERATED, "assets");
const RAW_HTML = join(GENERATED, "raw-html");
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

function runGit(cwd, ...args) {
  return execFileSync("git", ["-c", "user.name=demo", "-c", "user.email=demo@example.com", ...args], {
    cwd,
    encoding: "utf8",
  });
}

function createDemoRepo() {
  const repo = mkdtempSync(join(tmpdir(), "prefablens-site-"));
  runGit(repo, "init", "-q", "-b", "main");
  cpSync(join(FIXTURES, "before"), repo, { recursive: true });
  runGit(repo, "add", ...DEMO_FILES);
  runGit(repo, "commit", "-q", "-m", "before");
  cpSync(join(FIXTURES, "after"), repo, { recursive: true });
  return repo;
}

function listChangedFiles(repo) {
  const files = [];
  for (const line of runGit(repo, "diff", "--name-status", "-M", "main").trimEnd().split("\n")) {
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

function convertAnsiToHtml(text) {
  let out = "";
  const activeAnsiClasses = new Set();
  // "\x1b[32m+\x1b[0m Cylinder" -> ["", "\x1b[32m", "+", "\x1b[0m", " Cylinder"]
  for (const part of text.split(/(\x1b\[[0-9]*m)/)) {
    // ""          -> null
    // "\x1b[32m"  -> ["\x1b[32m", "32"]
    // "+"         -> null
    // "\x1b[0m"   -> ["\x1b[0m", "0"]
    // " Cylinder" -> null
    const sgr = /^\x1b\[([0-9]*)m$/.exec(part);
    if (!sgr) {
      // skip "" parts
      if (!part) continue;
      const escaped = escapeHtml(part);
      out += activeAnsiClasses.size
        ? `<span class="${[...activeAnsiClasses].join(" ")}">${escaped}</span>`
        : escaped;
      continue;
    }
    // Bare \x1b[m means reset, same as \x1b[0m
    // That leaves sgr[1] as "", so fall back to "0"
    const code = sgr[1] === "" ? "0" : sgr[1];
    if (code === "0") activeAnsiClasses.clear();
    else if (code in ANSI_CLASSES) activeAnsiClasses.add(ANSI_CLASSES[code]);
    else throw new Error(`unsupported SGR code: ${code}`);
  }
  return out;
}

function createDiffTable(unified) {
  const rows = [];
  let added = 0;
  let removed = 0;
  let oldN = 0;
  let newN = 0;
  let inHunk = false;
  for (const line of unified.split("\n")) {
    // @@ -10,4 +12,5 @@
    // ->
    // [
    //   "@@ -10,4 +12,5 @@",
    //   "10",
    //   "12",
    //   index: 0,
    //   input: "@@ -10,4 +12,5 @@",
    //   groups: undefined
    // ]
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (hunk) {
      inHunk = true;
      oldN = Number(hunk[1]);
      newN = Number(hunk[2]);
      rows.push(`<tr class="hunk"><td colspan="2"></td><td class="code">${escapeHtml(line)}</td></tr>`);
      continue;
    }
    // skip
    if (!inHunk || !line || line === "\\ No newline at end of file") continue;
    if (line.startsWith("+")) {
      added += 1;
      rows.push(`<tr class="add"><td class="num"></td><td class="num">${newN++}</td><td class="code">+${escapeHtml(line.slice(1))}</td></tr>`);
    } else if (line.startsWith("-")) {
      removed += 1;
      rows.push(`<tr class="del"><td class="num">${oldN++}</td><td class="num"></td><td class="code">-${escapeHtml(line.slice(1))}</td></tr>`);
    // unchanged lines
    } else if (line.startsWith(" ")) {
      rows.push(`<tr><td class="num">${oldN++}</td><td class="num">${newN++}</td><td class="code"> ${escapeHtml(line.slice(1))}</td></tr>`);
    }
  }
  const body = rows.length
    ? `<table class="diff-table">${rows.join("")}</table>`
    : '<p class="hint file-empty">File renamed without changes.</p>'; // rename line when 0
  return { table: body, added, removed };
}

function createFileEntry(repo, { before, after }, index) {
  const path = after ?? before;
  const renamed = before !== null && after !== null && before !== after;
  const paths = renamed ? [before, after] : [path];
  const { table, added, removed } = createDiffTable(runGit(repo, "diff", "-M", "main", "--", ...paths));
  const tableRawHtml = `diffs/${index}.html`;
  writeFileSync(join(RAW_HTML, tableRawHtml), table);
  const href = (side, p) => (p ? `fixtures/${side}/${p}` : "");
  return {
    path,
    before: href("before", before),
    after: href("after", after),
    label: renamed ? `${before} → ${after}` : path,
    added,
    removed,
    table: tableRawHtml,
  };
}

// path = "Assets/Scripts/FixtureBehaviour.cs.meta"
// guid = "guid: abc123..."
// index["abc123..."] = "Assets/Scripts/FixtureBehaviour.cs"
function createGuidIndex(side) {
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

function deleteOutputs() {
  rmSync(GENERATED, { recursive: true, force: true });
  mkdirSync(ASSETS, { recursive: true });
  mkdirSync(join(RAW_HTML, "diffs"), { recursive: true });
  rmSync(DIST, { recursive: true, force: true });
}

function createFragments(repo) {
  const report = execFileSync(BIN, ["--html", "main"], { cwd: repo, encoding: "utf8" });
  // execFileSync captures stdout via a pipe (not a TTY), so force ANSI for convertAnsiToHtml
  const tree = execFileSync(BIN, ["--color", "main"], { cwd: repo, encoding: "utf8" });
  const heroReport = execFileSync(BIN, ["--html", "main", DEMO_FILES[0]], { cwd: repo, encoding: "utf8" });
  const files = listChangedFiles(repo);
  const heroDiff = createDiffTable(runGit(repo, "diff", "main", "--", DEMO_FILES[0]));

  // smoke assert
  if (!report.includes("pl-")) throw new Error("CLI report lost its pl- classes");
  if (!heroReport.includes("Rigidbody")) throw new Error("hero report is missing the Robot diff");
  if (!heroReport.includes("Head") || !heroReport.includes("Sensor")) {
    throw new Error("hero report is missing the Head → Sensor rename");
  }
  if (!heroReport.includes("Assets/Scripts/FixtureBehaviour.cs")) throw new Error("hero report lost guid resolution");
  if (tree.includes("unresolved")) throw new Error("tree output has unresolved guid references");
  if (!report.includes("(built-in)")) throw new Error("report lost built-in ref names");
  if (report.includes("guid:0000000000000000")) throw new Error("report shows raw built-in guids");
  if (!convertAnsiToHtml(tree).includes("<span")) throw new Error("tree output lost its ANSI colors");
  const paths = files.map((f) => f.after ?? f.before);
  if (paths.join("\n") !== DEMO_FILES.join("\n")) {
    throw new Error(`demo files drifted from DEMO_FILES:\n${paths.join("\n")}`);
  }

  writeFileSync(join(RAW_HTML, "hero-diff.html"), heroDiff.table);
  writeFileSync(
    join(GENERATED, "pull-request.json"),
    JSON.stringify(
      {
        base: "main",
        head: "feat/robot-rebalance",
        files: files.map((f, i) => createFileEntry(repo, f, i)),
      },
      null,
      2,
    ),
  );
  writeFileSync(
    join(RAW_HTML, "terminal.html"),
    `<span class="prompt">$</span> prefablens main\n${convertAnsiToHtml(tree.trimEnd())}`,
  );

  return { report, heroReport };
}

function writeAssets(report, heroReport) {
  writeFileSync(join(ASSETS, "hero-report.html"), heroReport);
  writeFileSync(join(ASSETS, "cli-report.html"), report);
  cpSync(join(FIXTURES, "before"), join(ASSETS, "fixtures", "before"), { recursive: true });
  cpSync(join(FIXTURES, "after"), join(ASSETS, "fixtures", "after"), { recursive: true });
  writeFileSync(join(ASSETS, "fixtures", "guids.json"), JSON.stringify(createGuidIndex("after"), null, 2));
  cpSync(WASM, join(ASSETS, "prefablens.wasm"));
  cpSync(DEMO, join(ASSETS, "demo.js"));
  console.log(`raw-html in ${RAW_HTML}, assets in ${ASSETS}`);
}

function main() {
  assertBuilt(BIN, "zig build");
  assertBuilt(WASM, "zig build wasm");
  assertBuilt(DEMO, "pnpm run demo (in extension/)");

  deleteOutputs();

  const repo = createDemoRepo();
  let report;
  let heroReport;
  try {
    ({ report, heroReport } = createFragments(repo));
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }

  writeAssets(report, heroReport);
}

main();
