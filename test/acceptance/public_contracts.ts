const repository = new URL("../../", import.meta.url).pathname.replace(
  /\/$/,
  "",
);
const binary = `${repository}/_build/default/bin/szaniec.exe`;
const decoder = new TextDecoder();
function assert(value: unknown, detail: string): asserts value {
  if (!value) throw new Error(detail);
}
async function copy(source: string, target: string) {
  await Deno.mkdir(target, { recursive: true });
  for await (const entry of Deno.readDir(source)) {
    if (entry.name === "_build") continue;
    const from = `${source}/${entry.name}`;
    const into = `${target}/${entry.name}`;
    if (entry.isDirectory) await copy(from, into);
    else if (entry.isFile) await Deno.copyFile(from, into);
  }
}
type Finding = { rule: string; evidencePath: string[] };
type Report = {
  status: string;
  summary: { violations: number; gaps: number };
  findings: Finding[];
};
Deno.test("compiled public contracts preserve private boundaries and approval", async () => {
  const root = await Deno.makeTempDir({ prefix: "szaniec-public-contracts-" });
  const environment = Deno.env.toObject();
  for (
    const key of [
      "INSIDE_DUNE",
      "DUNE_SOURCEROOT",
      "DUNE_OCAML_STDLIB",
      "DUNE_OCAML_HARDCODED",
      "OCAMLFIND_IGNORE_DUPS_IN",
      "BUILD_PATH_PREFIX_MAP",
      "OCAMLPATH",
      "CAML_LD_LIBRARY_PATH",
    ]
  ) delete environment[key];
  environment.DUNE_CACHE = "disabled";
  async function command(exe: string, args: string[]) {
    const result = await new Deno.Command(exe, {
      args,
      cwd: root,
      env: environment,
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
  async function approve() {
    const result = await command(binary, ["approve", "--project-root", root]);
    assert(result.code === 0, result.err + result.out);
  }
  async function check(rebuild = true) {
    const result = await command(binary, [
      "check",
      "--project-root",
      root,
      "--json",
      "--no-callgraph",
      ...(rebuild ? ["--rebuild"] : []),
    ]);
    assert(result.out.startsWith("{"), result.err + result.out);
    return { ...result, report: JSON.parse(result.out) as Report };
  }
  const manager = "lib/task_manager/task_manager_impl.ml";
  const client = "lib/web_client/page.ml";
  const policy = "szaniec.toml";
  async function scenario(
    name: string,
    changes: Record<string, string>,
    rules: string[],
    code = 1,
    reapprove = false,
  ) {
    const originals = new Map<string, string | null>();
    try {
      for (const [file, text] of Object.entries(changes)) {
        const path = `${root}/${file}`;
        let original = null;
        try {
          original = await Deno.readTextFile(path);
        } catch (error) {
          if (!(error instanceof Deno.errors.NotFound)) throw error;
        }
        originals.set(file, original);
        await Deno.mkdir(path.slice(0, path.lastIndexOf("/")), {
          recursive: true,
        });
        await Deno.writeTextFile(path, text);
      }
      if (reapprove) await approve();
      const result = await check();
      assert(
        result.code === code,
        `${name}: expected exit ${code}: ${result.err}${result.out}`,
      );
      for (const rule of rules) {
        assert(
          result.report.findings.some((f) => f.rule === rule),
          `${name}: missing ${rule}: ${result.out}`,
        );
      }
      if (code === 1) {
        assert(
          result.report.summary.gaps === 0,
          `${name}: unexpected gap: ${result.out}`,
        );
      }
      console.log(`${name}: ok`);
    } finally {
      for (const [file, original] of originals) {
        if (original === null) await Deno.remove(`${root}/${file}`);
        else await Deno.writeTextFile(`${root}/${file}`, original);
      }
    }
  }
  try {
    await copy(`${repository}/test/fixtures/owned-contracts-app`, root);
    const build = await command("dune", ["build"]);
    assert(build.code === 0, build.err);
    await approve();
    const base = await check();
    assert(base.code === 0 && base.report.status === "ok", base.err + base.out);
    assert(
      base.report.summary.violations === 0 && base.report.summary.gaps === 0,
      base.out,
    );
    const repeated = await check();
    assert(
      repeated.out === base.out,
      "identical contract input must produce identical reports",
    );
    const graph = await command(binary, [
      "check",
      "--project-root",
      root,
      "--json",
      "--out",
      "graph.json",
    ]);
    assert(graph.code === 0, graph.err + graph.out);
    const network = JSON.parse(await Deno.readTextFile(`${root}/graph.json`));
    assert(
      !network.services.some((s: { name: string }) => s.name === "Common"),
      "data-only Common must not become a Utility service",
    );
    const managerSource = await Deno.readTextFile(`${root}/${manager}`);
    const clientSource = await Deno.readTextFile(`${root}/${client}`);
    const config = await Deno.readTextFile(`${root}/${policy}`);
    await scenario(
      "registration does not approve unrelated initialization access",
      {
        "lib/bootstrap/bootstrap.ml":
          "let run () =\nignore Task_access_lib.Store.read;\nWell.Service.register Task_access_lib.Task_access_impl.spec;\nWell.Service.register Task_manager_lib.Task_manager_impl.spec\n",
      },
      ["IMPL-ACCESS-CROSS-SERVICE"],
    );
    await scenario("foreign private Store", {
      [manager]: managerSource +
        "\nlet bypass () = Task_access_lib.Store.read ()\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("foreign lock via module alias", {
      [manager]: managerSource +
        "\nmodule Private = Task_access_lib.Lock\nlet bypass () = Private.acquire ()\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("private Store callback", {
      [manager]: managerSource +
        "\nlet callbacks = List.map Task_access_lib.Store.read [()]\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("undeclared in-process member", {
      [manager]: managerSource +
        "\nlet bypass () = Task_access_lib.Api.Public.internal ()\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("unlisted consumer", {
      [client]: clientSource +
        "\nlet bypass () = Task_access_lib.Api.Public.read ()\n",
      "lib/web_client/dune":
        "(library (name web_client_lib) (libraries app_contract app_browser task_access_lib))\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("generic helper sharing", {
      "lib/kit/dune": "(library (name kit))\n",
      "lib/kit/kit.ml": "let render value = String.trim value\n",
      "lib/task_manager/dune":
        "(library (name task_manager_lib) (libraries app_contract task_access_lib kit))\n",
      "lib/web_client/dune":
        "(library (name web_client_lib) (libraries app_contract app_browser kit))\n",
      [manager]: managerSource + '\nlet extra () = Kit.render "manager"\n',
      [client]: clientSource + '\nlet extra () = Kit.render "client"\n',
    }, [
      "IMPL-ACCESS-CROSS-SERVICE",
      "SHARED-UNAPPROVED",
      "POLICY-UNCLASSIFIED",
    ]);
    await scenario("executable aggregator is not contract data", {
      "lib/generated/browser/app_browser.ml":
        "module Nested = struct\n module Common = App_service_common\n module Task_manager = App_service_task_manager\nend\nlet helper value = String.trim value\n",
      [client]: clientSource + '\nlet extra () = App_browser.helper "client"\n',
    }, ["IMPL-ACCESS-CROSS-SERVICE", "POLICY-UNCLASSIFIED"]);
    await scenario("extra code inside generated contract", {
      "lib/generated/native/app_service_common.ml": await Deno.readTextFile(
        `${root}/lib/generated/native/app_service_common.ml`,
      ) + '\nmodule Store = struct\nlet make () = "private"\nend\n',
      [manager]: managerSource +
        "\nlet extra () = App_contract.Common.Store.make ()\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario(
      "browser proxy preserves layer checks",
      {
        [policy]: config +
          '\n[[policy.contract_bindings]]\nsource="lib/contract/Task_access.cyrograf"\nmodule="App_browser.App_service_task_access"\n',
        "lib/generated/browser/app_service_task_access.ml":
          "module Proxy = struct\nlet read request ~on_done = on_done request\nend\n",
        "lib/generated/browser/app_browser.ml":
          "module Nested = struct\nmodule Common = App_service_common\nmodule Task_manager = App_service_task_manager\nend\nmodule Task_access = App_service_task_access\n",
        [client]: clientSource +
          "\nlet bypass () = App_browser.Task_access.Proxy.read () ~on_done:ignore\n",
      },
      ["ID-CLIENT-ACCESS"],
      1,
      true,
    );
    await scenario(
      "policy change revokes contract exemptions",
      {
        [policy]: config.replace(
          'consumers = ["Task_manager"]',
          'consumers = ["Task_manager", "Web_client"]',
        ),
      },
      ["GAP-POLICY-NOT-APPROVED", "IMPL-ACCESS-CROSS-SERVICE"],
      2,
    );
    await scenario(
      "missing public member is a gap",
      {
        [policy]: config.replace('members = ["read"]', 'members = ["missing"]'),
      },
      ["GAP-PUBLIC-CONTRACT"],
      2,
      true,
    );
    await scenario(
      "conflicting generated ownership is a gap",
      {
        [policy]: config +
          '\n[[policy.contract_bindings]]\nsource="lib/contract/Task_access.cyrograf"\nmodule="App_contract.App_service_common"\n',
      },
      ["GAP-AMBIGUOUS-OWNERSHIP"],
      2,
      true,
    );
    await scenario(
      "ambiguous service owner stays a gap",
      {
        "lib/task_access/api/public.ml":
          "let read () = Task_access_impl.read ()\nlet internal () = Store.read ()\nlet spec = App_contract.Task_manager.make_spec ()\n",
      },
      ["GAP-AMBIGUOUS-OWNERSHIP", "GAP-PUBLIC-CONTRACT"],
      2,
    );
    await scenario(
      "failed build preserves incomplete evidence",
      {
        [manager]: managerSource + "\nlet broken = Unknown.value\n",
      },
      ["GAP-BUILD"],
      2,
    );
    await check();
    const iface = `${root}/lib/task_access/api/public.mli`;
    const future = new Date(Date.now() + 60_000);
    await Deno.utime(iface, future, future);
    const stale = await check(false);
    assert(
      stale.code === 2 &&
        stale.report.findings.some((f) => f.rule === "GAP-STALE-ARTIFACT"),
      "stale interface must not approve a public facet: " + stale.out,
    );
    console.log("stale public interface: ok");
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
