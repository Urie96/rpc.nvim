-- rpc.nvim — RPC request runner with response preview
--
-- Filetype: rpc          for request files (first line + metadata + body)
-- Filetype: rpc_response  for response preview (first line, metadata, body)
--
-- Usage:
--   require('rpc').run_current()
--   Or override the default curl builder:
--   require('rpc').setup({
--     build_request_command = function(first_line, metadata, body)
--       -- Build a command from the parsed request.
--       -- @param first_line  string                First line of the request (required)
--       -- @param metadata    table<string,list>    Metadata key->list of values
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
  inspect_buf = nil,
  inspect_win = nil,
  running = false,
  start_time = nil,
  build_fn = nil,
}

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = 'rpc' }) end

local function trim(text) return (text:gsub('^%s+', ''):gsub('%s+$', '')) end

local function is_blank(line) return line == nil or line:match '^%s*$' ~= nil end

local function is_separator(line) return line ~= nil and line:match '^%s*###' ~= nil end

local function is_comment(line) return line ~= nil and not is_separator(line) and line:match '^%s*#' ~= nil end

--- ── Buffer / window helpers ──────────────────────────────────────────

local function ensure_preview_buffer()
  if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then return state.preview_buf end

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
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then return end
  if not vim.api.nvim_win_is_valid(current_win) or current_win == state.preview_win then return end

  local total_width = vim.api.nvim_win_get_width(current_win) + vim.api.nvim_win_get_width(state.preview_win)
  pcall(vim.api.nvim_win_set_width, state.preview_win, math.floor(total_width / 2))
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

local function ensure_inspect_buffer()
  if state.inspect_buf and vim.api.nvim_buf_is_valid(state.inspect_buf) then return state.inspect_buf end

  local buf = vim.api.nvim_create_buf(false, true)
  state.inspect_buf = buf

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = 'bash'

  return buf
end

local function normalize_buffer_lines(lines)
  local normalized = {}

  for _, line in ipairs(lines) do
    local text = tostring(line):gsub('\r\n', '\n'):gsub('\r', '\n')
    for _, split_line in ipairs(vim.split(text, '\n', { plain = true })) do
      table.insert(normalized, split_line)
    end
  end

  return #normalized == 0 and { '' } or normalized
end

local function open_inspect_window(lines)
  lines = normalize_buffer_lines(lines)

  if state.inspect_win and vim.api.nvim_win_is_valid(state.inspect_win) then
    pcall(vim.api.nvim_win_close, state.inspect_win, true)
  end

  local buf = ensure_inspect_buffer()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  --- Fixed generous sizing for the inspect window.
  local width = math.max(60, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.9)))
  local height = math.max(8, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.8)))

  state.inspect_win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' request_command ',
    title_pos = 'center',
  })

  vim.wo[state.inspect_win].wrap = true
  vim.wo[state.inspect_win].cursorline = true

  -- Close with q or <Esc>
  vim.keymap.set('n', 'q', function()
    if state.inspect_win and vim.api.nvim_win_is_valid(state.inspect_win) then
      vim.api.nvim_win_close(state.inspect_win, true)
      state.inspect_win = nil
    end
  end, { buffer = buf, silent = true, nowait = true, desc = 'Close inspect window' })

  vim.keymap.set('n', '<Esc>', function()
    if state.inspect_win and vim.api.nvim_win_is_valid(state.inspect_win) then
      vim.api.nvim_win_close(state.inspect_win, true)
      state.inspect_win = nil
    end
  end, { buffer = buf, silent = true, nowait = true, desc = 'Close inspect window' })
end

--- ── Default curl command builder ─────────────────────────────────────

local function parse_curl_headers(header_text)
  local lines = vim.split(header_text, '\n', { plain = true })
  local first_line = lines[1] or ''
  local metadata = {}

  for idx = 2, #lines do
    local line = lines[idx]
    if line ~= '' then
      local key, value = line:match '^([^:]+):%s*(.*)$'
      if key then
        key = trim(key)
        if not metadata[key] then metadata[key] = {} end
        table.insert(metadata[key], trim(value))
      end
    end
  end

  return first_line, metadata
