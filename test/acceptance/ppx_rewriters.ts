// Dune-managed PPX rewriters ([preprocess (pps ...)]) are trusted Dune
// dependencies: an ordinary external `dune build` yields current evidence
// without `check --rebuild`, while generated code is still analyzed and
// authored source edits are still detected. The driver uses only
// compiler-libs so the suite needs no ppxlib installation.
const repository = new URL("../../", import.meta.url).pathname.replace(
  /\/$/,
  "",
);
const binary = Deno.env.get("SZANIEC_TEST_BINARY") ??
  `${repository}/_release/szaniec`;
const decoder = new TextDecoder();
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
type Report = {
  status: string;
  summary: { violations: number; gaps: number };
  findings: { rule: string; locations: { path: string }[] }[];
};

const driver = `let mappers : Ast_mapper.mapper list ref = ref []

let register mapper = mappers := mapper :: !mappers

let main () =
  let rec parse output input kind = function
    | "-o" :: path :: rest -> parse (Some path) input kind rest
    | "--impl" :: path :: rest -> parse output (Some path) \`Impl rest
    | "--intf" :: path :: rest -> parse output (Some path) \`Intf rest
    | ("--cookie" | "-corrected-suffix" | "-diff-cmd") :: _ :: rest ->
        parse output input kind rest
    | _ :: rest -> parse output input kind rest
    | [] -> (output, input, kind)
  in
  match parse None None \`Impl (List.tl (Array.to_list Sys.argv)) with
  | Some output, Some input, kind ->
      let channel = open_in_bin input in
      let lexbuf = Lexing.from_channel channel in
      Location.init lexbuf input ;
      let out = open_out_bin output in
      ( match kind with
      | \`Impl ->
          let ast =
            List.fold_left
              (fun ast (m : Ast_mapper.mapper) -> m.structure m ast)
              (Parse.implementation lexbuf)
              !mappers
          in
          output_string out Config.ast_impl_magic_number ;
          output_value out input ;
          output_value out ast
      | \`Intf ->
          let ast =
            List.fold_left
              (fun ast (m : Ast_mapper.mapper) -> m.signature m ast)
              (Parse.interface lexbuf)
              !mappers
          in
          output_string out Config.ast_intf_magic_number ;
          output_value out input ;
          output_value out ast ) ;
      close_out out ;
      close_in channel
  | _ ->
      prerr_endline "usage: driver -o OUTPUT (--impl|--intf) INPUT" ;
      exit 2
`;

// [%szaniec.expr "code"] expands to the parsed expression, standing in for
// rewriters such as well.ppx that emit calls the author never wrote.
const rewriter = `let expand (expr : Parsetree.expression) =
  match expr.pexp_desc with
  | Pexp_extension
      ( {txt= "szaniec.expr"; _}
      , PStr
          [ { pstr_desc=
                Pstr_eval
                  ({pexp_desc= Pexp_constant {pconst_desc= Pconst_string (code, _, _); _}; _}, _)
            ; _ } ] ) ->
      let lexbuf = Lexing.from_string code in
      Lexing.set_position lexbuf expr.pexp_loc.loc_start ;
      Some (Parse.expression lexbuf)
  | _ -> None

let () =
  Szaniec_test_driver.register
    { Ast_mapper.default_mapper with
      expr=
        (fun self expr ->
          match expand expr with
          | Some expr -> expr
          | None -> Ast_mapper.default_mapper.expr self expr ) }
`;

