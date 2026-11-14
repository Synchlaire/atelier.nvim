# Startup performance

## Harness

`tests/benchmark.py` (stdlib Python) drives `tests/benchmark.lua` (the Neovim init file).

```sh
# baseline: freeze tracked HEAD with git archive, run the 6 regression tests, benchmark
python3 tests/benchmark.py --runs 9 --warmup 1 --freeze-head --run-tests --output /tmp/atelier-baseline.json
# after a change: same command against the working tree (or another checkout)
python3 tests/benchmark.py --root /path/to/repo --runs 9 --warmup 1 --output /tmp/atelier-after.json
```

Options: `--root`, `--runs N` (>= 1, fresh process each), `--warmup N` (>= 0, discarded), `--sizes 1,10,100` (non-empty, positive, unique), `--output JSON`, `--nvim`, `--freeze-head`, `--rev REV` (what `--freeze-head` archives, default `HEAD`), `--run-tests`.

Failure handling: invalid arguments exit 2. A run fails if nvim exits nonzero, writes anything to stderr, reports a non-empty `v:errmsg`, produces no result file, hangs (30 s timeout) or ends with the wrong `colors_name`. Neovim can exit 0 after an init error, so stderr and the result file are checked too. `--run-tests` exits 1 when `tests/run.lua` fails (rc != 0, no `N tests passed` line or an error on stderr); the JSON is still written.

