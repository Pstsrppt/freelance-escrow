const path = require("path");
// End-to-end UI test: loads index.html in jsdom with a fake MetaMask backed by the local chain
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { ethers } = require("ethers");
const solc = require("solc");
const RPC = "http://127.0.0.1:8545";

async function rpc(method, params = []) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json(); if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; } return j.result;
}

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : fail++; console.log(c ? "  PASS" : "  FAIL", m); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const accounts = await rpc("eth_accounts");
  const [admin, client, free] = accounts;
  // deploy with admin
  const abi = JSON.parse(fs.readFileSync(path.join(__dirname,"../abi/FreelanceEscrow.abi.json"), "utf8"));
  const src = fs.readFileSync(path.join(__dirname,"../contracts/FreelanceEscrow.sol"), "utf8");
  const out = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity", sources: { a: { content: src } }, settings: { optimizer: { enabled: true, runs: 200 }, outputSelection: { "*": { "*": ["evm.bytecode.object"] } } } })));
  const bytecode = "0x" + out.contracts.a.FreelanceEscrow.evm.bytecode.object;
  const h = await rpc("eth_sendTransaction", [{ from: admin, data: bytecode, gas: "0x500000" }]);
  const addr = (await rpc("eth_getTransactionReceipt", [h])).contractAddress;

  async function openAs(account) {
    const html = fs.readFileSync(path.join(__dirname,"../index.html"), "utf8").replace(/<script src="https:\/\/cdn[^"]+"><\/script>/, "").replace(/<link[^>]+>/g, "");
    const dom = new JSDOM(html, { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
    const w = dom.window;
    w.eval(fs.readFileSync(path.join(__dirname,"../node_modules/ethers/dist/ethers.umd.min.js"), "utf8"));
    w.confirm = () => true;
    w.ethereum = {
      on() {},
      async request({ method, params }) {
        if (method === "eth_requestAccounts" || method === "eth_accounts") return [account];
        return rpc(method, params || []);
      },
    };
    w.localStorage.setItem("escrowAddr", addr);
    w.eval(html.split("<script>")[1].split("</script>")[0]);
    await w.connect();
    await sleep(300);
    return w;
  }
  const until = async (w, fn, ms = 60000) => { const t = Date.now(); while (Date.now() - t < ms) { if (fn(w)) return true; await sleep(200); } return false; };
  const text = (w, id) => w.document.getElementById(id).textContent;

  console.log("Client: create + deposit through UI");
  let w = await openAs(client);
  ok(text(w, "info").includes("จำนวนงาน 0"), "contract loaded in UI");
  const d = w.document;
  d.getElementById("fTitle").value = "Website";
  d.getElementById("fDesc").value = "Landing page";
  d.getElementById("fAmt").value = "0.5";
  d.getElementById("fFree").value = free;
  await w.createJob();
  ok(await until(w, w => text(w, "jobs").includes("ฝากเงินแล้ว รอส่งงาน")), "job #1 created & funded (status shown)");
  ok(text(w, "info").includes("0.5 ETH"), "escrow balance 0.5 ETH shown");

  console.log("Freelancer: submit work");
  w = await openAs(free);
  w.document.getElementById("ev1").value = "https://github.com/demo/site";
  await w.act("submit", 1);
  ok(await until(w, w => text(w, "jobs").includes("ส่งงานแล้ว รอตรวจรับ")), "status Submitted shown");

  console.log("Client: approve & release");
  const before = BigInt(await rpc("eth_getBalance", [free, "latest"]));
  w = await openAs(client);
  await w.act("approve", 1);
  ok(await until(w, w => text(w, "jobs").includes("จ่ายเงินแล้ว")), "status Released shown");
  const after = BigInt(await rpc("eth_getBalance", [free, "latest"]));
  ok(after - before === ethers.parseEther("0.5"), "freelancer balance +0.5 ETH");
  await w.act("approve", 1); // should fail gracefully (no button but call directly)
  ok(text(w, "toast").includes("ไม่สำเร็จ"), "double approve rejected in UI: " + text(w, "toast").slice(0, 80));

  console.log("Dispute flow");
  d.getElementById; // noop
  w.document.getElementById("fTitle").value = "App"; w.document.getElementById("fAmt").value = "1"; w.document.getElementById("fFree").value = free;
  await w.createJob();
  await until(w, w => text(w, "jobs").includes("#2"));
  w.document.getElementById("rs2").value = "ไม่ส่งงานตามสเปก";
  await w.act("dispute", 2);
  ok(await until(w, w => text(w, "jobs").includes("ข้อพิพาท")), "dispute raised");
  w = await openAs(admin);
  w.document.getElementById("sp2").value = "0.4";
  await w.act("resolve", 2);
  ok(await until(w, w => text(w, "jobs").includes("ตัดสินข้อพิพาทแล้ว")), "admin resolved 0.4 / 0.6");

  console.log("History");
  await w.loadHistory();
  const hist = text(w, "history");
  ok(["สร้างข้อตกลง", "ฝากเงิน", "ส่งงาน", "จ่ายเงินให้ฟรีแลนซ์", "แจ้งข้อพิพาท", "ตัดสินข้อพิพาท"].every(s => hist.includes(s)), "history table shows all event types");
  ok(w.document.querySelectorAll("#history a[href*='sepolia.etherscan.io/tx/']").length >= 7, "tx hash links to Etherscan");
  await w.jobHistory(2);
  ok(w.document.querySelectorAll("#jh2 tbody tr").length === 4, "per-job history (#2: create, deposit, dispute, resolve)");

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
