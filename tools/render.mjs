// render.mjs — 把鲸鱼精灵按“平滑位移场”变形渲染到 192x208 格
import { createRequire } from 'module';
const require = createRequire('/Users/cypress/.dsh/profiles/desktop/package.json');
const sharp = require('sharp');

export const CELL_W = 192, CELL_H = 208;
export const SC = 0.355, OX = 11.85, OY = 57.0;   // sprite(474x349) -> cell
export const CX = 96.0, CY = 112.0;              // 全局变换中心（格内像素）
const PREF = 0.5;                                 // 精灵预缩小倍数（抗缩混叠）

export const CORE = [82, 110, 255];
export const MIST = [150, 178, 255];
export const LIGHT = [178, 200, 255];

let SPR = null;
export async function loadSprite(file = 'sprite.png') {
  const { data, info } = await sharp(file).ensureAlpha()
    .resize(Math.round(474 * PREF), Math.round(349 * PREF), { kernel: 'lanczos3' })
    .raw().toBuffer({ resolveWithObject: true });
  SPR = { W: info.width, H: info.height, d: data };
  return SPR;
}

// 体轴：头部锚点 A0（s=0 处）到尾尖 A1
const A0 = [30, 160], A1 = [460, 20];
const AXL = Math.hypot(A1[0] - A0[0], A1[1] - A0[1]);
const E1x = (A1[0] - A0[0]) / AXL, E1y = (A1[1] - A0[1]) / AXL;
const E2x = -E1y, E2y = E1x;
const TAU = Math.PI * 2;

function bendD(u, v, B, out) {
  const s = (u - A0[0]) * E1x + (v - A0[1]) * E1y;
  let w = (s - B.s0) / (AXL - B.s0);
  w = w <= 0 ? 0 : w >= 1 ? 1 : Math.pow(w, B.pow);
  const D = B.A * w * Math.sin(TAU * s / B.lam - B.ph);
  out[0] = E2x * D; out[1] = E2y * D;
}

function rotD(u, v, F, out) {
  const dx = u - F.cx, dy = v - F.cy;
  const g = Math.exp(-(dx * dx + dy * dy) / (2 * F.sig * F.sig));
  const c = Math.cos(F.ang), sn = Math.sin(F.ang);
  out[0] = g * (dx * c - dy * sn - dx);
  out[1] = g * (dx * sn + dy * c - dy);
}

function lookD(u, v, L, out) {
  const s = (u - A0[0]) * E1x + (v - A0[1]) * E1y;
  let w = 1 - s / 240;
  w = w <= 0 ? 0 : w >= 1 ? 1 : Math.pow(w, 1.2);
  out[0] = L.dx * w; out[1] = L.dy * w;
}

function warpToSprite(px, py, P, out) {
  let x = px - CX - (P.tx || 0), y = py - CY - (P.ty || 0);
  const c = Math.cos(-(P.rot || 0)), sn = Math.sin(-(P.rot || 0));
  const rx = (x * c - y * sn) / (P.sx || 1), ry = (x * sn + y * c) / (P.sy || 1);
  let u = (rx + CX - OX) / SC, v = (ry + CY - OY) / SC;
  const d = [0, 0];
  if (P.bend) { bendD(u, v, P.bend, d); u -= d[0]; v -= d[1]; }
  if (P.fin) { rotD(u, v, P.fin, d); u -= d[0]; v -= d[1]; }
  if (P.fluke) { rotD(u, v, P.fluke, d); u -= d[0]; v -= d[1]; }
  if (P.look) { lookD(u, v, P.look, d); u -= d[0]; v -= d[1]; }
  out[0] = u; out[1] = v;
}

function samplePremul(u, v, out) {
  const { W, H, d } = SPR;
  out[0] = out[1] = out[2] = out[3] = 0;
  const x0 = Math.floor(u - 0.5), y0 = Math.floor(v - 0.5);
  const fx = u - 0.5 - x0, fy = v - 0.5 - y0;
  for (let j = 0; j < 2; j++) {
    const yy = y0 + j;
    if (yy < 0 || yy >= H) continue;
    const wy = j ? fy : 1 - fy;
    if (wy <= 0) continue;
    for (let i = 0; i < 2; i++) {
      const xx = x0 + i;
      if (xx < 0 || xx >= W) continue;
      const w = wy * (i ? fx : 1 - fx);
      if (w <= 0) continue;
      const o = (yy * W + xx) * 4;
      const a = d[o + 3] / 255;
      out[0] += d[o] * w * a;
      out[1] += d[o + 1] * w * a;
      out[2] += d[o + 2] * w * a;
      out[3] += a * w;
    }
  }
}

function blend(buf, x, y, r, g, b, a) {
  if (x < 0 || y < 0 || x >= CELL_W || y >= CELL_H || a <= 0.0005) return;
  const o = (y * CELL_W + x) * 4, inv = 1 - a;
  buf[o] = r * a + buf[o] * inv;
  buf[o + 1] = g * a + buf[o + 1] * inv;
  buf[o + 2] = b * a + buf[o + 2] * inv;
  buf[o + 3] = a + buf[o + 3] * inv;
}

export function drawDot(buf, cx, cy, rad, col, alpha) {
  const x0 = Math.max(0, Math.floor(cx - rad - 1)), x1 = Math.min(CELL_W - 1, Math.ceil(cx + rad + 1));
  const y0 = Math.max(0, Math.floor(cy - rad - 1)), y1 = Math.min(CELL_H - 1, Math.ceil(cy + rad + 1));
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
    const dx = x + 0.5 - cx, dy = y + 0.5 - cy;
    const dd = Math.sqrt(dx * dx + dy * dy);
    const cov = rad + 0.5 - dd;
    if (cov > 0) blend(buf, x, y, col[0], col[1], col[2], alpha * (cov > 1 ? 1 : cov));
  }
}

