// env.mjs — 统一解析 sharp 和仓库根路径，让所有脚本在任意 cwd 下都能跑。
//
// sharp 的查找顺序：
//   1. 常规 require('sharp')  —— 在仓库根 `npm i sharp` 之后即可命中
//   2. $DSH_HOME/profiles/desktop 里那份（本机开发时用的就是它）
// 两边都没有就报错，并告诉你怎么办。

import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const HERE = dirname(fileURLToPath(import.meta.url));   // tools/
export const ROOT = resolve(HERE, '..');                        // 仓库根

const require = createRequire(import.meta.url);

function loadSharp() {
  try { return require('sharp'); } catch { /* 继续找 */ }
  const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh');
  const profile = join(dshHome, 'profiles/desktop/package.json');
  if (existsSync(profile)) {
    try { return createRequire(profile)('sharp'); } catch { /* 继续报错 */ }
  }
  throw new Error(
    '找不到 sharp。在仓库根跑 `npm i sharp`，' +
    `或设 DSH_HOME 指向装了 sharp 的 DSH 目录（当前找的是 ${profile}）。`
  );
}

export const sharp = loadSharp();
