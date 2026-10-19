// Regenerates every image the app ships. src-tauri/icons and src/icons.svg are committed,
// so a build never needs this script.
//   - the app icon: the letter S, through the public favicon tool at ciromaciel.click/tools
//     (Candal, 555555 on white, size 60)
//   - the menu bar glyph: the same square in ink with the letter cut out (template image)
//   - the states of the menu bar: the same S with a badge in the bottom-right corner (a dot
//     that grows with the voice, a turning ring, a dash) or, for attention, the S in outline
//   - the window icons: Tabler outline, stroke 1.5, as one SVG sprite (src/icons.svg)
//
// Needs rsvg-convert (brew install librsvg) and iconutil (ships with macOS).
// Run from anywhere: bun scripts/assets.mjs
import { $ } from 'bun';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { crc32, deflateSync, inflateSync } from 'node:zlib';
import { dirname, join } from 'node:path';

const LETTER = 'S';
const ROOT = join(dirname(new URL(import.meta.url).pathname), '..');
const ICONS = join(ROOT, 'src-tauri', 'icons');

// Window: menu, status line, buttons.
const SPRITE = [
  'home', 'keyboard', 'cpu', 'vocabulary', 'sparkles', 'layout-navbar', 'lock', 'settings',
  'check', 'copy', 'download', 'refresh', 'trash', 'x', 'plus', 'microphone', 'clipboard-text',
];

const tmp = join(tmpdir(), 'speech-to-text-assets');
mkdirSync(tmp, { recursive: true });

async function tabler(name) {
  const svg = await (await fetch(`https://unpkg.com/@tabler/icons@3/icons/outline/${name}.svg`)).text();
  if (!svg.includes('<svg')) throw new Error(`tabler icon not found: ${name}`);
  return svg.replace('stroke-width="2"', 'stroke-width="1.5"');
}

// --- window sprite ---------------------------------------------------------------
const symbols = [];
for (const name of SPRITE) {
  const inner = (await tabler(name)).replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '').trim();
  symbols.push(`<symbol id="${name}" viewBox="0 0 24 24">${inner}</symbol>`);
}
writeFileSync(join(ROOT, 'src', 'icons.svg'),
  `<svg xmlns="http://www.w3.org/2000/svg" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">\n${symbols.join('\n')}\n</svg>\n`);
console.log(`sprite: ${SPRITE.length} icons → src/icons.svg`);

// --- app icon --------------------------------------------------------------------
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
const out = result.structuredContent ?? JSON.parse(result.content[0].text);
const iconSvg = join(tmp, 'icon.svg');
writeFileSync(iconSvg, out.svg);

// Straight from the vector at every size. rsvg writes an opaque image as RGB, and Tauri
// refuses any icon without alpha, so each PNG is rewritten as RGBA.
const png = async (size, dest) => {
  await $`rsvg-convert -w ${size} -h ${size} -o ${dest} ${iconSvg}`.quiet();
  writeFileSync(dest, toRgba(readFileSync(dest)));
};

function toRgba(file) {
  const chunks = [];
  for (let at = 8; at < file.length;) {
    const length = file.readUInt32BE(at), type = file.toString('ascii', at + 4, at + 8);
    chunks.push({ type, data: file.subarray(at + 8, at + 8 + length) });
    at += 12 + length;
  }
  const ihdr = chunks.find(c => c.type === 'IHDR').data;
  const width = ihdr.readUInt32BE(0), height = ihdr.readUInt32BE(4), depth = ihdr[8], color = ihdr[9];
  if (color === 6) return file;
  if (color !== 2 || depth !== 8 || ihdr[12] !== 0) throw new Error(`unexpected PNG (color ${color}, depth ${depth})`);
  const raw = inflateSync(Buffer.concat(chunks.filter(c => c.type === 'IDAT').map(c => c.data)));
  const stride = width * 3, rgb = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= 3 ? rgb[y * stride + x - 3] : 0, b = y ? rgb[(y - 1) * stride + x] : 0;
      const c = x >= 3 && y ? rgb[(y - 1) * stride + x - 3] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const predictor = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      rgb[y * stride + x] = (line[x] + predictor) & 255;
    }
  }
  const rgba = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    rgb.copy(rgba, y * (width * 4 + 1) + 1 + x * 4, y * stride + x * 3, y * stride + x * 3 + 3);
    rgba[y * (width * 4 + 1) + 1 + x * 4 + 3] = 255;
  }
  const header = Buffer.from(ihdr); header[9] = 6;
  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); data.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
    return out;
  };
  return Buffer.concat([file.subarray(0, 8), chunk('IHDR', header), chunk('IDAT', deflateSync(rgba)), chunk('IEND', Buffer.alloc(0))]);
}
await png(512, join(ICONS, 'icon.png'));
await png(32, join(ICONS, '32x32.png'));
await png(128, join(ICONS, '128x128.png'));
await png(256, join(ICONS, '128x128@2x.png'));

