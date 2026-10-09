const repository = new URL("../../", import.meta.url).pathname.replace(
  /\/$/,
  "",
);
const binary = Deno.env.get("SZANIEC_TEST_BINARY") ??
  `${repository}/_release/szaniec`;
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
async function compilerArtifacts(directory: string): Promise<string[]> {
  const paths: string[] = [];
  for await (const entry of Deno.readDir(directory)) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory) paths.push(...await compilerArtifacts(path));
    else if (entry.name.endsWith(".cmt")) paths.push(path);
  }
  return paths;
}
type Finding = { rule: string; evidencePath: string[]; message: string };
type Report = {
  status: string;
  inputs: { adapters: { programAccess: string; interpretation: string } };
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
      if (code === 0) {
        assert(
          result.report.summary.violations === 0 &&
            result.report.summary.gaps === 0,
          `${name}: expected complete clean analysis: ${result.out}`,
        );
      }
      console.log(`${name}: ok ${JSON.stringify(result.report.summary)}`);
      return result;
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
    const evidence = await command(
      `${repository}/_build/default/test/acceptance/contract_observation.exe`,
      [root],
    );
    assert(evidence.code === 0, evidence.err + evidence.out);
    await approve();
    const base = await check();
    assert(base.code === 0 && base.report.status === "ok", base.err + base.out);
    assert(
      base.report.summary.violations === 0 && base.report.summary.gaps === 0,
      base.out,
    );
    console.log(
      `fresh packaged fixture: ${
        JSON.stringify(base.report.inputs.adapters)
      }, ` +
        `${JSON.stringify(base.report.summary)}`,
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
    const managerCalls = network.services.find(
      (s: { name: string }) => s.name === "Task_manager",
    ).methods.find((m: { name: string }) => m.name === "read").calls;
    assert(
      managerCalls.some(
        (c: { to: { service?: string; method?: string } }) =>
          c.to.service === "Task_access" && c.to.method === "read",
      ),
      "in-process public API must retain the real Manager -> Access edge",
    );
    const graphText = JSON.stringify(network);
    assert(
      !/"method":"(?:make|to_drut|from_drut|to_data|from_data|to_storage_value|from_storage_value|wire_of_storage|storage_of_wire)"/
        .test(graphText),
      "constructors and codecs must not become service methods",
    );
    const managerSource = await Deno.readTextFile(`${root}/${manager}`);
    const clientSource = await Deno.readTextFile(`${root}/${client}`);
    const config = await Deno.readTextFile(`${root}/${policy}`);
    const browserCommon = "lib/generated/browser/app_service_common.ml";
    const browserSource = await Deno.readTextFile(`${root}/${browserCommon}`);
    const browserDune = "lib/generated/browser/dune";
    const browserLibrary = await Deno.readTextFile(`${root}/${browserDune}`);
    await scenario("serializer body retains foreign private calls", {
      [browserDune]: browserLibrary.replace(
        "(name app_browser)",
        "(name app_browser) (libraries task_access_lib)",
      ),
      [browserCommon]: browserSource.replace(
        "    let* arr = Drut_runtime.dec_struct 1 wire in",
        "    ignore (Task_access_lib.Store.read ());\n    let* arr = Drut_runtime.dec_struct 1 wire in",
      ),
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("serializer body retains foreign private callbacks", {
      [browserDune]: browserLibrary.replace(
        "(name app_browser)",
        "(name app_browser) (libraries task_access_lib)",
      ),
      [browserCommon]: browserSource.replace(
        "    let* arr = Drut_runtime.dec_struct 1 wire in",
        "    ignore (List.map Task_access_lib.Store.read [()]);\n    let* arr = Drut_runtime.dec_struct 1 wire in",
      ),
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario(
      "unsupported call inside a public serializer remains a gap",
      {
        [browserCommon]: browserSource.replace(
          "    match encode_value v with",
          "    let apply operation = operation v in\n    match apply encode_value with",
        ),
      },
      ["GAP-UNRESOLVED-CALL"],
      2,
    );
    await scenario("serializer body retains protected resources", {
      [browserDune]: browserLibrary.replace(
        "(name app_browser)",
        "(name app_browser) (libraries well)",
      ),
      "lib/well/well.ml": await Deno.readTextFile(`${root}/lib/well/well.ml`) +
        "\nmodule Db = struct\nlet execute () = ()\nend\n",
      "lib/generated/browser/app_service_task_manager.ml":
        await Deno.readTextFile(
          `${root}/lib/generated/browser/app_service_task_manager.ml`,
        ) + "\n" +
        browserSource.slice(browserSource.indexOf("module Cyrograf = struct"))
          .replace(
            "    let* arr = Drut_runtime.dec_struct 1 wire in",
            "    Well.Db.execute ();\n    let* arr = Drut_runtime.dec_struct 1 wire in",
          ),
      "lib/contract/Task_manager.cyrograf":
        await Deno.readTextFile(`${root}/lib/contract/Task_manager.cyrograf`) +
        "\nstruct Payload { value: String }\n",
    }, ["RESOURCE-BOUNDARY"]);
    await scenario(
      "serializer runtime remains private to generated conversions",
      {
        "lib/generated/browser/app_browser.ml": await Deno.readTextFile(
          `${root}/lib/generated/browser/app_browser.ml`,
        ) +
          "\nmodule Runtime = Drut_runtime\n",
        [client]: clientSource +
          '\nlet extra () = App_browser.Runtime.dec_string (`String "private")\n',
      },
      ["IMPL-ACCESS-CROSS-SERVICE"],
    );
    await scenario("serializer internals are not public callbacks", {
      [client]: clientSource +
        '\nlet extra () = List.map Messages.Payload.encode_value [Messages.Payload.make ~value:"private" ()]\n',
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    const runtime = "lib/generated/browser/drut_runtime.ml";
    const runtimeSource = await Deno.readTextFile(`${root}/${runtime}`);
    await scenario(
      "data-only serializer does not gain Utility resource permission",
      {
        [browserDune]: browserLibrary.replace(
          "(name app_browser)",
          "(name app_browser) (libraries well)",
        ),
        "lib/well/well.ml":
          await Deno.readTextFile(`${root}/lib/well/well.ml`) +
          "\nmodule Db = struct\nlet execute () = ()\nend\n",
        [browserCommon]: browserSource.replace(
          "    let* arr = Drut_runtime.dec_struct 1 wire in",
          "    Well.Db.execute ();\n    let* arr = Drut_runtime.dec_struct 1 wire in",
        ),
      },
      ["RESOURCE-BOUNDARY"],
    );
    await scenario("serialization runtime retains protected resource checks", {
      [browserDune]: browserLibrary.replace(
        "(name app_browser)",
        "(name app_browser) (libraries well)",
      ),
      "lib/well/well.ml": await Deno.readTextFile(`${root}/lib/well/well.ml`) +
        "\nmodule Db = struct\nlet execute () = ()\nend\n",
      [runtime]: runtimeSource.replace(
        "let enc_list encode items =",
        "let enc_list encode items =\n  Well.Db.execute ();",
      ),
    }, ["RESOURCE-BOUNDARY"]);
    await scenario("serialization runtime retains private dependencies", {
      [browserDune]: browserLibrary.replace(
        "(name app_browser)",
        "(name app_browser) (libraries task_access_lib)",
      ),
      [runtime]: runtimeSource.replace(
        "let enc_list encode items =",
        "let enc_list encode items =\n  ignore (Task_access_lib.Store.read ());",
      ),
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("serializer spelling does not approve an authored helper", {
      "lib/task_access/task_access_impl.ml":
        await Deno.readTextFile(`${root}/lib/task_access/task_access_impl.ml`) +
        "\nlet encode_value value = value\n",
      [client]: clientSource +
        '\nlet extra () = Task_access_lib.Task_access_impl.encode_value "private"\n',
      "lib/web_client/dune":
        "(library (name web_client_lib) (libraries app_contract app_browser task_access_lib))\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("runtime spelling does not approve an unrelated unit", {
      "lib/unrelated/drut_runtime.ml": "let dec_string value = value\n",
      "lib/unrelated/dune": "(library (name unrelated))\n",
      [client]: clientSource +
        '\nlet extra () = Unrelated.Drut_runtime.dec_string "private"\n',
      [manager]: managerSource +
        '\nlet extra () = Unrelated.Drut_runtime.dec_string "private"\n',
      "lib/web_client/dune":
        "(library (name web_client_lib) (libraries app_contract app_browser unrelated))\n",
      "lib/task_manager/dune":
        "(library (name task_manager_lib) (libraries app_contract task_access_lib unrelated))\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE", "SHARED-UNAPPROVED"]);
    await scenario(
      "exact compiled target declarations",
      {
        [policy]: config.replace(
          'module = "App_contract.Common"',
          'module = "App_contract.App_service_common"',
        ).replace(
          'module = "App_contract.Task_access"',
          'module = "App_contract.App_service_task_access"',
        ).replace(
          'module = "App_contract.Task_manager"',
          'module = "App_contract.App_service_task_manager"',
        ).replace(
          'module = "App_browser.Nested.Common"',
          'module = "App_browser.App_service_common"',
        ).replace(
          'module = "App_browser.Nested.Task_manager"',
          'module = "App_browser.App_service_task_manager"',
        ),
      },
      [],
      0,
      true,
    );
    await approve();
    await scenario(
      "public constructor and storage codec callbacks",
      {
        [manager]: managerSource +
          '\nlet extra () = List.map Contract.Message.from_data ["manager"]\n',
        [client]: clientSource +
          '\nlet extra () = List.map Messages.Message.Storage.from_storage_value ["client"]\n',
      },
      [],
      0,
    );
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
        "\nmodule Private : module type of Task_access_lib.Lock = Task_access_lib.Lock\nlet bypass () = Private.acquire ()\n",
    }, ["IMPL-ACCESS-CROSS-SERVICE"]);
    await scenario("private Store callback", {
      [manager]: managerSource +
        "\nmodule Private : module type of Task_access_lib.Store = Task_access_lib.Store\nlet callbacks = List.map Private.read [()]\n",
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
    await scenario("undeclared storage-like module stays private", {
      "lib/generated/native/app_service_common.ml": await Deno.readTextFile(
        `${root}/lib/generated/native/app_service_common.ml`,
      ) +
        "\nmodule Private = struct\nmodule Storage = struct\nlet from_storage_value value = value\nend\nend\n",
      [manager]: managerSource +
        '\nlet extra () = App_contract.Common.Private.Storage.from_storage_value "private"\n',
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
    const missingBinding = await scenario(
      "unmarked bindings require approval",
      {
        [policy]: config.replace(
          /\[\[policy\.contract_bindings\]\]\n\s*source = "lib\/contract\/Common\.cyrograf"\n\s*module = "[^"]+"\n/g,
          "",
        ),
      },
      ["GAP-PUBLIC-CONTRACT"],
      2,
      true,
    );
    assert(
      missingBinding.report.findings.some((f) =>
        f.rule === "GAP-PUBLIC-CONTRACT" &&
        f.message.includes("policy.contract_bindings")
      ),
      "missing mapping must explain the exact declaration workflow",
    );
    await approve();
    await scenario("protected resource access remains visible", {
      "lib/well/well.ml": await Deno.readTextFile(`${root}/lib/well/well.ml`) +
        "\nmodule Db = struct\nlet execute () = ()\nend\n",
      "lib/task_manager/dune":
        "(library (name task_manager_lib) (libraries app_contract task_access_lib well))\n",
      [manager]: managerSource + "\nlet extra () = Well.Db.execute ()\n",
    }, ["RESOURCE-BOUNDARY"]);
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
    const rewritten = [
      "lib/generated/native/app_service_common.ml",
      "lib/generated/native/app_contract.ml",
      "lib/generated/browser/app_service_common.ml",
      "lib/generated/browser/app_browser.ml",
      "lib/task_access/api/public.mli",
    ];
    const originalTimes = await Promise.all(
      rewritten.map((file) => Deno.stat(`${root}/${file}`)),
    );
    const rewriteTime = new Date(Date.now() + 60_000);
    try {
      for (const file of rewritten) {
        const path = `${root}/${file}`;
        await Deno.writeTextFile(path, await Deno.readTextFile(path));
        await Deno.utime(path, rewriteTime, rewriteTime);
      }
      const incremental = await command("dune", ["build"]);
      assert(incremental.code === 0, incremental.err);
      const oldArtifacts = await compilerArtifacts(
        `${root}/_build/default/lib/generated/native`,
      );
      assert(
        (await Promise.all(oldArtifacts.map((path) => Deno.stat(path))))
          .some((stat) => stat.mtime!.getTime() < rewriteTime.getTime()),
        "incremental build must retain an older artifact for unchanged content",
      );
      const current = await check(false);
      assert(
        current.code === 0 && current.report.summary.gaps === 0,
        "content-current rewrites must retain their bindings: " + current.out,
      );
      const freshEvidence = await command(
        `${repository}/_build/default/test/acceptance/contract_observation.exe`,
        [root],
      );
      assert(freshEvidence.code === 0, freshEvidence.err + freshEvidence.out);
      console.log(
        "unchanged source/interface rewrite and incremental build: ok",
      );
    } finally {
      for (const [index, file] of rewritten.entries()) {
        await Deno.utime(
          `${root}/${file}`,
          originalTimes[index].atime!,
          originalTimes[index].mtime!,
        );
      }
    }
    const transformed = `${root}/lib/generated/preprocessed/projection.ml`;
    const transformedTimes = await Deno.stat(transformed);
    try {
      await Deno.utime(transformed, rewriteTime, rewriteTime);
      const unsupportedProof = await check(false);
      assert(
        unsupportedProof.code === 2 &&
          unsupportedProof.report.findings.some((f) =>
            f.rule === "GAP-STALE-ARTIFACT"
          ),
        "a preprocessed input digest cannot prove a rewritten original is current: " +
          unsupportedProof.out,
      );
      const rebuilt = await check();
      assert(
        rebuilt.code === 0,
        "successful transformation rebuild must provide current evidence: " +
          rebuilt.out,
      );
      console.log("preprocessed input requires transformation evidence: ok");
    } finally {
      await Deno.utime(
        transformed,
        transformedTimes.atime!,
        transformedTimes.mtime!,
      );
    }
    const transformDune = `${root}/lib/generated/preprocessed/dune`;
    const transformRule = await Deno.readTextFile(transformDune);
    try {
      await Deno.writeTextFile(
        transformDune,
        transformRule.replace(
          " (libraries app_contract)",
          " (libraries app_contract)\n (flags (:standard -pp cat))",
        ),
      );
      const rebuilt = await check();
      assert(rebuilt.code === 0, rebuilt.err + rebuilt.out);
      const unproven = await check(false);
      assert(
        unproven.code === 2 &&
          unproven.report.findings.some((f) => f.rule === "GAP-STALE-ARTIFACT"),
        "a compiler-applied transform requires a successful rebuild: " +
          unproven.out,
      );
      console.log(
        "compiler-applied preprocessing requires rebuild evidence: ok",
      );
    } finally {
      await Deno.writeTextFile(transformDune, transformRule);
      await check();
    }
    const iface = `${root}/lib/task_access/api/public.mli`;
    const interfaceTimes = await Deno.stat(iface);
    const interfaceSource = await Deno.readTextFile(iface);
    const interfaceArtifact =
      (await compilerArtifacts(`${root}/_build/default/lib/task_access`))
        .find((path) => path.endsWith("__Api__Public.cmt"));
    assert(
      interfaceArtifact,
      "interface CRC scenario requires compiler evidence",
    );
    const cmiTarget = interfaceArtifact.slice(`${root}/_build/default/`.length)
      .replace(/\.cmt$/, ".cmi");
    try {
      await Deno.writeTextFile(
        iface,
        interfaceSource + "\nval not_built : unit\n",
      );
      const changedInterface = await command("dune", ["build", cmiTarget]);
      assert(changedInterface.code === 0, changedInterface.err);
      const inconsistent = await check(false);
      assert(
        inconsistent.code === 2 &&
          inconsistent.report.findings.some((f) =>
            f.rule === "GAP-STALE-ARTIFACT"
          ),
        "unchanged implementation input cannot excuse a changed interface CRC: " +
          inconsistent.out,
      );
      console.log(
        "changed compiler interface invalidates old implementations: ok",
      );
    } finally {
      await Deno.writeTextFile(iface, interfaceSource);
      await Deno.utime(iface, interfaceTimes.atime!, interfaceTimes.mtime!);
      await check();
    }
    const future = new Date(Date.now() + 60_000);
    await Deno.writeTextFile(
      iface,
      interfaceSource + "\nval not_built : unit\n",
    );
    await Deno.utime(iface, future, future);
    const stale = await check(false);
    assert(
      stale.code === 2 &&
        stale.report.findings.some((f) => f.rule === "GAP-STALE-ARTIFACT"),
      "stale interface must not approve a public facet: " + stale.out,
    );
    console.log("stale public interface: ok");
    await Deno.writeTextFile(iface, interfaceSource);
    await Deno.utime(iface, interfaceTimes.atime!, interfaceTimes.mtime!);
    await check();
    for (
      const file of [
        "lib/generated/native/app_service_common.ml",
        "lib/generated/native/app_service_task_access.ml",
        "lib/generated/native/app_contract.ml",
        "lib/generated/browser/app_browser.ml",
      ]
    ) {
      const path = `${root}/${file}`;
      const times = await Deno.stat(path);
      const source = await Deno.readTextFile(path);
      try {
        await Deno.writeTextFile(path, source + "\nlet not_built = ()\n");
        await Deno.utime(
          path,
          times.atime!,
          file.endsWith("app_service_common.ml") ? times.mtime! : future,
        );
        const result = await check(false);
        assert(
          result.code === 2 && result.report.findings.some((f) =>
            f.rule === "GAP-STALE-ARTIFACT"
          ) && result.report.findings.some((f) =>
            f.rule === "GAP-UNRESOLVED-TARGET"
          ),
          `${file}: stale target/alias must remain a gap: ${result.out}`,
        );
        assert(
          !result.report.findings.some((f) =>
            f.rule === "IMPL-ACCESS-CROSS-SERVICE" ||
            f.rule === "SHARED-UNAPPROVED"
          ),
          `${file}: stale evidence must not establish implementation access: ${result.out}`,
        );
        console.log(`stale contract evidence ${file}: ok`);
      } finally {
        await Deno.writeTextFile(path, source);
        await Deno.utime(path, times.atime!, times.mtime!);
      }
    }
    const artifacts = (await compilerArtifacts(
      `${root}/_build/default/lib/generated`,
    )).filter((path) => path.endsWith("__App_service_common.cmt"));
    assert(
      artifacts.length > 0,
      "missing-artifact scenario needs real artifacts",
    );
    const hidden = await Deno.makeTempDir({
      prefix: "szaniec-missing-contract-",
    });
    try {
      for (const [index, path] of artifacts.entries()) {
        await Deno.rename(path, `${hidden}/${index}.cmt`);
      }
      const missing = await check(false);
      assert(
        missing.code === 2 && missing.report.findings.some((f) =>
          f.rule === "GAP-UNOBSERVED-SOURCE"
        ) && missing.report.findings.some((f) =>
          f.rule === "GAP-PUBLIC-CONTRACT"
        ) && missing.report.findings.some((f) =>
          f.rule === "GAP-UNRESOLVED-TARGET"
        ),
        "missing contract targets must retain incomplete evidence: " +
          missing.out,
      );
      assert(
        !missing.report.findings.some((f) =>
          f.rule === "IMPL-ACCESS-CROSS-SERVICE" ||
          f.rule === "SHARED-UNAPPROVED"
        ),
        "missing evidence must not establish implementation access: " +
          missing.out,
      );
      console.log("missing contract artifacts: ok");
      const graph = await command(binary, [
        "check",
        "--project-root",
        root,
        "--json",
        "--out",
        "missing-graph.json",
      ]);
      assert(graph.code === 2, graph.err + graph.out);
      const network = JSON.stringify(
        JSON.parse(await Deno.readTextFile(`${root}/missing-graph.json`)),
      );
      assert(
        network.includes('"kind":"unresolved"') &&
          network.includes("target ownership cannot be resolved"),
        "unavailable contract targets must retain unresolved graph evidence",
      );
    } finally {
      for (const [index, path] of artifacts.entries()) {
        await Deno.rename(`${hidden}/${index}.cmt`, path);
      }
      await Deno.remove(hidden, { recursive: true });
    }
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
