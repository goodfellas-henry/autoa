/* AutoA 操作画面 */
(() => {
  "use strict";
  const { ethers } = window;
  const ART = window.VAULT_ARTIFACT;

  // ------------------------------------------------------------ ネットワーク設定
  const NETS = {
    8453: {
      name: "Base",
      explorer: "https://basescan.org",
      npm: "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1", // Uniswap V3 NonfungiblePositionManager
      router: "0x2626664c2603336E57B271c5C0b26F421741e481", // Uniswap SwapRouter02
      weth: "0x4200000000000000000000000000000000000006",
      usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      cbbtc: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf",
    },
  };
  // テスト用（手元の練習環境）。通常は使われません。
  try {
    const dev = JSON.parse(localStorage.getItem("devNet") || "null");
    if (dev) NETS[31337] = { name: "練習環境", explorer: "", ...dev };
  } catch (_) {}

  const FEE_TIERS = [
    { fee: 100, spacing: 1, label: "0.01%" },
    { fee: 500, spacing: 10, label: "0.05%" },
    { fee: 3000, spacing: 60, label: "0.3%" },
    { fee: 10000, spacing: 200, label: "1%" },
  ];
  const PAIR_NOTE = {
    usdc: "ETH とドル（USDC）の組み合わせ。ETH が上がると USDC が増え、下がると ETH が増えます。",
    cbbtc: "BTC と ETH の組み合わせ。両方とも仮想通貨なので、仮想通貨全体が上がれば増え、下がれば減ります。2つは同じ方向に動きやすく、範囲から外れにくいのが特徴です。",
  };

  const ERC20 = ["function decimals() view returns (uint8)", "function symbol() view returns (string)", "function balanceOf(address) view returns (uint256)"];
  const POOL = ["function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)", "function liquidity() view returns (uint128)"];
  const FACTORY = ["function getPool(address, address, uint24) view returns (address)"];
  const NPM = [
    "function factory() view returns (address)",
    "function positions(uint256) view returns (uint96, address, address, address, uint24, int24, int24, uint128 liquidity, uint256, uint256, uint128, uint128)",
    "function collect((uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max)) returns (uint256 amount0, uint256 amount1)",
  ];
  const MAX128 = (1n << 128n) - 1n;

  const ERR_JA = {
    NotOwner: "持ち主の財布でしか実行できません。",
    NotKeeperOrOwner: "ロボットか持ち主しか実行できません。",
    IsPaused: "ロボットが一時停止中です。",
    HasPosition: "すでに運用中です。追加する場合は「資金を追加する」を使ってください。",
    NoPosition: "運用中のポジションがありません。",
    InRange: "価格が範囲内なので、組み直しは不要です。",
    TooSoon: "前回の組み直しから時間が経っていません。",
    PriceUnstable: "価格が急に動いた直後のため、安全のため中止しました。数分待ってからやり直してください。",
    BadParam: "設定の値が正しくありません（選んだ手数料の区分のプールが存在しない可能性があります）。",
    EthTransferFailed: "ETH の送金に失敗しました。",
  };

  // ------------------------------------------------------------ 画面の部品
  const $ = (id) => document.getElementById(id);
  const show = (id, on = true) => $(id).classList.toggle("hidden", !on);
  const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "-");
  function say(msg, kind = "info") {
    const t = new Date().toLocaleTimeString("ja-JP");
    const div = document.createElement("div");
    div.className = "box " + kind;
    div.innerHTML = `<b>${t}</b>　${msg}`;
    $("log").prepend(div);
    while ($("log").children.length > 8) $("log").lastChild.remove();
  }
  const usd = (n) => "$" + (n >= 1000 ? n.toLocaleString("en-US", { maximumFractionDigits: 0 }) : n.toFixed(2));
  const amt = (n, d = 6) => (Math.abs(n) < 1e-9 ? "0" : Math.abs(n) < 0.000001 ? n.toExponential(2) : Number(n.toFixed(d)).toString());
  const niceSym = (s) => (s === "WETH" ? "ETH" : s === "cbBTC" ? "BTC" : s);

  // ------------------------------------------------------------ 状態
  let provider, signer, account, chainId, net, factory;
  let vault, info;
  let isOwner = false;

  // ------------------------------------------------------------ 保存済みの金庫
  const savedKey = () => "vaults:" + chainId;
  function loadSaved() {
    let list = [];
    try { list = JSON.parse(localStorage.getItem(savedKey()) || "[]"); } catch (_) {}
    const old = localStorage.getItem("vault:" + chainId); // 旧形式からの引き継ぎ
    if (old && !list.some((v) => v.addr.toLowerCase() === old.toLowerCase())) list.push({ addr: old, label: "金庫" });
    return list;
  }
  function saveVault(addr, label) {
    try {
      const list = loadSaved().filter((v) => v.addr.toLowerCase() !== addr.toLowerCase());
      list.unshift({ addr, label });
      localStorage.setItem(savedKey(), JSON.stringify(list));
      localStorage.setItem("lastVault:" + chainId, addr);
    } catch (_) {}
    renderSaved();
  }
  function renderSaved() {
    const list = loadSaved();
    $("savedList").innerHTML = list.map((v) => `<option value="${v.addr}">${v.label}（${short(v.addr)}）</option>`).join("");
    show("savedWrap", list.length > 0);
    $("createBox").open = list.length === 0;
  }

  // ------------------------------------------------------------ 接続
  async function connect() {
    if (!window.ethereum) {
      say("MetaMask が見つかりません。スマホの場合は MetaMask アプリ内のブラウザでこのページを開いてください。", "err");
      return;
    }
    provider = new ethers.BrowserProvider(window.ethereum, "any");
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    account = await signer.getAddress();
    chainId = Number((await provider.getNetwork()).chainId);
    net = NETS[chainId];
    $("acct").textContent = short(account);
    $("net").textContent = net ? net.name : `対応していません（${chainId}）`;
    show("netWarn", !net);
    $("btnConnect").textContent = "つなぎ直す";
    if (!net) return;
    const npm = new ethers.Contract(net.npm, NPM, provider);
    factory = new ethers.Contract(await npm.factory(), FACTORY, provider);
    show("pickCard");
    renderSaved();
    await updateFeeChoices();
    const last = localStorage.getItem("lastVault:" + chainId) || loadSaved()[0]?.addr;
    if (last) {
      $("savedList").value = last;
      await openVault(last);
    }
  }

  async function switchToBase() {
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x2105" }] });
    } catch (e) {
      if (e.code === 4902) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{ chainId: "0x2105", chainName: "Base", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: ["https://mainnet.base.org"], blockExplorerUrls: ["https://basescan.org"] }],
        });
      } else throw e;
    }
    location.reload();
  }

  // ------------------------------------------------------------ 取引の送信
  function explainError(e) {
    let name = e?.revert?.name;
    if (!name && e?.data) {
      try { name = new ethers.Interface(ART.abi).parseError(e.data)?.name; } catch (_) {}
    }
    if (name && ERR_JA[name]) return ERR_JA[name];
    if (e?.code === "ACTION_REJECTED" || e?.code === 4001) return "MetaMask でキャンセルされました。";
    if (/"OLD"|reverted: OLD/.test(e?.message || "")) return "このプールは平均価格の記録がまだ足りません。「価格記録を準備する」を押して10分ほど待ってから、やり直してください。";
    if (/insufficient funds/i.test(e?.message || "")) return "ETH が足りません（ガス代を含めて確認してください）。";
    if (/Too little received/i.test(e?.message || "") || /Too little/i.test(e?.shortMessage || "")) return "交換で受け取る量が想定より少なかったため中止しました（価格が動いた可能性があります）。";
    return e?.shortMessage || e?.message || String(e);
  }

  async function run(label, fn) {
    const btns = document.querySelectorAll("button");
    btns.forEach((b) => (b.disabled = true));
    try {
      say(`${label}：MetaMask で内容を確認して承認してください。`);
      const tx = await fn();
      say(`${label}：送信しました。完了を待っています…`);
      const rc = await tx.wait();
      const link = net.explorer ? ` <a href="${net.explorer}/tx/${rc.hash}" target="_blank" rel="noopener">記録を見る</a>` : "";
      say(`${label}：完了しました。${link}`, "ok");
      return rc;
    } catch (e) {
      say(`${label}：${explainError(e)}`, "err");
      return null;
    } finally {
      btns.forEach((b) => (b.disabled = false));
      if (vault) await refresh().catch(() => {});
    }
  }

  // ------------------------------------------------------------ 計算
  const sqrtFromTick = (t) => Math.pow(1.0001, Number(t) / 2);
  function amountsFor(L, sqrtP, ta, tb) {
    const a = sqrtFromTick(ta), b = sqrtFromTick(tb);
    if (sqrtP <= a) return [(L * (b - a)) / (a * b), 0];
    if (sqrtP >= b) return [0, L * (b - a)];
    return [(L * (b - sqrtP)) / (sqrtP * b), L * (sqrtP - a)];
  }
  function widthTicks(pct, spacing) {
    const raw = (2 * Math.log(1 + pct)) / Math.log(1.0001);
    return Math.max(2 * spacing, Math.round(raw / spacing) * spacing);
  }
  function nearestPct(width) {
    const opts = [0.01, 0.02, 0.03, 0.05, 0.1];
    let best = opts[0];
    for (const o of opts) if (Math.abs(widthTicks(o, info.spacing) - width) < Math.abs(widthTicks(best, info.spacing) - width)) best = o;
    return best.toFixed(2);
  }
  // 1 token0 あたりの token1（人が読む単位）
  const p1per0FromTick = (tick) => Math.pow(1.0001, Number(tick)) * Math.pow(10, info.dec0 - info.dec1);
  // 表示用の価格：1 base あたりの quote
  const basePrice = (tick) => (info.baseIs0 ? p1per0FromTick(tick) : 1 / p1per0FromTick(tick));
  function fmtPrice(p) {
    return info.quoteIsUsd ? usd(p) : `${amt(p, p >= 100 ? 2 : 4)} ${info.quoteName}`;
  }

  // ------------------------------------------------------------ 新しい金庫：使えるプールの確認
  async function updateFeeChoices() {
    const otherKey = $("newPair").value;
    $("pairNote").textContent = PAIR_NOTE[otherKey] || "";
    const other = net[otherKey];
    const sel = $("newFee");
    sel.innerHTML = `<option value="">確認中…</option>`;
    if (!other) { sel.innerHTML = `<option value="">このネットワークでは使えません</option>`; return; }
    const found = [];
    for (const t of FEE_TIERS) {
      try {
        const p = await factory.getPool(net.weth, other, t.fee);
        if (p !== ethers.ZeroAddress) {
          const liq = await new ethers.Contract(p, POOL, provider).liquidity();
          found.push({ ...t, liq });
        }
      } catch (_) {}
    }
    if (!found.length) { sel.innerHTML = `<option value="">使えるプールがありません</option>`; return; }
    const best = found.reduce((a, b) => (b.liq > a.liq ? b : a));
    sel.innerHTML = found
      .map((t) => `<option value="${t.fee}" ${t === best ? "selected" : ""}>${t.label}${t === best ? "（取引が一番多い・おすすめ）" : ""}</option>`)
      .join("");
  }

  // ------------------------------------------------------------ 金庫を作る
  async function deploy() {
    const keeper = $("newKeeper").value.trim();
    if (!ethers.isAddress(keeper)) return say("ロボットの住所が正しくありません（0x で始まる42文字）。", "err");
    if (keeper.toLowerCase() === account.toLowerCase()) return say("ロボットの住所に、自分の財布の住所は使わないでください。", "err");
    const fee = Number($("newFee").value);
    const tier = FEE_TIERS.find((t) => t.fee === fee);
    if (!tier) return say("手数料の区分を選んでください。", "err");
    const otherKey = $("newPair").value;
    const width = widthTicks(Number($("newWidth").value), tier.spacing);
    const cf = new ethers.ContractFactory(ART.abi, ART.bytecode, signer);
    let addr;
    const rc = await run("金庫の作成", async () => {
      const c = await cf.deploy(net.npm, net.router, net.weth, net[otherKey], fee, keeper, width);
      addr = await c.getAddress();
      return c.deploymentTransaction();
    });
    if (rc && addr) {
      say(`金庫ができました。住所：<span class="mono">${addr}</span><br>ロボットの設定で使うので、控えておいてください。`, "ok");
      await openVault(addr);
    }
  }

  // ------------------------------------------------------------ 金庫を開く
  async function openVault(addr) {
    if (!ethers.isAddress(addr)) return say("金庫の住所が正しくありません。", "err");
    const code = await provider.getCode(addr);
    if (code === "0x") return say("この住所には金庫が見つかりません。ネットワークと住所を確認してください。", "err");
    vault = new ethers.Contract(addr, ART.abi, signer);
    const [owner, t0, t1, poolAddr, npmAddr, wethAddr, fee, spacing] = await Promise.all([
      vault.owner(), vault.token0(), vault.token1(), vault.pool(), vault.positionManager(), vault.weth(), vault.fee(), vault.tickSpacing(),
    ]);
    const c0 = new ethers.Contract(t0, ERC20, provider), c1 = new ethers.Contract(t1, ERC20, provider);
    const [dec0, dec1, sym0, sym1] = await Promise.all([c0.decimals(), c1.decimals(), c0.symbol(), c1.symbol()]);
    const wethIs0 = t0.toLowerCase() === wethAddr.toLowerCase();
    const otherSym = wethIs0 ? sym1 : sym0;
    const quoteIsUsd = /USD/i.test(otherSym);
    // USD の組み合わせ：ETH の価格をドルで表示。仮想通貨どうし：BTC の価格を ETH で表示。
    const baseIs0 = quoteIsUsd ? wethIs0 : !wethIs0;
    info = {
      addr, owner, t0, t1, c0, c1, fee: Number(fee), spacing: Number(spacing),
      dec0: Number(dec0), dec1: Number(dec1), sym0: niceSym(sym0), sym1: niceSym(sym1),
      wethIs0, baseIs0, quoteIsUsd,
      baseName: niceSym(baseIs0 ? sym0 : sym1),
      quoteName: niceSym(baseIs0 ? sym1 : sym0),
      pool: new ethers.Contract(poolAddr, POOL, provider),
      npm: new ethers.Contract(npmAddr, NPM, provider),
    };
    info.pairLabel = `${info.baseName} / ${info.quoteName}`;
    // 仮想通貨どうしの場合、ドル換算用に ETH/USDC の価格を取る
    info.ethUsdPool = null;
    if (!quoteIsUsd && net.usdc) {
      for (const f of [500, 3000]) {
        try {
          const p = await factory.getPool(net.weth, net.usdc, f);
          if (p !== ethers.ZeroAddress) { info.ethUsdPool = new ethers.Contract(p, POOL, provider); break; }
        } catch (_) {}
      }
      const [d0] = [Number(await new ethers.Contract(net.usdc, ERC20, provider).decimals())];
      info.usdcDec = d0;
      info.usdcIs0 = net.usdc.toLowerCase() < net.weth.toLowerCase();
    }
    saveVault(addr, `${info.pairLabel}・${(info.fee / 10000).toString()}%`);
    isOwner = owner.toLowerCase() === account.toLowerCase();
    $("createBox").open = false;
    show("statusCard");
    show("notOwner", !isOwner);
    await refresh();
  }

  async function ethUsd() {
    if (!info.ethUsdPool) return null;
    try {
      const s = await info.ethUsdPool.slot0();
      const p = Math.pow(1.0001, Number(s.tick)); // token1 per token0（生の単位）
      return info.usdcIs0 ? (1 / p) * Math.pow(10, info.usdcDec - 18) : p * Math.pow(10, 18 - info.usdcDec);
    } catch (_) { return null; }
  }

  // ------------------------------------------------------------ 成績（入れたお金と今のお金）
  // 入れた記録はこの端末（ブラウザ）に保存する。操作画面から入れたときは自動で記録する。
  const KNOWN_DEPOSITS = {
    // 設置時の記録（ブロックチェーン上の入金記録より）
    "0x231914d76edac99528683ef909b16ab9f18f9974": { eth: 0.01, date: "2026-10-21" },
    "0xdeeeb4b517e54a656b6b707e016372d7bfb98c18": { eth: 0.01, date: "2026-10-21" },
  };
  const recKey = (addr) => `deposit:${chainId}:${addr.toLowerCase()}`;
  function loadRec(addr) {
    try {
      const r = JSON.parse(localStorage.getItem(recKey(addr)) || "null");
      if (r) return r;
    } catch (_) {}
    return KNOWN_DEPOSITS[addr.toLowerCase()] || null;
  }
  function saveRec(addr, r) {
    try { localStorage.setItem(recKey(addr), JSON.stringify(r)); } catch (_) {}
  }
  const todayJst = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  // 操作画面から ETH を入れたとき、量を足し上げる（円は入れた日の値段で足す）
  async function addToRec(addr, ethIn) {
    let r = loadRec(addr);
    if (!r || !(r.eth > 0)) r = { eth: 0, date: todayJst(), yen: 0 };
    let yen = r.yen ?? null;
    if (yen == null && r.eth > 0) {
      const h = await jpyOn(r.date);
      yen = h ? r.eth * h : null;
    }
    const nowJ = await jpyNow();
    saveRec(addr, { eth: r.eth + ethIn, date: r.date, yen: yen != null && nowJ ? yen + ethIn * nowJ : null });
  }

  // ETH の円の値段（CoinGecko（コインゲッコー）の無料の公開情報を使う）
  let jpyCache = { at: 0, v: null };
  async function jpyNow() {
    if (Date.now() - jpyCache.at < 60e3 && jpyCache.v) return jpyCache.v;
    try {
      const r = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=jpy");
      const v = (await r.json())?.ethereum?.jpy;
      if (v > 0) { jpyCache = { at: Date.now(), v }; return v; }
    } catch (_) {}
    // 予備：ETH のドルの値段 × ドル円（為替の無料公開情報）
    try {
      const usdPerEth = info?.quoteIsUsd ? info.lastPrice : await ethUsd();
      const r = await fetch("https://open.er-api.com/v6/latest/USD");
      const fx = (await r.json())?.rates?.JPY;
      if (usdPerEth > 0 && fx > 0) { jpyCache = { at: Date.now(), v: usdPerEth * fx }; return jpyCache.v; }
    } catch (_) {}
    return jpyCache.v;
  }
  async function jpyOn(date) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date || "")) return null;
    const key = "jpyhist:" + date;
    try { const c = Number(localStorage.getItem(key)); if (c > 0) return c; } catch (_) {}
    try {
      const [y, m, d] = date.split("-");
      const r = await fetch(`https://api.coingecko.com/api/v3/coins/ethereum/history?date=${d}-${m}-${y}&localization=false`);
      const v = (await r.json())?.market_data?.current_price?.jpy;
      if (v > 0) { try { localStorage.setItem(key, String(v)); } catch (_) {} return v; }
    } catch (_) {}
    return null;
  }
  const yen = (n) => (n < 0 ? "−" : "") + Math.round(Math.abs(n)).toLocaleString("ja-JP") + "円";
  const signedYen = (n) => (n >= 0 ? "+" : "−") + Math.round(Math.abs(n)).toLocaleString("ja-JP") + "円";

  async function showPerf(totalEth) {
    const r = loadRec(info.addr);
    const set = (id, html) => ($(id).innerHTML = html);
    $("pEth").value = r?.eth ?? "";
    $("pDate").value = r?.date ?? "";
    $("pYen").value = r?.yen != null ? Math.round(r.yen) : "";
    if (!r || !(r.eth > 0)) {
      set("pIn", "-"); set("pNow", `${amt(totalEth, 6)} ETH`); set("pGain", "-");
      set("pNote", "入れた記録がありません。下の「入れた記録を直す」で、入れた ETH の量と日付を入れてください。");
      return;
    }
    const nowJ = await jpyNow();
    const histJ = r.yen != null ? null : await jpyOn(r.date);
    const inYen = r.yen != null ? r.yen : histJ ? r.eth * histJ : null;
    const ethGain = totalEth - r.eth, pctEth = (ethGain / r.eth) * 100;
    set("pIn", `${amt(r.eth, 6)} ETH${inYen != null ? `<br><small>${yen(inYen)}（${r.date}）</small>` : ""}`);
    set("pNow", `${amt(totalEth, 6)} ETH${nowJ ? `<br><small>${yen(totalEth * nowJ)}（今の値段）</small>` : ""}`);
    if (nowJ && inYen != null) {
      const g = totalEth * nowJ - inYen, pct = (g / inYen) * 100;
      set("pGain", `<span class="${g >= 0 ? "up" : "down"}">${signedYen(g)}（${pct >= 0 ? "+" : ""}${pct.toFixed(2)}%）</span>`);
      const opYen = ethGain * nowJ, priceYen = g - opYen;
      set("pNote",
        `内訳：運用の成果 <b class="${opYen >= 0 ? "up" : "down"}">${signedYen(opYen)}</b>（ETH の量で ${ethGain >= 0 ? "+" : ""}${pctEth.toFixed(2)}%）` +
        ` ／ ETH の値動き <b class="${priceYen >= 0 ? "up" : "down"}">${signedYen(priceYen)}</b><br>` +
        `「運用の成果」は、ETH をそのまま持っていた場合と比べてどれだけ増えたかです。財布に届いた手数料（毎日数円）は含みません。`);
    } else {
      set("pGain", `<span class="${ethGain >= 0 ? "up" : "down"}">${ethGain >= 0 ? "+" : ""}${amt(ethGain, 6)} ETH（${pctEth >= 0 ? "+" : ""}${pctEth.toFixed(2)}%）</span>`);
      set("pNote", "円の値段を取得できなかったため、ETH の量だけで表示しています。少し待ってから「最新の状態に更新」を押してください。");
    }
  }

  // ------------------------------------------------------------ 状況の表示
  async function refresh() {
    const [slot, pid, lo, hi, keeper, paused, feesToOwner, width, interval, twap, b0raw, b1raw, ethRaw] = await Promise.all([
      info.pool.slot0(), vault.positionId(), vault.tickLower(), vault.tickUpper(), vault.keeper(), vault.paused(),
      vault.feesToOwner(), vault.rangeWidth(), vault.minRebalanceInterval(), vault.twapWindow(),
      info.c0.balanceOf(info.addr), info.c1.balanceOf(info.addr), provider.getBalance(info.addr),
    ]);
    const sqrtP = Number(slot.sqrtPriceX96) / 2 ** 96;
    const tick = Number(slot.tick);
    const price = basePrice(tick); // 1 base あたりの quote
    const d0 = 10 ** info.dec0, d1 = 10 ** info.dec1;
    // token0/1 の量を base/quote に並べ替える
    const bq = (a0, a1) => (info.baseIs0 ? [a0, a1] : [a1, a0]);

    let p0 = 0, p1 = 0, f0 = 0, f1 = 0;
    const has = pid !== 0n;
    if (has) {
      const pos = await info.npm.positions(pid);
      [p0, p1] = amountsFor(Number(pos.liquidity), sqrtP, lo, hi);
      p0 /= d0; p1 /= d1;
      try {
        const r = await info.npm.collect.staticCall({ tokenId: pid, recipient: info.addr, amount0Max: MAX128, amount1Max: MAX128 }, { from: info.addr });
        f0 = Number(r[0]) / d0; f1 = Number(r[1]) / d1;
      } catch (_) {}
    }
    let i0 = Number(b0raw) / d0, i1 = Number(b1raw) / d1;
    const ethIdle = Number(ethers.formatEther(ethRaw)); // 金庫に残った ETH は WETH と同じ扱い
    if (info.wethIs0) i0 += ethIdle; else i1 += ethIdle;

    const [pb, pq] = bq(p0, p1), [fb, fq] = bq(f0, f1), [ib, iq] = bq(i0, i1);
    const inQuote = (b, q) => b * price + q;
    const totalQ = inQuote(pb + fb + ib, pq + fq + iq);
    const both = (b, q, dq = 6) => `${amt(b)} ${info.baseName} ／ ${amt(q, dq)} ${info.quoteName}`;

    $("sPair").textContent = `${info.pairLabel}（${info.fee / 10000}%）`;
    $("sPriceLbl").textContent = `${info.baseName} の価格`;
    $("sPrice").textContent = fmtPrice(price);
    $("sKeeper").textContent = short(keeper) + (paused ? "（一時停止中）" : "");
    $("sVault").textContent = info.addr;
    $("sIdle").textContent = both(ib, iq, info.quoteIsUsd ? 2 : 6);

    let totalText = info.quoteIsUsd ? usd(totalQ) : `${amt(totalQ, 6)} ${info.quoteName}`;
    if (!info.quoteIsUsd) {
      const eu = await ethUsd();
      if (eu) totalText += `（約 ${usd(totalQ * eu)}）`;
    }
    $("sTotal").textContent = totalText;
    // 金庫の中身を ETH の量に直す（ドルとの組み合わせはドル÷ETH の価格、仮想通貨どうしは元々 ETH 建て）
    const totalEth = info.quoteIsUsd ? totalQ / price : totalQ;
    info.lastPrice = price;
    showPerf(totalEth).catch(() => {});

    const pill = $("pill");
    if (!has) {
      pill.className = "pill none"; pill.textContent = "未運用";
      $("sRange").textContent = "-"; $("sPos").textContent = "-"; $("sFees").textContent = "-";
      show("barWrap", false);
    } else {
      const pa = basePrice(lo), pbb = basePrice(hi);
      const [pLo, pHi] = pa < pbb ? [pa, pbb] : [pbb, pa];
      const inR = tick >= Number(lo) && tick < Number(hi);
      pill.className = "pill " + (inR ? "in" : "out");
      pill.textContent = inR ? "範囲内：手数料が入っています" : "範囲外：手数料は止まっています";
      $("sRange").textContent = `${fmtPrice(pLo)} 〜 ${fmtPrice(pHi)}`;
      $("sPos").textContent = both(pb, pq, info.quoteIsUsd ? 2 : 6);
      const feeQ = inQuote(fb, fq);
      $("sFees").textContent = `${both(fb, fq, info.quoteIsUsd ? 4 : 8)}（約 ${info.quoteIsUsd ? usd(feeQ) : amt(feeQ, 8) + " " + info.quoteName}）`;
      const span = pHi - pLo, min = Math.min(pLo, price) - span * 0.6, max = Math.max(pHi, price) + span * 0.6;
      const pos = (v) => ((v - min) / (max - min)) * 100;
      $("barRange").style.left = pos(pLo) + "%";
      $("barRange").style.width = pos(pHi) - pos(pLo) + "%";
      $("barNow").style.left = `calc(${pos(price)}% - 1px)`;
      $("barMin").textContent = fmtPrice(min);
      $("barMax").textContent = fmtPrice(max);
      show("barWrap");
    }

    document.querySelectorAll(".ownerOnly").forEach((el) => el.classList.toggle("hidden", !isOwner));
    if (isOwner) {
      show("startCard", !has);
      show("manageCard", has || i0 + i1 > 0);
      $("btnAdd").disabled = !has;
      $("btnCollect").disabled = !has;
      $("startNote").textContent = `入れた ETH の半分を自動で ${info.wethIs0 ? info.sym1 : info.sym0} に交換し、今の価格を中心に預けます。交換で受け取る量が想定より 1% 以上少ない場合は自動で中止されます。`;
      $("setWidth").value = nearestPct(Number(width));
      $("setFees").value = feesToOwner ? "1" : "0";
      $("setInterval").value = Math.round(Number(interval) / 60);
      $("setTwap").value = Math.round(Number(twap) / 60);
      $("btnPause").textContent = paused ? "ロボットを再開する" : "ロボットを一時停止する";
      $("btnPause").dataset.paused = paused ? "1" : "0";
    }
    info.tick = tick;
    let oracleOk = true;
    try { await vault.twapTick(); } catch (_) { oracleOk = false; }
    show("oracleWarn", !oracleOk && isOwner);
  }

  // ------------------------------------------------------------ 持ち主の操作
  async function minOutFor(ethIn) {
    // WETH の半分を相手の通貨に交換。受け取り量が想定より 1% 以上少なければ中止。
    const wethBal = Number(await (info.wethIs0 ? info.c0 : info.c1).balanceOf(info.addr)) / 1e18;
    const swapEth = (ethIn + wethBal) * 0.5;
    const p = p1per0FromTick(info.tick);
    const otherPerEth = info.wethIs0 ? p : 1 / p;
    const out = swapEth * otherPerEth * (1 - info.fee / 1e6) * 0.99;
    const dOther = info.wethIs0 ? info.dec1 : info.dec0;
    return BigInt(Math.floor(out * 10 ** dOther));
  }

  function readEth(id) {
    const v = $(id).value.trim();
    if (!v || !(Number(v) > 0)) { say("ETH の量を入力してください。", "err"); return null; }
    return v;
  }

  async function start() {
    const v = readEth("startAmt"); if (!v) return;
    await refresh();
    const minOut = await minOutFor(Number(v));
    const rc = await run("運用の開始", () => vault.start(5000, minOut, { value: ethers.parseEther(v) }));
    if (rc) { await addToRec(info.addr, Number(v)); await refresh().catch(() => {}); }
  }

  async function addFunds() {
    const v = readEth("addAmt"); if (!v) return;
    await refresh();
    const minOut = await minOutFor(Number(v));
    const rc = await run("資金の追加", () => vault.addFunds(5000, minOut, { value: ethers.parseEther(v) }));
    if (rc) { await addToRec(info.addr, Number(v)); await refresh().catch(() => {}); }
  }

  async function exitAll() {
    if (!confirm("運用を止めて、中身をすべてあなたの財布へ送ります。よろしいですか？")) return;
    const rc = await run("全額の引き出し", () => vault.exit($("unwrap").checked));
    // 全部引き出したら記録を0に戻す（次に入れたときに新しく数え直すため）
    if (rc) { saveRec(info.addr, { eth: 0, date: todayJst(), yen: 0 }); await refresh().catch(() => {}); }
  }

  async function saveParams() {
    const width = widthTicks(Number($("setWidth").value), info.spacing);
    const twap = Math.round(Number($("setTwap").value) * 60);
    const interval = Math.round(Number($("setInterval").value) * 60);
    const dev = await vault.maxTwapDeviation();
    await run("設定の保存", () => vault.setParams(width, twap, dev, interval, $("setFees").value === "1"));
  }

  async function setKeeper() {
    const k = $("setKeeper").value.trim();
    if (!ethers.isAddress(k)) return say("ロボットの住所が正しくありません。", "err");
    if (k.toLowerCase() === account.toLowerCase()) return say("自分の財布の住所はロボットに使わないでください。", "err");
    await run("ロボットの変更", () => vault.setKeeper(k));
  }

  async function togglePause() {
    const paused = $("btnPause").dataset.paused === "1";
    await run(paused ? "ロボットの再開" : "ロボットの一時停止", () => vault.setPaused(!paused));
  }

  async function rescue() {
    if (!confirm("緊急用の操作です。運用中のポジションを、そのままあなたの財布へ移します。以後、ロボットは動かなくなります。よろしいですか？")) return;
    await run("ポジションの移動", () => vault.rescuePositionNFT());
  }

  // ------------------------------------------------------------ ボタン
  const on = (id, fn, ev = "click") => $(id).addEventListener(ev, () => fn().catch((e) => say(explainError(e), "err")));
  on("btnConnect", connect);
  on("btnSwitch", switchToBase);
  on("btnOpen", () => openVault($("vaultAddr").value.trim()));
  on("btnOpenSaved", () => openVault($("savedList").value));
  on("newPair", updateFeeChoices, "change");
  on("btnDeploy", deploy);
  on("btnRefresh", refresh);
  on("btnSaveRec", async () => {
    const eth = Number($("pEth").value.replace(/,/g, ""));
    const date = $("pDate").value;
    const y = $("pYen").value.replace(/[,円\s]/g, "");
    if (!(eth > 0)) return say("入れた ETH の量を数字で入れてください（例 0.01）。", "err");
    if (!date) return say("入れた日を選んでください。", "err");
    saveRec(info.addr, { eth, date, yen: y ? Number(y) : null });
    say("入れた記録を保存しました。", "ok");
    await refresh();
  });
  on("btnStart", start);
  on("btnAdd", addFunds);
  on("btnCollect", () => run("手数料の回収", () => vault.collectFees()));
  on("btnExit", exitAll);
  on("btnSaveParams", saveParams);
  on("btnSetKeeper", setKeeper);
  on("btnPause", togglePause);
  on("btnRescue", rescue);
  on("btnOracle", () => run("価格記録の準備", () => vault.prepareOracle(100)));
  if (window.ethereum) {
    window.ethereum.on?.("accountsChanged", () => location.reload());
    window.ethereum.on?.("chainChanged", () => location.reload());
  }
})();
