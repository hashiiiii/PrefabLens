/** Minimal ANSI SGR → HTML converter for the CLI's tree output. Covers exactly
 *  the six codes render_tree.zig emits (cli/src/render_tree.zig Color); any
 *  other code throws so a CLI palette change breaks the site build loudly. */

const CLASSES = { 1: "b", 2: "dim", 31: "red", 32: "green", 33: "yellow" };

function escapeHtml(text) {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

export function ansiToHtml(text) {
  let out = "";
  const active = new Set();
  // Every text run carries its full class set, so flat spans suffice (no nesting).
  for (const part of text.split(/(\x1b\[[0-9;]*m)/)) {
    const sgr = /^\x1b\[([0-9;]*)m$/.exec(part);
    if (!sgr) {
      if (!part) continue;
      const escaped = escapeHtml(part);
      out += active.size ? `<span class="${[...active].join(" ")}">${escaped}</span>` : escaped;
      continue;
    }
    for (const code of (sgr[1] === "" ? "0" : sgr[1]).split(";")) {
      if (code === "0") active.clear();
      else if (code in CLASSES) active.add(CLASSES[code]);
      else throw new Error(`unsupported SGR code: ${code}`);
    }
  }
  return out;
}
