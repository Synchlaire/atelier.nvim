#!/usr/bin/env python3
"""Reproducible isolated startup benchmark for atelier.nvim (stdlib only).

  python3 tests/benchmark.py --runs 7 --freeze-head --run-tests \
      --output /tmp/atelier-baseline.json
  python3 tests/benchmark.py --root /path/to/repo --runs 7   # "after" run

Every measured run is a fresh `nvim --headless` process with temporary XDG
dirs and HOME, local synthetic colorschemes only (no network, no user
config/data). Scenarios per fixture size N (default 1/10/100):
  control-N  N theme dirs on the rtp, `:colorscheme` at VimEnter, no atelier
  atelier-N  require('atelier') + setup{N local specs, persist=true}
All temp dirs are removed on exit, including failures and SIGTERM.
"""
import argparse
import json
import os
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

args_timeout = 30
HERE = os.path.dirname(os.path.abspath(__file__))
INIT = os.path.join(HERE, "benchmark.lua")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def git(root, *args):
    r = run(["git", "-C", root, *args])
    return r.stdout.strip() if r.returncode == 0 else None


def isolated_env(base):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NVIM", "XDG_", "VIM"))}
    home = os.path.join(base, "home")
    env.update(
        HOME=home,
        XDG_CONFIG_HOME=os.path.join(home, "config"),
        XDG_DATA_HOME=os.path.join(home, "data"),
        XDG_STATE_HOME=os.path.join(home, "state"),
        XDG_CACHE_HOME=os.path.join(home, "cache"),
        XDG_CONFIG_DIRS=os.path.join(home, "etc-xdg"),
        XDG_DATA_DIRS=os.path.join(home, "share"),
        TMPDIR=os.path.join(base, "tmp"),
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_SYSTEM=os.devnull,
    )
    for k in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR"):
        os.makedirs(env[k], exist_ok=True)
    return env


def make_fixture(base, n):
    """N trivial local colorschemes; the last one is the persisted active theme."""
    fx = os.path.join(base, f"fixture-{n}")
    names = [f"bench-{i:03d}" for i in range(1, n + 1)]
    for name in names:
        d = os.path.join(fx, "themes", name, "colors")
        os.makedirs(d)
        with open(os.path.join(d, f"{name}.lua"), "w") as f:
            f.write(
                "vim.cmd('highlight clear')\n"
                f"vim.g.colors_name = '{name}'\n"
                "vim.api.nvim_set_hl(0, 'Normal', { fg = '#cccccc', bg = '#111111' })\n"
            )
    os.makedirs(os.path.join(fx, "data"))
    active = names[-1]
    with open(os.path.join(fx, "data", "state.json"), "w") as f:
        json.dump({"spec_name": active, "theme": active, "background": "dark"}, f)
    # Validate fixture colors_name matches file name.
    for name in names:
        p = os.path.join(fx, "themes", name, "colors", f"{name}.lua")
        m = re.search(r"vim\.g\.colors_name = '([^']+)'", open(p).read())
        assert m and m.group(1) == name, f"bad fixture {p}"
    return fx, active


def startuptime_total(path):
    try:
        last = [l for l in open(path).read().splitlines() if l.strip()][-1]
        return float(last.split()[0])
    except (OSError, IndexError, ValueError):
        return None


