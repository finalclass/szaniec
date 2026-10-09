const root = new URL("../../", import.meta.url).pathname;
const bin = `${root}_build/default/bin/szaniec.exe`;
const decoder = new TextDecoder();
const assert = (value: unknown, message: string) => {
  if (!value) throw new Error(message);
};
type Region = { kind: string; api: string; site: { line: number } };
type Context = {
  origin: string;
  site: { line: number };
  evidencePath: string[];
  loops: Region[];
  activations: Region[];
  unknownReasons: string[];
};
type Edge = {
  to: { service?: string; method?: string; api?: string; kind?: string };
  contexts: Context[];
};
async function run(cwd: string, ...args: string[]) {
  const result = await new Deno.Command(bin, {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: result.code,
    out: decoder.decode(result.stdout),
    err: decoder.decode(result.stderr),
  };
}
const source = `module Impl : Task_manager.IMPL = struct
  let list ctx (req : Task_access.ListReq.t) = (Task_access.list ~ctx ~limit:req.limit).tasks
  let add ctx (req : Task_manager.AddReq.t) =
    ignore (Repeat.fetch ctx req.title);
    for _i = 0 to Repeat.bound ctx req.title do
      ignore (Repeat.fetch ctx req.title)
    done;
    while Repeat.condition ctx req.title do
      ignore (Repeat.fetch ctx req.title)
    done;
    ignore (List.map (fun _ -> Repeat.fetch ctx req.title) [1; 2]);
    List.iter (Repeat.named ctx) [req.title];
    ignore (Array.init 2 (fun _ -> Repeat.fetch ctx req.title));
    ignore ([1; 2] |> List.map (fun _ -> Repeat.fetch ctx req.title));
    ignore (List.map (fun _ -> Repeat.fetch ctx req.title) @@ [1; 2]);
    let mapper = List.map (fun _ -> Repeat.fetch ctx req.title) in
    ignore mapper;
    let produced = Repeat.factory ctx req.title in
    for _i = 0 to 2 do ignore (produced ()) done;
    for _i = 0 to 2 do
      for _j = 0 to 2 do ignore (Repeat.fetch ctx req.title) done
    done;
    for _i = 0 to 2 do
      let deferred () = Repeat.fetch ctx req.title in
      ignore deferred
    done;
    Repeat.fetch ctx req.title
end
let spec = Task_manager.make_spec (module Impl)
let () = Well.every ~name:"worker" ~sleep:0.1 (fun () ->
  ignore (Repeat.fetch {Well.session_id=""; user_id=None} "job");
  for _i = 0 to 2 do
    ignore (Repeat.fetch {Well.session_id=""; user_id=None} "job")
  done;
  ignore (Task_manager.add ~ctx:{Well.session_id=""; user_id=None} ~title:"job"))
`;

Deno.test("source-to-callgraph repetition and independent activation contexts", async () => {
  const project = await Deno.makeTempDir({ prefix: "szaniec-loops-" });
  try {
    const copy = await new Deno.Command("cp", {
      args: ["-R", `${root}test/fixtures/tasks-app/.`, project],
    }).output();
    assert(copy.success, decoder.decode(copy.stderr));
    await Deno.writeTextFile(
      `${project}/lib/task_manager/task_manager_impl.ml`,
      source,
    );
    await Deno.writeTextFile(
      `${project}/lib/task_manager/repeat.ml`,
      `let fetch ctx title = Task_access.create ~ctx ~title
let bound ctx title = (fetch ctx title).id
let condition ctx title = (fetch ctx title).id < 0
let named ctx = function title -> ignore (fetch ctx title)
let factory ctx title = let result = fetch ctx title in fun () -> result
let rec recursive ctx title n =
  if n > 0 then begin ignore (fetch ctx title); recursive ctx title (n - 1) end
let opaque callback = callback ()
let unknown ctx title = opaque (fun () -> ignore (fetch ctx title))
module List = struct let map callback values = ignore callback; values end
let shadowed ctx title = List.map (fun () -> fetch ctx title) [()]
`,
    );
    const stub = `${project}/lib/well_stub/well.ml`;
    await Deno.writeTextFile(
      stub,
      await Deno.readTextFile(stub) +
        "\nlet every ~name ~sleep callback = ignore (name, sleep, callback)\n",
    );
    let result = await run(project, "approve");
    assert(result.code === 0, result.err);
    result = await run(project, "check", "--rebuild", "--json");
    assert(result.out.startsWith("{"), result.err + result.out);
    const report = JSON.parse(result.out);
    assert(
      !report.findings.some((f: { rule: string }) => f.rule === "GAP-BUILD"),
      result.err + result.out,
    );
    assert(
      report.findings.every((f: { rule: string }) => !f.rule.includes("LOOP")),
      "annotations must not invent a conformance rule",
    );
    const first = await Deno.readTextFile(`${project}/szaniec.json`);
    const graph = JSON.parse(first);
    assert(graph.format === "szaniec-callgraph/3", "versioned graph contract");
    const manager = graph.services.find((s: { name: string }) =>
      s.name === "Task_manager"
    );
    const method = manager.methods.find((m: { name: string }) =>
      m.name === "add"
    );
    const contexts: Context[] = method.calls.flatMap((e: Edge) =>
      e.to.service === "Task_access" ? e.contexts : []
    );
    const line = (text: string) =>
      source.slice(0, source.indexOf(text)).split("\n").length;
    assert(contexts.some((c) => c.loops.length === 0), "ordinary helper calls");
    assert(
      contexts.some((c) => c.loops.some((r) => r.kind === "for")),
      "for body must repeat through its helper",
    );
    assert(
      contexts.some((c) =>
        c.loops.some((r) => r.kind === "while") &&
        c.evidencePath.some((s) => s.endsWith("Repeat.condition"))
      ),
      "while condition must repeat",
    );
    assert(
      contexts.some((c) =>
        c.loops.length === 0 &&
        c.evidencePath.some((s) => s.endsWith("Repeat.bound"))
      ),
      "for bounds are evaluated outside the loop",
    );
    assert(
      contexts.some((c) => c.loops.some((r) => r.api === "Stdlib.List.map")),
      "anonymous List.map callback",
    );
    assert(
      contexts.some((c) => c.loops.some((r) => r.api === "Stdlib.Array.init")),
      "Array.init callback has a different argument position",
    );
    assert(
      contexts.some((c) =>
        c.loops.some((r) => r.api === "Stdlib.List.iter") &&
        c.evidencePath.some((s) => s.endsWith("Repeat.named"))
      ),
      "partially applied named iterator callback",
    );
    assert(
      contexts.some((c) =>
        c.loops.filter((r) => r.kind === "for").length === 2
      ),
      "nested loop evidence",
    );
    assert(
      contexts.every((c) =>
        !c.evidencePath.some((s) => s.includes("deferred@"))
      ),
      "defining a callback inside a loop must not execute its body",
    );
    assert(
      contexts.every((c) =>
        !c.loops.some((r) => r.site.line === line("let mapper ="))
      ),
      "creating an unused partial iterator must not invoke its callback",
    );
    assert(
      contexts.filter((c) => c.evidencePath.includes("Repeat.factory"))
        .every((c) => c.loops.length === 0),
      "invoking a returned function does not repeat the factory",
    );
    assert(
      method.calls.some((e: Edge) =>
        e.to.kind === "unresolved" &&
        e.contexts.some((c) =>
          c.unknownReasons.includes("returned function target unresolved")
        )
      ),
      "unresolved returned function retains execution evidence",
    );
    assert(
      ["ignore ([1; 2] |>", " @@ [1; 2]"].every((expression) =>
        contexts.some((c) =>
          c.loops.some((r) =>
            r.api === "Stdlib.List.map" && r.site.line === line(expression)
          ) &&
          c.unknownReasons.length === 0
        )
      ),
      "application operators preserve iterator context",
    );
    assert(
      contexts.every((c) => c.activations.length === 0),
      "activation stops at the next service boundary",
    );
    const entryContexts = (needle: string): Context[] =>
      graph.entryPoints.filter((e: { symbol: string }) =>
        e.symbol.includes(needle)
      )
        .flatMap((e: { calls: Edge[] }) => e.calls)
        .flatMap((e: Edge) => e.to.service === "Task_access" ? e.contexts : []);
    const worker = entryContexts("<init@");
    assert(
      worker.some((c) =>
        c.activations.some((r) => r.api === "Well.every") &&
        c.loops.length === 0
      ),
      "periodic listener is an activation rather than an intra-use-case loop",
    );
    assert(
      worker.some((c) =>
        c.activations.length > 0 && c.loops.some((r) => r.kind === "for")
      ),
      "a loop inside a recurring activation retains both contexts",
    );
    const recursive = entryContexts("Repeat.recursive");
    assert(
      recursive.some((c) => c.loops.some((r) => r.kind === "recursion")),
      "recursive invocation cycle",
    );
    const unknown = entryContexts("Repeat.unknown");
    assert(
      unknown.some((c) => c.unknownReasons.length > 0),
      "custom callback semantics remain unknown",
    );
    const shadowed = entryContexts("Repeat.shadowed");
    assert(
      shadowed.every((c) => !c.loops.some((r) => r.api === "Stdlib.List.map")),
      "a user module named List is not a standard iterator",
    );
    assert(
      contexts.some((c) =>
        c.loops.some((r) => r.site.line === line("for _i = 0 to Repeat.bound"))
      ),
      "loop source evidence",
    );
    result = await run(project, "check", "--json");
    assert(
      first === await Deno.readTextFile(`${project}/szaniec.json`),
      "byte-identical repeated graph",
    );
    assert(
      report.status === JSON.parse(result.out).status,
      "stable findings alongside graph metadata",
    );
  } finally {
    await Deno.remove(project, { recursive: true });
  }
});
