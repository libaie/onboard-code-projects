import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { access, copyFile, mkdtemp, mkdir, open, readFile, realpath, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  ackReceipt,
  bindWakeAutomation,
  bindWakeWorker,
  captureStop,
  claimPending,
  clearWakeWorker,
  commitControllerReplacement,
  completeTaskSetResetFence,
  prepareWakeAutomation,
  prepareControllerReplacement,
  prepareTaskSetResetFence,
  prepareWakeWorker,
  readControllerReplacement,
  readDispatch,
  readPending,
  readWakeWorker,
  recordWakeWorkerClientThread,
  registerController,
  registerDispatch,
  renewClaim,
  replaceController,
  terminalEnvelope,
  unregisterDispatch,
  verifyDispatch,
} from "./dispatch-return-runtime.mjs";

const HASH_A = "a".repeat(64);
const HASH_B = "b".repeat(64);
const HASH_C = "c".repeat(64);
const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

function runtimeLock(token, pid, timestamp) {
  return {
    schemaVersion: 1,
    token,
    pid,
    createdAt: timestamp,
    heartbeatAt: timestamp,
  };
}

function sealDispatch(identity, taskSpec = { objective: "Run the exact task", dispatchIdentity: identity }) {
  const taskSpecHash = sha256(JSON.stringify(taskSpec));
  const core = {
    schemaVersion: 1,
    kind: "onboard-code-projects.dispatch",
    ...identity,
    taskSpecHash,
    taskSpec,
  };
  return { ...core, dispatchHash: sha256(JSON.stringify(core)) };
}

function receiptIdentity(envelope, evidenceHash, turnId) {
  return sha256([
    "dispatch-return-receipt-v2",
    envelope.chainId,
    envelope.projectTaskId,
    envelope.dispatchId,
    String(envelope.generation),
    String(envelope.rework),
    envelope.taskSpecHash,
    envelope.resultState,
    envelope.failureClass,
    evidenceHash,
    turnId,
  ].join("\0"));
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "onboard-return-"));
  const controllerRoot = join(root, "controller");
  const projectRoot = join(root, "project");
  const statePath = join(root, "runtime.json");
  await mkdir(controllerRoot);
  await mkdir(projectRoot);
  const identity = {
    chainId: "CHAIN-20260808-001",
    projectTaskId: "019f-project-task",
    dispatchId: "dispatch-a1",
    generation: 1,
    rework: 0,
  };
  const envelope = sealDispatch(identity);
  const dispatch = {
    controllerRoot,
    ...identity,
    taskSpecHash: envelope.taskSpecHash,
    dispatchHash: envelope.dispatchHash,
    projectRoot,
  };
  await registerController({
    statePath,
    controllerRoot,
    controllerThreadId: "019f-controller-task",
    hostId: "local",
  });
  await registerDispatch({ statePath, ...dispatch });
  return { root, statePath, controllerRoot, projectRoot, dispatch, envelope };
}

function replacementInput(f, overrides = {}) {
  return {
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    operationId: "replace-controller-1",
    replacementSetHash: HASH_A,
    oldControllerThreadId: "019f-controller-task",
    oldHostId: "local",
    newControllerThreadId: "019f-controller-task-new",
    newHostId: "local-new",
    manifestPreparedHash: HASH_B,
    preparedAt: "2026-08-13T01:00:00.000Z",
    ...overrides,
  };
}

function resetFenceInput(f, overrides = {}) {
  return {
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    operationId: "replace-controller-1",
    planHash: HASH_A,
    manifestExpectedHash: HASH_B,
    preparedAt: "2026-08-13T00:30:00.000Z",
    ...overrides,
  };
}

async function installTaskSetResetSeal(f, overrides = {}) {
  const manifestBytes = Buffer.from(overrides.manifestText ?? '{"schemaVersion":3,"generator":"reset-test"}\n', "utf8");
  const finalManifestHash = sha256(manifestBytes);
  const marker = {
    schemaVersion: 1,
    kind: "task-set-reset-seal",
    operationId: "replace-controller-1",
    completedAt: "2026-08-13T01:01:30.000Z",
    sourceManifestHash: HASH_A,
    candidateHash: HASH_B,
    sourceHistoryHash: HASH_C,
    targetHistoryHash: HASH_A,
    historyEntryHash: HASH_B,
    finalManifestHash,
    ...overrides.marker,
  };
  const sealPath = join(f.controllerRoot, "state", ".task-set-reset-seal.json");
  await mkdir(dirname(sealPath), { recursive: true });
  await writeFile(join(f.controllerRoot, ".codex-controller.json"), manifestBytes);
  await writeFile(sealPath, `${JSON.stringify(marker)}\n`);
  return { finalManifestHash, manifestBytes, marker, sealPath };
}

async function prepareCoordinatedReplacement(replacement) {
  await prepareTaskSetResetFence({
    statePath: replacement.statePath,
    controllerRoot: replacement.controllerRoot,
    operationId: replacement.operationId,
    planHash: replacement.replacementSetHash,
    manifestExpectedHash: replacement.manifestPreparedHash,
    preparedAt: new Date(Date.parse(replacement.preparedAt) - 60_000).toISOString(),
  });
  return prepareControllerReplacement(replacement);
}

async function unregisterFixtureDispatch(f) {
  await unregisterDispatch({
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    projectTaskId: f.dispatch.projectTaskId,
    dispatchId: f.dispatch.dispatchId,
    taskSpecHash: f.dispatch.taskSpecHash,
  });
}

async function installWakeWorker(f) {
  await prepareWakeWorker({
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    operationId: "wake-worker-op-reset",
    codexProjectId: "controller-project-id",
    hostId: "local",
    projectRoot: f.controllerRoot,
    startedAt: "2026-08-13T00:00:00.000Z",
  });
  await recordWakeWorkerClientThread({
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    operationId: "wake-worker-op-reset",
    clientThreadId: "receipt-worker-client",
  });
  await bindWakeWorker({
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    operationId: "wake-worker-op-reset",
    workerThreadId: "receipt-worker-task",
    codexProjectId: "controller-project-id",
    hostId: "local",
    projectRoot: f.controllerRoot,
  });
  await prepareWakeAutomation({
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    workerThreadId: "receipt-worker-task",
    operationId: "wake-automation-op-reset",
    startedAt: "2026-08-13T00:01:00.000Z",
  });
  await bindWakeAutomation({
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    workerThreadId: "receipt-worker-task",
    operationId: "wake-automation-op-reset",
    automationId: "receipt-wake-reset",
  });
}

function runCli(action, statePath, payload) {
  return spawnSync(process.execPath, [
    fileURLToPath(new URL("./dispatch-return-runtime.mjs", import.meta.url)),
    action,
    "--state-path",
    statePath,
    "--payload-base64",
    Buffer.from(JSON.stringify(payload), "utf8").toString("base64"),
  ], { encoding: "utf8" });
}

function terminalInput(dispatch, overrides = {}) {
  const envelope = {
    chainId: dispatch.chainId,
    dispatchId: dispatch.dispatchId,
    projectTaskId: dispatch.projectTaskId,
    generation: dispatch.generation,
    rework: dispatch.rework,
    taskSpecHash: dispatch.taskSpecHash,
    resultState: "completed",
    failureClass: "N/A",
    ...overrides.envelope,
  };
  return {
    session_id: dispatch.projectTaskId,
    turn_id: "turn-1",
    cwd: dispatch.projectRoot,
    last_assistant_message: `${JSON.stringify(envelope)}\nEvidence follows.`,
    ...overrides.input,
  };
}

test("terminal envelope generator returns only the validated closed packet", () => {
  const envelope = {
    chainId: "CHAIN-terminal",
    dispatchId: "dispatch-terminal",
    projectTaskId: "project-task-terminal",
    generation: 1,
    rework: 0,
    taskSpecHash: HASH_A,
    resultState: "completed",
    failureClass: "N/A",
  };
  assert.deepEqual(terminalEnvelope(envelope), envelope);
  assert.throws(() => terminalEnvelope({ ...envelope, unknown: true }), /invalid-envelope/);
  assert.throws(() => terminalEnvelope({ ...envelope, resultState: "blocked" }), /invalid-envelope/);
});

