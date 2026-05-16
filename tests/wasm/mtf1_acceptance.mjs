import fs from "node:fs";

const wasmPath = process.argv[2];

if (!wasmPath) {
  console.error("usage: node tests/wasm/mtf1_acceptance.mjs <artifact.wasm>");
  process.exit(1);
}

const bytes = fs.readFileSync(wasmPath);

if (bytes.length < 8) {
  throw new Error(`expected nonempty wasm artifact, got ${bytes.length} bytes`);
}

if (
  bytes[0] !== 0x00 ||
  bytes[1] !== 0x61 ||
  bytes[2] !== 0x73 ||
  bytes[3] !== 0x6d
) {
  throw new Error("artifact does not start with the wasm module header");
}

const module = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(module);
const exports = WebAssembly.Module.exports(module);

if (imports.length !== 0) {
  throw new Error(`expected import-free module, saw ${JSON.stringify(imports)}`);
}

const instance = new WebAssembly.Instance(module, {});
const exportNames = Object.keys(instance.exports);

if (!exportNames.includes("entrypoint")) {
  throw new Error(`expected entrypoint export, saw ${exportNames.join(", ")}`);
}

const result = instance.exports.entrypoint();

if (typeof result !== "bigint") {
  throw new Error(`expected bigint entrypoint result, got ${typeof result}`);
}

if (result !== 42n) {
  throw new Error(`expected entrypoint result 42n, got ${result}n`);
}

console.log(`imports=${JSON.stringify(imports)}`);
console.log(`exports=${exportNames.join(",")}`);
console.log(`entrypointType=${typeof result}`);
console.log(`entrypointValue=${result}`);
