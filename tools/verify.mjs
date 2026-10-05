import { sharp, ROOT } from './env.mjs';
import { join } from 'node:path';

const FILE = process.argv[2] || join(ROOT, 'spritesheet.png');
const CW = 192, CH = 208;
const { data, info } = await sharp(FILE).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
console.log('尺寸 ' + info.width + 'x' + info.height + '  通道 ' + info.channels);
if (info.width !== 1536 || info.height !== 2288) console.log('!! 尺寸不符 8 列 11 行协议');
const W = info.width;
const VALID = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8];

let totalOpaque = 0, totalSemi = 0;
for (let row = 0; row < 11; row++) {
  const line = [];
  for (let col = 0; col < 8; col++) {
    let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1, n = 0, semi = 0, border = 0;
    for (let y = 0; y < CH; y++) for (let x = 0; x < CW; x++) {
      const o = ((row * CH + y) * W + col * CW + x) * 4;
      const a = data[o + 3];
      if (a > 0) {
        n++;
        if (a < 255) semi++;
        if (a > 8) {
          if (x < x0) x0 = x; if (x > x1) x1 = x;
          if (y < y0) y0 = y; if (y > y1) y1 = y;
          if (x === 0 || x === CW - 1 || y === 0 || y === CH - 1) border++;
        }
      }
    }
    totalOpaque += n; totalSemi += semi;
    const empty = col >= VALID[row];
    if (empty) {
      if (n > 0) line.push(`c${col}:!!应空但有${n}px`);
      continue;
    }
    line.push(`c${col}:${(x1 - x0 + 1)}x${(y1 - y0 + 1)}@${x0},${y0}${border ? ' CLIP' + border : ''}`);
  }
  console.log('r' + String(row).padStart(2) + ' ' + line.join('  '));
}
console.log('不透明像素 ' + totalOpaque + '，半透明(抗锯齿) ' + totalSemi);
