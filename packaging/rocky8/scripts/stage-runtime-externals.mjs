#!/usr/bin/env node
// Stage the runtime node_modules for the Rocky 8 backend image.
//
// The server bundle (dist/bin.mjs) inlines everything EXCEPT the native
// packages it must load from disk (see scripts/lib/cli-external-packages.ts):
// node-pty and @ff-labs/fff-node (+ their transitive deps: ffi-rs and the
// @yuuang napi binding). This script installs exactly those into a clean,
// hoisted node_modules tree and swaps in the Rocky-compatible libfff_c.so.
//
// Versions are read from the workspace install (frozen lockfile), so the
// stage always matches the build. node-pty compiles here with the container
// toolchain (it ships no Linux prebuilds).
//
// Usage:
//   node stage-runtime-externals.mjs --repo /src --fff-so /opt/fff/libfff_c.so --out /opt/t3stage

import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

function arg(name) {
  const i = process.argv.indexOf(name);
  if (i === -1 || i + 1 >= process.argv.length) {
    console.error(`missing ${name}`);
    process.exit(2);
  }
  return process.argv[i + 1];
}

const repo = arg("--repo");
const fffSo = arg("--fff-so");
const out = arg("--out");

// Resolve versions from the frozen workspace install via Node's own
// resolution (layout-agnostic: works with pnpm's isolated store, where
// transitive deps like ffi-rs are NOT under apps/server/node_modules).
const serverRequire = createRequire(join(repo, "apps/server/package.json"));

function packageDirFor(requireFn, name) {
  let dir = dirname(realpathSync(requireFn.resolve(name)));
  for (let i = 0; i < 10; i++) {
    if (existsSync(join(dir, "package.json"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(`cannot locate package dir for ${name}`);
}

function installedVersion(requireFn, name) {
  const pkgPath = join(packageDirFor(requireFn, name), "package.json");
  return JSON.parse(readFileSync(pkgPath, "utf8")).version;
}

const fffEntry = serverRequire.resolve("@ff-labs/fff-node");
const fffRequire = createRequire(fffEntry);

const versions = {
  "node-pty": installedVersion(serverRequire, "node-pty"),
  "@ff-labs/fff-node": installedVersion(serverRequire, "@ff-labs/fff-node"),
  "@ff-labs/fff-bin-linux-x64-gnu": installedVersion(
    fffRequire,
    "@ff-labs/fff-bin-linux-x64-gnu",
  ),
  // fff-node wants ffi-rs ^1.0.0; pin the locked version instead of latest.
  "ffi-rs": installedVersion(fffRequire, "ffi-rs"),
};
console.log("staging runtime externals at locked versions:", JSON.stringify(versions, null, 2));

mkdirSync(out, { recursive: true });
writeFileSync(
  join(out, "package.json"),
  `${JSON.stringify({ name: "t3-rocky8-runtime", private: true, dependencies: versions }, null, 2)}\n`,
);

execFileSync("npm", ["install", "--omit=dev", "--no-audit", "--no-fund"], {
  cwd: out,
  stdio: "inherit",
  env: process.env, // inherits CC/CXX/npm_config_python for the node-pty build
});

const nm = join(out, "node_modules");

// Apply the repo's fff-node patch (adds the "require" export the server's
// createRequire loader needs, plus the asar path fix). The workspace install
// gets this via pnpm patchedDependencies; the npm stage needs it explicitly.
const fffNodeDir = join(nm, "@ff-labs/fff-node");
const fffPatch = readdirSync(join(repo, "patches"))
  .filter((f) => f.startsWith("@ff-labs__fff-node@") && f.endsWith(".patch"))
  .sort()
  .at(-1);
if (!fffPatch) throw new Error("repo fff-node patch not found under patches/");
execFileSync("patch", ["-p1", "--directory", fffNodeDir, "-i", join(repo, "patches", fffPatch)], {
  stdio: "inherit",
});
console.log(`applied ${fffPatch} to staged fff-node`);

// Swap the stock glibc-2.31+ binary for the Rocky 8 rebuild.
const stockSo = join(nm, "@ff-labs/fff-bin-linux-x64-gnu/libfff_c.so");
if (!existsSync(stockSo)) throw new Error(`expected ${stockSo} missing after npm install`);
cpSync(fffSo, stockSo);
console.log(`replaced ${stockSo} with Rocky 8 rebuild`);

// Prune what the runtime never loads: manifests, shims, and node-pty's
// foreign (darwin/win32) prebuilds — the Linux .node compiles into build/.
for (const entry of [
  "package.json",
  "package-lock.json",
  ".package-lock.json",
  join("node_modules", ".bin"),
  join("node_modules", ".package-lock.json"),
  join("node_modules", "node-pty", "prebuilds"),
]) {
  rmSync(join(out, entry), { recursive: true, force: true });
}

// Gate: the compiled pty binding must exist and load on this system.
const ptyBinding = join(nm, "node-pty", "build", "Release", "pty.node");
if (!existsSync(ptyBinding)) {
  throw new Error(`node-pty did not compile: ${ptyBinding} missing`);
}
createRequire(join(nm, "probe.cjs"))("node-pty");
console.log("node-pty loads from staged tree");
// Same loader the server bundle uses (createRequire of an ESM-only package:
// needs the patched "require" export). Loading must not throw; the native
// library itself opens lazily on FileFinder.create.
createRequire(join(nm, "probe.cjs"))("@ff-labs/fff-node");
console.log("fff-node loads via require() from staged tree");

execFileSync("ldd", [stockSo], { stdio: "inherit" });
console.log(`staged runtime externals in ${nm}`);
