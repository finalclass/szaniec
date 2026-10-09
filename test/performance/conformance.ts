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
const profileAcquisition = Deno.args.includes("--profile-acquisition");
const cacheFollowups = Deno.args.includes("--cache-followups");
const snapshotRoots = option("--snapshot-roots")?.split(",");
if (snapshotRoots && !option("--project-root")) {
  throw new Error("--snapshot-roots requires --project-root");
}
if (
  cacheFollowups &&
  (component === "cache" || option("--project-root") && !snapshotRoots)
) {
  throw new Error(
    "--cache-followups requires an uncached component and a snapshot for existing applications",
  );
}
if (
  snapshotRoots?.some((root) =>
    !root || root.startsWith("/") || root.split("/").some((p) =>
      !p || p === "." || p === ".."
    ) || root === "_build"
  )
) {
  throw new Error(
    "--snapshot-roots requires comma-separated relative source roots",
  );
}
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
  "rendering",
  "imports",
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

async function addAcquisitionProfile(build: string) {
  const directory = `${build}/lib/program_access`;
  await Deno.writeTextFile(
    `${directory}/acquisition_profile.ml`,
    `
type timing = { mutable calls : int; mutable inclusive : float; mutable exclusive : float }
type frame = { mutable children : float }
let timings = Hashtbl.create 16
let stack = ref []
let reset () = Hashtbl.clear timings; stack := []
let measure name f =
  let started = Unix.gettimeofday () in
  let frame = { children = 0. } in
  stack := frame :: !stack;
  Fun.protect ~finally:(fun () ->
    let elapsed = Unix.gettimeofday () -. started in
    stack := List.tl !stack;
    (match !stack with parent :: _ -> parent.children <- parent.children +. elapsed | [] -> ());
    let timing = match Hashtbl.find_opt timings name with
      | Some timing -> timing
      | None -> let timing = { calls = 0; inclusive = 0.; exclusive = 0. } in Hashtbl.add timings name timing; timing in
    timing.calls <- timing.calls + 1;
    timing.inclusive <- timing.inclusive +. elapsed;
    timing.exclusive <- timing.exclusive +. max 0. (elapsed -. frame.children)) f
let report () =
  Hashtbl.to_seq timings |> List.of_seq |> List.sort compare
  |> List.iter (fun (name, timing) ->
    Printf.eprintf "SZANIEC_ACQUISITION_PROFILE name=%s calls=%d inclusive=%.9f exclusive=%.9f\\n%!"
      name timing.calls timing.inclusive timing.exclusive)
`,
  );
  const cachePath = `${directory}/observation_cache.ml`;
  let cache = await Deno.readTextFile(cachePath);
  cache = replaceOnce(cache, "let digest text =", "let digest_raw text =");
  cache = replaceOnce(
    cache,
    "let read_file path =",
    `let digest text = Acquisition_profile.measure "cache_hash" (fun () -> digest_raw text)

let read_file_raw path =`,
  );
  cache = replaceOnce(
    cache,
    "let create ~project_root ~evidence =",
    `let read_file path = Acquisition_profile.measure "cache_io" (fun () -> read_file_raw path)

let create ~project_root ~evidence =`,
  );
  await Deno.writeTextFile(cachePath, cache);
  const path = `${directory}/ocaml_adapter.ml`;
  let source = await Deno.readTextFile(path);
  source = replaceOnce(
    source,
    "open Szaniec_model\n",
    `open Szaniec_model
module Cmt_format = struct
  include Cmt_format
  let read_cmt path = Acquisition_profile.measure "cmt_decode" (fun () -> read_cmt path)
end
module Cmi_format = struct
  include Cmi_format
  let read_cmi path = Acquisition_profile.measure "cmi_decode" (fun () -> read_cmi path)
end
module Observation_cache = struct
  include Observation_cache
  let key cache ~kind ~artifact ~source = Acquisition_profile.measure "cache_key" (fun () -> key cache ~kind ~artifact ~source)
  let read cache key = Acquisition_profile.measure "cache_read" (fun () -> read cache key)
  let write cache key value = Acquisition_profile.measure "cache_write" (fun () -> write cache key value)
  let artifact_current cache ~artifact = Acquisition_profile.measure "artifact_recheck" (fun () -> artifact_current cache ~artifact)
end
module Execution = struct
  include Execution
  let observe ~unit_canonical ~resolve ~site_of_loc structure =
    Acquisition_profile.measure "execution_extract" (fun () -> observe ~unit_canonical ~resolve ~site_of_loc structure)
end
`,
  );
  source = replaceOnce(
    source,
    "let scan_artifacts (project_root",
    `let scan_sources project_root roots = Acquisition_profile.measure "scan_sources" (fun () -> scan_sources project_root roots)

let scan_artifacts (project_root`,
  );
  source = replaceOnce(
    source,
    "let strip_build_prefix (p",
    `let scan_artifacts project_root = Acquisition_profile.measure "scan_artifacts" (fun () -> scan_artifacts project_root)

let strip_build_prefix (p`,
  );
  source = replaceOnce(
    source,
    "let interface_crc path name =",
    `let current_input ~project_root ~source cmt artifact =
  Acquisition_profile.measure "freshness_source" (fun () -> current_input ~project_root ~source cmt artifact)

let interface_crc path name =`,
  );
  source = replaceOnce(
    source,
    "let current_imports ~project_root",
    `let current_interface ~project_root ~source cmt artifact =
  Acquisition_profile.measure "freshness_interface" (fun () -> current_interface ~project_root ~source cmt artifact)

let current_imports ~project_root`,
  );
  source = replaceOnce(
    source,
    "let sha256_hex (s",
    `let current_imports ~project_root ~local_units cmt =
  Acquisition_profile.measure "freshness_imports" (fun () -> current_imports ~project_root ~local_units cmt)

let sha256_hex (s`,
  );
  source = replaceOnce(
    source,
    "type evidence =",
    `let walk_unit ?execution ~project_root ~lib ~unit_name cmt facts =
  Acquisition_profile.measure "facts_extract" (fun () -> walk_unit ?execution ~project_root ~lib ~unit_name cmt facts)

type evidence =`,
  );
  source = replaceOnce(source, "let observe\n", "let observe_raw\n");
  source = replaceOnce(
    source,
    "  let module_aliases =\n",
    `  Acquisition_profile.measure "normalize_observation" (fun () ->
  let module_aliases =
`,
  );
  source += ")\n";
  source += `
let observe ?evidence ~project_root ~program_roots ~assume_fresh () =
  Acquisition_profile.reset ();
  Fun.protect ~finally:Acquisition_profile.report (fun () ->
    Acquisition_profile.measure "observation" (fun () ->
      observe_raw ?evidence ~project_root ~program_roots ~assume_fresh ()))
`;
  await Deno.writeTextFile(path, source);
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
  const projection =
    "  let callgraph = build_callgraph ~cy ~observation ~interpretation in\n";
  source = replaceOnce(
    source,
    projection,
    "  let projection_started = Unix.gettimeofday () in\n" + projection +
      '  Printf.eprintf "SZANIEC_STAGE projection=%.9f\\n%!" (Unix.gettimeofday () -. projection_started) ;\n',
  );
  if (profileAcquisition) {
    source = source.replaceAll(
      "  Gc.full_major () ;\n",
      `  let gc_started = Unix.gettimeofday () in
  Gc.full_major () ;
  Printf.eprintf "SZANIEC_FORCED_GC seconds=%.9f\\n%!" (Unix.gettimeofday () -. gc_started) ;
`,
    );
  }
  return source;
}

