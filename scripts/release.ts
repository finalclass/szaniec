/** Package Well's Linux bundle for use as a CLI from any project directory. */
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function run(command: string, args: string[], cwd?: string) {
  const result = await new Deno.Command(command, { args, cwd }).output();
  if (!result.success) {
    throw new Error(
      `${command} exited ${result.code}: ${decoder.decode(result.stderr)}`,
    );
  }
  return decoder.decode(result.stdout).trim();
}

const version = Deno.args[0] ?? "dev";
if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(version)) {
  throw new Error(
    "Version/tag must contain only letters, digits, '.', '_' or '-'.",
  );
}
if (Deno.build.os !== "linux") {
  throw new Error("Linux packaging requires Linux.");
}
const arch = { x86_64: "x86_64", aarch64: "aarch64" }[Deno.build.arch];
if (!arch) throw new Error(`Unsupported architecture: ${Deno.build.arch}`);

const build = await new Deno.Command("well", {
  args: ["build"],
  stdout: "inherit",
  stderr: "inherit",
}).spawn().status;
if (!build.success) throw new Error(`well build exited ${build.code}`);

const bundle = await Deno.realPath("_release");
const binary = `${bundle}/bin/szaniec`;
const interpreter = await run("patchelf", ["--print-interpreter", binary]);
if (!/^bin\/lib\/ld[^/]+$/.test(interpreter)) {
  throw new Error(`Unexpected Well interpreter: ${interpreter}`);
}
await Deno.stat(`${bundle}/${interpreter}`);
const rpath = await run("patchelf", ["--print-rpath", binary]);
if (rpath !== "$ORIGIN/lib") throw new Error(`Unexpected Well rpath: ${rpath}`);
const needed = await run("patchelf", ["--print-needed", binary]);
for (const library of needed.split("\n").filter(Boolean)) {
  await Deno.stat(`${bundle}/bin/lib/${library}`);
}
const dependencies = await run("ldd", [binary]);
if (dependencies.includes("not found")) throw new Error(dependencies);

// POSIX sh is the Linux runtime launcher, not a build-time scripting dependency.
// Explicit loader invocation preserves the application's working directory.
// --argv0 keeps coverage's nested supervise launches on this same launcher.
await Deno.writeTextFile(
  `${bundle}/szaniec`,
  `#!/bin/sh
set -eu
bundle=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
exec "$bundle/${interpreter}" --library-path "$bundle/bin/lib" \\
  --argv0 "$bundle/szaniec" "$bundle/bin/szaniec" "$@"
`,
);
await Deno.chmod(`${bundle}/szaniec`, 0o755);
await Deno.copyFile("README.md", `${bundle}/README.md`);

// Exercise the extracted bundle from an unrelated cwd, including a path with
// spaces and a PATH-style symlink. No source/toolchain paths may be required.
const scratch = await Deno.makeTempDir({ prefix: "szaniec-release-" });
try {
  const relocated = `${scratch}/relocated bundle`;
  await Deno.mkdir(relocated);
  await run("cp", ["-a", `${bundle}/.`, relocated]);
  const project = `${scratch}/application`;
  await Deno.mkdir(project);
  await Deno.mkdir(`${project}/lib`);
  await Deno.writeTextFile(`${project}/dune-project`, "(lang dune 3.17)\n");
  await Deno.writeTextFile(
    `${project}/szaniec.toml`,
    `format = "szaniec-config/1"
[policy]
name = "release-smoke"
roots = ["lib"]
`,
  );
  await Deno.symlink(`${relocated}/szaniec`, `${scratch}/szaniec`);
  const nested = `${project}/lib`;
  await run(`${scratch}/szaniec`, ["approve"], nested);
  const report = JSON.parse(
    await run(`${scratch}/szaniec`, [
      "check",
      "--json",
      "--no-callgraph",
    ], nested),
  );
  if (
    report.inputs.policy.name !== "release-smoke" ||
    report.inputs.policy.approved !== true ||
    !/^sha256:[a-f0-9]{64}$/.test(report.inputs.policy.approvedDigest)
  ) {
    throw new Error("Relocated bundle did not record a valid TOML approval.");
  }
} finally {
  await Deno.remove(scratch, { recursive: true });
}

await Deno.mkdir("dist", { recursive: true });
const archive = `szaniec-${version}-linux-${arch}.tar.gz`;
await run("tar", ["czf", `dist/${archive}`, "-C", bundle, "."]);
const digest = await crypto.subtle.digest(
  "SHA-256",
  await Deno.readFile(`dist/${archive}`),
);
const hex = [...new Uint8Array(digest)].map((n) =>
  n.toString(16).padStart(2, "0")
).join("");
await Deno.writeFile(
  `dist/${archive}.sha256`,
  encoder.encode(`${hex}  ${archive}\n`),
);
console.log(`Created dist/${archive} and dist/${archive}.sha256`);