Deno.test("Dune-managed PPX rewrites need no transformation receipt", async () => {
  const root = await Deno.makeTempDir({ prefix: "szaniec-ppx-" });
  const environment = Deno.env.toObject();
  for (const key of Object.keys(environment)) {
    if (/^(DUNE_|OCAML|CAML_|BUILD_PATH_PREFIX_MAP|INSIDE_DUNE)/.test(key)) {
      delete environment[key];
    }
  }
  environment.DUNE_CACHE = "disabled";
  async function command(executable: string, args: string[]) {
    const result = await new Deno.Command(executable, {
      args,
      cwd: root,
      clearEnv: true,
      env: environment,
      stdout: "piped",
      stderr: "piped",
    }).output();
    return {
      code: result.code,
      out: decoder.decode(result.stdout),
      err: decoder.decode(result.stderr),
    };
  }
  async function build() {
    const result = await command("dune", ["build"]);
    assert(result.code === 0, result.err + result.out);
  }
  async function check(cache = "on") {
    environment.SZANIEC_OBSERVATION_CACHE = cache;
    const result = await command(binary, ["check", "--json"]);
    assert(result.out.startsWith("{"), result.err + result.out);
    return { ...result, report: JSON.parse(result.out) as Report };
  }
  const rules = (report: Report) => report.findings.map((f) => f.rule);
  try {
    const copy = await command("cp", [
      "-R",
      `${repository}/test/fixtures/tasks-app/.`,
      root,
    ]);
    assert(copy.code === 0, copy.err);
    await Deno.mkdir(`${root}/support/rewriter`, { recursive: true });
    await Deno.writeTextFile(
      `${root}/support/rewriter/dune`,
      `(library
 (name szaniec_test_driver)
 (modules szaniec_test_driver)
 (libraries compiler-libs.common)
 (ppx.driver
  (main Szaniec_test_driver.main)))

(library
 (name szaniec_test_rewriter)
 (modules szaniec_test_rewriter)
 (kind ppx_rewriter)
 (libraries compiler-libs.common szaniec_test_driver))
`,
    );
    await Deno.writeTextFile(
      `${root}/support/rewriter/szaniec_test_driver.ml`,
      driver,
    );
    await Deno.writeTextFile(
      `${root}/support/rewriter/szaniec_test_rewriter.ml`,
      rewriter,
    );
    const libraryDune = `${root}/lib/dune`;
    const library = await Deno.readTextFile(libraryDune);
    await Deno.writeTextFile(
      libraryDune,
      library.replace(
        " (flags",
        " (preprocess\n  (pps szaniec_test_rewriter))\n (flags",
      ),
    );
    assert((await command(binary, ["approve"])).code === 0, "approve fixture");
    await build();
    const artifacts = await command("find", [
      "_build/default/lib",
      "-name",
      "*.pp.ml",
    ]);
    assert(
      artifacts.out.includes("tasks_page.pp.ml"),
      "fixture must compile Dune PPX output: " + artifacts.out,
    );

    const base = await check();
    assert(
      base.code === 0 && base.report.summary.gaps === 0,
      "external Dune PPX build must be current: " + base.out,
    );
    console.log("external build of Dune PPX units is current: ok");

    const page = `${root}/lib/web_client/tasks_page.ml`;
    const authored = await Deno.readTextFile(page);
    const call = "Task_manager.add ~ctx:ctx_w ~title:req.title";
    assert(authored.includes(call), "fixture call site moved");
    await Deno.writeTextFile(
      page,
      authored.replace(
        call,
        `[%szaniec.expr "Task_access.create ~ctx:ctx_w ~title:req.title"]`,
      ),
    );
    const stale = await check();
    assert(
      stale.code === 2 &&
        stale.report.findings.some((f) =>
          f.rule === "GAP-STALE-ARTIFACT" &&
          f.locations.some((l) => l.path === "lib/web_client/tasks_page.ml")
        ) &&
        !rules(stale.report).includes("GAP-UNVERIFIABLE-TRANSFORMATION"),
      "unbuilt authored edit must be stale, not trusted: " + stale.out,
    );
    console.log("unbuilt edit of a Dune PPX unit is stale: ok");

    await build();
    const generated = await check();
    assert(
      generated.code === 1 && generated.report.summary.gaps === 0 &&
        rules(generated.report).includes("ID-CLIENT-ACCESS"),
      "PPX-generated client-to-access call must remain a violation: " +
        generated.out,
    );
    const uncached = await check("off");
    assert(
      uncached.out === generated.out,
      "cached and uncached PPX evidence differ",
    );
    console.log("PPX-generated call is analyzed after an external build: ok");

    // Compiler-applied preprocessing is not a Dune dependency and still
    // requires the checker's own build evidence.
    await Deno.writeTextFile(page, authored);
    await Deno.writeTextFile(
      libraryDune,
      library.replace(" (flags\n  (:standard", " (flags\n  (:standard -pp cat"),
    );
    await build();
    const compilerApplied = await check();
    assert(
      compilerApplied.code === 2 &&
        rules(compilerApplied.report).includes(
          "GAP-UNVERIFIABLE-TRANSFORMATION",
        ),
      "compiler-applied -pp must keep receipt evidence: " +
        compilerApplied.out,
    );
    console.log("compiler-applied preprocessing still needs receipts: ok");
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
