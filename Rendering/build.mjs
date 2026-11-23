import { build } from "esbuild";
import { copyFile, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const output = "RichContent";
const result = await build({
  entryPoints: ["diagram.js", "highlight.js"],
  outdir: output,
  bundle: true,
  minify: true,
  metafile: true,
  target: "safari18",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "linked"
});

await mkdir(output, { recursive: true });
await copyFile("diagram.html", join(output, "diagram.html"));

const packages = new Set();
for (const input of Object.keys(result.metafile.inputs)) {
  for (let folder = dirname(input); folder.includes("node_modules/"); folder = dirname(folder)) {
    if (/node_modules\/(?:@[^/]+\/)?[^/]+$/.test(folder)) {
      packages.add(folder);
      break;
    }
  }
}
const notices = await Promise.all([...packages].sort().map(async folder => {
  const pkg = JSON.parse(await readFile(join(folder, "package.json"), "utf8"));
  const files = (await readdir(folder)).filter(file => /^(licen[cs]e|copying|notice)(\.|$)/i.test(file));
  const licenses = await Promise.all(files.map(file => readFile(join(folder, file), "utf8")));
  return [`${pkg.name} ${pkg.version} (${pkg.license ?? "see upstream"})`, ...licenses].join("\n");
}));
await writeFile(join(output, "ThirdPartyNotices.txt"), notices.join("\n\n-----------------------------------\n\n"));
