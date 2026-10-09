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
const selectedTime = option("--time-command");
const component = option("--component", "conformance")!;
const domains = Number(option("--domains", "4"));
const shape = option("--shape", "helpers");
const complexityCommand = Deno.args.includes("--complexity");
const filesystemCache = option("--filesystem-cache", "warm");
const timeoutSeconds = Number(option("--timeout-seconds", "300"));
const components = [
  "conformance",
  "all",
  "resolver",
  "attribution",
  "aggregation",
  "selection",
  "capabilities",
  "cache",
  "parallel",
];
if (!components.includes(component)) throw new Error("Unknown --component");
const evaluationOnly = Deno.args.includes("--evaluation-only");
const projectionOnly = Deno.args.includes("--projection-only");
if (
  !Number.isInteger(runs) || runs < 1 || !Number.isInteger(size) || size < 1
) {
  throw new Error("--runs and --size must be positive integers");
}

async function command(
  program: string,
  args: string[],
  cwd = repo,
  env: Record<string, string> = {},
) {
  return await new Deno.Command(program, {
    args,
    cwd,
    env,
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
  const observationMarker =
    "  let observation =\n    Szaniec_program_access.Ocaml_adapter.observe";
  source = replaceOnce(
    source,
    observationMarker,
    "  let observation_started = Unix.gettimeofday () in\n" + observationMarker,
  );
  source = replaceOnce(
    source,
    "  match build_code with\n",
    '  Printf.eprintf "SZANIEC_STAGE observation=%.9f\\n%!" (Unix.gettimeofday () -. observation_started) ;\n  match build_code with\n',
  );
  source = source.replaceAll(
    "  let interpretation =\n",
    "  let interpretation_started = Unix.gettimeofday () in\n  let interpretation =\n",
  );
  source = source.replaceAll(
    "      ~cy\n      observation\n  in\n",
    '      ~cy\n      observation\n  in\n  Printf.eprintf "SZANIEC_STAGE interpretation=%.9f\\n%!" (Unix.gettimeofday () -. interpretation_started) ;\n',
  );
  if (complexityCommand) {
    const marker = "  let owner_of (unit_name : string)";
    source = replaceOnce(
      source,
      marker,
      '  Printf.eprintf "SZANIEC_BENCH evaluation=0 allocation=0 units=%d paths=%d calls=%d\\n%!" (List.length observation.Observation.units) (List.length observation.Observation.exec_paths) (List.length observation.Observation.calls) ;\n' +
        marker,
    );
  }
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
  observationSeconds: number;
  interpretationSeconds: number;
  fullSeconds: number;
  peakKiB: number;
  cpuSeconds: number;
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

async function artifactPaths(directory: string): Promise<string[]> {
  const paths: string[] = [];
  for await (const entry of Deno.readDir(directory)) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory && entry.name !== ".szaniec-observations") {
      paths.push(...await artifactPaths(path));
    } else if (entry.isFile && /\.(cmt|cmti|cmi)$/.test(entry.name)) {
      paths.push(path);
    }
  }
  return paths;
}

async function cacheSize(directory: string) {
  let entries = 0, bytes = 0;
  try {
    for await (const entry of Deno.readDir(directory)) {
      if (entry.isFile && !entry.name.startsWith(".")) {
        entries++;
        bytes += (await Deno.stat(`${directory}/${entry.name}`)).size;
      }
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  return { entries, bytes };
}

const temporary = await Deno.makeTempDir({
  prefix: "szaniec-conformance-benchmark-",
});
try {
  const timeCommand = selectedTime ?? `${temporary}/measure`;
  if (!selectedTime) {
    await required("cc", [
      "-O2",
      "-Wall",
      "-Wextra",
      "-o",
      timeCommand,
      `${repo}/test/performance/measure.c`,
    ]);
  }
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
      const readCurrent = (path: string) =>
        Deno.readTextFile(`${build}/${path}`);
      const writeCurrent = (path: string, source: string) =>
        Deno.writeTextFile(`${build}/${path}`, source);
      const readBaseline = (path: string) =>
        required("git", ["show", `${baseline}:${path}`]);
      if (component === "conformance") {
        await writeCurrent(enginePath, baselineEngine);
      }
      if (component === "all") {
        for (
          const path of [
            enginePath,
            managerPath,
            "lib/interpretation_engine/well_adapter.ml",
            "lib/interpretation_engine/public_contracts.ml",
            "lib/model/canonical.ml",
            "lib/program_access/function_catalog.ml",
            "lib/program_access/ocaml_adapter.ml",
          ]
        ) await writeCurrent(path, await readBaseline(path));
        const adapter = "lib/interpretation_engine/well_adapter.ml";
        await writeCurrent(
          adapter,
          (await readCurrent(adapter)).replace(
            '| "spec" :: mod_segs_rev -> (\n          let unit_root = List.hd mod_segs_rev in',
            '| "spec" :: unit_root :: _ -> (',
          ).replace(
            "let name = List.rev (Canonical.split_dots symbol) |> List.hd in",
            'let name = match List.rev (Canonical.split_dots symbol) with name :: _ -> name | [] -> "" in',
          ),
        );
      }
      if (component === "resolver") {
        const path = "lib/model/canonical.ml";
        const source = await readCurrent(path);
        const start = source.indexOf("let unit_resolver units =");
        const end = source.indexOf("let alias_resolver", start);
        await writeCurrent(
          path,
          source.slice(0, start) +
            "let unit_resolver units path = unit_prefix units path\n\n" +
            source.slice(end),
        );
      }
      if (component === "attribution" || component === "aggregation") {
        const old = await readBaseline(managerPath);
        let current = await readCurrent(managerPath);
        const oldStart = old.indexOf("  let starts_with (s : string)");
        const oldEnd = old.indexOf("  let method_of_origin", oldStart);
        const newStart = current.indexOf("  let owner_prefixes =");
        const newEnd = current.indexOf("  let method_of_origin", newStart);
        if (component === "attribution") {
          current = current.slice(0, newStart) + old.slice(oldStart, oldEnd) +
            current.slice(newEnd);
        } else {current = old.slice(0, oldStart) +
            current.slice(newStart, newEnd) + old.slice(oldEnd);}
        await writeCurrent(managerPath, current);
      }
      if (component === "selection") {
        const path = "lib/program_access/ocaml_adapter.ml";
        let source = await readCurrent(path);
        const start = source.indexOf("let strip_tree");
        const end = source.indexOf("(* ── observation driver", start);
        source = source.slice(0, start) + "let strip_tree cmt = cmt\n\n" +
          source.slice(end);
        source = replaceOnce(
          source,
          "                      Observation_cache.note_read cache ;\n                      let current =\n                        Cmt_format.read_cmt (project_root // artifact)\n                      in",
          "                      let current = cmt in",
        );
        await writeCurrent(path, source);
      }
      if (component === "capabilities") {
        const path = "lib/program_access/ocaml_adapter.ml";
        const source = await readCurrent(path);
        await writeCurrent(
          path,
          source.replace(
            "  let architecture = evidence <> Measurement in",
            "  let _ = evidence in\n  let evidence = All in\n  let architecture = evidence <> Measurement in",
          ),
        );
      }
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
      projectionOnly
        ? "test/performance/projection.exe"
        : evaluationOnly
        ? "test/performance/evaluation.exe"
        : "bin/szaniec.exe",
    ], build);
  }

  const fixture = `${temporary}/fixture`;
  await required("cp", ["-R", `${repo}/test/fixtures/tasks-app`, fixture]);
  await seedBuild(fixture);
  let functions = Array.from(
    { length: size },
    (_, i) =>
      `let leaf_${i} () = Task_manager.list ~ctx:ctx_w ~limit:10\n` +
      `let middle_${i} () = leaf_${i} ()\n` +
      `let helper_${i} () = middle_${i} ()\n` +
      `let entry_${i} () = helper_${i} ()\n`,
  ).join("\n");
  if (shape === "branching") {
    functions = "\nlet branching n = match n with\n" +
      Array.from(
        { length: 48 },
        (_, i) =>
          `${
            i === 47 ? "| _" : `| ${i}`
          } -> Task_manager.list ~ctx:ctx_w ~limit:10\n`,
      ).join("") +
      Array.from(
        { length: size },
        (_, i) => `let entry_${i} () = branching ${i}\n`,
      ).join("");
  } else if (shape !== "helpers") throw new Error("Unknown --shape");
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
  if (component === "cache") {
    for (const label of ["one-changed", "broad-changes"]) {
      projects.push({ label, root: fixture, config: "szaniec.toml" });
    }
  }
  for (const project of projects) {
    if (project.label === "one-changed") {
      await Deno.writeTextFile(
        `${fixture}/lib/web_client/tasks_page.ml`,
        "\n(* cache invalidation probe *)\n",
        { append: true },
      );
      await required("dune", ["build"], fixture);
    }
    if (project.label === "broad-changes") {
      const paths =
        (await required("git", ["ls-files", "test/fixtures/tasks-app/lib"]))
          .trim().split("\n").filter((p) => p.endsWith(".ml"));
      for (const path of paths) {
        await Deno.writeTextFile(
          `${fixture}/${path.slice("test/fixtures/tasks-app/".length)}`,
          "\n(* broad invalidation probe *)\n",
          { append: true },
        );
      }
      await required("dune", ["build"], fixture);
    }
    let reference: Output | undefined;
    const samples: Sample[][] = [[], []];
    for (let run = 0; run < runs; run++) {
      const order = run % 2 ? [1, 0] : [0, 1];
      for (const i of order) {
        if (filesystemCache === "cold") {
          if (selectedTime) {
            throw new Error(
              "Cold-cache advice requires the native measurement helper",
            );
          }
          const paths = await artifactPaths(`${project.root}/_build/default`);
          for (let j = 0; j < paths.length; j += 100) {
            await required(timeCommand, [
              "--evict",
              ...paths.slice(j, j + 100),
            ]);
          }
        } else if (filesystemCache !== "warm") {
          throw new Error("Unknown --filesystem-cache");
        }
        const graphPath = `${temporary}/graph.json`;
        const started = performance.now();
        const args = projectionOnly
          ? [
            `${builds[i]}/_build/default/test/performance/projection.exe`,
            String(size),
          ]
          : evaluationOnly
          ? [
            `${builds[i]}/_build/default/test/performance/evaluation.exe`,
            project.root,
            project.config,
          ]
          : [
            `${builds[i]}/_build/default/bin/szaniec.exe`,
            complexityCommand ? "complexity" : "check",
            "--project-root",
            project.root,
            "--config",
            project.config,
            "--json",
            ...(complexityCommand ? [] : ["--out", graphPath]),
          ];
        const result = await command(
          "timeout",
          [
            String(timeoutSeconds),
            timeCommand,
            "-f",
            "SZANIEC_PEAK %M",
            ...args,
          ],
          repo,
          {
            SZANIEC_OBSERVATION_CACHE: component === "cache" && i === 1
              ? "on"
              : "off",
            SZANIEC_DOMAINS: String(
              component === "parallel" && i === 1 ? domains : 1,
            ),
            SZANIEC_ACQUISITION_STATS: "1",
          },
        );
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
          graph: evaluationOnly || projectionOnly || complexityCommand
            ? new Uint8Array()
            : await Deno.readFile(graphPath),
        };
        const report = JSON.parse(decoder.decode(output.report));
        const graph = evaluationOnly || projectionOnly || complexityCommand
          ? {}
          : JSON.parse(decoder.decode(output.graph));
        if (
          complexityCommand
            ? report.format !== "szaniec-complexity/1"
            : projectionOnly
            ? report.format !== "szaniec-projection-benchmark/1"
            : evaluationOnly
            ? report.format !== "szaniec-evaluation-benchmark/1"
            : report.format !== "szaniec-report/1" ||
              !graph.format?.startsWith("szaniec-callgraph/")
        ) {
          throw new Error(
            `${project.label}: missing complete report or callgraph`,
          );
        }
        if (!evaluationOnly && !projectionOnly && !complexityCommand) {
          await Deno.remove(graphPath);
        }
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
          observationSeconds: Number(
            stderr.match(/SZANIEC_STAGE observation=([\d.]+)/)?.[1] ?? 0,
          ),
          interpretationSeconds: Number(
            stderr.match(/SZANIEC_STAGE interpretation=([\d.]+)/)?.[1] ?? 0,
          ),
          fullSeconds,
          peakKiB: Number(peak[1]),
          cpuSeconds: Number(
            stderr.match(/SZANIEC_PROCESS elapsed=[\d.]+ cpu=([\d.]+)/)?.[1] ??
              0,
          ),
          evaluationAllocatedBytes: Number(timing[2]),
        };
        samples[i].push(sample);
        console.log(JSON.stringify({
          project: project.label,
          component,
          filesystemCache,
          evaluationOnly,
          evaluator: i === 0 ? "baseline" : "indexed",
          run: run + 1,
          units: Number(timing[3]),
          paths: Number(timing[4]),
          calls: Number(timing[5]),
          exit: result.code,
          evaluationSeconds: sample.evaluationSeconds,
          observationSeconds: sample.observationSeconds,
          interpretationSeconds: sample.interpretationSeconds,
          ...(evaluationOnly
            ? { processSeconds: sample.fullSeconds }
            : { fullSeconds: sample.fullSeconds }),
          peakKiB: sample.peakKiB,
          cpuSeconds: sample.cpuSeconds,
          acquisition: stderr.match(/SZANIEC_ACQUISITION[^\n]*/)?.[0],
          ...(component === "cache"
            ? {
              cache: await cacheSize(
                `${project.root}/_build/.szaniec-observations`,
              ),
            }
            : {}),
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
      component,
      evaluationOnly,
      byteIdentical: true,
      reportDigest: await digest(reference!.report),
      ...(evaluationOnly || projectionOnly || complexityCommand
        ? {}
        : { graphDigest: await digest(reference!.graph) }),
      medians: samples.map((set, i) => ({
        evaluator: i === 0 ? "baseline" : "indexed",
        evaluationSeconds: median(set.map((s) => s.evaluationSeconds)),
        observationSeconds: median(set.map((s) => s.observationSeconds)),
        interpretationSeconds: median(set.map((s) => s.interpretationSeconds)),
        ...(evaluationOnly
          ? { processSeconds: median(set.map((s) => s.fullSeconds)) }
          : { fullSeconds: median(set.map((s) => s.fullSeconds)) }),
        peakKiB: median(set.map((s) => s.peakKiB)),
        cpuSeconds: median(set.map((s) => s.cpuSeconds)),
        evaluationAllocatedBytes: median(
          set.map((s) => s.evaluationAllocatedBytes),
        ),
      })),
    }));
  }
} finally {
  await Deno.remove(temporary, { recursive: true });
}
