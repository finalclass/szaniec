/** Compare real CC inventories without changing the application or its scope. */
function option(name: string, fallback?: string) {
  const index = Deno.args.indexOf(name);
  const value = index < 0 ? fallback : Deno.args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`Missing ${name}`);
  return value;
}

const baseline = await Deno.realPath(option("--baseline"));
const candidate = await Deno.realPath(option("--candidate"));
const project = await Deno.realPath(option("--project-root"));
const samples = Number(option("--samples", "3"));
const cache = option("--cache", "on");
if (
  !Number.isInteger(samples) || samples < 1 || !["on", "off"].includes(cache)
) {
  throw new Error("Use positive --samples and --cache on|off");
}

const results: { version: string; seconds: number; code: number }[] = [];
let expected: string | undefined;
let inventory: unknown;
for (let sample = 0; sample < samples; sample++) {
  // Alternate order to avoid assigning all background load to one version.
  const pair: [string, string][] = sample % 2
    ? [["candidate", candidate], ["baseline", baseline]]
    : [["baseline", baseline], ["candidate", candidate]];
  for (const [version, executable] of pair) {
    const started = performance.now();
    const result = await new Deno.Command(executable, {
      args: ["complexity", "--sort", "complexity", "--json"],
      cwd: project,
      env: { SZANIEC_OBSERVATION_CACHE: cache },
    }).output();
    const seconds = (performance.now() - started) / 1000;
    if (![0, 2].includes(result.code)) {
      throw new Error(new TextDecoder().decode(result.stderr));
    }
    const digest = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", result.stdout)),
      (byte) => byte.toString(16).padStart(2, "0"),
    ).join("");
    const identity = `${result.code}:${digest}`;
    expected ??= identity;
    if (identity !== expected) {
      throw new Error(`${version}: report or exit status changed`);
    }
    inventory ??= JSON.parse(new TextDecoder().decode(result.stdout)).summary;
    results.push({ version, seconds, code: result.code });
    console.log(
      JSON.stringify({ sample: sample + 1, version, seconds, digest }),
    );
  }
}
function median(version: string) {
  const values = results.filter((r) => r.version === version)
    .map((r) => r.seconds).sort((a, b) => a - b);
  const mid = Math.floor(values.length / 2);
  return values.length % 2 ? values[mid] : (values[mid - 1] + values[mid]) / 2;
}
console.log(JSON.stringify({
  cache,
  samples,
  inventory,
  reportIdentity: expected,
  baselineMedian: median("baseline"),
  candidateMedian: median("candidate"),
  speedup: median("baseline") / median("candidate"),
  candidateBelow15Seconds: median("candidate") < 15,
}));
