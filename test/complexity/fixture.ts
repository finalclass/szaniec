// Source-to-report scenarios for `szaniec complexity` over the checked-in
// fixture project test/fixtures/complexity-app (specimens with
// hand-derived Cognitive Complexity values).
const bin = Deno.env.get("SZANIEC_COMPLEXITY_BINARY") ??
  new URL("../../_build/default/bin/szaniec.exe", import.meta.url).pathname;
const fixture = new URL("../fixtures/complexity-app", import.meta.url).pathname;
const decoder = new TextDecoder();

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

type Fn = {
  id: string;
  qualname: string;
  module: string;
  kind: string;
  nested: boolean;
  provenance: string;
  status: string;
  metric: string;
  complexity: number | null;
  location: { path: string; line: number; col: number };
};
type Report = {
  format: string;
  metric: string;
  status: string;
  sort: string;
  inputs: { programRoots: string[]; programAccess: string };
  functions: Fn[];
  coverage: {
    path: string;
    provenance: string;
    status: string;
    functions: number;
  }[];
  gaps: { code: string; path: string; detail: string }[];
  summary: Record<string, number | null>;
};

// [module, qualname, complexity, nested, kind]
const specimens: [string, string, number, boolean, string][] = [
  ["Metric.Samples", "straight", 0, false, "named"],
  ["Metric.Samples", "conditional", 2, false, "named"],
  ["Metric.Samples", "multi", 1, false, "named"],
  ["Metric.Samples", "guarded", 3, false, "named"],
  ["Metric.Samples", "short", 2, false, "named"],
  ["Metric.Samples", "if_and", 3, false, "named"],
  ["Metric.Samples", "loop_for", 1, false, "named"],
  ["Metric.Samples", "loop_while", 1, false, "named"],
  ["Metric.Samples", "exceptional", 1, false, "named"],
  ["Metric.Samples", "two_handlers", 2, false, "named"],
  ["Metric.Samples", "match_exn", 1, false, "named"],
  ["Metric.Samples", "or_pat", 1, false, "named"],
  ["Metric.Samples", "partial_match", 1, false, "named"],
  ["Metric.Samples", "outer", 0, false, "named"],
  ["Metric.Samples", "outer.nested", 2, true, "named"],
  ["Metric.Samples", "curried", 2, false, "named"],
  ["Metric.Samples", "uses_anon", 0, false, "named"],
  ["Metric.Samples", "uses_anon.anon", 2, true, "anonymous"],
  ["Metric.Samples", "returns_fun", 0, false, "named"],
  ["Metric.Samples", "returns_fun.anon", 2, true, "anonymous"],
  ["Metric.Samples", "unused_plain", 0, false, "named"],
  ["Metric.Samples", "as_function", 1, false, "named"],
  ["Metric.Samples", "if_unit", 1, false, "named"],
  ["Metric.Samples", "just_raise", 2, false, "named"],
  ["Metric.Samples", "Local.hidden", 0, false, "named"],
  ["Metric.Samples", "with_effect", 1, false, "named"],
  ["Metric.Recursion", "recursive", 3, false, "named"],
  ["Metric.Recursion", "even", 3, false, "named"],
  ["Metric.Recursion", "odd", 3, false, "named"],
  ["Metric.Widget_manager_impl", "ping", 2, false, "named"],
  ["Metric.Widget_manager_impl", "helper", 0, false, "named"],
  ["Probe", "probe", 0, false, "named"],
];

async function workspace(): Promise<string> {
  const root = await Deno.makeTempDir({ prefix: "szaniec-cc-fixture-" });
  const copy = await new Deno.Command("cp", {
    args: ["-R", `${fixture}/.`, root],
  }).output();
  assert(copy.success, decoder.decode(copy.stderr));
  await Deno.remove(`${root}/_build`, { recursive: true }).catch(() => {});
  return root;
}

async function run(root: string, ...args: string[]) {
  const result = await new Deno.Command(bin, {
    args: [
      "complexity",
      "--project-root",
      root,
      "--root",
      "metric",
      "--root",
      "test",
      ...args,
    ],
    stdout: "piped",
    stderr: "piped",
  }).output();
  const text = decoder.decode(result.stdout);
  return { code: result.code, text, stderr: decoder.decode(result.stderr) };
}

async function report(root: string, ...args: string[]) {
  const r = await run(root, "--json", ...args);
  assert(
    r.text.startsWith('{"format":"szaniec-complexity/1"'),
    `report is not one JSON line with the format first: ${r.stderr}${r.text}`,
  );
  return { code: r.code, text: r.text, json: JSON.parse(r.text) as Report };
}

