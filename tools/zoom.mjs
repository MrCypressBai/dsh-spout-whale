import { createRequire } from 'module';
const require = createRequire('/Users/cypress/.dsh/profiles/desktop/package.json');
const sharp = require('sharp');
const CW = 192, CH = 208, S = Number(process.argv[2] || 3);
const cells = process.argv[3].split(',').map(s => s.split(':').map(Number)); // row:col
const cols = Math.min(cells.length, 4), rows = Math.ceil(cells.length / cols);
const OW = cols * CW * S, OH = rows * CH * S;
const out = Buffer.alloc(OW * OH * 3, 246);
for (let i = 0; i < cells.length; i++) {
  const [row, col] = cells[i];
  const { data } = await sharp('/Users/cypress/.dsh/codex-pet/pets/spout-whale/spritesheet.png')
    .extract({ left: col * CW, top: row * CH, width: CW, height: CH }).ensureAlpha()
    .raw().toBuffer({ resolveWithObject: true });
  const ox = (i % cols) * CW * S, oy = Math.floor(i / cols) * CH * S;
  for (let y = 0; y < CH * S; y++) for (let x = 0; x < CW * S; x++) {
    const sx = Math.floor(x / S), sy = Math.floor(y / S);
    const o = (sy * CW + sx) * 4, a = data[o + 3] / 255;
    const t = ((oy + y) * OW + ox + x) * 3;
    out[t] = Math.round(data[o] * a + 246 * (1 - a));
    out[t + 1] = Math.round(data[o + 1] * a + 246 * (1 - a));
    out[t + 2] = Math.round(data[o + 2] * a + 246 * (1 - a));
  }
  // 格线
  for (let y = 0; y < CH * S; y++) for (const gx of [0, CW * S - 1]) {
    const t = ((oy + y) * OW + ox + gx) * 3; out[t] = 240; out[t + 1] = 120; out[t + 2] = 120;
  }
  for (let x = 0; x < CW * S; x++) for (const gy of [0, CH * S - 1]) {
    const t = ((oy + gy) * OW + ox + x) * 3; out[t] = 240; out[t + 1] = 120; out[t + 2] = 120;
  }
}
await sharp(out, { raw: { width: OW, height: OH, channels: 3 } }).png().toFile('zoom.png');
console.log('zoom.png ' + OW + 'x' + OH);
