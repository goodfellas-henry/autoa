// AutoA 運用ロボット（複数の金庫に対応）
// ---------------------------------------------------------------------------
// やること:
//   1. 一定間隔で各金庫を確認し、価格が範囲から外れていたら rebalance() を呼ぶ
//   2. 設定した間隔で collectFees() を呼び、手数料を回収する
//   3. 何かあれば Discord に通知する（任意）
// このロボットの鍵では、金庫からお金を引き出すことはできません。
// ---------------------------------------------------------------------------
import { ethers } from "ethers";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------- 設定の読み込み
function loadEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}
loadEnv(path.join(here, ".env"));

const cfg = {
  rpc: process.env.RPC_URL || "https://mainnet.base.org",
  key: process.env.KEEPER_PRIVATE_KEY,
  vaults: (process.env.VAULT_ADDRESS || "").split(/[\s,]+/).filter(Boolean),
  intervalSec: Number(process.env.CHECK_INTERVAL_SEC || 60),
  collectHours: Number(process.env.COLLECT_FEES_EVERY_HOURS || 24),
  reportHours: Number(process.env.REPORT_EVERY_HOURS || 24),
  lowGasEth: Number(process.env.LOW_GAS_WARN_ETH || 0.0003),
  discord: process.env.DISCORD_WEBHOOK_URL || "",
  expectedChainId: BigInt(process.env.CHAIN_ID || 8453),
  // 定期報告を送る時刻（日本時間の「時」。off にすると REPORT_EVERY_HOURS の間隔で送る）
  reportHourJst: (process.env.REPORT_HOUR_JST || "9").trim(),
  // 各金庫に入れた ETH の量（VAULT_ADDRESS と同じ順に、カンマ区切り）。成績の比べる相手になる
  startEth: (process.env.START_ETH || "").split(/[\s,]+/).filter(Boolean).map(Number),
};
const STATE_FILE = path.join(here, "state.json");
const EXPLORER = cfg.expectedChainId === 8453n ? "https://basescan.org/tx/" : "tx: ";

const VAULT_ABI = [
  "function owner() view returns (address)",
  "function keeper() view returns (address)",
  "function weth() view returns (address)",
  "function fee() view returns (uint24)",
  "function paused() view returns (bool)",
  "function feesToOwner() view returns (bool)",
  "function positionId() view returns (uint256)",
  "function tickLower() view returns (int24)",
  "function tickUpper() view returns (int24)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function currentTick() view returns (int24)",
  "function inRange() view returns (bool)",
  "function needsRebalance() view returns (bool)",
  "function positionManager() view returns (address)",
  "function pool() view returns (address)",
  "event FeesCollected(uint256 amount0, uint256 amount1, bool sentToOwner)",
  "function rebalance()",
  "function collectFees()",
  "error PriceUnstable(int24 tick, int24 twapTick)",
  "error TooSoon()",
  "error InRange()",
  "error IsPaused()",
  "error NoPosition()",
  "error NotKeeperOrOwner()",
];
const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
];
const NPM_ABI = [
  "function positions(uint256) view returns (uint96, address, address, address, uint24, int24, int24, uint128 liquidity, uint256, uint256, uint128, uint128)",
  "function collect((uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max)) returns (uint256 amount0, uint256 amount1)",
];
const POOL_ABI = ["function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)"];
const MAX128 = (1n << 128n) - 1n;

// ---------------------------------------------------------------- 記録（成績の計算用）
// 持ち主の財布へ送った手数料は金庫から出ていくので、ここに足し上げて成績に含める
function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch (_) { return {}; }
}
function saveState(st) {
  try { fs.writeFileSync(STATE_FILE, JSON.stringify(st, null, 2)); } catch (e) { console.log("記録の保存に失敗:", e.message); }
}

