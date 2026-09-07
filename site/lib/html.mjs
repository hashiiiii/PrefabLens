// These classes match the terminal palette in public/site.css.
const ANSI_CLASSES = { 1: "b", 2: "dim", 31: "red", 32: "green", 33: "yellow" };

function escapeHtml(text) {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

export function convertAnsiToHtml(text) {
  let html = "";
  const classes = new Set();
  for (const part of text.split(/(\x1b\[[0-9]*m)/)) {
    const sgr = /^\x1b\[([0-9]*)m$/.exec(part);
    if (sgr) {
      // ANSI permits an omitted code as another form of reset.
      const code = sgr[1] || "0";
      if (code === "0") classes.clear();
      else if (code in ANSI_CLASSES) classes.add(ANSI_CLASSES[code]);
      else throw new Error(`unsupported SGR code: ${code}`);
    } else if (part) {
      const escaped = escapeHtml(part);
      html += classes.size ? `<span class="${[...classes].join(" ")}">${escaped}</span>` : escaped;
    }
  }
  return html;
}

export function createDiffTable(unified) {
  const rows = [];
  let added = 0;
  let removed = 0;
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;
  for (const line of unified.split("\n")) {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (hunk) {
      inHunk = true;
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
      rows.push(`<tr class="hunk"><td colspan="2"></td><td class="code">${escapeHtml(line)}</td></tr>`);
      continue;
    }

    const kind = line[0];
    if (!inHunk || !["+", "-", " "].includes(kind)) continue;
    if (kind === "+") added += 1;
    if (kind === "-") removed += 1;
    const before = kind === "+" ? "" : oldLine++;
    const after = kind === "-" ? "" : newLine++;
    const className = kind === "+" ? ' class="add"' : kind === "-" ? ' class="del"' : "";
    rows.push(`<tr${className}><td class="num">${before}</td><td class="num">${after}</td><td class="code">${escapeHtml(line)}</td></tr>`);
  }
  const table = rows.length
    ? `<table class="diff-table">${rows.join("")}</table>`
    : '<p class="hint file-empty">File renamed without changes.</p>';
  return { table, added, removed };
}
