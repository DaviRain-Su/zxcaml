import { readFile } from "node:fs/promises";

const [wasmPath] = process.argv.slice(2);

if (!wasmPath) {
  console.error("usage: node tests/near/inspect_near_wasm.mjs <module.wasm>");
  process.exit(1);
}

const bytes = new Uint8Array(await readFile(wasmPath));

if (bytes.length < 8 || bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
  throw new Error(`invalid wasm header for ${wasmPath}`);
}

let offset = 8;
const types = [];
const importedFunctions = [];
const definedFunctionTypeIndices = [];
const exportsList = [];

function readVarUint() {
  let result = 0;
  let shift = 0;
  while (true) {
    const byte = bytes[offset++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return result >>> 0;
    shift += 7;
  }
}

function readString() {
  const length = readVarUint();
  const start = offset;
  offset += length;
  return new TextDecoder().decode(bytes.subarray(start, start + length));
}

function readSectionBytes() {
  const length = readVarUint();
  const start = offset;
  offset += length;
  return bytes.subarray(start, start + length);
}

function valueTypeLabel(byte) {
  switch (byte) {
    case 0x7f:
      return "i32";
    case 0x7e:
      return "i64";
    case 0x7d:
      return "f32";
    case 0x7c:
      return "f64";
    default:
      return `0x${byte.toString(16)}`;
  }
}

while (offset < bytes.length) {
  const sectionId = bytes[offset++];
  const sectionBytes = readSectionBytes();
  let sectionOffset = 0;

  const readSectionVarUint = () => {
    let result = 0;
    let shift = 0;
    while (true) {
      const byte = sectionBytes[sectionOffset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return result >>> 0;
      shift += 7;
    }
  };

  const readSectionString = () => {
    const length = readSectionVarUint();
    const start = sectionOffset;
    sectionOffset += length;
    return new TextDecoder().decode(sectionBytes.subarray(start, start + length));
  };

  if (sectionId === 1) {
    const typeCount = readSectionVarUint();
    for (let index = 0; index < typeCount; index += 1) {
      const form = sectionBytes[sectionOffset++];
      if (form !== 0x60) throw new Error(`unsupported type form 0x${form.toString(16)}`);
      const paramCount = readSectionVarUint();
      const params = [];
      for (let paramIndex = 0; paramIndex < paramCount; paramIndex += 1) {
        params.push(valueTypeLabel(sectionBytes[sectionOffset++]));
      }
      const resultCount = readSectionVarUint();
      const results = [];
      for (let resultIndex = 0; resultIndex < resultCount; resultIndex += 1) {
        results.push(valueTypeLabel(sectionBytes[sectionOffset++]));
      }
      types.push({ params, results });
    }
  } else if (sectionId === 2) {
    const importCount = readSectionVarUint();
    for (let index = 0; index < importCount; index += 1) {
      const module = readSectionString();
      const name = readSectionString();
      const kind = sectionBytes[sectionOffset++];
      if (kind === 0x00) {
        const typeIndex = readSectionVarUint();
        importedFunctions.push({ module, name, typeIndex });
      } else if (kind === 0x01) {
        sectionOffset += 1;
        readSectionVarUint();
        readSectionVarUint();
      } else if (kind === 0x02) {
        const flags = readSectionVarUint();
        readSectionVarUint();
        if (flags & 0x01) readSectionVarUint();
      } else if (kind === 0x03) {
        const flags = readSectionVarUint();
        readSectionVarUint();
        if (flags & 0x01) readSectionVarUint();
      } else {
        throw new Error(`unsupported import kind ${kind}`);
      }
    }
  } else if (sectionId === 3) {
    const functionCount = readSectionVarUint();
    for (let index = 0; index < functionCount; index += 1) {
      definedFunctionTypeIndices.push(readSectionVarUint());
    }
  } else if (sectionId === 7) {
    const exportCount = readSectionVarUint();
    for (let index = 0; index < exportCount; index += 1) {
      const name = readSectionString();
      const kind = sectionBytes[sectionOffset++];
      const itemIndex = readSectionVarUint();
      exportsList.push({ name, kind, itemIndex });
    }
  }
}

const formatSignature = (typeIndex) => {
  const signature = types[typeIndex];
  const params = signature.params.join(",");
  const results = signature.results.join(",");
  return `(${params})->(${results})`;
};

const renderedImports = importedFunctions
  .map((entry) => `${entry.module}.${entry.name}:${formatSignature(entry.typeIndex)}`)
  .join(",");

const renderedExports = exportsList
  .map((entry) => {
    if (entry.kind === 0x02) return `${entry.name}:memory`;
    if (entry.kind !== 0x00) return `${entry.name}:kind${entry.kind}`;
    const typeIndex =
      entry.itemIndex < importedFunctions.length
        ? importedFunctions[entry.itemIndex].typeIndex
        : definedFunctionTypeIndices[entry.itemIndex - importedFunctions.length];
    return `${entry.name}:${formatSignature(typeIndex)}`;
  })
  .join(",");

console.log(`imports=${renderedImports}`);
console.log(`exports=${renderedExports}`);
