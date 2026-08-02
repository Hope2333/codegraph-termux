# codegraph-termux

[colbymchenry/codegraph](https://github.com/colbymchenry/codegraph) — local-first
code intelligence for AI agents (MCP) — running natively on **Termux (Android)**.

This repo is a build/install layer for Termux, in the same spirit as the other
`*-termux` repos in this workspace (codebuff-termux, opencode-termux, ...). The
upstream release bundles its own Node.js runtime (glibc, 121 MB) plus a Rust
kernel; Termux provides **bionic** libc, so two problems must be solved:

1. the bundled glibc `node` binary cannot load on bionic → patched with `patchelf`
2. Android blocks reading `/proc/stat` → Node's `os.cpus()` returns 0 cores
   → fixed with `proot` + fake files

## Status

| Area                | Status |
|---------------------|--------|
| `codegraph --version` | ✅ 1.5.0 |
| `codegraph init`      | ✅ |
| `codegraph index`     | ✅ (incl. spawning bionic `git`) |
| `codegraph status`    | ✅ |
| `codegraph query`     | ✅ |
| `os.cpus()`           | ✅ 8 cores via proot fakes |
| MCP server (daemon)   | ✅ runs through the wrapper |
| Upgrade               | manual — `make runtime VER=<new>` (or re-run `scripts/install.sh <new>`) |

## Quick Start

```bash
cd ~/develop/codegraph-termux
# install from a pre-built package (pacman system):
pacman -U packing/pacman/codegraph-1.5.0-1-aarch64.pkg.tar.xz
# or build & install in one go:
make all VER=1.5.0 PKG=pacman && pacman -U packing/pacman/codegraph-1.5.0-1-aarch64.pkg.tar.xz
# or classic script path:
bash scripts/install.sh 1.5.0
make test
codegraph init                 # inside your project
codegraph index
```

Dependencies (Termux): `pacman -S gcc patchelf proot glibc curl` (or `pkg install …`)

## How it works

```
terminal
  │  codegraph  (C wrapper, compiled on-device → bionic ELF)
  │    • clears LD_PRELOAD / LD_LIBRARY_PATH / LD_DEBUG
  │      (LD_LIBRARY_PATH leaks into bionic children like `git` and
  │       breaks them: "CANNOT LINK EXECUTABLE … bad ELF magic")
  │    • writes fake /proc/stat, /proc/loadavg, /proc/cpuinfo,
  │      /sys/devices/system/cpu/{present,online} to $TMPDIR/.codegraph-fake
  │    • sets CODEGRAPH_HOST_PPID (upstream launcher behaviour, #1185)
  │
  ▼  proot  (5 bind mounts, minimal — no qemu)
  │
  ▼  node  (bundled glibc v24.16.0, patchelf'd interpreter)
  │       + codegraph.js (--liftoff-only, as upstream)
  │
  ▼  Rust kernel (codegraph-kernel.node) + tree-sitter wasm parsers
```

### The two fixes

**1. glibc binary on bionic — one `patchelf` call, interpreter only**

```
patchelf --set-interpreter $PREFIX/glibc/lib/ld-linux-aarch64.so.1 node
```

- Termux's glibc `ld.so` has `/data/data/com.termux/files/usr/glibc/lib/`
  compiled in as its default search path → **no** `LD_LIBRARY_PATH` needed.
- Never add `--set-rpath` and never run `patchelf` twice: both corrupt the
  121 MB binary (immediate SIGSEGV, exit 139).

**2. Android hides `/proc/stat` + `/proc/loadavg` (Permission denied)**

`os.cpus()` returns `[]` → downstream tools see 0 cores and hang. The wrapper
binds 5 fake files through `proot` (which is fast enough for a wrapper; we did
not need a `LD_PRELOAD` hook like codebuff-termux's `hook.c`).

A clean environment is essential: no `LD_LIBRARY_PATH` means bionic children
(`git`, `timeout`, ...) spawned by codegraph keep working.

## Installation layout

```
$PREFIX/bin/codegraph              → C wrapper (bionic)
$PREFIX/lib/codegraph-termux/
  current → 1.5.0/
  1.5.0/                           → extracted release tarball
    node                           → glibc node, interpreter patched
    bin/codegraph                  → upstream shell launcher (unused)
    lib/dist/bin/codegraph.js      → JS entry
    lib/kernel/codegraph-kernel.node → Rust kernel
```

## Scripts

| Script                | Purpose |
| Script                | Purpose |
|-----------------------|---------|
| `make all VER=… PKG=pacman` | full pipeline: produce → stage → package (both — pacman (pkg.tar.xz) + deb (optional)) |
| `tools/produce-local.sh` | resolve version (or `CODEGRAPH_TARBALL=…`) → download → extract → `patchelf` node → cache in `~/.cache/codegraph-termux/` |
| `scripts/build.sh`    | stage a relocatable prefix under `artifacts/staged/` (wrapper compiles with relative self-detection) |
| `scripts/compile-wrapper.sh` | compile `codegraph-wrapper.c` with the four `-D` paths baked in |
| `scripts/install.sh`  | one-shot: resolve → download → extract → patch → compile wrapper → symlink `current` → smoke test |
| `scripts/package/package_pacman.sh` | `makepkg` with `packaging/pacman/PKGBUILD` → `packing/pacman/codegraph-*.pkg.tar.*` |
| `scripts/package/package_deb.sh` | `dpkg-deb` from the staged prefix → `packing/deb/codegraph_*.deb` (optional, dpkg Termux) |
| `scripts/test.sh`     | PASS/FAIL/SKIP harness: ELF checks, interpreter check, `--version`, `os.cpus()` under proot, fake-file creation, `index`+`status` in a scratch git repo |

## Troubleshooting

- **`os.cpus()` still 0** → `pkg install proot`; fake files live in
  `${TMPDIR:-$PREFIX/tmp}/.codegraph-fake` (recreated on every wrapper run).
- **`CANNOT LINK EXECUTABLE`** for `git`/`sh` → some script exported
  `LD_LIBRARY_PATH`; the wrapper strips it — run codegraph through the wrapper,
  not through the bundled node directly.
- **SIGSEGV / exit 139** → the bundle node was patched twice or got an rpath;
  re-extract from the tarball and re-run `patchelf` once.
- **Upgrading** → `bash scripts/install.sh <new-version>`; old versions stay
  under `$PREFIX/lib/codegraph-termux/` — remove them manually.
- **Telemetry** → codegraph collects usage telemetry (see upstream docs); use
  `codegraph telemetry --help` (or run with `CODEGRAPH_DISABLE_TELEMETRY=1`).

## License

MIT — see [LICENSE](LICENSE). The bundled upstream binary keeps its own license.
