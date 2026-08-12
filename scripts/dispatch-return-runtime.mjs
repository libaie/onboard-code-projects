#!/usr/bin/env node

import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import {
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const HASH_RE = /^[0-9a-f]{64}$/;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const TERMINAL_STATES = new Set(["completed", "blocked", "auth-required", "cancelled", "convergence-failed"]);
const ENVELOPE_FIELDS = [
  "chainId",
  "dispatchId",
  "projectTaskId",
  "generation",
  "rework",
  "taskSpecHash",
  "resultState",
  "failureClass",
];
const REGISTRY_FIELDS = ["schemaVersion", "controllers"];
const LEGACY_CONTROLLER_FIELDS = ["controllerRoot", "controllerThreadId", "hostId", "dispatches"];
const V2_CONTROLLER_FIELDS = [...LEGACY_CONTROLLER_FIELDS, "wakeWorker"];
const CONTROLLER_FIELDS = [...V2_CONTROLLER_FIELDS, "lastReplacement"];
const CONTROLLER_REPLACEMENT_FIELDS = [
  "operationId",
  "oldControllerThreadId",
  "oldHostId",
  "newControllerThreadId",
  "newHostId",
  "replacedAt",
];
const WAKE_WORKER_FIELDS = [
  "operationId",
  "codexProjectId",
  "hostId",
  "projectRoot",
  "startedAt",
  "workerThreadId",
  "clientThreadId",
  "automation",
];
const WAKE_AUTOMATION_FIELDS = ["operationId", "startedAt", "automationId"];
const DISPATCH_FIELDS = [
  "chainId",
  "projectTaskId",
  "dispatchId",
  "generation",
  "rework",
  "taskSpecHash",
  "dispatchHash",
  "projectRoot",
];
const DISPATCH_ENVELOPE_FIELDS = [
  "schemaVersion",
  "kind",
  "chainId",
  "projectTaskId",
  "dispatchId",
  "generation",
  "rework",
  "taskSpecHash",
  "taskSpec",
  "dispatchHash",
];
const DISPATCH_IDENTITY_FIELDS = ["chainId", "projectTaskId", "dispatchId", "generation", "rework"];
const LEGACY_CLAIM_FIELDS = ["schemaVersion", "receiptId", "claimedAt"];
const CLAIM_FIELDS = ["schemaVersion", "receiptId", "claimOwnerId", "claimedAt", "leaseUntil"];
const WORKER_SAFE_ACTIONS = new Set(["read", "claim", "renew-claim"]);
const RECEIPT_FIELDS = [
  "schemaVersion",
  "receiptId",
  "receivedAt",
  "sessionId",
  "turnId",
  "cwd",
  "controllerRoot",
  "evidenceHash",
  "envelope",
];

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");
const keysEqual = (value, fields) =>
  value && typeof value === "object" && !Array.isArray(value) &&
  Object.keys(value).sort().join("\0") === [...fields].sort().join("\0");
const comparablePath = (value) => {
  try { return realpathSync.native(resolve(value)); } catch { return resolve(value); }
};
const samePath = (left, right) =>
  process.platform === "win32"
    ? comparablePath(left).toLowerCase() === comparablePath(right).toLowerCase()
    : comparablePath(left) === comparablePath(right);

function defaultStatePath() {
  const codexRoot = process.env.CODEX_HOME || join(homedir(), ".codex");
  return join(codexRoot, "skill-state", "onboard-code-projects", "runtime.json");
}

function requireId(value, field) {
  if (typeof value !== "string" || !ID_RE.test(value)) throw new Error(`invalid-${field}`);
  return value;
}

function requireHash(value, field) {
  if (typeof value !== "string" || !HASH_RE.test(value)) throw new Error(`invalid-${field}`);
  return value;
}

function requireCounter(value, field) {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`invalid-${field}`);
  return value;
}

function requireIso(value, field) {
  if (typeof value !== "string" || Number.isNaN(Date.parse(value)) || !value.endsWith("Z")) {
    throw new Error(`invalid-${field}`);
  }
  return value;
}

function addMilliseconds(iso, milliseconds) {
  const value = Date.parse(iso) + milliseconds;
  if (!Number.isSafeInteger(value)) throw new Error("invalid-lease");
  return new Date(value).toISOString();
}

async function requireRoot(value, field) {
  if (typeof value !== "string" || value.length === 0 || value.length > 32_767 || !isAbsolute(value)) {
    throw new Error(`invalid-${field}`);
  }
  const resolved = resolve(value);
  let physical;
  try {
    physical = await realpath(resolved);
  } catch {
    throw new Error(`invalid-${field}`);
  }
  const info = await stat(physical);
  if (!info.isDirectory()) throw new Error(`invalid-${field}`);
  return physical;
}

function validateDispatch(value) {
  if (!keysEqual(value, DISPATCH_FIELDS)) throw new Error("invalid-dispatch");
  requireId(value.chainId, "chain-id");
  requireId(value.projectTaskId, "project-task-id");
  requireId(value.dispatchId, "dispatch-id");
  requireCounter(value.generation, "generation");
  requireCounter(value.rework, "rework");
  requireHash(value.taskSpecHash, "task-spec-hash");
  requireHash(value.dispatchHash, "dispatch-hash");
  if (typeof value.projectRoot !== "string" || !isAbsolute(value.projectRoot)) throw new Error("invalid-project-root");
  return value;
}

