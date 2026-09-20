// Minimal MCP stdio server for the js end-to-end test: newline-delimited
// JSON-RPC over stdin/stdout. Speaks the stateless modern protocol
// (server/discover + tools/list + tools/call) so the client takes its
// modern path — the legacy fallback is not implemented on js.
//
// Both knobs below default off, so the legacy surface is byte-identical:
// - MCP_FIXTURE_RESILIENCE=1 advertises two extra tools: `sleep` (delays
//   `ms` ms, default 1000, then answers "slept <ms>ms") for timeout tests,
//   and `exit` (answers success, then process.exit(0) 50ms later so the
//   client sees the reply before stream EOF) for kill/reconnect tests.
// - MCP_FIXTURE_NOTIFICATION_LOG=<path> appends every received notification
//   (message without an id) to that file as one JSON line per message;
//   append failures are silently ignored.
// - MCP_FIXTURE_FLAKY=N with MCP_FIXTURE_FLAKY_STATE=<path>: the first N
//   initialize attempts (counted across process restarts in the state file)
//   are rejected by exiting without a reply — the client observes stream EOF
//   and the connect fails — and later attempts serve normally. Without the
//   pair the surface is untouched.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import readline from "node:readline";

const RESILIENCE = process.env.MCP_FIXTURE_RESILIENCE === "1";
const NOTIFICATION_LOG = process.env.MCP_FIXTURE_NOTIFICATION_LOG;
const FLAKY = Number(process.env.MCP_FIXTURE_FLAKY || "0");
const FLAKY_STATE = process.env.MCP_FIXTURE_FLAKY_STATE;

const rl = readline.createInterface({ input: process.stdin });

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function logNotification(msg) {
  if (!NOTIFICATION_LOG) return;
  try {
    appendFileSync(NOTIFICATION_LOG, JSON.stringify(msg) + "\n");
  } catch {}
}

// Cross-process attempt counter for the flaky gate; returns the attempt
// number of this initialize (1-based). Read/write failures degrade to
// "always attempt 1".
function bumpFlakyAttempt() {
  let count = 0;
  try {
    count = Number(readFileSync(FLAKY_STATE, "utf8").trim() || "0");
  } catch {}
  count += 1;
  try {
    writeFileSync(FLAKY_STATE, String(count));
  } catch {}
  return count;
}

rl.on("line", (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  const { id, method, params } = msg;
  if (id === undefined || id === null) {
    logNotification(msg); // e.g. notifications/cancelled
    return; // notification
  }
  switch (method) {
    case "server/discover":
      if (FLAKY > 0 && FLAKY_STATE && bumpFlakyAttempt() <= FLAKY) {
        // Reject this initialize attempt by dying without a reply: the
        // client observes stream EOF and the connect fails.
        process.exit(1);
      }
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: "2026-07-28",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "echo", version: "1.0.0" },
        },
      });
      break;
    case "tools/list":
      send({
        jsonrpc: "2.0",
        id,
        result: {
          tools: [
            {
              name: "echo",
              description: "Echo the arguments back as text.",
              inputSchema: { type: "object", properties: {} },
            },
            {
              // Deliberately dirty schema: every keyword here is outside
              // the Kernel's supported subset. The bridge must sanitize it
              // (drop the constraints, keep the shape) or the whole catalog
              // refresh is rejected.
              name: "dirty",
              description: "Tool with an off-subset schema.",
              inputSchema: {
                type: "object",
                properties: {
                  q: {
                    anyOf: [{ type: "string" }, { type: "number" }],
                    minLength: 1,
                    format: "uri",
                  },
                  n: { type: "integer", minimum: 0, maximum: 10 },
                },
                required: ["q"],
                additionalProperties: false,
                $defs: { x: { type: "string" } },
              },
            },
            ...(RESILIENCE
              ? [
                  {
                    name: "sleep",
                    description: "Sleep `ms` ms (default 1000), then succeed.",
                    inputSchema: {
                      type: "object",
                      properties: { ms: { type: "integer" } },
                    },
                  },
                  {
                    name: "exit",
                    description: "Reply once, then terminate the server.",
                    inputSchema: { type: "object", properties: {} },
                  },
                ]
              : []),
          ],
        },
      });
      break;
    case "tools/call":
      if (RESILIENCE && params?.name === "sleep") {
        const requested = params?.arguments?.ms;
        const ms =
          typeof requested === "number" && Number.isFinite(requested) && requested >= 0
            ? requested
            : 1000;
        setTimeout(() => {
          send({
            jsonrpc: "2.0",
            id,
            result: {
              content: [{ type: "text", text: "slept " + ms + "ms" }],
              isError: false,
            },
          });
        }, ms);
        break;
      }
      if (RESILIENCE && params?.name === "exit") {
        // Answer first, then die: the client observes a successful tools/call
        // followed by stream EOF — the deterministic way to trigger
        // "connection closed" for reconnect tests.
        send({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{ type: "text", text: "exiting" }],
            isError: false,
          },
        });
        setTimeout(() => process.exit(0), 50);
        break;
      }
      send({
        jsonrpc: "2.0",
        id,
        result: {
          content: [
            {
              type: "text",
              text: "echo:" + JSON.stringify(params?.arguments ?? {}),
            },
          ],
          isError: false,
        },
      });
      break;
    default:
      send({ jsonrpc: "2.0", id, error: { code: -32601, message: "unknown method " + method } });
  }
});
