// sprite.mjs — 参考图 -> 干净的透明鲸鱼精灵（sprite.png / sprite-meta.json）
import { sharp, HERE } from './env.mjs';
import { join } from 'node:path';
import fs from 'fs';

const TOP = 59, W = 474, H = 349;
const NOISE = 0.10;    // 背景近白伪影 alpha 噪声底
const SPECK_MAX = 30;  // 小于此面积的实心碎块 -> 清除
const HOLE_MAX = 45;   // 小于此面积且未触边的内部空洞 -> 填平

function components(mask, W, H) {
  const seen = new Uint8Array(W * H);
  const stack = new Int32Array(W * H);
  const out = [];
  for (let i = 0; i < W * H; i++) {
    if (seen[i] || !mask[i]) continue;
    let sp = 0; stack[sp++] = i; seen[i] = 1;
    const px = [];
    while (sp > 0) {
      const p = stack[--sp];
      px.push(p);
      const x = p % W, y = (p - x) / W;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        if (!dx && !dy) continue;
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
        const q = ny * W + nx;
        if (seen[q] || !mask[q]) continue;
        seen[q] = 1; stack[sp++] = q;
      }
    }
    out.push(px);
  }
  return out;
}

const { data, info } = await sharp(join(HERE, 'src.webp'))
  .extract({ left: 0, top: TOP, width: W, height: H })
  .ensureAlpha().raw().toBuffer({ resolveWithObject: true });
if (info.channels !== 4) throw new Error('expect rgba, got ' + info.channels);

const N = W * H;
const alpha = new Float32Array(N);
const col = new Float32Array(N * 3);

for (let i = 0; i < N; i++) {
  const r = data[4 * i], g = data[4 * i + 1], b = data[4 * i + 2];
  const aRaw = (((255 - r) / 167) + ((255 - g) / 151)) / 2;      // 与白底解混得到的覆盖率
  let a = (aRaw - NOISE) / (1 - NOISE);
  a = a < 0 ? 0 : a > 1 ? 1 : a;
  alpha[i] = a;
  if (aRaw > 0.02) {                                             // 用真实覆盖率反预乘，消除白边
    const R = (r - (1 - aRaw) * 255) / aRaw;
    const G = (g - (1 - aRaw) * 255) / aRaw;
    const B = (b - (1 - aRaw) * 255) / aRaw;
    col[3 * i] = R < 0 ? 0 : R > 255 ? 255 : R;
    col[3 * i + 1] = G < 0 ? 0 : G > 255 ? 255 : G;
    col[3 * i + 2] = B < 0 ? 0 : B > 255 ? 255 : B;
  }
}

// --- 清理：移除实心碎块 / 填平内部小孔（webp 伪影） ---
const onMask = new Uint8Array(N);
for (let i = 0; i < N; i++) onMask[i] = alpha[i] > 0.5 ? 1 : 0;

let cleared = 0, filled = 0;
for (const px of components(onMask, W, H)) {
  if (px.length < SPECK_MAX) { for (const p of px) { alpha[p] = 0; onMask[p] = 0; } cleared += px.length; }
}
const offMask = new Uint8Array(N);
for (let i = 0; i < N; i++) offMask[i] = onMask[i] ? 0 : 1;
for (const px of components(offMask, W, H)) {
  let touches = false;
  for (const p of px) {
    const x = p % W, y = (p - x) / W;
    if (x === 0 || x === W - 1 || y === 0 || y === H - 1) { touches = true; break; }
  }
  if (!touches && px.length < HOLE_MAX) {
    for (const p of px) { alpha[p] = 1; onMask[p] = 1; }
    filled += px.length;
    for (let pass = 0; pass < 2; pass++) {
      for (const p of px) {
        const x = p % W, y = (p - x) / W;
        let s = [0, 0, 0], n = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
          const q = ny * W + nx;
          if (q === p || alpha[q] <= 0.5) continue;
          s[0] += col[3 * q]; s[1] += col[3 * q + 1]; s[2] += col[3 * q + 2]; n++;
        }
        if (n) { col[3 * p] = s[0] / n; col[3 * p + 1] = s[1] / n; col[3 * p + 2] = s[2] / n; }
      }
    }
  }
}
console.log('清理: 清除碎块 ' + cleared + ' px, 填平小孔 ' + filled + ' px');

// --- 诊断 ---
let onCount = 0, second = 0;
let bx0 = 1e9, by0 = 1e9, bx1 = -1, by1 = -1;
for (let i = 0; i < N; i++) {
  if (alpha[i] > 0.5) {
    onCount++;
    const x = i % W, y = (i - x) / W;
    if (x < bx0) bx0 = x; if (x > bx1) bx1 = x;
    if (y < by0) by0 = y; if (y > by1) by1 = y;
    const r = col[3 * i], g = col[3 * i + 1], b = col[3 * i + 2];
    if (Math.abs(r - 72) < 12 && Math.abs(g - 104) < 12 && Math.abs(b - 248) < 12) second++;
  }
}
console.log('实心像素 ' + onCount + ', bbox ' + [bx0, by0, bx1, by1].join(','));
console.log('次色调(72,104,248)像素 ' + second);

// --- 输出 sprite.png ---
const out = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
  out[4 * i] = Math.round(col[3 * i]);
  out[4 * i + 1] = Math.round(col[3 * i + 1]);
  out[4 * i + 2] = Math.round(col[3 * i + 2]);
  out[4 * i + 3] = Math.round(alpha[i] * 255);
}
await sharp(out, { raw: { width: W, height: H, channels: 4 } }).png().toFile(join(HERE, 'sprite.png'));

// --- 品红底 2x 预览（暴露白边/暗边） ---
const prev = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
  const a = alpha[i];
  prev[4 * i] = Math.round(col[3 * i] * a + 255 * (1 - a));
  prev[4 * i + 1] = Math.round(col[3 * i + 1] * a + 0 * (1 - a));
  prev[4 * i + 2] = Math.round(col[3 * i + 2] * a + 255 * (1 - a));
  prev[4 * i + 3] = 255;
}
await sharp(prev, { raw: { width: W, height: H, channels: 4 } }).resize(Math.round(W * 1.5), Math.round(H * 1.5)).png().toFile(join(HERE, 'sprite-magenta.png'));

fs.writeFileSync(join(HERE, 'sprite-meta.json'), JSON.stringify({ W, H, TOP }, null, 2));
console.log('OK sprite.png / sprite-magenta.png');

// --- 精确颜色直方图（实心像素） ---
const hist = new Map();
for (let i = 0; i < N; i++) {
  if (alpha[i] < 0.99) continue;
  const k = Math.round(col[3*i]) + ',' + Math.round(col[3*i+1]) + ',' + Math.round(col[3*i+2]);
  hist.set(k, (hist.get(k) || 0) + 1);
}
console.log('top colors:', [...hist.entries()].sort((a,b)=>b[1]-a[1]).slice(0,5));