// 集中流動性の「預けている量」を計算する（Uniswap V3 の公式どおり）
export function amountsFor(L, sqrtP, tickLo, tickHi) {
  const a = Math.sqrt(Math.pow(1.0001, Number(tickLo))), b = Math.sqrt(Math.pow(1.0001, Number(tickHi)));
  if (sqrtP <= a) return [(L * (b - a)) / (a * b), 0];
  if (sqrtP >= b) return [0, L * (b - a)];
  return [(L * (b - sqrtP)) / (sqrtP * b), L * (sqrtP - a)];
}

// ---------------------------------------------------------------- 便利関数
const now = () => new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo" });
const log = (...a) => console.log(`[${now()}]`, ...a);
const niceSym = (s) => (s === "WETH" ? "ETH" : s === "cbBTC" ? "BTC" : s);

async function notify(text) {
  log(text);
  if (!cfg.discord) return;
  try {
    await fetch(cfg.discord, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ username: "AutoA", content: text.slice(0, 1900) }),
    });
  } catch (e) {
    log("Discord 通知に失敗:", e.message);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 公開の接続口は一度に大量の問い合わせを受けると失敗することがあるため、
// 読み取りは1つずつ順番に行い、失敗したら少し待ってやり直す
async function read(fn, tries = 4) {
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i >= tries - 1) throw e;
      await sleep(1500 * (i + 1));
    }
  }
}
async function readAll(fns) {
  const out = [];
  for (const f of fns) out.push(await read(f));
  return out;
}

function fmt(n) {
  return n >= 100 ? n.toFixed(0) : n >= 1 ? n.toFixed(2) : n.toPrecision(4);
}

function shortErr(e) {
  if (e?.revert?.name) return `${e.revert.name}(${(e.revert.args || []).join(", ")})`;
  return e?.shortMessage || e?.reason || e?.message || String(e);
}

// ---------------------------------------------------------------- 金庫ごとの準備
async function prepareVault(addr, wallet, provider) {
  const vault = new ethers.Contract(addr, VAULT_ABI, wallet);
  const [keeperOnChain, t0, t1, weth, fee] = await readAll([
    () => vault.keeper(), () => vault.token0(), () => vault.token1(), () => vault.weth(), () => vault.fee(),
  ]);
  const c0 = new ethers.Contract(t0, ERC20_ABI, provider), c1 = new ethers.Contract(t1, ERC20_ABI, provider);
  const [dec0, dec1, s0, s1] = await readAll([() => c0.decimals(), () => c1.decimals(), () => c0.symbol(), () => c1.symbol()]);
  const sym0 = niceSym(s0), sym1 = niceSym(s1);
  const wethIs0 = t0.toLowerCase() === weth.toLowerCase();
  const quoteIsUsd = /USD/i.test(wethIs0 ? sym1 : sym0);
  // ドルとの組み合わせ → ETH の価格をドルで。仮想通貨どうし → BTC 等の価格を ETH で。
  const baseIs0 = quoteIsUsd ? wethIs0 : !wethIs0;
  const base = baseIs0 ? sym0 : sym1, quote = baseIs0 ? sym1 : sym0;
  const D = Number(dec0) - Number(dec1);
  const priceOf = (tick) => {
    const p = Math.pow(1.0001, Number(tick)) * Math.pow(10, D);
    return baseIs0 ? p : 1 / p;
  };
  const name = `${base}/${quote}`;
  const [npmAddr, poolAddr] = await readAll([() => vault.positionManager(), () => vault.pool()]);
  const v = {
    addr, vault, name, base, quote, quoteIsUsd, priceOf, lastCollect: Date.now(),
    c0, c1, dec0: Number(dec0), dec1: Number(dec1), wethIs0,
    npm: new ethers.Contract(npmAddr, NPM_ABI, provider),
    pool: new ethers.Contract(poolAddr, POOL_ABI, provider),
  };

  log(`金庫 ${name}（手数料 ${Number(fee) / 10000}%）: ${addr}`);
  if (keeperOnChain.toLowerCase() !== wallet.address.toLowerCase()) {
    await notify(
      `⚠️ [${name}] この鍵は金庫のロボットとして登録されていません。\n登録中: ${keeperOnChain}\nこの鍵: ${wallet.address}\n操作画面の「ロボットを変更」で登録してください。`
    );
  }
  return v;
}

