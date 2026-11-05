// Independent staking compatibility check; never rewrites the accepted STRN baselines.
const fs = require("fs"),
  cp = require("child_process"),
  path = require("path"),
  assert = require("assert/strict");
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
    for (const [a, b] of Object.entries(remaps))
      if (name.startsWith(a)) name = b + name.slice(a.length);
    if (name.startsWith("."))
      name = path.posix.normalize(
        path.posix.join(path.posix.dirname(file), name),
      );
    add(name);
  }
}
add("src/StakedSTRN.sol");
add("src/interfaces/IStakedSTRN.sol");
add("test/fixtures/StakedSTRNV2.sol");
sources["src/StakedSTRNBad.sol"] = {
  content: sources["src/StakedSTRN.sol"].content
    .replace("contract StakedSTRN is", "contract StakedSTRNBad is")
    .replace(
      "STRN token;",
      "uint256 insertedBeforeToken;\n        STRN token;",
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
      encoding: "utf8",
      maxBuffer: 128 * 1024 * 1024,
    }),
  );
  assert.deepEqual(
    (o.errors || []).filter((e) => e.severity === "error"),
    [],
  );
  return o;
}
const output = compile(input),
  namespaced = compile(oz.makeNamespacedInput(input, output));
const validation = oz.validate(
  output,
  oz.solcInputOutputDecoder(input, output),
  "0.8.36",
  input,
  namespaced,
);
function layout(name) {
  const version = oz.getContractVersion(validation, name);
  oz.assertUpgradeSafe(validation, version, { kind: "transparent" });
  return oz.getStorageLayout(validation, version);
}
const current = layout("src/StakedSTRN.sol:StakedSTRN");
assert.ok(current.namespaces["erc7201:saturn.storage.StakedSTRN"]);
oz.assertStorageUpgradeSafe(
  current,
  layout("test/fixtures/StakedSTRNV2.sol:StakedSTRNV2"),
  {},
);
const bad = oz.getStorageLayout(
  validation,
  oz.getContractVersion(validation, "src/StakedSTRNBad.sol:StakedSTRNBad"),
);
assert.throws(
  () => oz.assertStorageUpgradeSafe(current, bad, {}),
  /storage layout is incompatible/,
);
const abi = output.contracts["src/StakedSTRN.sol"].StakedSTRN.abi;
// Solidity nominal types/names may differ; external ABI types, mutability and event indexing must match.
function wireType(p) {
  return p.type.startsWith("tuple")
    ? "(" + p.components.map(wireType).join(",") + ")" + p.type.slice(5)
    : p.type;
}
function signature(x) {
  return (
    x.type + ":" + x.name + "(" + (x.inputs || []).map(wireType).join(",") + ")"
  );
}
function wireABI(x) {
  return {
    signature: signature(x),
    outputs: (x.outputs || []).map(wireType),
    mutability: x.stateMutability,
    indexed: (x.inputs || []).map((p) => p.indexed),
    anonymous: x.anonymous,
  };
}
const consumer =
  output.contracts["src/interfaces/IStakedSTRN.sol"].IStakedSTRN.abi;
for (const item of consumer) {
  const implementation = abi.find((x) => signature(x) === signature(item));
  assert.ok(implementation, "Missing consumer ABI: " + signature(item));
  const actual = wireABI(implementation);
  const effects = { pure: 0, view: 1, nonpayable: 2 };
  if (
    effects[actual.mutability] !== undefined &&
    effects[item.stateMutability] !== undefined &&
    effects[actual.mutability] <= effects[item.stateMutability]
  )
    actual.mutability = item.stateMutability;
  assert.deepEqual(
    wireABI(item),
    actual,
    "Consumer ABI mismatch: " + signature(item),
  );
}
console.log(
  "PASS: IStakedSTRN consumer functions, return tuples and events match implementation ABI",
);
const next =
  output.contracts["test/fixtures/StakedSTRNV2.sol"].StakedSTRNV2.abi;
for (const item of abi.filter((x) => x.type !== "constructor"))
  assert.ok(next.some((x) => JSON.stringify(x) === JSON.stringify(item)));
const write = process.argv.includes("--write-baseline");
for (const [name, value] of [
  ["StakedSTRN.abi.json", abi],
  ["StakedSTRN.storage.json", current],
]) {
  const file = "verification/baselines/" + name;
  if (fs.existsSync(file)) {
    const original = JSON.parse(fs.readFileSync(file, "utf8"));
    if (name.includes("abi")) {
      if (write) {
        for (const item of original.filter((x) => x.type !== "constructor"))
          assert.ok(
            value.some((x) => JSON.stringify(x) === JSON.stringify(item)),
          );
      } else assert.deepEqual(value, original, "sSTRN ABI changed");
    } else oz.assertStorageUpgradeSafe(original, value, {});
  } else assert.ok(write, "Missing sSTRN baseline; initialize it explicitly");
  if (write) fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
}
if (process.env.STRN_EVIDENCE_DIR) {
  fs.mkdirSync(process.env.STRN_EVIDENCE_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(
      process.env.STRN_EVIDENCE_DIR,
      "staking-upgrade-check-input.json",
    ),
    JSON.stringify(input, null, 2) + "\n",
  );
}
console.log(
  "PASS: sSTRN initializer/upgrade safety, ERC-7201 compatibility and ABI; incompatible compiled fixture rejected",
);
