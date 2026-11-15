-- lamaline.nvim: on-demand line completion using a local model (Ollama).
local M = {}

local defaults = {
  url = "http://localhost:11434/api/generate",
  model = "qwen2.5-coder:1.5b-base",
  -- Insert-mode keys that request and accept a completion. When both are the
  -- same key, it requests when nothing is shown and accepts otherwise.
  request_keymap = "<A-Space>",
  accept_keymap = "<A-Space>",
  -- Lines of context sent before and after the cursor.
  context_before = 100,
  context_after = 30,
  -- Start the prompt with a comment holding the file's path (relative to the
  -- git root or cwd), so the model knows the language and project layout.
  include_path = true,
  -- Add the most relevant snippets from other open buffers to the prompt.
  include_other_buffers = true,
  -- Tuning for include_other_buffers.
  other_buffers = {
    max_buffers = 3, -- snippets to include, one per buffer
    max_lines = 40, -- lines per snippet
    same_filetype = true, -- only use buffers with the current buffer's filetype
  },
  max_tokens = 64,
  temperature = 0.1,
  timeout = 10, -- seconds
  hl_group = "Comment",
}

M.config = vim.deepcopy(defaults)

local ns = vim.api.nvim_create_namespace("lamaline")

-- Current state: an in-flight request and/or a displayed suggestion.
local state = {
  request_id = 0,
  job = nil,
  suggestion = nil, -- { buf, row, col, text, extmark }
}

local function cancel_job()
  if state.job then
    pcall(function() state.job:kill(15) end)
    state.job = nil
  end
end

function M.clear()
  state.request_id = state.request_id + 1
  cancel_job()
  local s = state.suggestion
  if s and vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  end
  state.suggestion = nil
end

function M.is_visible()
  return state.suggestion ~= nil
end

