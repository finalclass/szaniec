// Source-to-report checks for the OCaml Cognitive Complexity profile.
const bin = Deno.env.get("SZANIEC_COMPLEXITY_BINARY") ??
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
let method_call (receiver : < apply : int -> int >) n = receiver#apply n
let method_receiver select (left : < value : int >) right =
  (if select then left else right)#value
let method_argument (receiver : < apply : int -> int >) select =
  receiver#apply (if select then 1 else 0)
let method_callback (receiver : < apply : (bool -> int) -> int >) =
  receiver#apply (fun select -> if select then 1 else 0)
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
  method_call: [0, 1],
  method_receiver: [2, 2],
  method_argument: [2, 2],
  method_callback: [0, 1],
  "method_callback.anon": [2, 2],
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

Deno.test("open struct inventories private bodies and preserves incomplete evidence", async () => {
  const root = await Deno.makeTempDir({ prefix: "szaniec-open-struct-" });
  const opened = `open struct
  let hidden flag = if flag then 1 else 0
  open struct
    let nested flag = if flag then 2 else 0
  end
  let run_ flag = hidden flag + nested flag
end
let run = run_
`;
  const details = `module Imported = struct
  let original flag = if flag then 1 else 0
end
open Imported
open Imported
open struct
  let local flag = let helper flag = if flag then 1 else 0 in helper flag
  let callback flags = List.map (fun flag -> if flag then 1 else 0) flags
  open struct
    let shadow flag = if flag then 1 else 0
  end
  let shadow flag = if flag then 2 else 0
end
let exported = shadow
`;
  type Function = Entry & {
    id: string;
    location: { path: string; line: number; col: number };
    end: { line: number; col: number };
    nested: boolean;
    kind: string;
  };
  type OpenReport = {
    status: string;
    functions: Function[];
    coverage: { path: string; status: string; functions: number }[];
    gaps: { code: string; path: string }[];
  };
  try {
    await Deno.mkdir(`${root}/lib`);
    await Deno.writeTextFile(
      `${root}/dune-project`,
      "(lang dune 3.17)\n(package (name metric) (allow_empty) (depends (ocaml (and (>= 5.4) (< 5.5))) yojson))\n",
    );
    const lock = await new Deno.Command("cp", {
      args: [
        "-R",
        new URL("../fixtures/tasks-app/dune.lock", import.meta.url).pathname,
        `${root}/dune.lock`,
      ],
    }).output();
    assert(lock.success, decoder.decode(lock.stderr));
    await Deno.writeTextFile(
      `${root}/lib/dune`,
      "(library (name metric) (flags (:standard -bin-annot -w -32-33)))\n",
    );
    await Deno.writeTextFile(`${root}/lib/opened.ml`, opened);
    await Deno.writeTextFile(
      `${root}/lib/opened.mli`,
      "val run : bool -> int\n",
    );
    await Deno.writeTextFile(`${root}/lib/details.ml`, details);
    await Deno.writeTextFile(
      `${root}/lib/empty.ml`,
      "open List\nlet value = 1\n",
    );
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      'format = "szaniec-config/1"\n[policy]\nname = "metric"\nroots = ["lib"]\n',
    );
    async function run(metric: string, rebuild = false, cache = true) {
      const result = await new Deno.Command(bin, {
        args: [
          "complexity",
          "--project-root",
          root,
          "--json",
          "--sort",
          "complexity",
          "--metric",
          metric,
          ...(rebuild ? ["--rebuild"] : []),
        ],
        env: { SZANIEC_OBSERVATION_CACHE: cache ? "on" : "off" },
      }).output();
      const text = decoder.decode(result.stdout);
      assert(text.startsWith("{"), decoder.decode(result.stderr) + text);
      return {
        code: result.code,
        text,
        report: JSON.parse(text) as OpenReport,
      };
    }
    const inventories: unknown[] = [];
    for (const [index, metric] of ["cognitive", "cyclomatic"].entries()) {
      const first = await run(metric, index === 0);
      const cached = await run(metric);
      const uncached = await run(metric, false, false);
      assert(first.code === 0 && first.report.status === "ok", first.text);
      assert(
        first.text === cached.text && first.text === uncached.text &&
          cached.code === 0 && uncached.code === 0,
        "cache changed inventory",
      );
      const report = first.report;
      assert(report.gaps.length === 0, "supported opens introduced a gap");
      const entries = report.functions.filter((f) =>
        f.location.path === "lib/opened.ml"
      );
      assert(
        entries.length === 3,
        `expected three private bodies, got ${entries.length}`,
      );
      for (
        const [name, scores, line, col] of [
          ["hidden", [2, 2], 2, 2],
          ["nested", [2, 2], 4, 4],
          ["run_", [0, 1], 6, 2],
        ] as const
      ) {
        const f = entries.find((f) => f.qualname === name);
        assert(
          f?.complexity === scores[index],
          `${metric}: missing or wrong ${name}`,
        );
        assert(
          f.location.line === line && f.location.col === col &&
            f.end.line === line &&
            f.end.col > col,
          `${name}: authored source span lost`,
        );
        assert(
          f.id === `Metric.Opened.${name}` && !f.nested && f.kind === "named",
          `${name}: wrong identity or nesting`,
        );
      }
      const extra = report.functions.filter((f) =>
        f.location.path === "lib/details.ml"
      );
      assert(
        extra.length === 7,
        "imports duplicated functions or open bodies omitted",
      );
      for (
        const [name, count, scores] of [
          ["Imported.original", 1, [2, 2]],
          ["local", 1, [0, 1]],
          ["local.helper", 1, [2, 2]],
          ["callback", 1, [0, 1]],
          ["callback.anon", 1, [2, 2]],
          ["shadow", 2, [2, 2]],
        ] as const
      ) {
        const matches = extra.filter((f) => f.qualname === name);
        assert(
          matches.length === count &&
            matches.every((f) => f.complexity === scores[index]),
          `${metric}: incorrect inventory for ${name}`,
        );
        assert(
          matches.every((f) =>
            f.nested ===
              (name === "local.helper" || name === "callback.anon")
          ),
          `${name}: module opening changed lexical nesting`,
        );
      }
      const shadows = extra.filter((f) => f.qualname === "shadow");
      assert(
        new Set(shadows.map((f) => f.id)).size === 2 &&
          shadows.every((f) =>
            f.id ===
              `Metric.Details.shadow@${f.location.line}:${f.location.col}`
          ),
        "shadow identities collided",
      );
      assert(
        report.coverage.some((c) =>
          c.path === "lib/opened.ml" && c.status === "measured" &&
          c.functions === 3
        ),
        "private implementation coverage was incomplete",
      );
      assert(
        report.coverage.some((c) =>
          c.path === "lib/empty.ml" && c.status === "measured" &&
          c.functions === 0
        ),
        "genuinely function-free file must remain valid",
      );
      inventories.push(
        report.functions.map(({ complexity: _score, metric: _metric, ...f }) =>
          f
        )
          .sort((a, b) => a.id.localeCompare(b.id)),
      );
    }
    assert(
      JSON.stringify(inventories[0]) === JSON.stringify(inventories[1]),
      "metric selection changed definition identities or spans",
    );
    await Deno.writeTextFile(
      `${root}/lib/unsupported.ml`,
      `open struct
  open struct
    class unsupported = object method value = 1 end
    let make () = object method value = 1 end
  end
end
`,
    );
    for (const [index, metric] of ["cognitive", "cyclomatic"].entries()) {
      const { code, report, text } = await run(metric, index === 0);
      assert(code === 2 && report.status === "incomplete", text);
      assert(
        report.gaps.filter((g) =>
          g.code === "GAP-UNMEASURABLE" && g.path === "lib/unsupported.ml"
        ).length === 2,
        "unsupported class or function inside open was silently accepted",
      );
      const make = report.functions.find((f) =>
        f.location.path === "lib/unsupported.ml" && f.qualname === "make"
      );
      assert(
        make?.complexity === null,
        "unsupported function became a measured zero",
      );
    }
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
