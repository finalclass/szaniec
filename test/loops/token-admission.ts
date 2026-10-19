const root = new URL("../../", import.meta.url).pathname;
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("token admission callbacks retain activation, violations and unknown labels", async () => {
  const project = await Deno.makeTempDir({
    prefix: "szaniec-token-admission-",
  });
  async function check(...args: string[]) {
    const result = await new Deno.Command(
      `${root}_build/default/bin/szaniec.exe`,
      {
        cwd: project,
        args,
        stdout: "piped",
        stderr: "piped",
      },
    ).output();
    return {
      code: result.code,
      out: decoder.decode(result.stdout),
      err: decoder.decode(result.stderr),
    };
  }
  try {
    const copied = await new Deno.Command("cp", {
      args: ["-R", `${root}test/fixtures/tasks-app/.`, project],
    }).output();
    assert(copied.success, decoder.decode(copied.stderr));
    const stub = `${project}/lib/well_stub/well.ml`;
    await Deno.writeTextFile(
      stub,
      await Deno.readTextFile(stub) + `
let api_token_auth ?(applies_to = fun _ -> true) ?(authorize = fun _ -> true)
    ?(unknown = fun _ -> true) ~verify () = ignore (applies_to, authorize, unknown, verify)
`,
    );
    const page = `${project}/lib/web_client/tasks_page.ml`;
    const previous = await Deno.readTextFile(page);
    const registration = (label: string) => `
let () = Well.api_token_auth ~${label}:(fun (_ : Well.request) ->
  ignore (Task_access.list ~ctx:{Well.session_id=""; user_id=None} ~limit:1); true)
  ~verify:(fun (_ : string) -> None) ()
`;
    await Deno.writeTextFile(page, previous + registration("authorize"));
    assert((await check("approve")).code === 0, "fixture policy approved");
    const supported = await check("check", "--rebuild", "--json");
    const report = JSON.parse(supported.out);
    assert(
      !report.findings.some((f: { severity: string }) => f.severity === "gap"),
      supported.err + supported.out,
    );
    assert(
      report.findings.some((f: { rule: string }) =>
        f.rule === "ID-CLIENT-ACCESS"
      ),
      "callback application call must still violate Client-to-Access",
    );
    assert(supported.code === 1, "known callback does not suppress violations");
    const graph = JSON.parse(
      await Deno.readTextFile(`${project}/szaniec.json`),
    );
    const contexts = graph.services.flatMap((
      s: {
        methods: {
          calls: { contexts: { activations: { api: string }[] }[] }[];
        }[];
      },
    ) => s.methods.flatMap((m) => m.calls.flatMap((c) => c.contexts)));
    assert(
      contexts.some((c: { activations: { api: string }[] }) =>
        c.activations.some((a) => a.api === "Well.api_token_auth")
      ),
      "callback retains independent activation context",
    );
    await Deno.writeTextFile(page, previous + registration("unknown"));
    const unknown = await check("check", "--rebuild", "--json");
    assert(
      unknown.code === 2 &&
        JSON.parse(unknown.out).findings.some((f: { rule: string }) =>
          f.rule === "GAP-CALLBACK-SEMANTICS"
        ),
      "unknown label remains incomplete",
    );
  } finally {
    await Deno.remove(project, { recursive: true });
  }
});