function checkSorted(inventory: Report, sorted: Report) {
  assert(sorted.sort === "complexity", "sort field");
  assert(sorted.status === inventory.status, "sort changed the status");
  const ids = (r: Report) => r.functions.map((f) => f.id).sort().join("\n");
  assert(ids(inventory) === ids(sorted), "sort changed the function set");
  for (let i = 1; i < sorted.functions.length; i++) {
    const a = sorted.functions[i - 1], b = sorted.functions[i];
    if (a.complexity === null) {
      assert(b.complexity === null, `measured after unmeasurable at ${b.id}`);
      assert(a.id <= b.id, `null tie break at ${b.id}`);
    } else if (b.complexity !== null) {
      assert(a.complexity >= b.complexity, `complexity rose at ${b.id}`);
      if (a.complexity === b.complexity) {
        assert(a.id <= b.id, `tie break at ${b.id}`);
      }
    }
  }
}

Deno.test("fixture inventory, sorting, staleness, partial and unmeasurable files", async () => {
  const root = await workspace();
  try {
    // Inventory twice through the build command given on the CLI.
    const first = await report(root, "--rebuild", "--build", "dune build");
    const again = await report(root, "--rebuild");
    assert(first.text === again.text, "repeated complexity report differs");
    const j = first.json;
    assert(first.code === 0, `exit ${first.code}: ${first.text}`);
    assert(j.metric === "szaniec-cognitive/1" && j.status === "ok", "status");
    assert(j.sort === "location", "default sort");
    assert(
      JSON.stringify(j.inputs.programRoots) === '["metric","test"]',
      "roots",
    );
    assert(j.gaps.length === 0, `gaps: ${JSON.stringify(j.gaps)}`);
    for (const [module, qualname, cc, nested, kind] of specimens) {
      const fs = j.functions.filter((f) =>
        f.module === module && f.qualname === qualname
      );
      assert(fs.length === 1, `${module}.${qualname} occurs ${fs.length}x`);
      const f = fs[0];
      assert(f.complexity === cc, `${qualname}: ${f.complexity} != ${cc}`);
      assert(f.nested === nested && f.kind === kind, `${qualname}: shape`);
      assert(f.status === "measured", `${qualname}: status`);
      assert(f.metric === "szaniec-cognitive/1", `${qualname}: metric`);
      assert(
        f.provenance === (module === "Probe" ? "test" : "authored"),
        `${qualname}: provenance`,
      );
      if (kind === "named") {
        assert(f.id === `${module}.${qualname}`, `${qualname}: id ${f.id}`);
      } else {
        const parent = qualname.slice(0, -".anon".length);
        assert(
          f.id.startsWith(`${module}.${parent}#anon@`),
          `anon id ${f.id}`,
        );
      }
    }
    const shadows = j.functions.filter((f) =>
      f.module === "Metric.Samples" && f.qualname === "shadow"
    );
    assert(
      shadows.length === 2 &&
        JSON.stringify(shadows.map((f) => f.complexity).sort()) === "[0,2]" &&
        shadows[0].id !== shadows[1].id &&
        shadows.every((f) => f.id.startsWith("Metric.Samples.shadow@")),
      "shadowed definitions",
    );
    assert(
      j.functions.length === specimens.length + 2,
      `function count ${j.functions.length}`,
    );
    assert(
      !j.functions.some((f) =>
        ["alias_of_straight", "partial_apply", "shadow_kept"].some((b) =>
          f.id.includes(b)
        )
      ),
      "inventoried a non-definition",
    );
    assert(
      j.summary.functions === specimens.length + 2 &&
        j.summary.unmeasurable === 0 && j.summary.maxComplexity === 3 &&
        j.summary.gaps === 0,
      `summary ${JSON.stringify(j.summary)}`,
    );
    const cov = (path: string, provenance: string, functions: number) => {
      const c = j.coverage.filter((c) => c.path === path);
      assert(
        c.length === 1 && c[0].provenance === provenance &&
          c[0].status === "measured" && c[0].functions === functions,
        `coverage ${path}: ${JSON.stringify(c)}`,
      );
    };
    cov("metric/samples.ml", "authored", 28);
    cov("metric/recursion.ml", "authored", 3);
    cov("metric/widget_manager_impl.ml", "authored", 2);
    cov("test/probe.ml", "test", 1);
    cov("metric/metric.ml-gen", "generated", 0);
    assert(
      !j.coverage.some((c) => c.path.endsWith(".mli")),
      "interfaces reported as implementations",
    );

    const sorted = await report(root, "--sort", "complexity");
    assert(sorted.code === 0, "sort exit");
    checkSorted(j, sorted.json);

    const text = await run(root);
    assert(
      text.code === 0 && text.text.includes("Metric.Samples.straight  0  "),
      `text report: ${text.text}`,
    );

    // Stale artifact: an edited source without a rebuild.
    const samples = `${root}/metric/samples.ml`;
    const original = await Deno.readTextFile(samples);
    await Deno.writeTextFile(samples, original + "\n(* edited *)\n");
    const stale = await report(root);
    assert(stale.code === 2 && stale.json.status === "incomplete", "stale");
    assert(
      stale.json.gaps.some((g) =>
        g.code === "GAP-STALE-ARTIFACT" && g.path === "metric/samples.ml"
      ),
      "missing stale gap",
    );
    assert(
      !stale.json.functions.some((f) =>
        f.location.path === "metric/samples.ml"
      ),
      "stale file contributed functions",
    );
    assert(
      stale.json.functions.some((f) => f.qualname === "ping"),
      "current files were dropped",
    );
    await Deno.writeTextFile(samples, original);

    // A source that does not type-check must not look measured.
    await report(root, "--rebuild");
    await Deno.writeTextFile(
      `${root}/metric/broken.ml`,
      'let broken x = x + "no"\n',
    );
    const partial = await report(root, "--rebuild");
    assert(
      partial.code === 2 && partial.json.status === "incomplete",
      "partial status",
    );
    assert(
      partial.json.gaps.some((g) => g.code === "GAP-BUILD"),
      "failed build not reported",
    );
    assert(
      partial.json.gaps.some((g) => g.path === "metric/broken.ml"),
      "missing gap for broken.ml",
    );
    assert(
      !partial.json.functions.some((f) =>
        f.location.path === "metric/broken.ml"
      ),
      "partial file contributed functions",
    );
    assert(
      partial.json.coverage.filter((c) =>
        c.path === "metric/broken.ml" && c.status !== "measured"
      ).length === 1,
      "partial coverage looks measured",
    );
    await Deno.remove(`${root}/metric/broken.ml`);
    await report(root, "--rebuild");

    // Object and class definitions stay gaps; method sends are calls.
    await Deno.writeTextFile(
      `${root}/metric/objects.ml`,
      `let make () =
  object
    method m = 1
  end
let call o = o#m
class c =
  object
    method n = 2
  end
`,
    );
    const objects = await report(root, "--rebuild");
    assert(
      objects.code === 2 && objects.json.status === "incomplete",
      "objects status",
    );
    const make = objects.json.functions.find((f) =>
      f.module === "Metric.Objects" && f.qualname === "make"
    );
    assert(
      make?.complexity === null && make.status === "unmeasurable",
      "object constructor became a measured value",
    );
    const call = objects.json.functions.find((f) =>
      f.module === "Metric.Objects" && f.qualname === "call"
    );
    assert(
      call?.complexity === 0 && call.status === "measured",
      "method send",
    );
    assert(
      objects.json.gaps.some((g) =>
        g.path === "metric/objects.ml" && g.detail.includes("class definitions")
      ),
      "missing class gap",
    );
    assert(
      objects.json.coverage.some((c) =>
        c.path === "metric/objects.ml" && c.status === "measured" &&
        c.functions === 2
      ),
      "objects coverage",
    );
    const objectsSorted = await report(root, "--sort", "complexity");
    assert(objectsSorted.code === 2, "sorted objects exit");
    checkSorted(objects.json, objectsSorted.json);

    // A failing build command is a gap, never a silent pass.
    const failing = await report(root, "--rebuild", "--build", "exit 3");
    assert(
      failing.code === 2 &&
        failing.json.gaps.some((g) =>
          g.code === "GAP-BUILD" && g.detail.includes("exit 3")
        ),
      "failing build command accepted",
    );
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});

Deno.test("usage errors exit 2", async () => {
  for (
    const args of [
      ["complexity", "--sort", "size"],
      ["complexity", "--metric", "loc"],
      ["complexity", "--build", "make"],
      ["complexity", "--root", "/abs"],
      ["complexity", "--config", "szaniec.toml"],
      ["init"],
      ["approve"],
      ["coverage"],
      ["suggestions"],
    ]
  ) {
    const r = await new Deno.Command(bin, { args, stderr: "piped" }).output();
    assert(r.code === 2, `${args.join(" ")} exited ${r.code}`);
  }
});
