# syntax=docker/dockerfile:1
# T3 Code backend (t3 server + web client) built and runnable on Rocky Linux 8.10.
#
# Why this exists: the stock backend has two blockers on Rocky 8.10 (glibc 2.28):
#   1. node-pty ships no Linux prebuilds, so it compiles from source. Node 24
#      headers need a C++20-capable compiler, but Rocky 8 ships GCC 8.5.
#      Fixed with gcc-toolset-13 in the builder (+ its libstdc++ at runtime).
#   2. @ff-labs/fff-bin-linux-x64-gnu targets glibc >= 2.31 and cannot dlopen
#      on 2.28. Fixed by rebuilding libfff_c.so from the exact tagged source
#      (v0.9.4) with Rust 1.90 inside this same Rocky 8.10 builder.
#
# Build (context = repo root):
#   docker build -f packaging/rocky8/Dockerfile -t t3-rocky8:local .
# Run:
#   docker run --rm -p 3773:3773 -v t3data:/data t3-rocky8:local
#
# The default CMD serves headless on 0.0.0.0:3773 with T3CODE_HOME=/data.
# Override for other CLI usage, e.g.:
#   docker run --rm t3-rocky8:local --help
#   docker run --rm -v t3data:/data t3-rocky8:local pair --help

ARG ROCKY_VERSION=8.10
ARG NODE_VERSION=24.21.0
ARG RUST_TOOLCHAIN=1.90.0
ARG ZIG_VERSION=0.16.0

# ---------------------------------------------------------------------------
# Stage: node-base — Rocky 8.10 + upstream Node (shared by build and runtime).
# Rocky AppStream's nodejs:24 module (24.11.x) is older than the repo's
# engines floor (^24.13.1), so Node comes from nodejs.org. The official
# linux-x64 tarball runs fine on glibc 2.28 (verified).
# ---------------------------------------------------------------------------
FROM rockylinux/rockylinux:${ROCKY_VERSION} AS node-base
ARG NODE_VERSION
RUN dnf install -y curl tar xz gzip ca-certificates \
  && dnf clean all \
  && rm -rf /var/cache/dnf
RUN curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
  && tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 \
  && rm "node-v${NODE_VERSION}-linux-x64.tar.xz" \
  && node --version \
  && npm --version \
  && node -e "const s=require('node:sqlite');new s.DatabaseSync(':memory:').exec('CREATE TABLE t(a)');console.log('node:sqlite ok')"

# ---------------------------------------------------------------------------
# Stage: build — full monorepo install + backend bundle, all on Rocky 8.10.
# ---------------------------------------------------------------------------
FROM node-base AS build
ARG RUST_TOOLCHAIN
ARG ZIG_VERSION

# git: fff source checkout. python3.11: node-gyp (Rocky default 3.6 too old).
# gcc-toolset-13: C++20 compiler for node-pty against Node 24 headers.
# cmake/make/pkg-config/perl: fff's vendored libgit2 C build.
# clang-devel: libclang for zlob's bindgen step. patch: apply the repo's
# fff-node patch to the staged runtime externals.
RUN dnf install -y \
  git python3.11 cmake make pkg-config perl clang-devel patch \
  gcc-toolset-13-gcc gcc-toolset-13-gcc-c++ gcc-toolset-13-libstdc++-devel \
  && dnf clean all \
  && rm -rf /var/cache/dnf \
  && ln -sf /usr/bin/python3.11 /usr/local/bin/python3 \
  && python3 --version

# Toolset first on PATH so cc/gcc/g++ resolve to GCC 13 (node-gyp, cmake).
ENV PATH="/opt/rh/gcc-toolset-13/root/usr/bin:/usr/local/bin:/usr/bin:/bin" \
  CC=/opt/rh/gcc-toolset-13/root/usr/bin/gcc \
  CXX=/opt/rh/gcc-toolset-13/root/usr/bin/g++ \
  npm_config_python=/usr/bin/python3.11