const iconset = join(tmp, 'icon.iconset');
rmSync(iconset, { recursive: true, force: true });
mkdirSync(iconset);
for (const size of [16, 32, 128, 256, 512]) {
  await png(size, join(iconset, `icon_${size}x${size}.png`));
  await png(size * 2, join(iconset, `icon_${size}x${size}@2x.png`));
}
await $`iconutil -c icns -o ${join(ICONS, 'icon.icns')} ${iconset}`.quiet();

// ICO with PNG entries (16, 32, 48, 256): what the Windows installer and the taskbar read.
const icoSizes = [16, 32, 48, 256];
const pngs = [];
for (const size of icoSizes) {
  const p = join(tmp, `ico-${size}.png`);
  await png(size, p);
  pngs.push(readFileSync(p));
}
const header = Buffer.alloc(6 + 16 * pngs.length);
header.writeUInt16LE(0, 0); header.writeUInt16LE(1, 2); header.writeUInt16LE(pngs.length, 4);
let offset = header.length;
pngs.forEach((data, i) => {
  const at = 6 + 16 * i, size = icoSizes[i] === 256 ? 0 : icoSizes[i];
  header.writeUInt8(size, at); header.writeUInt8(size, at + 1);
  header.writeUInt16LE(1, at + 4); header.writeUInt16LE(32, at + 6);
  header.writeUInt32LE(data.length, at + 8); header.writeUInt32LE(offset, at + 12);
  offset += data.length;
});
writeFileSync(join(ICONS, 'icon.ico'), Buffer.concat([header, ...pngs]));
console.log(`app icon: ${LETTER} → ${out.link ?? 'ok'}`);

// --- menu bar --------------------------------------------------------------------
// The S never leaves the menu bar; the state is a badge cut into the square's bottom-right
// corner, in one ink, so it stays a template image (13-favicon.md). 36 px = 18 pt at 2x; macOS
// paints the black template for light and dark menu bars, and Linux panels get the white one
// (tray.rs picks it).
//   idle           the S alone
//   listening      a steady dot (one size: following the voice made the icon tremble)
//   processing-0…7 a ring with a gap, turned 45° per frame: tray.rs plays them while transcribing
//   paused         a dash
//   attention      the S in outline: the whole silhouette changes, with no badge to mix up
const letter = out.svg.match(/<path[^>]* d="([^"]+)"/)[1];
const TRAY_DIR = join(ICONS, 'tray');
rmSync(TRAY_DIR, { recursive: true, force: true });
mkdirSync(TRAY_DIR, { recursive: true });
const square = `M0 0H100V100H0Z ${letter}`;
const notched = (badge) => `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 100 100">`
  + `<defs><mask id="m"><rect width="100" height="100" fill="#fff"/><circle cx="85" cy="85" r="23" fill="#000"/></mask></defs>`
  + `<path fill="INK" fill-rule="evenodd" d="${square}" mask="url(#m)"/>${badge}</svg>`;
const FRAMES = {
  idle: `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 100 100"><path fill="INK" fill-rule="evenodd" d="${square}"/></svg>`,
  paused: notched('<rect x="69" y="80" width="31" height="10" fill="INK"/>'),
  attention: `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 100 100"><path fill="INK" fill-rule="evenodd" d="M0 0H100V100H0Z M11 11V89H89V11Z"/><path fill="INK" d="${letter}"/></svg>`,
};
FRAMES.listening = notched('<circle cx="85" cy="85" r="15" fill="INK"/>');
for (let i = 0; i < 8; i++) {
  FRAMES[`processing-${i}`] = notched(`<circle cx="85" cy="85" r="11.5" fill="none" stroke="INK" stroke-width="7" stroke-dasharray="52 20" transform="rotate(${i * 45} 85 85)"/>`);
}
for (const [name, svg] of Object.entries(FRAMES)) {
  for (const [variant, ink] of [['dark', '#000000'], ['light', '#FFFFFF']]) {
    const src = join(tmp, `${name}-${variant}.svg`);
    writeFileSync(src, svg.replaceAll('INK', ink));
    await $`rsvg-convert -w 36 -h 36 -o ${join(TRAY_DIR, `${name}-${variant}.png`)} ${src}`.quiet();
  }
}
console.log(`menu bar: ${Object.keys(FRAMES).length} frames (${LETTER}) → src-tauri/icons/tray`);