function validateControllerReplacement(value) {
  if (!keysEqual(value, CONTROLLER_REPLACEMENT_FIELDS)) throw new Error("runtime-registry-invalid");
  requireId(value.operationId, "controller-replacement-operation-id");
  requireId(value.oldControllerThreadId, "old-controller-thread-id");
  requireId(value.oldHostId, "old-host-id");
  requireId(value.newControllerThreadId, "new-controller-thread-id");
  requireId(value.newHostId, "new-host-id");
  requireIso(value.replacedAt, "controller-replaced-at");
  if (value.oldControllerThreadId === value.newControllerThreadId) throw new Error("runtime-registry-invalid");
  return value;
}

function validateWakeAutomation(value) {
  if (!keysEqual(value, WAKE_AUTOMATION_FIELDS)) throw new Error("runtime-registry-invalid");
  requireId(value.operationId, "wake-automation-operation-id");
  requireIso(value.startedAt, "wake-automation-started-at");
  if (value.automationId !== null) requireId(value.automationId, "wake-automation-id");
  return value;
}

function validateWakeWorker(value) {
  if (!keysEqual(value, WAKE_WORKER_FIELDS) || typeof value.projectRoot !== "string" || !isAbsolute(value.projectRoot)) {
    throw new Error("runtime-registry-invalid");
  }
  requireId(value.operationId, "wake-worker-operation-id");
  requireId(value.codexProjectId, "wake-worker-project-id");
  requireId(value.hostId, "wake-worker-host-id");
  requireIso(value.startedAt, "wake-worker-started-at");
  if (value.workerThreadId !== null) requireId(value.workerThreadId, "wake-worker-thread-id");
  if (value.clientThreadId !== null) requireId(value.clientThreadId, "wake-worker-client-thread-id");
  if (value.automation !== null) {
    if (value.workerThreadId === null) throw new Error("runtime-registry-invalid");
    validateWakeAutomation(value.automation);
  }
  return value;
}

function validateRegistry(value) {
  if (!keysEqual(value, REGISTRY_FIELDS) || !Array.isArray(value.controllers)) {
    throw new Error("runtime-registry-invalid");
  }
  if (value.schemaVersion === 1) {
    for (const controller of value.controllers) {
      if (!keysEqual(controller, LEGACY_CONTROLLER_FIELDS)) throw new Error("runtime-registry-invalid");
    }
    return validateRegistry({
      schemaVersion: 3,
      controllers: value.controllers.map((controller) => ({ ...controller, wakeWorker: null, lastReplacement: null })),
    });
  }
  if (value.schemaVersion === 2) {
    for (const controller of value.controllers) {
      if (!keysEqual(controller, V2_CONTROLLER_FIELDS)) throw new Error("runtime-registry-invalid");
    }
    return validateRegistry({
      schemaVersion: 3,
      controllers: value.controllers.map((controller) => ({ ...controller, lastReplacement: null })),
    });
  }
  if (value.schemaVersion !== 3) throw new Error("runtime-registry-invalid");
  const controllerThreadIds = new Set(value.controllers.map((controller) => controller.controllerThreadId));
  if (controllerThreadIds.size !== value.controllers.length) throw new Error("runtime-registry-invalid");
  const workerThreadIds = new Set();
  const automationIds = new Set();
  for (const controller of value.controllers) {
    if (!keysEqual(controller, CONTROLLER_FIELDS) || typeof controller.controllerRoot !== "string" || !isAbsolute(controller.controllerRoot) ||
        typeof controller.controllerThreadId !== "string" || typeof controller.hostId !== "string" ||
        !Array.isArray(controller.dispatches)) throw new Error("runtime-registry-invalid");
    requireId(controller.controllerThreadId, "controller-thread-id");
    requireId(controller.hostId, "host-id");
    controller.dispatches.forEach(validateDispatch);
    if (controller.lastReplacement !== null) {
      validateControllerReplacement(controller.lastReplacement);
      if (controller.controllerThreadId !== controller.lastReplacement.newControllerThreadId ||
          controller.hostId !== controller.lastReplacement.newHostId) throw new Error("runtime-registry-invalid");
    }
    if (controller.wakeWorker !== null) {
      validateWakeWorker(controller.wakeWorker);
      if (controller.wakeWorker.workerThreadId !== null) {
        if (controllerThreadIds.has(controller.wakeWorker.workerThreadId) || workerThreadIds.has(controller.wakeWorker.workerThreadId)) {
          throw new Error("runtime-registry-invalid");
        }
        workerThreadIds.add(controller.wakeWorker.workerThreadId);
      }
      const automationId = controller.wakeWorker.automation?.automationId;
      if (automationId !== null && automationId !== undefined) {
        if (automationIds.has(automationId)) throw new Error("runtime-registry-invalid");
        automationIds.add(automationId);
      }
    }
  }
  return value;
}

async function readRegistry(statePath) {
  try {
    const raw = await readFile(statePath, "utf8");
    if (Buffer.byteLength(raw, "utf8") > 1_048_576) throw new Error("runtime-registry-too-large");
    return validateRegistry(JSON.parse(raw));
  } catch (error) {
    if (error?.code === "ENOENT") return { schemaVersion: 3, controllers: [] };
    throw error;
  }
}

async function writeRegistry(statePath, registry) {
  validateRegistry(registry);
  await mkdir(dirname(statePath), { recursive: true });
  const temporary = `${statePath}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(registry)}\n`, { encoding: "utf8", flag: "wx" });
  try {
    await rename(temporary, statePath);
  } finally {
    await rm(temporary, { force: true });
  }
}

