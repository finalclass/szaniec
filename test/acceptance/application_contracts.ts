const repository = new URL("../../", import.meta.url).pathname.replace(
  /\/$/,
  "",
);
const binaries = Deno.args.length > 0 ? Deno.args : [
  `${repository}/_build/default/bin/szaniec.exe`,
  `${repository}/_release/szaniec`,
];
const probe =
  `${repository}/_build/default/test/acceptance/contract_bindings_probe.exe`;
const services = [
  "Task_manager",
  "Task_access",
  "Notification_manager",
  "Template_engine",
  "Formatting_engine",
];
const decoder = new TextDecoder();
const versions = await Deno.readTextFile(`${repository}/lib/model/version.ml`);
const expectedAdapters = Object.fromEntries(
  [["programAccess", "adapter_ocaml"], ["interpretation", "adapter_well"], [
    "rules",
    "rules",
  ]].map(([key, variable]) => {
    const match = versions.match(new RegExp(`let ${variable} = "([^"]+)"`));
    assert(match, `missing version: ${variable}`);
    return [key, match[1]];
  }),
);

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

type Report = {
  status: string;
  inputs: {
    compiler: string;
    adapters: { programAccess: string; interpretation: string; rules: string };
    policy: { digest: string; approvedDigest: string };
  };
  findings: { rule: string; participants: string[]; evidencePath: string[] }[];
  summary: { violations: number; gaps: number };
};
type Evidence = {
  units: {
    module: string;
    source: string;
    artifact: string;
    fresh: boolean;
    header: string;
  }[];
  calls: { caller: string; callee: string }[];
  references: string[];
  owners: { module: string; class: string; service: string }[];
  interactions: {
    kind: string;
    from: string;
    to: string;
    method: string;
    api: string;
    path: string[];
  }[];
  gaps: { code: string; path: string }[];
};