end

local function is_curl_header_block(header_text)
  if not header_text:match '^HTTP/%S+%s+%d%d%d' then return false end

  local lines = vim.split(header_text, '\n', { plain = true })
  for idx = 2, #lines do
    local line = lines[idx]
    if line ~= '' and not line:match '^[^:]+:' then return false end
  end

  return true
end

local function parse_curl_response(stdout)
  local text = (stdout or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local header_text, body = text:match '^(.-)\n\n(.*)$'

  if not header_text or not is_curl_header_block(header_text) then return '', {}, text end

  while true do
    local next_header_text, next_body = body:match '^(.-)\n\n(.*)$'
    if not next_header_text or not is_curl_header_block(next_header_text) then break end
    header_text = next_header_text
    body = next_body
  end

  local first_line, metadata = parse_curl_headers(header_text)
  return first_line, metadata, body
end

--- Build a curl command for a parsed request block.
---
--- The request first line must be `METHOD URL`. Metadata entries are sent as
--- HTTP headers, and a non-empty body is passed as a command-line argument.
---
--- @param first_line string
--- @param metadata table<string,list<string>>
--- @param body string|nil
--- @return string[] command
--- @return function parse_fn
function M.build_curl_command(first_line, metadata, body)
  local method, url = first_line:match '^(%S+)%s+(%S+)$'
  if not method or not url then error 'curl builder requires first line in the form: METHOD URL' end

  local command = { 'curl', '-sS', '-i', '-X', method }

  local keys = vim.tbl_keys(metadata or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    local values = metadata[key]
    if type(values) == 'table' then
      for _, value in ipairs(values) do
        table.insert(command, '-H')
        table.insert(command, key .. ': ' .. value)
      end
    else
      table.insert(command, '-H')
      table.insert(command, key .. ': ' .. tostring(values))
    end
  end

  if body and body ~= '' then
    table.insert(command, '--data-raw')
    table.insert(command, body)
  end

  table.insert(command, url)

  return command, parse_curl_response
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

  if block_start > block_end then error 'empty request block' end

  return block_start, block_end
end

local function parse_metadata_line(line, line_nr)
  local key, value = line:match '^%s*([^:]+)%s*:%s*(.-)%s*$'
  if not key then error(('invalid metadata at line %d: %s'):format(line_nr, line)) end
  return trim(key), trim(value)
end

local function decode_basic_variable_escapes(value)
  local escapes = {
    n = '\n',
    r = '\r',
    t = '\t',
    ['"'] = '"',
    ["'"] = "'",
    ['\\'] = '\\',
  }

  return (value:gsub('\\(.)', function(char) return escapes[char] or ('\\' .. char) end))
end

local function parse_variable_value(raw_value, line_nr)
  local value = trim(raw_value)
  local quote = value:sub(1, 1)

  if quote == '"' then
    local ok, decoded = pcall(vim.json.decode, value)
    if not ok or type(decoded) ~= 'string' then
      error(('invalid quoted variable value at line %d: %s'):format(line_nr, value))
    end
    return decoded
  end

  if quote == "'" then
    if value:sub(-1) ~= "'" then error(('invalid quoted variable value at line %d: %s'):format(line_nr, value)) end
    return decode_basic_variable_escapes(value:sub(2, -2))
  end

  return decode_basic_variable_escapes(value)
end

local function parse_variable_declaration(line, line_nr)
  local name, value = line:match '^%s*@([%w_.%-]+)%s*=%s*(.-)%s*$'
  if name then return name, parse_variable_value(value, line_nr) end
  if line:match '^%s*@' then error(('invalid variable declaration at line %d: %s'):format(line_nr, line)) end
  return nil, nil
end

local function is_variable_declaration(line) return line ~= nil and line:match '^%s*@[%w_.%-]+%s*=' ~= nil end

local function replace_variables_in_text(text, variables, unresolved_variables)
  if text == nil then return nil end

  return (
    text:gsub('({{%s*([%w_.%-]+)%s*}})', function(placeholder, name)
      local value = variables[name]
      if value == nil then
        -- Fall back to system environment variables
        value = vim.env[name]
      end
      if value == nil then
        unresolved_variables[name] = true
        return placeholder
      end
      return value
    end)
  )
end

local function collect_variable_declarations(lines, start_line, end_line, variables, unresolved_variables)
  while start_line <= end_line and is_blank(lines[start_line]) do
    start_line = start_line + 1
  end
  while end_line >= start_line and is_blank(lines[end_line]) do
    end_line = end_line - 1
  end

  local header_end = end_line
  for line_nr = start_line, end_line do
    if is_blank(lines[line_nr]) then
      header_end = line_nr - 1
      break
    end
  end

  for line_nr = start_line, header_end do
    local line = lines[line_nr]
    if not is_comment(line) then
      local name, value = parse_variable_declaration(line, line_nr)
      if name then variables[name] = replace_variables_in_text(value, variables, unresolved_variables) end
    end
  end
end

local function collect_variables(lines, block_start, block_header_end)
  local variables = {}
  local unresolved_variables = {}
  local first_separator = nil

  for line_nr = 1, #lines do
    if is_separator(lines[line_nr]) then
      first_separator = line_nr
      break
    end
  end

  if first_separator and first_separator > 1 then
    collect_variable_declarations(lines, 1, first_separator - 1, variables, unresolved_variables)
  end

  collect_variable_declarations(lines, block_start, block_header_end, variables, unresolved_variables)

  return variables, unresolved_variables
end

local function replace_variables_in_lines(lines, variables, unresolved_variables)
  local replaced_lines = {}
  for _, line in ipairs(lines) do
    local replaced = replace_variables_in_text(line, variables, unresolved_variables)
    for _, replaced_line in ipairs(vim.split(replaced, '\n', { plain = true })) do
      table.insert(replaced_lines, replaced_line)
    end
  end
  return replaced_lines
end

--- Parse the request block under the cursor.
---
--- Returns `first_line, metadata, body_raw, unresolved_variables` where:
---   - first_line (string)  — first non-blank non-comment line (required)
---   - metadata   (table<string,list<string>>)
---   - body_raw   (string)
---   - unresolved_variables (table<string,true>)
local function parse_current_request()
  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local block_start, block_end = get_block_range(lines, cursor_line)

  local block_lines = {}
  for line_nr = block_start, block_end do
    table.insert(block_lines, lines[line_nr])
  end

  -- Collect variables from the original header range, then expand before
  -- parsing the request. Expansion may introduce new header/body lines.
  local original_separator_idx = nil
  for idx, line in ipairs(block_lines) do
    if is_blank(line) then
      original_separator_idx = idx
      break
    end
  end

  local original_header_end = original_separator_idx and (original_separator_idx - 1) or #block_lines
  local variables, unresolved_variables = collect_variables(lines, block_start, block_start + original_header_end - 1)
  block_lines = replace_variables_in_lines(block_lines, variables, unresolved_variables)

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
    if not is_blank(line) and not is_comment(line) and not is_variable_declaration(line) then
      first_line = line
      first_line_idx = idx
      break
    end
  end
  if not first_line then error 'missing required first line' end

  -- Validate first line has exactly two parts separated by whitespace
  -- e.g., "RPC SayHello" or "GET /path"
  local parts = vim.split(first_line, '%s+')
  if #parts ~= 2 then
    error(('first line must have exactly two parts (e.g., "RPC SayHello"), got %d: %s'):format(#parts, first_line))
  end

  -- ── Metadata (optional, duplicate keys → list) ─────────────────────
  local metadata = {}
  for idx = first_line_idx + 1, header_end do
    local line = block_lines[idx]
    if not is_blank(line) and not is_comment(line) and not is_variable_declaration(line) then
      local key, value = parse_metadata_line(line, block_start + idx - 1)
      if not metadata[key] then metadata[key] = {} end
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

  return first_line, metadata, body_raw, unresolved_variables
end

--- ── Setup (public API) ───────────────────────────────────────────────

--- Configure rpc.nvim with an optional user-provided command builder.
---
--- @param opts table|nil  May contain `build_request_command` function.
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error 'rpc.setup() requires a table argument' end
  if opts.build_request_command ~= nil and type(opts.build_request_command) ~= 'function' then
    error 'rpc.setup() requires build_request_command to be a function'
  end
  state.build_fn = opts.build_request_command or M.build_curl_command
end

local function notify_unresolved_variables(unresolved_variables)
  local unresolved_names = vim.tbl_keys(unresolved_variables or {})
  table.sort(unresolved_names)
  if #unresolved_names > 0 then
    notify('undefined variable(s): ' .. table.concat(unresolved_names, ', '), vim.log.levels.WARN)
  end
end

local function build_current_request()
  local build_fn = state.build_fn or M.build_curl_command

  local first_line, metadata, body_raw, unresolved_variables = parse_current_request()
  notify_unresolved_variables(unresolved_variables)

  local command, parse_fn = build_fn(first_line, metadata, body_raw)

  if type(command) ~= 'table' or #command == 0 then
    error 'build_request_command must return a non-empty command array'
  end
  if type(parse_fn) ~= 'function' then
    error 'build_request_command must return a parse function as second return value'
  end

  return command, parse_fn
end

local function command_to_inspect_lines(command)
  local shell_parts = {}
  for _, arg in ipairs(command) do
    table.insert(shell_parts, vim.fn.shellescape(tostring(arg)))
  end

  return { table.concat(shell_parts, ' ') }
end

function M.inspect_current()
  local ok, command_or_err = pcall(build_current_request)
  if not ok then
    notify(command_or_err, vim.log.levels.ERROR)
    return
  end

  open_inspect_window(command_to_inspect_lines(command_or_err))
end

--- Show the generated request command in the response/preview window.
function M.inspect_in_response()
  local ok, command_or_err = pcall(build_current_request)
  if not ok then
    notify(command_or_err, vim.log.levels.ERROR)
    return
  end

  local shell_line = table.concat(
    vim.tbl_map(function(arg) return vim.fn.shellescape(tostring(arg)) end, command_or_err),
    ' '
  )

  set_preview_content('', {}, shell_line)
end

--- ── Run current request ──────────────────────────────────────────────

function M.run_current()
  if state.running then
    notify('RPC request already running', vim.log.levels.WARN)
    return
  end

  local ok_build, command, parse_fn = pcall(build_current_request)
  if not ok_build then
    notify(command, vim.log.levels.ERROR)
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

  local spawn_ok, spawn_err = pcall(vim.system, command, { text = true }, function(result)
    state.running = false
    vim.schedule(function()
      -- Parse the response via the user-provided parse function
      local ok_resp, resp_first_line, resp_metadata, resp_body = pcall(parse_fn, result.stdout or '')
      if not ok_resp then
        notify('parse function error: ' .. tostring(resp_first_line), vim.log.levels.WARN)
        set_preview_content('', {}, result.stdout or '')
      else
        set_preview_content(resp_first_line, resp_metadata, resp_body)
      end

      -- Notify on non-zero exit or stderr output
      if result.code ~= 0 or (result.stderr and result.stderr ~= '') then
        local messages = {}
        if result.code ~= 0 then table.insert(messages, ('exit code: %d'):format(result.code)) end
        if result.stderr and result.stderr ~= '' then table.insert(messages, result.stderr) end
        notify(table.concat(messages, '\n'), result.code ~= 0 and vim.log.levels.ERROR or vim.log.levels.WARN)
      end
    end)
  end)

  if not spawn_ok then
    state.running = false
    notify(spawn_err, vim.log.levels.ERROR)
  end
end

return M
