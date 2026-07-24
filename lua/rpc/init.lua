-- rpc.nvim — RPC request runner with response preview
--
-- Filetype: rpc          for request files (first line + metadata + body)
-- Filetype: rpc_response  for response preview (first line, metadata, body)
--
-- Usage:
--   require('rpc').setup({
--     build_request_command = function(first_line, metadata, body)
--       -- Build a command from the parsed request.
--       -- @param first_line  string                First line of the request (required)
--       -- @param metadata    table<string,list>    Metadata key→list of values
--       -- @param body        string|nil            Request body after blank-line separator
--       -- @return command   string[]              Argument list for vim.system
--       -- @return parse_fn  function              Response parser:
--       --   parse_fn(stdout) -> first_line (string), metadata (table), body (string)
--     end,
--   })
--   require('rpc').run_current()
--   Or map <CR> in rpc buffers to trigger it automatically.

local M = {}

local state = {
  preview_buf = nil,
  preview_win = nil,
  running = false,
  start_time = nil,
  build_fn = nil,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'rpc' })
end

local function trim(text)
  return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function is_blank(line)
  return line == nil or line:match '^%s*$' ~= nil
end

local function is_separator(line)
  return line ~= nil and line:match '^%s*###' ~= nil
end

local function is_comment(line)
  return line ~= nil and not is_separator(line) and line:match '^%s*#' ~= nil
end

--- ── Buffer / window helpers ──────────────────────────────────────────

local function ensure_preview_buffer()
  if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
    return state.preview_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.preview_buf = buf

  pcall(vim.api.nvim_buf_set_name, buf, 'rpc-response')

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = 'rpc_response'

  return buf
end

local function configure_preview_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].filetype == 'rpc_response' then
    vim.wo[win].foldmethod = 'indent'
  else
    vim.wo[win].foldmethod = 'expr'
    vim.wo[win].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
  end
  vim.wo[win].foldlevel = 99
end

local function resize_preview_equal(current_win)
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then
    return
  end
  if not vim.api.nvim_win_is_valid(current_win) or current_win == state.preview_win then
    return
  end

  local total_width = vim.api.nvim_win_get_width(current_win)
    + vim.api.nvim_win_get_width(state.preview_win)
  pcall(
    vim.api.nvim_win_set_width,
    state.preview_win,
    math.floor(total_width / 2)
  )
end

local function ensure_preview_window()
  local current_win = vim.api.nvim_get_current_win()
  local buf = ensure_preview_buffer()

  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    vim.api.nvim_win_set_buf(state.preview_win, buf)
    configure_preview_window(state.preview_win)
    resize_preview_equal(current_win)
    return buf
  end

  vim.cmd 'botright vsplit'
  state.preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.preview_win, buf)
  configure_preview_window(state.preview_win)
  vim.api.nvim_set_current_win(current_win)
  resize_preview_equal(current_win)

  return buf
end

--- ── Response display ─────────────────────────────────────────────────

local function set_preview_content(first_line, metadata, body)
  local buf = ensure_preview_window()

  local parts = {}
  table.insert(parts, first_line or '')

  if metadata then
    local keys = vim.tbl_keys(metadata)
    table.sort(keys)
    for _, key in ipairs(keys) do
      local values = metadata[key]
      if type(values) == 'table' then
        for _, value in ipairs(values) do
          table.insert(parts, key .. ': ' .. value)
        end
      else
        -- fallback for scalar values (defensive)
        table.insert(parts, key .. ': ' .. tostring(values))
      end
    end
  end

  table.insert(parts, '')
  table.insert(parts, body or '')

  local text = table.concat(parts, '\n')
  local lines = text == '' and { '' } or vim.split(text, '\n', { plain = true })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'rpc_response'
end

--- ── Request parsing ──────────────────────────────────────────────────

local function get_block_range(lines, cursor_line)
  local block_start
  if is_separator(lines[cursor_line]) then
    block_start = cursor_line + 1
  else
    local previous_separator = nil
    for line_nr = cursor_line, 1, -1 do
      if is_separator(lines[line_nr]) then
        previous_separator = line_nr
        break
      end
    end
    block_start = previous_separator and (previous_separator + 1) or 1
  end

  local next_separator = nil
  for line_nr = block_start, #lines do
    if is_separator(lines[line_nr]) then
      next_separator = line_nr
      break
    end
  end

  local block_end = next_separator and (next_separator - 1) or #lines

  while block_start <= block_end and is_blank(lines[block_start]) do
    block_start = block_start + 1
  end
  while block_end >= block_start and is_blank(lines[block_end]) do
    block_end = block_end - 1
  end

  if block_start > block_end then
    error 'empty request block'
  end

  return block_start, block_end
end

local function parse_metadata_line(line, line_nr)
  local key, value = line:match '^%s*([^:]+)%s*:%s*(.-)%s*$'
  if not key then
    error(('invalid metadata at line %d: %s'):format(line_nr, line))
  end
  return trim(key), trim(value)
end

