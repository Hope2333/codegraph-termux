/**
 * codegraph-wrapper.c — CodeGraph for Termux launcher (proot-only approach)
 *
 * CodeGraph bundled Node.js runtime is a glibc ELF. On Termux (Android,
 * bionic libc) it cannot start unless its interpreter points at Termux
 * glibc ld.so. The interpreter alone is enough — Termux glibc ld.so has
 * its default library search path compiled in ($PREFIX/glibc/lib), so
 * NO LD_LIBRARY_PATH and NO rpath patching is needed. That keeps the
 * environment clean: bionic child processes (git, sh, ...) spawned by
 * CodeGraph are never polluted with glibc library paths.
 *
 * What this wrapper does:
 *   1. Clears LD_PRELOAD / LD_LIBRARY_PATH / LD_DEBUG so Termux bionic
 *      preloads (e.g. libtermux-exec.so) and stray library paths never
 *      poison the glibc runtime or its children.
 *   2. Writes 5 fake CPU/proc files into a temp dir. Android blocks
 *      reading /proc/stat and /proc/loadavg (Permission denied), which
 *      makes Node os.cpus() report 0 cores and breaks CPU counting.
 *   3. Execs proot with 5 bind mounts replacing the blocked files, then
 *      runs the bundle node with the CodeGraph JS entry. proot intercepts
 *      at the ptrace level, so direct syscalls from Node/V8 are covered
 *      too (an LD_PRELOAD libc hook would be bypassed).
 *   4. If proot is missing, falls back to a direct exec (core CLI still
 *      works; os.cpus() will report 0 cores).
 *
 * Build (see scripts/compile-wrapper.sh):
 *   gcc -O2 -s -o codegraph-wrapper codegraph-wrapper.c \
 *     -DNODE_PATH=/path/to/codegraph-termux/current/node \
 *     -DCODEGRAPH_JS=/path/to/.../lib/dist/bin/codegraph.js \
 *     -DPROOT_PATH=/data/data/com.termux/files/usr/bin/proot \
 *     -DFAKE_DIR=/data/data/com.termux/files/usr/tmp/.codegraph-fake
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <limits.h>
#include <errno.h>

#ifndef NODE_PATH
#  define NODE_PATH \
    "/data/data/com.termux/files/usr/lib/codegraph-termux/current/node"
#endif
#ifndef CODEGRAPH_JS
#  define CODEGRAPH_JS \
    "/data/data/com.termux/files/usr/lib/codegraph-termux/current/lib/dist/bin/codegraph.js"
#endif
#ifndef PROOT_PATH
#  define PROOT_PATH \
    "/data/data/com.termux/files/usr/bin/proot"
#endif
#ifndef FAKE_DIR
#  define FAKE_DIR \
    "/data/data/com.termux/files/usr/tmp/.codegraph-fake"
#endif

/* Extra flags the official launcher (bin/codegraph) passes to node:
 * --liftoff-only avoids a V8 turboshaft WASM Zone OOM (upstream #293/#298);
 * --disable-warning mutes node:sqlite experimental-feature warning. */
static const char *NODE_FLAGS[] = {
    "--liftoff-only",
    "--disable-warning=ExperimentalWarning",
    NULL
};

static void ensure_dir(const char *dir) {
    struct stat st;
    if (stat(dir, &st) == -1) mkdir(dir, 0755);
}

static void write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fwrite(content, 1, strlen(content), f);
    fclose(f);
    chmod(path, 0644);
}

static void create_fake_files(void) {
    ensure_dir(FAKE_DIR);

    /* /proc/stat — 8 CPU cores (Android blocks reading the real one) */
    write_file(FAKE_DIR "/stat",
        "cpu  0 0 0 0 0 0 0 0 0 0\n"
        "cpu0 0 0 0 0 0 0 0 0 0 0\n"
        "cpu1 0 0 0 0 0 0 0 0 0 0\n"
        "cpu2 0 0 0 0 0 0 0 0 0 0\n"
        "cpu3 0 0 0 0 0 0 0 0 0 0\n"
        "cpu4 0 0 0 0 0 0 0 0 0 0\n"
        "cpu5 0 0 0 0 0 0 0 0 0 0\n"
        "cpu6 0 0 0 0 0 0 0 0 0 0\n"
        "cpu7 0 0 0 0 0 0 0 0 0 0\n"
        "intr 0 0 0 0 0 0 0 0 0 0\n"
        "ctxt 0\nbtime 0\nprocesses 0\n"
        "procs_running 1\nprocs_blocked 0\n"
        "softirq 0 0 0 0 0 0 0 0 0 0\n");

    /* /proc/cpuinfo — 8 ARM cores */
    {
        FILE *f = fopen(FAKE_DIR "/cpuinfo", "w");
        if (f) {
            for (int i = 0; i < 8; i++)
                fprintf(f,
                    "processor\t: %d\n"
                    "BogoMIPS\t: 100.00\n"
                    "Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32\n"
                    "CPU implementer\t: 0x41\n"
                    "CPU architecture\t: 8\n"
                    "CPU variant\t: 0x0\n"
                    "CPU part\t: 0xd0d\n"
                    "CPU revision\t: 2\n\n", i);
            fclose(f);
            chmod(FAKE_DIR "/cpuinfo", 0644);
        }
    }

    /* /proc/loadavg — also blocked on Android */
    write_file(FAKE_DIR "/loadavg", "0.00 0.00 0.00 1/1 1\n");
    /* /sys/devices/system/cpu/present + online */
    write_file(FAKE_DIR "/cpu-present", "0-7\n");
    write_file(FAKE_DIR "/cpu-online", "0-7\n");
}

/* ── argv builder ── */
typedef struct { char **argv; int cap, len; } Argv;

