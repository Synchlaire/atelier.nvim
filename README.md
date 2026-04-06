# atelier.nvim

A small, fast colorscheme manager for Neovim.

- Parallel install/update (no serial pipeline)
- Pure-function picker with diffed redraws (no flicker)
- Debounced hover preview that restores on cancel
- Tiny config schema, callback-based escape hatches
- Single explicit `State` table — no module-level globals

## Requirements

Neovim 0.10+ and `git` on your `PATH`.

## Install

With lazy.nvim:

```lua
{
  'atelier.nvim',
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
  preview_delay_ms = 120,     -- debounce for hover preview
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
| `:Atelier clean`  | Remove themes no longer in your config |

## Picker keys

The picker groups themes by spec. Each group has a header (`▾`/`▸`) you can fold open or closed. When the list is long (more than ~6 specs) atelier starts collapsed.

| Key                 | Action                                                |
|---------------------|-------------------------------------------------------|
| `<CR>`              | Commit the previewed theme (or toggle fold on a header) |
| `<Tab>`             | Toggle fold under the cursor                          |
| `zo` / `zc`         | Open / close fold                                     |
| `zR` / `zM`         | Expand all / collapse all                             |
| `/`                 | Inline filter — type to narrow live, `<Esc>` clears   |
| `<C-/>`             | Hand off to `snacks.picker` (falls back to inline `/`) |
| `q` / `<Esc>`       | Close (or clear filter if one is active)              |
| `B`                 | Toggle `vim.o.background` between dark and light      |
| `I` / `U` / `C`     | Install missing / update all / clean unused           |
| `R`                 | Force redraw                                          |

Filtering force-expands any spec whose name or variants match, so a search like `/dark` immediately surfaces every dark variant across every group.

### Dark / light

Atelier never guesses whether a colorscheme is dark or light. If you want it to know, declare it on the spec via `background = 'dark' | 'light'` (or per-variant via `backgrounds = { variant_name = 'dark' }`). When set, atelier writes `vim.o.background` before calling `:colorscheme`, so colorschemes that branch on `vim.o.background` get the right value at load time. As soon as *any* spec declares a background, the picker splits into `── Dark ──` / `── Light ──` / `── Auto ──` sections; until then it stays flat.

Pressing `B` flips the mode. If the *current* spec has a paired variant declared in the opposite mode (e.g. `backgrounds = { ['tokyonight-day'] = 'light', ['tokyonight-night'] = 'dark' }`), atelier switches to it directly — colorscheme and background flip together. Otherwise it just sets `vim.o.background` and lets you pick from the now-sorted section.

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

## License

MIT