--- Parse the request block under the cursor.
---
--- Returns `first_line, metadata, body_raw` where:
---   - first_line (string)  — first non-blank non-comment line (required)
---   - metadata   (table<string,list<string>>)
---   - body_raw   (string)
local function parse_current_request()
  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local block_start, block_end = get_block_range(lines, cursor_line)

  local block_lines = {}
  for line_nr = block_start, block_end do
    table.insert(block_lines, lines[line_nr])
  end

  -- Find the first blank line – it separates header (first line + metadata)
  -- from the optional body.
  local separator_idx = nil
  for idx, line in ipairs(block_lines) do
    if is_blank(line) then
      separator_idx = idx
      break
    end
  end

  local header_end = separator_idx and (separator_idx - 1) or #block_lines

  -- ── First line (required) ──────────────────────────────────────────
  local first_line = nil
  local first_line_idx = nil
  for idx = 1, header_end do
    local line = block_lines[idx]
    if not is_blank(line) and not is_comment(line) then
      first_line = line
      first_line_idx = idx
      break
    end
  end
  if not first_line then
    error 'missing required first line'
  end

  -- Validate first line has exactly two parts separated by whitespace
  -- e.g., "RPC SayHello" or "GET /path"
  local parts = vim.split(first_line, '%s+')
  if #parts ~= 2 then
    error(
      ('first line must have exactly two parts (e.g., "RPC SayHello"), got %d: %s')
      :format(#parts, first_line)
    )
  end

  -- ── Metadata (optional, duplicate keys → list) ─────────────────────
  local metadata = {}
  for idx = first_line_idx + 1, header_end do
    local line = block_lines[idx]
    if not is_blank(line) and not is_comment(line) then
      local key, value = parse_metadata_line(line, block_start + idx - 1)
      if not metadata[key] then
        metadata[key] = {}
      end
      table.insert(metadata[key], value)
    end
  end

  -- ── Body (optional) ────────────────────────────────────────────────
  local body_raw = ''
  if separator_idx then
    local body_lines = {}
    for idx = separator_idx + 1, #block_lines do
      table.insert(body_lines, block_lines[idx])
    end
    body_raw = table.concat(body_lines, '\n')
  end

  return first_line, metadata, body_raw
end

--- ── Setup (public API) ───────────────────────────────────────────────

--- Configure rpc.nvim with a user-provided command builder.
---
--- @param opts table  Must contain `build_request_command` function.
function M.setup(opts)
  if type(opts) ~= 'table' then
    error('rpc.setup() requires a table argument')
  end
  if type(opts.build_request_command) ~= 'function' then
    error('rpc.setup() requires build_request_command function')
  end
  state.build_fn = opts.build_request_command
end

--- ── Run current request ──────────────────────────────────────────────

function M.run_current()
  if state.running then
    notify('RPC request already running', vim.log.levels.WARN)
    return
  end

  if not state.build_fn then
    notify(
      'rpc.nvim: setup() has not been called. Use require("rpc").setup({...}).',
      vim.log.levels.ERROR
    )
    return
  end

  -- Parse the request buffer ──────────────────────────────────────────
  local ok, first_line, metadata, body_raw = pcall(parse_current_request)
  if not ok then
    notify(first_line, vim.log.levels.ERROR) -- first_line is the error string
    return
  end

  -- Build command + parse function ────────────────────────────────────
  local ok_build, result1, result2 = pcall(state.build_fn, first_line, metadata, body_raw)
  if not ok_build then
    notify(result1, vim.log.levels.ERROR)
    return
  end

  local command = result1
  local parse_fn = result2

  if type(command) ~= 'table' or #command == 0 then
    notify(
      'build_request_command must return a non-empty command array',
      vim.log.levels.ERROR
    )
    return
  end
  if type(parse_fn) ~= 'function' then
    notify(
      'build_request_command must return a parse function as second return value',
      vim.log.levels.ERROR
    )
    return
  end

  local executable = command[1]
  if vim.fn.executable(executable) == 0 then
    notify('rpc command is not executable: ' .. executable, vim.log.levels.ERROR)
    return
  end

  -- Execute ───────────────────────────────────────────────────────────
  state.running = true
  state.start_time = vim.loop.now()
  set_preview_content('', {}, '{"_status": "loading"}')

  local spawn_ok, spawn_err = pcall(
    vim.system,
    command,
    { stdin = body_raw, text = true },
    function(result)
      state.running = false
      vim.schedule(function()
        -- Parse the response via the user-provided parse function
        local ok_resp, resp_first_line, resp_metadata, resp_body =
          pcall(parse_fn, result.stdout or '')
        if not ok_resp then
          notify(
            'parse function error: ' .. tostring(resp_first_line),
            vim.log.levels.WARN
          )
          set_preview_content('', {}, result.stdout or '')
        else
          set_preview_content(resp_first_line, resp_metadata, resp_body)
        end

        -- Notify on non-zero exit or stderr output
        if result.code ~= 0 or (result.stderr and result.stderr ~= '') then
          local messages = {}
          if result.code ~= 0 then
            table.insert(messages, ('exit code: %d'):format(result.code))
          end
          if result.stderr and result.stderr ~= '' then
            table.insert(messages, result.stderr)
          end
          notify(
            table.concat(messages, '\n'),
            result.code ~= 0 and vim.log.levels.ERROR or vim.log.levels.WARN
          )
        end
      end)
    end
  )

  if not spawn_ok then
    state.running = false
    notify(spawn_err, vim.log.levels.ERROR)
  end
end

return M
