// actions.mjs — 11 行 × 8 列的动作参数表（行/帧数与 Codex 8 列协议一致）
// 行: 0 空闲6 | 1 向右跑8 | 2 向左跑8 | 3 挥手4 | 4 跳跃5 | 5 失败8
//     6 等待用户6 | 7 工作中6 | 8 完成待查看6 | 9-10 注视方向16
export const FRAME_COUNT = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8];

const TAU = Math.PI * 2;
const deg = d => d * Math.PI / 180;

const BEND = (A, ph, pow = 1.7, lam = 300, s0 = 40) => ({ A, ph, pow, lam, s0 });
const FIN = ang => ({ ang, cx: 192, cy: 296, sig: 45 });
const FLUKE = ang => ({ ang, cx: 358, cy: 95, sig: 55 });
const PL = (t, h, spread, strength, tilt = 0) => ({ t, h, spread, strength, tilt });

export function paramsFor(row, col) {
  if (col >= FRAME_COUNT[row]) return null;   // 无效帧保持透明
  const P = { mirror: false };
  const t = col / 8;

  if (row === 0) {                       // 空闲：呼吸 + 一次短促喷水
    const T = [0.00, 0.06, 0.22, 0.42, 0.62, 0.86][col];
    P.ty = [0.0, -1.2, -2.0, -1.0, 0.2, 0.6][col];
    P.bend = BEND([5, 10, 9, 7, 6, 5][col], T * TAU);
    P.fin = FIN(0.05 * Math.sin(T * TAU));
    P.plume = PL(T, [11, 24, 30, 26, 17, 9][col], [6, 11, 14, 15, 12, 7][col],
      [0.45, 1, 1, 0.9, 0.6, 0.3][col]);
    return P;
  }

  if (row === 1 || row === 2) {          // 向右跑（1，镜像） / 向左跑（2）
    const T = col / 8;
    P.mirror = row === 1;
    P.bend = BEND(20, T * TAU);
    P.ty = Math.sin(T * TAU * 2) * 2.2;
    P.rot = deg(2.5) * Math.sin(T * TAU);
    P.fin = FIN(0.28 * Math.sin(T * TAU * 2 + 0.6));
    P.fluke = FLUKE(0.10 * Math.sin(T * TAU * 2 + 1.2));
    P.plume = PL((col / 8 * 1.4) % 1, 20, 20, 1.0, 0.30);
    return P;
  }

  if (row === 3) {                       // 挥手：胸鳍抬起挥动 + 大喷水
    P.fin = FIN([0.0, -0.45, -0.62, -0.30][col]);
    P.rot = deg([0, -2, -3, -1][col]);
    P.ty = [0, -1.5, -2, -0.5][col];
    P.bend = BEND([5, 8, 9, 6][col], col / 4 * TAU);
    P.plume = PL(col / 4, [12, 28, 34, 22][col], [7, 14, 16, 12][col], [0.5, 1, 1, 0.8][col]);
    return P;
  }

  if (row === 4) {                       // 跳跃：蓄力-起跳-顶点-下落-落地
    P.sy = [0.92, 1.06, 1.00, 1.03, 0.90][col];
    P.sx = [1.06, 0.95, 1.00, 0.97, 1.08][col];
    P.ty = [5, -8, -18, -9, 4][col];
    P.rot = deg([2, -7, -4, 2, 1][col]);
    P.bend = BEND([8, 6, 10, 8, 6][col], col / 5 * TAU);
    P.fin = FIN([0.15, -0.40, -0.55, -0.20, 0.10][col]);
    P.plume = PL([0.20, 0.50, 0.75, 0.90, 0.05][col], [14, 30, 34, 26, 12][col],
      [9, 16, 20, 14, 8][col], [0.6, 1, 1, 0.8, 0.4][col]);
    return P;
  }

  if (row === 5) {                       // 失败：低头下坠，喷水有气无力
    P.rot = deg([6, 7, 8, 7, 6, 7, 8, 6][col]);
    P.ty = [2, 3, 4, 3, 2, 3, 4, 3][col];
    P.sx = 1.02; P.sy = 0.97;
    P.tx = Math.sin(col / 8 * TAU * 2) * 1.2;
    P.bend = BEND(4, col / 8 * TAU);
    P.fin = FIN(0.30);
    P.plume = PL(col / 8, 9, 5, [0.35, 0, 0.20, 0, 0.25, 0, 0.15, 0.05][col]);
    return P;
  }

  if (row === 6) {                       // 等待用户：左右轻摆，喷水稳定
    const T = col / 6;
    P.tx = Math.sin(T * TAU) * 2.0;
    P.ty = Math.cos(T * TAU) * 1.0;
    P.bend = BEND(7, T * TAU);
    P.fin = FIN(0.12 * Math.sin(T * TAU * 3));
    P.plume = PL(T, 18, 11, 0.75);
    return P;
  }

  if (row === 7) {                       // 工作中：奋力游动 + 持续喷水
    const T = col / 6;
    P.bend = BEND(24, T * TAU);
    P.ty = Math.sin(T * TAU * 2) * 2.5;
    P.rot = deg(2) * Math.sin(T * TAU);
    P.fin = FIN(0.30 * Math.sin(T * TAU * 2 + 0.5));
    P.fluke = FLUKE(0.16 * Math.sin(T * TAU * 2 + 1.0));
    P.plume = PL(T, 40, 22, 1.0, 0.22);
    return P;
  }

  if (row === 8) {                       // 完成待查看：得意，翘鳍 + 高喷
    const T = col / 6;
    P.ty = [0, -2.5, -3.5, -2, 0, 1.2][col];
    P.rot = deg([0, -1, -2, -1, 0, 1][col]);
    P.bend = BEND(10, T * TAU);
    P.fin = FIN(-0.35);
    P.plume = PL(T, [20, 36, 46, 38, 26, 16][col], [10, 16, 20, 17, 13, 9][col],
      [0.8, 1, 1, 1, 0.8, 0.5][col]);
    return P;
  }

  // rows 9-10: 16 个注视方向，从正上方起顺时针每 22.5°
  const i = (row - 9) * 8 + col;
  const ang = i * Math.PI / 8;
  const dx = Math.sin(ang), dy = -Math.cos(ang);
  P.look = { dx: dx * 15, dy: dy * 15 };
  P.tx = dx * 1.2; P.ty = dy * 1.2;
  P.rot = deg(2.5) * dx;
  P.bend = BEND(5, i / 16 * TAU);
  P.fin = FIN(0.05);
  P.plume = PL((i % 6) / 6, 14, 8, 0.7, dx * 0.30);
  return P;
}