def one_run(nvim, root, fx, scenario, base, idx):
    env = isolated_env(os.path.join(base, f"run-{idx}"))
    out = os.path.join(base, f"run-{idx}", "result.json")
    log = os.path.join(base, f"run-{idx}", "startup.log")
    env.update(
        ATELIER_BENCH_ROOT=root,
        ATELIER_BENCH_FIXTURE=fx,
        ATELIER_BENCH_SCENARIO=scenario,
        ATELIER_BENCH_OUT=out,
    )
    cmd = [nvim, "--headless", "-n", "-i", "NONE", "-u", INIT, "--startuptime", log]
    t0 = time.perf_counter()
    try:
        r = run(cmd, env=env, cwd=base, timeout=args_timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{scenario} run timed out after {args_timeout}s (nvim hung, likely an init error)")
    wall = (time.perf_counter() - t0) * 1000
    # Neovim may exit 0 on init errors: any stderr output, a missing result
    # file or a non-empty v:errmsg is a failed run.
    if r.returncode != 0 or r.stderr.strip() or not os.path.exists(out):
        raise RuntimeError(f"{scenario} run failed rc={r.returncode}\n{r.stdout}\n{r.stderr}")
    res = json.load(open(out))
    if res.get("errmsg"):
        raise RuntimeError(f"{scenario} run reported v:errmsg: {res['errmsg']}")
    res["startuptime_total_ms"] = startuptime_total(log)
    res["process_wall_ms"] = wall
    shutil.rmtree(os.path.join(base, f"run-{idx}"), ignore_errors=True)
    return res


def med(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


METRICS = ["require_ms", "setup_ms", "require_plus_setup_ms", "vimenter_resolution_ms",
           "startuptime_total_ms", "process_wall_ms"]


def summarize(results):
    s = {"runs": len(results)}
    for m in METRICS:
        v = [r.get(m) for r in results if r.get(m) is not None]
        s[m] = {"median": med(v), "min": min(v), "max": max(v)} if v else None
    first = results[0]
    s["modules_after_setup"] = first["after_setup"]["atelier_modules"]
    s["modules_at_vimenter_start"] = first["at_vimenter_start"]["atelier_modules"]
    s["modules_at_vimenter_end"] = first["at_vimenter_end"]["atelier_modules"]
    s["module_names_at_vimenter_end"] = first["at_vimenter_end"]["atelier_module_names"]
    s["rtp_after_setup"] = first["after_setup"]["managed_rtp"]
    s["rtp_at_vimenter_end"] = first["at_vimenter_end"]["managed_rtp"]
    s["loaded_by_setup"] = all(r["loaded_by_setup"] for r in results)
    s["loaded_at_vimenter"] = all(r["loaded_at_vimenter"] for r in results)
    s["colors_name_ok"] = all(r["colors_name_ok"] for r in results)
    s["expected_theme"] = first["expected_theme"]
    s["actual_colors_name"] = first["at_vimenter_end"]["colors_name"]
    return s


def render(report):
    L = []
    rev = report["revision"]
    L.append(f"revision {rev['commit']} ({rev['source']}); nvim {report['nvim']}; "
             f"runs/scenario {report['runs']} (+{report['warmup']} warmup); "
             f"{report['platform']}")
    L.append("")
    L.append("| scenario | require | setup | req+setup | VimEnter resolution | startuptime total | wall | mods setup/VE | rtp setup/VE | theme loaded |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    f = lambda x: "-" if x is None else f"{x['median']:.2f}"
    for name, s in report["scenarios"].items():
        where = "setup" if s["loaded_by_setup"] else ("VimEnter" if s["loaded_at_vimenter"] else "NOT LOADED")
        L.append(f"| {name} | {f(s['require_ms'])} | {f(s['setup_ms'])} | {f(s['require_plus_setup_ms'])} | "
                 f"{f(s['vimenter_resolution_ms'])} | {f(s['startuptime_total_ms'])} | {f(s['process_wall_ms'])} | "
                 f"{s['modules_after_setup']}/{s['modules_at_vimenter_end']} | "
                 f"{s['rtp_after_setup']}/{s['rtp_at_vimenter_end']} | {where} |")
    L.append("")
    L.append("Medians in ms. Overhead vs control (atelier - control):")
    for n in report["sizes"]:
        a, c = report["scenarios"][f"atelier-{n}"], report["scenarios"][f"control-{n}"]
        d = lambda m: a[m]["median"] - c[m]["median"]
        L.append(f"- N={n}: req+setup {d('require_plus_setup_ms'):+.2f}, VimEnter {d('vimenter_resolution_ms'):+.2f}, "
                 f"startuptime {d('startuptime_total_ms'):+.2f}" if a["startuptime_total_ms"] and c["startuptime_total_ms"]
                 else f"- N={n}: req+setup {d('require_plus_setup_ms'):+.2f}, VimEnter {d('vimenter_resolution_ms'):+.2f}")
    return "\n".join(L)


def run_tests(nvim, root, base):
    env = isolated_env(os.path.join(base, "tests-env"))
    r = run([nvim, "--clean", "--headless", "-u", "NONE", "-l", "tests/run.lua"], env=env, cwd=root, timeout=120)
    passed = re.search(r"atelier: (\d+) tests passed", r.stdout + r.stderr)
    ok = r.returncode == 0 and passed is not None and "Error" not in r.stderr
    return {"returncode": r.returncode if ok or r.returncode else 1,
            "stdout": (r.stdout + r.stderr).strip(),
            "passed": int(passed.group(1)) if passed else None,
            "stderr_seen": not ok}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.dirname(HERE), help="repo to benchmark (default: this repo)")
    ap.add_argument("--runs", type=int, default=7, help="fresh-process runs per scenario")
    ap.add_argument("--warmup", type=int, default=1, help="discarded runs per scenario")
    ap.add_argument("--sizes", default="1,10,100")
    ap.add_argument("--output", help="write JSON report here")
    ap.add_argument("--nvim", default=shutil.which("nvim") or "/usr/sbin/nvim")
    ap.add_argument("--freeze-head", action="store_true",
                    help="git-archive tracked HEAD of --root into a temp dir and benchmark that")
    ap.add_argument("--rev", default="HEAD", help="revision to freeze with --freeze-head (default HEAD)")
    ap.add_argument("--run-tests", action="store_true", help="also run tests/run.lua in the benchmarked root")
    args = ap.parse_args()

    if args.runs < 1:
        ap.error("--runs must be >= 1")
    if args.warmup < 0:
        ap.error("--warmup must be >= 0")
    try:
        sizes = [int(x) for x in args.sizes.split(",")]
    except ValueError:
        ap.error("--sizes must be comma-separated integers")
    if not sizes or any(n < 1 for n in sizes) or len(set(sizes)) != len(sizes):
        ap.error("--sizes must be non-empty, positive and unique")
    if not os.path.isdir(args.root):
        ap.error(f"--root is not a directory: {args.root}")
    exit_code = 0

    base = tempfile.mkdtemp(prefix="atelier-bench-")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        root = os.path.abspath(args.root)
        commit = git(root, "rev-parse", args.rev if args.freeze_head else "HEAD") or "unknown"
        source = "working tree"
        if args.freeze_head:
            frozen = os.path.join(base, "frozen")
            os.makedirs(frozen)
            ar = subprocess.Popen(["git", "-C", root, "archive", args.rev], stdout=subprocess.PIPE)
            tar = subprocess.run(["tar", "-x", "-C", frozen], stdin=ar.stdout)
            if ar.wait() != 0 or tar.returncode != 0:
                raise RuntimeError("git archive failed")
            root, source = frozen, f"frozen tracked {args.rev} (git archive)"
        elif git(root, "status", "--porcelain", "--untracked-files=no"):
            source = "working tree (tracked changes, dirty)"
        nvim_v = run([args.nvim, "--version"]).stdout.splitlines()[0]
        report = {
            "revision": {"commit": commit, "source": source},
            "nvim": nvim_v, "nvim_path": args.nvim,
            "platform": f"{platform.system()} {platform.release()} {platform.machine()}, {os.cpu_count()} cpus",
            "runs": args.runs, "warmup": args.warmup, "sizes": sizes,
            "scenarios": {}, "raw": {},
        }
        if args.run_tests:
            report["tests"] = run_tests(args.nvim, root, base)
        fixtures = {n: make_fixture(base, n) for n in sizes}
        scen = [(f"{k}-{n}", k, n) for n in sizes for k in ("control", "atelier")]
        raw = {name: [] for name, _, _ in scen}
        idx = 0
        # Interleave scenarios per round so drift hits all of them equally.
        for rnd in range(args.warmup + args.runs):
            for name, kind, n in scen:
                idx += 1
                res = one_run(args.nvim, root, fixtures[n][0], kind, base, idx)
                if res["at_vimenter_end"].get("colors_name") != fixtures[n][1]:
                    raise RuntimeError(f"{name}: colors_name {res['at_vimenter_end'].get('colors_name')!r} != {fixtures[n][1]!r}")
                if rnd >= args.warmup:
                    raw[name].append(res)
        for name, _, _ in scen:
            report["scenarios"][name] = summarize(raw[name])
            report["raw"][name] = raw[name]
        print(render(report))
        if "tests" in report:
            print(f"\ntests rc={report['tests']['returncode']}: {report['tests']['stdout']}")
            if report["tests"]["returncode"] != 0 or report["tests"]["stderr_seen"]:
                print("TESTS FAILED", file=sys.stderr)
                exit_code = 1
        if args.output:
            with open(args.output, "w") as f:
                json.dump(report, f, indent=2)
    finally:
        shutil.rmtree(base, ignore_errors=True)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