async function withLock(lockPath, operation) {
  await mkdir(dirname(lockPath), { recursive: true });
  const deadline = Date.now() + 5_000;
  while (true) {
    try {
      const handle = await open(lockPath, "wx");
      await handle.writeFile(`${process.pid}\n`, "utf8");
      await handle.close();
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      try {
        if (Date.now() - (await stat(lockPath)).mtimeMs > 30_000) await rm(lockPath, { force: true });
      } catch (inspectError) {
        if (inspectError?.code !== "ENOENT") throw inspectError;
      }
      if (Date.now() >= deadline) throw new Error("runtime-lock-timeout");
      await sleep(25);
    }
  }
  try {
    return await operation();
  } finally {
    await rm(lockPath, { force: true });
  }
}

async function mutateRegistry(statePath, operation) {
  return withLock(`${statePath}.lock`, async () => {
    const registry = await readRegistry(statePath);
    const result = await operation(registry);
    await writeRegistry(statePath, registry);
    return result;
  });
}

function findController(registry, controllerRoot) {
  return registry.controllers.find((item) => samePath(item.controllerRoot, controllerRoot));
}

function sameDispatch(left, right) {
  return DISPATCH_FIELDS.every((field) =>
    field.endsWith("Root") ? samePath(left[field], right[field]) : left[field] === right[field]);
}

export async function registerController({
  statePath = defaultStatePath(),
  controllerRoot,
  controllerThreadId,
  hostId,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  requireId(controllerThreadId, "controller-thread-id");
  requireId(hostId, "host-id");
  return mutateRegistry(statePath, async (registry) => {
    const current = findController(registry, root);
    if (current) {
      if (current.controllerThreadId !== controllerThreadId || current.hostId !== hostId) {
        throw new Error("controller-binding-conflict");
      }
      return { state: "controller-exists", controllerRoot: root };
    }
    registry.controllers.push({
      controllerRoot: root,
      controllerThreadId,
      hostId,
      dispatches: [],
      wakeWorker: null,
      lastReplacement: null,
    });
    return { state: "controller-registered", controllerRoot: root };
  });
}

export async function replaceController({
  statePath = defaultStatePath(),
  controllerRoot,
  operationId,
  oldControllerThreadId,
  oldHostId,
  newControllerThreadId,
  newHostId,
  replacedAt = new Date().toISOString(),
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  const replacement = validateControllerReplacement({
    operationId,
    oldControllerThreadId,
    oldHostId,
    newControllerThreadId,
    newHostId,
    replacedAt,
  });
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    if (!controller) throw new Error("controller-not-registered");
    if (controller.controllerThreadId === newControllerThreadId && controller.hostId === newHostId &&
        controller.lastReplacement && CONTROLLER_REPLACEMENT_FIELDS.every(
          (field) => controller.lastReplacement[field] === replacement[field],
        )) return { state: "controller-replacement-exists", controllerRoot: root };
    if (controller.controllerThreadId !== oldControllerThreadId || controller.hostId !== oldHostId) {
      throw new Error("controller-binding-conflict");
    }
    if (controller.dispatches.length !== 0) throw new Error("controller-not-quiescent");
    if ((await listPending(root)).length !== 0) throw new Error("controller-pending-receipts");
    if (registry.controllers.some((item) => item !== controller && item.controllerThreadId === newControllerThreadId)) {
      throw new Error("controller-binding-conflict");
    }
    controller.controllerThreadId = newControllerThreadId;
    controller.hostId = newHostId;
    controller.lastReplacement = replacement;
    return { state: "controller-replaced", controllerRoot: root };
  });
}

export async function readWakeWorker({ statePath = defaultStatePath(), controllerRoot }) {
  const { root, controller } = await controllerForRoot(statePath, controllerRoot);
  return { state: "wake-worker-read", controllerRoot: root, wakeWorker: controller.wakeWorker };
}

export async function prepareWakeWorker({
  statePath = defaultStatePath(),
  controllerRoot,
  operationId,
  codexProjectId,
  hostId,
  projectRoot,
  startedAt,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  const exactProjectRoot = await requireRoot(projectRoot, "wake-worker-project-root");
  if (!samePath(root, exactProjectRoot)) throw new Error("wake-worker-project-root-mismatch");
  requireId(operationId, "wake-worker-operation-id");
  requireId(codexProjectId, "wake-worker-project-id");
  requireId(hostId, "wake-worker-host-id");
  requireIso(startedAt, "wake-worker-started-at");
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    if (!controller) throw new Error("controller-not-registered");
    if (controller.hostId !== hostId) throw new Error("wake-worker-host-conflict");
    const current = controller.wakeWorker;
    if (current) {
      if (current.operationId !== operationId || current.codexProjectId !== codexProjectId ||
          current.hostId !== hostId || !samePath(current.projectRoot, exactProjectRoot) || current.startedAt !== startedAt) {
        throw new Error("wake-worker-conflict");
      }
      return { state: "wake-worker-intent-exists", controllerRoot: root };
    }
    controller.wakeWorker = {
      operationId,
      codexProjectId,
      hostId,
      projectRoot: exactProjectRoot,
      startedAt,
      workerThreadId: null,
      clientThreadId: null,
      automation: null,
    };
    return { state: "wake-worker-intent-recorded", controllerRoot: root };
  });
}

