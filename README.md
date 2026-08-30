# atelier.nvim

A small, fast colorscheme manager for Neovim.

- Parallel install/update (no serial pipeline)
- Pure-function picker with diffed redraws (no flicker)
- Explicit `<Space>` preview that restores on cancel
- Distinct preview/applied states with visible operation progress
- Recoverable cleanup: unused themes are archived, never silently deleted
- Tiny config schema, callback-based escape hatches
- Single explicit `State` table — no module-level globals

## Requirements

Neovim 0.10+ and `git` on your `PATH`.

## Install

With lazy.nvim:

```lua
{
  'Synchlaire/atelier.nvim',
  lazy = false,
  priority = 1000,
  opts = {
    themes = {
      'folke/tokyonight.nvim',
      'rebelot/kanagawa.nvim',
      { 'comfysage/evergarden', branch = 'mega' },
    },
  },
}
```

Open the picker with `:Atelier`. Press `I` to install missing themes, `U` to update, `<CR>` to commit a selection, `q` or `<Esc>` to cancel.

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
      background = 'dark',            -- optional: 'dark' | 'light'. atelier sets vim.o.background before :colorscheme.
      backgrounds = {                 -- optional per-variant override map; wins over `background`.
        ['evergarden-fall'] = 'dark',
      },
    },
    'default',                        -- built-ins work too
    '/abs/path/to/local/colorscheme', -- absolute paths are treated as local plugins
  },

  install_on_setup = false,   -- if true, missing themes auto-clone on setup()
  parallel = 4,               -- worker pool size for git ops
  persist = true,             -- remember the last theme across sessions
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
| `b`                 | Preview the paired dark/light variant (`B` and `t` remain aliases) |
| `?`                 | Show the workshop action reference                    |
| `I` / `U` / `C`     | Install missing / update all / archive unused         |
| `R`                 | Force redraw                                          |

Filtering force-expands any spec whose name or variants match, so a search like `/dark` immediately surfaces every dark variant across every group.

### Dark / light

Atelier never guesses whether a colorscheme is dark or light. If you want it to know, declare it on the spec via `background = 'dark' | 'light'` (or per-variant via `backgrounds = { variant_name = 'dark' }`). When set, atelier writes `vim.o.background` before calling `:colorscheme`, so colorschemes that branch on `vim.o.background` get the right value at load time. Declared backgrounds are shown as a `· dark` / `· light` suffix on each variant row in the picker.

Pressing `b` previews the opposite mode. If the active spec has a paired variant declared in that mode (e.g. `backgrounds = { ['tokyonight-day'] = 'light', ['tokyonight-night'] = 'dark' }`), atelier previews that variant directly. Otherwise it previews the background change on the current colorscheme. Press `<CR>` to apply and persist it; closing the picker restores the original theme and background.

The committed background is persisted alongside the theme name, so the next session restores it before `:colorscheme` runs.

## Lua API

```lua
local atelier = require('atelier')

atelier.pick()                    -- open the picker
atelier.load('tokyonight', 'tokyonight-night')
atelier.current()                 -- { spec_name, theme }
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
```

## License

MIT
