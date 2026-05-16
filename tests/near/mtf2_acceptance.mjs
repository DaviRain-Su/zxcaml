import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

import { Worker } from "near-workspaces";

const require = createRequire(import.meta.url);
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../..");
const expectedImports =
  "env.input:(i64)->(),env.register_len:(i64)->(i64),env.read_register:(i64,i64)->(),env.log_utf8:(i64,i64)->(),env.value_return:(i64,i64)->(),env.panic_utf8:(i64,i64)->()";
const expectedExports = "memory:memory,entrypoint:()->()";

function packageJsonPathFor(moduleSpecifier) {
  const entryPath = require.resolve(moduleSpecifier);
  let currentPath = path.dirname(entryPath);
  while (true) {
    const candidate = path.join(currentPath, "package.json");
    try {
      require(candidate);
      return candidate;
    } catch (error) {
      if (error?.code !== "MODULE_NOT_FOUND") {
        throw error;
      }
    }
    const parent = path.dirname(currentPath);
    if (parent === currentPath) {
      throw new Error(`could not locate package.json for ${moduleSpecifier}`);
    }
    currentPath = parent;
  }
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    ...options,
  });
  return {
    ...result,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function assertSuccess(result, label) {
  if (result.status !== 0) {
    throw new Error(
      `${label} failed with exit ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
}

function assertFailure(result, label) {
  if (result.status === 0) {
    throw new Error(
      `${label} unexpectedly succeeded\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
}

function decodeReturnedStatus(txResult) {
  assert.equal(txResult.failed, false, "expected NEAR call to succeed");
  assert.ok(txResult.SuccessValue, "expected base64 success value");
  const bytes = Buffer.from(txResult.SuccessValue, "base64");
  assert.equal(bytes.length, 8, "expected little-endian u64 payload");
  return Number(bytes.readBigUInt64LE(0));
}

function failureText(txResult) {
  return [
    txResult.Failure ? JSON.stringify(txResult.Failure) : "",
    ...txResult.receiptFailureMessages,
    ...txResult.logs,
  ]
    .filter(Boolean)
    .join("\n");
}

function inspectWasm(wasmPath) {
  const inspect = run("node", ["tests/near/inspect_near_wasm.mjs", wasmPath]);
  assertSuccess(inspect, `inspect ${wasmPath}`);

  const importsLine = inspect.stdout
    .split("\n")
    .find((line) => line.startsWith("imports="));
  const exportsLine = inspect.stdout
    .split("\n")
    .find((line) => line.startsWith("exports="));

  assert.ok(importsLine, "expected imports= line");
  assert.ok(exportsLine, "expected exports= line");
  return {
    imports: importsLine.slice("imports=".length).trim(),
    exports: exportsLine.slice("exports=".length).trim(),
    stdout: inspect.stdout,
  };
}

function expectDiagnostic(result, expectedParts, outputPath, label) {
  assertFailure(result, label);
  const combined = `${result.stdout}\n${result.stderr}`;
  for (const part of expectedParts) {
    assert.match(combined, part, `${label} should mention ${part}`);
  }
}

async function verifyPinnedLocalDependencies() {
  const nearWorkspacesPkgPath = packageJsonPathFor("near-workspaces");
  const nearSandboxPkgPath = packageJsonPathFor("near-sandbox");
  assert.match(
    nearWorkspacesPkgPath,
    /tests\/near\/node_modules\/near-workspaces\/package\.json$/,
  );
  assert.match(
    nearSandboxPkgPath,
    /tests\/near\/node_modules\/near-sandbox\/package\.json$/,
  );

  const nearWorkspacesPkg = JSON.parse(
    await fs.readFile(nearWorkspacesPkgPath, "utf8"),
  );
  const nearSandboxPkg = JSON.parse(await fs.readFile(nearSandboxPkgPath, "utf8"));

  assert.equal(nearWorkspacesPkg.version, "5.0.0");
  assert.equal(nearSandboxPkg.version, "0.3.0");

  console.log(`near-workspaces=${nearWorkspacesPkgPath}`);
  console.log(`near-sandbox=${nearSandboxPkgPath}`);
}

async function buildNearFixture(sourcePath, outputPath, extraArgs = []) {
  await fs.rm(outputPath, { force: true });
  return run("zig-out/bin/omlz", [
    "build",
    "--target=near",
    ...extraArgs,
    sourcePath,
    "-o",
    outputPath,
  ]);
}

async function main() {
  await verifyPinnedLocalDependencies();

  const tempRoot = await fs.mkdtemp(path.join(tmpdir(), "zxcaml-near-"));
  let worker = null;

  try {
    const validArtifact = path.join(tempRoot, "mtf2_near_ok.wasm");
    const validBuild = await buildNearFixture(
      "examples/mtf2_near_no_storage.ml",
      validArtifact,
    );
    assertSuccess(validBuild, "build valid near fixture");

    const inspected = inspectWasm(validArtifact);
    assert.equal(inspected.imports, expectedImports);
    assert.equal(inspected.exports, expectedExports);
    console.log(inspected.stdout.trim());

    worker = await Worker.init();
    const rpcAddr = worker.provider.connection.url;
    assert.match(rpcAddr, /^http:\/\/127\.0\.0\.1:\d+$/);
    console.log(`sandboxRpc=${rpcAddr}`);

    const contract = await worker.rootAccount.devDeploy(validArtifact);
    const beforeState = await contract.viewStateRaw();
    assert.deepEqual(beforeState, []);

    const successTx = await worker.rootAccount.callRaw(
      contract,
      "entrypoint",
      Uint8Array.from([65]),
    );
    assert.equal(successTx.failed, false, "expected successful NEAR call");
    assert.equal(decodeReturnedStatus(successTx), 65);
    assert.deepEqual(successTx.logs, ["omlz near entrypoint"]);
    assert.ok(successTx.transactionReceipt.hash.length > 0);

    const afterState = await contract.viewStateRaw();
    assert.deepEqual(afterState, beforeState);

    const malformedTx = await worker.rootAccount.callRaw(
      contract,
      "entrypoint",
      new Uint8Array(),
    );
    assert.equal(malformedTx.failed, true, "expected malformed input failure");
    assert.match(failureText(malformedTx), /near input payload must not be empty/);

    const panicArtifact = path.join(tempRoot, "mtf2_near_panic.wasm");
    const panicBuild = await buildNearFixture(
      "tests/fixtures/near_assert_false.ml",
      panicArtifact,
    );
    assertSuccess(panicBuild, "build panic near fixture");
    const panicContract = await worker.rootAccount.devDeploy(panicArtifact);
    const panicTx = await worker.rootAccount.callRaw(
      panicContract,
      "entrypoint",
      Uint8Array.from([7]),
    );
    assert.equal(panicTx.failed, true, "expected panic fixture failure");
    assert.match(failureText(panicTx), /wasm|trap|panic|assert/i);

    const negativeCases = [
      {
        sourcePath: "examples/log_accounts.ml",
        outputPath: path.join(tempRoot, "near_reject_log_accounts.wasm"),
        expectedParts: [
          /target `near`/,
          /Solana account API/,
          /account-shaped accounts parameter/,
        ],
      },
      {
        sourcePath: "examples/syscall_test.ml",
        outputPath: path.join(tempRoot, "near_reject_syscall.wasm"),
        expectedParts: [/target `near`/, /Solana host API/, /Syscall\.sol_sha256/],
      },
      {
        sourcePath: "tests/fixtures/near_storage_write.ml",
        outputPath: path.join(tempRoot, "near_reject_storage.wasm"),
        expectedParts: [/target `near`/, /NEAR storage API/, /near\.storage_write/],
      },
      {
        sourcePath: "tests/fixtures/near_predecessor_account_id.ml",
        outputPath: path.join(tempRoot, "near_reject_caller.wasm"),
        expectedParts: [
          /target `near`/,
          /NEAR caller identity API/,
          /near\.predecessor_account_id/,
        ],
      },
      {
        sourcePath: "tests/fixtures/near_promise_create.ml",
        outputPath: path.join(tempRoot, "near_reject_promise.wasm"),
        expectedParts: [/target `near`/, /NEAR promise API/, /near\.promise_create/],
      },
    ];

    for (const testCase of negativeCases) {
      const result = await buildNearFixture(testCase.sourcePath, testCase.outputPath);
      expectDiagnostic(
        result,
        testCase.expectedParts,
        testCase.outputPath,
        `build ${testCase.sourcePath}`,
      );
      await assert.rejects(fs.access(testCase.outputPath));
    }

    console.log("near acceptance passed");
  } finally {
    if (worker) {
      await worker.tearDown();
    }
    await fs.rm(tempRoot, { force: true, recursive: true });
  }
}

await main();