export async function recordWakeWorkerClientThread({
  statePath = defaultStatePath(), controllerRoot, operationId, clientThreadId,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  requireId(operationId, "wake-worker-operation-id");
  requireId(clientThreadId, "wake-worker-client-thread-id");
  return mutateRegistry(statePath, async (registry) => {
    const current = findController(registry, root)?.wakeWorker;
    if (!current || current.operationId !== operationId) throw new Error("wake-worker-conflict");
    if (current.clientThreadId === clientThreadId) return { state: "wake-worker-client-exists", clientThreadId };
    if (current.clientThreadId !== null) throw new Error("wake-worker-conflict");
    current.clientThreadId = clientThreadId;
    return { state: "wake-worker-client-recorded", clientThreadId };
  });
}

export async function bindWakeWorker({
  statePath = defaultStatePath(),
  controllerRoot,
  operationId,
  workerThreadId,
  codexProjectId,
  hostId,
  projectRoot,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  const exactProjectRoot = await requireRoot(projectRoot, "wake-worker-project-root");
  requireId(operationId, "wake-worker-operation-id");
  requireId(workerThreadId, "wake-worker-thread-id");
  requireId(codexProjectId, "wake-worker-project-id");
  requireId(hostId, "wake-worker-host-id");
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    const current = controller?.wakeWorker;
    if (!current || current.operationId !== operationId || current.codexProjectId !== codexProjectId ||
        current.hostId !== hostId || !samePath(current.projectRoot, exactProjectRoot)) {
      throw new Error("wake-worker-conflict");
    }
    if (registry.controllers.some((item) => item.controllerThreadId === workerThreadId ||
        (item !== controller && item.wakeWorker?.workerThreadId === workerThreadId))) {
      throw new Error("wake-worker-conflict");
    }
    if (current.workerThreadId === workerThreadId) return { state: "wake-worker-exists", workerThreadId };
    if (current.workerThreadId !== null) throw new Error("wake-worker-conflict");
    current.workerThreadId = workerThreadId;
    return { state: "wake-worker-bound", workerThreadId };
  });
}

export async function prepareWakeAutomation({
  statePath = defaultStatePath(), controllerRoot, workerThreadId, operationId, startedAt,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  requireId(workerThreadId, "wake-worker-thread-id");
  requireId(operationId, "wake-automation-operation-id");
  requireIso(startedAt, "wake-automation-started-at");
  return mutateRegistry(statePath, async (registry) => {
    const current = findController(registry, root)?.wakeWorker;
    if (!current || current.workerThreadId !== workerThreadId) throw new Error("wake-worker-conflict");
    if (current.automation) {
      if (current.automation.operationId !== operationId || current.automation.startedAt !== startedAt) {
        throw new Error("wake-automation-conflict");
      }
      return { state: "wake-automation-intent-exists", operationId };
    }
    current.automation = { operationId, startedAt, automationId: null };
    return { state: "wake-automation-intent-recorded", operationId };
  });
}

export async function bindWakeAutomation({
  statePath = defaultStatePath(), controllerRoot, workerThreadId, operationId, automationId,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  requireId(workerThreadId, "wake-worker-thread-id");
  requireId(operationId, "wake-automation-operation-id");
  requireId(automationId, "wake-automation-id");
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    const current = controller?.wakeWorker;
    if (!current || current.workerThreadId !== workerThreadId || !current.automation ||
        current.automation.operationId !== operationId) throw new Error("wake-automation-conflict");
    if (registry.controllers.some((item) => item !== controller && item.wakeWorker?.automation?.automationId === automationId)) {
      throw new Error("wake-automation-conflict");
    }
    if (current.automation.automationId === automationId) return { state: "wake-automation-exists", automationId };
    if (current.automation.automationId !== null) throw new Error("wake-automation-conflict");
    current.automation.automationId = automationId;
    return { state: "wake-automation-bound", automationId };
  });
}

export async function clearWakeWorker({
  statePath = defaultStatePath(),
  controllerRoot,
  expectedOperationId,
  expectedWorkerThreadId = null,
  expectedAutomationId = null,
  confirmReconciliation,
}) {
  if (confirmReconciliation !== true) throw new Error("wake-worker-reconciliation-required");
  const root = await requireRoot(controllerRoot, "controller-root");
  requireId(expectedOperationId, "wake-worker-operation-id");
  if (expectedWorkerThreadId !== null) requireId(expectedWorkerThreadId, "wake-worker-thread-id");
  if (expectedAutomationId !== null) requireId(expectedAutomationId, "wake-automation-id");
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    if (!controller) throw new Error("controller-not-registered");
    const current = controller.wakeWorker;
    if (!current) return { state: "wake-worker-not-registered", controllerRoot: root };
    if (current.operationId !== expectedOperationId || current.workerThreadId !== expectedWorkerThreadId ||
        (current.automation?.automationId ?? null) !== expectedAutomationId) throw new Error("wake-worker-conflict");
    controller.wakeWorker = null;
    return { state: "wake-worker-cleared", controllerRoot: root };
  });
}

export async function registerDispatch({ statePath = defaultStatePath(), controllerRoot, ...input }) {
  const root = await requireRoot(controllerRoot, "controller-root");
  const projectRoot = await requireRoot(input.projectRoot, "project-root");
  const dispatch = validateDispatch({ ...input, projectRoot });
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    if (!controller) throw new Error("controller-not-registered");
    const current = controller.dispatches.find((item) => item.projectTaskId === dispatch.projectTaskId);
    if (current) {
      if (!sameDispatch(current, dispatch)) throw new Error("active-dispatch-conflict");
      return { state: "dispatch-exists", dispatchId: dispatch.dispatchId };
    }
    if (registry.controllers.some((item) => item.dispatches.some((active) => active.dispatchId === dispatch.dispatchId))) {
      throw new Error("dispatch-id-conflict");
    }
    controller.dispatches.push(dispatch);
    return { state: "dispatch-registered", dispatchId: dispatch.dispatchId };
  });
}