static Argv *argv_new(int hint) {
    Argv *a = malloc(sizeof(Argv));
    a->cap = hint ? hint : 32;
    a->len = 0;
    a->argv = malloc(a->cap * sizeof(char *));
    return a;
}

static void argv_add(Argv *a, const char *s) {
    if (a->len >= a->cap - 1) {
        a->cap *= 2;
        a->argv = realloc(a->argv, a->cap * sizeof(char *));
    }
    a->argv[a->len++] = strdup(s);
}

static void argv_emit(Argv *a) { a->argv[a->len] = NULL; }

/* Resolve the install prefix relative to this binary, mirroring the
 * upstream shell launcher (which derives paths from $0). Layout:
 *   <prefix>/bin/codegraph
 *   <prefix>/lib/codegraph-termux/current/{node,lib/dist/bin/codegraph.js}
 * Falls back to the compiled-in -D paths when that layout is absent
 * (e.g. the wrapper was copied elsewhere). */
static int resolve_self_prefix(char *out, size_t outsz) {
    char link[PATH_MAX], *p;
    ssize_t n = readlink("/proc/self/exe", link, sizeof(link) - 1);
    if (n <= 0) return 0;
    link[n] = '\0';
    p = strrchr(link, '/');            /* strip /codegraph */
    if (!p) return 0;
    *p = '\0';
    p = strrchr(link, '/');            /* strip /bin -> prefix */
    if (!p) return 0;
    *p = '\0';
    char probe[PATH_MAX];
    snprintf(probe, sizeof(probe),
             "%s/lib/codegraph-termux/current/node", link);
    if (access(probe, X_OK) == 0) {
        snprintf(out, outsz, "%s", link);
        return 1;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    /* Strip LD_* env vars that could poison glibc loading (bionic
     * libtermux-exec.so preload, stray library paths, ...). */
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("LD_DEBUG");

    /* Thread the MCP host pid to the server orphan watchdog — mirrors
     * what the official bin/codegraph launcher does (upstream #1185). */
    {
        const char *existing = getenv("CODEGRAPH_HOST_PPID");
        if (!existing || !*existing) {
            char buf[32];
            snprintf(buf, sizeof(buf), "%ld", (long)getppid());
            setenv("CODEGRAPH_HOST_PPID", buf, 1);
        }
    }

    /* Check proot availability */
    struct stat st;
    int has_proot = (stat(PROOT_PATH, &st) == 0 && (st.st_mode & S_IXUSR));

    /* Resolve node + JS entry: prefer self-relative layout (works from a
     * staged prefix and from the packaged install alike), fall back to
     * the paths baked in at compile time. */
    char node_path[PATH_MAX], js_path[PATH_MAX], self_prefix[PATH_MAX];
    if (resolve_self_prefix(self_prefix, sizeof(self_prefix))) {
        snprintf(node_path, sizeof(node_path),
                 "%s/lib/codegraph-termux/current/node", self_prefix);
        snprintf(js_path, sizeof(js_path),
                 "%s/lib/codegraph-termux/current/lib/dist/bin/codegraph.js",
                 self_prefix);
    } else {
        snprintf(node_path, sizeof(node_path), "%s", NODE_PATH);
        snprintf(js_path, sizeof(js_path), "%s", CODEGRAPH_JS);
    }

    /* Build the node invocation: node <flags> <js-entry> [user args...] */
    Argv *node_argv = argv_new(4 + argc);
    argv_add(node_argv, node_path);
    for (int i = 0; NODE_FLAGS[i]; i++)
        argv_add(node_argv, NODE_FLAGS[i]);
    argv_add(node_argv, js_path);
    for (int i = 1; i < argc; i++)
        argv_add(node_argv, argv[i]);
    argv_emit(node_argv);

    if (!has_proot) {
        fprintf(stderr, "codegraph: proot not found at %s, "
                "running without CPU fakes (os.cpus() may report 0 cores)\n",
                PROOT_PATH);
        execv(node_path, node_argv->argv);
        fprintf(stderr, "codegraph: exec failed: %m\n");
        return 1;
    }

    /* Create fake files */
    create_fake_files();

    /* Build proot command with all bind mounts */
    Argv *cmd = argv_new(6 + node_argv->len);
    argv_add(cmd, PROOT_PATH);

    {
        char bind[512];
        snprintf(bind, sizeof(bind), FAKE_DIR "/stat:/proc/stat");
        argv_add(cmd, "-b"); argv_add(cmd, bind);
        snprintf(bind, sizeof(bind), FAKE_DIR "/cpuinfo:/proc/cpuinfo");
        argv_add(cmd, "-b"); argv_add(cmd, bind);
        snprintf(bind, sizeof(bind), FAKE_DIR "/loadavg:/proc/loadavg");
        argv_add(cmd, "-b"); argv_add(cmd, bind);
        snprintf(bind, sizeof(bind),
                 FAKE_DIR "/cpu-present:/sys/devices/system/cpu/present");
        argv_add(cmd, "-b"); argv_add(cmd, bind);
        snprintf(bind, sizeof(bind),
                 FAKE_DIR "/cpu-online:/sys/devices/system/cpu/online");
        argv_add(cmd, "-b"); argv_add(cmd, bind);
    }

    /* Append the node invocation + user args */
    for (int i = 0; node_argv->argv[i]; i++)
        argv_add(cmd, node_argv->argv[i]);
    argv_emit(cmd);

    /* Exec under proot */
    execv(PROOT_PATH, cmd->argv);

    /* Fallback: direct exec */
    fprintf(stderr, "codegraph: proot exec failed (%m), falling back\n");
    execv(node_path, node_argv->argv);
    fprintf(stderr, "codegraph: exec failed: %m\n");
    return 1;
}
