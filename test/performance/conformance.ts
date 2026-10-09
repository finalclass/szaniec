const decoder = new TextDecoder();
const repo = Deno.cwd();

function option(name: string, fallback?: string): string | undefined {
  const index = Deno.args.indexOf(name);
  if (index < 0) return fallback;
  const value = Deno.args[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${name} needs a value`);
  }
  return value;
}

const baseline = option("--baseline");
if (!baseline) {
  throw new Error("Pass --baseline <git-ref> from before the change");
}
const runs = Number(option("--runs", "3"));
const size = Number(option("--size", "2000"));
const timeCommand = option("--time-command", "time")!;
const evaluationOnly = Deno.args.includes("--evaluation-only");
if (
  !Number.isInteger(runs) || runs < 1 || !Number.isInteger(size) || size < 1
) {
  throw new Error("--runs and --size must be positive integers");
}

async function command(program: string, args: string[], cwd = repo) {
  return await new Deno.Command(program, {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
}

async function required(program: string, args: string[], cwd = repo) {
  const result = await command(program, args, cwd);
  if (!result.success) {
    throw new Error(
      `${program} failed (${result.code}): ${decoder.decode(result.stderr)}`,
    );
  }
  return decoder.decode(result.stdout);
}

function replaceOnce(source: string, from: string, to: string) {
  if (source.split(from).length !== 2) throw new Error(`Expected one ${from}`);
  return source.replace(from, to);
}

function instrument(source: string) {
  if (Deno.args.includes("--collect-between-stages")) {
    for (const marker of ["  (* 3. interpret *)\n", "  (* 4. evaluate *)\n"]) {
      source = replaceOnce(source, marker, `  Gc.full_major () ;\n${marker}`);
    }
  }
  source = replaceOnce(
    source,
    "  let violations =\n",
    "  let benchmark_started = Unix.gettimeofday () in\n  let benchmark_allocated = Gc.allocated_bytes () in\n  let violations =\n",
  );
  source = replaceOnce(
    source,
    "  let callgraph = build_callgraph ~cy ~observation ~interpretation in\n",
    '  Printf.eprintf "SZANIEC_BENCH evaluation=%.9f allocation=%.0f units=%d paths=%d calls=%d\\n%!"\n    (Unix.gettimeofday () -. benchmark_started)\n    (Gc.allocated_bytes () -. benchmark_allocated)\n    (List.length observation.Observation.units)\n    (List.length observation.Observation.exec_paths)\n    (List.length observation.Observation.calls) ;\n  let callgraph = build_callgraph ~cy ~observation ~interpretation in\n',
  );
  if (Deno.args.includes("--collect-between-stages")) {
    source = replaceOnce(
      source,
      "  let callgraph = build_callgraph ~cy ~observation ~interpretation in\n",
      "  Gc.full_major () ;\n  let callgraph = build_callgraph ~cy ~observation ~interpretation in\n  Gc.full_major () ;\n",
    );
  }
  return source;
}

async function copySources(destination: string) {
  const paths = (await required("git", [
    "ls-files",
    "--cached",
    "--others",
    "--exclude-standard",
    "-z",
  ])).split("\0").filter(Boolean);
  for (const path of new Set(paths)) {
    const target = `${destination}/${path}`;
    await Deno.mkdir(target.slice(0, target.lastIndexOf("/")), {
      recursive: true,
    });
    await Deno.copyFile(`${repo}/${path}`, target);
    await Deno.chmod(
      target,
      (await Deno.stat(`${repo}/${path}`)).mode! & 0o777,
    );
  }
}

async function seedBuild(destination: string) {
  try {
    await Deno.stat(`${destination}/_build`);
    return;
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  try {
    await Deno.stat(`${repo}/_build`);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return;
    throw error;
  }
  await required("cp", [
    "-a",
    "--reflink=auto",
    `${repo}/_build`,
    `${destination}/_build`,
  ]);
}

type Sample = {
  evaluationSeconds: number;
  fullSeconds: number;
  peakKiB: number;
  evaluationAllocatedBytes: number;
};
type Output = { code: number; report: Uint8Array; graph: Uint8Array };

function equal(a: Uint8Array, b: Uint8Array) {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}

function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

const temporary = await Deno.makeTempDir({
  prefix: "szaniec-conformance-benchmark-",
});
try {
  const builds = [`${temporary}/baseline`, `${temporary}/indexed`];
  const enginePath = "lib/conformance_engine/conformance_engine.ml";
  const managerPath = "lib/inspection_manager/inspection_manager.ml";
  const baselineEngine = await required("git", [
    "show",
    `${baseline}:${enginePath}`,
  ]);
  for (const [i, build] of builds.entries()) {
    console.log(`Preparing ${i === 0 ? baseline : "working tree"} evaluator`);
    await copySources(build);
    await seedBuild(build);
    if (i === 0) {
      await Deno.writeTextFile(`${build}/${enginePath}`, baselineEngine);
    }
    await Deno.writeTextFile(
      `${build}/${managerPath}`,
      instrument(await Deno.readTextFile(`${build}/${managerPath}`)),
    );
    if (evaluationOnly) {
      const adapterPath = `${build}/lib/interpretation_engine/well_adapter.ml`;
      const adapter = await Deno.readTextFile(adapterPath);
      const marker = "~execution:obs.execution";
      if (adapter.split(marker).length !== 3) {
        throw new Error("Expected two graph execution projections");
      }
      await Deno.writeTextFile(
        adapterPath,
        adapter.replaceAll(marker, "~execution:Observation.empty_execution"),
      );
    }
    await required("dune", [
      "build",
      evaluationOnly ? "test/performance/evaluation.exe" : "bin/szaniec.exe",
    ], build);
  }

  const fixture = `${temporary}/fixture`;
  await required("cp", ["-R", `${repo}/test/fixtures/tasks-app`, fixture]);
  await seedBuild(fixture);
  const functions = Array.from(
    { length: size },
    (_, i) =>
      `let leaf_${i} () = Task_manager.list ~ctx:ctx_w ~limit:10\n` +
      `let middle_${i} () = leaf_${i} ()\n` +
      `let helper_${i} () = middle_${i} ()\n` +
      `let entry_${i} () = helper_${i} ()\n`,
  ).join("\n");
  await Deno.writeTextFile(
    `${fixture}/lib/web_client/tasks_page.ml`,
    functions,
    { append: true },
  );
  await required("dune", ["build"], fixture);

  const projects = [{
    label: "synthetic",
    root: fixture,
    config: "szaniec.toml",
  }];
  const projectRoot = option("--project-root");
  if (projectRoot) {
    projects.push({
      label: "application",
      root: await Deno.realPath(projectRoot),
      config: option("--config", "szaniec.toml")!,
    });
  }
  for (const project of projects) {
    let reference: Output | undefined;
    const samples: Sample[][] = [[], []];
    for (let run = 0; run < runs; run++) {
      const order = run % 2 ? [1, 0] : [0, 1];
      for (const i of order) {
        const graphPath = `${temporary}/graph.json`;
        const started = performance.now();
        const args = evaluationOnly
          ? [
            `${builds[i]}/_build/default/test/performance/evaluation.exe`,
            project.root,
            project.config,
          ]
          : [
            `${builds[i]}/_build/default/bin/szaniec.exe`,
            "check",
            "--project-root",
            project.root,
            "--config",
            project.config,
            "--json",
            "--out",
            graphPath,
          ];
        const result = await command(timeCommand, [
          "-f",
          "SZANIEC_PEAK %M",
          ...args,
        ]);
        const fullSeconds = (performance.now() - started) / 1000;
        const stderr = decoder.decode(result.stderr);
        if (result.code > 2) {
          throw new Error(
            `${project.label}: check failed (${result.code}): ${stderr}`,
          );
        }
        const timing = stderr.match(
          /SZANIEC_BENCH evaluation=([\d.]+) allocation=(\d+) units=(\d+) paths=(\d+) calls=(\d+)/,
        );
        const peak = stderr.match(/SZANIEC_PEAK (\d+)/);
        if (!timing || !peak) throw new Error(`Missing measurement: ${stderr}`);
        const output: Output = {
          code: result.code,
          report: result.stdout,
          graph: evaluationOnly
            ? new Uint8Array()
            : await Deno.readFile(graphPath),
        };
        const report = JSON.parse(decoder.decode(output.report));
        const graph = evaluationOnly
          ? {}
          : JSON.parse(decoder.decode(output.graph));
        if (
          evaluationOnly
            ? report.format !== "szaniec-evaluation-benchmark/1"
            : report.format !== "szaniec-report/1" ||
              !graph.format?.startsWith("szaniec-callgraph/")
        ) {
          throw new Error(
            `${project.label}: missing complete report or callgraph`,
          );
        }
        if (!evaluationOnly) await Deno.remove(graphPath);
        if (reference) {
          if (
            reference.code !== output.code ||
            !equal(reference.report, output.report) ||
            !equal(reference.graph, output.graph)
          ) {
            throw new Error(
              `${project.label}: report, graph or exit status changed`,
            );
          }
        } else reference = output;
        const sample = {
          evaluationSeconds: Number(timing[1]),
          fullSeconds,
          peakKiB: Number(peak[1]),
          evaluationAllocatedBytes: Number(timing[2]),
        };
        samples[i].push(sample);
        console.log(JSON.stringify({
          project: project.label,
          evaluationOnly,
          evaluator: i === 0 ? "baseline" : "indexed",
          run: run + 1,
          units: Number(timing[3]),
          paths: Number(timing[4]),
          calls: Number(timing[5]),
          exit: result.code,
          evaluationSeconds: sample.evaluationSeconds,
          ...(evaluationOnly
            ? { processSeconds: sample.fullSeconds }
            : { fullSeconds: sample.fullSeconds }),
          peakKiB: sample.peakKiB,
          evaluationAllocatedBytes: sample.evaluationAllocatedBytes,
        }));
      }
    }
    const digest = async (bytes: Uint8Array) =>
      Array.from(
        new Uint8Array(
          await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)),
        ),
      )
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
    console.log(JSON.stringify({
      project: project.label,
      evaluationOnly,
      byteIdentical: true,
      reportDigest: await digest(reference!.report),
      ...(evaluationOnly
        ? {}
        : { graphDigest: await digest(reference!.graph) }),
      medians: samples.map((set, i) => ({
        evaluator: i === 0 ? "baseline" : "indexed",
        evaluationSeconds: median(set.map((s) => s.evaluationSeconds)),
        ...(evaluationOnly
          ? { processSeconds: median(set.map((s) => s.fullSeconds)) }
          : { fullSeconds: median(set.map((s) => s.fullSeconds)) }),
        peakKiB: median(set.map((s) => s.peakKiB)),
        evaluationAllocatedBytes: median(
          set.map((s) => s.evaluationAllocatedBytes),
        ),
      })),
    }));
  }
} finally {
  await Deno.remove(temporary, { recursive: true });
}