export async function unregisterDispatch({
  statePath = defaultStatePath(),
  controllerRoot,
  projectTaskId,
  dispatchId,
  taskSpecHash,
}) {
  const root = await requireRoot(controllerRoot, "controller-root");
  requireId(projectTaskId, "project-task-id");
  requireId(dispatchId, "dispatch-id");
  requireHash(taskSpecHash, "task-spec-hash");
  return mutateRegistry(statePath, async (registry) => {
    const controller = findController(registry, root);
    if (!controller) throw new Error("controller-not-registered");
    const index = controller.dispatches.findIndex((item) => item.projectTaskId === projectTaskId);
    if (index < 0) return { state: "dispatch-not-registered", dispatchId };
    const current = controller.dispatches[index];
    if (current.dispatchId !== dispatchId || current.taskSpecHash !== taskSpecHash) {
      throw new Error("active-dispatch-conflict");
    }
    controller.dispatches.splice(index, 1);
    return { state: "dispatch-unregistered", dispatchId };
  });
}

function validateDispatchEnvelope(dispatchJson) {
  if (typeof dispatchJson !== "string" || dispatchJson.includes("\n") || dispatchJson.includes("\r") ||
      Buffer.byteLength(dispatchJson, "utf8") > 16_384) throw new Error("invalid-dispatch-envelope");
  let envelope;
  try { envelope = JSON.parse(dispatchJson); }
  catch { throw new Error("invalid-dispatch-envelope"); }
  if (!keysEqual(envelope, DISPATCH_ENVELOPE_FIELDS) || envelope.schemaVersion !== 1 ||
      envelope.kind !== "onboard-code-projects.dispatch" || JSON.stringify(envelope) !== dispatchJson ||
      !envelope.taskSpec || typeof envelope.taskSpec !== "object" || Array.isArray(envelope.taskSpec)) {
    throw new Error("invalid-dispatch-envelope");
  }
  requireId(envelope.chainId, "chain-id");
  requireId(envelope.projectTaskId, "project-task-id");
  requireId(envelope.dispatchId, "dispatch-id");
  requireCounter(envelope.generation, "generation");
  requireCounter(envelope.rework, "rework");
  requireHash(envelope.taskSpecHash, "task-spec-hash");
  requireHash(envelope.dispatchHash, "dispatch-hash");
  const identity = envelope.taskSpec.dispatchIdentity;
  if (!keysEqual(identity, DISPATCH_IDENTITY_FIELDS) || DISPATCH_IDENTITY_FIELDS.some(
    (field) => identity[field] !== envelope[field],
  )) throw new Error("dispatch-identity-mismatch");
  if (sha256(JSON.stringify(envelope.taskSpec)) !== envelope.taskSpecHash) {
    throw new Error("task-spec-hash-mismatch");
  }
  const core = {
    schemaVersion: envelope.schemaVersion,
    kind: envelope.kind,
    chainId: envelope.chainId,
    projectTaskId: envelope.projectTaskId,
    dispatchId: envelope.dispatchId,
    generation: envelope.generation,
    rework: envelope.rework,
    taskSpecHash: envelope.taskSpecHash,
    taskSpec: envelope.taskSpec,
  };
  if (sha256(JSON.stringify(core)) !== envelope.dispatchHash) throw new Error("dispatch-hash-mismatch");
  return envelope;
}

export async function verifyDispatch({ statePath = defaultStatePath(), projectRoot, dispatchJson }) {
  const exactProjectRoot = await requireRoot(projectRoot, "project-root");
  const envelope = validateDispatchEnvelope(dispatchJson);
  const registry = await readRegistry(statePath);
  const identityMatches = registry.controllers.flatMap((controller) => controller.dispatches.filter((dispatch) =>
    dispatch.chainId === envelope.chainId && dispatch.projectTaskId === envelope.projectTaskId &&
    dispatch.dispatchId === envelope.dispatchId && dispatch.generation === envelope.generation &&
    dispatch.rework === envelope.rework));
  if (identityMatches.length !== 1) throw new Error("dispatch-not-registered");
  const registered = identityMatches[0];
  if (!samePath(registered.projectRoot, exactProjectRoot)) throw new Error("dispatch-project-root-mismatch");
  if (registered.taskSpecHash !== envelope.taskSpecHash || registered.dispatchHash !== envelope.dispatchHash) {
    throw new Error("dispatch-registry-mismatch");
  }
  return {
    state: "dispatch-verified",
    chainId: envelope.chainId,
    projectTaskId: envelope.projectTaskId,
    dispatchId: envelope.dispatchId,
    taskSpecHash: envelope.taskSpecHash,
    dispatchHash: envelope.dispatchHash,
    projectRoot: exactProjectRoot,
  };
}

export async function readDispatch({ statePath = defaultStatePath(), controllerRoot, projectTaskId }) {
  const { root, controller } = await controllerForRoot(statePath, controllerRoot);
  requireId(projectTaskId, "project-task-id");
  const matches = controller.dispatches.filter((dispatch) => dispatch.projectTaskId === projectTaskId);
  if (matches.length !== 1) throw new Error("dispatch-not-registered");
  return { state: "dispatch-read", controllerRoot: root, dispatch: matches[0] };
}

