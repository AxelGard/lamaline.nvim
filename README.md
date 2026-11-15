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
Typing or moving the cursor also dismisses it. `:LamalineComplete` requests a completion too.

## Configuration

Defaults:

```lua
require("lamaline").setup({
  url = "http://localhost:11434/api/generate",
  model = "qwen2.5-coder:1.5b-base",
  keymap = "<A-Space>",      -- request / accept
  dismiss_keymap = "<A-e>",  -- false to disable
  context_before = 100,      -- lines of context before the cursor
  context_after = 30,        -- lines of context after the cursor
  max_tokens = 64,
  temperature = 0.1,
  timeout = 10,              -- seconds
  hl_group = "Comment",      -- highlight for the ghost text
})
```
