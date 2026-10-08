/** Link the complete local CLI bundle into the user's executable directory. */
const home = Deno.env.get("HOME");
if (!home) throw new Error("HOME must be set to install Szaniec.");

const launcher = await Deno.realPath(
  new URL("../_release/szaniec", import.meta.url),
);
const bin = `${home}/.local/bin`;
const destination = `${bin}/szaniec`;
await Deno.mkdir(bin, { recursive: true });

try {
  const existing = await Deno.lstat(destination);
  if (!existing.isSymlink) {
    throw new Error(
      `Refusing to replace ${destination}: it is not a symbolic link.`,
    );
  }
} catch (error) {
  if (!(error instanceof Deno.errors.NotFound)) throw error;
}

// Rename a prepared link so reinstalling never leaves the command missing.
const temporary = await Deno.makeTempDir({ dir: bin, prefix: ".szaniec-" });
try {
  const link = `${temporary}/szaniec`;
  await Deno.symlink(launcher, link);
  await Deno.rename(link, destination);
} finally {
  await Deno.remove(temporary, { recursive: true });
}
console.log(`Installed ${destination} -> ${launcher}`);