async function snapshot(v) {
  const [pid, lo, hi, tick, inR, paused] = await readAll([
    () => v.vault.positionId(), () => v.vault.tickLower(), () => v.vault.tickUpper(),
    () => v.vault.currentTick(), () => v.vault.inRange(), () => v.vault.paused(),
  ]);
  const a = v.priceOf(lo), b = v.priceOf(hi);
  return { pid, paused, inRange: inR, price: v.priceOf(tick), lo: Math.min(a, b), hi: Math.max(a, b) };
}

// 金庫の中身（預けている分＋未回収の手数料＋待機分）を ETH の量に換算する
async function valueInEth(v, provider) {
  const [slot, pid, lo, hi, b0, b1, ethRaw] = await readAll([
    () => v.pool.slot0(), () => v.vault.positionId(), () => v.vault.tickLower(), () => v.vault.tickUpper(),
    () => v.c0.balanceOf(v.addr), () => v.c1.balanceOf(v.addr), () => provider.getBalance(v.addr),
  ]);
  const sqrtP = Number(slot.sqrtPriceX96) / 2 ** 96;
  let a0 = Number(b0), a1 = Number(b1); // 生の単位
  if (pid !== 0n) {
    const pos = await read(() => v.npm.positions(pid));
    const [p0, p1] = amountsFor(Number(pos.liquidity), sqrtP, lo, hi);
    a0 += p0; a1 += p1;
    try {
      const r = await read(() =>
        v.npm.collect.staticCall({ tokenId: pid, recipient: v.addr, amount0Max: MAX128, amount1Max: MAX128 }, { from: v.addr })
      );
      a0 += Number(r[0]); a1 += Number(r[1]);
    } catch (_) {}
  }
  return toEth(v, a0, a1, sqrtP) + Number(ethers.formatEther(ethRaw));
}

// token0/token1 の生の量を、今の価格で ETH の量に直す
export function toEth(v, raw0, raw1, sqrtP) {
  const p = sqrtP * sqrtP; // 1 token0 あたりの token1（生の単位）
  return v.wethIs0 ? (raw0 + raw1 / p) / 1e18 : (raw1 + raw0 * p) / 1e18;
}

function resultText(v, totalEth, st, start) {
  const sent = st.sentToOwnerEth?.[v.addr.toLowerCase()] || 0;
  const all = totalEth + sent;
  let line = `　ETH 換算の合計: ${all.toFixed(6)} ETH`;
  if (sent > 0) line += `（うち財布へ送った手数料 ${sent.toFixed(6)}）`;
  if (start > 0) {
    const pct = ((all - start) / start) * 100;
    const mark = pct > 0.05 ? "🟢" : pct < -0.05 ? "🔴" : "⚪";
    line += `\n　入れた ${start} ETH と比べて: ${mark} ${pct >= 0 ? "+" : ""}${pct.toFixed(2)}%（${all - start >= 0 ? "+" : ""}${(all - start).toFixed(6)} ETH）`;
  }
  const prev = st.lastTotal?.[v.addr.toLowerCase()];
  if (typeof prev === "number" && prev > 0) {
    const d = ((all - prev) / prev) * 100;
    line += `\n　前回の報告から: ${d >= 0 ? "+" : ""}${d.toFixed(2)}%`;
  }
  return { line, all };
}

function priceText(v, n) {
  return v.quoteIsUsd ? `$${fmt(n)}` : `${fmt(n)} ${v.quote}`;
}

function describe(v, s) {
  if (s.pid === 0n) return `【${v.name}】運用中のポジションはありません`;
  return `【${v.name}】${v.base} の価格 ${priceText(v, s.price)} ／ 範囲 ${priceText(v, s.lo)}〜${priceText(v, s.hi)} ／ ${
    s.inRange ? "範囲内（手数料が入っています）" : "範囲外"
  }${s.paused ? " ／ 一時停止中" : ""}`;
}

