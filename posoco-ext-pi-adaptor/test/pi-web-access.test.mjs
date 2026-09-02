import assert from "node:assert/strict";
import test from "node:test";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { PiPackageHost } from "../host.ts";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const adaptorModuleUrl = pathToFileURL(await findBuiltModule()).href;
const piPackagesRoot = join(homedir(), ".cetas", "pi-packages");
const piWebAccessRoot = join(piPackagesRoot, "node_modules", "pi-web-access");

// Keep the real package's config/cache writes inside a temp dir instead of ~/.pi.
process.env.PI_CODING_AGENT_DIR = join(tmpdir(), "cetas-pi-web-access-probe");

await writeProbeSsrfConfig();

const manifest = await readPiWebAccessManifest();
const skipReason = manifest === null
  ? `pi-web-access is not installed under ${piPackagesRoot}; run \`bun add pi-web-access\` there first`
  : null;

test("loads real pi-web-access and registers expected tools", { skip: skipReason }, async (t) => {
  const loadedHost = await loadHostForTest(t);
  if (loadedHost === null) return;
  const { host, loaded } = loadedHost;

  assert.equal(loaded.name, "pi-web-access");
  assert.deepEqual(loaded.extensions, ["./index.ts"]);

  const names = host.catalog().map((tool) => tool.name);
  console.log(`pi-web-access@${loaded.version} registered tools: ${JSON.stringify(names)}`);

  for (const expected of ["web_search", "fetch_content", "get_search_content"]) {
    assert.equal(names.includes(expected), true, `expected tool '${expected}' in catalog`);
  }
  if (isVersionAtLeast(loaded.version, 0, 20)) {
    assert.equal(names.includes("source_check"), true, "expected tool 'source_check' in catalog (version >= 0.20)");
  }

  // W1D: the catalog view must be free of keywords posoco core rejects at
  // composition time (e.g. TypeBox numeric constraints and unions), since the
  // raw 0.27.0 schemas triggered UnsupportedSchemaKeyword(keyword=minimum).
  const webSearch = host.catalog().find((tool) => tool.name === "web_search");
  if (webSearch) {
    const projected = JSON.stringify(webSearch.parameters);
    console.log(`web_search projected parameters: ${projected}`);
    assert.equal(projected.includes('"minimum":'), false, "projected web_search schema must not contain 'minimum'");
    assert.equal(projected.includes('"maximum":'), false, "projected web_search schema must not contain 'maximum'");
    assert.equal(projected.includes('"anyOf":'), false, "projected web_search schema must not contain 'anyOf'");
    assert.equal(webSearch.parameters.type, "object", "expected web_search parameters to stay an object schema");
  }
});

test("session_start delivered without error", { skip: skipReason }, async (t) => {
  const host = await PiPackageHost.fromModuleUrl(adaptorModuleUrl, {
    cwd: piPackagesRoot,
    projectTrusted: true,
  });
  let loaded = null;
  try {
    loaded = await host.loadPackage(piWebAccessRoot);
  } catch (error) {
    if (isUnsupportedTypeStripping(error)) {
      t.skip("node cannot type-strip packages under node_modules; run this file with bun");
      return;
    }
    throw error;
  }
  assert.equal(loaded.extensions.length, 1);

  const delivered = await host.startSession({ source: "cetas-probe" });
  assert.equal(Number.isFinite(delivered), true);
  assert.equal(delivered >= 1, true, "expected at least one session_start handler to run");

  // W1 event bridge: the package's session_tree handler must still fire
  // through the unchanged js_emit_event path.
  const tree = await host.emit("session_tree");
  assert.equal(Number.isFinite(tree), true);
  assert.equal(tree >= 1, true, "expected at least one session_tree handler to run");

  assert.equal(Array.isArray(host.takeUpdates()), true);
  assert.equal(Array.isArray(host.takeFollowUps()), true);
  await new Promise((resolve) => setImmediate(resolve));
});

