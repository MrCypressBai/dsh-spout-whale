// build.mjs — 渲染 8x11 图集并写出 spritesheet.png / pet.json
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
const require = createRequire('/Users/cypress/.dsh/profiles/desktop/package.json');
const sharp = require('sharp');
import { loadSprite, renderCell, toRGBA, CELL_W, CELL_H } from './render.mjs';
import { paramsFor } from './actions.mjs';

const COLS = 8, ROWS = 11;
const SHEET_W = COLS * CELL_W, SHEET_H = ROWS * CELL_H;   // 1536 x 2288
const OUT = process.argv[2] || '/Users/cypress/.dsh/codex-pet/pets/spout-whale';

await loadSprite('sprite.png');

const sheet = Buffer.alloc(SHEET_W * SHEET_H * 4);
const t0 = Date.now();
for (let row = 0; row < ROWS; row++) {
  for (let col = 0; col < COLS; col++) {
    const P = paramsFor(row, col);
    if (!P) continue;
    const cell = toRGBA(renderCell(P));
    for (let y = 0; y < CELL_H; y++) {
      cell.copy(sheet, ((row * CELL_H + y) * SHEET_W + col * CELL_W) * 4, y * CELL_W * 4, (y + 1) * CELL_W * 4);
    }
  }
  process.stdout.write('row ' + row + ' done  ');
}
console.log('\n渲染耗时 ' + ((Date.now() - t0) / 1000).toFixed(1) + 's');

fs.mkdirSync(OUT, { recursive: true });
await sharp(sheet, { raw: { width: SHEET_W, height: SHEET_H, channels: 4 } })
  .png({ compressionLevel: 9 }).toFile(path.join(OUT, 'spritesheet.png'));

const manifest = {
  displayName: '喷水鲸鱼',
  description: '一只蓝色的喷水鲸鱼：会摆尾游动、跃出水面、喷水问好，也能安静发呆和注视四周。',
  spritesheetPath: 'spritesheet.png',
  spriteVersionNumber: 2,
};
fs.writeFileSync(path.join(OUT, 'pet.json'), JSON.stringify(manifest, null, 2) + '\n', 'utf8');

// ---------- 预览 ----------
function overBg(rgba, w, h, bg) {
  const out = Buffer.alloc(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    const a = rgba[i * 4 + 3] / 255;
    out[i * 3] = Math.round(rgba[i * 4] * a + bg[0] * (1 - a));
    out[i * 3 + 1] = Math.round(rgba[i * 4 + 1] * a + bg[1] * (1 - a));
    out[i * 3 + 2] = Math.round(rgba[i * 4 + 2] * a + bg[2] * (1 - a));
  }
  return out;
}
function grid(rgb, w, h, cw, ch, gap) {
  for (let x = 0; x < w; x += cw) for (let y = 0; y < h; y++) {
    const i = (y * w + x) * 3;
    rgb[i] = 235; rgb[i + 1] = 90; rgb[i + 2] = 90;
    for (let k = 1; k < gap; k++) if (x + k < w) { const j = (y * w + x + k) * 3; rgb[j] = 235; rgb[j + 1] = 90; rgb[j + 2] = 90; }
  }
  for (let y = 0; y < h; y += ch) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 3;
    rgb[i] = 235; rgb[i + 1] = 90; rgb[i + 2] = 90;
    for (let k = 1; k < gap; k++) if (y + k < h) { const j = ((y + k) * w + x) * 3; rgb[j] = 235; rgb[j + 1] = 90; rgb[j + 2] = 90; }
  }
}

const BG = [246, 247, 250];
const contactRGB = overBg(sheet, SHEET_W, SHEET_H, BG);
await sharp(contactRGB, { raw: { width: SHEET_W, height: SHEET_H, channels: 3 } })
  .resize(768, 1144).png().toFile('preview-contact.png');

const gridRGB = overBg(sheet, SHEET_W, SHEET_H, BG);
grid(gridRGB, SHEET_W, SHEET_H, CELL_W, CELL_H, 2);
await sharp(gridRGB, { raw: { width: SHEET_W, height: SHEET_H, channels: 3 } })
  .resize(900, 1341).png().toFile('preview-grid.png');

for (let row = 0; row < ROWS; row++) {
  const y0 = row * CELL_H;
  const band = Buffer.alloc(SHEET_W * CELL_H * 4);
  for (let y = 0; y < CELL_H; y++)
    sheet.copy(band, y * SHEET_W * 4, ((y0 + y) * SHEET_W) * 4, ((y0 + y + 1) * SHEET_W) * 4);
  const bandRGB = overBg(band, SHEET_W, CELL_H, BG);
  grid(bandRGB, SHEET_W, CELL_H, CELL_W, CELL_H, 1);
  await sharp(bandRGB, { raw: { width: SHEET_W, height: CELL_H, channels: 3 } })
    .resize(SHEET_W, SHEET_H).png().toFile('strip-row' + row + '.png');
}
console.log('OK -> ' + OUT);
