// Source-to-report checks for the OCaml Cognitive Complexity profile.
const bin =
  new URL("../../_build/default/bin/szaniec.exe", import.meta.url).pathname;
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
const flatArms = Array.from({ length: 19 }, (_, i) => `| ${i} -> leaf ${i}`)
  .join("\n");
const nested = (depth: number): string =>
  depth === 0
    ? "leaf n"
    : `match input with Error _ -> 0 | Ok ${depth === 1 ? "n" : "_n"} -> (${
      nested(depth - 1)
    })`;
const source = `
let leaf n = n
let dispatch n = match n with ${flatArms} | _ -> leaf 19
let nested input = ${nested(7)}
let ( let* ) value next = match value with Ok x -> next x | Error e -> Error e
let chain input =
  let* a = input in
  let* b = input in
  let* c = input in
  Ok (a + b + c)
let bound_decision input =
  let* n = input in
  if n > 0 then Ok n else Ok 0
let ( let+ ) value next = match value with Ok x -> Ok (next x) | Error e -> Error e
let ( and+ ) a b = match a, b with
  | Ok x, Ok y -> Ok (x, y)
  | Error e, _ | _, Error e -> Error e
let parallel a b = let+ x = a and+ y = b in if x > y then x else y
let nested_ifs a b c = if a then (if b then (if c then ()))
let else_if a b = if a then 1 else if b then 2 else 3
let nested_else a b = if a then (if b then 1 else 2) else 3
let same_ops a b c d = a && b && c && d
let partial_boolean a = ( && ) a
let mixed_ops a b c d = (a && b) || (c && d)
let not_boundary a b c = a && not (b && c)
let guarded input = match input with n when n > 0 -> n | _ -> 0
let guarded_bool input a b = match input with n when a && b -> n | _ -> 0
let scrutinee input = match (match input with 0 -> 1 | n -> n) with 0 -> 1 | n -> n
let loop n = for i = 1 to n do if i > 0 then () done
let caught f = try f () with Failure _ -> 0 | _ -> 1
let caught_in_loop n f = for _i = 1 to n do
  try f () with Failure _ -> if n > 0 then () else () done
let local x = let helper y = if y then 1 else 0 in helper x
let callback xs = List.map (fun x -> if x then 1 else 0) xs
let optional ?(n = if true then 1 else 0) () = n
let refutable (Some n) = n [@@warning "-8"]
let rec recursive n = if n <= 0 then 0 else recursive (n - 1)
let rec even n = if n = 0 then true else odd (n - 1)
and odd n = if n = 0 then false else even (n - 1)
let rec acyclic n = terminal n
and terminal n = n [@@warning "-39"]
let rec unused_rec n = n [@@warning "-39"]
let rec shadowed n = let shadowed x = x in shadowed n [@@warning "-39"]
module Custom = struct
  let ( && ) a b = a + b
  let call a b = a && b
end
`;
// These are hand-derived acceptance examples, not snapshots of the walker.
const expectations: Record<string, [number, number]> = {
  leaf: [0, 1],
  dispatch: [1, 20],
  nested: [28, 8],
  "let*": [1, 2],
  chain: [0, 1],
  bound_decision: [2, 2],
  "let+": [1, 2],
  "and+": [1, 2],
  parallel: [2, 2],
  nested_ifs: [6, 4],
  else_if: [3, 3],
  nested_else: [5, 3],
  same_ops: [1, 4],
  partial_boolean: [0, 2],
  mixed_ops: [3, 4],
  not_boundary: [2, 3],
  guarded: [3, 3],
  guarded_bool: [4, 4],
  scrutinee: [2, 3],
  loop: [3, 3],
  caught: [2, 3],
  caught_in_loop: [7, 4],
  local: [0, 1],
  "local.helper": [2, 2],
  callback: [0, 1],
  "callback.anon": [2, 2],
  optional: [2, 2],
  refutable: [0, 1],
  recursive: [3, 2],
  even: [3, 2],
  odd: [3, 2],
  acyclic: [0, 1],
  terminal: [0, 1],
  unused_rec: [0, 1],
  shadowed: [0, 1],
  "shadowed.shadowed": [0, 1],
  "Custom.&&": [0, 1],
  "Custom.call": [0, 1],
};
type Entry = { qualname: string; complexity: number | null; metric: string };
type Report = {
  metric: string;
  functions: Entry[];
  summary: unknown;
  gaps: unknown[];
};
Deno.test("Cognitive Complexity distinguishes dispatch, nesting and Result sequencing", async () => {
  const root = await Deno.makeTempDir({ prefix: "szaniec-cognitive-" });
  try {
    await Deno.mkdir(`${root}/lib`);
    await Deno.writeTextFile(
      `${root}/dune-project`,
      "(lang dune 3.17)\n(package (name metric) (allow_empty) (depends (ocaml (and (>= 5.4) (< 5.5))) yojson))\n",
    );
    const fixtureLock =
      new URL("../fixtures/tasks-app/dune.lock", import.meta.url).pathname;
    const copyLock = await new Deno.Command("cp", {
      args: ["-R", fixtureLock, `${root}/dune.lock`],
    }).output();
    assert(copyLock.success, decoder.decode(copyLock.stderr));
    await Deno.writeTextFile(
      `${root}/lib/dune`,
      "(library (name metric) (flags (:standard -bin-annot)))\n",
    );
    await Deno.writeTextFile(`${root}/lib/metric.ml`, source);
    const config =
      `format = "szaniec-config/1"\n[policy]\nname = "metric"\nroots = ["lib"]\n`;
    await Deno.writeTextFile(`${root}/szaniec.toml`, config);
    async function run(...args: string[]) {
      const result = await new Deno.Command(bin, {
        args: ["complexity", "--project-root", root, "--json", ...args],
        stdout: "piped",
        stderr: "piped",
      }).output();
      const text = decoder.decode(result.stdout);
      assert(result.code === 0, decoder.decode(result.stderr) + text);
      return { report: JSON.parse(text) as Report, text };
    }
    const first = await run("--rebuild");
    const cached = await run();
    assert(first.text === cached.text, "cached cognitive report changed");
    const legacy = await run("--metric", "cyclomatic");
    for (
      const [report, index, metric] of [
        [first.report, 0, "szaniec-cognitive/1"],
        [legacy.report, 1, "szaniec-cc/1"],
      ] as const
    ) {
      assert(report.metric === metric, `wrong report metric ${report.metric}`);
      assert(report.gaps.length === 0, "unexpected measurement gap");
      assert(
        report.functions.length === Object.keys(expectations).length,
        `unexpected function inventory: ${
          report.functions.map((f) => f.qualname).join(", ")
        }`,
      );
      for (const [name, scores] of Object.entries(expectations)) {
        const matches = report.functions.filter((f) => f.qualname === name);
        assert(
          matches.length === 1,
          `${name}: expected one function, got ${matches.length}`,
        );
        assert(matches[0].metric === metric, `${name}: wrong entry metric`);
        assert(
          matches[0].complexity === scores[index],
          `${name}: ${metric} = ${matches[0].complexity}, expected ${
            scores[index]
          }`,
        );
      }
    }
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      config + '[complexity]\nmetric = "cyclomatic"\n',
    );
    assert(
      (await run()).report.metric === "szaniec-cc/1",
      "configured metric ignored",
    );
    assert(
      (await run("--metric", "cognitive")).report.metric ===
        "szaniec-cognitive/1",
      "CLI metric override ignored",
    );
    // An external build creates transformed artifacts without the checker's
    // provenance receipt. Missing evidence must not become a successful zero.
    await Deno.writeTextFile(
      `${root}/lib/dune`,
      "(library (name metric) (flags (:standard -bin-annot)) (preprocess (action (run cat %{input-file}))))\n",
    );
    const build = await new Deno.Command("dune", {
      args: ["build", "--root", root],
    }).output();
    assert(build.success, decoder.decode(build.stderr));
    const unverified = await new Deno.Command(bin, {
      args: ["complexity", "--project-root", root, "--json"],
    }).output();
    const gapReport = JSON.parse(decoder.decode(unverified.stdout));
    assert(
      unverified.code === 2 && gapReport.status === "incomplete" &&
        gapReport.gaps.some((g: { code: string }) =>
          g.code === "GAP-UNVERIFIABLE-TRANSFORMATION"
        ),
      "unverified transformation was silently accepted",
    );
    assert(
      (await run("--rebuild")).report.functions.length ===
        Object.keys(expectations).length,
      "verified rebuild did not recover the full inventory",
    );
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