for (const binary of binaries) {
  Deno.test(`application-generated bindings: ${binary.slice(repository.length + 1)}`, async () => {
    const root = await Deno.makeTempDir({
      prefix: "szaniec-application-contracts-",
    });
    const environment = Deno.env.toObject();
    for (const key of Object.keys(environment)) {
      if (/^(DUNE_|OCAML|CAML_|BUILD_PATH_PREFIX_MAP|INSIDE_DUNE)/.test(key)) {
        delete environment[key];
      }
    }
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
        "--out",
        "graph.json",
        ...(rebuild ? ["--rebuild"] : []),
      ]);
      assert(result.out.startsWith("{"), result.err + result.out);
      return { ...result, report: JSON.parse(result.out) as Report };
    }
    async function evidence() {
      const result = await command(probe, [root]);
      assert(result.code === 0, result.err + result.out);
      return JSON.parse(result.out) as Evidence;
    }
    async function scenario(
      name: string,
      changes: Record<string, string>,
      rules: string[],
      code = 1,
      reapprove = false,
      validate?: (facts: Evidence) => void,
    ) {
      const originals = new Map<string, string | null>();
      const originalPolicy = await Deno.readTextFile(`${root}/szaniec.toml`);
      try {
        for (const [file, text] of Object.entries(changes)) {
          let original = null;
          try {
            original = await Deno.readTextFile(`${root}/${file}`);
          } catch (error) {
            if (!(error instanceof Deno.errors.NotFound)) throw error;
          }
          originals.set(file, original);
          assert(text !== original, `${name}: mutation did not change ${file}`);
          await Deno.writeTextFile(`${root}/${file}`, text);
        }
        if (reapprove) await approve();
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
        if (validate) validate(await evidence());
        console.log(`${name}: ok`);
      } finally {
        for (const [file, text] of originals) {
          if (text === null) await Deno.remove(`${root}/${file}`);
          else await Deno.writeTextFile(`${root}/${file}`, text);
        }
        await Deno.writeTextFile(`${root}/szaniec.toml`, originalPolicy);
      }
    }
    try {
      await copy(`${repository}/test/fixtures/tasks-app`, root);
      await copy(
        `${repository}/test/fixtures/generated-contracts/lib`,
        `${root}/lib`,
      );
      for (
        const directory of [
          "contract_data",
          "contract_data_browser",
          "generated_server",
          "generated_browser",
        ]
      ) {
        for await (const entry of Deno.readDir(`${root}/lib/${directory}`)) {
          if (!entry.name.endsWith(".ml")) continue;
          const path = `${root}/lib/${directory}/${entry.name}`;
          const source = (await Deno.readTextFile(path))
            .replace(
              /^\(\* Generated by (Well|Cyrograf)\. Do not edit\. \*\)\n\n/,
              "",
            )
            .replace(/  let unknown value = [^\n]+\n\n/, "");
          await Deno.writeTextFile(path, source);
          if (entry.name.startsWith("app_service_")) {
            await Deno.rename(
              path,
              path.replace("/app_service_", "/project_service_"),
            );
          }
        }
        const dune = `${root}/lib/${directory}/dune`;
        await Deno.writeTextFile(
          dune,
          (await Deno.readTextFile(dune)).replace(
            "app_server",
            "project_native",
          ).replace("app_browser", "project_browser"),
        );
      }
      for (
        const [directory, library] of [["generated_server", "project_native"], [
          "generated_browser",
          "project_browser",
        ]]
      ) {
        await Deno.writeTextFile(
          `${root}/lib/${directory}/${library}.ml`,
          "module Nested = struct\n" + services.map((service) =>
            `module ${service} = Project_service_${service.toLowerCase()}\n`
          ).join("") + "end\n",
        );
      }
      for (const service of services) {
        const contract = `${root}/lib/contract/${service}.cyrograf`;
        await Deno.writeTextFile(
          contract,
          "struct Request { value: i32 }\n" + await Deno.readTextFile(contract),
        );
      }
      const dune = `${root}/lib/dune`;
      await Deno.writeTextFile(
        dune,
        (await Deno.readTextFile(dune)).replace(
          "  contract\n  well",
          "  contract\n  contract_data\n  contract_data_browser\n  project_native\n  project_browser\n  well",
        ),
      );
      await Deno.copyFile(
        `${repository}/test/fixtures/generated-contracts/application.toml`,
        `${root}/szaniec.toml`,
      );
      const client = "lib/web_client/tasks_page.ml";
      const codec = "lib/web_client/generated_codec.ml";
      await Deno.writeTextFile(
        `${root}/${codec}`,
        `module Native = Project_native.Nested.Task_manager
module Browser = Project_browser.Nested.Task_manager
module Access = Project_browser.Nested.Task_access
module Engine = Project_native.Nested.Template_engine
module Data = Contract_data.Task_access.Request
module Browser_data = Contract_data_browser.Template_engine.Request

let native value = Native.Request.from_drut (Native.Request.to_drut (Native.Request.make value))
let browser value = Browser.Request.from_drut (Browser.Request.to_drut (Browser.Request.make value))
let access value = Access.Request.from_drut (Access.Request.to_drut (Access.Request.make value))
let engine value = Engine.Request.from_drut (Engine.Request.to_drut (Engine.Request.make value))
let data value = Data.from_drut (Data.to_drut (Data.make value))
let browser_data value = Browser_data.from_drut (Browser_data.to_drut (Browser_data.make value))
let storage value = Native.Request.Storage.from_storage_value (Browser.Request.Storage.to_storage_value (Browser.Request.Storage.from_storage_value value))
let wire value = Browser.Request.Storage.storage_of_wire (Native.Request.Storage.wire_of_storage value)
let callback value = List.map Access.Request.to_drut [Access.Request.make value]
`,
      );
      const clientSource = (await Deno.readTextFile(`${root}/${client}`))
        .replace(
          "Task_manager.add ~ctx:ctx_w",
          "Project_browser.Nested.Task_manager.Proxy.add ~ctx:ctx_w",
        );
      await Deno.writeTextFile(`${root}/${client}`, clientSource);
      await approve();
      const base = await check();
      assert(
        base.code === 0 && base.report.status === "ok",
        base.err + base.out,
      );
      assert(
        base.report.summary.violations === 0 && base.report.summary.gaps === 0,
        base.out,
      );
      console.log(JSON.stringify({ inputs: base.report.inputs }));
      assert(
        base.report.inputs.compiler === "5.4",
        "fixture must use supported compiler artifacts",
      );
      for (const [key, expected] of Object.entries(expectedAdapters)) {
        assert(
          base.report.inputs
            .adapters[key as keyof Report["inputs"]["adapters"]] === expected,
          `stale binary adapter: ${key}`,
        );
      }
      assert(
        base.report.inputs.policy.digest ===
          base.report.inputs.policy.approvedDigest,
        "exact binding policy must be approved",
      );
      const fresh = await evidence();
      assert(fresh.gaps.length === 0, JSON.stringify(fresh.gaps));
      assert(
        fresh.units.every((unit) => unit.fresh),
        "all compiler artifacts must be fresh without assume_fresh",
      );
      console.log(
        `fresh compiler units: ${fresh.units.length}; explicit contract bindings: 20`,
      );
      for (const service of services) {
        for (const library of ["Project_native", "Project_browser"]) {
          const module = `${library}.Project_service_${service.toLowerCase()}`;
          assert(
            fresh.owners.some((owner) =>
              owner.module === module && owner.service === service &&
              owner.class.startsWith("contract")
            ),
            `missing contract owner: ${module}`,
          );
          assert(
            fresh.units.some((unit) =>
              unit.module === module && !unit.header.includes("Generated by")
            ),
            `wrapper must have no recognized header: ${module}`,
          );
        }
      }
      assert(
        fresh.calls.some((call) =>
          call.caller ===
            "Project_browser.Project_service_task_manager.Request.to_drut" &&
          call.callee === "Contract_data_browser.Task_manager.Request.to_drut"
        ),
        "conversion forwarding must retain its compiler dependency",
      );
      assert(
        fresh.calls.some((call) =>
          call.caller ===
            "Project_browser.Project_service_task_access.Proxy.create" &&
          call.callee === "Task_access.create"
        ),
        "proxy forwarding must retain its compiler dependency",
      );
      assert(
        fresh.references.includes(
          "Project_browser.Project_service_task_access.Request.to_drut",
        ),
        "codec callback dependency must remain",
      );
      assert(
        !fresh.interactions.some((i) =>
          i.kind === "service-request" && /\.(Request|Storage)\./.test(i.api)
        ),
        "conversions must not become requests",
      );
      assert(
        !fresh.interactions.some((i) =>
          i.kind === "service-request" && i.from.startsWith("Project_")
        ),
        "wrapper plumbing must not become an independent caller",
      );
      assert(
        fresh.interactions.some((i) =>
          i.kind === "service-request" && i.from === "Web_client" &&
          i.to === "Task_manager" && i.method === "add"
        ),
        "real caller's RPC must survive",
      );
      const firstGraph = await Deno.readTextFile(`${root}/graph.json`);
      const network = JSON.parse(firstGraph);
      assert(
        network.services.map((s: { name: string }) => s.name).sort().join(
          ",",
        ) === [...services, "Audit_client"].sort().join(","),
        "wrappers and aggregates must not declare independent services",
      );
      const repeated = await check(false);
      assert(
        repeated.out === base.out &&
          await Deno.readTextFile(`${root}/graph.json`) === firstGraph,
        "identical fresh input must produce identical report and graph",
      );
      console.log("approved headerless codecs and proxy forwarding: ok");

      await scenario(
        "client-to-access through helper and browser proxy",
        {
          [client]: clientSource.replace(
            "let tasks_handler req =",
            "let create title = Project_browser.Nested.Task_access.Proxy.create ~ctx:ctx_w ~title\n\nlet tasks_handler req =",
          ).replace(
            "Project_browser.Nested.Task_manager.Proxy.add ~ctx:ctx_w ~title:req.title",
            "create req.title",
          ),
        },
        ["ID-CLIENT-ACCESS"],
        1,
        false,
        (facts) =>
          assert(
            facts.interactions.some((i) =>
              i.from === "Web_client" && i.to === "Task_access" &&
              i.method === "create" && i.path.length >= 3
            ),
            "original client and helper path must survive",
          ),
      );
      const manager = "lib/task_manager/task_manager_impl.ml";
      const managerSource = await Deno.readTextFile(`${root}/${manager}`);
      await scenario(
        "synchronous manager-to-manager through browser proxy",
        {
          [manager]: managerSource.replace(
            "    Task_access.create ~ctx ~title:req.title",
            "    ignore (Project_browser.Nested.Notification_manager.Proxy.publish ~ctx ~text:req.title);\n    Task_access.create ~ctx ~title:req.title",
          ),
          "lib/task_manager/dune":
            (await Deno.readTextFile(`${root}/lib/task_manager/dune`)).replace(
              "task_access_lib)",
              "task_access_lib project_browser)",
            ),
        },
        ["ID-MANAGER-MANAGER"],
        1,
        false,
        (facts) =>
          assert(
            facts.interactions.some((i) =>
              i.kind === "service-request" && i.from === "Task_manager" &&
              i.to === "Notification_manager" && i.method === "publish"
            ),
            "manager proxy must retain original caller and target",
          ),
      );
      const engine = "lib/template_engine/template_engine_impl.ml";
      await scenario(
        "engine-to-engine through native proxy",
        {
          [engine]: (await Deno.readTextFile(`${root}/${engine}`)).replace(
            'let expand _ctx text = "{" ^ text ^ "}"',
            "let expand ctx text = Project_native.Nested.Formatting_engine.Proxy.render ~ctx ~text",
          ),
          "lib/template_engine/dune":
            (await Deno.readTextFile(`${root}/lib/template_engine/dune`))
              .replace(
                "formatting_engine_lib)",
                "formatting_engine_lib project_native)",
              ),
        },
        ["ID-ENGINE-ENGINE"],
        1,
        false,
        (facts) =>
          assert(
            facts.interactions.some((i) =>
              i.kind === "service-request" && i.from === "Template_engine" &&
              i.to === "Formatting_engine" && i.method === "render"
            ),
            "engine proxy must retain original caller and target",
          ),
      );
      const config = await Deno.readTextFile(`${root}/szaniec.toml`);
      await scenario(
        "unapproved declarations do not grant contract status",
        {
          "szaniec.toml": config.replace(
            'name = "tasks-app"',
            'name = "edited"',
          ),
        },
        ["GAP-POLICY-NOT-APPROVED"],
        2,
      );
      await scenario(
        "missing wrapper binding does not grant contract status",
        {
          "szaniec.toml": config.replace(
            /\[\[policy\.contract_bindings\]\][\s\S]*?(?=\n\[|$)/g,
            (binding) =>
              binding.includes('"Project_browser.Nested.Task_manager"')
                ? ""
                : binding,
          ),
        },
        ["POLICY-UNCLASSIFIED"],
        1,
        true,
      );
      await scenario(
        "missing binding unit remains a gap",
        {
          "szaniec.toml": config.replace(
            '"Project_browser.Nested.Task_manager"',
            '"Project_browser.Missing"',
          ),
        },
        ["GAP-PUBLIC-CONTRACT", "POLICY-UNCLASSIFIED"],
        2,
        true,
      );
      await scenario(
        "conflicting contract identity remains a gap",
        {
          "szaniec.toml": config +
            '\n[[policy.contract_bindings]]\nsource = "lib/contract/Task_access.cyrograf"\nmodule = "Project_browser.Nested.Task_manager"\n',
        },
        ["GAP-AMBIGUOUS-OWNERSHIP"],
        2,
        true,
      );
      const wrapper = "lib/generated_browser/project_service_task_manager.ml";
      const wrapperSource = await Deno.readTextFile(`${root}/${wrapper}`);
      await scenario(
        "missing generator provenance remains a gap",
        {
          "lib/generated_browser/app_service_task_manager.ml": wrapperSource,
        },
        ["GAP-AMBIGUOUS-OWNERSHIP"],
        2,
      );
      const browserDune = "lib/generated_browser/dune";
      const browserDuneSource = await Deno.readTextFile(
        `${root}/${browserDune}`,
      );
      await scenario(
        "approved wrapper retains private executable dependencies",
        {
          [wrapper]: wrapperSource +
            '\nlet helper () = Json_util.normalize "private"\n',
          [browserDune]: browserDuneSource.replace(
            "contract well)",
            "contract well task_access_lib)",
          ),
        },
        ["IMPL-ACCESS-CROSS-SERVICE"],
      );
      const access = "lib/task_access/task_access_impl.ml";
      const accessSource = await Deno.readTextFile(`${root}/${access}`);
      await scenario(
        "authored helper named to_drut is not a codec",
        {
          [access]: accessSource + "\nlet to_drut title = String.trim title\n",
          [client]: clientSource +
            '\nlet bypass () = Task_access_impl.to_drut "private"\n',
        },
        ["IMPL-ACCESS-CROSS-SERVICE"],
      );
      await scenario(
        "private nested wrapper member is not a codec",
        {
          [wrapper]: wrapperSource +
            "\nmodule Store = struct\nlet to_drut value = String.trim value\nend\n",
          [client]: clientSource +
            '\nlet bypass () = Project_browser.Nested.Task_manager.Store.to_drut "private"\n',
        },
        ["IMPL-ACCESS-CROSS-SERVICE", "SPEC-UNDECLARED-METHOD"],
      );
      await check();
      const future = new Date(Date.now() + 60_000);
      await Deno.writeTextFile(
        `${root}/${wrapper}`,
        wrapperSource + "\nlet not_built = ()\n",
      );
      await Deno.utime(`${root}/${wrapper}`, future, future);
      const stale = await check(false);
      assert(
        stale.code === 2 && stale.report.findings.some((f) =>
          f.rule === "GAP-STALE-ARTIFACT"
        ) && stale.report.findings.some((f) =>
          f.rule === "GAP-PUBLIC-CONTRACT"
        ),
        "stale wrapper must invalidate its explicit binding: " + stale.out,
      );
      const staleEvidence = await evidence();
      assert(
        !staleEvidence.owners.some((o) =>
          o.module === "Project_browser.Project_service_task_manager" &&
          o.class.startsWith("contract")
        ),
        "stale wrapper must not retain contract status",
      );
      console.log("stale bound wrapper: ok");
    } finally {
      await Deno.remove(root, { recursive: true });
    }
  });
}
