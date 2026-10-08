const mode = Deno.env.get("COVERAGE_MODE") ?? "graceful";
const bin = Deno.env.get("SZANIEC_BIN");
const server = Deno.env.get("COVERAGE_SERVER");
const context = Deno.env.get("SZANIEC_COVERAGE_CONTEXT");
const duneRoot = Deno.env.get("COVERAGE_DUNE_ROOT") ?? Deno.cwd();

if (!bin || !server || !context) {
  console.error("scenario: SZANIEC_BIN, COVERAGE_SERVER, and SZANIEC_COVERAGE_CONTEXT are required");
  Deno.exit(2);
}

const base = 20000 + (Deno.pid % 10000);

type Running = {
  proc: Deno.ChildProcess;
  serverPid: number;
  port: number;
};

const running: Running[] = [];

function fail(message: string): never {
  console.error("scenario: " + message);
  Deno.exit(1);
}

async function readReady(proc: Deno.ChildProcess): Promise<number> {
  const reader = proc.stdout
    .pipeThrough(new TextDecoderStream())
    .getReader();
  let buf = "";
  const drain = async () => {
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
      }
    } catch {
      // The process has already closed its stdout.
    }
  };
  while (true) {
    const next = await reader.read();
    if (next.done) fail("supervise closed before ready:\n" + buf);
    buf += next.value;
    if (buf.includes("ready")) {
      const match = buf.match(/pid (\d+)/);
      if (!match) fail("supervise output has no pid:\n" + buf);
      void drain();
      return Number(match[1]);
    }
  }
}

async function start(port: number): Promise<Running> {
  const proc = new Deno.Command(bin!, {
    args: [
      "coverage",
      "supervise",
      "--port",
      String(port),
      "--pass-env",
      "PORT",
      "--",
      server!,
    ],
    clearEnv: true,
    env: {
      PATH: Deno.env.get("PATH") ?? "",
      HOME: Deno.env.get("HOME") ?? "",
      PORT: String(port),
      SZANIEC_COVERAGE_CONTEXT: context!,
    },
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  const serverPid = await readReady(proc);
  const item = { proc, serverPid, port };
  running.push(item);
  return item;
}

async function get(port: number, path: string): Promise<string> {
  const response = await fetch(`http://127.0.0.1:${port}${path}`);
  const text = await response.text();
  if (!response.ok) fail(`${path} returned ${response.status}: ${text}`);
  return text;
}

async function expectRoutes(port: number): Promise<void> {
  const [health, answer, nested, marker] = await Promise.all([
    get(port, "/health"),
    get(port, "/answer"),
    get(port, "/nested"),
    get(port, "/marker"),
  ]);
  if (health !== "ok") fail("health body " + health);
  if (answer !== "42") fail("answer body " + answer);
  if (nested !== "hello n!") fail("nested body " + nested);
  if (marker !== "marked-by-ppx") fail("marker body " + marker);
}

async function stop(item: Running, signal: "SIGTERM" | "SIGKILL"): Promise<void> {
  const index = running.indexOf(item);
  if (index >= 0) running.splice(index, 1);
  try {
    Deno.kill(item.serverPid, signal);
  } catch (error) {
    fail(`failed to signal server ${item.serverPid}: ${error}`);
  }
  const status = await item.proc.status;
  if (status.code !== 0) {
    fail(`supervise exited ${status.code} after ${signal}`);
  }
}

async function once(port: number): Promise<void> {
  const item = await start(port);
  await expectRoutes(port);
  await stop(item, "SIGTERM");
}

try {
  if (mode === "graceful") {
    const scratch = await Deno.makeTempDir({ prefix: "szaniec-scenario-" });
    try {
      await Deno.writeTextFile(`${scratch}/instance.txt`, "kept outside coverage");
      const first = await start(base);
      const second = await start(base + 1);
      await Promise.all([expectRoutes(first.port), expectRoutes(second.port)]);
      await Deno.remove(scratch, { recursive: true });
      await stop(first, "SIGTERM");
      const restarted = await start(base + 2);
      await expectRoutes(restarted.port);
      await stop(second, "SIGTERM");
      await stop(restarted, "SIGTERM");
    } finally {
      try {
        await Deno.remove(scratch, { recursive: true });
      } catch {
        // Already removed after the requests.
      }
    }
  } else if (mode === "once") {
    await once(base + 10);
  } else if (mode === "forced") {
    const item = await start(base + 20);
    const health = await get(item.port, "/health");
    if (health !== "ok") fail("health body " + health);
    await stop(item, "SIGKILL");
  } else if (mode === "stale") {
    const marker = `${duneRoot}/test/fixtures/coverage-app/lib/core/stale_marker.ml`;
    await Deno.writeTextFile(marker, "let stale_marker () = 1\n");
    await once(base + 30);
  } else {
    fail("unknown COVERAGE_MODE " + mode);
  }
} finally {
  for (const item of running.splice(0)) {
    try {
      Deno.kill(item.serverPid, "SIGKILL");
    } catch {
      // The server has already exited.
    }
    try {
      await item.proc.status;
    } catch {
      // Status was already collected.
    }
  }
}
