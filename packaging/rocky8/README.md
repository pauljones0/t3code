# T3 Code backend on Rocky Linux 8.10

Builds the `t3` backend (server bundle + web client + native externals) into a
`rockylinux:8.10`-based image and verifies it boots and serves there.

Upstream commit: see `git log` on the `rocky8-backend` branch (forked from
`pingdotgg/t3code` `main`).

## Why a special build?

Rocky 8.10 ships glibc 2.28 and GCC 8.5, which breaks two native pieces of the
stock backend:

| Piece | Stock behavior on Rocky 8.10 | Fix in this image |
|---|---|---|
| `node-pty` | Ships no Linux prebuilds; compiling against Node 24 headers needs C++20, GCC 8.5 fails | Compile in-image with `gcc-toolset-13`; ship its `libstdc++` (`gcc-toolset-13-runtime` + `LD_LIBRARY_PATH`) |
| `libfff_c.so` (`@ff-labs/fff-bin-linux-x64-gnu`) | Prebuilt for glibc ≥ 2.31 → `GLIBC_2.29/2.30 not found` on dlopen | Rebuild from the exact tagged source (`v0.9.4`) with Rust 1.90 in the Rocky 8.10 builder |
| Node itself | AppStream maxes at Node 24.11.x, below the repo engines floor (`^24.13.1`) | Official `nodejs.org` linux-x64 tarball (verified working on glibc 2.28) |

Everything else (including `node:sqlite`, which the server uses for state, and
the `ffi-rs` napi binding) already runs on Rocky 8.10 unmodified.

## Build

From the repo root:

```bash
docker build -f packaging/rocky8/Dockerfile -t t3-rocky8:local .
```

The default target is `selftest`: the build itself boots the server and runs
the smoke test below, failing if anything is broken. To skip that (layers are
cached, so it is cheap either way):

```bash
docker build -f packaging/rocky8/Dockerfile --target runtime -t t3-rocky8:local .
```

Build args (defaults in the Dockerfile): `ROCKY_VERSION=8.10`,
`NODE_VERSION=24.21.0`, `RUST_TOOLCHAIN=1.90.0`, `ZIG_VERSION=0.16.0`,
`FFF_TAG=v0.9.4`.

## Run

```bash
docker run --rm -p 3773:3773 -v t3data:/data t3-rocky8:local
```

This serves headless on `0.0.0.0:3773` with `T3CODE_HOME=/data` (a named volume,
so `state.sqlite` and credentials persist). Open `http://localhost:3773`.

Other CLI usage (same image, override the command):

```bash
docker run --rm t3-rocky8:local --help
docker run --rm t3-rocky8:local --version
docker run --rm -v t3data:/data t3-rocky8:local serve --host 0.0.0.0 --port 3773 --base-dir /data
```

## Verify

`packaging/rocky8/scripts/smoke-test.sh` is the acceptance check. It asserts:

1. `dist/bin.mjs`, `dist/client/index.html`, and the native externals exist.
2. `t3 --version` / `--help` exit 0.
3. `node-pty` spawns a process.
4. `FileFinder` (rebuilt `libfff_c.so` via `ffi-rs`) indexes and searches a temp dir.
5. `t3 serve` boots, serves the web client (`GET /` → HTML), and auth-gates
   the RPC socket (`GET /ws` → 4xx).
6. `state.sqlite` is created (proves `node:sqlite` migrations ran).

Run it against a running container (it boots a second server on `SMOKE_PORT`,
so pick a free port inside the container):

```bash
docker run -d --name t3smoke -p 3774:3773 -v t3data:/data t3-rocky8:local
docker cp packaging/rocky8/scripts/smoke-test.sh t3smoke:/tmp/smoke.sh
docker exec -e SMOKE_PORT=3775 -e T3CODE_HOME=/tmp/smokehome t3smoke bash /tmp/smoke.sh
```

(The default `docker build` already runs this script in its `selftest` stage.)

## Bare-metal Rocky 8.10 install (no Docker)

Extract the tested `/app` tree plus a Node runtime onto a Rocky 8.10 host:

```bash
# on the host with docker:
id="$(docker create t3-rocky8:local)"
mkdir -p t3-rocky8-app && docker cp "$id:/app" t3-rocky8-app/app
docker cp "$id:/usr/local" t3-rocky8-app/node
docker rm "$id"
tar -czf t3-rocky8-linux-x64.tar.gz -C t3-rocky8-app .

# on the Rocky 8.10 host:
sudo dnf install -y git openssh-clients ca-certificates gcc-toolset-13-runtime
sudo mkdir -p /opt/t3 && sudo tar -xzf t3-rocky8-linux-x64.tar.gz -C /opt/t3
export PATH=/opt/t3/node/bin:$PATH
export LD_LIBRARY_PATH=/opt/rh/gcc-toolset-13/root/usr/lib64
/opt/t3/node/bin/node /opt/t3/app/dist/bin.mjs serve --host 0.0.0.0 --port 3773
```

A prebuilt `t3-rocky8-linux-x64.tar.gz` may also be attached to the fork's
GitHub releases (see below).

## Staying up to date (automated releases)

Releases are built by CI. To ship a new backend, rebase the packaging onto the
latest upstream and push a tag — the
[`rocky8-backend-release`](../../.github/workflows/rocky8-backend-release.yml)
workflow builds the image, runs the selftest, pushes to GHCR, and attaches the
bare-metal tarball to the release. No local Docker needed.

```bash
git fetch origin                        # upstream pingdotgg/t3code
git checkout rocky8-backend
git rebase origin/main                  # our commit is packaging-only; usually clean
git push fork rocky8-backend --force-with-lease
git tag rocky8-v0.0.43 && git push fork rocky8-v0.0.43
```

Tag convention: `rocky8-v<VERSION>[-N]`, where `VERSION` matches
`apps/server/package.json` and `-N` disambiguates rebuilds of the same backend
version (packaging fixes, base-image refreshes). Watch the run under the fork's
Actions tab; a red build creates no release.

Published artifacts per tag:

- Image: `ghcr.io/pauljones0/t3code-rocky8:<tag>` (and `:latest`)
- Tarball: `t3-rocky8-linux-x64.tar.gz` on the release page

To verify CI without cutting a release, use Actions → `rocky8-backend-release`
→ Run workflow: it builds, self-tests, and uploads the tarball as a run
artifact instead.

## Files

- `Dockerfile` — multi-stage `rockylinux:8.10` build (`node-base`, `build`,
  `runtime`, `selftest`).
- `scripts/build-fff.sh` — rebuilds `libfff_c.so` from tagged source; hard-fails
  unless `ldd` resolves on glibc 2.28.
- `scripts/stage-runtime-externals.mjs` — installs only the native externals at
  the lockfile-pinned versions, applies the repo's `fff-node` patch (the
  `require` export the server loader needs), and swaps in the rebuilt `.so`.
- `scripts/smoke-test.sh` — acceptance check (also the `selftest` stage).
- `.github/workflows/rocky8-backend-release.yml` — tag-driven CI: build,
  selftest, GHCR push, release tarball.

## Source / fork

Fork: `https://github.com/pauljones0/t3code` (branch `rocky8-backend`),
based on upstream `https://github.com/pingdotgg/t3code`.
