-- rpc_runner.nvim — RPC request runner with response preview
--
-- Filetype: rpc          for request files (PSM/Method metadata + JSON body)
-- Filetype: rpc_response  for response preview (metadata headers + JSON body)
--
-- Usage:
--   require('rpc_runner').run_current()
--   Or map <CR> in rpc buffers to trigger it automatically.

local M = {}

local state = {
  preview_buf = nil,
  preview_win = nil,
  running = false,
  start_time = nil,
}

local DEFAULT_COMMAND = 'bam'

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'rpc_runner' })
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

local function is_metadata_comment(line)
  return line ~= nil and not is_separator(line) and line:match '^%s*#' ~= nil
end

local function get_command_prefix()
  local configured = vim.g.rpc_runner_command
  if configured == nil then return { DEFAULT_COMMAND } end
  if type(configured) == 'string' and configured ~= '' then return { configured } end
  if type(configured) == 'table' and #configured > 0 then return vim.deepcopy(configured) end
  error 'vim.g.rpc_runner_command is not configured'
end

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

local function set_preview_content(body, metadata)
  local buf = ensure_preview_window()

  local parts = {}
  if metadata then
    for _, kv in ipairs(metadata) do
      table.insert(parts, kv[1] .. ': ' .. kv[2])
    end
    table.insert(parts, '')
  end
  table.insert(parts, body or '')

  local text = table.concat(parts, '\n')
  local lines = text == '' and { '' } or vim.split(text, '\n', { plain = true })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'rpc_response'
end

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

local function parse_current_request()
  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local block_start, block_end = get_block_range(lines, cursor_line)

  local block_lines = {}
  for line_nr = block_start, block_end do
    table.insert(block_lines, lines[line_nr])
  end

  local separator_idx = nil
  for idx, line in ipairs(block_lines) do
    if is_blank(line) then
      separator_idx = idx
      break
    end
  end

  local metadata = {}
  local seen_keys = {}
  local metadata_end = separator_idx and (separator_idx - 1) or #block_lines

  for idx = 1, metadata_end do
    local line = block_lines[idx]
    if not is_metadata_comment(line) then
      local key, value = parse_metadata_line(line, block_start + idx - 1)
      if seen_keys[key] then error('duplicate metadata: ' .. key) end
      seen_keys[key] = true
      metadata[key] = value
    end
  end

  local psm = metadata.PSM
  local method = metadata.Method

  if not psm or psm == '' then error 'missing required metadata: PSM' end
  if not method or method == '' then error 'missing required metadata: Method' end

  local body_raw = ''
  if separator_idx then
    local body_lines = {}
    for idx = separator_idx + 1, #block_lines do
      table.insert(body_lines, block_lines[idx])
    end
    body_raw = table.concat(body_lines, '\n')
  end

  return {
    psm = psm,
    method = method,
    metadata = metadata,
    body_raw = body_raw,
    range = { start_line = block_start, end_line = block_end },
  }
end

local function build_bam_command(request)
  local metadata = request.metadata
  local command = get_command_prefix()
  local ignored = {}

  if metadata.IDLBranch and metadata.IDL_BRANCH and metadata.IDLBranch ~= metadata.IDL_BRANCH then
    error 'conflicting metadata: IDLBranch and IDL_BRANCH'
  end

  table.insert(command, request.psm)
  table.insert(command, request.method)
  table.insert(command, '-')

  if metadata.ENV and metadata.ENV ~= '' then
    table.insert(command, '--env')
    table.insert(command, metadata.ENV)
  end

  if metadata.IDC and metadata.IDC ~= '' then
    table.insert(command, '--idc')
    table.insert(command, metadata.IDC)
  end

  local idl_branch = metadata.IDLBranch or metadata.IDL_BRANCH
  if idl_branch and idl_branch ~= '' then
    table.insert(command, '--idl-branch')
    table.insert(command, idl_branch)
  end

  for key, _ in pairs(metadata) do
    if key ~= 'PSM' and key ~= 'Method' and key ~= 'ENV' and key ~= 'IDC' and key ~= 'IDLBranch' and key ~= 'IDL_BRANCH' then
      table.insert(ignored, key)
    end
  end
  table.sort(ignored)

  return command, ignored
end

function M.run_current()
  if state.running then
    notify('RPC request already running', vim.log.levels.WARN)
    return
  end

  local ok, request_or_err = pcall(parse_current_request)
  if not ok then
    notify(request_or_err, vim.log.levels.ERROR)
    return
  end

  local request = request_or_err
  local command_ok, command_or_err, ignored_metadata = pcall(build_bam_command, request)
  if not command_ok then
    notify(command_or_err, vim.log.levels.ERROR)
    return
  end

  local command = command_or_err
  local executable = command[1]
  if vim.fn.executable(executable) == 0 then
    notify('rpc command is not executable: ' .. executable, vim.log.levels.ERROR)
    return
  end

  if #ignored_metadata > 0 then
    notify('Ignored metadata: ' .. table.concat(ignored_metadata, ', '), vim.log.levels.WARN)
  end

  state.running = true
  state.start_time = vim.loop.now()
  set_preview_content('{"_status": "loading"}')

  local spawn_ok, spawn_err = pcall(vim.system, command, { stdin = request.body_raw, text = true }, function(result)
    state.running = false
    vim.schedule(function()
      local elapsed_ms = math.floor(vim.loop.now() - state.start_time)

      local metadata = {
        { 'Status', result.code == 0 and 'OK' or tostring(result.code) },
        { 'Latency', elapsed_ms .. 'ms' },
        { 'PSM', request.psm },
        { 'Method', request.method },
      }

      set_preview_content(result.stdout or '', metadata)

      if result.code ~= 0 or (result.stderr and result.stderr ~= '') then
        local messages = {}
        if result.code ~= 0 then
          table.insert(messages, ('exit code: %d'):format(result.code))
        end
        if result.stderr and result.stderr ~= '' then
          table.insert(messages, result.stderr)
        end
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