# Rust 1.90: newest toolchain whose std still links against glibc 2.28.
# (Rust 1.91+ requires glibc >= 2.31; see fff's release.yaml comment.)
# Used ONLY to rebuild libfff_c.so; the JS build does not need it.
ENV RUSTUP_HOME=/opt/rustup \
  CARGO_HOME=/opt/cargo
ENV PATH="/opt/cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
  && sh /tmp/rustup.sh -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
  && rm /tmp/rustup.sh \
  && rustc --version \
  && cargo --version

# Zig (same version as fff's official release): zlob compiles its SIMD core
# from Zig sources at build time.
RUN curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
  && tar -xJf "zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -C /opt \
  && ln -sf "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
  && rm "zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
  && zig version

# pnpm pinned to the repo's packageManager field.
RUN corepack enable \
  && corepack prepare pnpm@11.10.0 --activate \
  && pnpm --version

WORKDIR /src
COPY . .
# Frozen install (runs `prepare`: effect-tsgo patch + local `vp config`).
RUN pnpm install --frozen-lockfile
# Backend bundle. t3#build depends on @t3tools/web#build, so this also builds
# the web app and copies it into apps/server/dist/client.
RUN ./node_modules/.bin/vp run --filter t3 build
RUN test -f apps/server/dist/bin.mjs && test -f apps/server/dist/client/index.html \
  && echo "server bundle + web client present"

# Rebuild the one native library that cannot run on glibc 2.28, from the exact
# tagged source matching the repo's pinned @ff-labs/fff-node. The tag is
# derived from the pin (never hardcoded) so version bumps can't silently drift.
RUN packaging/rocky8/scripts/build-fff.sh --tag "v$(node -p 'require("/src/apps/server/package.json").dependencies["@ff-labs/fff-node"]')" --out /opt/fff/libfff_c.so

# Stage the runtime node_modules: only the native externals the bundle keeps
# external (node-pty, fff-node, ffi-rs + platform bindings), with the rebuilt
# libfff_c.so swapped in.
RUN node packaging/rocky8/scripts/stage-runtime-externals.mjs \
  --repo /src --fff-so /opt/fff/libfff_c.so --out /opt/t3stage

# ---------------------------------------------------------------------------
# Stage: runtime — minimal Rocky 8.10 + Node + backend.
# ---------------------------------------------------------------------------
FROM rockylinux/rockylinux:${ROCKY_VERSION} AS runtime
# git: checkpoints/worktrees shell out to it. openssh-clients: git+ssh remotes.
# gcc-toolset-13-runtime: newer libstdc++ for the GCC-13-built pty.node.
RUN dnf install -y git openssh-clients ca-certificates gcc-toolset-13-runtime \
  && dnf clean all \
  && rm -rf /var/cache/dnf
COPY --from=node-base /usr/local /usr/local
ENV LD_LIBRARY_PATH=/opt/rh/gcc-toolset-13/root/usr/lib64
COPY --from=build /src/apps/server/dist /app/dist
COPY --from=build /opt/t3stage/node_modules /app/node_modules
RUN ln -sf /app/dist/bin.mjs /usr/local/bin/t3 \
  && chmod +x /app/dist/bin.mjs \
  && node --version \
  && node -e "require('/app/node_modules/node-pty');console.log('pty.node loads')" \
  && node -e "require('/app/node_modules/@napi-rs/keyring');console.log('keyring loads')" \
  && ldd /app/node_modules/@ff-labs/fff-bin-linux-x64-gnu/libfff_c.so
WORKDIR /app
EXPOSE 3773
ENV NODE_ENV=production \
  T3CODE_HOME=/data
VOLUME /data
ENTRYPOINT ["node", "dist/bin.mjs"]
CMD ["serve", "--host", "0.0.0.0", "--port", "3773"]

# ---------------------------------------------------------------------------
# Stage: selftest — boot the backend and exercise it (runs during docker build
# when targeted: docker build -f packaging/rocky8/Dockerfile --target selftest .).
# ---------------------------------------------------------------------------
FROM runtime AS selftest
COPY packaging/rocky8/scripts/smoke-test.sh /tmp/smoke-test.sh
ENV SMOKE_PORT=3773
RUN /tmp/smoke-test.sh
