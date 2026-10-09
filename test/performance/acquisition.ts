const repository = new URL("../../", import.meta.url).pathname.replace(
  /\/$/,
  "",
);
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("cached acquisition preserves fresh, changed, incomplete and concurrent checks", async () => {
  const root = await Deno.makeTempDir({ prefix: "szaniec-acquisition-" });
  const environment = Deno.env.toObject();
  for (
    const name of [
      "INSIDE_DUNE",
      "DUNE_SOURCEROOT",
      "DUNE_OCAML_STDLIB",
      "DUNE_OCAML_HARDCODED",
      "OCAMLFIND_IGNORE_DUPS_IN",
      "BUILD_PATH_PREFIX_MAP",
      "OCAMLPATH",
      "CAML_LD_LIBRARY_PATH",
    ]
  ) delete environment[name];
  environment.DUNE_CACHE = "disabled";
  async function command(executable: string, args: string[], env = {}) {
    const result = await new Deno.Command(executable, {
      args,
      cwd: root,
      clearEnv: true,
      env: { ...environment, ...env },
      stdout: "piped",
      stderr: "piped",
    }).output();
    return {
      code: result.code,
      out: decoder.decode(result.stdout),
      err: decoder.decode(result.stderr),
    };
  }
  const binary = `${repository}/_release/szaniec`;
  const graph = `${root}/network.json`;
  async function check(cache: string, domains = 1) {
    const result = await command(binary, ["check", "--json", "--out", graph], {
      SZANIEC_OBSERVATION_CACHE: cache,
      SZANIEC_DOMAINS: String(domains),
      SZANIEC_ACQUISITION_STATS: "1",
    });
    assert(result.code <= 2, result.err);
    JSON.parse(result.out);
    return { ...result, graph: await Deno.readTextFile(graph) };
  }
  async function verify(label: string, expected?: number) {
    const baseline = await check("off");
    if (expected !== undefined) {
      assert(baseline.code === expected, `${label}: ${baseline.out}`);
    }
    for (const domains of [1, 2, 4, 8]) {
      const cached = await check("on", domains);
      assert(
        cached.code === baseline.code && cached.out === baseline.out &&
          cached.graph === baseline.graph,
        `${label}: cached/domain output differs`,
      );
    }
    console.log(
      `${label}: identical cached/uncached reports, graph and exit status`,
    );
    return baseline;
  }
  const build = async () => {
    const result = await command("dune", ["build"]);
    assert(result.code === 0, result.err);
  };
  try {
    const copy = await command("cp", [
      "-R",
      `${repository}/test/fixtures/tasks-app/.`,
      root,
    ]);
    assert(copy.code === 0, copy.err);
    const source = `${root}/lib/web_client/tasks_page.ml`;
    const original = await Deno.readTextFile(source);
    await Deno.writeTextFile(
      `${root}/lib/web_client/bulk.ml`,
      Array.from(
        { length: 300 },
        (_, i) => `let entry_${i} ctx = Task_manager.list ~ctx ~limit:10`,
      ).join("\n"),
    );
    assert((await command(binary, ["approve"])).code === 0, "approve fixture");
    await build();
    const first = await verify("fresh acquisition", 0);
    const warm = await check("on");
    assert(/cache_hits=[1-9]/.test(warm.err), "unchanged run must hit cache");
    const cacheDirectory = `${root}/_build/.szaniec-observations`;
    for await (const entry of Deno.readDir(cacheDirectory)) {
      await Deno.remove(`${cacheDirectory}/${entry.name}`);
    }
    const concurrent = await Promise.all(
      Array.from({ length: 4 }, (_, i) =>
        command(binary, [
          "check",
          "--json",
          "--out",
          `${root}/concurrent-${i}.json`,
        ], { SZANIEC_DOMAINS: "4", SZANIEC_ACQUISITION_STATS: "1" })),
    );
    for (const [i, result] of concurrent.entries()) {
      assert(
        result.out === first.out && result.code === first.code,
        "concurrent cache writers changed findings",
      );
      assert(
        await Deno.readTextFile(`${root}/concurrent-${i}.json`) === first.graph,
        "concurrent cache writers changed the graph",
      );
    }
    assert(
      concurrent.some((result) => /cache_misses=[1-9]/.test(result.err)),
      "concurrent checks must include cold cache writes",
    );
    const probe = await command(
      `${repository}/_build/default/test/performance/acquisition.exe`,
      [root],
    );
    assert(probe.code === 0, probe.err);
    console.log(probe.out.trim());
    for (const config of ["off", "on"]) {
      const result = await command(binary, [
        "complexity",
        "--json",
        "--config",
        "szaniec.toml",
      ], { SZANIEC_OBSERVATION_CACHE: config });
      assert(result.code === 0, result.err);
      if (config === "off") {
        await Deno.writeTextFile(`${root}/measurement.json`, result.out);
      } else {assert(
          result.out === await Deno.readTextFile(`${root}/measurement.json`),
          "measurement capability cache differs",
        );}
    }
    await Deno.writeTextFile(
      `${cacheDirectory}/.pending-interrupted.tmp`,
      "partial write",
    );
    for await (const entry of Deno.readDir(cacheDirectory)) {
      if (!entry.name.startsWith(".")) {
        await Deno.writeTextFile(`${cacheDirectory}/${entry.name}`, "corrupt");
      }
    }
    await verify("corrupt and interrupted entries", 0);
    async function artifacts(directory: string): Promise<string[]> {
      const paths: string[] = [];
      for await (const entry of Deno.readDir(directory)) {
        const path = `${directory}/${entry.name}`;
        if (entry.isDirectory && entry.name !== ".szaniec-observations") {
          paths.push(...await artifacts(path));
        } else if (entry.name.endsWith(".cmt")) paths.push(path);
      }
      return paths;
    }
    const artifact = (await artifacts(`${root}/_build/default`))
      .find((path) => path.toLowerCase().endsWith("tasks_page.cmt"));
    assert(artifact, "compiled client artifact is required");
    const bytes = await Deno.readFile(artifact);
    await Deno.writeTextFile(artifact, "corrupt compiler artifact");
    await verify("corrupt artifact cannot reuse cached facts", 2);
    await Deno.writeFile(artifact, bytes);
    const duplicate = `${root}/_build/default/zz-duplicate.cmt`;
    await Deno.copyFile(artifact, duplicate);
    await verify("duplicate unit selection", 0);
    await Deno.remove(duplicate);
    await Deno.writeTextFile(source, original + "\nlet extra () = ()\n");
    await verify("source-only change remains stale", 2);
    await build();
    await verify("rebuilt source", 0);
    await Deno.writeTextFile(`${root}/lib/new.ml`, "let new_value () = ()\n");
    await verify("added unbuilt source", 2);
    await Deno.remove(`${root}/lib/new.ml`);
    await Deno.remove(source);
    await verify("deleted source with retained artifact", 2);
    await Deno.writeTextFile(source, original);
    await build();
    const contract = `${root}/lib/contract/Task_manager.cyrograf`;
    const contractSource = await Deno.readTextFile(contract);
    await Deno.writeTextFile(
      contract,
      contractSource.replace(/^rpc list.*\n/m, ""),
    );
    await verify("contract change reevaluates current declarations", 2);
    await Deno.writeTextFile(contract, contractSource);
    const policy = `${root}/szaniec.toml`;
    const policySource = await Deno.readTextFile(policy);
    await Deno.writeTextFile(
      policy,
      policySource.replace(/roots = \[[^\]]*\]/, 'roots = ["bin", "lib"]'),
    );
    await verify("scope/policy change does not reuse approval", 2);
    await Deno.writeTextFile(policy, policySource);
    await verify("restored current inputs", 0);
    const invalid = await command(
      binary,
      ["check", "--json", "--no-callgraph"],
      { SZANIEC_DOMAINS: "0" },
    );
    assert(
      invalid.code === 2 && invalid.err.includes("SZANIEC_DOMAINS"),
      "invalid domain setting must fail explicitly",
    );
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
