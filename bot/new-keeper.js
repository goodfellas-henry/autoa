// ロボット専用の新しい鍵を作り、.env に保存する。
// この鍵では金庫からお金を引き出せないが、ガス代用の ETH は入れるので他人に見せないこと。
import { ethers } from "ethers";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.join(here, ".env");

let env = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : fs.readFileSync(path.join(here, ".env.example"), "utf8");
if (/^KEEPER_PRIVATE_KEY=0x[0-9a-fA-F]{64}\s*$/m.test(env)) {
  const addr = new ethers.Wallet(env.match(/^KEEPER_PRIVATE_KEY=(0x[0-9a-fA-F]{64})/m)[1]).address;
  console.log("ロボットの鍵はすでに作成済みです。");
  console.log("ロボットの住所:", addr);
  process.exit(0);
}

const w = ethers.Wallet.createRandom();
env = env.replace(/^KEEPER_PRIVATE_KEY=.*$/m, `KEEPER_PRIVATE_KEY=${w.privateKey}`);
fs.writeFileSync(envPath, env, { mode: 0o600 });
fs.chmodSync(envPath, 0o600);

console.log("ロボット専用の鍵を作りました（.env に保存済み）。");
console.log("");
console.log("ロボットの住所: " + w.address);
console.log("");
console.log("次にやること:");
console.log("  1. この住所をメモする（操作画面で金庫を作る時に使います）");
console.log("  2. MetaMask から、この住所へ Base の ETH を少し（目安 0.001 ETH）送る");
