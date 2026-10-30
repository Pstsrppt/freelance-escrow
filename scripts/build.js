// Compile the contract, write the ABI, and inject it into index.html
const fs = require("fs"), path = require("path"), solc = require("solc");
const root = path.join(__dirname, "..");
const src = fs.readFileSync(path.join(root, "contracts/FreelanceEscrow.sol"), "utf8");
const input = { language: "Solidity", sources: { "FreelanceEscrow.sol": { content: src } },
  settings: { optimizer: { enabled: true, runs: 200 }, outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } } };
const out = JSON.parse(solc.compile(JSON.stringify(input)));
const errors = (out.errors || []).filter(e => e.severity === "error");
(out.errors || []).forEach(e => console.log(e.severity + ": " + e.formattedMessage));
if (errors.length) process.exit(1);
const abi = out.contracts["FreelanceEscrow.sol"].FreelanceEscrow.abi;
fs.writeFileSync(path.join(root, "abi/FreelanceEscrow.abi.json"), JSON.stringify(abi, null, 2));
const tpl = fs.readFileSync(path.join(__dirname, "index.template.html"), "utf8");
fs.writeFileSync(path.join(root, "index.html"), tpl.replace("__ABI__", JSON.stringify(abi)));
console.log("Built abi/FreelanceEscrow.abi.json and index.html");