-- A comment line like "-- Path: lua/lamaline/init.lua" for the buffer, or nil.
local function path_header(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local cs = vim.bo[buf].commentstring
  if name == "" or vim.bo[buf].buftype ~= "" or not cs:find("%s", 1, true) then
    return nil
  end
  local root = vim.fs.root(buf, ".git")
  local path
  if root and name:sub(1, #root + 1) == root .. "/" then
    path = name:sub(#root + 2)
  else
    path = vim.fn.fnamemodify(name, ":.")
    -- Outside the cwd: keep just "parent/file" rather than an absolute path.
    if path:sub(1, 1) == "/" then
      path = vim.fn.fnamemodify(name, ":h:t") .. "/" .. vim.fn.fnamemodify(name, ":t")
    end
  end
  -- Escape "%" in the path so gsub treats it literally.
  return (cs:gsub("%%s", (("Path: " .. path):gsub("%%", "%%%%"))))
end

-- Bounds on the work done looking through other buffers.
local MAX_CANDIDATES = 10
local MAX_SCAN_LINES = 5000

-- Keywords common to many languages; they say nothing about relevance.
local STOPWORDS = {}
for word in ([[
  and as break case class const continue def do elif else elseif end export
  false fn for from func function if import in is let local nil none not null
  or pass pub return self static then this true try type use var while with
]]):gmatch("%S+") do
  STOPWORDS[word] = true
end

local function tokens(lines)
  local set = {}
  for _, line in ipairs(lines) do
    for word in line:gmatch("[%w_]+") do
      if #word > 1 and not STOPWORDS[word:lower()] then
        set[word] = true
      end
    end
  end
  return set
end

local function jaccard(a, b)
  local inter, union = 0, 0
  for word in pairs(a) do
    union = union + 1
    if b[word] then inter = inter + 1 end
  end
  for word in pairs(b) do
    if not a[word] then union = union + 1 end
  end
  return union == 0 and 0 or inter / union
end

-- The window of `size` lines in buf most similar to `query`: score, lines.
local function best_window(buf, query, size)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, MAX_SCAN_LINES, false)
  local last_start = math.max(1, #lines - size + 1)
  local step = math.max(1, math.floor(size / 2))
  local best_score, best_start = 0, nil
  local start = 1
  while true do
    local score = jaccard(query, tokens(vim.list_slice(lines, start, start + size - 1)))
    if score > best_score then
      best_score, best_start = score, start
    end
    if start == last_start then break end
    start = math.min(start + step, last_start)
  end
  if not best_start then return nil end
  return best_score, vim.list_slice(lines, best_start, best_start + size - 1)
end

-- Lines holding the best-matching snippet of each relevant other buffer,
-- each under its path header, most relevant last (closest to the cursor).
local function other_buffer_snippets(buf, query_lines)
  local opts = M.config.other_buffers
  local query = tokens(query_lines)
  local filetype = vim.bo[buf].filetype

  local infos = vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })
  table.sort(infos, function(a, b) return a.lastused > b.lastused end)

  local scored, candidates = {}, 0
  for _, info in ipairs(infos) do
    local b = info.bufnr
    if b ~= buf and vim.bo[b].buftype == ""
      and (not opts.same_filetype or vim.bo[b].filetype == filetype) then
      local header = path_header(b)
      if header then
        candidates = candidates + 1
        local score, lines = best_window(b, query, opts.max_lines)
        if score then
          table.insert(scored, { score = score, header = header, lines = lines })
        end
        if candidates >= MAX_CANDIDATES then break end
      end
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)

  local out = {}
  for i = math.min(#scored, opts.max_buffers), 1, -1 do
    table.insert(out, scored[i].header)
    vim.list_extend(out, scored[i].lines)
    table.insert(out, "")
  end
  return out
end

local function get_context(buf, row, col)
  local cfg = M.config
  local first = math.max(0, row - cfg.context_before)
  local last = math.min(vim.api.nvim_buf_line_count(buf), row + 1 + cfg.context_after)
  local before = vim.api.nvim_buf_get_lines(buf, first, row, false)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local after = vim.api.nvim_buf_get_lines(buf, row + 1, last, false)

  table.insert(before, line:sub(1, col))

  local snippets = {}
  if cfg.include_other_buffers and cfg.other_buffers then
    local query = vim.list_slice(before, math.max(1, #before - cfg.other_buffers.max_lines + 1))
    snippets = other_buffer_snippets(buf, query)
  end
  -- The current file needs its header to be told apart from the snippets.
  if cfg.include_path or #snippets > 0 then
    local header = path_header(buf)
    if header then
      table.insert(before, 1, header)
    end
  end
  before = vim.list_extend(snippets, before)
  local suffix_lines = { line:sub(col + 1) }
  vim.list_extend(suffix_lines, after)
  return table.concat(before, "\n"), table.concat(suffix_lines, "\n"), line:sub(col + 1)
end

-- Reduce the raw model output to a single line that fits at the cursor.
local function clean(text, rest_of_line)
  text = text:gsub("\r", "")
  text = text:match("^[^\n]*") or ""
  -- Drop text the model repeats from what already follows the cursor.
  if rest_of_line ~= "" then
    local idx = text:find(rest_of_line, 1, true)
    if idx and idx + #rest_of_line - 1 == #text then
      text = text:sub(1, idx - 1)
    end
  end
  return text:gsub("%s+$", "")
end

local function show(buf, row, col, text)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local extmark = vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
    virt_text = { { text, M.config.hl_group } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  })
  state.suggestion = { buf = buf, row = row, col = col, text = text, extmark = extmark }
end

function M.request()
  M.clear()
  local cfg = M.config
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local prefix, suffix, rest_of_line = get_context(buf, row, col)

  local body = vim.json.encode({
    model = cfg.model,
    prompt = prefix,
    suffix = suffix,
    stream = false,
    options = {
      num_predict = cfg.max_tokens,
      temperature = cfg.temperature,
      stop = { "\n" },
    },
  })

  local id = state.request_id
  local ok, job = pcall(vim.system, {
    "curl", "-sS", "--max-time", tostring(cfg.timeout),
    "-H", "Content-Type: application/json",
    "-d", "@-", cfg.url,
  }, { stdin = body, text = true }, function(res)
    vim.schedule(function()
      if id ~= state.request_id then return end -- stale or cancelled
      state.job = nil
      if res.code ~= 0 then
        if res.signal == 0 then
          vim.notify("lamaline: request failed: " .. vim.trim(res.stderr or ""), vim.log.levels.WARN)
        end
        return
      end
      local decoded_ok, decoded = pcall(vim.json.decode, res.stdout)
      if not decoded_ok or type(decoded) ~= "table" then
        vim.notify("lamaline: invalid response from model server", vim.log.levels.WARN)
        return
      end
      if decoded.error then
        vim.notify("lamaline: " .. tostring(decoded.error), vim.log.levels.WARN)
        return
      end
      -- Only show if the user is still where they asked.
      local cur = vim.api.nvim_win_get_cursor(0)
      if vim.api.nvim_get_current_buf() ~= buf or cur[1] - 1 ~= row or cur[2] ~= col then
        return
      end
      if not vim.fn.mode():match("^i") then return end
      local text = clean(decoded.response or "", rest_of_line)
      if text ~= "" then
        show(buf, row, col, text)
      end
    end)
  end)
  if not ok then
    vim.notify("lamaline: could not start curl: " .. tostring(job), vim.log.levels.ERROR)
    return
  end
  state.job = job
end

function M.accept()
  local s = state.suggestion
  if not s then return false end
  M.clear()
  if not vim.api.nvim_buf_is_valid(s.buf) then return false end
  vim.api.nvim_buf_set_text(s.buf, s.row, s.col, s.row, s.col, { s.text })
  vim.api.nvim_win_set_cursor(0, { s.row + 1, s.col + #s.text })
  return true
end

-- Accept if a suggestion is shown, otherwise request one.
function M.trigger()
  if not M.accept() then
    M.request()
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  local cfg = M.config

  local function termcodes(key)
    return key and vim.api.nvim_replace_termcodes(key, true, true, true)
  end
  if cfg.request_keymap and termcodes(cfg.request_keymap) == termcodes(cfg.accept_keymap) then
    vim.keymap.set("i", cfg.request_keymap, M.trigger, { desc = "lamaline: complete / accept line" })
  else
    if cfg.request_keymap then
      vim.keymap.set("i", cfg.request_keymap, M.request, { desc = "lamaline: complete line" })
    end
    if cfg.accept_keymap then
      vim.keymap.set("i", cfg.accept_keymap, function()
        if not M.accept() then
          -- Nothing to accept: let the key do what it normally does.
          vim.api.nvim_feedkeys(termcodes(cfg.accept_keymap), "n", false)
        end
      end, { desc = "lamaline: accept completion" })
    end
  end

  local group = vim.api.nvim_create_augroup("lamaline", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI", "InsertLeave", "BufLeave" }, {
    group = group,
    callback = function()
      if state.suggestion or state.job then
        M.clear()
      end
    end,
  })

  -- Any other key the user types rejects the suggestion (or cancels the
  -- pending request), even ones that neither move the cursor nor edit.
  local own_keys = { [termcodes(cfg.request_keymap) or ""] = true, [termcodes(cfg.accept_keymap) or ""] = true }
  vim.on_key(function(_, typed)
    if typed and typed ~= "" and not own_keys[typed] and (state.suggestion or state.job) then
      vim.schedule(M.clear)
    end
  end, ns)

  vim.api.nvim_create_user_command("LamalineComplete", M.request, { desc = "Request a line completion" })
end

return M