function instrumentCli(source: string) {
  source = replaceOnce(
    source,
    "let write_callgraph (r : Finding.report)",
    "let write_callgraph_raw (r : Finding.report)",
  );
  const marker = "let complexity_text (r : Complexity.t)";
  return replaceOnce(
    source,
    marker,
    'let write_callgraph report out root =\n  let started = Unix.gettimeofday () in\n  write_callgraph_raw report out root ;\n  Printf.eprintf "SZANIEC_STAGE rendering=%.9f\\n%!" (Unix.gettimeofday () -. started)\n\n' +
      marker,
  );
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
  let exists = true;
  try {
    await Deno.stat(`${destination}/_build`);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
    exists = false;
  }
  if (!exists) {
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
  // Project-root keys cannot reuse the source checkout's observations.
  try {
    await Deno.remove(`${destination}/_build/.szaniec-observations`, {
      recursive: true,
    });
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
}

type Sample = {
  evaluationSeconds: number;
  observationSeconds: number;
  interpretationSeconds: number;
  projectionSeconds: number;
  renderingSeconds: number;
  fullSeconds: number;
  peakKiB: number;
  cpuSeconds: number;
  evaluationAllocatedBytes: number;
};
type Output = { code: number; report: Uint8Array; graphPath?: string };

async function validateGraph(path: string) {
  const file = await Deno.open(path);
  const prefix = new Uint8Array(4096);
  let length: number | null;
  try {
    length = await file.read(prefix);
  } finally {
    file.close();
  }
  if (
    !/^\s*\{\s*"format"\s*:\s*"szaniec-callgraph\/\d+"/.test(
      decoder.decode(prefix.subarray(0, length ?? 0)),
    )
  ) throw new Error("Missing callgraph format");
  // Parse every byte without constructing a multi-gigabyte JavaScript object.
  await required("jq", ["--stream", "empty", path]);
}

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
  if (!evaluationOnly && !projectionOnly && !complexityCommand) {
    await required("jq", ["--version"]);
    await required("cmp", ["--version"]);
    await required("sha256sum", ["--version"]);
  }
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
      if (component === "imports") {
        const path = "lib/program_access/ocaml_adapter.ml";
        const source = await readCurrent(path);
        const original = await required("git", ["show", `${baseline}:${path}`]);
        const section = (text: string) => {
          const start = text.indexOf("let current_imports ~project_root");
          const end = text.indexOf("let sha256_hex", start);
          if (start < 0 || end < 0) {
            throw new Error("Missing import-validation section");
          }
          return text.slice(start, end);
        };
        await writeCurrent(
          path,
          replaceOnce(source, section(source), section(original)),
        );
      }
      const readBaseline = (path: string) =>
        required("git", ["show", `${baseline}:${path}`]);
      if (component === "conformance") {
        await writeCurrent(enginePath, baselineEngine);
      }
      if (component === "rendering" || component === "all") {
        await writeCurrent(
          "bin/szaniec.ml",
          await readBaseline("bin/szaniec.ml"),
        );
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
    await Deno.writeTextFile(
      `${build}/bin/szaniec.ml`,
      instrumentCli(await Deno.readTextFile(`${build}/bin/szaniec.ml`)),
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
    if (profileAcquisition) await addAcquisitionProfile(build);
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
    let root = await Deno.realPath(projectRoot);
    let config = option("--config", "szaniec.toml")!;
    if (snapshotRoots) {
      const snapshot = `${temporary}/application`;
      await Deno.mkdir(`${snapshot}/_build`, { recursive: true });
      for (const path of [...snapshotRoots, "_build"]) {
        const destination = `${snapshot}/${path}`;
        await Deno.mkdir(destination, {
          recursive: true,
        });
        await required("cp", [
          "-a",
          "--reflink=auto",
          `${root}/${path}/.`,
          destination,
        ]);
      }
      await seedBuild(snapshot);
      const snapshotConfig = `${temporary}/application-config.toml`;
      await Deno.copyFile(
        config.startsWith("/") ? config : `${root}/${config}`,
        snapshotConfig,
      );
      config = snapshotConfig;
      root = snapshot;
    }
    projects.push({
      label: "application",
      root,
      config,
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
    const rounds: {
      run: number;
      order: number[];
      cacheFollowup?: "cold" | "warm";
    }[] = Array.from(
      { length: runs },
      (_, run) => ({ run, order: run % 2 ? [1, 0] : [0, 1] }),
    );
    if (cacheFollowups) {
      rounds.push(
        { run: runs, order: [1], cacheFollowup: "cold" },
        { run: runs + 1, order: [1], cacheFollowup: "warm" },
      );
    }
    for (const { run, order, cacheFollowup } of rounds) {
      for (const i of order) {
        const cacheEnabled = component === "cache" && i === 1 ||
          !!cacheFollowup;
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
            SZANIEC_OBSERVATION_CACHE: cacheEnabled ? "on" : "off",
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
          ...(evaluationOnly || projectionOnly || complexityCommand
            ? {}
            : { graphPath }),
        };
        const report = JSON.parse(decoder.decode(output.report));
        const acquisitionProfile = [...stderr.matchAll(
          /SZANIEC_ACQUISITION_PROFILE name=(\S+) calls=(\d+) inclusive=([\d.]+) exclusive=([\d.]+)/g,
        )].map((match) => ({
          name: match[1],
          calls: Number(match[2]),
          inclusiveSeconds: Number(match[3]),
          exclusiveSeconds: Number(match[4]),
        }));
        if (profileAcquisition) {
          const observation = acquisitionProfile.find((p) =>
            p.name === "observation"
          );
          const exclusive = acquisitionProfile.reduce(
            (sum, p) => sum + p.exclusiveSeconds,
            0,
          );
          if (
            !observation || observation.calls !== 1 ||
            Math.abs(exclusive - observation.inclusiveSeconds) > 0.001
          ) {
            throw new Error(
              `${project.label}: missing or overlapping acquisition timings`,
            );
          }
        }
        if (
          complexityCommand
            ? report.format !== "szaniec-complexity/1"
            : projectionOnly
            ? report.format !== "szaniec-projection-benchmark/1"
            : evaluationOnly
            ? report.format !== "szaniec-evaluation-benchmark/1"
            : report.format !== "szaniec-report/1"
        ) {
          throw new Error(
            `${project.label}: missing complete report or callgraph`,
          );
        }
        if (output.graphPath) await validateGraph(output.graphPath);
        if (reference) {
          if (
            reference.code !== output.code ||
            !equal(reference.report, output.report)
          ) {
            throw new Error(
              `${project.label}: report, graph or exit status changed`,
            );
          }
          if (output.graphPath) {
            await required("cmp", [
              "-s",
              reference.graphPath!,
              output.graphPath,
            ]);
            await Deno.remove(output.graphPath);
          }
        } else {
          if (output.graphPath) {
            const referencePath = `${temporary}/reference-graph.json`;
            await Deno.rename(output.graphPath, referencePath);
            output.graphPath = referencePath;
          }
          reference = output;
        }
        const sample = {
          evaluationSeconds: Number(timing[1]),
          observationSeconds: Number(
            stderr.match(/SZANIEC_STAGE observation=([\d.]+)/)?.[1] ?? 0,
          ),
          interpretationSeconds: Number(
            stderr.match(/SZANIEC_STAGE interpretation=([\d.]+)/)?.[1] ?? 0,
          ),
          projectionSeconds: Number(
            stderr.match(/SZANIEC_STAGE projection=([\d.]+)/)?.[1] ?? 0,
          ),
          renderingSeconds: Number(
            stderr.match(/SZANIEC_STAGE rendering=([\d.]+)/)?.[1] ?? 0,
          ),
          fullSeconds,
          peakKiB: Number(peak[1]),
          cpuSeconds: Number(
            stderr.match(/SZANIEC_PROCESS elapsed=[\d.]+ cpu=([\d.]+)/)?.[1] ??
              0,
          ),
          evaluationAllocatedBytes: Number(timing[2]),
        };
        if (!cacheFollowup) samples[i].push(sample);
        console.log(JSON.stringify({
          project: project.label,
          component,
          filesystemCache,
          evaluationOnly,
          evaluator: i === 0 ? "baseline" : "indexed",
          cacheEnabled,
          ...(cacheFollowup ? { cacheFollowup } : {}),
          run: run + 1,
          units: Number(timing[3]),
          paths: Number(timing[4]),
          calls: Number(timing[5]),
          exit: result.code,
          evaluationSeconds: sample.evaluationSeconds,
          observationSeconds: sample.observationSeconds,
          interpretationSeconds: sample.interpretationSeconds,
          projectionSeconds: sample.projectionSeconds,
          renderingSeconds: sample.renderingSeconds,
          ...(evaluationOnly
            ? { processSeconds: sample.fullSeconds }
            : { fullSeconds: sample.fullSeconds }),
          peakKiB: sample.peakKiB,
          cpuSeconds: sample.cpuSeconds,
          acquisition: stderr.match(/SZANIEC_ACQUISITION[^\n]*/)?.[0],
          ...(profileAcquisition
            ? {
              acquisitionProfile,
              forcedGcSeconds: [
                ...stderr.matchAll(/SZANIEC_FORCED_GC seconds=([\d.]+)/g),
              ].reduce((sum, match) => sum + Number(match[1]), 0),
            }
            : {}),
          ...(component === "cache" || cacheFollowup
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
      ...(evaluationOnly || projectionOnly || complexityCommand ? {} : {
        graphDigest: (await required("sha256sum", [reference!.graphPath!]))
          .split(" ")[0],
        graphBytes: (await Deno.stat(reference!.graphPath!)).size,
      }),
      medians: samples.map((set, i) => ({
        evaluator: i === 0 ? "baseline" : "indexed",
        evaluationSeconds: median(set.map((s) => s.evaluationSeconds)),
        observationSeconds: median(set.map((s) => s.observationSeconds)),
        interpretationSeconds: median(set.map((s) => s.interpretationSeconds)),
        projectionSeconds: median(set.map((s) => s.projectionSeconds)),
        renderingSeconds: median(set.map((s) => s.renderingSeconds)),
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
    if (reference?.graphPath) await Deno.remove(reference.graphPath);
  }
} finally {
  await Deno.remove(temporary, { recursive: true });
}