// 固定种子喷水水珠
function mulberry32(a) {
  return function () {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(20240117);
const FAN = [];
for (let i = 0; i < 12; i++) {
  FAN.push({
    ang: (-34 + 6.2 * i) * Math.PI / 180 + (rnd() - 0.5) * 0.10,
    off: rnd() * 0.85,
    sp: 0.85 + rnd() * 0.3,
    rad: 1.5 + rnd() * 1.6,
  });
}

export function drawPlume(buf, bx, by, pl) {
  if (!pl || pl.strength <= 0.01) return;
  const { t, h, spread, strength, tilt } = pl;
  const wide = spread / 16;                       // 扇形张角缩放
  const N = 22;
  for (let i = 0; i <= N; i++) {                  // 1) 竖直水柱，下粗上细
    const a = i / N;
    const hy = h * 0.50 * Math.pow(a, 0.85);
    const wob = Math.sin(a * 2.4 - t * TAU * 2) * 2.0 * a;
    const lat = tilt * hy + wob;
    const rad = 5.0 * Math.pow(1 - a, 0.65) + 1.4;
    drawDot(buf, bx + lat, by - hy, rad, MIST, strength * (1 - 0.35 * a));
  }
  for (let i = 0; i < FAN.length; i++) {          // 2) 扇形水花，沿各自射线飞散
    const d = FAN[i];
    let a = (t * d.sp + d.off) % 1; if (a < 0) a += 1;
    const R = h * (0.44 + 0.58 * a);
    const sa = Math.sin(d.ang) * wide, ca = Math.cos(d.ang);
    const x = bx + sa * R + tilt * ca * R;
    const y = by - ca * R;
    const al = strength * Math.min(1, a / 0.12) * Math.min(1, Math.max(0, (1 - a) / 0.28));
    if (al <= 0.02) continue;
    drawDot(buf, x, y, d.rad * (1.05 - 0.35 * a), i % 3 === 2 ? LIGHT : MIST, al);
  }
  drawDot(buf, bx, by + 1.0, 3.4 * wide + 1.2, CORE, strength * 0.9);   // 3) 喷口根部
}


// 喷口在格内的基准位置（sprite 243,13 -> cell）
// 喷口（头顶脊最高点）
export const BLOW = [OX + 236 * SC, OY + 8 * SC];

export function blowholeCell(P) {
  const [bx0, by0] = BLOW;
  const x = bx0 - CX - (P.tx || 0), y = by0 - CY - (P.ty || 0);
  const c = Math.cos(P.rot || 0), sn = Math.sin(P.rot || 0);
  let rx = (x * c - y * sn) * (P.sx || 1), ry = (x * sn + y * c) * (P.sy || 1);
  let u = 236, v = 8;
  const d = [0, 0];
  if (P.bend) { bendD(u, v, P.bend, d); u -= d[0]; v -= d[1]; }
  if (P.look) { lookD(u, v, P.look, d); u -= d[0]; v -= d[1]; }
  const du = (u - 236) * SC, dv = (v - 8) * SC;
  return [rx + CX + du, ry + CY + dv];
}

export function renderCell(P) {
  const SS = 2;
  const buf = new Float32Array(CELL_W * CELL_H * 4);
  const co = [0, 0], sm = [0, 0, 0, 0];
  const inv = 1 / (SS * SS);
  for (let py = 0; py < CELL_H; py++) {
    for (let px = 0; px < CELL_W; px++) {
      let ar = 0, ag = 0, ab = 0, aa = 0;
      for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
        warpToSprite(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS, P, co);
        samplePremul(co[0] * PREF, co[1] * PREF, sm);
        ar += sm[0]; ag += sm[1]; ab += sm[2]; aa += sm[3];
      }
      if (aa * inv > 0.0008) {
        const o = (py * CELL_W + px) * 4;
        buf[o] = ar * inv; buf[o + 1] = ag * inv; buf[o + 2] = ab * inv; buf[o + 3] = aa * inv;
      }
    }
  }
  // 喷水（格内坐标，先于镜像翻转绘制）
  if (P.plume) {
    const [bx, by] = blowholeCell(P);
    drawPlume(buf, bx, by, P.plume);
  }
  // 镜像：整格水平翻转
  if (P.mirror) {
    for (let y = 0; y < CELL_H; y++) {
      for (let x = 0; x < CELL_W / 2; x++) {
        const a = (y * CELL_W + x) * 4, b = (y * CELL_W + (CELL_W - 1 - x)) * 4;
        for (let k = 0; k < 4; k++) { const tmp = buf[a + k]; buf[a + k] = buf[b + k]; buf[b + k] = tmp; }
      }
    }
  }
  return buf;
}

// 预乘浮点 -> 直通 RGBA 字节
export function toRGBA(buf) {
  const out = Buffer.alloc(CELL_W * CELL_H * 4);
  for (let i = 0; i < CELL_W * CELL_H; i++) {
    const o = i * 4, a = buf[o + 3];
    if (a <= 0.0008) continue;
    const ia = 1 / a;
    out[o] = Math.max(0, Math.min(255, Math.round(buf[o] * ia)));
    out[o + 1] = Math.max(0, Math.min(255, Math.round(buf[o + 1] * ia)));
    out[o + 2] = Math.max(0, Math.min(255, Math.round(buf[o + 2] * ia)));
    out[o + 3] = Math.round(Math.min(1, a) * 255);
  }
  return out;
}
