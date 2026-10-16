const repo = new URL("../../", import.meta.url).pathname.replace(/\/$/, "");
const bin = Deno.env.get("SZANIEC_COACHING_BINARY") ??
  `${repo}/_build/default/bin/szaniec.exe`;
const decode = new TextDecoder();

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

async function run(root: string, ...args: string[]) {
  const result = await new Deno.Command(bin, {
    args: [...args, "--project-root", root],
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: result.code,
    out: decode.decode(result.stdout),
    err: decode.decode(result.stderr),
  };
}

async function copy(source: string, target: string) {
  await Deno.mkdir(target, { recursive: true });
  for await (const entry of Deno.readDir(source)) {
    if (entry.name === "_build" || entry.name.startsWith(".")) continue;
    if (entry.isDirectory) {
      await copy(`${source}/${entry.name}`, `${target}/${entry.name}`);
    } else if (entry.isFile) {
      await Deno.copyFile(`${source}/${entry.name}`, `${target}/${entry.name}`);
    }
  }
}

Deno.test("coaching preserves source findings, mixed gaps, summaries and clean runs", async () => {
  const root = await Deno.makeTempDir({ prefix: "szaniec-coaching-" });
  try {
    await copy(`${repo}/test/fixtures/tasks-app`, root);
    assert((await run(root, "approve")).code === 0, "fixture approval");
    let result = await run(root, "check", "--rebuild", "--json");
    assert(result.code === 0, result.err + result.out);
    assert(JSON.parse(result.out).findings.length === 0, "clean findings");
    const source = `${root}/lib/web_client/tasks_page.ml`;
    const original = await Deno.readTextFile(source);
    await Deno.writeTextFile(
      source,
      original.replace(
        "Task_manager.add ~ctx:ctx_w ~title:req.title",
        "Task_access.create ~ctx:ctx_w ~title:req.title",
      ),
    );
    result = await run(root, "check", "--rebuild", "--json");
    assert(result.code === 1, result.err + result.out);
    const report = JSON.parse(result.out);
    const finding = report.findings.find((f: { rule: string }) =>
      f.rule === "ID-CLIENT-ACCESS"
    );
    assert(finding?.severity === "violation", "original severity retained");
    assert(
      finding.locations.some((l: { path: string }) =>
        l.path === "lib/web_client/tasks_page.ml"
      ) && finding.evidencePath.length >= 2,
      "original source and call path retained",
    );
    assert(
      finding.coaching.catalog === "szaniec-coaching/1" &&
        finding.coaching.id === "client-business-entry",
      "Client-to-Access repair guide",
    );
    const second = await run(root, "check", "--json");
    assert(
      second.code === result.code && second.out === result.out,
      "stable JSON",
    );
    const graph = await Deno.readTextFile(`${root}/szaniec.json`);
    const text = await run(root, "check");
    assert(text.code === 1, text.err);
    assert(
      text.out.includes(
        "coaching [szaniec-coaching/1/client-business-entry]",
      ) &&
        text.out.includes("example before:") && text.out.includes("avoid:") &&
        text.out.includes("path:"),
      "guide accompanies the original text evidence",
    );
    assert(
      await Deno.readTextFile(`${root}/szaniec.json`) === graph,
      "coaching presentation leaves graph unchanged",
    );
    const summary = await run(root, "check", "--summary");
    assert(
      summary.code === 1 &&
        summary.out === "szaniec violations: 1 violation(s), 0 gap(s)\n",
      "one-line summary and status",
    );
    const configPath = `${root}/szaniec.toml`;
    const config = await Deno.readTextFile(configPath);
    await Deno.writeTextFile(
      configPath,
      config.replace('name = "tasks-app"', 'name = "changed-policy"'),
    );
    result = await run(root, "check", "--json");
    const mixed = JSON.parse(result.out);
    assert(
      result.code === 2 &&
        mixed.summary.violations >= report.summary.violations &&
        mixed.summary.gaps >= 1,
      result.err + result.out,
    );
    assert(
      JSON.stringify(
        mixed.findings.find((f: { rule: string }) =>
          f.rule === "ID-CLIENT-ACCESS"
        ),
      ) === JSON.stringify(finding),
      "original violation, evidence and guide survive the approval gap",
    );
    assert(
      mixed.findings.some((f: { rule: string; coaching: { id: string } }) =>
        f.rule === "GAP-POLICY-NOT-APPROVED" &&
        f.coaching.id === "approved-policy"
      ),
      "approval gap gets deliberate-review guidance",
    );
    await Deno.writeTextFile(configPath, config);
    await Deno.writeTextFile(source, original);
    result = await run(root, "check", "--rebuild");
    assert(
      result.code === 0 && !result.out.includes("coaching ["),
      "clean result has no repair guide: " + result.err + result.out,
    );
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
