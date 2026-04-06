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

| Key       | Action                          |
|-----------|---------------------------------|
| `<CR>`    | Commit the previewed theme      |
| `q`/`<Esc>` | Cancel and restore the original |
| `I`       | Install missing                 |
| `U`       | Update all                      |
| `C`       | Clean unused                    |
| `R`       | Force redraw                    |

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
