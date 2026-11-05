// Compiler-backed ERC-7201 validation, including a deliberately incompatible compiled fixture.
const fs = require("fs");
const cp = require("child_process");
const path = require("path");
const assert = require("assert/strict");
const oz = require("@openzeppelin/upgrades-core");
const solc = process.argv[2] || "solc";
assert.match(
  cp.execFileSync(solc, ["--version"], { encoding: "utf8" }),
  /0\.8\.36\+commit\.8a079791/,
);
const remaps = {
  "@openzeppelin/contracts/": "lib/openzeppelin-contracts/contracts/",
  "@openzeppelin/contracts-upgradeable/":
    "lib/openzeppelin-contracts-upgradeable/contracts/",
};
const sources = {};
function add(file) {
  if (sources[file]) return;
  const content = fs.readFileSync(file, "utf8");
  sources[file] = { content };
  for (const m of content.matchAll(
    /import\s+(?:[\s\S]*?from\s+)?["']([^"']+)["']\s*;/g,
  )) {
    let name = m[1];
    for (const [prefix, actual] of Object.entries(remaps))
      if (name.startsWith(prefix)) name = actual + name.slice(prefix.length);
    if (name.startsWith("."))
      name = path.posix.normalize(
        path.posix.join(path.posix.dirname(file), name),
      );
    add(name);
  }
}
add("src/STRN.sol");
add("test/fixtures/STRNV2.sol");
sources["fixtures/STRNBad.sol"] = {
  content: sources["src/STRN.sol"].content
    .replace("contract STRN is", "contract STRNBad is")
    .replace(
      "address seizureRecipient;",
      "uint256 insertedBeforeRecipient;\n        address seizureRecipient;",
    ),
};
const input = {
  language: "Solidity",
  sources,
  settings: {
    remappings: Object.entries(remaps).map(([a, b]) => a + "=" + b),
    optimizer: { enabled: true, runs: 200 },
    viaIR: true,
    evmVersion: "cancun",
    outputSelection: {
      "*": {
        "*": ["abi", "storageLayout", "evm.bytecode", "evm.deployedBytecode"],
        "": ["ast"],
      },
    },
  },
};
function compile(i) {
  const o = JSON.parse(
    cp.execFileSync(solc, ["--standard-json"], {
      input: JSON.stringify(i),
      maxBuffer: 64 * 1024 * 1024,
      encoding: "utf8",
    }),
  );
  const errors = (o.errors || []).filter((e) => e.severity === "error");
  assert.equal(errors.length, 0, JSON.stringify(errors));
  return o;
}
const output = compile(input);
// Screen constructs implicated by the retrieved compiler bug list for this pin.
function walk(node, visit) {
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const value of Object.values(node))
    if (Array.isArray(value)) value.forEach((x) => walk(x, visit));
    else if (value && typeof value === "object") walk(value, visit);
}
const functions = new Map();
for (const source of Object.values(output.sources))
  walk(source.ast, (n) => {
    if (n.nodeType === "FunctionDefinition") functions.set(n.id, n);
    if (n.nodeType === "FunctionCall" && n.expression?.name === "require")
      assert.ok(
        !n.arguments?.[1]?.names?.length,
        "Affected named custom-error require construct",
      );
  });
const edges = new Map();
for (const [id, fn] of functions) {
  const targets = new Set();
  walk(fn.body, (n) => {
    if (
      n.nodeType === "FunctionCall" &&
      functions.has(n.expression?.referencedDeclaration)
    )
      targets.add(n.expression.referencedDeclaration);
  });
  edges.set(id, targets);
}
function visit(id, active, done) {
  assert.ok(
    !active.has(id),
    "Recursive static call graph needs compiler bug review",
  );
  if (done.has(id)) return;
  active.add(id);
  for (const next of edges.get(id) || []) visit(next, active, done);
  active.delete(id);
  done.add(id);
}
const done = new Set();
for (const id of functions.keys()) visit(id, new Set(), done);
console.log(
  "PASS: no named-error require calls or recursion in resolved static function graph; viaIR enabled",
);
const namespaced = compile(oz.makeNamespacedInput(input, output));
const validation = oz.validate(
  output,
  oz.solcInputOutputDecoder(input, output),
  "0.8.36",
  input,
  namespaced,
);
const version = oz.getContractVersion(validation, "src/STRN.sol:STRN");
oz.assertUpgradeSafe(validation, version, { kind: "transparent" });
const layout = oz.getStorageLayout(validation, version);
assert.ok(layout.namespaces["erc7201:saturn.storage.STRN"]);
const nextVersion = oz.getContractVersion(
  validation,
  "test/fixtures/STRNV2.sol:STRNV2",
);
oz.assertUpgradeSafe(validation, nextVersion, { kind: "transparent" });
const next = oz.getStorageLayout(validation, nextVersion);
assert.ok(next.namespaces["erc7201:saturn.storage.STRNV2"]);
oz.assertStorageUpgradeSafe(layout, next, {});
const bad = oz.getStorageLayout(
  validation,
  oz.getContractVersion(validation, "fixtures/STRNBad.sol:STRNBad"),
);
assert.throws(
  () => oz.assertStorageUpgradeSafe(layout, bad, {}),
  /storage layout is incompatible/,
);
const abi = output.contracts["src/STRN.sol"].STRN.abi;
const nextAbi = output.contracts["test/fixtures/STRNV2.sol"].STRNV2.abi;
for (const item of abi.filter((x) => x.type !== "constructor"))
  assert.ok(
    nextAbi.some((x) => JSON.stringify(x) === JSON.stringify(item)),
    `ABI removed: ${item.name}`,
  );
for (const name of ["mint", "burn", "burnFrom", "upgradeToAndCall", "permit"])
  assert.ok(!abi.some((x) => x.type === "function" && x.name === name));
// Frozen baselines are never silently overwritten. Run --write-baseline only when intentionally accepting v1.
const write = process.argv.includes("--write-baseline");
for (const [name, value] of [
  ["STRN.abi.json", abi],
  ["STRN.storage.json", layout],
]) {
  const file = "verification/baselines/" + name;
  if (write) {
    const original = JSON.parse(fs.readFileSync(file, "utf8"));
    if (name.includes("abi"))
      for (const item of original.filter((x) => x.type !== "constructor"))
        assert.ok(
          value.some((x) => JSON.stringify(x) === JSON.stringify(item)),
          `Existing ABI removed: ${item.name}`,
        );
    else oz.assertStorageUpgradeSafe(original, value, {});
    fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
  } else {
    const original = JSON.parse(fs.readFileSync(file, "utf8"));
    if (name.includes("abi"))
      assert.deepEqual(value, original, "v1 ABI changed");
    else oz.assertStorageUpgradeSafe(original, value, {});
  }
}
// Ordinary verification does not emit or overwrite evidence.
if (process.env.STRN_EVIDENCE_DIR) {
  const dir = process.env.STRN_EVIDENCE_DIR;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    path.join(dir, "upgrade-check-input.json"),
    JSON.stringify(input, null, 2) + "\n",
  );
}
console.log(
  "PASS: initializer/upgrade safety; ERC-7201 namespaces:",
  Object.keys(layout.namespaces).join(", "),
);
console.log(
  "PASS: compatible V2 storage and ABI; compiled incompatible namespace rejected; v1 baseline verified",
);
