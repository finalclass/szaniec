const root = new URL("../../", import.meta.url).pathname;
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("approved Utility continuations retain caller ownership and unresolved storage evidence", async () => {
  const project = await Deno.makeTempDir({
    prefix: "szaniec-service-callbacks-",
  });
  async function write(path: string, text: string) {
    await Deno.mkdir(`${project}/${path.slice(0, path.lastIndexOf("/"))}`, {
      recursive: true,
    });
    await Deno.writeTextFile(`${project}/${path}`, text);
  }
  async function run(...args: string[]) {
    const r = await new Deno.Command(
      Deno.env.get("SZANIEC_CALLBACK_BINARY") ??
        `${root}_build/default/bin/szaniec.exe`,
      {
        cwd: project,
        args,
        stdout: "piped",
        stderr: "piped",
      },
    ).output();
    return {
      code: r.code,
      out: decoder.decode(r.stdout),
      err: decoder.decode(r.stderr),
    };
  }
  try {
    const copy = await new Deno.Command("cp", {
      args: ["-R", `${root}test/fixtures/tasks-app/.`, project],
    }).output();
    assert(copy.success, decoder.decode(copy.stderr));
    await write(
      "lib/transaction_utility/dune",
      `(include_subdirs no)\n(library (name transaction_utility) (wrapped false) (flags (:standard -bin-annot)))\n`,
    );
    await write(
      "lib/transaction_utility/transaction_api.ml",
      `
type scope = { rollback: (unit -> unit) list ref }
let scope = {rollback=ref []}
let on_rollback f = scope.rollback := f :: !(scope.rollback)
let run f = f ()
let compensate () = List.iter (fun f -> f ()) !(scope.rollback)
`,
    );
    await write(
      "lib/transaction_utility/transaction_api.mli",
      `
val on_rollback : (unit -> unit) -> unit
val run : (unit -> unit) -> unit
val compensate : unit -> unit
`,
    );
    await write(
      "lib/contract/TransactionUtility.cyrograf",
      "// Local technical transaction boundary; no RPC.\n",
    );
    const policy = `${project}/szaniec.toml`;
    await Deno.writeTextFile(
      policy,
      await Deno.readTextFile(policy) + `
[[policy.local_services]]
name = "TransactionUtility"
root = "lib/transaction_utility"
[[policy.public_contracts]]
service = "TransactionUtility"
module = "Transaction_api"
members = ["run", "on_rollback"]
consumers = ["Task_manager"]
`,
    );
    const dune = `${project}/lib/task_manager/dune`;
    await Deno.writeTextFile(
      dune,
      (await Deno.readTextFile(dune)).replace(
        "contract well task_access_lib",
        "contract well task_access_lib transaction_utility",
      ),
    );
    const source = `${project}/lib/task_manager/task_manager_impl.ml`;
    const original = await Deno.readTextFile(source);
    assert((await run("approve")).code === 0, "approve fixture scope");
    for (
      const registration of [
        `Transaction_api.on_rollback (fun () -> ignore (Task_access.list ~ctx ~limit:1))`,
        `let cleanup () = ignore (Task_access.list ~ctx ~limit:1) in Transaction_api.run cleanup`,
      ]
    ) {
      await Deno.writeTextFile(
        source,
        original + `\nlet register ctx = ${registration}\n`,
      );
      const checked = await run(
        "check",
        "--rebuild",
        "--json",
        "--no-callgraph",
      );
      const report = JSON.parse(checked.out);
      assert(
        !report.findings.some((f: { rule: string }) =>
          [
            "GAP-BUILD",
            "GAP-LOCAL-SERVICE",
            "GAP-PUBLIC-CONTRACT",
            "POLICY-UNCLASSIFIED",
          ].includes(f.rule)
        ),
        checked.err + checked.out,
      );
      assert(
        !report.findings.some((
          f: {
            rule: string;
            participants: string[];
            locations: { path: string }[];
          },
        ) =>
          f.rule === "IMPL-ACCESS-CROSS-SERVICE" &&
          f.participants.includes("TransactionUtility") &&
          f.participants.includes("Task_manager") &&
          f.locations.some((l) =>
            l.path === "lib/task_manager/task_manager_impl.ml"
          )
        ),
        "A Utility continuation must retain its originating service boundary: " +
          checked.err + checked.out,
      );
      assert(
        report.findings.some((f: { rule: string }) =>
          f.rule === "GAP-UNRESOLVED-CALL"
        ),
        "Unknown stored invocation evidence must remain explicit",
      );
      assert(
        checked.code === 2,
        "Unresolved stored invocation remains incomplete",
      );
    }
    await Deno.writeTextFile(
      source,
      original + `
let within_family f = f ()
let ordinary ctx = within_family (fun () -> ignore (Task_access.list ~ctx ~limit:1))
`,
    );
    const ordinary = await run(
      "check",
      "--rebuild",
      "--json",
      "--no-callgraph",
    );
    assert(
      !JSON.parse(ordinary.out).findings.some((f: { participants: string[] }) =>
        f.participants?.includes("TransactionUtility") &&
        f.participants.includes("Task_manager")
      ),
      "Private same-family callbacks do not cross a service boundary",
    );
    await write(
      "lib/transaction_utility/transaction_api.ml",
      `
type scope = { mutable after_commit: (unit -> unit) list }
let scope = {after_commit=[]}
let on_rollback f = scope.after_commit <- f :: scope.after_commit
let run f = f ()
let locked f = Fun.protect ~finally:(fun () -> ()) f
let owned () = locked (fun () -> if Sys.opaque_identity true then scope else failwith "No scope")
let collect () =
  locked (fun () ->
  let scope = owned () in
  let callbacks = List.rev scope.after_commit in
  scope.after_commit <- [];
  (true, callbacks))
let compensate () =
  ignore (locked (fun () -> 123));
  let _, callbacks = collect () in
  List.iter (fun callback -> callback ()) callbacks
`,
    );
    await Deno.writeTextFile(
      source,
      original + `
let register ctx = Transaction_api.run (fun () ->
  Transaction_api.on_rollback (fun () -> ignore (Task_access.list ~ctx ~limit:1)))
`,
    );
    const stored = await run("check", "--rebuild", "--json", "--no-callgraph");
    assert(
      stored.code === 0,
      "Known callback queue must resolve without adopting Manager code: " +
        stored.err + stored.out,
    );
    const appDune = `${project}/lib/dune`;
    await Deno.writeTextFile(
      policy,
      (await Deno.readTextFile(policy)).replace(
        'consumers = ["Task_manager"]',
        'consumers = ["Task_manager", "Web_client"]',
      ),
    );
    assert(
      (await run("approve")).code === 0,
      "approve the Client's technical Utility facet",
    );
    await Deno.writeTextFile(
      appDune,
      (await Deno.readTextFile(appDune)).replace(
        "contract\n",
        "contract\n  transaction_utility\n",
      ),
    );
    const client = `${project}/lib/web_client/tasks_page.ml`;
    const clientSource = await Deno.readTextFile(client);
    await Deno.writeTextFile(
      client,
      clientSource + `
let forbidden_continuation () =
  Transaction_api.run (fun () -> ignore (Task_access.list ~ctx:ctx_w ~limit:1))
`,
    );
    const forbidden = await run(
      "check",
      "--rebuild",
      "--json",
      "--no-callgraph",
    );
    assert(
      JSON.parse(forbidden.out).findings.some((
        f: { rule: string; participants: string[] },
      ) =>
        f.rule === "ID-CLIENT-ACCESS" && f.participants.includes("Web_client")
      ),
      "Utility must not launder a Client's Access call: " + forbidden.out,
    );
    await Deno.writeTextFile(client, clientSource);
    const utilityInterface =
      `${project}/lib/transaction_utility/transaction_api.mli`;
    const knownQueueInterface = await Deno.readTextFile(utilityInterface);
    const utilitySource =
      `${project}/lib/transaction_utility/transaction_api.ml`;
    const knownQueueSource = await Deno.readTextFile(utilitySource);
    await Deno.writeTextFile(
      utilityInterface,
      (await Deno.readTextFile(utilityInterface)) +
        "\nval unknown_writer : (unit -> (unit -> unit) list) -> unit\n",
    );
    await Deno.writeTextFile(
      `${project}/lib/transaction_utility/transaction_api.ml`,
      (await Deno.readTextFile(
        `${project}/lib/transaction_utility/transaction_api.ml`,
      )) + `\nlet unknown_writer make = scope.after_commit <- make ()\n`,
    );
    const unknown = await run("check", "--rebuild", "--json", "--no-callgraph");
    assert(
      !JSON.parse(unknown.out).findings.some((f: { rule: string }) =>
        f.rule === "GAP-BUILD"
      ),
      "Unknown-writer scenario must compile: " + unknown.err,
    );
    assert(
      unknown.code === 2 &&
        JSON.parse(unknown.out).findings.some((f: { rule: string }) =>
          f.rule === "GAP-UNRESOLVED-CALL"
        ),
      "Unknown queue writers must preserve incomplete analysis: " + unknown.out,
    );
    async function receiverRole(engine: boolean) {
      const from = engine ? "transaction_utility" : "transaction_engine";
      const to = engine ? "transaction_engine" : "transaction_utility";
      await Deno.rename(`${project}/lib/${from}`, `${project}/lib/${to}`);
      for (
        const file of [
          `${project}/lib/${to}/dune`,
          `${project}/lib/task_manager/dune`,
          `${project}/lib/dune`,
          policy,
        ]
      ) {
        await Deno.writeTextFile(
          file,
          (await Deno.readTextFile(file)).replaceAll(from, to).replaceAll(
            engine ? "TransactionUtility" : "Transaction_engine",
            engine ? "Transaction_engine" : "TransactionUtility",
          ),
        );
      }
    }
    await receiverRole(true);
    assert(
      (await run("approve")).code === 0,
      "approve an Engine facet without allowing private implementation sharing",
    );
    const business = await run(
      "check",
      "--rebuild",
      "--json",
      "--no-callgraph",
    );
    assert(
      !JSON.parse(business.out).findings.some((f: { rule: string }) =>
        [
          "GAP-BUILD",
          "GAP-LOCAL-SERVICE",
          "GAP-PUBLIC-CONTRACT",
          "POLICY-UNCLASSIFIED",
        ].includes(f.rule)
      ) && JSON.parse(business.out).findings.some((
        f: { rule: string; participants: string[] },
      ) =>
        f.rule === "IMPL-ACCESS-CROSS-SERVICE" &&
        f.participants.includes("Transaction_engine") &&
        f.participants.includes("Task_manager")
      ),
      "Business service facets still reject private callbacks: " + business.out,
    );
    await receiverRole(false);
    assert((await run("approve")).code === 0, "restore the approved Utility");
    await Deno.writeTextFile(
      `${project}/lib/well_stub/well.ml`,
      (await Deno.readTextFile(`${project}/lib/well_stub/well.ml`)) +
        "\nlet opaque_store_transfer _ = ()\n",
    );
    const utilityDune = `${project}/lib/transaction_utility/dune`;
    await Deno.writeTextFile(
      utilityDune,
      (await Deno.readTextFile(utilityDune)).replace(
        "(wrapped false)",
        "(wrapped false) (libraries well)",
      ),
    );
    await Deno.writeTextFile(
      utilityInterface,
      knownQueueInterface + "\nval opaque_writer : unit -> unit\n",
    );
    await Deno.writeTextFile(
      utilitySource,
      knownQueueSource +
        "\nlet opaque_writer () = Well.opaque_store_transfer scope\n",
    );
    const escaped = await run("check", "--rebuild", "--json", "--no-callgraph");
    const escapedReport = JSON.parse(escaped.out);
    assert(
      !escapedReport.findings.some((f: { rule: string }) =>
        f.rule === "GAP-BUILD"
      ),
      "Opaque-record scenario must compile: " + escaped.err,
    );
    assert(
      escaped.code === 2 &&
        escapedReport.findings.some((f: { rule: string }) =>
          f.rule === "GAP-UNRESOLVED-CALL"
        ),
      "Opaque record transfer must preserve unknown writers: " + escaped.out,
    );
    await Deno.writeTextFile(utilitySource, knownQueueSource);
    await Deno.writeTextFile(
      utilityInterface,
      "type scope = { mutable after_commit: (unit -> unit) list }\nval scope : scope\n" +
        knownQueueInterface,
    );
    for (
      const transfer of [
        "Well.opaque_store_transfer Transaction_api.scope",
        "Well.opaque_store_transfer {payload=Transaction_api.scope}",
        "Well.opaque_store_transfer (Payload Transaction_api.scope)",
        "Well.opaque_store_transfer (Inline {payload=Transaction_api.scope})",
        "Well.opaque_store_transfer (`Payload Transaction_api.scope)",
        "Well.opaque_store_transfer ((`Payload Transaction_api.scope) : poly_envelope)",
        "Well.opaque_store_transfer (More (Leaf (0, Transaction_api.scope)))",
        "List.iter Well.opaque_store_transfer [Transaction_api.scope]",
        "Option.iter Well.opaque_store_transfer (Some Transaction_api.scope)",
        "forward Transaction_api.scope",
        "alias_forward Transaction_api.scope",
        "forward (Some Transaction_api.scope)",
        "local_list_forward [Transaction_api.scope]",
        "List.iter (fun payload -> forward payload) [Transaction_api.scope]",
      ]
    ) {
      await write(
        "lib/transaction_utility/opaque_transfer.ml",
        `type envelope = {payload:Transaction_api.scope}
type variant_envelope = Payload of Transaction_api.scope
type inline_envelope = Inline of {payload:Transaction_api.scope}
type poly_envelope = [\`Payload of Transaction_api.scope]
type 'a nested_envelope = Leaf of 'a | More of ('a * Transaction_api.scope) nested_envelope
let forward payload = Well.opaque_store_transfer payload
let alias_forward payload = let alias = payload in Well.opaque_store_transfer alias
let local_list_forward payloads = List.iter Well.opaque_store_transfer payloads
let run () = ${transfer}
`,
      );
      const checked = await run(
        "check",
        "--rebuild",
        "--json",
        "--no-callgraph",
      );
      const report = JSON.parse(checked.out);
      assert(
        !report.findings.some((f: { rule: string }) =>
          [
            "GAP-BUILD",
            "GAP-LOCAL-SERVICE",
            "GAP-PUBLIC-CONTRACT",
            "POLICY-UNCLASSIFIED",
          ].includes(f.rule)
        ),
        "Transfer fixture must compile and retain ownership: " + checked.err +
          checked.out,
      );
      assert(
        checked.code === 2 &&
          report.findings.some((f: { rule: string }) =>
            f.rule === "GAP-UNRESOLVED-CALL"
          ),
        "Foreign-module and iterator transfers must retain unknown writers: " +
          transfer + checked.out,
      );
    }
    await Deno.remove(`${project}/lib/transaction_utility/opaque_transfer.ml`);
    for (const nested of [false, true]) {
      await write(
        "lib/transaction_utility/queue_payload.ml",
        nested
          ? `type 'a slot = { mutable callbacks: 'a list }
type 'a node = { payload: 'a slot; next: (unit -> unit) node option }
let leaf = { payload={callbacks=Transaction_api.scope.after_commit}; next=None }
let root = { payload={callbacks=[0]}; next=Some leaf }
let drain () = List.iter (fun callback -> callback ()) leaf.payload.callbacks
`
          : `type 'a node = { mutable callbacks: 'a list; next: (unit -> unit) node option }
let leaf = { callbacks=Transaction_api.scope.after_commit; next=None }
let root = { callbacks=[0]; next=Some leaf }
let drain () = List.iter (fun callback -> callback ()) leaf.callbacks
`,
      );
      const substitutedQueue = await run(
        "check",
        "--rebuild",
        "--json",
        "--no-callgraph",
      );
      assert(
        substitutedQueue.code === 0,
        "Known substituted queue must resolve: " + substitutedQueue.err +
          substitutedQueue.out,
      );
      await write(
        "lib/transaction_utility/opaque_transfer.ml",
        "let run () = Well.opaque_store_transfer Queue_payload.root\n",
      );
      const substitutedEscape = await run(
        "check",
        "--rebuild",
        "--json",
        "--no-callgraph",
      );
      const substitutedReport = JSON.parse(substitutedEscape.out);
      assert(
        !substitutedReport.findings.some((f: { rule: string }) =>
          f.rule === "GAP-BUILD"
        ) &&
          substitutedEscape.code === 2 &&
          substitutedReport.findings.some((f: { rule: string }) =>
            f.rule === "GAP-UNRESOLVED-CALL"
          ),
        "Repeated nominal heads must reclassify callable fields in another module: " +
          substitutedEscape.err + substitutedEscape.out,
      );
      await Deno.remove(
        `${project}/lib/transaction_utility/opaque_transfer.ml`,
      );
      await Deno.remove(`${project}/lib/transaction_utility/queue_payload.ml`);
    }
    await Deno.writeTextFile(
      `${project}/lib/well_stub/well.ml`,
      (await Deno.readTextFile(`${project}/lib/well_stub/well.ml`)) +
        "\nlet unknown_value () = Obj.magic 0\nlet unknown_values () = [Obj.magic 0]\n",
    );
    await write(
      "lib/transaction_utility/opaque_return.ml",
      "let obtain () = Well.unknown_value ()\nlet values = Well.unknown_values ()\n",
    );
    await write(
      "lib/transaction_utility/included_return.ml",
      "include Opaque_return\nlet value () = List.hd values\n",
    );
    for (
      const producer of [
        "Well.unknown_value ()",
        "obtain ()",
        "Opaque_return.obtain ()",
        "_protected_obtain ()",
        "_forwarded_obtain ()",
        "_from_values ()",
        "List.hd _values",
        "List.hd _tuple_values",
        "List.hd _alias_values",
        "_from_foreign_values ()",
        "List.hd Opaque_return.values",
        "Included_return.value ()",
      ]
    ) {
      await Deno.writeTextFile(
        utilitySource,
        knownQueueSource + `
let obtain () = Well.unknown_value ()
let _protected_obtain () = Fun.protect ~finally:(fun () -> ()) obtain
let identity value = value
let _forwarded_obtain () = identity (Well.unknown_value ())
let _values = Well.unknown_values ()
let (_tuple_values, _) = (Well.unknown_values (), 0)
let _alias_values = _values
let _from_values () = List.hd _values
let _from_foreign_values () = List.hd Opaque_return.values
let _foreign_compensation () =
  let foreign : scope = ${producer} in
  List.iter (fun callback -> callback ()) foreign.after_commit
`,
      );
      const checked = await run(
        "check",
        "--rebuild",
        "--json",
        "--no-callgraph",
      );
      const report = JSON.parse(checked.out);
      assert(
        !report.findings.some((f: { rule: string }) =>
          ["GAP-BUILD", "GAP-LOCAL-SERVICE", "GAP-PUBLIC-CONTRACT"].includes(
            f.rule,
          )
        ),
        "Generic producer fixture must compile and retain ownership: " +
          checked.err + checked.out,
      );
      assert(
        checked.code === 2 &&
          report.findings.some((f: { rule: string }) =>
            f.rule === "GAP-UNRESOLVED-CALL"
          ),
        "Generic producers must retain their opaque result origins: " +
          producer +
          checked.out,
      );
    }
    await Deno.remove(`${project}/lib/transaction_utility/opaque_return.ml`);
    await Deno.remove(`${project}/lib/transaction_utility/included_return.ml`);
    await Deno.writeTextFile(
      `${project}/lib/well_stub/well.ml`,
      (await Deno.readTextFile(`${project}/lib/well_stub/well.ml`)) +
        "\nlet unknown_queue () = (true, [])\n",
    );
    await Deno.writeTextFile(
      utilitySource,
      knownQueueSource.replace(
        "let collect () =",
        "let collect () = if Sys.opaque_identity true then (",
      ).replace(
        "(true, callbacks))",
        "(true, callbacks))) else Well.unknown_queue ()",
      ),
    );
    const alternative = await run(
      "check",
      "--rebuild",
      "--json",
      "--no-callgraph",
    );
    const alternativeReport = JSON.parse(alternative.out);
    assert(
      !alternativeReport.findings.some((f: { rule: string }) =>
        f.rule === "GAP-BUILD"
      ),
      "Alternative producer fixture must compile: " + alternative.err,
    );
    assert(
      alternative.code === 2 &&
        alternativeReport.findings.some((f: { rule: string }) =>
          f.rule === "GAP-UNRESOLVED-CALL"
        ),
      "Known projection must not hide an unknown whole-result branch: " +
        alternative.out,
    );
  } finally {
    await Deno.remove(project, { recursive: true });
  }
});
