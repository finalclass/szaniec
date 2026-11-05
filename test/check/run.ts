// Source-to-report tests for `szaniec check` over the fixture projects in
// test/fixtures/check. Positive cases mutate a copy of the conforming
// project; the conforming project itself is the negative case of every
// rule (each allowed edge appears in it at least once).
const bin = Deno.env.get("SZANIEC_CHECK_BINARY") ??
  new URL("../../_build/default/bin/szaniec.exe", import.meta.url).pathname;
const fixtures = new URL("../fixtures/check", import.meta.url).pathname;
const decoder = new TextDecoder();

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

type Endpoint = {
  name: string;
  kind: string;
  class: string;
  role: string | null;
};
type Position = { path: string; line: number; col: number };
type Finding = {
  rule: string;
  from: Endpoint;
  to: Endpoint;
  location: Position;
  message: string;
  coaching: string;
};
type Component = {
  name: string;
  kind: string;
  class: string;
  role: string | null;
  service: string | null;
  location: Position;
};
type Report = {
  format: string;
  status: string;
  project: string;
  profile: string;
  services: { name: string; source: string; methods: string[] }[];
  components: Component[];
  findings: Finding[];
};

async function check(dir: string, ...args: string[]) {
  const result = await new Deno.Command(bin, {
    args: ["check", dir, ...args],
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: result.code,
    stdout: decoder.decode(result.stdout),
    stderr: decoder.decode(result.stderr),
  };
}

// Coaching per rule seen in any report, compared with the catalog document.
const coaching = new Map<string, string>();

async function report(dir: string) {
  const r = await check(dir, "--json");
  assert(r.code !== 2, `check failed: ${r.stderr}`);
  const json = JSON.parse(r.stdout) as Report;
  for (const f of json.findings) coaching.set(f.rule, f.coaching);
  return { code: r.code, json };
}

async function copy(name: string): Promise<string> {
  const root = await Deno.makeTempDir({ prefix: `szaniec-check-${name}-` });
  const cp = await new Deno.Command("cp", {
    args: ["-R", `${fixtures}/${name}/.`, root],
  }).output();
  assert(cp.success, decoder.decode(cp.stderr));
  return root;
}

// 1-based position of the n-th whole-atom occurrence of [atom] in [text].
function position(text: string, atom: string, occurrence = 1) {
  const lines = text.split("\n");
  let seen = 0;
  for (let i = 0; i < lines.length; i++) {
    const re = new RegExp(
      `(?<=[\\s("])${atom.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?=[\\s)"]|$)`,
      "g",
    );
    for (const m of lines[i].matchAll(re)) {
      if (++seen === occurrence) return { line: i + 1, col: m.index! + 1 };
    }
  }
  throw new Error(`atom ${atom} not found`);
}

Deno.test("conforming project exits 0 with classified components", async () => {
  const dir = `${fixtures}/conforming`;
  const { code, json } = await report(dir);
  assert(code === 0, `exit ${code}: ${JSON.stringify(json.findings)}`);
  assert(json.format === "szaniec-check/2", "format");
  assert(json.status === "conforming" && json.findings.length === 0, "status");
  assert(json.profile === "well-ocaml", "profile");
  assert(
    JSON.stringify(json.services.map((s) => s.name)) ===
      '["Notification","OrderManager","PricingEngine","TaskAccess","TaskManager"]',
    `services ${JSON.stringify(json.services)}`,
  );
  const expected: Record<
    string,
    [string, string, string | null, string | null]
  > = {
    task_manager: ["library", "service", "manager", "TaskManager"],
    task_manager_contract: ["library", "contract", "manager", "TaskManager"],
    task_manager_spec: ["library", "spec", "manager", "TaskManager"],
    task_manager_wire: ["library", "wire", "manager", "TaskManager"],
    task_manager_browser: [
      "library",
      "browser-contract",
      "manager",
      "TaskManager",
    ],
    task_access: ["library", "service", "access", "TaskAccess"],
    task_access_api: ["library", "facet", "access", "TaskAccess"],
    notification: ["library", "service", "utility", "Notification"],
    pricing_engine: ["library", "service", "engine", "PricingEngine"],
    web_client: ["library", "local", "client", null],
    clock: ["library", "local", "utility", null],
    app_types: ["library", "local", "utility", null],
    main: ["executable", "root", null, null],
    test_tasks: ["test", "test", null, null],
  };
  for (const [name, [kind, cls, role, service]] of Object.entries(expected)) {
    const c = json.components.find((c) => c.name === name);
    assert(
      c && c.kind === kind && c.class === cls && c.role === role &&
        c.service === service,
      `${name}: ${JSON.stringify(c)}`,
    );
  }
  const text = await check(dir);
  assert(
    text.code === 0 && text.stdout.includes("conforming") &&
      text.stdout.includes("0 finding(s)"),
    text.stdout,
  );
  // --project-root is equivalent to the positional directory.
  const flag = await new Deno.Command(bin, {
    args: ["check", "--project-root", dir, "--json"],
  }).output();
  assert(
    flag.code === 0 &&
      (JSON.parse(decoder.decode(flag.stdout)) as Report).components.length ===
        json.components.length,
    "--project-root",
  );
});

Deno.test("directory walk honours dirs, data_only, vendored, subdir, include, select and comments", async () => {
  const dir = `${fixtures}/walk`;
  const source = await Deno.readTextFile(`${dir}/src/dune`);
  const { code, json } = await report(dir);
  assert(code === 1 && json.status === "violations", `exit ${code}`);
  assert(
    JSON.stringify(json.services.map((s) => [s.name, s.source])) ===
      '[["ReportEngine","data/ReportEngine.cyrograf"]]',
    `services from data-only dirs only: ${JSON.stringify(json.services)}`,
  );
  const names = json.components.map((c) => c.name).sort();
  assert(
    JSON.stringify(names) ===
      JSON.stringify([
        "clock",
        "generated_access",
        "included_util",
        "planner_manager",
        "report_engine",
        "vendor_manager_contract",
        "walker_client",
        "walker_util",
      ]),
    `components ${names}`,
  );
  const included = json.components.find((c) => c.name === "included_util")!;
  assert(
    included.location.path === "src/extra.inc" &&
      included.location.line === 2,
    "include position",
  );
  assert(
    json.components.find((c) => c.name === "vendor_manager_contract")
      ?.class === "local",
    "vendored contract was read",
  );
  const got = json.findings.map((f) =>
    [
      f.rule,
      f.from.name,
      f.to.name,
      f.location.path,
      f.location.line,
      f
        .location.col,
    ].join(" ")
  );
  const at = (atom: string, n = 1) => {
    const p = position(source, atom, n);
    return `src/dune ${p.line} ${p.col}`;
  };
  const want = [
    `ID-ENGINE-MANAGER report_engine planner_manager ${at("walk.planner", 2)}`,
    `IMPL-CROSS-SERVICE walker_client report_engine ${at("report_engine", 2)}`,
    `DUNE-REEXPORT walker_util clock ${at("clock", 3)}`,
    `ID-ACCESS-CLIENT generated_access walker_client ${at("walker_client", 2)}`,
  ];
  assert(
    JSON.stringify(got.slice().sort()) === JSON.stringify(want.slice().sort()),
    `findings\n${got.join("\n")}\nexpected\n${want.join("\n")}`,
  );
  for (const f of json.findings) {
    assert(f.message.length > 0 && f.coaching.length > 80, "coaching text");
  }
});

Deno.test("dependency names are classified even when their stanza is absent", async () => {
  const dir = `${fixtures}/absent-contracts`;
  const source = await Deno.readTextFile(`${dir}/lib/dune`);
  const { code, json } = await report(dir);
  assert(code === 1, `exit ${code}`);
  assert(
    !json.components.some((c) => c.name === "x_access_contract"),
    "excluded generated directory was read",
  );
  const got = json.findings.map((f) =>
    [
      f.rule,
      f.from.name,
      f.to.name,
      f.to.kind,
      f.to.class,
      f.location.line,
      f
        .location.col,
    ].join(" ")
  ).sort();
  const at = (atom: string, n = 1) => {
    const p = position(source, atom, n);
    return `${p.line} ${p.col}`;
  };
  const want = [
    `ID-CLIENT-ACCESS report_client x_access_contract undefined-library contract ${
      at("x_access_contract")
    }`,
    `ID-CLIENT-ENGINE report_client stats_engine undefined-library local ${
      at("stats_engine")
    }`,
    `IMPL-CROSS-SERVICE order_manager x_access undefined-library service ${
      at("x_access")
    }`,
    `ROOT-LEAK order_manager app_root undefined-library root ${at("app_root")}`,
  ].sort();
  assert(
    JSON.stringify(got) === JSON.stringify(want),
    `findings\n${got.join("\n")}\nexpected\n${want.join("\n")}`,
  );
});

// Each case adds lib/mutation/dune to a copy of the conforming project.
// [label, dune text, expected [rule, from, to, atom, occurrence?][]]
type Expect = [string, string, string, string, number?];
const cases: [string, string, Expect[]][] = [
  ["client to client", lib("admin_client", "web_client"), [
    ["ID-CLIENT-CLIENT", "admin_client", "web_client", "web_client"],
  ]],
  ["client to engine", lib("admin_client", "pricing_engine_contract"), [
    [
      "ID-CLIENT-ENGINE",
      "admin_client",
      "pricing_engine_contract",
      "pricing_engine_contract",
    ],
  ]],
  ["client to access", lib("admin_client", "task_access_contract"), [
    [
      "ID-CLIENT-ACCESS",
      "admin_client",
      "task_access_contract",
      "task_access_contract",
    ],
  ]],
  ["client to access facet", lib("admin_client", "task_access_api"), [
    ["ID-CLIENT-ACCESS", "admin_client", "task_access_api", "task_access_api"],
  ]],
  ["manager to manager", lib("billing_manager", "order_manager_contract"), [
    [
      "ID-MANAGER-MANAGER",
      "billing_manager",
      "order_manager_contract",
      "order_manager_contract",
    ],
  ]],
  [
    "manager to manager browser contract",
    lib(
      "billing_manager",
      "task_manager_browser",
    ),
    [
      [
        "ID-MANAGER-MANAGER",
        "billing_manager",
        "task_manager_browser",
        "task_manager_browser",
      ],
    ],
  ],
  ["manager to client", lib("billing_manager", "web_client"), [
    ["ID-MANAGER-CLIENT", "billing_manager", "web_client", "web_client"],
  ]],
  ["engine to engine", lib("tax_engine", "pricing_engine_contract"), [
    [
      "ID-ENGINE-ENGINE",
      "tax_engine",
      "pricing_engine_contract",
      "pricing_engine_contract",
    ],
  ]],
  ["engine to manager", lib("tax_engine", "task_manager_contract"), [
    [
      "ID-ENGINE-MANAGER",
      "tax_engine",
      "task_manager_contract",
      "task_manager_contract",
    ],
  ]],
  ["engine to client", lib("tax_engine", "web_client"), [
    ["ID-ENGINE-CLIENT", "tax_engine", "web_client", "web_client"],
  ]],
  ["access to access", lib("ledger_access", "task_access_contract"), [
    [
      "ID-ACCESS-ACCESS",
      "ledger_access",
      "task_access_contract",
      "task_access_contract",
    ],
  ]],
  [
    "access calls up",
    lib(
      "ledger_access",
      "task_manager_contract pricing_engine_contract",
    ),
    [
      [
        "ID-ACCESS-OUTBOUND",
        "ledger_access",
        "task_manager_contract",
        "task_manager_contract",
      ],
      [
        "ID-ACCESS-OUTBOUND",
        "ledger_access",
        "pricing_engine_contract",
        "pricing_engine_contract",
      ],
    ],
  ],
  ["access to client", lib("ledger_access", "web_client"), [
    ["ID-ACCESS-CLIENT", "ledger_access", "web_client", "web_client"],
  ]],
  [
    "utility to business",
    lib(
      "formatting",
      "task_access_contract web_client",
    ),
    [
      [
        "ID-UTILITY-BUSINESS",
        "formatting",
        "task_access_contract",
        "task_access_contract",
      ],
      ["ID-UTILITY-BUSINESS", "formatting", "web_client", "web_client"],
    ],
  ],
  [
    "implementation of another service",
    lib(
      "billing_manager",
      "task_access task_manager_spec task_manager_wire",
    ),
    [
      ["IMPL-CROSS-SERVICE", "billing_manager", "task_access", "task_access"],
      [
        "IMPL-CROSS-SERVICE",
        "billing_manager",
        "task_manager_spec",
        "task_manager_spec",
      ],
      [
        "IMPL-CROSS-SERVICE",
        "billing_manager",
        "task_manager_wire",
        "task_manager_wire",
      ],
    ],
  ],
  [
    "service-to-service implementation",
    lib(
      "order_manager_spec",
      "order_manager_contract",
    ) +
    lib("order_manager_wire", "order_manager pricing_engine_contract clock"),
    [
      ["CONTRACT-LEAK", "order_manager_wire", "order_manager", "order_manager"],
      [
        "CONTRACT-LEAK",
        "order_manager_wire",
        "pricing_engine_contract",
        "pricing_engine_contract",
      ],
    ],
  ],
  [
    "facet and family allowed for a manager",
    lib(
      "billing_manager",
      "task_access_api pricing_engine_contract clock",
    ),
    [],
  ],
  ["framework outside root", lib("formatting", "well.core well.cli"), [
    ["FRAMEWORK-BOUNDARY", "formatting", "well.core", "well.core"],
    ["FRAMEWORK-BOUNDARY", "formatting", "well.cli", "well.cli"],
  ]],
  ["resource outside access", lib("tax_engine", "sqlite3", "well.ppx"), [
    ["RESOURCE-BOUNDARY", "tax_engine", "sqlite3", "sqlite3"],
    ["RESOURCE-BOUNDARY", "tax_engine", "well.ppx", "well.ppx"],
  ]],
  ["publish outside manager", lib("ledger_access", "well.publish"), [
    ["EVT-PUBLISH-ROLE", "ledger_access", "well.publish", "well.publish"],
  ]],
  ["subscribe outside manager or client", lib("tax_engine", "well.subscribe"), [
    ["EVT-SUBSCRIBE-ROLE", "tax_engine", "well.subscribe", "well.subscribe"],
  ]],
  [
    "presentation outside client",
    lib(
      "billing_manager",
      "well.html well.http",
    ),
    [
      ["PRESENTATION-BOUNDARY", "billing_manager", "well.html", "well.html"],
      ["PRESENTATION-BOUNDARY", "billing_manager", "well.http", "well.http"],
    ],
  ],
  [
    "re_export outside the contract family",
    lib(
      "formatting",
      "(re_export clock) (re_export yojson)",
    ),
    [
      ["DUNE-REEXPORT", "formatting", "clock", "clock"],
      ["DUNE-REEXPORT", "formatting", "yojson", "yojson"],
    ],
  ],
  [
    "contract re_exports a business component",
    lib(
      "order_manager_wire",
      "(re_export task_access_contract) (re_export well.core)",
    ),
    [
      [
        "DUNE-REEXPORT",
        "order_manager_wire",
        "task_access_contract",
        "task_access_contract",
      ],
      [
        "CONTRACT-LEAK",
        "order_manager_wire",
        "task_access_contract",
        "task_access_contract",
      ],
      ["DUNE-REEXPORT", "order_manager_wire", "well.core", "well.core"],
    ],
  ],
  [
    "virtual libraries",
    `(library
 (name clock_virtual)
 (virtual_modules clock_impl))

(library
 (name clock_unix)
 (implements clock_virtual))

(library
 (name clock_default)
 (default_implementation clock_unix))
`,
    [
      [
        "DUNE-UNSUPPORTED",
        "clock_virtual",
        "virtual_modules",
        "virtual_modules",
      ],
      ["DUNE-UNSUPPORTED", "clock_unix", "implements", "implements"],
      [
        "DUNE-UNSUPPORTED",
        "clock_default",
        "default_implementation",
        "default_implementation",
      ],
    ],
  ],
  [
    "copy_files from outside the directory",
    `(copy_files ../task_access/*.ml)

(copy_files#
 (files /tmp/elsewhere/*.ml))

(copy_files local/*.ml)
`,
    [
      ["DUNE-UNSUPPORTED", "lib/mutation", "copy_files", "../task_access/*.ml"],
      [
        "DUNE-UNSUPPORTED",
        "lib/mutation",
        "copy_files#",
        "/tmp/elsewhere/*.ml",
      ],
    ],
  ],
  [
    "composition-root libraries link everything; only roots and tests use them",
    `(library
 (name task_manager_root)
 (libraries well.core well.cli task_manager task_manager_spec task_manager_wire
  task_access sqlite3 web_client))

(library
 (name app_root)
 (libraries task_manager_root pricing_engine))

(executable
 (name server)
 (libraries app_root))

(test
 (name test_root)
 (libraries task_manager_root))

(library
 (name formatting)
 (libraries app_root))

(library
 (name billing_manager)
 (libraries task_manager_root))
`,
    [
      ["ROOT-LEAK", "formatting", "app_root", "app_root", 3],
      [
        "ROOT-LEAK",
        "billing_manager",
        "task_manager_root",
        "task_manager_root",
        4,
      ],
    ],
  ],
  [
    "several libraries partition one directory with (modules)",
    `(library
 (name billing_manager)
 (modules :standard \\ impl)
 (libraries order_manager_contract))

(library
 (name billing_impl_engine)
 (modules impl)
 (libraries pricing_engine_contract))
`,
    [
      [
        "ID-MANAGER-MANAGER",
        "billing_manager",
        "order_manager_contract",
        "order_manager_contract",
      ],
      [
        "ID-ENGINE-ENGINE",
        "billing_impl_engine",
        "pricing_engine_contract",
        "pricing_engine_contract",
      ],
    ],
  ],
  [
    "roots and tests are exempt from role rules",
    `(executable
 (name tool)
 (libraries well.core sqlite3 task_access well.html))

(test
 (name test_more)
 (libraries task_manager task_access_contract well.publish))
`,
    [],
  ],
];

function lib(name: string, libraries: string, pps?: string) {
  return `(library
 (name ${name})
 (libraries ${libraries})${pps ? `\n (preprocess\n  (pps ${pps}))` : ""})

`;
}

for (const [label, text, expected] of cases) {
  Deno.test(`rule: ${label}`, async () => {
    const root = await copy("conforming");
    try {
      await Deno.mkdir(`${root}/lib/mutation`);
      await Deno.writeTextFile(`${root}/lib/mutation/dune`, text);
      const { code, json } = await report(root);
      const got = json.findings.map((f) =>
        [
          f.rule,
          f.from.name,
          f.to.name,
          f.location.path,
          f.location.line,
          f.location.col,
        ].join(" ")
      ).sort();
      const want = expected.map(([rule, from, to, atom, n]) => {
        const p = position(text, atom, n ?? 1);
        return [rule, from, to, "lib/mutation/dune", p.line, p.col].join(" ");
      }).sort();
      assert(
        JSON.stringify(got) === JSON.stringify(want),
        `${label}\n got:\n${got.join("\n")}\n want:\n${want.join("\n")}`,
      );
      assert(code === (want.length ? 1 : 0), `exit ${code}`);
      for (const f of json.findings) {
        assert(f.coaching.length > 80, `${f.rule}: missing coaching`);
      }
    } finally {
      await Deno.remove(root, { recursive: true });
    }
  });
}

Deno.test("rule: DUNE-TRANSITIVE missing, disabled or too old", async () => {
  for (
    const [project, needle] of [
      ["(lang dune 3.17)\n", "3.17"],
      ["(lang dune 3.17)\n(implicit_transitive_deps true)\n", "true"],
      ["(lang dune 3.16)\n(implicit_transitive_deps false)\n", "3.16"],
    ]
  ) {
    const root = await copy("conforming");
    try {
      await Deno.writeTextFile(`${root}/dune-project`, project);
      const { code, json } = await report(root);
      const p = position(project, needle);
      assert(
        code === 1 && json.findings.length === 1 &&
          json.findings[0].rule === "DUNE-TRANSITIVE" &&
          json.findings[0].location.path === "dune-project" &&
          json.findings[0].location.line === p.line &&
          json.findings[0].location.col === p.col,
        `${project}: ${JSON.stringify(json.findings)}`,
      );
      const text = await check(root);
      assert(
        text.code === 1 && text.stdout.includes("DUNE-TRANSITIVE (1)") &&
          text.stdout.includes("How to fix:"),
        text.stdout,
      );
    } finally {
      await Deno.remove(root, { recursive: true });
    }
  }
});

Deno.test("unparseable dune files and missing projects exit 2", async () => {
  for (
    const [file, text, line, col] of [
      ["lib/broken/dune", "(library\n (name broken)\n", 1, 1],
      ["lib/broken/dune", '(library\n (name "broken))\n', 2, 8],
      ["lib/broken/dune", "(library (name a))\n#| never closed\n", 2, 1],
      ["lib/broken/dune", "(library (name a)))\n", 1, 19],
      ["dune-project", "(lang dune 3.17\n", 1, 1],
    ] as const
  ) {
    const root = await copy("conforming");
    try {
      await Deno.mkdir(`${root}/lib/broken`, { recursive: true });
      await Deno.writeTextFile(`${root}/${file}`, text);
      const r = await check(root, "--json");
      assert(r.code === 2, `${text}: exit ${r.code}`);
      assert(r.stdout === "", "no report on a parse error");
      assert(
        r.stderr.includes(`${file}:${line}:${col}:`),
        `${text}: ${r.stderr}`,
      );
    } finally {
      await Deno.remove(root, { recursive: true });
    }
  }
  const empty = await Deno.makeTempDir({ prefix: "szaniec-check-empty-" });
  try {
    const r = await check(empty);
    assert(r.code === 2 && r.stderr.includes("dune-project"), r.stderr);
    const missing = await check(`${empty}/missing`);
    assert(missing.code === 2, "missing directory");
    const usage = await check(empty, "--bogus");
    assert(usage.code === 2, "unknown flag");
  } finally {
    await Deno.remove(empty, { recursive: true });
  }
});

Deno.test("check never reads _build", async () => {
  const root = await copy("conforming");
  try {
    await Deno.mkdir(`${root}/_build/default/lib`, { recursive: true });
    await Deno.writeTextFile(`${root}/_build/default/lib/dune`, "((((");
    await Deno.writeTextFile(
      `${root}/_build/default/Rogue.cyrograf`,
      "rpc x(A) -> B\n",
    );
    const { code, json } = await report(root);
    assert(code === 0 && json.services.length === 5, "read _build");
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});

Deno.test("every catalog rule is exercised and documented verbatim", async () => {
  const doc = await Deno.readTextFile(
    new URL("../../docs/contracts/rule-catalog.md", import.meta.url),
  );
  const documented = [...doc.matchAll(/^### ([A-Z-]+)$/gm)].map((m) => m[1]);
  assert(documented.length === 23, `documented rules ${documented.length}`);
  for (const rule of documented) {
    const text = coaching.get(rule);
    assert(text, `${rule} is never reported by the tests`);
    assert(doc.includes(`> ${text}\n`), `${rule}: coaching differs from doc`);
  }
  assert(
    [...coaching.keys()].every((rule) => documented.includes(rule)),
    "undocumented rule reported",
  );
});
