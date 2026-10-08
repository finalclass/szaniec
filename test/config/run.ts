// Run with: deno test --allow-read --allow-write --allow-run test/config/run.ts
const bin =
  new URL("../../_build/default/bin/szaniec.exe", import.meta.url).pathname;
const text = new TextDecoder();
const assert = (value: unknown, message: string) => {
  if (!value) throw new Error(message);
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
    out: text.decode(result.stdout),
    err: text.decode(result.stderr),
  };
}
async function project(test: (root: string, nested: string) => Promise<void>) {
  const root = await Deno.makeTempDir({ prefix: "szaniec-config-cli-" });
  try {
    await Deno.mkdir(`${root}/lib/nested`, { recursive: true });
    // Git worktree marker: discovery must treat .git files like directories.
    await Deno.writeTextFile(`${root}/.git`, "gitdir: /unused\n");
    await Deno.writeTextFile(
      `${root}/szaniec.toml`,
      `format = "szaniec-config/1"
[policy]
name = "cli-test"
roots = ["lib"]
[check]
json = true
no_callgraph = true
[complexity]
json = true
sort = "complexity"
[suggestions]
model = "configured-model"
no_cache = true
decisions = "decisions.json"
`,
    );
    await test(root, `${root}/lib/nested`);
  } finally {
    await Deno.remove(root, { recursive: true });
  }
}
Deno.test("discover repository configuration from a nested worktree directory", () =>
  project(async (root, nested) => {
    // A local decoy config must not override the repository root.
    await Deno.writeTextFile(`${nested}/szaniec.toml`, "invalid");
    let r = await run(nested, "approve");
    assert(r.code === 0, r.err);
    const config = await Deno.readTextFile(`${root}/szaniec.toml`);
    assert(
      config.includes("[approval]"),
      "approval must live in the root TOML",
    );
    r = await run(nested, "check");
    assert(r.code === 0, r.err + r.out);
    const report = JSON.parse(r.out);
    assert(report.inputs.policy.approved === true, "approved policy must pass");
    r = await run(nested, "complexity", "--sort", "location");
    assert(
      r.code === 0 && JSON.parse(r.out).sort === "location",
      "CLI overrides configured sort: " + r.err,
    );
  }));
Deno.test("explicit root/config and decision paths resolve against selected root", () =>
  project(async (root, nested) => {
    await Deno.rename(`${root}/szaniec.toml`, `${root}/selected.toml`);
    await Deno.writeTextFile(`${nested}/selected.toml`, "invalid");
    let r = await run(
      nested,
      "approve",
      "--project-root",
      root,
      "--config",
      "selected.toml",
    );
    assert(r.code === 0, r.err);
    r = await run(
      nested,
      "suggestions",
      "decide",
      "--project-root",
      root,
      "--config",
      "selected.toml",
      "--id",
      "example",
      "--decision",
      "defer",
      "--rationale",
      "Review later",
    );
    assert(r.code === 0, r.err);
    assert(
      (await Deno.readTextFile(`${root}/decisions.json`)).includes("example"),
      "configured decision path",
    );
    r = await run(
      nested,
      "suggestions",
      "decide",
      "--project-root",
      root,
      "--config",
      "selected.toml",
      "--decisions",
      "overridden.json",
      "--id",
      "example",
      "--decision",
      "reject",
      "--rationale",
      "Keep current code",
    );
    assert(r.code === 0, r.err);
    assert(
      (await Deno.stat(`${root}/overridden.json`)).isFile,
      "CLI path overrides TOML",
    );
  }));
Deno.test("missing and malformed configuration fail with exit 2 without mutations", () =>
  project(async (root, nested) => {
    for (
      const invalid of [
        'format="bad"',
        'format="szaniec-config/1"\n[check]\njsno=true',
        'format="szaniec-config/1"\n[suggestions]\napi_candidates=["x",1]',
        '{"format":"szaniec-policy/2"}',
      ]
    ) {
      await Deno.writeTextFile(`${root}/szaniec.toml`, invalid);
      const r = await run(nested, "approve");
      assert(
        r.code === 2 && r.err.includes("szaniec"),
        "invalid config must be diagnosed",
      );
      assert(
        await Deno.readTextFile(`${root}/szaniec.toml`) === invalid,
        "invalid configuration must not be rewritten",
      );
    }
    await Deno.remove(`${root}/szaniec.toml`);
    const r = await run(nested, "check");
    assert(
      r.code === 2 && r.err.includes("szaniec.toml"),
      "missing config must fail",
    );
    const supervise = await run(nested, "coverage", "supervise");
    assert(
      supervise.err.includes("requires --port") &&
        !supervise.err.includes("szaniec.toml"),
      "supervise is independent of config",
    );
  }));

Deno.test("suggestions reads its section and CLI overrides the configured model", () =>
  project(async (root, nested) => {
    await Deno.writeTextFile(
      `${root}/provider.json`,
      JSON.stringify({
        format: "szaniec-suggestion-fixture/1",
        model: "fixture-model",
        onMissing: "default",
        defaults: {
          noul: { type: "noul", noul: 0.05 },
          choice: {
            type: "choice",
            choice: "acceptable",
            probabilities: { acceptable: 1 },
            confidence: 1,
          },
          score: {
            type: "score",
            score: 0,
            legend: { "0": "simple" },
            probabilities: { "0": 1 },
            confidence: 1,
          },
        },
        answers: {},
      }),
    );
    let config = await Deno.readTextFile(`${root}/szaniec.toml`);
    config +=
      'provider_fixture = "provider.json"\nexperimental = true\napi_candidates = ["List.map"]\n';
    await Deno.writeTextFile(`${root}/szaniec.toml`, config);
    let r = await run(nested, "suggestions", "--json");
    assert(r.code === 0, r.err + r.out);
    let report = JSON.parse(r.out);
    assert(
      report.inputs.modelRequested === "configured-model",
      "configured model: " + r.out,
    );
    assert(
      !report.criteriaNotRun.some((c: { criterion: string }) =>
        c.criterion === "idiomatic-alternative"
      ),
      "inline API candidates must enable the criterion",
    );
    r = await run(nested, "suggestions", "--json", "--model", "cli-model");
    assert(r.code === 0, r.err + r.out);
    report = JSON.parse(r.out);
    assert(report.inputs.modelRequested === "cli-model", "CLI model must win");
  }));

Deno.test("outside Git the nearest Dune root supplies configuration", () =>
  project(async (root, nested) => {
    await Deno.remove(`${root}/.git`);
    await Deno.writeTextFile(`${root}/dune-project`, "(lang dune 3.17)\n");
    const r = await run(nested, "approve");
    assert(r.code === 0, r.err);
    assert(
      (await Deno.readTextFile(`${root}/szaniec.toml`)).includes("[approval]"),
      "Dune root discovery",
    );
  }));
