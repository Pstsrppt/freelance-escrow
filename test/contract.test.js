const path = require("path");
const fs = require("fs");
const solc = require("solc");
const ganache = require("ganache");
const { ethers } = require("ethers");

const src = fs.readFileSync(path.join(__dirname,"../contracts/FreelanceEscrow.sol"), "utf8");
const input = { language: "Solidity", sources: { "FreelanceEscrow.sol": { content: src } },
  settings: { optimizer: { enabled: true, runs: 200 }, outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } } };
const out = JSON.parse(solc.compile(JSON.stringify(input)));
(out.errors || []).forEach(e => console.log(e.severity, e.formattedMessage));
if ((out.errors || []).some(e => e.severity === "error")) process.exit(1);
const c = out.contracts["FreelanceEscrow.sol"].FreelanceEscrow;
fs.writeFileSync(path.join(__dirname,"../abi/FreelanceEscrow.abi.json"), JSON.stringify(c.abi));

let pass = 0, fail = 0;
const ok = (cond, msg) => { cond ? pass++ : fail++; console.log(cond ? "  PASS" : "  FAIL", msg); };
async function reverts(p, reason, msg) {
  try { const tx = await p; await tx.wait(); ok(false, msg + " (no revert)"); }
  catch (e) { const m = (e.shortMessage || e.message || "") + JSON.stringify(e.info || ""); ok(m.includes(reason), msg + " -> " + reason); }
}

(async () => {
  const provider = new ethers.JsonRpcProvider("http://127.0.0.1:8545", undefined, { batchMaxCount: 1, cacheTimeout: -1, staticNetwork: true });
  const _eg = provider.estimateGas.bind(provider); provider.estimateGas = async (tx) => (await _eg(tx)) * 2n;
  const [admin, client, free, other] = await Promise.all([0, 1, 2, 3].map(i => provider.getSigner(i)));
  const F = new ethers.ContractFactory(c.abi, c.evm.bytecode.object, admin);
  const esc = await F.deploy(); await esc.waitForDeployment();
  const E = s => esc.connect(s);
  const now = async () => (await provider.getBlock("latest")).timestamp;
  const amt = ethers.parseEther("1");
  const bal = a => provider.getBalance(a);

  console.log("Scenario 1: happy path");
  await (await E(client).createJob("Website", "Landing page", amt, (await now()) + 86400, free.address)).wait();
  await reverts(E(client).depositPayment(1, { value: ethers.parseEther("0.5") }), "Must deposit exact amount", "wrong amount");
  await reverts(E(other).depositPayment(1, { value: amt }), "Only client", "non-client deposit");
  await (await E(client).depositPayment(1, { value: amt })).wait();
  await reverts(E(client).approveAndRelease(1), "Work not submitted", "release before submit");
  await reverts(E(client).submitWork(1, "x"), "Only freelancer", "client submits");
  await (await E(free).submitWork(1, "ipfs://QmHash")).wait();
  const b0 = await bal(free.address);
  await (await E(client).approveAndRelease(1, {gasLimit: 300000})).wait();
  ok((await bal(free.address)) - b0 === amt, "freelancer received 1 ETH");
  await reverts(E(client).approveAndRelease(1), "already paid", "double payment blocked");
  const j = await esc.getJob(1);
  ok(Number(j.status) === 3 && j.escrowBalance === 0n, "status Released, escrow 0");

  console.log("Scenario 2: dispute split");
  await (await E(client).createJob("App", "Mobile", amt, (await now()) + 86400, free.address)).wait();
  await (await E(client).depositPayment(2, { value: amt })).wait();
  await (await E(free).submitWork(2, "https://github.com/x")).wait();
  await (await E(client).raiseDispute(2, "Incomplete")).wait();
  await reverts(E(client).approveAndRelease(2), "Work not submitted", "release blocked during dispute");
  await reverts(E(other).resolveDispute(2, 0), "Only arbiter", "non-arbiter resolve");
  const fb = await bal(free.address), cb = await bal(client.address);
  await (await E(admin).resolveDispute(2, ethers.parseEther("0.3"), {gasLimit: 500000})).wait();
  ok((await bal(free.address)) - fb === ethers.parseEther("0.3"), "freelancer got 0.3");
  ok((await bal(client.address)) - cb === ethers.parseEther("0.7"), "client got 0.7");
  await reverts(E(admin).resolveDispute(2, 0), "No active dispute", "double resolve blocked");

  console.log("Scenario 3: refund after deadline");
  await (await E(client).createJob("Logo", "Graphic", amt, (await now()) + 100, free.address)).wait();
  await (await E(client).depositPayment(3, { value: amt })).wait();
  await reverts(E(client).refundAfterDeadline(3), "Deadline not passed", "early refund blocked");
  await provider.send("evm_increaseTime", [200]); await provider.send("evm_mine", []);
  await reverts(E(free).submitWork(3, "late"), "Deadline passed", "late submit blocked");
  await (await E(client).refundAfterDeadline(3, {gasLimit: 500000})).wait();
  await reverts(E(client).refundAfterDeadline(3), "Refund not allowed", "double refund blocked");

  console.log("Scenario 4: misc");
  await reverts(client.sendTransaction({ to: await esc.getAddress(), value: 1n }), "Use depositPayment", "direct ETH rejected");
  await (await E(client).createJob("X", "", amt, (await now()) + 1000, free.address)).wait();
  await (await E(client).cancelJob(4)).wait();
  await reverts(E(client).depositPayment(4, { value: amt }), "Already funded or closed", "deposit on cancelled");
  ok((await esc.contractBalance()) === 0n, "contract balance 0 at end");
  ok((await esc.getJobsByClient(client.address)).length === 4, "getJobsByClient = 4");
  const logs = await esc.queryFilter("*");
  ok(logs.length > 10, "events emitted: " + logs.length);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
