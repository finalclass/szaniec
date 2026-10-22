const root = new URL("../../", import.meta.url).pathname;
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("owned service facets cannot receive another family's private callbacks", async () => {
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
        report.findings.some((
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
        "Receiving service must expose the private callback boundary violation: " +
          checked.err + checked.out,
      );
      assert(
        report.findings.some((f: { rule: string }) =>
          f.rule === "GAP-UNRESOLVED-CALL"
        ),
        "The unresolved stored invocation must remain a gap alongside the violation",
      );
      assert(
        checked.code === 2,
        "Violation plus unresolved target remains incomplete",
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
  } finally {
    await Deno.remove(project, { recursive: true });
  }
});