function validateEnvelope(envelope) {
  if (!keysEqual(envelope, ENVELOPE_FIELDS) || !TERMINAL_STATES.has(envelope.resultState)) {
    throw new Error("invalid-envelope");
  }
  requireId(envelope.chainId, "chain-id");
  requireId(envelope.dispatchId, "dispatch-id");
  requireId(envelope.projectTaskId, "project-task-id");
  requireCounter(envelope.generation, "generation");
  requireCounter(envelope.rework, "rework");
  requireHash(envelope.taskSpecHash, "task-spec-hash");
  if (envelope.failureClass !== "N/A") requireId(envelope.failureClass, "failure-class");
  const requiresFailure = !["completed", "cancelled"].includes(envelope.resultState);
  if (requiresFailure === (envelope.failureClass === "N/A")) throw new Error("invalid-envelope");
  return envelope;
}

export function terminalEnvelope(input) {
  return validateEnvelope(input);
}

function parseEnvelope(message) {
  if (typeof message !== "string" || Buffer.byteLength(message, "utf8") > 1_048_576) return null;
  const firstLine = message.split(/\r?\n/, 1)[0];
  if (!firstLine || Buffer.byteLength(firstLine, "utf8") > 4_096) return null;
  try { return validateEnvelope(JSON.parse(firstLine)); }
  catch { return null; }
}

function receiptPaths(controllerRoot, receiptId) {
  const root = join(controllerRoot, "state", "dispatch-receipts");
  return {
    inbox: join(root, "inbox", `${receiptId}.json`),
    ack: join(root, "ack", `${receiptId}.json`),
    claim: join(root, "claim", `${receiptId}.json`),
    claimLock: join(root, "claim", `${receiptId}.lock`),
  };
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

export async function captureStop({ statePath = defaultStatePath(), input, now = new Date().toISOString() }) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return { state: "ignored" };
  const sessionId = input.session_id;
  const turnId = input.turn_id;
  if (typeof sessionId !== "string" || typeof turnId !== "string" || !ID_RE.test(sessionId) || !ID_RE.test(turnId)) {
    return { state: "ignored" };
  }
  const envelope = parseEnvelope(input.last_assistant_message);
  if (!envelope || envelope.projectTaskId !== sessionId || typeof input.cwd !== "string" || !isAbsolute(input.cwd)) {
    return { state: "ignored" };
  }
  let cwd;
  try {
    cwd = await requireRoot(input.cwd, "cwd");
    requireIso(now, "received-at");
  } catch {
    return { state: "ignored" };
  }
  const registry = await readRegistry(statePath);
  const matches = [];
  for (const controller of registry.controllers) {
    for (const dispatch of controller.dispatches) {
      if (dispatch.projectTaskId === sessionId && samePath(dispatch.projectRoot, cwd) &&
          dispatch.chainId === envelope.chainId && dispatch.dispatchId === envelope.dispatchId &&
          dispatch.generation === envelope.generation && dispatch.rework === envelope.rework &&
          dispatch.taskSpecHash === envelope.taskSpecHash) matches.push({ controller, dispatch });
    }
  }
  if (matches.length !== 1) return { state: "ignored" };
  const evidenceHash = sha256(input.last_assistant_message);
  const receiptId = receiptIdentity(envelope, evidenceHash, turnId);
  const controllerRoot = await requireRoot(matches[0].controller.controllerRoot, "controller-root");
  if (!samePath(controllerRoot, matches[0].controller.controllerRoot)) return { state: "ignored" };
  const receipt = {
    schemaVersion: 1,
    receiptId,
    receivedAt: now,
    sessionId,
    turnId,
    cwd,
    controllerRoot,
    evidenceHash,
    envelope,
  };
  const paths = receiptPaths(controllerRoot, receiptId);
  await mkdir(dirname(paths.inbox), { recursive: true });
  try {
    await writeFile(paths.inbox, `${JSON.stringify(receipt)}\n`, { encoding: "utf8", flag: "wx" });
    return { state: "receipt-recorded", receiptId };
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    return { state: "receipt-exists", receiptId };
  }
}

function validateReceipt(value, controllerRoot, expectedReceiptId) {
  try {
    if (!keysEqual(value, RECEIPT_FIELDS) || value.schemaVersion !== 1 || value.receiptId !== expectedReceiptId ||
        !HASH_RE.test(value.receiptId) || !HASH_RE.test(value.evidenceHash) ||
        typeof value.controllerRoot !== "string" || !samePath(value.controllerRoot, controllerRoot) ||
        typeof value.cwd !== "string" || !isAbsolute(value.cwd)) throw new Error("receipt-invalid");
    requireIso(value.receivedAt, "received-at");
    requireId(value.sessionId, "session-id");
    requireId(value.turnId, "turn-id");
    validateEnvelope(value.envelope);
    if (value.envelope.projectTaskId !== value.sessionId || receiptIdentity(value.envelope, value.evidenceHash, value.turnId) !== value.receiptId) {
      throw new Error("receipt-invalid");
    }
    return value;
  } catch {
    throw new Error("receipt-invalid");
  }
}

