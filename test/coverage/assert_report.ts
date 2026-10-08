const mode = Deno.args[0];
const path = Deno.args[1];
if (!mode || !path) {
  console.error("usage: assert_report.ts <graceful|forced|gap|stale> <report.json>");
  Deno.exit(2);
}

const report = JSON.parse(await Deno.readTextFile(path));
const text = JSON.stringify(report);

function fail(message: string): never {
  console.error("report: " + message);
  console.error(text);
  Deno.exit(1);
}

if (text.toLowerCase().includes("bisect")) {
  fail("report names the internal points engine");
}

if (report.format !== "szaniec-coverage/1") fail("format " + report.format);
if (report.measurementWindow !== "process") fail("window " + report.measurementWindow);
if (report.coverageKind !== "point") fail("kind " + report.coverageKind);
if (report.denominator !== "instrumented-points") {
  fail("denominator " + report.denominator);
}
if (report.facade !== "szaniec-instrumentation/1") fail("facade " + report.facade);
if (!String(report.compiler).startsWith("5.4")) fail("compiler " + report.compiler);

const exclusions = report.exclusions ?? [];
for (const name of [
  "action-preprocessors",
  "class-methods",
  "mli-interfaces",
  "mlx-dialect",
  "not-branch-coverage",
]) {
  if (!exclusions.includes(name)) fail("missing exclusion " + name);
}

const engines = report.engines ?? [];
const points = engines.find((engine: { name: string }) => engine.name === "points");
const probe = engines.find((engine: { name: string }) => engine.name === "probe");
if (!points || points.version !== "szaniec-points/1" || points.kind !== "point") {
  fail("points engine missing");
}
if (!probe || probe.version !== "szaniec-probe/1" || probe.kind !== "visit") {
  fail("probe engine missing");
}

const gaps = report.gaps ?? [];
const codes = gaps.map((gap: { code: string }) => gap.code);

function requireCode(code: string) {
  if (!codes.includes(code)) fail("missing gap " + code);
}

if (mode === "graceful") {
  if (report.status !== "complete") fail("status " + report.status);
  if (report.scenario?.status !== "passed") fail("scenario " + report.scenario?.status);
  if (gaps.length !== 0) fail("unexpected gaps");
  if (!(probe.visits > 0)) fail("probe visits " + probe.visits);
  if (!(report.summary?.pointsTotal > 0)) fail("no points");
  const functions = report.functions ?? [];
  const named = (name: string) =>
    functions.filter((fn: { name: string }) => fn.name === name);
  const unused = named("unused")[0];
  const answer = named("answer")[0];
  const inner = named("inner")[0];
  const suffix = named("suffix")[0];
  const anonymous = functions.find((fn: { kind: string }) => fn.kind === "anonymous");
  if (!unused) fail("unused function missing");
  if (unused.measurement !== "measured" || unused.executed !== false) {
    fail("unused was not measured-unexecuted");
  }
  if (!(unused.points?.total > 0) || unused.points?.covered !== 0) {
    fail("unused points are not a measured zero");
  }
  if (unused.crap?.status !== "available" || unused.crap?.score !== "2.00") {
    fail("unused CRAP " + JSON.stringify(unused.crap));
  }
  if (!answer || answer.kind !== "function") fail("answer missing");
  if (answer.crap?.reason !== "complexity-missing") {
    fail("answer CRAP should stay unavailable without complexity");
  }
  if (!inner || inner.kind !== "local") fail("inner is not a local function");
  if (!suffix || suffix.kind !== "local") fail("suffix is not a local function");
  if (!anonymous) fail("anonymous function missing");
  const nodes = report.nodes ?? [];
  if (nodes.length < 3) fail("expected a restart and a second instance");
  for (const node of nodes) {
    if (node.disposition !== "exited" || node.code !== 0 || !(node.records > 0)) {
      fail("node did not flush: " + JSON.stringify(node));
    }
  }
} else if (mode === "forced") {
  if (report.status !== "incomplete") fail("status " + report.status);
  if (report.scenario?.status !== "passed") fail("scenario " + report.scenario?.status);
  requireCode("COVERAGE-FORCED-TERMINATION");
} else if (mode === "gap") {
  if (report.status !== "incomplete") fail("status " + report.status);
  if (report.scenario?.status !== "passed") fail("scenario " + report.scenario?.status);
  requireCode("COVERAGE-MISSING-HOOK");
} else if (mode === "stale") {
  if (report.status !== "incomplete") fail("status " + report.status);
  if (report.scenario?.status !== "passed") fail("scenario " + report.scenario?.status);
  requireCode("COVERAGE-STALE-SNAPSHOT");
} else {
  fail("unknown mode " + mode);
}

console.log("report " + mode + ": ok");
