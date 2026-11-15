# lamaline.nvim
a neovim plugin for line completion using a local model.

Completions are only requested when you press a key — nothing runs while you type.

## Requirements

- Neovim 0.10+
- `curl`
- [Ollama](https://ollama.com) with a model that supports fill-in-the-middle, e.g.

  ```sh
  ollama pull qwen2.5-coder:1.5b-base
  ```

## Install

lazy.nvim:

```lua
{
  "AxelGard/lamaline.nvim",
  opts = {},
}
```

Or call `require("lamaline").setup({})` yourself.

## Usage

In insert mode:

| Key         | Action                                              |
|-------------|-----------------------------------------------------|
| `<A-Space>` | Request a completion for the current line           |
| `<A-Space>` | Accept the shown completion (pressed again)         |
| `<A-e>`     | Dismiss the completion                              |

Alt keys need your terminal to send Option as Alt (e.g. Ghostty `macos-option-as-alt = left`).
`request_keymap` and `accept_keymap` can be set to different keys (any of them can be `false`).
A separate accept key keeps its normal behaviour when no completion is shown, so e.g. `<Tab>` still indents.
Typing or moving the cursor also dismisses it. `:LamalineComplete` requests a completion too.

## Configuration

Defaults:

```lua
require("lamaline").setup({
  url = "http://localhost:11434/api/generate",
  model = "qwen2.5-coder:1.5b-base",
  request_keymap = "<A-Space>", -- request a completion
  accept_keymap = "<A-Space>",  -- accept it (same key as request: toggles)
  dismiss_keymap = "<A-e>",  -- false to disable
  context_before = 100,      -- lines of context before the cursor
  context_after = 30,        -- lines of context after the cursor
  include_path = true,       -- tell the model the file's path (see below)
  max_tokens = 64,
  temperature = 0.1,
  timeout = 10,              -- seconds
  hl_group = "Comment",      -- highlight for the ghost text
})
```

### File path context

With `include_path` on, the prompt starts with a comment holding the file's
path, written in the buffer's `commentstring`. The path is relative to the
git root, or the cwd, or just `parent/file` when the file is outside both:

```lua
-- Path: lua/lamaline/init.lua
```

This helps the model pick the right language and conventions when the code
around the cursor is ambiguous (short files, the top of a file, `.h`, `.ts`
vs `.js`, ...). The comment is only sent to the model, never inserted.

