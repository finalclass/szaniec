const repository = new URL("../../", import.meta.url).pathname.replace(
  /\/$/,
  "",
);
const binary = Deno.env.get("SZANIEC_TEST_BINARY") ??
  `${repository}/_release/szaniec`;
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
type Finding = {
  rule: string;
  message: string;
  evidencePath: string[];
  locations: { path: string; line: number }[];
};
type Report = {
  status: string;
  summary: { violations: number; gaps: number; units: number };
  findings: Finding[];
  inputs: { exclusions: string[] };
};
async function copy(from: string, into: string) {
  await Deno.mkdir(into, { recursive: true });
  for await (const entry of Deno.readDir(from)) {
    if (entry.name === "_build") continue;
    if (entry.isDirectory) {
      await copy(`${from}/${entry.name}`, `${into}/${entry.name}`);
    } else if (entry.isFile) {
      await Deno.copyFile(`${from}/${entry.name}`, `${into}/${entry.name}`);
    }
  }
}
Deno.test("compiled local ownership, SQLite, callbacks, path summaries, transformation and MLX evidence", async () => {
  const retained = Deno.env.get("SZANIEC_CAPABILITY_FIXTURE");
  const root = retained ??
    await Deno.makeTempDir({ prefix: "szaniec-capabilities-" });
  if (retained) {
    assert(
      /^\/tmp\/szaniec-capabilities-[A-Za-z0-9_-]+$/.test(root),
      "retained fixture must be a dedicated temporary directory",
    );
    await Deno.mkdir(root, { recursive: true });
    assert(
      !(await Deno.lstat(root)).isSymlink,
      "retained fixture cannot be a symbolic link",
    );
    for await (const entry of Deno.readDir(root)) {
      if (entry.name !== "_build") {
        await Deno.remove(`${root}/${entry.name}`, { recursive: true });
      }
    }
  }
  const environment = Deno.env.toObject();
  for (const key of Object.keys(environment)) {
    if (/^(DUNE_|OCAML|CAML_|BUILD_PATH_PREFIX_MAP|INSIDE_DUNE)/.test(key)) {
      delete environment[key];
    }
  }
  environment.DUNE_CACHE = "disabled";
  async function command(
    exe: string,
    args: string[],
    extra: Record<string, string> = {},
  ) {
    const result = await new Deno.Command(exe, {
      args,
      cwd: root,
      env: { ...environment, ...extra },
      clearEnv: true,
      stdout: "piped",
      stderr: "piped",
    }).output();
    return {
      code: result.code,
      out: decoder.decode(result.stdout),
      err: decoder.decode(result.stderr),
    };
  }
  async function write(file: string, source: string) {
    await Deno.mkdir(`${root}/${file.slice(0, file.lastIndexOf("/"))}`, {
      recursive: true,
    });
    await Deno.writeTextFile(`${root}/${file}`, source);
  }
  async function approve() {
    const result = await command(binary, ["approve", "--project-root", root]);
    assert(result.code === 0, result.err + result.out);
  }
  async function check(rebuild = true, extra: Record<string, string> = {}) {
    const result = await command(binary, [
      "check",
      "--project-root",
      root,
      "--json",
      "--out",
      "_build/graph.json",
      ...(rebuild ? ["--rebuild"] : []),
    ], extra);
    assert(result.out.startsWith("{"), result.err + result.out);
    return { ...result, report: JSON.parse(result.out) as Report };
  }
  const client = "lib/web_client/page.ml";
  let policy = "";
  async function scenario(
    name: string,
    source: string,
    rules: string[] = [],
    code = 0,
  ) {
    await write(client, source);
    const result = await check();
    assert(
      result.code === code,
      `${name}: expected ${code}: ${result.err}${result.out}`,
    );
    for (const rule of rules) {
      assert(
        result.report.findings.some((f) => f.rule === rule),
        `${name}: missing ${rule}: ${result.out}`,
      );
    }
    if (code < 2) {
      assert(
        result.report.summary.gaps === 0,
        `${name}: unexpected gaps: ${result.out}`,
      );
    }
    const repeated = await check(false);
    const uncached = await check(false, { SZANIEC_OBSERVATION_CACHE: "off" });
    assert(
      result.out === repeated.out && repeated.out === uncached.out,
      `${name}: rebuild, repeated and uncached evidence differ\n${result.out}\n${repeated.out}\n${uncached.out}`,
    );
    if (
      name === "returned immutable variant record retains its callable target"
    ) {
      const summary = await command(binary, [
        "check",
        "--summary",
        "--no-callgraph",
      ]);
      assert(summary.code === 1, summary.err + summary.out);
      assert(
        summary.out === "szaniec violations: 1 violation(s), 0 gap(s)\n",
        summary.out,
      );
    }
    console.log(`${name}: ok`);
    return result;
  }
  const message = 'App_contract.Common.Message.make ~value:"test"';
  const manager =
    `ignore (App_contract.Task_manager.read ~ctx:() (${message}))`;
  const access = `ignore (App_contract.Task_access.read ~ctx:() (${message}))`;
  try {
    await copy(`${repository}/test/fixtures/owned-contracts-app`, root);
    policy = await Deno.readTextFile(`${root}/szaniec.toml`);
    await approve();
    const baseline = await check();
    let result = baseline;
    assert(
      baseline.code === 0,
      `fresh fixture baseline: ${baseline.err}${baseline.out}`,
    );
    await write(
      "_release/static/dune",
      "(rule (target unused) (deps missing.release.input) (action (run missing.release.tool)))\n",
    );
    const generatedDune = "lib/task_access/dune";
    const generatedOriginal = await Deno.readTextFile(
      `${root}/${generatedDune}`,
    );
    await write(
      generatedDune,
      generatedOriginal +
        '\n(rule (target generated.ml) (deps (universe)) (action (write-file generated.ml "let value = 7\\n")))\n',
    );
    result = await check();
    assert(
      result.code === 0,
      "generated source and release copies: " + result.err + result.out,
    );
    assert(
      (await check(false)).out === result.out,
      "generated source survives incremental checks",
    );
    await Deno.chmod(
      `${root}/_build/default/lib/task_access/generated.ml`,
      0o644,
    );
    await Deno.writeTextFile(
      `${root}/_build/default/lib/task_access/generated.ml`,
      "let value = 8\n",
    );
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-STALE-ARTIFACT"),
      "changed generated input stays incomplete: " + result.out,
    );
    await Deno.remove(`${root}/_build/default/lib/task_access/generated.ml`);
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-MISSING-INPUT"),
      "missing generated input stays incomplete: " + result.out,
    );
    await write(generatedDune, generatedOriginal);
    await Deno.remove(`${root}/_release`, { recursive: true });
    result = await check();
    assert(result.code === 0, result.err + result.out);
    await write(
      "support/sqlite3/dune",
      "(library (name sqlite3) (wrapped false))\n",
    );
    await write(
      "support/sqlite3/sqlite3.ml",
      `type db = unit
module Rc = struct type t = OK let to_string (_ : t) = "ok" end
module Data = struct
  type t = TEXT of string
  let opt_text = function Some s -> TEXT s | None -> TEXT ""
  let to_string = function TEXT s -> Some s
end
let db_open (_ : string) : db = ()
let exec (_ : db) (_ : string) = Rc.OK
let errmsg (_ : db) = "error"
`,
    );
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib))\n",
    );
    await scenario(
      "SQLite value conversions",
      "let format_result rc = Sqlite3.Rc.to_string rc\nlet format_data value = Sqlite3.Data.to_string (Sqlite3.Data.opt_text value)\n",
    );
    await scenario(
      "SQLite conversions through aliases and callbacks",
      "module Codes = Sqlite3.Rc\nlet helper rc = ignore (Codes.to_string rc)\nlet show () = let callback () = helper Sqlite3.Rc.OK in callback ()\n",
    );
    const resourceCallback = await scenario(
      "SQLite query through helper callback retains owner",
      'let helper () = let db = Sqlite3.db_open ":memory:" in ignore (Sqlite3.exec db "select 1")\nlet show () = let callback = helper in callback ()\n',
      ["RESOURCE-BOUNDARY"],
      1,
    );
    assert(
      resourceCallback.report.findings.some((f) =>
        f.rule === "RESOURCE-BOUNDARY" &&
        f.message.startsWith("Web_client accesses")
      ),
      "callback resource performer",
    );
    await scenario(
      "SQLite connection remains protected",
      'let show () = ignore (Sqlite3.db_open ":memory:")\n',
      ["RESOURCE-BOUNDARY"],
      1,
    );
    await scenario(
      "SQLite handle diagnostic remains protected",
      "let show db = ignore (Sqlite3.errmsg db)\n",
      ["RESOURCE-BOUNDARY"],
      1,
    );
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      policy +
        '\n[[policy.resources]]\nname = "custom"\napi_prefixes = ["Sqlite3.Rc."]\n',
    );
    await approve();
    await scenario(
      "explicit resource policy takes precedence",
      "let show rc = ignore (Sqlite3.Rc.to_string rc)\n",
      ["RESOURCE-BOUNDARY"],
      1,
    );
    await Deno.writeTextFile(`${root}/szaniec.toml`, policy);
    await approve();
    await scenario(
      "typed local function and alias",
      `let show () = let callback () = ${manager} in let alias = callback in alias ()\n`,
    );
    let nestedOperands = "apply () () () ()";
    for (let depth = 0; depth < 3; depth++) {
      nestedOperands =
        `apply (${nestedOperands}) (apply () () () ()) (apply () () () ()) (apply () () () ())`;
    }
    await scenario(
      "shared nested operand-order nodes stay bounded",
      `let apply a b c d = ignore (a, b, c, d)\nlet show () = ${nestedOperands}\n`,
    );
    await scenario(
      "typed callback reaches Access",
      `let show () = let callback () = ${access} in let alias = callback in alias ()\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "immutable record callback",
      `type handler = {run : unit -> unit}\nlet show () = let handler = {run = (fun () -> ${access})} in handler.run ()\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "known callback passed to local helper",
      `let invoke callback = callback ()\nlet show () = let callback () = ${access} in invoke callback\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "a literal method witness passed to an unused helper input never executes",
      `let unused _ () = ${manager}\nlet show () = unused (fun (obj : < witness : unit >) -> obj#witness) ()\n`,
    );
    await scenario(
      "an activated object method witness retains unresolved evidence",
      `let invoke callback arg = callback arg\nlet show obj = invoke (fun (arg : < witness : unit >) -> arg#witness) obj\n`,
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "an omitted optional function invokes its default",
      `let invoke ?(callback=(fun () -> ${access})) () = callback ()\nlet show () = invoke ()\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "a supplied optional function retains its target",
      `let invoke ?(callback=(fun () -> ())) () = callback ()\nlet show () = invoke ~callback:(fun () -> ${access}) ()\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "a first-class module retains its typed method target",
      `module type Handler = sig val run : unit -> unit end\nlet invoke (module Handler : Handler) = Handler.run ()\nlet show () = invoke (module struct let run () = ${access} end)\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "an unbound first-class module remains incomplete",
      "module type Handler = sig val run : unit -> unit end\nlet show (module Handler : Handler) = Handler.run ()\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "callback from a locally opened structure retains ownership",
      `open struct let invoke callback = callback () end\nlet show () = invoke (fun () -> ${access})\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "a pipeline invokes a function produced by an immutable let binding",
      `let show () = () |> (let value=() in fun () -> ignore value; ${access})\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "a locally aliased public module retains layer checks",
      `let show () = let module Alias = App_contract.Task_access in ignore (Alias.read ~ctx:() (${message}))\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "immutable record passed through helpers retains its callback",
      `type handler = {run : unit -> unit}\nlet invoke handler = handler.run ()\nlet forward handler = invoke handler\nlet show () = forward {run = (fun () -> ${access})}\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    const wellSource = await Deno.readTextFile(`${root}/lib/well/well.ml`);
    await write(
      "lib/well/well.ml",
      wellSource +
        `\nmodule Db = struct\n  type row = {int : int -> int}\n  let query _db _sql _params f = [f {int = (fun _ -> 0)}]\n  let query_one _db _sql _params f = Some (f {int = (fun _ -> 0)})\nend\n`,
    );
    await scenario(
      "database row getter has producer provenance",
      'let show () = ignore (Well.Db.query () "select 1" [] (fun row -> row.int 0))\n',
      ["RESOURCE-BOUNDARY"],
      1,
    );
    await scenario(
      "database row producer survives a helper with an exception handler",
      'let query db sql params f = try Well.Db.query db sql params f with Failure _ -> []\nlet show () = ignore (query () "select 1" [] (fun row -> row.int 0))\n',
      ["RESOURCE-BOUNDARY"],
      1,
    );
    await scenario(
      "database row producer reaches the remaining input of a partial mapper",
      'let read db row = ignore db; row.Well.Db.int 0\nlet show () = ignore (Well.Db.query () "select 1" [] (read ()))\n',
      ["RESOURCE-BOUNDARY"],
      1,
    );
    await scenario(
      "an application-created database row retains its function field",
      `let read (row : Well.Db.row) = row.int 0\nlet show () = ignore (read {int = (fun _ -> ${access}; 0)})\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "dynamic callback remains incomplete",
      "let show callback = callback ()\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "mutable record target remains incomplete",
      `type handler = {mutable run : unit -> unit}\nlet show () = let handler = {run = (fun () -> ${manager})} in handler.run ()\n`,
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await write(
      "lib/second_manager/dune",
      "(library (name second_manager) (wrapped false) (libraries well))\n",
    );
    await write(
      "lib/second_manager/Second_manager.cyrograf",
      "rpc run(Unit) -> Unit\n",
    );
    await write(
      "lib/second_manager/second_manager.ml",
      'let run () = ()\nlet make_spec () = Well.Service.{name = "Second_manager"}\n',
    );
    await write(
      "lib/second_manager/second_manager_impl.ml",
      "let run () = ()\nlet spec = Second_manager.make_spec ()\n",
    );
    const initialBootstrap = await Deno.readTextFile(
      `${root}/lib/bootstrap/bootstrap.ml`,
    );
    await write(
      "lib/bootstrap/bootstrap.ml",
      initialBootstrap +
        "\nlet () = Well.Service.register Second_manager_impl.spec\n",
    );
    await write(
      "lib/bootstrap/dune",
      "(library (name bootstrap) (libraries well task_access_lib task_manager_lib second_manager))\n",
    );
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib second_manager))\n",
    );
    await scenario(
      "wide equivalent alternatives",
      `let show n = match n with\n${
        Array.from({ length: 80 }, (_, i) =>
          `| ${i} -> ${i % 2 === 0 ? manager : "Second_manager.run ()"}`).join(
            "\n",
          )
      }\n| _ -> ()\n`,
    );
    await scenario(
      "wide alternatives with executable multi-Manager path",
      `let show n = (match n with\n${
        Array.from(
          { length: 80 },
          (_, i) =>
            `| ${i} -> ${i % 2 === 0 ? manager : "Second_manager.run ()"}`,
        ).join("\n")
      }\n| _ -> ()); Second_manager.run ()\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "ignored closure does not execute a multi-Manager path",
      `let hidden () = ${manager}; Second_manager.run ()\nlet show () = ignore hidden\n`,
    );
    await scenario(
      "partial helper construction defers execution",
      `let factory a b = ignore (a, b); ${manager}; Second_manager.run ()\nlet show () = let unused = factory () in ignore unused\n`,
    );
    await scenario(
      "invoked partial helper executes its body",
      `let factory a b = ignore (a, b); ${manager}; Second_manager.run ()\nlet show () = let callback = factory () in callback ()\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "uncalled record closure remains deferred",
      `type handler = {run : unit -> unit}\nlet show () = let handler = {run = (fun () -> ${manager}; Second_manager.run ())} in ignore handler\n`,
    );
    await scenario(
      "mapping curried callbacks constructs functions",
      `let callback first second = ignore (first, second); ${manager}; Second_manager.run ()\nlet show () = ignore (List.map callback [()])\n`,
    );
    await scenario(
      "invoked known returned closure retains provenance",
      `let factory () = let value = () in ignore value; (fun () -> ${manager})\nlet show () = let callback = factory () in callback ()\n`,
    );
    await scenario(
      "invoked returned closure retains a multi-Manager violation",
      `let factory () = let value = () in ignore value; (fun () -> ${manager}; Second_manager.run ())\nlet show () = let callback = factory () in callback ()\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "an unknown returned function keeps uncertainty",
      "let factory choice = if choice then (fun () -> ()) else (fun () -> ())\nlet show choice = let callback = factory choice in callback ()\n",
      ["GAP-RETURNED-CLOSURE"],
      2,
    );
    await scenario(
      "executed iterator callback retains multi-Manager path",
      `let hidden () = ${manager}; Second_manager.run ()\nlet show () = List.iter hidden [()]\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "String callbacks retain service interactions",
      `let show () = String.iter (fun _ -> ${manager}; Second_manager.run ()) "x"\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "String predicates have known callback execution",
      `let show () = ignore (String.for_all (fun _ -> ${manager}; true) "x")\n`,
    );
    await write(
      "lib/web_client/dune",
      (await Deno.readTextFile(`${root}/lib/web_client/dune`)).replace(
        /\(libraries ([^)]*)\)/,
        "(libraries $1 str)",
      ),
    );
    await scenario(
      "regular-expression substitutions retain callback interactions",
      `let show () = ignore (Str.global_substitute (Str.regexp "x") (fun _ -> ${manager}; Second_manager.run (); "y") "xx")\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "exception uncertainty retains a single helper callback input",
      `let invoke f = try f () with _ -> ()\nlet show () = invoke (fun () -> ${manager})\n`,
    );
    await scenario(
      "partially applied scalar predicates are not closure factories",
      "let show () = ignore (Option.fold ~none:true ~some:(List.mem 1) (Some [1])); ignore (Option.fold ~none:0 ~some:(max 2) (Some 3))\n",
    );
    await scenario(
      "returned immutable variant record retains its callable target",
      "type source = { iter : (string -> unit) -> unit }\nlet open_source () = `Ok { iter = (fun write -> " +
        access +
        '; write "chunk") }\nlet show () = match open_source () with `Ok src -> src.iter ignore\n',
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "different callable result providers remain incomplete",
      "type source = { iter : unit -> unit }\nlet open_source yes = if yes then `Ok {iter=(fun () -> ())} else `Ok {iter=(fun () -> ())}\nlet show yes = match open_source yes with `Ok src -> src.iter ()\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await write(
      "lib/well/well.ml",
      (await Deno.readTextFile(`${root}/lib/well/well.ml`)) +
        '\nlet open_http_stream ~sw ~net ~method_ url = ignore (sw, net, method_, url); (200, [], fun write -> write "chunk")\n',
    );
    await scenario(
      "an unknown result branch cannot inherit a known record target",
      "type source = { iter : unit -> unit }\nlet open_source yes unknown = if yes then `Ok {iter=(fun () -> ())} else `Ok unknown\nlet show yes unknown = match open_source yes unknown with `Ok src -> src.iter ()\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "returned immutable record does not resolve an unknown captured callback",
      "type source = { iter : unit -> unit }\nlet open_source callback = `Ok {iter=callback}\nlet show callback = match open_source callback with `Ok src -> src.iter ()\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "framework stream result survives tuple and immutable variant record",
      'type source = { iter : (string -> unit) -> unit }\nlet open_source () = let _, _, iter = Well.open_http_stream ~sw:() ~net:() ~method_:"GET" "url" in `Ok {iter}\nlet show () = match open_source () with `Ok src -> src.iter ignore\n',
    );
    await scenario(
      "framework iterator does not resolve an unknown application writer",
      'let show writer = let _, _, iter = Well.open_http_stream ~sw:() ~net:() ~method_:"GET" "url" in iter writer\n',
      [],
      2,
    );
    await scenario(
      "exception uncertainty with distinct callback inputs stays incomplete",
      `let invoke first second = try first () with _ -> second ()\nlet show () = invoke (fun () -> ${manager}) (fun () -> Second_manager.run ())\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    await scenario(
      "a declared native scalar primitive has a concrete external dependency",
      'external native_length : string -> int = "%string_length"\nlet show () = ignore (native_length "x")\n',
    );
    assert(
      (await Deno.readTextFile(`${root}/_build/graph.json`)).includes(
        "Native_primitive.%string_length",
      ),
      "the native dependency remains in the graph",
    );
    await scenario(
      "a native callback primitive retains unknown invocation semantics",
      'external native_callback : (unit -> unit) -> unit -> unit = "caml_callback"\nlet show () = native_callback (fun () -> ()) ()\n',
      ["GAP-CALLBACK-SEMANTICS"],
      2,
    );
    const nativeProvider = "lib/task_access/task_access_impl.ml";
    const nativeProviderSource = await Deno.readTextFile(
      `${root}/${nativeProvider}`,
    );
    await write(
      nativeProvider,
      nativeProviderSource +
        '\nexternal native_length : string -> int = "%string_length"\n',
    );
    await scenario(
      "a foreign native declaration keeps its owning private service boundary",
      'let show () = ignore (Task_access_lib.Task_access_impl.native_length "x")\n',
      ["IMPL-ACCESS-CROSS-SERVICE"],
      1,
    );
    await write(nativeProvider, nativeProviderSource);
    await scenario(
      "formatted input fully invokes its typed callback",
      `let show () = Scanf.sscanf "1:2" "%d:%d" (fun a b -> ignore (a,b); ${manager}; Second_manager.run ())\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "an unforced lazy sequence does not execute its callback",
      `let show () = let unused = Seq.map (fun () -> ${manager}; Second_manager.run ()) (List.to_seq [()]) in ignore unused\n`,
    );
    await scenario(
      "forcing a lazy sequence retains service interactions",
      `let show () = ignore (List.of_seq (Seq.map (fun () -> ${manager}; Second_manager.run ()) (List.to_seq [()])))\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "a standard Set functor retains its concrete comparator",
      `module Keys = struct type t = unit let compare a b = ignore (a,b); ${manager}; Second_manager.run (); 0 end\nmodule Bag = Set.Make(Keys)\nlet show () = ignore (Bag.add () Bag.empty)\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "a standard Set with a library comparator is complete",
      'module Bag = Set.Make(String)\nlet show () = ignore (Bag.mem "x" (Bag.add "x" Bag.empty))\n',
    );
    await scenario(
      "Fun.protect body and finalizer retain service interactions",
      `let show () = Fun.protect (fun () -> ${manager}) ~finally:(fun () -> Second_manager.run ())\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await write(
      "support/unknown/dune",
      "(library (name unknown) (wrapped false))\n",
    );
    await write(
      "support/unknown/unknown.ml",
      "let accept callback = ignore callback\n",
    );
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib second_manager unknown))\n",
    );
    const unknownCallback = await scenario(
      "unknown callback API does not prove execution",
      `let hidden () = ${manager}; Second_manager.run ()\nlet show () = Unknown.accept hidden\n`,
      ["GAP-CALLBACK-SEMANTICS"],
      2,
    );
    assert(
      !unknownCallback.report.findings.some((f) =>
        f.rule === "UC-CLIENT-MULTI-MANAGER"
      ),
      "unknown callback must not assert execution",
    );
    const wrappedCallback = await scenario(
      "wrapped callback to unknown API stays incomplete",
      `type handler = {run : unit -> unit}\nlet show () = Unknown.accept {run = (fun () -> ${manager}; Second_manager.run ())}\n`,
      ["GAP-CALLBACK-SEMANTICS"],
      2,
    );
    assert(
      !wrappedCallback.report.findings.some((f) =>
        f.rule === "UC-CLIENT-MULTI-MANAGER"
      ),
      "wrapped closure does not prove invocation",
    );
    const ambiguousCallback = await scenario(
      "separate callback bindings preserve mutually exclusive paths",
      `let invoke callback = callback ()\nlet first () = ${manager}\nlet second () = Second_manager.run ()\nlet show yes = if yes then invoke first else invoke second\n`,
      [],
      0,
    );
    assert(
      ambiguousCallback.report.summary.violations === 0,
      "separate callback bindings do not create a combined Manager path",
    );
    const callbackPolicy = await Deno.readTextFile(`${root}/szaniec.toml`);
    const callbackDune = await Deno.readTextFile(`${root}/lib/web_client/dune`);
    await write(
      "lib/callback_utility/dune",
      "(library (name callback_utility))\n",
    );
    await write(
      "lib/callback_utility/api.ml",
      "let choose yes ~first ~second = if yes then first () else second ()\n",
    );
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      callbackPolicy +
        `\n[[policy.local_services]]\nname = "CallbackUtility"\nroot = "lib/callback_utility"\n[[policy.public_contracts]]\nservice = "CallbackUtility"\nmodule = "Callback_utility.Api"\nmembers = ["choose"]\nconsumers = ["Web_client"]\n`,
    );
    await write(
      "lib/web_client/dune",
      callbackDune.replace("(libraries ", "(libraries callback_utility "),
    );
    await approve();
    await scenario(
      "callbacks across a public Utility retain branch correlation",
      `let show yes = Callback_utility.Api.choose yes ~first:(fun () -> ${manager}) ~second:(fun () -> Second_manager.run ())\n`,
    );
    await scenario(
      "public Utility callback retains a two-Manager violation",
      `let show yes = Callback_utility.Api.choose yes ~first:(fun () -> ${manager}; Second_manager.run ()) ~second:(fun () -> ())\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "public Utility callback retains protected Access calls",
      `let show yes = Callback_utility.Api.choose yes ~first:(fun () -> ${access}) ~second:(fun () -> ())\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await Deno.writeTextFile(`${root}/szaniec.toml`, callbackPolicy);
    await write("lib/web_client/dune", callbackDune);
    await Deno.remove(`${root}/lib/callback_utility`, { recursive: true });
    await approve();
    await scenario(
      "wide path alternatives with one reachable Manager have a safe bound",
      `${
        Array.from({ length: 9 }, (_, i) => `let h${i} () = ${manager}`).join(
          "\n",
        )
      }\nlet show n =\n${
        Array.from(
          { length: 9 },
          (_, i) => `(if n land ${1 << i} <> 0 then h${i} ());`,
        ).join("\n")
      }\n()\n`,
    );
    await scenario(
      "wide path alternatives with two possible Managers remain incomplete",
      `${
        Array.from({ length: 9 }, (_, i) =>
          `let h${i} () = ${i === 8 ? "Second_manager.run ()" : manager}`).join(
            "\n",
          )
      }\nlet show n =\n${
        Array.from({ length: 9 }, (_, i) =>
          `(if n land ${1 << i} <> 0 then h${i} ());`).join("\n")
      }\n()\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    const recursiveUnknown = await scenario(
      "recursive multi-target uncertainty",
      `let rec helper n = if n > 0 then ((if n mod 2 = 0 then ${manager} else Second_manager.run ()); helper (n - 1))\nlet show n = helper n\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    assert(
      recursiveUnknown.report.findings.some((f) =>
        f.rule === "GAP-AMBIGUOUS-PATH" &&
        f.message.includes("recursive helper")
      ),
      "concrete recursive limit",
    );
    await scenario(
      "exception reachability bound preserves structural violations",
      `let show () = try ${manager} with _ -> ${access}\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "unknown exception completion with multiple possible Managers",
      `let show () = try ${manager} with _ -> Second_manager.run ()\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib second_manager unknown) (flags (:standard -w -21)))\n",
    );
    await scenario(
      "raise prevents an infeasible multi-Manager continuation",
      `let show () = ${manager}; raise Exit; Second_manager.run ()\n`,
    );
    await scenario(
      "raising helper prevents an infeasible continuation",
      `let helper () = ${manager}; raise Exit\nlet show () = helper (); Second_manager.run ()\n`,
    );
    await scenario(
      "raising alias prevents an infeasible continuation",
      `let stop = raise\nlet show () = ${manager}; stop Exit; Second_manager.run ()\n`,
    );
    await scenario(
      "explicit exception selects one handler",
      `let show () = try raise Exit with Exit -> ${manager} | _ -> ${access}\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "recursive single-target bound preserves structural findings",
      `let rec helper n = if n > 0 then (${access}; helper (n - 1))\nlet show n = helper n\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    const recursiveCallbacks =
      "let with_lock f = if Random.bool () then f () else Fun.protect ~finally:(fun () -> ()) f\n" +
      "let rec with_write f = match with_lock (fun () -> if Random.bool () then None else Some (f ())) with Some result -> result | None -> with_write f\n";
    await scenario(
      "recursive write callbacks have a closed single-Manager upper bound",
      recursiveCallbacks +
        `let show () = with_lock (fun () -> ()); with_write (fun () -> ${manager})\n`,
    );
    await scenario(
      "recursive write callbacks with distinct Managers remain incomplete",
      recursiveCallbacks +
        `let first () = with_write (fun () -> ${manager})\nlet second () = with_write (fun () -> Second_manager.run ())\nlet show () = first (); second ()\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    assert(
      (await Deno.readTextFile(`${root}/_build/graph.json`)).includes(
        "recursive helper reference",
      ),
      "recursive execution remains unknown despite a safe fan-out bound",
    );

    await write(client, "let show () = ()\n");
    await write(
      "lib/web_client/runtime.ml",
      "let register () = ()\nlet private_member () = ()\n",
    );
    await write(
      "lib/web_client/runtime.mli",
      "val register : unit -> unit\nval private_member : unit -> unit\n",
    );
    const bootstrap = await Deno.readTextFile(
      `${root}/lib/bootstrap/bootstrap.ml`,
    );
    await write(
      "lib/bootstrap/dune",
      "(library (name bootstrap) (libraries well task_access_lib task_manager_lib web_client_lib replay_utility_lib second_manager))\n",
    );
    await write(
      "lib/bootstrap/bootstrap.ml",
      bootstrap + "\nlet () = Web_client_lib.Runtime.register ()\n",
    );
    await write(
      "lib/replay_utility/dune",
      "(library (name replay_utility_lib) (libraries sqlite3))\n",
    );
    await write(
      "lib/replay_utility/store.ml",
      'let read () = let db = Sqlite3.db_open ":memory:" in ignore (Sqlite3.exec db "select 1")\nlet lock () = ()\n',
    );
    await write(
      "lib/replay_utility/api.ml",
      "let replay () = Store.read ()\nlet maintain () = Store.read ()\n",
    );
    await write(
      "lib/replay_utility/api.mli",
      "val replay : unit -> unit\nval maintain : unit -> unit\n",
    );
    await write(
      "lib/replay_utility/maintenance.ml",
      "let trim () = Store.read ()\n",
    );
    await write(
      "lib/replay_utility/maintenance.mli",
      "val trim : unit -> unit\n",
    );
    const localPolicy = policy + `
[[policy.local_services]]
name = "ReplayUtility"
root = "lib/replay_utility"
[[policy.public_contracts]]
service = "ReplayUtility"
module = "Replay_utility_lib.Api"
members = ["replay"]
consumers = ["Task_manager"]
[[policy.public_contracts]]
service = "ReplayUtility"
module = "Replay_utility_lib.Maintenance"
members = ["trim"]
consumers = ["Task_access"]
[[policy.public_contracts]]
service = "Web_client"
module = "Web_client_lib.Runtime"
members = ["register"]
consumers = ["Bootstrap"]
`;
    const managerPath = "lib/task_manager/task_manager_impl.ml";
    const managerSource = await Deno.readTextFile(`${root}/${managerPath}`);
    await write(
      "lib/task_manager/dune",
      "(library (name task_manager_lib) (libraries app_contract task_access_lib replay_utility_lib))\n",
    );
    await write(
      managerPath,
      managerSource + "\nlet replay () = Replay_utility_lib.Api.replay ()\n",
    );
    await write(
      "lib/task_access/dune",
      "(include_subdirs qualified)\n(library (name task_access_lib) (libraries app_contract replay_utility_lib))\n",
    );
    await write(
      "lib/task_access/task_access_impl.ml",
      await Deno.readTextFile(`${root}/lib/task_access/task_access_impl.ml`) +
        "\nlet maintenance () = Replay_utility_lib.Maintenance.trim ()\n",
    );
    await Deno.writeTextFile(`${root}/szaniec.toml`, localPolicy);
    await approve();
    await scenario(
      "approved local Utility and Client facet",
      "let show () = ()\n",
    );
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib replay_utility_lib))\n",
    );
    await scenario(
      "private Store remains private",
      "let show () = Replay_utility_lib.Store.lock ()\n",
      ["IMPL-ACCESS-CROSS-SERVICE"],
      1,
    );
    await scenario(
      "unlisted local facade consumer",
      "let show () = Replay_utility_lib.Api.replay ()\n",
      ["IMPL-ACCESS-CROSS-SERVICE"],
      1,
    );
    await write(client, "let show () = ()\n");
    await write(
      "lib/web_client/runtime.ml",
      'let register () = ignore (Sqlite3.db_open ":memory:")\nlet private_member () = ()\n',
    );
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) => f.rule === "RESOURCE-BOUNDARY"),
      "Client facet cannot hide resource access: " + result.out,
    );
    await write(
      "lib/web_client/runtime.ml",
      "let register () = ignore (Task_access_lib.Store.read ())\nlet private_member () = ()\n",
    );
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) =>
          f.rule === "IMPL-ACCESS-CROSS-SERVICE"
        ),
      "Client facet cannot hide foreign private access: " + result.out,
    );
    await write(
      "lib/web_client/runtime.ml",
      "let register () = ()\nlet private_member () = ()\n",
    );
    await write(
      "lib/bootstrap/bootstrap.ml",
      bootstrap + "\nlet () = Web_client_lib.Runtime.private_member ()\n",
    );
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) =>
          f.rule === "IMPL-ACCESS-CROSS-SERVICE"
        ),
      result.out,
    );
    await write(
      "lib/bootstrap/bootstrap.ml",
      bootstrap + "\nlet () = Web_client_lib.Runtime.register ()\n",
    );
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      localPolicy.replace('members = ["register"]', 'members = ["missing"]'),
    );
    await approve();
    result = await check();
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-PUBLIC-CONTRACT"),
      result.out,
    );
    await Deno.writeTextFile(`${root}/szaniec.toml`, localPolicy);
    result = await check();
    assert(
      result.code === 2 &&
        result.report.findings.some((f) =>
          f.rule === "GAP-POLICY-NOT-APPROVED"
        ),
      result.out,
    );
    await approve();

    // The real Well preprocessor emits compiler AST locations for authored MLX.
    result = await check();
    assert(result.code === 0, result.out + result.err);
    const acceptedLocalPolicy = await Deno.readTextFile(`${root}/szaniec.toml`);
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      acceptedLocalPolicy +
        '\n[[policy.local_services]]\nname = "Replay_utility"\nroot = "lib/replay_utility"\n',
    );
    await approve();
    result = await check();
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-LOCAL-SERVICE"),
      "conflicting local ownership stays a gap",
    );
    await Deno.writeTextFile(`${root}/szaniec.toml`, acceptedLocalPolicy);
    await approve();
    result = await check();
    assert(result.code === 0, result.out + result.err);
    const storeSource = await Deno.readTextFile(
      `${root}/lib/replay_utility/store.ml`,
    );
    await write(
      "lib/replay_utility/store.ml",
      storeSource + "\n(* changed private source *)\n",
    );
    result = await check(false);
    assert(
      result.code === 2 && result.report.findings.some((f) =>
        f.rule === "GAP-STALE-ARTIFACT"
      ) && result.report.findings.some((f) => f.rule === "GAP-LOCAL-SERVICE"),
      "stale local ownership remains incomplete",
    );
    assert(
      result.report.findings.some((f) =>
        f.rule === "GAP-UNRESOLVED-TARGET" &&
        f.message.includes("GAP-STALE-ARTIFACT")
      ),
      "dependent target gaps explain upstream freshness",
    );
    await write("lib/replay_utility/store.ml", storeSource);
    const clientSurface = `[[policy.public_contracts]]
service = "Web_client"
module = "Web_client_lib.Runtime"
members = ["register"]
consumers = ["Bootstrap"]
`;
    assert(
      localPolicy.includes(clientSurface),
      "literal Client surface fixture",
    );
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      localPolicy.replace(clientSurface, ""),
    );
    await approve();
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) =>
          f.rule === "IMPL-ACCESS-CROSS-SERVICE"
        ),
      "mli/Runtime naming alone grants no Client contract",
    );
    await Deno.writeTextFile(`${root}/szaniec.toml`, acceptedLocalPolicy);
    await approve();
    await write(
      "lib/rule_engine/dune",
      "(library (name rule_engine_lib) (wrapped false) (libraries well))\n",
    );
    await write(
      "lib/rule_engine/Rule_engine.cyrograf",
      "rpc apply(Unit) -> Unit\n",
    );
    await write(
      "lib/rule_engine/rule_engine.ml",
      'let apply () = ()\nlet make_spec () = Well.Service.{name = "Rule_engine"}\n',
    );
    await write(
      "lib/rule_engine/rule_engine_impl.ml",
      "let apply () = ()\nlet spec = Rule_engine.make_spec ()\n",
    );
    await write(
      "lib/bootstrap/bootstrap.ml",
      await Deno.readTextFile(`${root}/lib/bootstrap/bootstrap.ml`) +
        "\nlet () = Well.Service.register Rule_engine_impl.spec\n",
    );
    await write(
      "lib/bootstrap/dune",
      "(library (name bootstrap) (libraries well task_access_lib task_manager_lib web_client_lib replay_utility_lib second_manager rule_engine_lib))\n",
    );
    await write("support/html/dune", "(library (name html) (wrapped false))\n");
    await write(
      "support/html/html.ml",
      "let tag _ ~attrs ~bool_attrs ~handlers ~children () = ignore (attrs, bool_attrs, handlers, children)\nlet txt (_ : string) = ()\n",
    );
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib replay_utility_lib html second_manager rule_engine_lib))\n",
    );
    const beforeMLX = await check();
    assert(beforeMLX.code === 0, beforeMLX.err + beforeMLX.out);
    await write(
      "dune-project",
      await Deno.readTextFile(`${root}/dune-project`) + `
(dialect (name mlx) (implementation (extension mlx)
 (preprocess (run well-mlx-pp %{input-file}))))
`,
    );
    await Deno.remove(`${root}/${client}`);
    await write(
      "lib/web_client/page.mlx",
      `let component () = <div></div>\nlet show () = ${manager}; component ()\n`,
    );
    result = await check();
    assert(result.code === 0, `MLX Manager: ${result.err}${result.out}`);
    assert(
      result.report.summary.units === beforeMLX.report.summary.units,
      "MLX acquisition does not count authored/generated units twice",
    );
    await write(
      "lib/web_client/page.mlx",
      "let show () = Rule_engine.apply ()\n",
    );
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) => f.rule === "ID-CLIENT-ENGINE"),
      "MLX Engine: " + result.out,
    );
    await write(
      "lib/web_client/page.mlx",
      "let show () = ignore (Task_access_lib.Store.read ())\n",
    );
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) =>
          f.rule === "IMPL-ACCESS-CROSS-SERVICE"
        ),
      "MLX private implementation: " + result.out,
    );
    await write(
      "lib/web_client/page.mlx",
      `let helper () = ${access}\nlet show yes = if yes then List.iter helper [()] else ()\n`,
    );
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) => f.rule === "ID-CLIENT-ACCESS"),
      "MLX branches/helpers/callbacks: " + result.out,
    );
    await write("lib/web_client/page.mlx", `let show () = ${access}\n`);
    result = await check();
    assert(
      result.code === 1 &&
        result.report.findings.some((f) =>
          f.rule === "ID-CLIENT-ACCESS" &&
          f.locations.some((l) => l.path.endsWith("page.mlx"))
        ),
      `MLX Access location: ${result.err}${result.out}`,
    );
    const mapped = await check(false);
    const mappedUncached = await check(false, {
      SZANIEC_OBSERVATION_CACHE: "off",
    });
    assert(
      mapped.out === result.out && mappedUncached.out === result.out,
      "MLX cached provenance",
    );
    const dialect = await Deno.readTextFile(`${root}/dune-project`);
    await write(
      "dune-project",
      dialect.replace(
        "run well-mlx-pp %{input-file}",
        "run well-mlx-pp -print-ml %{input-file}",
      ),
    );
    result = await check();
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-SOURCE-MAPPING"),
      "unmapped MLX is incomplete: " + result.out,
    );
    assert(
      (await check(false)).out === result.out &&
        (await check(false, { SZANIEC_OBSERVATION_CACHE: "off" })).out ===
          result.out,
      "unmapped MLX gap survives cache reuse",
    );
    await write("dune-project", dialect);
    result = await check();
    assert(result.code === 1, result.out + result.err);
    await write("lib/web_client/page.mlx", `let show () = ${manager}\n`);
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) =>
          ["GAP-STALE-ARTIFACT", "GAP-UNVERIFIABLE-TRANSFORMATION"].includes(
            f.rule,
          )
        ),
      "changed authored MLX cannot reuse transformation",
    );
    result = await check();
    assert(result.code === 0, result.out + result.err);
    const transformed = "lib/generated/preprocessed/transform.ts";
    const transformation = await Deno.readTextFile(`${root}/${transformed}`);
    await write(
      transformed,
      transformation + "\n// changed transformation dependency\n",
    );
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) =>
          f.rule === "GAP-UNVERIFIABLE-TRANSFORMATION"
        ),
      "changed preprocessor dependency invalidates receipt",
    );
    result = await check();
    assert(result.code === 0, result.out + result.err);
    const transformBuild = "lib/generated/preprocessed/dune";
    const transformBuildSource = await Deno.readTextFile(
      `${root}/${transformBuild}`,
    );
    await write("lib/generated/preprocessed/settings.dat", "initial\n");
    await write(
      transformBuild,
      transformBuildSource.replace(
        "(preprocessor_deps transform.ts)",
        "(preprocessor_deps transform.ts settings.dat)",
      ),
    );
    result = await check();
    assert(result.code === 0, result.out + result.err);
    await write("lib/generated/preprocessed/settings.dat", "changed\n");
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) =>
          f.rule === "GAP-UNVERIFIABLE-TRANSFORMATION"
        ),
      "literal preprocessing dependencies invalidate transformation receipts",
    );
    result = await check();
    assert(result.code === 0, result.out + result.err);
    await Deno.remove(
      `${root}/_build/default/lib/generated/preprocessed/projection.pp.ml`,
    );
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-MISSING-INPUT"),
      "missing generated input is distinct",
    );
    result = await check();
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-MISSING-INPUT"),
      "successful no-op build cannot certify a missing compiler input",
    );
    await write(
      "lib/generated/preprocessed/projection.ml",
      await Deno.readTextFile(
        `${root}/lib/generated/preprocessed/projection.ml`,
      ) + "\n(* regenerate the deliberately removed compiler input *)\n",
    );
    result = await check();
    assert(result.code === 0, result.out + result.err);
    await Deno.remove(`${root}/lib/web_client/page.mlx`);
    await write(client, `let show () = ${manager}\n`);
    await write(
      "lib/web_client/dune",
      "(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib replay_utility_lib) (flags (:standard -pp cat)))\n",
    );
    await scenario(
      "compiler-applied PP provenance",
      `let show () = ${manager}\n`,
    );
    await write(
      "support/ppx/dune",
      "(executable (name identity_ppx) (libraries compiler-libs.common))\n",
    );
    await write(
      "support/ppx/identity_ppx.ml",
      "let () = Ast_mapper.run_main (fun _ -> Ast_mapper.default_mapper)\n",
    );
    const ppx = await command("dune", [
      "build",
      "support/ppx/identity_ppx.exe",
    ]);
    assert(ppx.code === 0, ppx.err + ppx.out);
    await write(
      "lib/web_client/dune",
      `(library (name web_client_lib) (libraries app_contract app_browser sqlite3 task_access_lib replay_utility_lib) (flags (:standard -ppx ${root}/_build/default/support/ppx/identity_ppx.exe)))\n`,
    );
    await scenario(
      "compiler-applied PPX provenance",
      `let show () = ${manager}\n`,
    );
    await write(
      "lib/web_client/runtime.mli",
      "val register : unit -> unit\nval private_member : unit -> unit\nval added : unit -> unit\n",
    );
    result = await check(false);
    assert(
      result.code === 2 &&
        result.report.findings.some((f) =>
          f.rule === "GAP-STALE-ARTIFACT" ||
          f.rule === "GAP-UNVERIFIABLE-TRANSFORMATION"
        ),
      "stale transformed interface fails closed",
    );
    result = await check();
    assert(
      result.code === 2 &&
        result.report.findings.some((f) => f.rule === "GAP-BUILD"),
      "failed PPX build stays incomplete",
    );
    console.log(
      "local ownership, transformation receipts and compiler-mapped MLX: ok",
    );
  } finally {
    if (!retained) await Deno.remove(root, { recursive: true });
  }
});