- Every run is a fresh `nvim --headless -n -i NONE -u tests/benchmark.lua --startuptime LOG` with temporary `HOME`/`XDG_*`/`TMPDIR`. No user config or data and no network (local specs only, nothing installed or cloned).
- Fixtures are generated per size N (1/10/100): `bench-001 ... bench-N`, each a local plugin dir with `colors/<name>.lua` that only runs `highlight clear`, sets `g:colors_name` and one `Normal` highlight. Theme execution cost is therefore trivial, and the numbers measure framework overhead, not a real colorscheme. The last theme is persisted as active in `state.json` (`background = dark`). The runner checks each fixture's `colors_name` and that the resolved `g:colors_name` equals the persisted theme.
- Scenarios run interleaved per round: `control-N` (N dirs on the rtp, `:colorscheme` at VimEnter, no atelier) and `atelier-N` (`require('atelier')`, then `setup{ themes = N local paths, persist = true }`).
- Measured: `require_ms`, `setup_ms` (the `require` is excluded from it, and `require_plus_setup_ms` sums them), `vimenter_resolution_ms` (time spent in the VimEnter handlers between two probes that bracket atelier's handler; for control, the `:colorscheme` call), `startuptime_total_ms` (last line of `--startuptime`), process wall time, `atelier*` modules in `package.loaded` and fixture dirs on the rtp, each at end of setup and at VimEnter. "Theme loaded" is `setup` if `g:colors_name` equals the persisted theme right after setup, else `VimEnter`.
- Temp dirs are removed in a `finally` (also on SIGTERM). `--freeze-head` extracts tracked HEAD only, so later edits and untracked files in the repo do not affect the baseline.
- Timer noise is about 1 ms; read deltas of that size as zero. Treat startuptime and wall as the least precise, since they include process start.

## Baseline

- Revision: `a5bdb0c6a090c755613ae33214c0ce918cb4cc69` (tracked HEAD, frozen via `git archive`)
- Neovim: `NVIM v0.12.6` (`/usr/sbin/nvim`)
- Host: Linux 7.3.3-1-cachyos-bore-lto x86_64, 8 cpus
- 9 measured fresh-process runs per scenario, plus 1 discarded warmup.
- Regression tests on the frozen HEAD: `nvim --clean --headless -u NONE -l tests/run.lua` printed `atelier: 6 tests passed`, rc 0.
- Raw JSON: `/tmp/atelier-baseline.json` (not committed).

Medians, ms:

| scenario | require | setup | require+setup | VimEnter resolution | startuptime total | wall | modules setup/VimEnter | rtp setup/VimEnter | theme loaded |
|---|---|---|---|---|---|---|---|---|---|
| control-1 | 0.00 | 0.09 | 0.09 | 0.72 | 26.05 | 31.57 | 0/0 | 1/1 | VimEnter |
| atelier-1 | 1.63 | 1.67 | 3.33 | 1.02 | 29.39 | 34.33 | 9/10 | 1/1 | VimEnter |
| control-10 | 0.00 | 0.93 | 0.93 | 0.84 | 27.47 | 32.86 | 0/0 | 10/10 | VimEnter |
| atelier-10 | 1.80 | 4.12 | 5.92 | 1.09 | 33.85 | 39.13 | 9/10 | 10/10 | VimEnter |
| control-100 | 0.00 | 9.74 | 9.74 | 0.91 | 48.20 | 53.45 | 0/0 | 100/100 | VimEnter |
| atelier-100 | 1.55 | 16.35 | 17.87 | 1.79 | 57.99 | 63.06 | 9/10 | 100/100 | VimEnter |

Atelier minus control (framework overhead):

| N | require+setup | VimEnter resolution | startuptime total |
|---|---|---|---|
| 1 | +3.24 | +0.30 | +3.34 |
| 10 | +4.99 | +0.26 | +6.38 |
| 100 | +8.13 | +0.89 | +9.79 |

Observations:
- At HEAD the persisted theme is always loaded at VimEnter, never in setup. The `VimEnter` autocmd in `lua/atelier/init.lua` does the load.
- `require('atelier')` loads 9 modules (`atelier`, `api`, `config`, `events`, `git`, `jobs`, `loader`, `manager`, `state`). `persist` is the tenth, loaded when the VimEnter handler runs.
- Setup cost grows with N: `refresh_status` does an `fs_stat` plus a scan of the whole `rtp` per spec. At N=100, atelier's setup is 16.35 ms against 9.74 ms for the bare rtp prepends in the control.
- The control's own rtp prepends already cost 9.74 ms at N=100, so some of this cost is not atelier's.
- The VimEnter resolution cost is small at every N (0.3 to 0.9 ms above control) because the fixture theme is trivial.

## Final comparison (verified working tree)

Final pair recorded back-to-back on the same host (Neovim `v0.12.6`, 9 measured runs + 1 warmup per scenario). Both runs used `--run-tests` and exited 0. Raw JSON: `/tmp/atelier-baseline-final.json`, `/tmp/atelier-after-final.json` (not committed).

- Before: `a5bdb0c6a090c755613ae33214c0ce918cb4cc69`, frozen tracked HEAD via `--freeze-head --rev a5bdb0c`. 6 tests pass.
- After: the same commit plus uncommitted working-tree changes (tracked files dirty). 29 tests pass. Nothing has been committed; this measures the working tree as it was at the time of the run.

Medians, ms (before -> after):

| N | setup | require+setup | VimEnter resolution | startuptime total | modules setup/VimEnter | managed rtp setup/VimEnter | theme loaded |
|---|---|---|---|---|---|---|---|
| 1 | 1.58 -> 3.43 | 2.98 -> 5.12 | 0.92 -> 0.14 | 23.33 -> 25.38 | 9/10 -> 10/10 | 1/1 -> 1/1 | VimEnter -> setup |
| 10 | 3.29 -> 3.29 | 4.94 -> 4.66 | 0.99 -> 0.11 | 27.66 -> 24.04 | 9/10 -> 10/10 | 10/10 -> 1/1 | VimEnter -> setup |
| 100 | 13.57 -> 5.00 | 15.07 -> 6.37 | 1.36 -> 0.10 | 46.27 -> 23.57 | 9/10 -> 10/10 | 100/100 -> 1/1 | VimEnter -> setup |

Controls (no atelier; N rtp prepends; `:colorscheme` at VimEnter), startuptime total, before / after session: N=1 19.33 / 20.04, N=10 22.66 / 23.79, N=100 36.07 / 33.48.

Reading the results:
- The active theme now loads during `setup()`; the VimEnter handler has almost nothing left to do (about 0.1 ms, down from 0.9 to 1.4 ms).
- The managed rtp holds only the active theme's directory at both points, instead of all N, avoiding the previous per-provider rtp work. Catalog normalization still grows with collection size. At N=100, setup drops 13.57 -> 5.00 ms and startuptime 46.27 -> 23.57 ms.
- At N=1 setup is slower (1.58 -> 3.43 ms) and total startup is 23.33 -> 25.38 ms. That is the cost of doing the theme load in `setup()` rather than at VimEnter, plus one more module loaded after setup (10 against 9). At N=10 total is 27.66 -> 24.04 ms.
- Caveat: the small-N total differences (about 2 to 4 ms, in both directions) are close to run-to-run noise and to the control drift between sessions (several ms). The fixtures are trivial single-file themes, so a real colorscheme adds its own execution cost in both builds. Treat the N=100 gain as the reliable result and the small-N numbers as roughly neutral.
- A negative atelier-minus-control overhead at N=100 only means atelier no longer puts all 100 dirs on the rtp, which the control still does. It is not a claim that atelier is faster than no plugin.

## Functional and visual verification

The final functional sweep (after adding anchor-preservation, unsupported-Auto and legacy fixed-mode regressions to the 29-test benchmark snapshot) passed on Neovim **0.10.4** and **0.12.6**:

- `tests/run.lua`: 32 tests (activation, early restore, persistence, migration, API, preview/cancel, Auto anchors and lifecycle, git operations).
- `tests/desktop.lua`: 14 tests with fake transport (portal reads, fallback, chunked signals, cancellation and resource cleanup).
- `tests/ui.lua`: 12 tests using real `nvzone/volt`; without Volt, 2 fallback tests pass and drawing cases explicitly skip.
- All Lua sources parse and pass StyLua's AST verification; `git diff --check` is clean. This is syntax/AST verification, not a claim of repository-wide formatting compliance.

A read-only smoke test of the real Linux portal returned `light`. Live desktop settings and user Neovim configuration were not modified. Embedded-Neovim rendered captures were inspected in dark/light modes, mode previews, narrow terminals and after scrolling; capture artifacts were kept under `/tmp/atelier-capture/out/`, not added as runtime dependencies.

The 0.10.4 check used the official release binary in a temporary directory, removed after the run. The installed Neovim was not replaced.