test("CLI executes through a directory alias instead of silently returning", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-alias-"));
  const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
  const aliasRoot = join(root, "skill-alias");
  const envelope = {
    chainId: "CHAIN-alias",
    dispatchId: "dispatch-alias",
    projectTaskId: "project-task-alias",
    generation: 1,
    rework: 0,
    taskSpecHash: HASH_A,
    resultState: "completed",
    failureClass: "N/A",
  };
  try {
    await symlink(packageRoot, aliasRoot, process.platform === "win32" ? "junction" : "dir");
    const payload = Buffer.from(JSON.stringify(envelope), "utf8").toString("base64");
    const run = spawnSync(process.execPath, [
      join(aliasRoot, "scripts", "dispatch-return-runtime.mjs"),
      "terminal-envelope",
      "--payload-base64",
      payload,
    ], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(JSON.parse(run.stdout), envelope);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("CLI rejects payload statePath overrides before any registry access", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-state-override-"));
  const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
  const statePath = join(root, "runtime.json");
  const attackerPath = join(root, "attacker.json");
  try {
    const payload = Buffer.from(JSON.stringify({ statePath: attackerPath }), "utf8").toString("base64");
    const run = spawnSync(process.execPath, [
      join(packageRoot, "scripts", "dispatch-return-runtime.mjs"),
      "verify",
      "--state-path",
      statePath,
      "--payload-base64",
      payload,
    ], { encoding: "utf8" });
    assert.equal(run.status, 1);
    assert.equal(JSON.parse(run.stderr).reasonCode, "payload-state-path-forbidden");
    await assert.rejects(access(attackerPath), /ENOENT/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("worker-safe CLI actions reject arbitrary state paths", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-worker-state-"));
  const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
  const controllerRoot = join(root, "controller");
  const attackerPath = join(root, "attacker.json");
  try {
    await mkdir(controllerRoot);
    const payload = Buffer.from(JSON.stringify({ controllerRoot }), "utf8").toString("base64");
    for (const action of ["read", "claim", "renew-claim"]) {
      const run = spawnSync(process.execPath, [
        join(packageRoot, "scripts", "dispatch-return-runtime.mjs"),
        action,
        "--state-path",
        attackerPath,
        "--payload-base64",
        payload,
      ], { encoding: "utf8" });
      assert.equal(run.status, 1);
      assert.equal(JSON.parse(run.stderr).reasonCode, "worker-state-path-forbidden");
    }
    await assert.rejects(access(attackerPath), /ENOENT/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("sealed dispatch verification binds both hashes, registry identity, and physical project root", async () => {
  const f = await fixture();
  const otherRoot = join(f.root, "other-project");
  try {
    await mkdir(otherRoot);
    const physicalProjectRoot = await realpath(f.projectRoot);
    const verified = await verifyDispatch({
      statePath: f.statePath,
      projectRoot: physicalProjectRoot,
      dispatchJson: JSON.stringify(f.envelope),
    });
    const readback = await readDispatch({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      projectTaskId: f.dispatch.projectTaskId,
    });
    assert.equal(readback.state, "dispatch-read");
    assert.deepEqual(readback.dispatch, {
      chainId: f.dispatch.chainId,
      projectTaskId: f.dispatch.projectTaskId,
      dispatchId: f.dispatch.dispatchId,
      generation: f.dispatch.generation,
      rework: f.dispatch.rework,
      taskSpecHash: f.dispatch.taskSpecHash,
      dispatchHash: f.dispatch.dispatchHash,
      projectRoot: physicalProjectRoot,
    });
    assert.deepEqual(verified, {
      state: "dispatch-verified",
      chainId: f.dispatch.chainId,
      projectTaskId: f.dispatch.projectTaskId,
      dispatchId: f.dispatch.dispatchId,
      taskSpecHash: f.dispatch.taskSpecHash,
      dispatchHash: f.dispatch.dispatchHash,
      projectRoot: physicalProjectRoot,
    });

    const changedTask = { ...f.envelope, taskSpec: { ...f.envelope.taskSpec, objective: "Changed" } };
    await assert.rejects(
      verifyDispatch({ statePath: f.statePath, projectRoot: f.projectRoot, dispatchJson: JSON.stringify(changedTask) }),
      /task-spec-hash-mismatch/,
    );
    await assert.rejects(
      verifyDispatch({
        statePath: f.statePath,
        projectRoot: f.projectRoot,
        dispatchJson: JSON.stringify({ ...f.envelope, dispatchHash: HASH_A }),
      }),
      /dispatch-hash-mismatch/,
    );
    const differentlySealed = sealDispatch({
      chainId: f.dispatch.chainId,
      projectTaskId: f.dispatch.projectTaskId,
      dispatchId: f.dispatch.dispatchId,
      generation: f.dispatch.generation,
      rework: f.dispatch.rework,
    }, {
      objective: "A different but internally valid task",
      dispatchIdentity: f.envelope.taskSpec.dispatchIdentity,
    });
    await assert.rejects(
      verifyDispatch({
        statePath: f.statePath,
        projectRoot: f.projectRoot,
        dispatchJson: JSON.stringify(differentlySealed),
      }),
      /dispatch-registry-mismatch/,
    );
    await assert.rejects(
      verifyDispatch({ statePath: f.statePath, projectRoot: otherRoot, dispatchJson: JSON.stringify(f.envelope) }),
      /dispatch-project-root-mismatch/,
    );
    await assert.rejects(
      verifyDispatch({
        statePath: f.statePath,
        projectRoot: f.projectRoot,
        dispatchJson: JSON.stringify({ ...f.envelope, extra: true }),
      }),
      /invalid-dispatch-envelope/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("matching Stop return is durable, idempotent, claimed once, and acknowledged", async () => {
  const f = await fixture();
  try {
    const input = terminalInput(f.dispatch);
    const first = await captureStop({ statePath: f.statePath, input, now: "2026-08-08T10:00:00.000Z" });
    const replay = await captureStop({ statePath: f.statePath, input, now: "2026-08-08T10:00:01.000Z" });
    assert.equal(first.state, "receipt-recorded");
    assert.equal(replay.state, "receipt-exists");

    const pending = await readPending({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(pending.receipts.length, 1);
    assert.equal(pending.activeDispatchCount, 1);
    assert.equal(pending.receipts[0].envelope.resultState, "completed");
    assert.match(pending.receipts[0].evidenceHash, /^[0-9a-f]{64}$/);
    assert.equal("lastAssistantMessage" in pending.receipts[0], false);

    const claim = await claimPending({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      now: "2026-08-08T10:00:02.000Z",
      retryAfterMs: 600_000,
    });
    const duplicateClaim = await claimPending({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      now: "2026-08-08T10:00:03.000Z",
      retryAfterMs: 600_000,
    });
    assert.equal(claim.receipts.length, 1);
    assert.equal(duplicateClaim.receipts.length, 0);

    await ackReceipt({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      receiptId: first.receiptId,
      acknowledgedAt: "2026-08-08T10:00:04.000Z",
    });
    const afterAck = await readPending({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(afterAck.receipts.length, 0);
    assert.equal(afterAck.activeDispatchCount, 0);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a live claim can be renewed and an abandoned claim is redelivered after its bounded lease", async () => {
  const f = await fixture();
  try {
    await captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch), now: "2026-08-08T10:00:00.000Z" });
    const first = await claimPending({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      claimOwnerId: "worker-one",
      now: "2026-08-08T10:00:01.000Z",
      retryAfterMs: 600_000,
    });
    assert.equal(first.receipts.length, 1);
    const receiptId = first.receipts[0].receiptId;
    assert.equal((await renewClaim({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      receiptId,
      claimOwnerId: "worker-one",
      now: "2026-08-08T10:09:00.000Z",
      leaseMs: 600_000,
    })).state, "receipt-claim-renewed");
    await assert.rejects(
      renewClaim({
        statePath: f.statePath,
        controllerRoot: f.controllerRoot,
        receiptId,
        claimOwnerId: "worker-two",
        now: "2026-08-08T10:09:01.000Z",
        leaseMs: 600_000,
      }),
      /receipt-claim-conflict/,
    );
    assert.equal((await claimPending({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      claimOwnerId: "worker-two",
      now: "2026-08-08T10:11:00.000Z",
      retryAfterMs: 600_000,
    })).receipts.length, 0);
    assert.equal((await claimPending({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      claimOwnerId: "worker-two",
      now: "2026-08-08T10:20:00.000Z",
      retryAfterMs: 600_000,
    })).receipts.length, 1);
    const claimRecord = JSON.parse(await readFile(join(
      f.controllerRoot, "state", "dispatch-receipts", "claim", `${receiptId}.json`,
    ), "utf8"));
    assert.deepEqual(Object.keys(claimRecord).sort(), [
      "claimOwnerId", "claimedAt", "leaseUntil", "receiptId", "schemaVersion",
    ].sort());
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a reconciled same-identity turn receives a new durable receipt", async () => {
  const f = await fixture();
  try {
    const first = await captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch) });
    await ackReceipt({ statePath: f.statePath, controllerRoot: f.controllerRoot, receiptId: first.receiptId });
    await registerDispatch({ statePath: f.statePath, ...f.dispatch });
    const second = await captureStop({
      statePath: f.statePath,
      input: terminalInput(f.dispatch, { input: { turn_id: "turn-2" } }),
    });
    assert.equal(second.state, "receipt-recorded");
    assert.notEqual(second.receiptId, first.receiptId);
    const pending = await readPending({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(pending.receipts.length, 1);
    assert.equal(pending.receipts[0].turnId, "turn-2");
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("unknown, malformed, stale, non-terminal, and open envelopes are ignored", async () => {
  const f = await fixture();
  try {
    const cases = [
      terminalInput(f.dispatch, { input: { session_id: "unknown-task" } }),
      terminalInput(f.dispatch, { input: { last_assistant_message: "not-json" } }),
      terminalInput(f.dispatch, { envelope: { generation: 2 } }),
      terminalInput(f.dispatch, { envelope: { resultState: "runtime-approval-required" } }),
      terminalInput(f.dispatch, { envelope: { resultState: "blocked" } }),
      terminalInput(f.dispatch, { envelope: { extra: true } }),
      terminalInput(f.dispatch, { input: { cwd: join(f.projectRoot, "other") } }),
    ];
    for (const input of cases) {
      assert.equal((await captureStop({ statePath: f.statePath, input })).state, "ignored");
    }
    assert.equal((await readPending({ statePath: f.statePath, controllerRoot: f.controllerRoot })).receipts.length, 0);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a project cannot replace an unacknowledged active dispatch", async () => {
  const f = await fixture();
  try {
    await assert.rejects(
      registerDispatch({ statePath: f.statePath, ...f.dispatch, dispatchId: "c".repeat(64), generation: 2 }),
      /active-dispatch-conflict/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("uncoordinated controller replacement is explicitly disabled", async () => {
  const f = await fixture();
  try {
    await assert.rejects(
      replaceController({ statePath: f.statePath }),
      /controller-replacement-uncoordinated-disabled/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("task-set reset fence is durably prepared through the closed CLI before replacement", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    const { statePath: _statePath, ...request } = resetFenceInput(f);
    const prepared = runCli("prepare-task-set-reset-fence", f.statePath, request);
    assert.equal(prepared.status, 0, prepared.stderr);
    assert.deepEqual(JSON.parse(prepared.stdout), {
      state: "task-set-reset-fence-prepared",
      controllerRoot: await realpath(f.controllerRoot),
      preparedAt: request.preparedAt,
    });

    const read = runCli("read-controller-replacement", f.statePath, { controllerRoot: f.controllerRoot });
    assert.equal(read.status, 0, read.stderr);
    assert.deepEqual(Object.keys(JSON.parse(read.stdout)).sort(), [
      "activeDispatchCount",
      "committedAt",
      "controllerRoot",
      "controllerThreadId",
      "fenceCompletedAt",
      "fenceCompletedManifestHash",
      "fenceManifestExpectedHash",
      "fenceOperationId",
      "fencePlanHash",
      "fencePreparedAt",
      "fenceState",
      "hostId",
      "manifestPreparedHash",
      "manifestSwitchedHash",
      "newControllerThreadId",
      "newHostId",
      "oldControllerThreadId",
      "oldHostId",
      "operationId",
      "prepareToken",
      "preparedAt",
      "replacementSetHash",
      "replacementState",
      "state",
      "unacknowledgedReceiptCount",
      "wakeAutomationId",
      "wakeAutomationOperationId",
      "wakeAutomationState",
      "wakeWorkerClientThreadId",
      "wakeWorkerOperationId",
      "wakeWorkerState",
      "wakeWorkerThreadId",
    ].sort());
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("runtime UTC timestamps reject calendar rollover while retaining the controller format", async () => {
  const f = await fixture();
  try {
    for (const preparedAt of ["2026-02-30T00:00:00Z", "2026-01-01T24:00:00Z"]) {
      await assert.rejects(
        prepareTaskSetResetFence(resetFenceInput(f, { preparedAt })),
        /invalid-task-set-reset-fence-prepared-at/,
      );
    }
    await assert.rejects(
      prepareTaskSetResetFence(resetFenceInput(f, { preparedAt: "2026-01-31T23:59:59.1234567+00:00" })),
      /controller-not-quiescent/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("reset fence rejects unfinished runtime work and preserves fully bound wake state", async () => {
  const f = await fixture();
  try {
    await assert.rejects(prepareTaskSetResetFence(resetFenceInput(f)), /controller-not-quiescent/);
    const captured = await captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch) });
    await unregisterFixtureDispatch(f);
    await assert.rejects(prepareTaskSetResetFence(resetFenceInput(f)), /controller-pending-receipts/);
    await ackReceipt({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      receiptId: captured.receiptId,
      acknowledgedAt: "2026-08-13T00:10:00.000Z",
    });

    await prepareWakeWorker({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: "reset-pending-worker",
      codexProjectId: "reset-pending-worker-project",
      hostId: "local",
      projectRoot: f.controllerRoot,
      startedAt: "2026-08-13T00:11:00.000Z",
    });
    await assert.rejects(prepareTaskSetResetFence(resetFenceInput(f)), /wake-worker-intent-pending/);
    await recordWakeWorkerClientThread({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: "reset-pending-worker",
      clientThreadId: "reset-worker-client",
    });
    await bindWakeWorker({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: "reset-pending-worker",
      workerThreadId: "reset-worker-thread",
      codexProjectId: "reset-pending-worker-project",
      hostId: "local",
      projectRoot: f.controllerRoot,
    });
    await prepareWakeAutomation({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      workerThreadId: "reset-worker-thread",
      operationId: "reset-pending-automation",
      startedAt: "2026-08-13T00:12:00.000Z",
    });
    await assert.rejects(prepareTaskSetResetFence(resetFenceInput(f)), /wake-automation-intent-pending/);
    await bindWakeAutomation({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      workerThreadId: "reset-worker-thread",
      operationId: "reset-pending-automation",
      automationId: "reset-bound-automation",
    });
    const before = JSON.stringify(JSON.parse(await readFile(f.statePath, "utf8")).controllers[0].wakeWorker);
    assert.equal((await prepareTaskSetResetFence(resetFenceInput(f))).state, "task-set-reset-fence-prepared");
    const after = JSON.stringify(JSON.parse(await readFile(f.statePath, "utf8")).controllers[0].wakeWorker);
    assert.equal(after, before);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("prepared reset fence blocks registration and wake mutations but permits only its replacement", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    await prepareTaskSetResetFence(resetFenceInput(f));
    await assert.rejects(registerController({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      controllerThreadId: "019f-controller-task",
      hostId: "local",
    }), /task-set-reset-fence-pending/);
    await assert.rejects(registerDispatch({ statePath: f.statePath, ...f.dispatch }), /task-set-reset-fence-pending/);
    await assert.rejects(prepareWakeWorker({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: "reset-blocked-worker",
      codexProjectId: "reset-blocked-project",
      hostId: "local",
      projectRoot: f.controllerRoot,
      startedAt: "2026-08-13T00:31:00.000Z",
    }), /task-set-reset-fence-pending/);
    await assert.rejects(prepareControllerReplacement(replacementInput(f, {
      operationId: "other-reset-operation",
    })), /task-set-reset-fence-required/);
    const prepared = await prepareControllerReplacement(replacementInput(f));
    assert.equal(prepared.state, "controller-replacement-prepared");
    assert.equal((await commitControllerReplacement({
      ...replacementInput(f),
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    })).state, "controller-replacement-committed");
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("concurrent reset fence preparation has one durable winner and exact replay", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    const settled = await Promise.all(Array.from({ length: 16 }, () =>
      prepareTaskSetResetFence(resetFenceInput(f))));
    assert.equal(settled.filter((item) => item.state === "task-set-reset-fence-prepared").length, 1);
    assert.equal(settled.filter((item) => item.state === "task-set-reset-fence-prepare-exists").length, 15);
    await assert.rejects(
      prepareTaskSetResetFence(resetFenceInput(f, { planHash: HASH_C })),
      /task-set-reset-fence-conflict/,
    );
    await assert.rejects(
      prepareTaskSetResetFence(resetFenceInput(f, { operationId: "different-reset-operation" })),
      /task-set-reset-fence-conflict/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("reset fence completion is exact, clears replacement, replays, and permits the next identity", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    await prepareTaskSetResetFence(resetFenceInput(f));
    const prepared = await prepareControllerReplacement(replacementInput(f));
    await commitControllerReplacement({
      ...replacementInput(f),
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    });
    await assert.rejects(completeTaskSetResetFence({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: "wrong-reset-operation",
      completedManifestHash: HASH_A,
      completedAt: "2026-08-13T01:02:00.000Z",
    }), /task-set-reset-fence-conflict/);
    const completion = {
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: "replace-controller-1",
      completedManifestHash: HASH_A,
      completedAt: "2026-08-13T01:02:00.000Z",
    };
    await assert.rejects(
      completeTaskSetResetFence(completion),
      /task-set-reset-seal-required/,
    );
    const seal = await installTaskSetResetSeal(f);
    completion.completedManifestHash = seal.finalManifestHash;
    await writeFile(seal.sealPath, `${JSON.stringify({ ...seal.marker, extra: true })}\n`);
    await assert.rejects(completeTaskSetResetFence(completion), /task-set-reset-seal-invalid/);
    await writeFile(seal.sealPath, `${JSON.stringify({ ...seal.marker, operationId: "other-reset-operation" })}\n`);
    await assert.rejects(completeTaskSetResetFence(completion), /task-set-reset-seal-conflict/);
    await writeFile(seal.sealPath, `${JSON.stringify({ ...seal.marker, finalManifestHash: HASH_C })}\n`);
    await assert.rejects(completeTaskSetResetFence(completion), /task-set-reset-seal-conflict/);
    await writeFile(seal.sealPath, `${JSON.stringify(seal.marker)}\n`);
    await writeFile(join(f.controllerRoot, ".codex-controller.json"), '{"schemaVersion":3,"generator":"changed"}\n');
    await assert.rejects(completeTaskSetResetFence(completion), /task-set-reset-seal-conflict/);
    await writeFile(join(f.controllerRoot, ".codex-controller.json"), seal.manifestBytes);
    assert.equal((await completeTaskSetResetFence(completion)).state, "task-set-reset-fence-completed");
    assert.equal((await completeTaskSetResetFence(completion)).state, "task-set-reset-fence-complete-exists");
    await assert.rejects(
      completeTaskSetResetFence({ ...completion, completedManifestHash: HASH_B }),
      /task-set-reset-fence-conflict/,
    );
    const readback = await readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(readback.replacementState, "legacy");
    assert.equal(readback.operationId, completion.operationId);
    assert.equal(readback.fenceState, "completed");
    assert.equal(readback.fenceCompletedManifestHash, completion.completedManifestHash);
    const persisted = JSON.parse(await readFile(f.statePath, "utf8"));
    assert.equal(persisted.schemaVersion, 5);
    assert.equal(persisted.controllers[0].taskSetReplacement, null);

    await assert.rejects(registerDispatch({ statePath: f.statePath, ...f.dispatch }), /task-set-reset-fence-pending/);
    await rm(seal.sealPath);
    assert.equal((await completeTaskSetResetFence(completion)).state, "task-set-reset-fence-complete-exists");
    await assert.rejects(
      completeTaskSetResetFence({ ...completion, completedManifestHash: HASH_B }),
      /task-set-reset-fence-conflict/,
    );
    await assert.rejects(
      completeTaskSetResetFence({ ...completion, completedAt: "2026-08-13T01:02:00.0000001Z" }),
      /task-set-reset-fence-conflict/,
    );
    assert.equal((await registerDispatch({ statePath: f.statePath, ...f.dispatch })).state, "dispatch-registered");
    await unregisterFixtureDispatch(f);

    assert.equal((await prepareTaskSetResetFence(resetFenceInput(f))).state, "task-set-reset-fence-complete-exists");
    await assert.rejects(
      prepareTaskSetResetFence(resetFenceInput(f, { planHash: HASH_C })),
      /task-set-reset-fence-conflict/,
    );
    assert.equal((await prepareTaskSetResetFence(resetFenceInput(f, {
      operationId: "replace-controller-2",
      planHash: HASH_B,
      manifestExpectedHash: HASH_C,
      preparedAt: "2026-08-13T02:00:00.000Z",
    }))).state, "task-set-reset-fence-prepared");
    await assert.rejects(completeTaskSetResetFence(completion), /task-set-reset-fence-conflict/);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("reset fence completion cannot move backward within one millisecond", async () => {
  const f = await fixture();
  const precise = "2026-08-13T01:02:00.1234567Z";
  try {
    await unregisterFixtureDispatch(f);
    await prepareTaskSetResetFence(resetFenceInput(f, { preparedAt: precise }));
    const replacement = replacementInput(f, { preparedAt: precise });
    const prepared = await prepareControllerReplacement(replacement);
    await commitControllerReplacement({
      ...replacement,
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: precise,
    });
    const seal = await installTaskSetResetSeal(f);
    await assert.rejects(completeTaskSetResetFence({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: replacement.operationId,
      completedManifestHash: seal.finalManifestHash,
      completedAt: "2026-08-13T01:02:00.1234566Z",
    }), /task-set-reset-fence-conflict/);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("v1 through v4 registries migrate to v5 without losing dispatch, worker, automation, or legacy evidence", async () => {
  for (const schemaVersion of [1, 2, 3, 4]) {
    const root = await mkdtemp(join(tmpdir(), `onboard-runtime-v${schemaVersion}-`));
    const controllerRoot = join(root, "controller");
    const projectRoot = join(root, "project");
    const statePath = join(root, "runtime.json");
    try {
      await mkdir(controllerRoot);
      await mkdir(projectRoot);
      const dispatches = [{
        chainId: `CHAIN-v${schemaVersion}`,
        projectTaskId: `project-v${schemaVersion}`,
        dispatchId: `dispatch-v${schemaVersion}`,
        generation: 1,
        rework: 0,
        taskSpecHash: HASH_A,
        dispatchHash: HASH_B,
        projectRoot,
      }];
      const wakeWorker = schemaVersion >= 2 ? {
        operationId: `worker-op-v${schemaVersion}`,
        codexProjectId: `project-id-v${schemaVersion}`,
        hostId: "local",
        projectRoot: controllerRoot,
        startedAt: "2026-08-12T23:00:00.000Z",
        workerThreadId: `worker-v${schemaVersion}`,
        clientThreadId: `worker-client-v${schemaVersion}`,
        automation: {
          operationId: `automation-op-v${schemaVersion}`,
          startedAt: "2026-08-12T23:01:00.000Z",
          automationId: `automation-v${schemaVersion}`,
        },
      } : undefined;
      const lastReplacement = schemaVersion >= 3 ? {
        operationId: "legacy-replacement",
        oldControllerThreadId: "controller-before-legacy",
        oldHostId: "host-before-legacy",
        newControllerThreadId: "controller-current",
        newHostId: "host-current",
        replacedAt: "2026-08-12T23:02:00.000Z",
      } : undefined;
      const controller = {
        controllerRoot,
        controllerThreadId: lastReplacement?.newControllerThreadId ?? "controller-current",
        hostId: lastReplacement?.newHostId ?? "host-current",
        dispatches,
        ...(schemaVersion >= 2 ? { wakeWorker } : {}),
        ...(schemaVersion >= 3 ? { lastReplacement } : {}),
        ...(schemaVersion >= 4 ? { taskSetReplacement: null } : {}),
      };
      await writeFile(statePath, `${JSON.stringify({ schemaVersion, controllers: [controller] })}\n`);

      const readback = await readControllerReplacement({ statePath, controllerRoot });
      assert.equal(readback.replacementState, schemaVersion >= 3 ? "legacy" : "none");
      assert.equal(readback.activeDispatchCount, 1);
      assert.equal(readback.unacknowledgedReceiptCount, 0);
      assert.equal(readback.wakeWorkerState, wakeWorker ? "bound" : "none");
      assert.equal(readback.wakeWorkerOperationId, wakeWorker?.operationId ?? null);
      assert.equal(readback.wakeWorkerThreadId, wakeWorker?.workerThreadId ?? null);
      assert.equal(readback.wakeWorkerClientThreadId, wakeWorker?.clientThreadId ?? null);
      assert.equal(readback.wakeAutomationState, wakeWorker ? "bound" : "none");
      assert.equal(readback.wakeAutomationId, wakeWorker?.automation.automationId ?? null);
      assert.equal(readback.operationId, lastReplacement?.operationId ?? null);
      assert.equal(readback.fenceState, "none");

      assert.equal((await registerController({
        statePath,
        controllerRoot,
        controllerThreadId: controller.controllerThreadId,
        hostId: controller.hostId,
      })).state, "controller-exists");
      const migrated = JSON.parse(await readFile(statePath, "utf8"));
      assert.equal(migrated.schemaVersion, 5);
      assert.deepEqual(migrated.controllers[0].dispatches, dispatches);
      assert.deepEqual(migrated.controllers[0].wakeWorker, wakeWorker ?? null);
      assert.deepEqual(migrated.controllers[0].lastReplacement, lastReplacement ?? null);
      assert.equal(migrated.controllers[0].taskSetReplacement, null);
      assert.equal(migrated.controllers[0].taskSetResetFence, null);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("a migrated legacy audit remains valid evidence after a coordinated commit", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-legacy-commit-"));
  const controllerRoot = join(root, "controller");
  const statePath = join(root, "runtime.json");
  const lastReplacement = {
    operationId: "legacy-replacement",
    oldControllerThreadId: "controller-original",
    oldHostId: "host-original",
    newControllerThreadId: "019f-controller-task",
    newHostId: "local",
    replacedAt: "2026-08-12T23:02:00.000Z",
  };
  try {
    await mkdir(controllerRoot);
    await writeFile(statePath, `${JSON.stringify({
      schemaVersion: 3,
      controllers: [{
        controllerRoot,
        controllerThreadId: lastReplacement.newControllerThreadId,
        hostId: lastReplacement.newHostId,
        dispatches: [],
        wakeWorker: null,
        lastReplacement,
      }],
    })}\n`);
    const replacement = replacementInput({ statePath, controllerRoot });
    const prepared = await prepareCoordinatedReplacement(replacement);
    await commitControllerReplacement({
      ...replacement,
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    });
    const persisted = JSON.parse(await readFile(statePath, "utf8"));
    assert.deepEqual(persisted.controllers[0].lastReplacement, lastReplacement);
    assert.equal(persisted.controllers[0].controllerThreadId, replacement.newControllerThreadId);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("reset fence prepare requires no dispatch or unacknowledged receipt", async () => {
  const f = await fixture();
  const replacement = replacementInput(f);
  try {
    await assert.rejects(prepareTaskSetResetFence(resetFenceInput(f)), /controller-not-quiescent/);
    const captured = await captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch) });
    await unregisterFixtureDispatch(f);
    await assert.rejects(prepareTaskSetResetFence(resetFenceInput(f)), /controller-pending-receipts/);
    await ackReceipt({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      receiptId: captured.receiptId,
      acknowledgedAt: "2026-08-13T00:59:00.000Z",
    });
    assert.equal((await prepareTaskSetResetFence(resetFenceInput(f))).state, "task-set-reset-fence-prepared");
    assert.equal((await prepareControllerReplacement(replacement)).state, "controller-replacement-prepared");
    const current = await readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(current.controllerThreadId, replacement.oldControllerThreadId);
    assert.equal(current.hostId, replacement.oldHostId);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("prepare is deterministic, exact, freezes registration, and preserves the wake worker byte-for-byte", async () => {
  const f = await fixture();
  const replacement = replacementInput(f);
  try {
    await unregisterFixtureDispatch(f);
    await installWakeWorker(f);
    const before = await readFile(f.statePath, "utf8");
    const wakeWorkerBytes = JSON.stringify(JSON.parse(before).controllers[0].wakeWorker);
    await prepareTaskSetResetFence(resetFenceInput(f));
    await assert.rejects(
      prepareControllerReplacement({ ...replacement, newControllerThreadId: "receipt-worker-task" }),
      /controller-replacement-conflict/,
    );
    const prepared = await prepareControllerReplacement(replacement);
    const normalizedRoot = process.platform === "win32"
      ? (await realpath(f.controllerRoot)).toLowerCase()
      : await realpath(f.controllerRoot);
    assert.equal(prepared.prepareToken, sha256([
      "task-set-controller-replacement-v1",
      normalizedRoot,
      replacement.operationId,
      replacement.replacementSetHash,
      replacement.oldControllerThreadId,
      replacement.oldHostId,
      replacement.newControllerThreadId,
      replacement.newHostId,
      replacement.manifestPreparedHash,
      replacement.preparedAt,
    ].join("\0")));
    const replay = await prepareControllerReplacement(replacement);
    assert.equal(replay.state, "controller-replacement-prepare-exists");
    assert.equal(replay.prepareToken, prepared.prepareToken);
    assert.equal(replay.preparedAt, prepared.preparedAt);

    const secondControllerRoot = join(f.root, "controller-second");
    await mkdir(secondControllerRoot);
    await registerController({
      statePath: f.statePath,
      controllerRoot: secondControllerRoot,
      controllerThreadId: "controller-second",
      hostId: "local-second",
    });
    await prepareTaskSetResetFence({
      statePath: f.statePath,
      controllerRoot: secondControllerRoot,
      operationId: "replace-controller-second",
      planHash: HASH_B,
      manifestExpectedHash: HASH_C,
      preparedAt: "2026-08-13T00:59:02.000Z",
    });
    await assert.rejects(
      prepareControllerReplacement({
        statePath: f.statePath,
        controllerRoot: secondControllerRoot,
        operationId: "replace-controller-second",
        replacementSetHash: HASH_B,
        oldControllerThreadId: "controller-second",
        oldHostId: "local-second",
        newControllerThreadId: replacement.newControllerThreadId,
        newHostId: "local-new-second",
        manifestPreparedHash: HASH_C,
        preparedAt: "2026-08-13T01:00:02.000Z",
      }),
      /controller-replacement-conflict/,
    );

    for (const [field, value] of [
      ["operationId", "replace-controller-2"],
      ["replacementSetHash", HASH_C],
      ["oldControllerThreadId", "controller-third"],
      ["oldHostId", "host-third"],
      ["newControllerThreadId", "controller-third"],
      ["newHostId", "host-third"],
      ["manifestPreparedHash", HASH_C],
      ["preparedAt", "2026-08-13T01:00:01.000Z"],
    ]) {
      await assert.rejects(
        prepareControllerReplacement({ ...replacement, [field]: value }),
        /controller-replacement-conflict/,
      );
    }
    await assert.rejects(
      registerDispatch({ statePath: f.statePath, ...f.dispatch }),
      /task-set-reset-fence-pending/,
    );
    const persisted = await readFile(f.statePath, "utf8");
    assert.equal(JSON.parse(persisted).schemaVersion, 5);
    assert.ok(persisted.includes(wakeWorkerBytes));
    const readback = await readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(readback.replacementState, "prepared");
    assert.equal(readback.operationId, JSON.parse(persisted).controllers[0].taskSetReplacement.operationId);
    assert.equal(readback.manifestPreparedHash, replacement.manifestPreparedHash);
    assert.equal(readback.activeDispatchCount, 0);
    assert.equal(readback.unacknowledgedReceiptCount, 0);
    assert.equal(readback.wakeWorkerThreadId, "receipt-worker-task");
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a prepared replacement reserves its new task ID against controller registration", async () => {
  const f = await fixture();
  const replacement = replacementInput(f);
  const otherRoot = join(f.root, "controller-after-prepare");
  try {
    await mkdir(otherRoot);
    await unregisterFixtureDispatch(f);
    await prepareCoordinatedReplacement(replacement);
    await assert.rejects(
      registerController({
        statePath: f.statePath,
        controllerRoot: otherRoot,
        controllerThreadId: replacement.newControllerThreadId,
        hostId: "other-host",
      }),
      /controller-binding-conflict/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a prepared replacement reserves its new task ID against worker binding", async () => {
  const f = await fixture();
  const replacement = replacementInput(f);
  const otherRoot = join(f.root, "controller-worker-after-prepare");
  try {
    await mkdir(otherRoot);
    await registerController({
      statePath: f.statePath,
      controllerRoot: otherRoot,
      controllerThreadId: "controller-worker-owner",
      hostId: "worker-host",
    });
    await prepareWakeWorker({
      statePath: f.statePath,
      controllerRoot: otherRoot,
      operationId: "worker-after-prepare",
      codexProjectId: "worker-project-after-prepare",
      hostId: "worker-host",
      projectRoot: otherRoot,
      startedAt: "2026-08-13T01:00:02.000Z",
    });
    await unregisterFixtureDispatch(f);
    await prepareCoordinatedReplacement(replacement);
    await assert.rejects(
      bindWakeWorker({
        statePath: f.statePath,
        controllerRoot: otherRoot,
        operationId: "worker-after-prepare",
        workerThreadId: replacement.newControllerThreadId,
        codexProjectId: "worker-project-after-prepare",
        hostId: "worker-host",
        projectRoot: otherRoot,
      }),
      /wake-worker-conflict/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("registry validation rejects a preexisting controller that claims a reserved replacement task ID", async () => {
  const f = await fixture();
  const replacement = replacementInput(f);
  const otherRoot = join(f.root, "invalid-reservation-owner");
  try {
    await mkdir(otherRoot);
    await unregisterFixtureDispatch(f);
    await prepareCoordinatedReplacement(replacement);
    const registry = JSON.parse(await readFile(f.statePath, "utf8"));
    registry.controllers.push({
      controllerRoot: otherRoot,
      controllerThreadId: replacement.newControllerThreadId,
      hostId: "invalid-host",
      dispatches: [],
      wakeWorker: null,
      lastReplacement: null,
      taskSetReplacement: null,
    });
    await writeFile(f.statePath, `${JSON.stringify(registry)}\n`);
    await assert.rejects(
      readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot }),
      /runtime-registry-invalid/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a prepared replacement freezes wake-worker preparation", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    await prepareCoordinatedReplacement(replacementInput(f));
    await assert.rejects(
      prepareWakeWorker({
        statePath: f.statePath,
        controllerRoot: f.controllerRoot,
        operationId: "frozen-worker",
        codexProjectId: "frozen-worker-project",
        hostId: "local",
        projectRoot: f.controllerRoot,
        startedAt: "2026-08-13T01:02:00.000Z",
      }),
      /task-set-reset-fence-pending/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a prepared replacement freezes wake-worker client recording and binding", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    await installWakeWorker(f);
    await prepareCoordinatedReplacement(replacementInput(f));
    await assert.rejects(
      recordWakeWorkerClientThread({
        statePath: f.statePath,
        controllerRoot: f.controllerRoot,
        operationId: "wake-worker-op-reset",
        clientThreadId: "receipt-worker-client",
      }),
      /task-set-reset-fence-pending/,
    );
    await assert.rejects(
      bindWakeWorker({
        statePath: f.statePath,
        controllerRoot: f.controllerRoot,
        operationId: "wake-worker-op-reset",
        workerThreadId: "receipt-worker-task",
        codexProjectId: "controller-project-id",
        hostId: "local",
        projectRoot: f.controllerRoot,
      }),
      /task-set-reset-fence-pending/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a prepared replacement freezes automation preparation and binding", async () => {
  for (const action of ["prepare", "bind"]) {
    const f = await fixture();
    try {
      await unregisterFixtureDispatch(f);
      await installWakeWorker(f);
      await prepareCoordinatedReplacement(replacementInput(f));
      const request = action === "prepare"
        ? prepareWakeAutomation({
            statePath: f.statePath,
            controllerRoot: f.controllerRoot,
            workerThreadId: "receipt-worker-task",
            operationId: "wake-automation-op-reset",
            startedAt: "2026-08-13T00:01:00.000Z",
          })
        : bindWakeAutomation({
            statePath: f.statePath,
            controllerRoot: f.controllerRoot,
            workerThreadId: "receipt-worker-task",
            operationId: "wake-automation-op-reset",
            automationId: "receipt-wake-reset",
          });
      await assert.rejects(request, /task-set-reset-fence-pending/);
    } finally {
      await rm(f.root, { recursive: true, force: true });
    }
  }
});

test("a prepared replacement freezes wake-worker clearing", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    await installWakeWorker(f);
    await prepareCoordinatedReplacement(replacementInput(f));
    await assert.rejects(
      clearWakeWorker({
        statePath: f.statePath,
        controllerRoot: f.controllerRoot,
        expectedOperationId: "wake-worker-op-reset",
        expectedWorkerThreadId: "receipt-worker-task",
        expectedAutomationId: "receipt-wake-reset",
        confirmReconciliation: true,
      }),
      /task-set-reset-fence-pending/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("captureStop serializes registry match and receipt creation against prepare", async () => {
  const f = await fixture();
  const lockPath = `${f.statePath}.lock`;
  let lockHandle;
  try {
    lockHandle = await open(lockPath, "wx");
    const captured = captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch) });
    let settled = false;
    captured.finally(() => { settled = true; });
    await delay(75);
    assert.equal(settled, false);
    const registry = JSON.parse(await readFile(f.statePath, "utf8"));
    registry.controllers[0].dispatches = [];
    await writeFile(f.statePath, `${JSON.stringify(registry)}\n`);
    await lockHandle.close();
    lockHandle = null;
    await rm(lockPath, { force: true });

    assert.deepEqual(await captured, { state: "ignored" });
    assert.equal((await prepareCoordinatedReplacement(replacementInput(f))).state, "controller-replacement-prepared");
    const readback = await readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(readback.unacknowledgedReceiptCount, 0);
  } finally {
    if (lockHandle) await lockHandle.close();
    await rm(lockPath, { force: true });
    await rm(f.root, { recursive: true, force: true });
  }
});

test("an old lock owned by a live PID is never stolen", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-live-lock-"));
  const controllerRoot = join(root, "controller");
  const statePath = join(root, "runtime.json");
  const lockPath = `${statePath}.lock`;
  const timestamp = new Date(Date.now() - 60_000).toISOString();
  const owner = runtimeLock("1".repeat(64), process.pid, timestamp);
  let request;
  try {
    await mkdir(controllerRoot);
    await writeFile(lockPath, `${JSON.stringify(owner)}\n`);
    await utimes(lockPath, new Date(timestamp), new Date(timestamp));
    let settled = false;
    request = registerController({
      statePath,
      controllerRoot,
      controllerThreadId: "live-lock-controller",
      hostId: "local",
    }).finally(() => { settled = true; });
    await delay(150);
    assert.equal(settled, false);
    assert.deepEqual(JSON.parse(await readFile(lockPath, "utf8")), owner);
    await rm(lockPath);
    assert.equal((await request).state, "controller-registered");
  } finally {
    await rm(lockPath, { force: true });
    await request?.catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("a stale lock owned by a dead PID is recovered from its heartbeat timestamp", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-dead-lock-"));
  const controllerRoot = join(root, "controller");
  const statePath = join(root, "runtime.json");
  const lockPath = `${statePath}.lock`;
  const deadProcess = spawnSync(process.execPath, ["-e", ""]);
  const timestamp = new Date(Date.now() - 60_000).toISOString();
  let request;
  try {
    assert.ok(Number.isSafeInteger(deadProcess.pid));
    await mkdir(controllerRoot);
    await writeFile(lockPath, `${JSON.stringify(runtimeLock("2".repeat(64), deadProcess.pid, timestamp))}\n`);
    let settled = false;
    request = registerController({
      statePath,
      controllerRoot,
      controllerThreadId: "dead-lock-controller",
      hostId: "local",
    }).finally(() => { settled = true; });
    await delay(150);
    assert.equal(settled, true);
    assert.equal((await request).state, "controller-registered");
    await assert.rejects(access(lockPath), /ENOENT/);
  } finally {
    await rm(lockPath, { force: true });
    await request?.catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("concurrent stale-lock recovery never removes the winning successor", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-racing-recovery-"));
  const controllerRoot = join(root, "controller");
  const statePath = join(root, "runtime.json");
  const lockPath = `${statePath}.lock`;
  const deadProcess = spawnSync(process.execPath, ["-e", ""]);
  const timestamp = new Date(Date.now() - 60_000).toISOString();
  try {
    assert.ok(Number.isSafeInteger(deadProcess.pid));
    await mkdir(controllerRoot);
    await writeFile(lockPath, `${JSON.stringify(runtimeLock("4".repeat(64), deadProcess.pid, timestamp))}\n`);
    const settled = await Promise.allSettled(Array.from({ length: 16 }, () =>
      registerController({ statePath, controllerRoot, controllerThreadId: "racing-lock-controller", hostId: "local" })));
    assert.deepEqual(settled.filter((item) => item.status === "rejected"), []);
    const registrations = settled.map((item) => item.value);
    assert.equal(registrations.filter((item) => item.state === "controller-registered").length, 1);
    assert.equal(registrations.filter((item) => item.state === "controller-exists").length, 15);
    await assert.rejects(access(lockPath), /ENOENT/);
    assert.equal(JSON.parse(await readFile(statePath, "utf8")).controllers.length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a lock owner never deletes a successor token", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-runtime-successor-lock-"));
  const controllerRoot = join(root, "controller");
  const statePath = join(root, "runtime.json");
  const lockPath = `${statePath}.lock`;
  const successor = runtimeLock("3".repeat(64), process.pid, new Date().toISOString());
  try {
    await mkdir(controllerRoot);
    await registerController({
      statePath,
      controllerRoot,
      controllerThreadId: "successor-lock-controller",
      hostId: "local",
    });
    const inbox = join(controllerRoot, "state", "dispatch-receipts", "inbox");
    const ack = join(controllerRoot, "state", "dispatch-receipts", "ack");
    await mkdir(inbox, { recursive: true });
    await mkdir(ack, { recursive: true });
    await Promise.all(Array.from({ length: 1_000 }, async (_, index) => {
      const receiptId = index.toString(16).padStart(64, "0");
      await Promise.all([
        writeFile(join(inbox, `${receiptId}.json`), "{}\n"),
        writeFile(join(ack, `${receiptId}.json`), "{}\n"),
      ]);
    }));
    const reading = readControllerReplacement({ statePath, controllerRoot });
    let observed = false;
    let observedOwner;
    for (let attempt = 0; attempt < 500; attempt += 1) {
      try {
        const raw = await readFile(lockPath, "utf8");
        if (raw.length > 0) {
          observedOwner = JSON.parse(raw);
          observed = true;
          break;
        }
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      await delay(1);
    }
    assert.equal(observed, true);
    assert.deepEqual(Object.keys(observedOwner).sort(), [
      "createdAt", "heartbeatAt", "pid", "schemaVersion", "token",
    ].sort());
    assert.equal(observedOwner.pid, process.pid);
    assert.match(observedOwner.token, /^[0-9a-f]{64}$/);
    await writeFile(lockPath, `${JSON.stringify(successor)}\n`);
    assert.equal((await reading).state, "controller-replacement-read");
    assert.deepEqual(JSON.parse(await readFile(lockPath, "utf8")), successor);
  } finally {
    await rm(lockPath, { force: true });
    await rm(root, { recursive: true, force: true });
  }
});

test("commit requires every prepared field, switches only controller identity, and replays exactly", async () => {
  const missing = await fixture();
  try {
    await unregisterFixtureDispatch(missing);
    await assert.rejects(commitControllerReplacement({
      ...replacementInput(missing),
      prepareToken: HASH_A,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    }), /controller-replacement-not-prepared/);
  } finally {
    await rm(missing.root, { recursive: true, force: true });
  }

  const f = await fixture();
  const replacement = replacementInput(f);
  try {
    await unregisterFixtureDispatch(f);
    await installWakeWorker(f);
    const workerBefore = JSON.stringify(JSON.parse(await readFile(f.statePath, "utf8")).controllers[0].wakeWorker);
    const prepared = await prepareCoordinatedReplacement(replacement);
    const commit = {
      ...replacement,
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    };
    for (const [field, value] of [
      ["operationId", "replace-controller-2"],
      ["replacementSetHash", HASH_B],
      ["oldControllerThreadId", "controller-third"],
      ["oldHostId", "host-third"],
      ["newControllerThreadId", "controller-third"],
      ["newHostId", "host-third"],
      ["manifestPreparedHash", HASH_A],
      ["preparedAt", "2026-08-13T01:00:01.000Z"],
      ["prepareToken", HASH_B],
    ]) {
      await assert.rejects(
        commitControllerReplacement({ ...commit, [field]: value }),
        /controller-replacement-conflict/,
      );
    }

    const committed = await commitControllerReplacement(commit);
    assert.equal(committed.state, "controller-replacement-committed");
    const replay = await commitControllerReplacement(commit);
    assert.equal(replay.state, "controller-replacement-commit-exists");
    assert.equal(replay.committedAt, committed.committedAt);
    await assert.rejects(
      commitControllerReplacement({ ...commit, manifestSwitchedHash: HASH_A }),
      /controller-replacement-conflict/,
    );
    await assert.rejects(
      commitControllerReplacement({ ...commit, newControllerThreadId: "controller-third" }),
      /controller-replacement-conflict/,
    );
    await assert.rejects(
      prepareControllerReplacement({
        ...replacement,
        operationId: "replace-controller-2",
        newControllerThreadId: "controller-third",
      }),
      /task-set-reset-fence-required/,
    );

    const readback = await readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(readback.replacementState, "committed");
    assert.equal(readback.controllerThreadId, replacement.newControllerThreadId);
    assert.equal(readback.hostId, replacement.newHostId);
    assert.equal(readback.manifestSwitchedHash, HASH_C);
    assert.equal(readback.committedAt, committed.committedAt);
    const persisted = await readFile(f.statePath, "utf8");
    assert.ok(persisted.includes(workerBefore));
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a new quiescent operation advances the single committed audit slot", async () => {
  const f = await fixture();
  const first = replacementInput(f);
  try {
    await unregisterFixtureDispatch(f);
    const prepared = await prepareCoordinatedReplacement(first);
    const firstCommit = {
      ...first,
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    };
    await commitControllerReplacement(firstCommit);
    assert.equal(
      (await commitControllerReplacement(firstCommit)).state,
      "controller-replacement-commit-exists",
    );
    const firstSeal = await installTaskSetResetSeal(f);
    await completeTaskSetResetFence({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      operationId: first.operationId,
      completedManifestHash: firstSeal.finalManifestHash,
      completedAt: "2026-08-13T01:02:00.000Z",
    });

    const next = replacementInput(f, {
      operationId: "replace-controller-2",
      replacementSetHash: HASH_B,
      oldControllerThreadId: first.newControllerThreadId,
      oldHostId: first.newHostId,
      newControllerThreadId: "019f-controller-task-next",
      newHostId: "local-next",
      manifestPreparedHash: HASH_C,
      preparedAt: "2026-08-13T02:00:00.000Z",
    });
    await assert.rejects(
      prepareControllerReplacement({ ...next, operationId: first.operationId }),
      /task-set-reset-fence-required/,
    );
    const nextPrepared = await prepareCoordinatedReplacement(next);
    assert.equal(nextPrepared.state, "controller-replacement-prepared");
    const readback = await readControllerReplacement({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(readback.replacementState, "prepared");
    assert.equal(readback.operationId, next.operationId);
    assert.equal(readback.controllerThreadId, first.newControllerThreadId);
    assert.equal(readback.hostId, first.newHostId);
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("CLI exposes coordinated prepare, read, and commit while rejecting one-step replacement", async () => {
  const f = await fixture();
  try {
    await unregisterFixtureDispatch(f);
    const { statePath: _statePath, ...replacement } = replacementInput(f);
    const fenceRun = runCli("prepare-task-set-reset-fence", f.statePath, {
      controllerRoot: f.controllerRoot,
      operationId: replacement.operationId,
      planHash: replacement.replacementSetHash,
      manifestExpectedHash: replacement.manifestPreparedHash,
      preparedAt: "2026-08-13T00:59:00.000Z",
    });
    assert.equal(fenceRun.status, 0, fenceRun.stderr);
    const preparedRun = runCli("prepare-controller-replacement", f.statePath, replacement);
    assert.equal(preparedRun.status, 0, preparedRun.stderr);
    const prepared = JSON.parse(preparedRun.stdout);
    assert.equal(prepared.state, "controller-replacement-prepared");

    const preparedRead = runCli("read-controller-replacement", f.statePath, { controllerRoot: f.controllerRoot });
    assert.equal(preparedRead.status, 0, preparedRead.stderr);
    assert.equal(JSON.parse(preparedRead.stdout).replacementState, "prepared");

    const committedRun = runCli("commit-controller-replacement", f.statePath, {
      ...replacement,
      prepareToken: prepared.prepareToken,
      manifestSwitchedHash: HASH_C,
      committedAt: "2026-08-13T01:01:00.000Z",
    });
    assert.equal(committedRun.status, 0, committedRun.stderr);
    assert.equal(JSON.parse(committedRun.stdout).state, "controller-replacement-committed");

    const seal = await installTaskSetResetSeal(f);
    const completedRun = runCli("complete-task-set-reset-fence", f.statePath, {
      controllerRoot: f.controllerRoot,
      operationId: replacement.operationId,
      completedManifestHash: seal.finalManifestHash,
      completedAt: "2026-08-13T01:02:00.000Z",
    });
    assert.equal(completedRun.status, 0, completedRun.stderr);
    assert.equal(JSON.parse(completedRun.stdout).state, "task-set-reset-fence-completed");

    const oneStep = runCli("replace-controller", f.statePath, {});
    assert.equal(oneStep.status, 1);
    assert.equal(JSON.parse(oneStep.stderr).reasonCode, "controller-replacement-uncoordinated-disabled");
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("receipt reads reject a renamed or non-terminal envelope", async () => {
  const f = await fixture();
  try {
    const captured = await captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch) });
    const receiptPath = join(f.controllerRoot, "state", "dispatch-receipts", "inbox", `${captured.receiptId}.json`);
    const receipt = JSON.parse(await readFile(receiptPath, "utf8"));
    receipt.envelope.resultState = "running";
    receipt.receiptId = receiptIdentity(receipt.envelope, receipt.evidenceHash, receipt.turnId);
    await writeFile(receiptPath, `${JSON.stringify(receipt)}\n`);
    await assert.rejects(
      readPending({ statePath: f.statePath, controllerRoot: f.controllerRoot }),
      /receipt-invalid/,
    );
  } finally {
    await rm(f.root, { recursive: true, force: true });
  }
});

test("a source-checkout runtime ignores CODEX_HOME and falls back to the actual home", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-source-home-"));
  const attackerHome = join(root, "attacker-home");
  const attackerStatePath = join(attackerHome, "skill-state", "onboard-code-projects", "runtime.json");
  const controllerRoot = join(root, "controller");
  try {
    await mkdir(controllerRoot);
    await registerController({
      statePath: attackerStatePath,
      controllerRoot,
      controllerThreadId: "attacker-controller",
      hostId: "attacker-host",
    });
    const payload = Buffer.from(JSON.stringify({ controllerRoot }), "utf8").toString("base64");
    const run = spawnSync(process.execPath, [
      fileURLToPath(new URL("./dispatch-return-runtime.mjs", import.meta.url)),
      "read",
      "--payload-base64",
      payload,
    ], {
      encoding: "utf8",
      env: { ...process.env, CODEX_HOME: attackerHome },
    });
    assert.equal(run.status, 1);
    assert.equal(JSON.parse(run.stderr).reasonCode, "controller-not-registered");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("worker-safe CLI ignores CODEX_HOME and uses the installed runtime owner", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-worker-home-"));
  const installedHome = join(root, "installed-home");
  const runtimePath = join(installedHome, "skills", "onboard-code-projects", "scripts", "dispatch-return-runtime.mjs");
  const trustedStatePath = join(installedHome, "skill-state", "onboard-code-projects", "runtime.json");
  const attackerHome = join(root, "attacker-home");
  const attackerStatePath = join(attackerHome, "skill-state", "onboard-code-projects", "runtime.json");
  const controllerRoot = join(root, "controller");
  try {
    await mkdir(dirname(runtimePath), { recursive: true });
    await mkdir(controllerRoot);
    await copyFile(fileURLToPath(new URL("./dispatch-return-runtime.mjs", import.meta.url)), runtimePath);
    await registerController({
      statePath: trustedStatePath,
      controllerRoot,
      controllerThreadId: "trusted-controller",
      hostId: "trusted-host",
    });
    await registerController({
      statePath: attackerStatePath,
      controllerRoot,
      controllerThreadId: "attacker-controller",
      hostId: "attacker-host",
    });
    const attackerBefore = await readFile(attackerStatePath, "utf8");
    const payload = Buffer.from(JSON.stringify({ controllerRoot }), "utf8").toString("base64");
    const run = spawnSync(process.execPath, [
      runtimePath,
      "read",
      "--payload-base64",
      payload,
    ], {
      encoding: "utf8",
      env: { ...process.env, CODEX_HOME: attackerHome },
    });
    assert.equal(run.status, 0, run.stderr);
    const readback = JSON.parse(run.stdout);
    assert.equal(readback.controllerThreadId, "trusted-controller");
    assert.equal(readback.hostId, "trusted-host");
    assert.equal(await readFile(attackerStatePath, "utf8"), attackerBefore);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("one durable wake worker survives schema migration and rejects duplicate creation", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-wake-worker-"));
  const controllerRoot = join(root, "controller");
  const controllerAlias = join(root, "controller-alias");
  const statePath = join(root, "runtime.json");
  const worker = {
    controllerRoot,
    operationId: "wake-worker-op-1",
    codexProjectId: "controller-project-id",
    hostId: "local",
    projectRoot: controllerRoot,
    startedAt: "2026-08-08T11:00:00.000Z",
  };
  try {
    await mkdir(controllerRoot);
    await symlink(controllerRoot, controllerAlias, process.platform === "win32" ? "junction" : "dir");
    await writeFile(statePath, `${JSON.stringify({
      schemaVersion: 1,
      controllers: [{
        controllerRoot: controllerAlias,
        controllerThreadId: "controller-task",
        hostId: "local",
        dispatches: [],
      }],
    })}\n`);

    assert.equal((await readWakeWorker({ statePath, controllerRoot })).wakeWorker, null);
    assert.equal((await prepareWakeWorker({ statePath, ...worker })).state, "wake-worker-intent-recorded");
    assert.equal((await prepareWakeWorker({ statePath, ...worker })).state, "wake-worker-intent-exists");
    await assert.rejects(
      prepareWakeWorker({ statePath, ...worker, operationId: "wake-worker-op-2" }),
      /wake-worker-conflict/,
    );

    assert.equal((await recordWakeWorkerClientThread({
      statePath,
      controllerRoot,
      operationId: worker.operationId,
      clientThreadId: "client-worker-task",
    })).state, "wake-worker-client-recorded");
    await assert.rejects(
      bindWakeWorker({
        statePath,
        controllerRoot,
        operationId: worker.operationId,
        workerThreadId: "controller-task",
        codexProjectId: worker.codexProjectId,
        hostId: worker.hostId,
        projectRoot: worker.projectRoot,
      }),
      /wake-worker-conflict/,
    );
    assert.equal((await bindWakeWorker({
      statePath,
      controllerRoot,
      operationId: worker.operationId,
      workerThreadId: "receipt-worker-task",
      codexProjectId: worker.codexProjectId,
      hostId: worker.hostId,
      projectRoot: worker.projectRoot,
    })).state, "wake-worker-bound");

    assert.equal((await prepareWakeAutomation({
      statePath,
      controllerRoot,
      workerThreadId: "receipt-worker-task",
      operationId: "wake-automation-op-1",
      startedAt: "2026-08-08T11:01:00.000Z",
    })).state, "wake-automation-intent-recorded");
    assert.equal((await bindWakeAutomation({
      statePath,
      controllerRoot,
      workerThreadId: "receipt-worker-task",
      operationId: "wake-automation-op-1",
      automationId: "onboard-code-projects-receipt-wake-test",
    })).state, "wake-automation-bound");

    const readback = await readWakeWorker({ statePath, controllerRoot });
    assert.equal(readback.wakeWorker.workerThreadId, "receipt-worker-task");
    assert.equal(readback.wakeWorker.clientThreadId, "client-worker-task");
    assert.equal(readback.wakeWorker.automation.automationId, "onboard-code-projects-receipt-wake-test");
    const persisted = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(persisted.schemaVersion, 5);
    assert.equal(persisted.controllers[0].taskSetReplacement, null);

    await assert.rejects(
      clearWakeWorker({
        statePath,
        controllerRoot,
        expectedOperationId: worker.operationId,
        expectedWorkerThreadId: "receipt-worker-task",
        expectedAutomationId: "onboard-code-projects-receipt-wake-test",
        confirmReconciliation: false,
      }),
      /wake-worker-reconciliation-required/,
    );
    assert.equal((await clearWakeWorker({
      statePath,
      controllerRoot,
      expectedOperationId: worker.operationId,
      expectedWorkerThreadId: "receipt-worker-task",
      expectedAutomationId: "onboard-code-projects-receipt-wake-test",
      confirmReconciliation: true,
    })).state, "wake-worker-cleared");
    assert.equal((await readWakeWorker({ statePath, controllerRoot })).wakeWorker, null);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