// ---------------------------------------------------------------- 本体
async function main() {
  if (!cfg.key || cfg.vaults.length === 0) {
    console.error("設定が足りません。.env に KEEPER_PRIVATE_KEY と VAULT_ADDRESS を書いてください。");
    process.exit(1);
  }
  for (const a of cfg.vaults) {
    if (!ethers.isAddress(a)) {
      console.error(`金庫の住所の形が正しくありません: ${a}`);
      process.exit(1);
    }
  }
  const provider = new ethers.JsonRpcProvider(cfg.rpc, undefined, { batchMaxCount: 1 });
  const net = await read(() => provider.getNetwork());
  if (net.chainId !== cfg.expectedChainId) {
    console.error(`つながっているネットワークが違います（chainId ${net.chainId}、期待値 ${cfg.expectedChainId}）。`);
    process.exit(1);
  }
  const wallet = new ethers.Wallet(cfg.key, provider);
  log(`ロボットの住所: ${wallet.address}`);

  const vaults = [];
  for (const a of cfg.vaults) vaults.push(await prepareVault(a, wallet, provider));

  const state = loadState();
  state.sentToOwnerEth ||= {};
  state.lastTotal ||= {};

  // withResult: 成績（ETH 換算）も付ける。save: 「前回の報告」として記録する
  const describeAll = async ({ withResult = false, save = false } = {}) => {
    const lines = [];
    for (const [i, v] of vaults.entries()) {
      lines.push(describe(v, await snapshot(v)));
      if (!withResult) continue;
      try {
        const { line, all } = resultText(v, await valueInEth(v, provider), state, cfg.startEth[i] || 0);
        lines.push(line);
        if (save) state.lastTotal[v.addr.toLowerCase()] = all;
      } catch (e) {
        lines.push(`　（成績の計算に失敗しました: ${shortErr(e)}）`);
      }
    }
    if (save) saveState(state);
    return lines.join("\n");
  };

  if (process.argv.includes("--status")) {
    console.log(await describeAll({ withResult: true }));
    const bal = await read(() => provider.getBalance(wallet.address));
    console.log(`ロボットのガス代残高: ${ethers.formatEther(bal)} ETH`);
    return;
  }

  await notify(`🤖 AutoA ロボットを起動しました（金庫 ${vaults.length} 個）。\n${await describeAll({ withResult: true })}`);

  let lastReport = Date.now();
  // 日本時間の日付（例 2026-10-22）。決まった時刻に1日1回送るために使う
  const jstDay = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  const jstHour = () => new Date(Date.now() + 9 * 3600e3).getUTCHours();
  const fixedHour = /^\d{1,2}$/.test(cfg.reportHourJst) ? Number(cfg.reportHourJst) : null;
  // 起動したのが報告時刻より後なら、今日の分は送ったことにする（再起動のたびに送らないため）
  if (fixedHour !== null && jstHour() >= fixedHour) state.lastReportDay = state.lastReportDay || jstDay();
  let lastLowGasWarn = 0;
  const errors = new Map(); // 金庫ごとの連続エラー回数

  async function send(v, fnName) {
    // 失敗しそうな取引は送らない（事前に試算する）
    await v.vault[fnName].staticCall();
    const gas = await v.vault[fnName].estimateGas();
    const tx = await v.vault[fnName]({ gasLimit: (gas * 13n) / 10n });
    log(`[${v.name}] ${fnName} を送信しました: ${tx.hash}`);
    const rc = await tx.wait();
    if (rc.status !== 1) throw new Error(`${fnName} が失敗しました: ${tx.hash}`);
    return rc;
  }

  async function checkVault(v) {
    if (await read(() => v.vault.needsRebalance())) {
      const before = await snapshot(v);
      const rc = await send(v, "rebalance");
      const after = await snapshot(v);
      await notify(
        `🔁 [${v.name}] 範囲を追従させました。\n前: ${priceText(v, before.lo)}〜${priceText(v, before.hi)}\n後: ${priceText(v, after.lo)}〜${priceText(v, after.hi)}\n${v.base} の価格: ${priceText(v, after.price)}\n（交換なしで価格のすぐ隣に置き直しました。価格が少し戻ると手数料が入り始めます）\n${EXPLORER}${rc.hash}`
      );
    }
    if (cfg.collectHours > 0 && Date.now() - v.lastCollect > cfg.collectHours * 3600e3) {
      v.lastCollect = Date.now();
      const [pid, paused] = await readAll([() => v.vault.positionId(), () => v.vault.paused()]);
      if (pid !== 0n && !paused) {
        const rc = await send(v, "collectFees");
        const toOwner = await read(() => v.vault.feesToOwner());
        if (toOwner) {
          // 財布へ送った手数料を ETH に換算して記録（金庫から出ていった分も成績に含めるため）
          try {
            const slot = await read(() => v.pool.slot0());
            const sqrtP = Number(slot.sqrtPriceX96) / 2 ** 96;
            for (const lg of rc.logs) {
              if (lg.address.toLowerCase() !== v.addr.toLowerCase()) continue;
              const ev = v.vault.interface.parseLog(lg);
              if (ev?.name !== "FeesCollected") continue;
              const k = v.addr.toLowerCase();
              state.sentToOwnerEth[k] = (state.sentToOwnerEth[k] || 0) + toEth(v, Number(ev.args[0]), Number(ev.args[1]), sqrtP);
              saveState(state);
            }
          } catch (e) {
            log(`[${v.name}] 手数料の記録に失敗:`, shortErr(e));
          }
        }
        await notify(`💰 [${v.name}] 手数料を回収しました（${toOwner ? "持ち主の財布へ送金" : "金庫に保管"}）。\n${EXPLORER}${rc.hash}`);
      }
    }
  }

  async function round() {
    const bal = await read(() => provider.getBalance(wallet.address));
    if (Number(ethers.formatEther(bal)) < cfg.lowGasEth && Date.now() - lastLowGasWarn > 6 * 3600e3) {
      lastLowGasWarn = Date.now();
      await notify(`⛽ ロボットのガス代が少なくなっています（${ethers.formatEther(bal)} ETH）。\nBase の ETH を ${wallet.address} に少し送ってください。`);
    }

    // 1つの金庫で問題が起きても、他の金庫は止めない
    for (const v of vaults) {
      try {
        await checkVault(v);
        errors.set(v.addr, 0);
      } catch (e) {
        const n = (errors.get(v.addr) || 0) + 1;
        errors.set(v.addr, n);
        const msg = shortErr(e);
        // 価格が不安定・間隔が短すぎる等は「待てば解決する」ので静かに次回へ
        if (/PriceUnstable|TooSoon|InRange|IsPaused|NoPosition/.test(msg)) log(`[${v.name}] 今回は見送り:`, msg);
        else if (n === 3 || n % 60 === 0) await notify(`❗ [${v.name}] エラーが続いています（${n}回）: ${msg}`);
        else log(`[${v.name}] エラー:`, msg);
      }
    }

    const due =
      fixedHour !== null
        ? jstHour() >= fixedHour && state.lastReportDay !== jstDay()
        : cfg.reportHours > 0 && Date.now() - lastReport > cfg.reportHours * 3600e3;
    if (due) {
      lastReport = Date.now();
      state.lastReportDay = jstDay();
      await notify(`📊 定期報告（${jstDay()}）\n${await describeAll({ withResult: true, save: true })}\nガス代残高: ${ethers.formatEther(bal)} ETH`);
    }
  }

  // 無限ループ（エラーが出ても止まらない）
  for (;;) {
    try {
      await round();
    } catch (e) {
      log("エラー（通信など）:", shortErr(e));
    }
    await new Promise((r) => setTimeout(r, cfg.intervalSec * 1000));
  }
}

// 直接実行されたときだけ動かす（計算部分を試験で読み込めるようにするため）
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(async (e) => {
    await notify(`🛑 AutoA ロボットが停止しました: ${shortErr(e)}`);
    process.exit(1);
  });
}
