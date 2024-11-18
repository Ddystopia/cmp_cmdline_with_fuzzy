-- fuzzy_path.lua

local log = require('cmp_cmdline.dlog').logger("fuzzy_path")
local matcher = require('fuzzy_nvim')

-- Default options
local DEFAULT_OPTION = {
  fd_cmd = { 'fd', '-d', '20', '-p', '-i' },
  fd_timeout_msec = 1500,
  blocking = false,
}

-- Function to find the current working directory based on the pattern
local function find_cwd(pattern)
  local dname = string.gsub(pattern, '(.*[/\\])(.*)', '%1')
  local basename = string.gsub(pattern, '(.*[/\\])(.*)', '%2')
  if dname == nil or #dname == 0 or basename == dname then
    return pattern, vim.fn.getcwd(), ''
  else
    local cwd = vim.fs.normalize(vim.fn.resolve(vim.fs.normalize(dname)))
    return basename, cwd, dname
  end
end

-- Function to get file system statistics
local function stat(path)
  local stat = vim.loop.fs_stat(path)
  if stat and stat.type then
    return stat
  end
  return nil
end

-- Function to execute the 'fd' command, either synchronously or asynchronously
local function execute_fd(cmd, cwd, blocking, callback)
  log("Executing fd command: %s in cwd: %s", table.concat(cmd, ' '), cwd)
  if blocking then
    -- Synchronous execution
    local output = vim.fn.systemlist(cmd, cwd)
    if vim.v.shell_error ~= 0 then
      log("fd command failed with error code: %s", vim.v.shell_error)
      return {}
    end
    return output
  else
    -- Asynchronous execution using vim.fn.jobstart
    local items = {}
    local job = vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      cwd = cwd,
      on_exit = function(_, code)
        if code ~= 0 then
          log("fd command exited with code: %d", code)
          callback({})
        else
          callback(items)
        end
      end,
      on_stdout = function(_, lines)
        for _, line in ipairs(lines) do
          table.insert(items, line)
        end
      end,
    })

    -- Wait for the job to finish or timeout
    local timeout = DEFAULT_OPTION.fd_timeout_msec
    local wait_result = vim.fn.jobwait({ job }, timeout)
    if wait_result[1] == -1 then
      log("fd command timed out after %d ms", timeout)
      vim.fn.jobstop(job)
    end
    return items
  end
end

-- Function to build completion items from 'fd' output
local function build_items(output, cwd, prefix, new_pattern, filterText)
  local items = {}
  for _, line in ipairs(output) do
    -- Remove './' from beginning
    line = line:gsub([[^%./]], '')
    if #line > 0 then
      local full_path = cwd .. '/' .. line
      local fstat = stat(full_path)
      local kind = nil
      if fstat then
        if fstat.type == 'directory' then
          kind = vim.lsp.protocol.CompletionItemKind.Folder
        elseif fstat.type == 'file' then
          kind = vim.lsp.protocol.CompletionItemKind.File
        end
      end
      local score = nil
      if #new_pattern == 0 then
        score = 10
      else
        local matches = matcher:filter(new_pattern, { line })
        if #(matches or {}) > 0 then
          score = matches[1][3]
        end
      end
      if score ~= nil then
        local item = {
          label = prefix .. line,
          kind = kind,
          -- Data is for the compare function
          data = { path = full_path, stat = fstat, score = score },
          -- Hack cmp to not filter our fuzzy matches
          filterText = filterText,
        }
        log("Adding item [%s]", vim.print(item))
        table.insert(items, item)
      end
    end
  end
  return items
end

local function strip_e_and_trim(input)
    -- Remove leading 'e' (if present)
    local stripped = input:gsub("^e", "")
    -- Trim leading and trailing whitespace
    local trimmed = stripped:match("^%s*(.-)%s*$")
    return trimmed
end

-- Definition for fuzzy path completion
local fuzzy_definition = {
  ctype = 'cmdline',
  regex = [=[e *[^[:blank:]]*$]=],
  kind = vim.lsp.protocol.CompletionItemKind.File,
  isIncomplete = true,
  exec = function(option, arglead, cmdline, force)
    arglead = strip_e_and_trim(arglead)
    log("Starting fuzzy_path exec with arglead: %s", arglead)
    option = vim.tbl_deep_extend('keep', option or {}, DEFAULT_OPTION)
    local pattern = arglead

    local new_pattern, cwd, prefix = find_cwd(pattern)
    log("new_pattern: %s, cwd: %s, prefix: %s", new_pattern, cwd, prefix)

    -- Check if the current working directory is valid
    local fstat = stat(cwd)
    if not fstat or fstat.type ~= 'directory' then
      log("Invalid cwd: %s", cwd)
      return {}
    end

    -- Prepare the 'fd' command
    local cmd = { unpack(option.fd_cmd) }

    -- Adjust depth if cwd is root
    if cwd == '/' and cmd[1] == 'fd' then
      local new_cmd = {}
      local skip = false
      for _, value in ipairs(cmd) do
        if not skip then
          if value == '-d' or value == '--max-depth' then
            skip = true
          else
            table.insert(new_cmd, value)
          end
        else
          skip = false
        end
      end
      table.insert(new_cmd, '-d')
      table.insert(new_cmd, '1')
      cmd = new_cmd
    end

    -- Build the search pattern for 'fd'
    if #new_pattern > 0 then
      local path_regex = string.gsub(new_pattern, '(.)', '%1.*')
      table.insert(cmd, path_regex)
    end

    local filterText = string.sub(cmdline, -#arglead)

    local items = {}
    if option.blocking then
      -- Synchronous execution
      local output = execute_fd(cmd, cwd, true)
      items = build_items(output, cwd, prefix, new_pattern, filterText)
      log("Found %d items (blocking)", #items)
      return items
    else
      -- Asynchronous execution
      local async_items = {}
      local done = false
      execute_fd(cmd, cwd, false, function(output)
        async_items = build_items(output, cwd, prefix, new_pattern, filterText)
        done = true
        log("Found %d items (async)", #async_items)
      end)
      -- Wait for the asynchronous execution to finish or timeout
      local timeout = option.fd_timeout_msec
      local start_time = vim.loop.hrtime()
      while not done and (vim.loop.hrtime() - start_time) / 1e6 < timeout do
        vim.wait(30)
      end
      if not done then
        log("Asynchronous fd command timed out after %d ms", timeout)
        return {}
      end
      return async_items
    end
  end,
}

return fuzzy_definition

