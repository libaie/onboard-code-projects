import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { access, mkdtemp, mkdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  ackReceipt,
  bindWakeAutomation,
  bindWakeWorker,
  captureStop,
  claimPending,
  clearWakeWorker,
  prepareWakeAutomation,
  prepareWakeWorker,
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
const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

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

test("controller replacement is exact, quiescent, atomic, and idempotent", async () => {
  const f = await fixture();
  const replacement = {
    statePath: f.statePath,
    controllerRoot: f.controllerRoot,
    operationId: "replace-controller-1",
    oldControllerThreadId: "019f-controller-task",
    oldHostId: "local",
    newControllerThreadId: "019f-controller-task-new",
    newHostId: "local-new",
    replacedAt: "2026-08-08T10:30:00.000Z",
  };
  try {
    await assert.rejects(replaceController(replacement), /controller-not-quiescent/);
    const captured = await captureStop({ statePath: f.statePath, input: terminalInput(f.dispatch) });
    await unregisterDispatch({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      projectTaskId: f.dispatch.projectTaskId,
      dispatchId: f.dispatch.dispatchId,
      taskSpecHash: f.dispatch.taskSpecHash,
    });
    await assert.rejects(replaceController(replacement), /controller-pending-receipts/);
    await ackReceipt({
      statePath: f.statePath,
      controllerRoot: f.controllerRoot,
      receiptId: captured.receiptId,
      acknowledgedAt: "2026-08-08T10:29:00.000Z",
    });
    await assert.rejects(
      replaceController({ ...replacement, oldControllerThreadId: "wrong-controller" }),
      /controller-binding-conflict/,
    );
    assert.equal((await replaceController(replacement)).state, "controller-replaced");
    assert.equal((await replaceController(replacement)).state, "controller-replacement-exists");
    const current = await readPending({ statePath: f.statePath, controllerRoot: f.controllerRoot });
    assert.equal(current.controllerThreadId, replacement.newControllerThreadId);
    assert.equal(current.hostId, replacement.newHostId);
    const registry = JSON.parse(await readFile(f.statePath, "utf8"));
    assert.equal(registry.schemaVersion, 3);
    assert.deepEqual(Object.keys(registry.controllers[0]).sort(), [
      "controllerRoot", "controllerThreadId", "hostId", "dispatches", "wakeWorker", "lastReplacement",
    ].sort());
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

test("the default registry stays inside the narrow onboarding state directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "onboard-default-state-"));
  const controllerRoot = join(root, "controller");
  const previous = process.env.CODEX_HOME;
  try {
    await mkdir(controllerRoot);
    process.env.CODEX_HOME = root;
    await registerController({ controllerRoot, controllerThreadId: "controller-task", hostId: "local" });
    await access(join(root, "skill-state", "onboard-code-projects", "runtime.json"));
    await assert.rejects(access(join(root, "skill-state", "onboard-code-projects-runtime.json")), /ENOENT/);
  } finally {
    if (previous === undefined) delete process.env.CODEX_HOME;
    else process.env.CODEX_HOME = previous;
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
    assert.equal(persisted.schemaVersion, 3);

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
