local Promise = require('opencode.promise')
local log = require('opencode.log')

---@class PiServer
---@field handle uv_process_t|nil
---@field stdin uv_pipe_t|nil
---@field stdout uv_pipe_t|nil
---@field stderr uv_pipe_t|nil
---@field pid integer|nil
---@field is_ready boolean
---@field pending_commands table<string, Promise>
---@field event_callbacks fun(event:table)[]
---@field buffer string
---@field shutdown_promise Promise<boolean>
---@field spawn_promise Promise<PiServer>
local PiServer = {}
PiServer.__index = PiServer

function PiServer.new()
  return setmetatable({
    handle = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    pid = nil,
    is_ready = false,
    pending_commands = {},
    event_callbacks = {},
    buffer = '',
    shutdown_promise = Promise.new(),
    spawn_promise = Promise.new(),
  }, PiServer)
end

---@param cmd string[]
---@param opts? {cwd?: string, on_ready?: fun(server: PiServer), on_error?: fun(err: string), on_exit?: fun(code: integer, signal: integer)}
---@return Promise<PiServer>
function PiServer:spawn(cmd, opts)
  opts = opts or {}

  log.info('pi server: spawning with cmd: %s', vim.inspect(cmd))

  local startup_stderr = {}
  local startup_failed = false

  local function fail_startup(err)
    if startup_failed or self.is_ready then
      return
    end
    startup_failed = true
    self.spawn_promise:reject(err)
    if opts.on_error then
      opts.on_error(err)
    end
  end

  local stdin = vim.uv.new_pipe(false)
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)

  if not stdin or not stdout or not stderr then
    fail_startup('Failed to create pipes for pi process')
    return self.spawn_promise
  end

  self.stdin = stdin
  self.stdout = stdout
  self.stderr = stderr

  local spawn_opts = {
    stdio = { stdin, stdout, stderr },
    args = vim.list_slice(cmd, 2),
    cwd = opts.cwd,
  }

  local handle, pid = vim.uv.spawn(cmd[1], spawn_opts, function(code, signal)
    if not self.is_ready and not startup_failed then
      local stderr_output = table.concat(startup_stderr, '')
      local msg = stderr_output ~= '' and stderr_output
        or string.format('pi process exited unexpectedly (code=%s, signal=%s)', tostring(code), tostring(signal))
      fail_startup(msg)
    end
    self:_on_exit(code, signal)
    if opts.on_exit then
      opts.on_exit(code or 0, signal or 0)
    end
    self.shutdown_promise:resolve(true)
  end)

  if not handle then
    fail_startup('Failed to spawn pi process')
    return self.spawn_promise
  end

  self.handle = handle
  self.pid = pid

  -- Start reading stdout
  stdout:read_start(function(err, data)
    if err then
      log.error('pi server stdout error: %s', tostring(err))
      return
    end
    if data then
      log.debug('pi server stdout raw: %q', data)
      self:_on_stdout(data)
    end
  end)

  -- Start reading stderr
  stderr:read_start(function(err, data)
    if err then
      log.error('pi server stderr error: %s', tostring(err))
      return
    end
    if data and data ~= '' then
      table.insert(startup_stderr, data)
      log.info('pi server stderr: %s', vim.trim(data))
    end
  end)

  -- pi --mode rpc is ready immediately
  vim.defer_fn(function()
    if not self.is_ready and not startup_failed then
      self.is_ready = true
      self.spawn_promise:resolve(self)
      if opts.on_ready then
        opts.on_ready(self)
      end
    end
  end, 100)

  return self.spawn_promise
end

function PiServer:is_running()
  return self.handle ~= nil and not self.handle:is_closing()
end

