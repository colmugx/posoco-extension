import assert from "node:assert/strict";
import test from "node:test";
import { access } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { PiPackageHost } from "../host.ts";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const adaptorModuleUrl = pathToFileURL(await findBuiltModule()).href;
const fixtureRoot = fileURLToPath(new URL("./fixture/", import.meta.url));

async function loadHost(options = {}) {
  const host = await PiPackageHost.fromModuleUrl(adaptorModuleUrl, {
    cwd: packageRoot,
    ...options,
  });
  const loaded = await host.loadPackage(fixtureRoot);
  await host.startSession();
  return { host, loaded };
}

test("loads all package entries and emits session_start once", async () => {
  const { host, loaded } = await loadHost();

  assert.equal(loaded.name, "pi-adaptor-test-fixture");
  assert.deepEqual(loaded.extensions, ["./index.mjs", "./second.mjs"]);
  assert.equal(loaded.registeredTools, 5);
  assert.deepEqual(host.catalog().map((tool) => tool.name), [
    "echo",
    "delayed_echo",
    "cancellable_echo",
    "background_notify",
    "constrained_echo",
  ]);

  const starts = host.entries().filter((entry) => entry.customType === "fixture-session-start");
  assert.deepEqual(starts.map((entry) => entry.data.entry), ["primary", "secondary"]);
});

test("uses an untrusted headless context by default", async () => {
  const { host } = await loadHost();
  const result = await host.execute("echo", "echo-default-trust", { text: "hello" });

  assert.equal(result.ok, true);
  assert.equal(result.content, "echo:hello");
  assert.equal(result.details.projectTrusted, false);
  assert.equal(result.details.cwd, packageRoot);

  const updates = host.takeUpdates();
  assert.equal(updates.length, 1);
  assert.equal(updates[0].callId, "echo-default-trust");
  assert.equal(updates[0].name, "echo");
});

test("allows the embedding host to opt into project trust", async () => {
  const { host } = await loadHost({ projectTrusted: true });
  const result = await host.execute("echo", "echo-trusted", { text: "trusted" });
  assert.equal(result.details.projectTrusted, true);
});

test("awaits Pi promises through the MoonBit runtime bridge", async () => {
  const { host } = await loadHost();
  const outcome = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("runtime bridge timed out")), 2_000);
    host.module.pi_adaptor_execute_effect_via_runtime(
      host.adaptor,
      501,
      "delayed_echo",
      "runtime-call-501",
      JSON.stringify({ text: "runtime" }),
      (json) => {
        clearTimeout(timeout);
        resolve(JSON.parse(json));
      },
    );
  });

  assert.equal(outcome.kind, "Success");
  assert.equal(outcome.content, "delayed:runtime");
  assert.equal(outcome.structured.async, true);
  assert.deepEqual(host.cancelEffects([501], { kind: "HostRequested" }), [
    { effectId: 501, disposition: "AlreadySettled" },
  ]);
});

test("correlates cancellation by Posoco EffectId", async () => {
  const { host } = await loadHost();
  const execution = host.executeEffect(601, "cancellable_echo", "cancel-call-601", {
    text: "cancel me",
  });
  await waitFor(() => host.inflightCount() === 1);

  assert.deepEqual(host.cancelEffects([601, 999], {
    kind: "HostRequested",
    detail: "test cancellation",
  }), [
    { effectId: 601, disposition: "Propagated" },
    { effectId: 999, disposition: "NotPropagated" },
  ]);

  const result = await execution;
  assert.equal(result.ok, false);
  assert.equal(result.cancelled, true);
  assert.equal(host.inflightCount(), 0);
});

test("records follow-ups and refreshes the dynamic catalog", async () => {
  const { host } = await loadHost();
  const before = host.catalogSnapshot();
  assert.equal(before.version, 5);

  const queued = await host.execute("background_notify", "background-1", { text: "ready" });
  assert.equal(queued.ok, true);
  assert.equal(queued.details.queuedFollowUp, true);
  assert.equal(host.takeFollowUps().length, 1);

  assert.equal(await host.emit("session_tree"), 1);
  const after = host.catalogSnapshot();
  assert.equal(after.version, 6);
  assert.equal(after.tools.some((tool) => tool.name === "late_echo"), true);

  const dynamic = await host.execute("late_echo", "late-1", { text: "registered" });
  assert.equal(dynamic.content, "late:registered");
});

test("projects unsupported schema keywords out of the Posoco-visible catalog", async () => {
  const { host } = await loadHost();

  const tool = host.catalog().find((entry) => entry.name === "constrained_echo");
  const params = tool.parameters;

  // TypeBox numeric constraints are stripped...
  assert.equal("minimum" in params.properties.count, false);
  assert.equal("maximum" in params.properties.count, false);
  assert.equal("default" in params.properties.count, false);
  assert.equal(params.properties.count.type, "number");
  assert.equal(params.properties.count.description, "Echo repeat count");
  // ...anyOf unions collapse to an unconstrained but present parameter...
  assert.equal("anyOf" in params.properties.mode, false);
  assert.equal(params.properties.mode.description, "Optional echo mode");
  // ...string/array constraints vanish at every nesting level...
  assert.equal("minLength" in params.properties.text, false);
  assert.equal(params.properties.text.type, "string");
  assert.equal("minItems" in params.properties.tags, false);
  assert.equal("maxItems" in params.properties.tags, false);
  assert.equal("minLength" in params.properties.tags.items, false);
  assert.equal(params.properties.tags.items.type, "string");
  // ...and the supported skeleton survives intact.
  assert.deepEqual(params.required, ["text"]);
  assert.equal(params.additionalProperties, false);

  // The tool still executes end-to-end; validation authority stays Pi-side.
  const result = await host.execute("constrained_echo", "constrained-1", {
    text: "hi",
    count: 2,
    mode: null,
  });
  assert.equal(result.ok, true);
  assert.equal(result.content, "hi|hi");
  assert.equal(result.details.mode, null);
});

async function waitFor(predicate, timeoutMs = 1_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
}

async function findBuiltModule() {
  const relative = join(
    "_build",
    "js",
    "debug",
    "build",
    "colmugx",
    "posoco-ext-pi-adaptor",
    "posoco-ext-pi-adaptor.js",
  );
  const candidates = [
    join(packageRoot, relative),
    join(dirname(packageRoot), relative),
    join(dirname(dirname(packageRoot)), relative),
  ];
  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next workspace layout.
    }
  }
  throw new Error(`cannot find built adaptor module; checked ${candidates.join(", ")}`);
}