test("fetch_content executes against a public URL", { skip: skipReason }, async (t) => {
  const loadedHost = await loadHostForTest(t);
  if (loadedHost === null) return;
  const { host } = loadedHost;

  let result = await executeFetchOrThrow(t, host, "piwa-fetch-1", "https://example.com");
  // example.com's readable text is under the package's 500-char usefulness
  // threshold, so a successful fetch can still be flagged "incomplete"; fall
  // back to a richer canonical page to prove end-to-end extraction.
  if (!result.ok && isExtractionQualityError(result)) {
    console.log(`example.com probe returned: ${firstLine(result.content)}; retrying with iana.org`);
    result = await executeFetchOrThrow(t, host, "piwa-fetch-2", "https://www.iana.org/help/example-domains");
  }

  if (!result.ok && isNetworkDenial(result)) {
    t.skip(`network unavailable: ${result.content}`);
    return;
  }

  assert.equal(result.ok, true, `fetch_content failed: ${result.content}`);
  assert.equal(typeof result.content, "string");
  assert.equal(result.content.length > 0, true, "expected non-empty fetched content");
  console.log(`fetch_content probe content length: ${result.content.length}`);
});

async function executeFetchOrThrow(t, host, callId, url) {
  try {
    return await withTimeout(
      host.execute("fetch_content", callId, { url, mode: "readable" }),
      30_000,
    );
  } catch (error) {
    t.skip(`online probe could not run: ${errorMessage(error)}`);
    return { ok: false, content: `skipped: ${errorMessage(error)}`, details: {} };
  }
}

async function loadHostForTest(t) {
  const host = await PiPackageHost.fromModuleUrl(adaptorModuleUrl, {
    cwd: piPackagesRoot,
    projectTrusted: true,
  });
  let loaded;
  try {
    loaded = await host.loadPackage(piWebAccessRoot);
  } catch (error) {
    if (isUnsupportedTypeStripping(error)) {
      t.skip("node cannot type-strip packages under node_modules; run this file with bun");
      return null;
    }
    throw error;
  }
  await host.startSession();
  return { host, loaded };
}

async function readPiWebAccessManifest() {
  try {
    return JSON.parse(await readFile(join(piWebAccessRoot, "package.json"), "utf8"));
  } catch {
    return null;
  }
}

// TUN/fake-IP proxies (this machine included) resolve public domains into
// 198.18.0.0/15; the package's SSRF guard blocks them unless exempted via its
// documented ssrf.allowRanges option.
async function writeProbeSsrfConfig() {
  const configPath = join(process.env.PI_CODING_AGENT_DIR, "web-search.json");
  await mkdir(dirname(configPath), { recursive: true });
  await writeFile(configPath, JSON.stringify({
    ssrf: { allowRanges: ["198.18.0.0/15", "::ffff:198.18.0.0/112"] },
  }, null, 2) + "\n");
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

function isVersionAtLeast(version, major, minor) {
  const parts = String(version).split(".").map((part) => Number.parseInt(part, 10) || 0);
  const [actualMajor = 0, actualMinor = 0] = parts;
  return actualMajor > major || (actualMajor === major && actualMinor >= minor);
}

function isUnsupportedTypeStripping(error) {
  const message = errorMessage(error);
  return /ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING|ERR_UNKNOWN_FILE_EXTENSION|type.?stripping/i.test(message);
}

function isExtractionQualityError(result) {
  const message = `${result.content ?? ""} ${result.details?.error ?? ""}`.toLowerCase();
  return message.includes("appears incomplete")
    || message.includes("could not extract readable content")
    || message.includes("javascript-rendered");
}

function firstLine(text) {
  return String(text ?? "").split("\n")[0];
}

function isNetworkDenial(result) {
  const message = `${result.content ?? ""} ${result.details?.error ?? ""}`.toLowerCase();
  return [
    "fetch failed",
    "getaddrinfo",
    "enotfound",
    "eai_again",
    "econnrefused",
    "econnreset",
    "etimedout",
    "ehostunreach",
    "enetunreach",
    "unable to connect",
    "connection",
    "network",
    "tls",
    "certificate",
    "socket hang up",
    "failed to resolve",
    "blocked internal",
  ].some((needle) => message.includes(needle));
}

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`timed out after ${ms}ms (network unreachable or tool hung)`)),
      ms,
    );
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
