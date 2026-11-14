# atelier.nvim

A small, fast colorscheme manager for Neovim.

- Parallel install/update (no serial pipeline)
- Demand-loaded theme providers; only the saved provider is activated at startup
- Early restore of the last selection, before the first editor render
- Diffed picker with lazy-loaded Volt controls and a keyboard-only fallback
- Light / Dark / Auto preference, with optional Linux desktop following
- Explicit `<Space>` preview that restores on cancel
- Distinct preview/applied states with visible operation progress
- Recoverable cleanup: unused themes are archived, never silently deleted
- Tiny config schema, callback-based escape hatches
- Single explicit `State` table — no module-level globals

## Requirements

Neovim 0.10+ and `git` on your `PATH`.

[`nvzone/volt`](https://github.com/nvzone/volt) enables clickable picker controls. Without it the picker remains usable by keyboard and shows an installation hint. Linux Auto mode uses `gdbus` (provided by GLib) and an XDG desktop portal exposing the Settings interface; if unavailable, Atelier keeps the last effective background. Other platforms can supply a custom provider.

## Install

With lazy.nvim:

```lua
return {
  { 'nvzone/volt', lazy = true }, -- required only when :Atelier opens
  {
    'Synchlaire/atelier.nvim',
    lazy = false,
    priority = 1000,
    opts = {
      themes = {
        {
          'folke/tokyonight.nvim',
          backgrounds = {
            ['tokyonight-night'] = 'dark',
            ['tokyonight-day'] = 'light',
          },
        },
        'rebelot/kanagawa.nvim',
        { 'comfysage/evergarden', branch = 'mega' },
      },
    },
  },
}
```

Open the picker with `:Atelier`. Press `I` to install missing themes, `U` to update, `<CR>` to commit a selection, `q` or `<Esc>` to cancel.

Keep Volt as a separate lazy spec rather than an eager dependency of Atelier. lazy.nvim loads its Lua module on the first picker open. Atelier itself must run during startup to restore the selected colorscheme early. Themes managed by Atelier should not also be eagerly loaded by another plugin manager.

## Configuration

Everything other than `themes` is optional.

```lua
require('atelier').setup({
  themes = {
    'folke/tokyonight.nvim',
    'rebelot/kanagawa.nvim',
    {
      'comfysage/evergarden',
      branch = 'mega',
      only = { 'evergarden' },        -- whitelist (empty = all variants)
      except = {},                    -- blacklist
      before = function(name) end,    -- per-spec hook, runs before :colorscheme
      after  = function(name) end,    -- per-spec hook, runs after  :colorscheme
      auto = false,                   -- set true ONLY if this scheme handles both background values itself
      background = 'dark',            -- optional fixed default; not an Auto capability on its own
      backgrounds = {                 -- optional per-variant override map; wins over `background`.
        ['evergarden-fall'] = 'dark',
      },
    },
    'default',                        -- built-ins work too
    '/abs/path/to/local/colorscheme', -- absolute paths are treated as local plugins
  },

  install_on_setup = false,   -- if true, missing themes auto-clone on setup()
  parallel = 4,               -- worker pool size for git ops
  persist = true,             -- remember the last selection across sessions
  mode = 'auto',              -- fallback preference if no saved mode: 'auto' | 'dark' | 'light'
  desktop_provider = nil,     -- optional { start = function(callback) return stop end }
  activity = false,           -- (reserved) usage tracking
  data_dir = nil,             -- defaults to stdpath('data')/atelier

  on_load = function(name)    -- fires after every successful theme load
    -- e.g. require('lualine').setup { options = { theme = name } }
  end,
})
```

## Commands

| Command           | Action                          |
|-------------------|---------------------------------|
| `:Atelier`        | Open the picker                 |
| `:Atelier install`| Install all missing themes      |
| `:Atelier update` | Update all installed themes     |
| `:Atelier clean`  | Archive themes no longer in your config under `sites/trash/` |

## Picker keys

The picker groups themes by spec. Each group has a header (`▾`/`▸`) you can fold open or closed. When the list is long (more than ~6 specs) atelier starts collapsed.

| Key                 | Action                                                |
|---------------------|-------------------------------------------------------|
| `<CR>`              | Commit the previewed theme (or toggle fold on a header) |
| `<Space>`           | Preview the theme under the cursor without committing   |
| `<Tab>`             | Toggle fold under the cursor                          |
| `zo` / `zc`         | Open / close fold                                     |
| `zR` / `zM`         | Expand all / collapse all                             |
| `/`                 | Inline filter — type to narrow live, `<Esc>` clears   |
| `<C-/>`             | Hand off to `snacks.picker` (falls back to inline `/`) |
| `q` / `<Esc>`       | Close (or clear filter if one is active)              |
| `b`                 | Preview the opposite explicit mode (`B` and `t` remain aliases) |
| `a`                 | Preview Auto mode, following the desktop when supported |
| `?`                 | Show the workshop action reference                    |
| `I` / `U` / `C`     | Install missing / update all / archive unused         |
| `R`                 | Force redraw                                          |

Filtering force-expands any spec whose name or variants match, so a search like `/dark` immediately surfaces every dark variant across every group.

### Dark / light

Atelier never guesses capabilities from names. Declare `background = 'dark' | 'light'` or per-variant `backgrounds` to label variants and set `vim.o.background` before `:colorscheme`.

Auto following is enabled only when either:

- the spec declares `auto = true`, promising that the **same colorscheme** supports both background values; or
- the spec explicitly declares an allowed variant for each background using `backgrounds` (and optionally the spec-level `background`). `only` / `except` filters also apply to these pairs.

A fixed or unknown theme does not start desktop following. You can still choose it normally. Selecting a declared variant directly respects that variant even if the previous selection used the opposite explicit mode. Mode controls instead request a compatible variant; a fixed-only theme rejects an unsupported mode with a visible message.

With Volt installed, click **Light / Dark / Auto** to preview a preference. Keyboard equivalents are `b` for the opposite explicit background and `a` for Auto. These are drafts: `<CR>` applies and remembers the selection, while closing restores the original theme and background. Auto drafts may react to host changes, but no preview writes state. On cancellation, a committed Auto selection catches up with the latest host value.

Atelier stores the user-selected variant anchor (`choice`), effective variant (`theme`), preference (`mode`) and effective `background` under `<data_dir>/state.json`. An Auto round trip returns to the chosen variant when its declared background returns, even if several variants share that background. Successful host changes refresh the effective-result cache without changing the mode or anchor, avoiding repeated startup flips from an outdated cached background. Existing state files are read without requiring a reset: a legacy background matching declared metadata inherits `mode`; an undeclared override remains explicit.

The Linux provider uses asynchronous portal reads (`ReadOne`, with a fallback to `Read`) and `SettingChanged` signals, not polling. No preference, missing portal, or failed reads retain a stable background. Initial restore uses the last effective background; if the desktop changed while Neovim was closed, the asynchronous portal response can still cause one correction after startup.

A custom provider can extend this to another environment. Its `start` function must report the current preference once, then report subsequent changes; a change-only watcher needs an initial read to avoid waiting until the next host change:

```lua
desktop_provider = {
  start = function(callback)
    -- Report 'dark', 'light', or nil (no preference).
    -- callback may be called repeatedly; Atelier schedules it safely.
    callback('dark')
    return function()
      -- Stop your watcher and release its resources.
    end
  end,
}
```

Providers are stopped when neither the committed selection nor an Auto draft needs them, on repeated `setup()`, and on editor exit. Atelier does not change desktop settings.

### Loading and compatibility

Status checks, installation and variant discovery do not activate theme providers. A provider is added to `runtimepath` only before previewing, applying or restoring it. Previously used providers remain there because Lua modules may reference them; this is demand loading, not unsafe module unloading. Before the first activation, direct `:colorscheme` calls and provider-shipped integrations are unavailable; use `atelier.load(spec_name, variant)` to activate the provider first.

Atelier manages colorschemes, not arbitrary plugin lifecycles: runtime-only activation does not source a provider's `plugin/` scripts. Use `before` / `after` hooks for theme-specific setup, or manage a theme's additional plugin lifecycle externally. Core operations work without Volt; the picker and Volt are never required by `setup()`.

Restoration hooks now run inside `setup()`, not at `VimEnter`. Any modules required by `before`, `after` or `on_load` must already be available at that point; configure their loading order explicitly rather than relying on a later startup event.

## Lua API

```lua
local atelier = require('atelier')

atelier.pick()                    -- open the picker
atelier.load('tokyonight', 'tokyonight-night')
atelier.current()                 -- { spec_name, choice, theme, mode, background }
atelier.set_mode('auto')          -- apply + persist preference for the active theme
atelier.list()                    -- runtime info for every theme

atelier.install()
atelier.update()
atelier.clean()

atelier.on('state_changed', function() ... end)
```

Events: `state_changed`, `install_finished`, `update_finished`, `clean_finished`.

`atelier.clean()` moves unknown theme directories into a timestamped directory under `<data_dir>/sites/trash/`. The picker asks for confirmation and lists every affected theme first.

## Development

Run the regression suite from the repository root:

```sh
nvim --clean --headless -u NONE -l tests/run.lua
nvim --clean --headless -u NONE -l tests/desktop.lua
ATELIER_VOLT_PATH=/path/to/volt nvim --clean --headless -u NONE -l tests/ui.lua
```

The UI suite runs fallback tests without Volt and reports skipped drawing tests. Set `ATELIER_VOLT_PATH` to exercise real Volt rendering. Desktop tests use a fake transport, not your running desktop.

Reproducible isolated startup measurements and before/after results are in [docs/performance.md](docs/performance.md). For a fresh working-tree measurement:

```sh
python3 tests/benchmark.py --runs 9 --warmup 1 --run-tests --output /tmp/atelier-after.json
```

## License

MIT