---@param command table
---@return Promise<table>
function PiServer:send_command(command)
  local promise = Promise.new()

  if not self.stdin or self.stdin:is_closing() then
    promise:reject('Pi server is not running')
    return promise
  end

  local id = command.id or require('opencode.util').uid()
  command.id = id

  self.pending_commands[id] = promise

  local jsonl = vim.json.encode(command) .. '\n'
  log.debug('pi server stdin -> %s', vim.trim(jsonl))
  self.stdin:write(jsonl, function(err)
    if err then
      log.error('pi server stdin write error: %s', tostring(err))
      self.pending_commands[id] = nil
      promise:reject('Failed to write to pi stdin: ' .. tostring(err))
    end
  end)

  return promise
end

---@param callback fun(event: table)
function PiServer:on_event(callback)
  table.insert(self.event_callbacks, callback)
end

---@param callback fun(event: table)
function PiServer:off_event(callback)
  for i = #self.event_callbacks, 1, -1 do
    if self.event_callbacks[i] == callback then
      table.remove(self.event_callbacks, i)
    end
  end
end

function PiServer:shutdown()
  if self.shutdown_promise:is_resolved() then
    return self.shutdown_promise
  end

  if self.handle and not self.handle:is_closing() then
    if self.pid then
      pcall(function()
        vim.uv.kill(self.pid, 15)
      end)
    end
    self.handle:close()
  end

  if self.stdin and not self.stdin:is_closing() then
    self.stdin:close()
  end
  if self.stdout and not self.stdout:is_closing() then
    self.stdout:close()
  end
  if self.stderr and not self.stderr:is_closing() then
    self.stderr:close()
  end

  for id, promise in pairs(self.pending_commands) do
    promise:reject('Server shut down')
    self.pending_commands[id] = nil
  end

  self.is_ready = false
  self.handle = nil
  self.stdin = nil
  self.stdout = nil
  self.stderr = nil
  self.pid = nil

  if not self.shutdown_promise:is_resolved() then
    self.shutdown_promise:resolve(true)
  end

  return self.shutdown_promise
end

function PiServer:get_shutdown_promise()
  return self.shutdown_promise
end

function PiServer:get_spawn_promise()
  return self.spawn_promise
end

---@private
function PiServer:_on_stdout(data)
  self.buffer = self.buffer .. data

  while true do
    local newline_pos = self.buffer:find('\n', 1, true)
    if not newline_pos then
      break
    end

    local line = self.buffer:sub(1, newline_pos - 1)
    self.buffer = self.buffer:sub(newline_pos + 1)

    if line:sub(-1) == '\r' then
      line = line:sub(1, -2)
    end

    self:_process_line(line)
  end
end

---@private
function PiServer:_process_line(line)
  if line == '' then
    return
  end

  log.debug('pi server stdout <- %s', line)

  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= 'table' then
    log.warn('pi server: failed to parse JSONL line: %s', line)
    return
  end

  if obj.type == 'response' and obj.id then
    local promise = self.pending_commands[obj.id]
    if promise then
      self.pending_commands[obj.id] = nil
      log.debug('pi server: resolving command %s (success=%s)', obj.id, tostring(obj.success))
      if obj.success == false then
        promise:reject(obj.error or 'Command failed')
      else
        promise:resolve(obj.data or obj)
      end
    else
      log.debug('pi server: unmatched response id=%s', obj.id)
    end
  else
    log.debug('pi server: forwarding event type=%s', obj.type or '?')
    for _, cb in ipairs(self.event_callbacks) do
      local ok2, err = pcall(cb, obj)
      if not ok2 then
        log.error('pi server: event callback error: %s', tostring(err))
      end
    end
  end
end

---@private
function PiServer:_on_exit(code, signal)
  log.debug('pi server: process exited (code=%s, signal=%s)', tostring(code), tostring(signal))
  self.is_ready = false

  for id, promise in pairs(self.pending_commands) do
    promise:reject(string.format('pi process exited (code=%s, signal=%s)', tostring(code), tostring(signal)))
    self.pending_commands[id] = nil
  end
end

return PiServer