async function listPending(controllerRoot) {
  const inbox = join(controllerRoot, "state", "dispatch-receipts", "inbox");
  let entries;
  try {
    entries = await readdir(inbox, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
  if (entries.length > 10_000) throw new Error("receipt-store-too-large");
  const receipts = [];
  for (const entry of entries) {
    if (!entry.isFile() || !/^[0-9a-f]{64}\.json$/.test(entry.name)) continue;
    const receiptId = entry.name.slice(0, -5);
    const paths = receiptPaths(controllerRoot, receiptId);
    try {
      await stat(paths.ack);
      continue;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    const raw = await readFile(paths.inbox, "utf8");
    receipts.push(validateReceipt(JSON.parse(raw), controllerRoot, receiptId));
  }
  receipts.sort((left, right) => left.receivedAt.localeCompare(right.receivedAt) || left.receiptId.localeCompare(right.receiptId));
  return receipts;
}

async function controllerForRoot(statePath, controllerRoot) {
  const root = await requireRoot(controllerRoot, "controller-root");
  const controller = findController(await readRegistry(statePath), root);
  if (!controller) throw new Error("controller-not-registered");
  return { root, controller };
}

export async function readPending({ statePath = defaultStatePath(), controllerRoot }) {
  const { root, controller } = await controllerForRoot(statePath, controllerRoot);
  return {
    state: "receipts-read",
    controllerRoot: root,
    controllerThreadId: controller.controllerThreadId,
    hostId: controller.hostId,
    activeDispatchCount: controller.dispatches.length,
    receipts: await listPending(root),
  };
}

export async function claimPending({
  statePath = defaultStatePath(),
  controllerRoot,
  claimOwnerId = null,
  now = new Date().toISOString(),
  retryAfterMs = 600_000,
}) {
  requireIso(now, "claimed-at");
  if (!Number.isSafeInteger(retryAfterMs) || retryAfterMs < 60_000 || retryAfterMs > 86_400_000) {
    throw new Error("invalid-retry-after");
  }
  const pending = await readPending({ statePath, controllerRoot });
  const ownerId = claimOwnerId ?? pending.controllerThreadId;
  requireId(ownerId, "claim-owner-id");
  const claimed = [];
  for (const receipt of pending.receipts) {
    const paths = receiptPaths(pending.controllerRoot, receipt.receiptId);
    const selected = await withLock(paths.claimLock, async () => {
      let previous = null;
      try { previous = JSON.parse(await readFile(paths.claim, "utf8")); }
      catch (error) { if (error?.code !== "ENOENT") throw error; }
      if (previous) {
        if (keysEqual(previous, LEGACY_CLAIM_FIELDS) && previous.schemaVersion === 1 &&
            previous.receiptId === receipt.receiptId) {
          requireIso(previous.claimedAt, "claimed-at");
          if (Date.parse(now) < Date.parse(previous.claimedAt) + retryAfterMs) return false;
        } else if (keysEqual(previous, CLAIM_FIELDS) && previous.schemaVersion === 2 &&
                   previous.receiptId === receipt.receiptId) {
          requireId(previous.claimOwnerId, "claim-owner-id");
          requireIso(previous.claimedAt, "claimed-at");
          requireIso(previous.leaseUntil, "lease-until");
          if (Date.parse(previous.leaseUntil) <= Date.parse(previous.claimedAt)) throw new Error("receipt-claim-invalid");
          if (Date.parse(now) < Date.parse(previous.leaseUntil)) return false;
        } else {
          throw new Error("receipt-claim-invalid");
        }
      }
      const temporary = `${paths.claim}.${process.pid}.${Date.now()}.tmp`;
      await mkdir(dirname(paths.claim), { recursive: true });
      await writeFile(temporary, `${JSON.stringify({
        schemaVersion: 2,
        receiptId: receipt.receiptId,
        claimOwnerId: ownerId,
        claimedAt: now,
        leaseUntil: addMilliseconds(now, retryAfterMs),
      })}\n`, { flag: "wx" });
      try { await rename(temporary, paths.claim); }
      finally { await rm(temporary, { force: true }); }
      return true;
    });
    if (selected) claimed.push(receipt);
  }
  return { ...pending, state: "receipts-claimed", receipts: claimed };
}

export async function renewClaim({
  statePath = defaultStatePath(),
  controllerRoot,
  receiptId,
  claimOwnerId,
  now = new Date().toISOString(),
  leaseMs = 600_000,
}) {
  requireHash(receiptId, "receipt-id");
  requireId(claimOwnerId, "claim-owner-id");
  requireIso(now, "renewed-at");
  if (!Number.isSafeInteger(leaseMs) || leaseMs < 60_000 || leaseMs > 86_400_000) throw new Error("invalid-lease");
  const { root } = await controllerForRoot(statePath, controllerRoot);
  const paths = receiptPaths(root, receiptId);
  try { await stat(paths.ack); throw new Error("receipt-not-pending"); }
  catch (error) { if (error?.code !== "ENOENT") throw error; }
  validateReceipt(JSON.parse(await readFile(paths.inbox, "utf8")), root, receiptId);
  return withLock(paths.claimLock, async () => {
    let current;
    try { current = JSON.parse(await readFile(paths.claim, "utf8")); }
    catch (error) {
      if (error?.code === "ENOENT") throw new Error("receipt-claim-conflict");
      throw error;
    }
    if (!keysEqual(current, CLAIM_FIELDS) || current.schemaVersion !== 2 || current.receiptId !== receiptId ||
        current.claimOwnerId !== claimOwnerId) throw new Error("receipt-claim-conflict");
    requireIso(current.claimedAt, "claimed-at");
    requireIso(current.leaseUntil, "lease-until");
    const nowMs = Date.parse(now);
    if (nowMs < Date.parse(current.claimedAt) || nowMs >= Date.parse(current.leaseUntil)) {
      throw new Error("receipt-claim-expired");
    }
    const leaseUntil = new Date(Math.max(Date.parse(current.leaseUntil), nowMs + leaseMs)).toISOString();
    const renewed = { ...current, leaseUntil };
    const temporary = `${paths.claim}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(temporary, `${JSON.stringify(renewed)}\n`, { flag: "wx" });
    try { await rename(temporary, paths.claim); }
    finally { await rm(temporary, { force: true }); }
    return { state: "receipt-claim-renewed", receiptId, claimOwnerId, leaseUntil };
  });
}

export async function ackReceipt({
  statePath = defaultStatePath(),
  controllerRoot,
  receiptId,
  acknowledgedAt = new Date().toISOString(),
}) {
  requireHash(receiptId, "receipt-id");
  requireIso(acknowledgedAt, "acknowledged-at");
  const { root } = await controllerForRoot(statePath, controllerRoot);
  const paths = receiptPaths(root, receiptId);
  const receipt = validateReceipt(JSON.parse(await readFile(paths.inbox, "utf8")), root, receiptId);
  await unregisterDispatch({
    statePath,
    controllerRoot: root,
    projectTaskId: receipt.envelope.projectTaskId,
    dispatchId: receipt.envelope.dispatchId,
    taskSpecHash: receipt.envelope.taskSpecHash,
  });
  await mkdir(dirname(paths.ack), { recursive: true });
  try {
    await writeFile(paths.ack, `${JSON.stringify({ schemaVersion: 1, receiptId, acknowledgedAt })}\n`, { flag: "wx" });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
  }
  return { state: "receipt-acknowledged", receiptId };
}

function decodePayload(argv) {
  const index = argv.indexOf("--payload-base64");
  if (index < 0 || !argv[index + 1]) return {};
  const raw = Buffer.from(argv[index + 1], "base64").toString("utf8");
  if (Buffer.byteLength(raw, "utf8") > 1_048_576) throw new Error("payload-too-large");
  const payload = JSON.parse(raw);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("payload-invalid");
  if (Object.hasOwn(payload, "statePath")) throw new Error("payload-state-path-forbidden");
  return payload;
}

function cliStatePath(action, argv) {
  const indexes = argv.flatMap((value, index) => value === "--state-path" ? [index] : []);
  if (WORKER_SAFE_ACTIONS.has(action) && indexes.length !== 0) throw new Error("worker-state-path-forbidden");
  if (indexes.length === 0) return defaultStatePath();
  if (indexes.length !== 1 || !argv[indexes[0] + 1] || argv[indexes[0] + 1].startsWith("--") ||
      !isAbsolute(argv[indexes[0] + 1])) throw new Error("state-path-invalid");
  return resolve(argv[indexes[0] + 1]);
}

async function readStdin() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 1_048_576) throw new Error("hook-input-too-large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function main() {
  const action = process.argv[2] || "capture-stop";
  const argv = process.argv.slice(3);
  const payload = decodePayload(argv);
  const statePath = cliStatePath(action, argv);
  if (action === "capture-stop") {
    try { await captureStop({ statePath, input: await readStdin() }); } catch {}
    return;
  }
  let result;
  if (action === "register-controller") result = await registerController({ ...payload, statePath });
  else if (action === "replace-controller") result = await replaceController({ ...payload, statePath });
  else if (action === "read-wake-worker") result = await readWakeWorker({ ...payload, statePath });
  else if (action === "prepare-wake-worker") result = await prepareWakeWorker({ ...payload, statePath });
  else if (action === "record-wake-worker-client") result = await recordWakeWorkerClientThread({ ...payload, statePath });
  else if (action === "bind-wake-worker") result = await bindWakeWorker({ ...payload, statePath });
  else if (action === "prepare-wake-automation") result = await prepareWakeAutomation({ ...payload, statePath });
  else if (action === "bind-wake-automation") result = await bindWakeAutomation({ ...payload, statePath });
  else if (action === "clear-wake-worker") result = await clearWakeWorker({ ...payload, statePath });
  else if (action === "register-dispatch") result = await registerDispatch({ ...payload, statePath });
  else if (action === "read-dispatch") result = await readDispatch({ ...payload, statePath });
  else if (action === "verify-dispatch") result = await verifyDispatch({ ...payload, statePath });
  else if (action === "unregister-dispatch") result = await unregisterDispatch({ ...payload, statePath });
  else if (action === "read") result = await readPending({ ...payload, statePath });
  else if (action === "claim") result = await claimPending({ ...payload, statePath });
  else if (action === "renew-claim") result = await renewClaim({ ...payload, statePath });
  else if (action === "ack") result = await ackReceipt({ ...payload, statePath });
  else if (action === "terminal-envelope") result = terminalEnvelope(payload);
  else if (action === "verify") result = { state: "runtime-verified", registry: await readRegistry(statePath) };
  else throw new Error("unknown-action");
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

let isMain = false;
if (process.argv[1]) {
  try {
    isMain = samePath(await realpath(resolve(process.argv[1])), await realpath(fileURLToPath(import.meta.url)));
  } catch {}
}
if (isMain) {
  main().catch((error) => {
    process.stderr.write(`${JSON.stringify({ state: "error", reasonCode: error.message })}\n`);
    process.exitCode = 1;
  });
}
