// Demo content comes from the real CLI, Git, and extension demo bundle.
// Build inputs first: `zig build && zig build wasm`, then `pnpm run demo` in extension/.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { convertAnsiToHtml, createDiffTable } from "./lib/html.mjs";

const SITE = import.meta.dirname;
const ROOT = join(SITE, "..");
const BIN = join(ROOT, "zig-out", "bin", process.platform === "win32" ? "prefablens.exe" : "prefablens");
const WASM = join(ROOT, "zig-out", "bin", "prefablens.wasm");
const DEMO = join(ROOT, "extension", "dist", "demo.js");
const FIXTURES = join(SITE, "fixtures");
const GENERATED = join(SITE, "generated");
const ASSETS = join(GENERATED, "assets");
const RAW_HTML = join(GENERATED, "raw-html");

const DEMO_FILES = [
  "Assets/Prefabs/Robot.prefab", // Both landing-page views use the first fixture.
  "Assets/Prefabs/RobotVariant.prefab",
  "Assets/Scenes/Playground.unity",
  "Assets/Settings/Fixture.asset",
];

function assertBuilt(path, hint) {
  if (!existsSync(path)) throw new Error(`${path} not found. Run \`${hint}\`.`);
}

function runGit(cwd, ...args) {
  return execFileSync("git", ["-c", "user.name=demo", "-c", "user.email=demo@example.com", ...args], {
    cwd,
    encoding: "utf8",
  });
}

function prepareDemoRepo(repo) {
  runGit(repo, "init", "-q", "-b", "main");
  cpSync(join(FIXTURES, "before"), repo, { recursive: true });
  runGit(repo, "add", ...DEMO_FILES);
  runGit(repo, "commit", "-q", "-m", "before");
  cpSync(join(FIXTURES, "after"), repo, { recursive: true });

  // The demo links both sides of every file, so each fixture must remain a modification.
  const changes = runGit(repo, "diff", "--name-status", "-M", "main").trimEnd().split("\n").sort();
  assert.deepEqual(changes, DEMO_FILES.map((path) => `M\t${path}`).sort(), "demo files drifted from DEMO_FILES");
}

function createFileEntry(repo, path, index) {
  const { table, added, removed } = createDiffTable(runGit(repo, "diff", "-M", "main", "--", path));
  const fragment = `diffs/${index}.html`;
  writeFileSync(join(RAW_HTML, fragment), table);
  return {
    path,
    before: `fixtures/before/${path}`,
    after: `fixtures/after/${path}`,
    added,
    removed,
    table: fragment,
  };
}

function createGuidIndex() {
  const root = join(FIXTURES, "after");
  const index = {};
  for (const path of readdirSync(root, { recursive: true })) {
    if (!path.endsWith(".meta")) continue;
    const meta = readFileSync(join(root, path), "utf8");
    const guid = meta.split("\n").map((line) => line.trim()).find((line) => line.startsWith("guid:"));
    if (guid) index[guid.slice("guid:".length).trim()] = path.slice(0, -".meta".length).replaceAll("\\", "/");
  }
  return index;
}

function writeDemo(repo) {
  const report = execFileSync(BIN, ["--html", "main"], { cwd: repo, encoding: "utf8" });
  const heroReport = execFileSync(BIN, ["--html", "main", DEMO_FILES[0]], { cwd: repo, encoding: "utf8" });
  // Captured stdout is not a TTY, so the terminal preview needs explicit ANSI colors.
  const tree = execFileSync(BIN, ["--color", "main"], { cwd: repo, encoding: "utf8" });
  const terminal = convertAnsiToHtml(tree.trimEnd());

  assert(report.includes("pl-"), "CLI report lost its pl- classes");
  assert(heroReport.includes("Rigidbody"), "hero report is missing the Robot diff");
  assert(heroReport.includes("Head") && heroReport.includes("Sensor"), "hero report is missing the Head → Sensor rename");
  assert(heroReport.includes("Assets/Scripts/FixtureBehaviour.cs"), "hero report lost GUID resolution");
  assert(!tree.includes("unresolved"), "tree output has unresolved GUID references");
  assert(report.includes("(built-in)"), "report lost built-in ref names");
  assert(!report.includes("guid:0000000000000000"), "report shows raw built-in GUIDs");
  assert(terminal.includes("<span"), "tree output lost its ANSI colors");

  const files = DEMO_FILES.map((path, index) => createFileEntry(repo, path, index));
  // Reusing the first file keeps the landing and extension Raw diffs identical.
  cpSync(join(RAW_HTML, files[0].table), join(RAW_HTML, "hero-diff.html"));
  writeFileSync(
    join(GENERATED, "pull-request.json"),
    JSON.stringify({ base: "main", head: "feat/robot-rebalance", files }, null, 2),
  );
  writeFileSync(join(RAW_HTML, "terminal.html"), `<span class="prompt">$</span> prefablens main\n${terminal}`);
  writeFileSync(join(ASSETS, "hero-report.html"), heroReport);
  writeFileSync(join(ASSETS, "cli-report.html"), report);
  for (const side of ["before", "after"]) {
    cpSync(join(FIXTURES, side), join(ASSETS, "fixtures", side), { recursive: true });
  }
  writeFileSync(join(ASSETS, "fixtures", "guids.json"), JSON.stringify(createGuidIndex(), null, 2));
  cpSync(WASM, join(ASSETS, "prefablens.wasm"));
  cpSync(DEMO, join(ASSETS, "demo.js"));
  console.log(`raw-html in ${RAW_HTML}, assets in ${ASSETS}`);
}

function main() {
  assertBuilt(BIN, "zig build");
  assertBuilt(WASM, "zig build wasm");
  assertBuilt(DEMO, "pnpm run demo (in extension/)");

  rmSync(GENERATED, { recursive: true, force: true });
  rmSync(join(SITE, "dist"), { recursive: true, force: true });
  mkdirSync(ASSETS, { recursive: true });
  mkdirSync(join(RAW_HTML, "diffs"), { recursive: true });

  const repo = mkdtempSync(join(tmpdir(), "prefablens-site-"));
  try {
    prepareDemoRepo(repo);
    writeDemo(repo);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
}

main();
