// Regenerates the images the Swift app ships, as template PDFs in Resources/Icons. They are
// committed, so a build never needs this script.
//   - the window icons: Tabler outline, stroke 1.5
//   - the menu bar: the letter S cut out of an 18 pt square (13-favicon.md), and its states as a
//     badge cut into the bottom-right corner. In PDF the cut is a clip-path, never a mask:
//     rsvg-convert turns a mask into soft transparency and the template image loses the square.
// The app icon (Resources/AppIcon.icns) comes from the same favicon tool: S, Candal, 555555 on white, size 60.
//
// Needs rsvg-convert (brew install librsvg). Run from anywhere: bun scripts/assets.mjs
import { $ } from 'bun';
import { mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

const LETTER = 'S';
const ROOT = join(dirname(new URL(import.meta.url).pathname), '..');
const OUT = join(ROOT, 'Resources', 'Icons');
const tmp = join(tmpdir(), 'speech-to-text-swift-assets');
mkdirSync(tmp, { recursive: true });
mkdirSync(OUT, { recursive: true });

const TABLER = [
  'home', 'keyboard', 'cpu', 'vocabulary', 'sparkles', 'layout-navbar', 'lock', 'settings',
  'check', 'copy', 'download', 'refresh', 'trash', 'x', 'plus', 'microphone', 'clipboard-text',
  'chevron-down', 'chevron-up', 'command', 'option', 'arrow-big-up', 'arrow-left', 'arrow-right',
  'arrow-up', 'arrow-down', 'corner-down-left', 'backspace', 'folder', 'player-play',
];

const pdf = async (name, svg) => {
  const src = join(tmp, `${name}.svg`);
  writeFileSync(src, svg);
  await $`rsvg-convert -f pdf -o ${join(OUT, `${name}.pdf`)} ${src}`.quiet();
};

for (const name of TABLER) {
  const svg = await (await fetch(`https://unpkg.com/@tabler/icons@3/icons/outline/${name}.svg`)).text();
  if (!svg.includes('<svg')) throw new Error(`tabler icon not found: ${name}`);
  await pdf(name, svg.replace('stroke-width="2"', 'stroke-width="1.5"').replace('stroke="currentColor"', 'stroke="#000000"'));
}
console.log(`window: ${TABLER.length} Tabler icons`);

const res = await fetch('https://mcp.tools.ciromaciel.click', {
  method: 'POST',
  headers: { 'User-Agent': 'curl/8.7.1', 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
  body: JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name: 'generate_favicon', arguments: { mode: 'text', text: LETTER, font: 'Candal', background: 'ffffff', color: '555555', size: 60, adaptive: false } },
  }),
});
let raw = await res.text();
if (raw.startsWith('event:') || raw.startsWith('data:')) raw = raw.split('\n').find(l => l.startsWith('data:')).slice(5);
const result = JSON.parse(raw).result;
if (result.isError) throw new Error(`favicon tool: ${result.content?.[0]?.text}`);
const letter = (result.structuredContent ?? JSON.parse(result.content[0].text)).svg.match(/<path[^>]* d="([^"]+)"/)[1];

// The square with the letter cut out; with a badge, the corner circle (r 23 at 85,85) cut too.
const square = `M0 0H100V100H0Z ${letter}`;
const corner = 'M0 0H100V100H0Z M62 85a23 23 0 1 0 46 0a23 23 0 1 0 -46 0Z';
const svg = (body) => `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 100 100">${body}</svg>`;
const notched = (badge) => svg(
  `<defs><clipPath id="c"><path clip-rule="evenodd" d="${corner}"/></clipPath></defs>`
  + `<path fill="#000000" fill-rule="evenodd" clip-path="url(#c)" d="${square}"/>${badge}`);

const FRAMES = {
  menubar: svg(`<path fill="#000000" fill-rule="evenodd" d="${square}"/>`),
  'menubar-listening': notched('<circle cx="85" cy="85" r="15" fill="#000000"/>'),
  'menubar-paused': notched('<rect x="69" y="80" width="31" height="10" fill="#000000"/>'),
  'menubar-attention': svg(`<path fill="#000000" fill-rule="evenodd" d="M0 0H100V100H0Z M11 11V89H89V11Z"/><path fill="#000000" d="${letter}"/>`),
};
for (let i = 0; i < 8; i++) {
  FRAMES[`menubar-processing-${i}`] = notched(`<circle cx="85" cy="85" r="11.5" fill="none" stroke="#000000" stroke-width="7" stroke-dasharray="52 20" transform="rotate(${i * 45} 85 85)"/>`);
}
for (const [name, body] of Object.entries(FRAMES)) await pdf(name, body);
console.log(`menu bar: ${Object.keys(FRAMES).length} frames (${LETTER})`);
