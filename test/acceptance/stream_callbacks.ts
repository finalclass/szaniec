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
Deno.test("lazy sequences, scoped runtime callbacks and streaming results", async () => {
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
    console.log(`${name}: ok`);
    return result;
  }
  const message = 'App_contract.Common.Message.make ~value:"test"';
  const manager =
    `ignore (App_contract.Task_manager.read ~ctx:() (${message}))`;
  const access = `ignore (App_contract.Task_access.read ~ctx:() (${message}))`;
  try {
    await copy(`${repository}/test/fixtures/owned-contracts-app`, root);
    await approve();
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
      "(library (name web_client_lib) (libraries app_contract app_browser task_access_lib second_manager runtime_stub))\n",
    );

    await write(
      "support/runtime/dune",
      "(library (name runtime_stub) (wrapped false))\n",
    );
    await write(
      "support/runtime/eio.ml",
      `module Fiber = struct
      type 'a key = 'a option ref
      let create_key () = ref None
      let get key = !key
      let with_binding key value f = let old = !key in key := Some value; Fun.protect f ~finally:(fun () -> key := old)
    end
    module Mutex = struct let use_rw ~protect lock f = ignore (protect,lock); f () end
    `,
    );
    await write("support/runtime/eio_main.ml", "let run f = f ()\n");
    await write(
      "lib/well/well.ml",
      (await Deno.readTextFile(`${root}/lib/well/well.ml`)) + `
      type accepted = {accept_iter : (string -> unit) -> unit}
      type stream_open_result = Stream_accept of accepted | Stream_reject of unit
      let stream_open f = match f () with Stream_accept accepted -> accepted.accept_iter ignore | Stream_reject () -> ()
      let stream f = f ignore
    `,
    );
    await scenario(
      "append construction is lazy",
      `let show () = let unused = Seq.append (Seq.map (fun () -> ${manager}; Second_manager.run ()) (List.to_seq [()])) Seq.empty in ignore unused\n`,
    );
    await scenario(
      "append consumption reaches both Managers",
      `let show () = ignore (List.of_seq (Seq.append (Seq.map (fun () -> ${manager}; Second_manager.run ()) (List.to_seq [()])) Seq.empty))\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "recursive sequence tail consumption",
      `let rec consume n items = if n > 0 then match items () with Seq.Nil -> () | Seq.Cons (_, rest) -> consume (n - 1) rest\nlet show () = consume 3 (Seq.filter (fun _ -> true) (Seq.append (List.to_seq [()]) Seq.empty))\n`,
    );
    await scenario(
      "returned record passed through a constructor",
      `type source = {iter : (string -> unit) -> unit}\nlet source () = Ok {iter=(fun write -> write "chunk")}\nlet show () = match source () with Ok src -> src.iter ignore | Error () -> ()\n`,
    );
    await scenario(
      "returned record retains forbidden callback",
      `type source = {iter : (string -> unit) -> unit}\nlet source () = Ok {iter=(fun write -> ${access}; write "chunk")}\nlet show () = match source () with Ok src -> src.iter ignore | Error () -> ()\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "known forwarded record agrees with the constructed branch",
      `type source = {iter : unit -> unit}\nlet known () = ${manager}\nlet source yes other = if yes then Ok {iter=known} else Ok other\nlet show yes = match source yes {iter=known} with Ok src -> src.iter () | Error () -> ()\n`,
    );
    await scenario(
      "unknown forwarded record keeps the constructed branch incomplete",
      `type source = {iter : unit -> unit}\nlet known () = ${manager}\nlet source yes other = if yes then Ok {iter=known} else Ok other\nlet show yes other = match source yes other with Ok src -> src.iter () | Error () -> ()\n`,
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "different forwarded record keeps the constructed branch incomplete",
      `type source = {iter : unit -> unit}\nlet known () = ${manager}\nlet other () = Second_manager.run ()\nlet source yes other = if yes then Ok {iter=known} else Ok other\nlet show yes = match source yes {iter=other} with Ok src -> src.iter () | Error () -> ()\n`,
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "unknown record callback remains incomplete",
      `type source = {iter : (string -> unit) -> unit}\nlet source callback = Ok {iter=callback}\nlet show callback = match source callback with Ok src -> src.iter ignore | Error () -> ()\n`,
      ["GAP-UNRESOLVED-CALL"],
      2,
    );

    await scenario(
      "Eio entry executes its callback",
      `let show () = Eio_main.run (fun _ -> ${manager}; Second_manager.run ())\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    const fiber =
      "let key : (unit -> unit) Eio.Fiber.key = Eio.Fiber.create_key ()\nlet fetch () = match Eio.Fiber.get key with Some f -> f () | None -> ()\n";
    await scenario(
      "fresh fiber binding resolves the Some branch",
      fiber +
        "let show () = Eio_main.run (fun _ -> Eio.Fiber.with_binding key (fun () -> ()) fetch)\n",
    );
    await scenario(
      "fiber binding retains forbidden callback",
      fiber +
        `let show () = Eio_main.run (fun _ -> Eio.Fiber.with_binding key (fun () -> ${access}) fetch)\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "unknown fiber value remains incomplete",
      fiber + "let show unknown = Eio.Fiber.with_binding key unknown fetch\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "escaped fiber key remains incomplete",
      fiber +
        "let expose () = key\nlet show () = Eio.Fiber.with_binding key (fun () -> ()) fetch\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "accepted stream supplies the writer through recursion",
      `let rec emit write n = if n > 0 then (write "chunk"; emit write (n - 1))\nlet show () = Well.stream_open (fun _ -> Well.Stream_accept {accept_iter=(fun write -> emit write 3)})\n`,
    );
    await scenario(
      "stream callback retains forbidden service",
      `let rec emit write n = if n > 0 then (${access}; write "chunk"; emit write (n - 1))\nlet show () = Well.stream_open (fun _ -> Well.Stream_accept {accept_iter=(fun write -> emit write 3)})\n`,
      ["ID-CLIENT-ACCESS"],
      1,
    );
    await scenario(
      "unknown recursive writer remains incomplete",
      'let rec emit write n = if n > 0 then (write "chunk"; emit write (n - 1))\nlet show write = emit write 3\n',
      ["GAP-UNRESOLVED-CALL"],
      2,
    );

    await scenario(
      "nested protected stream result preserves the writer",
      `let protect f = try Ok (f ()) with Exit -> Error () | exn -> raise exn
let lock f = Eio.Mutex.use_rw ~protect:true () (fun () -> protect f)
let source () = protect (fun () -> let rec emit write n = if n > 0 then (write "chunk"; emit write (n - 1)) in ("text/plain", fun write -> emit write 3))
let show () = Well.stream_open (fun _ -> match source () with Error () -> Well.Stream_reject () | Ok (_, iter) -> Well.Stream_accept {accept_iter=(fun write -> ignore (lock (fun () -> iter write)))})
`,
    );
    await scenario(
      "recoverable exception alternatives stay disjoint",
      `let protect f = try Ok (f ()) with Exit -> Error () | exn -> raise exn
let show choose = ignore (protect (fun () -> if choose then ${manager} else Second_manager.run ()))
`,
    );
    await scenario(
      "protected executable path still detects two Managers",
      `let protect f = try Ok (f ()) with Exit -> Error () | exn -> raise exn
let show () = ignore (protect (fun () -> ${manager}; Second_manager.run ()))
`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );

    await scenario(
      "conditional lazy sequence construction stays inert",
      `let show yes = let seq = if yes then (fun () -> ${manager}; Second_manager.run (); Seq.Nil) else Seq.empty in ignore seq
`,
    );
    await scenario(
      "conditional lazy sequence consumption retains calls",
      `let show yes = let seq = if yes then (fun () -> ${manager}; Second_manager.run (); Seq.Nil) else Seq.empty in ignore (List.of_seq seq)
`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "flat_map forces the returned sequence",
      `let show () = ignore (List.of_seq (Seq.flat_map (fun () -> fun () -> ${manager}; Second_manager.run (); Seq.Nil) (List.to_seq [()])))
`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "recursive tree sequence and bounded tail consumer",
      `let rec walk n () = if n = 0 then Seq.Nil else let root = if n mod 2 = 0 then List.to_seq [()] else Seq.empty in let children = Seq.flat_map (fun () -> walk (n - 1)) (List.to_seq [()]) in Seq.append root children ()
let rec consume n items = if n > 0 then match items () with Seq.Nil -> () | Seq.Cons (_, rest) -> consume (n - 1) rest
let show () = consume 3 (Seq.filter (fun _ -> true) (walk 3))
`,
    );

    await scenario(
      "flat_map construction does not force its returned sequence",
      `let show () = let unused = Seq.flat_map (fun () -> fun () -> ${manager}; Second_manager.run (); Seq.Nil) (List.to_seq [()]) in ignore unused
`,
    );
    await scenario(
      "conditional thunks keep disjoint Managers separate",
      `let show yes = let seq = if yes then (fun () -> ${manager}; Seq.Nil) else (fun () -> Second_manager.run (); Seq.Nil) in ignore (List.of_seq seq)
`,
    );
    await scenario(
      "append executes successive sequence effects",
      `let show () = ignore (List.of_seq (Seq.append (fun () -> ${manager}; Seq.Nil) (fun () -> Second_manager.run (); Seq.Nil)))
`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "external sequence tail remains unresolved",
      `let rec consume n items = if n > 0 then match items () with Seq.Nil -> () | Seq.Cons (_, rest) -> consume (n - 1) rest
let show items = consume 3 items
`,
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "unknown accepted iterator remains incomplete",
      "let show accepted = Well.stream_open (fun _ -> Well.Stream_accept accepted)\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "rejected stream has no writer continuation",
      "let show () = Well.stream_open (fun _ -> Well.Stream_reject ())\n",
    );
    await scenario(
      "unknown accepted iterator through a helper remains incomplete",
      "let make accepted = Well.Stream_accept accepted\nlet show accepted = Well.stream_open (fun _ -> make accepted)\n",
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario(
      "partially applied flat_map callback forces its returned sequence",
      `let inner seq () = seq\nlet effects () = ${manager}; Second_manager.run (); Seq.Nil\nlet show () = ignore (List.of_seq (Seq.flat_map (inner effects) (List.to_seq [()])))\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    const bounded = await scenario(
      "one append node does not prove both sources execute",
      `let first () = ${manager}; Seq.Cons ((), Seq.empty)\nlet second () = Second_manager.run (); Seq.Nil\nlet show () = ignore ((Seq.append first second) ())\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    assert(
      bounded.report.summary.violations === 0,
      "single-node append falsely proves a violation",
    );
    const named = await scenario(
      "one named append node does not prove both sources execute",
      `let first () = ${manager}; Seq.Cons ((), Seq.empty)\nlet second () = Second_manager.run (); Seq.Nil\nlet show () = let items = Seq.append first second in ignore (items ())\n`,
      ["GAP-AMBIGUOUS-PATH"],
      2,
    );
    assert(
      named.report.summary.violations === 0,
      "named single-node append falsely proves a violation",
    );
    await scenario(
      "full named append consumption retains both sources",
      `let first () = ${manager}; Seq.Cons ((), Seq.empty)\nlet second () = Second_manager.run (); Seq.Nil\nlet show () = let items = Seq.append first second in ignore (List.of_seq items)\n`,
      ["UC-CLIENT-MULTI-MANAGER"],
      1,
    );
    await scenario(
      "single-node demand does not weaken later full consumption",
      `let first () = ${manager}; Seq.Cons ((), Seq.empty)\nlet second () = Second_manager.run (); Seq.Nil\nlet show () = let items = Seq.append first second in ignore (items ()); ignore (List.of_seq items)\n`,
      ["UC-CLIENT-MULTI-MANAGER", "GAP-AMBIGUOUS-PATH"],
      2,
    );
  } finally {
    if (!retained) await Deno.remove(root, { recursive: true });
  }
});
