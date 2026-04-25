local Promise = require('opencode.promise')
local log = require('opencode.log')

---@class PiServer
---@field job vim.SystemObj|nil
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
    job = nil,
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
  local config = require('opencode.config')

  log.debug('pi server: spawning with cmd: %s', vim.inspect(cmd))

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

  self.job = vim.system(cmd, {
    cwd = opts.cwd,
    stdin = true,
    stdout = function(err, data)
      if err then
        fail_startup(tostring(err))
        return
      end
      if data then
        self:_on_stdout(data)
      end
    end,
    stderr = function(err, data)
      if err then
        fail_startup(tostring(err))
        return
      end
      if data and data ~= '' then
        table.insert(startup_stderr, data)
        log.debug('pi server stderr: %s', data)
      end
    end,
  }, function(obj)
    if not self.is_ready and not startup_failed then
      local stderr_output = table.concat(startup_stderr, '')
      local msg = stderr_output ~= '' and stderr_output
        or string.format('pi process exited unexpectedly (code=%s, signal=%s)', tostring(obj.code), tostring(obj.signal))
      fail_startup(msg)
    end
    self:_on_exit(obj.code, obj.signal)
    if opts.on_exit then
      opts.on_exit(obj.code or 0, obj.signal or 0)
    end
    self.shutdown_promise:resolve(true)
  end)

  if not self.job or not self.job.pid then
    fail_startup('Failed to spawn pi process')
    return self.spawn_promise
  end

  -- pi --mode rpc is ready immediately (no startup message needed)
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
  return self.job ~= nil and self.job.pid ~= nil
end

---@param command table
---@return Promise<table>
function PiServer:send_command(command)
  local promise = Promise.new()

  if not self.job or not self.job.pid then
    promise:reject('Pi server is not running')
    return promise
  end

  local id = command.id or require('opencode.util').uid()
  command.id = id

  self.pending_commands[id] = promise

  local jsonl = vim.json.encode(command) .. '\n'
  local ok, err = pcall(function()
    self.job:write(jsonl)
  end)

  if not ok then
    self.pending_commands[id] = nil
    promise:reject('Failed to write to pi stdin: ' .. tostring(err))
  end

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

  if self.job and self.job.pid then
    local ok = pcall(function()
      vim.uv.kill(self.job.pid, 15)
    end)
    if not ok then
      pcall(function()
        vim.uv.kill(self.job.pid, 9)
      end)
    end
  end

  -- Reject any pending commands
  for id, promise in pairs(self.pending_commands) do
    promise:reject('Server shut down')
    self.pending_commands[id] = nil
  end

  self.is_ready = false
  self.job = nil

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

    -- Strip trailing \r for Windows compatibility
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

  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= 'table' then
    log.warn('pi server: failed to parse JSONL line: %s', line)
    return
  end

  if obj.type == 'response' and obj.id then
    local promise = self.pending_commands[obj.id]
    if promise then
      self.pending_commands[obj.id] = nil
      if obj.success == false then
        promise:reject(obj.error or 'Command failed')
      else
        promise:resolve(obj.data or obj)
      end
    end
  else
    -- It's an event
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
