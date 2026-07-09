/** Inline SVG markup for tree glyphs. Static strings only — never interpolate data. */
const svg = (body: string, size: number): string =>
  `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">${body}</svg>`;

export const CHEVRON = svg(
  '<path d="M6 4l4 4-4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
  12,
);

export const CUBE = svg(
  '<path d="M8 1.5 14 5v6l-6 3.5L2 11V5l6-3.5Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>' +
    '<path d="M2 5l6 3.5L14 5M8 8.5V14" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>',
  14,
);

export const GEAR = svg(
  '<circle cx="8" cy="8" r="2.2" stroke="currentColor" stroke-width="1.2"/>' +
    '<path d="M8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.7 3.7l1.4 1.4M10.9 10.9l1.4 1.4M12.3 3.7l-1.4 1.4M5.1 10.9l-1.4 1.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>',
  14,
);

export const ALERT = svg(
  '<path d="M8 1.75a.9.9 0 0 1 .78.45l6.3 10.9a.9.9 0 0 1-.78 1.35H1.7a.9.9 0 0 1-.78-1.35l6.3-10.9A.9.9 0 0 1 8 1.75Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>' +
    '<path d="M8 6v3.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>' +
    '<circle cx="8" cy="11.6" r=".8" fill="currentColor"/>',
  14,
);

export const CHECK = svg(
  '<path d="M13.5 4.5 6.5 11.5 2.5 7.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
  14,
);
