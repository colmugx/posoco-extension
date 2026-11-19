import { test, expect } from "bun:test";
import { createServer, connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { observeSessionSocket, serveSessionSocket, type SessionEvent } from "./bridge";

function endpoint(): string {
  const id = randomUUID().replaceAll("-", "");
  return process.platform === "win32"
    ? "\\\\.\\pipe\\posoco-session-test-" + id
    : join(tmpdir(), "posoco-session-test-" + id + ".sock");
}

function frame(type: string, cursor: number, busy: boolean): SessionEvent {
  return {
    type, session_id: "session-1", runtime_epoch: "epoch-1",
    cursor, high_water_cursor: cursor,
    cursor_advance: type !== "session.snapshot", busy,
    ...(type === "assistant.text_delta" ? { delta: "hello" } : {}),
  };
}

test("Go↔Bun wire contract: joining working Session receives snapshot and original live deltas", async () => {
  const path = endpoint();
  const server = createServer((socket) => {
    void serveSessionSocket(socket, { instanceID: "owner-js", runtimeEpoch: "epoch-1" },
      async (sessionID) => {
        if (sessionID !== "session-1") throw new Error("session is not owned");
        return {
          snapshot: frame("session.snapshot", 4, true),
          events: (async function* () {
            yield frame("assistant.text_delta", 5, true);
            yield frame("turn.completed", 6, false);
          })(),
          close() {},
        };
      }).catch(() => {});
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  let client: Socket | undefined;
  try {
    client = connect(path);
    await once(client, "connect");
    const observer = await observeSessionSocket(client, "session-1", "client-go");
    expect(observer.snapshot.busy).toBe(true);
    expect(observer.owner.runtimeEpoch).toBe("epoch-1");
    const stream = observer.events()[Symbol.asyncIterator]();
    const first = await stream.next();
    expect(first.value?.type).toBe("assistant.text_delta");
    expect(first.value?.delta).toBe("hello");
    const second = await stream.next();
    expect(second.value?.type).toBe("turn.completed");
    observer.close();
  } finally {
    client?.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("unowned Session is explicitly rejected, never composed", async () => {
  const path = endpoint();
  let composed = 0;
  const server = createServer((socket) => {
    void serveSessionSocket(socket, { instanceID: "owner-js", runtimeEpoch: "epoch-1" },
      async () => {
        composed++;
        throw new Error("unowned Session");
      }).catch(() => {});
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  const client = connect(path);
  await once(client, "connect");
  try {
    await expect(observeSessionSocket(client, "foreign", "viewer")).rejects.toThrow();
    expect(composed).toBe(1);
  } finally {
    client.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
