local Promise = require('opencode.promise')
local log = require('opencode.log')

---@class PiApiClient
---@field server PiServer|nil
---@field session_id string|nil
---@field session_name string|nil
---@field session_file string|nil
---@field _event_callback function|nil
---@field _event_emitter function|nil
---@field _pending_events table[]
local PiApiClient = {}
PiApiClient.__index = PiApiClient

function PiApiClient.new(server)
  return setmetatable({
    server = server,
    session_id = nil,
    session_name = nil,
    session_file = nil,
    _event_callback = nil,
    _event_emitter = nil,
    _pending_events = {},
  }, PiApiClient)
end

function PiApiClient:_emit_event(event_name, data)
  local event = { type = event_name, properties = data }
  if self._event_emitter then
    local ok, err = pcall(self._event_emitter, event)
    if not ok then
      log.error('pi api_client: failed to emit event %s: %s', event_name, tostring(err))
    end
  else
    table.insert(self._pending_events, event)
    log.debug('pi api_client: queued event %s (emitter not ready yet)', event_name)
  end
end

function PiApiClient:_flush_pending_events()
  if not self._event_emitter then
    return
  end
  while #self._pending_events > 0 do
    local event = table.remove(self._pending_events, 1)
    local ok, err = pcall(self._event_emitter, event)
    if not ok then
      log.error('pi api_client: failed to emit queued event %s: %s', event.type, tostring(err))
    end
  end
end

function PiApiClient:_ensure_event_callback()
  if self._event_callback then
    return self._event_callback
  end

  local adapter = require('opencode.pi.event_adapter').new()
  adapter:set_session_id(self.session_id or 'pi-session')

  self._event_callback = function(event)
    adapter:handle_event(event)
  end

  return self._event_callback
end

function PiApiClient:unsubscribe_from_events()
  if self.server and self._event_callback then
    self.server:off_event(self._event_callback)
    self._event_callback = nil
  end
end

-- ============================================================================
-- Session endpoints (simplified for pi single-session model)
-- ============================================================================

---@param directory string|nil
---@return Promise<Session[]>
function PiApiClient:list_sessions(directory)
  -- Pi doesn't have a list_sessions command. We scan the session dir if configured.
  local config = require('opencode.config')
  local session_dir = config.pi and config.pi.session_dir or nil

  if not session_dir then
    -- Return current session only
    if self.session_id then
      return self:get_session(self.session_id)
        :and_then(function(session)
          return { session }
        end)
        :catch(function()
          return {}
        end)
    end
    return Promise.new():resolve({})
  end

  -- Scan session_dir for .jsonl files
  local promise = Promise.new()
  vim.schedule(function()
    local sessions = {}
    local handle = vim.uv.fs_scandir(session_dir)
    if handle then
      while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        if t == 'file' and name:match('%.jsonl$') then
          local path = session_dir .. '/' .. name
          local stat = vim.uv.fs_stat(path)
          table.insert(sessions, {
            id = name:gsub('%.jsonl$', ''),
            title = name,
            workspace = directory or vim.fn.getcwd(),
      directory = directory or vim.fn.getcwd(),
            time = { created = stat and stat.mtime and stat.mtime.sec or 0, updated = stat and stat.mtime and stat.mtime.sec or 0 },
            parentID = nil,
          })
        end
      end
    end
    promise:resolve(sessions)
  end)
  return promise
end

---@param session_data {parentID?: string, title?: string}|nil|boolean
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:create_session(session_data, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  local cmd = { type = 'new_session' }
  if type(session_data) == 'table' and session_data.parentID then
    -- Pi doesn't support parentID in new_session, but we could fork later
  end

  return self.server:send_command(cmd):and_then(function(data)
    local cancelled = data and data.cancelled
    if cancelled then
      return Promise.new():reject('Session creation was cancelled')
    end

    -- After creating session, get state to know the session id
    return self:get_state()
  end):and_then(function(state_data)
    self.session_id = state_data.sessionId or 'pi-session'
    self.session_name = state_data.sessionName
    self.session_file = state_data.sessionFile

    local session = {
      id = self.session_id,
      title = self.session_name or 'Pi Session',
      workspace = directory or vim.fn.getcwd(),
      directory = directory or vim.fn.getcwd(),
      time = { created = os.time(), updated = os.time() },
      parentID = nil,
    }
    return session
  end)
end

---@param id string
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:get_session(id, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self:get_state():and_then(function(state_data)
    self.session_id = state_data.sessionId or id
    self.session_name = state_data.sessionName
    self.session_file = state_data.sessionFile

    return {
      id = self.session_id,
      title = self.session_name or 'Pi Session',
      workspace = directory or vim.fn.getcwd(),
      directory = directory or vim.fn.getcwd(),
      time = { created = os.time(), updated = os.time() },
      parentID = nil,
    }
  end)
end

---@param id string
---@param directory string|nil
---@return Promise<boolean>
function PiApiClient:delete_session(id, directory)
  -- Pi doesn't support deleting sessions via RPC
  return Promise.new():resolve(true)
end

---@param id string
---@param session_update {title?: string}
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:update_session(id, session_update, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  if session_update and session_update.title then
    return self.server:send_command({
      type = 'set_session_name',
      name = session_update.title,
    }):and_then(function()
      self.session_name = session_update.title
      return {
        id = id,
        title = session_update.title,
        workspace = directory or vim.fn.getcwd(),
      directory = directory or vim.fn.getcwd(),
        time = { created = os.time(), updated = os.time() },
        parentID = nil,
      }
    end)
  end

  return self:get_session(id, directory)
end

---@param id string
---@param directory string|nil
---@return Promise<Session[]>
function PiApiClient:get_session_children(id, directory)
  return Promise.new():resolve({})
end

---@param id string
---@param init_data {messageID: string, providerID: string, modelID: string}
---@param directory string|nil
---@return Promise<boolean>
function PiApiClient:init_session(id, init_data, directory)
  return Promise.new():resolve(true)
end

---@param id string
---@param directory string|nil
---@return Promise<boolean>
function PiApiClient:abort_session(id, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self.server:send_command({ type = 'abort' }):and_then(function()
    return true
  end)
end

---@param id string
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:share_session(id, directory)
  return Promise.new():reject('Sharing not supported in pi mode')
end

---@param id string
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:unshare_session(id, directory)
  return Promise.new():reject('Sharing not supported in pi mode')
end

---@param id string
---@param summary_data {providerID: string, modelID: string}
---@param directory string|nil
---@return Promise<boolean>
function PiApiClient:summarize_session(id, summary_data, directory)
  return Promise.new():reject('Summarization not supported in pi mode')
end

---@param id string
---@param fork_data {messageID?: string}|nil
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:fork_session(id, fork_data, directory)
  if not self.server or not fork_data or not fork_data.messageID then
    return Promise.new():reject('Pi server not running or no message ID provided')
  end

  return self.server:send_command({
    type = 'fork',
    entryId = fork_data.messageID,
  }):and_then(function(data)
    if data and data.cancelled then
      return Promise.new():reject('Fork was cancelled')
    end
    return self:get_session(id, directory)
  end)
end

-- ============================================================================
-- State
-- ============================================================================

---@return Promise<table>
function PiApiClient:get_state()
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self.server:send_command({ type = 'get_state' }):and_then(function(data)
    if data then
      self.session_id = data.sessionId or self.session_id
      self.session_name = data.sessionName or self.session_name
      self.session_file = data.sessionFile or self.session_file
    end
    return data or {}
  end)
end

-- ============================================================================
-- Message endpoints
-- ============================================================================

---@param id string
---@param directory string|nil
---@return Promise<OpencodeMessage[]>
function PiApiClient:list_messages(id, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self.server:send_command({ type = 'get_messages' }):and_then(function(data)
    local messages = (data and data.messages) or {}
    local converter = require('opencode.pi.message_converter')
    local session_id = self.session_id or id

    local opencode_messages = {}
    for _, msg in ipairs(messages) do
      table.insert(opencode_messages, converter.pi_agent_message_to_opencode(msg, session_id))
    end
    return opencode_messages
  end)
end

---@param id string Session ID (ignored for pi — uses current session)
---@param message_data {parts: OpencodeMessagePart[], model?: table, agent?: string, variant?: string, system?: string}
---@param directory string|nil
---@return Promise<{info: MessageInfo, parts: OpencodeMessagePart[]}>
function PiApiClient:create_message(id, message_data, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  local converter = require('opencode.pi.message_converter')
  local prompt_data = converter.opencode_parts_to_pi_prompt(message_data.parts or {})

  -- Optionally switch model first
  local model_promise = Promise.new():resolve(nil)
  if message_data.model and message_data.model.providerID and message_data.model.modelID then
    model_promise = self.server:send_command({
      type = 'set_model',
      provider = message_data.model.providerID,
      modelId = message_data.model.modelID,
    })
  end

  return model_promise:and_then(function()
    local cmd = {
      type = 'prompt',
      message = prompt_data.message,
    }
    if prompt_data.images and #prompt_data.images > 0 then
      cmd.images = prompt_data.images
    end

    log.debug('pi api_client: sending prompt (len=%d)', #prompt_data.message)
    return self.server:send_command(cmd)
  end):and_then(function(response)
    log.debug('pi api_client: prompt accepted, synthesizing user message')

    -- The prompt command response just indicates acceptance.
    -- We synthesize a user message immediately so it appears in the UI.
    local session_id = self.session_id or id or 'pi-session'
    local message_id = string.format('%s-user-%d', session_id, os.time())

    local user_message = {
      info = {
        id = message_id,
        sessionID = session_id,
        role = 'user',
        time = { created = os.time() * 1000, completed = os.time() * 1000 },
        tokens = { input = 0, output = 0, cache = { read = 0, write = 0 } },
        cost = 0,
        path = { cwd = vim.fn.getcwd(), root = vim.fn.getcwd() },
        modelID = message_data.model and message_data.model.modelID or '',
        providerID = message_data.model and message_data.model.providerID or '',
      },
      parts = {},
    }

    -- Add text part for the prompt
    if prompt_data.message and prompt_data.message ~= '' then
      table.insert(user_message.parts, {
        type = 'text',
        id = message_id .. '-text-0',
        messageID = message_id,
        sessionID = session_id,
        text = prompt_data.message,
      })
    end

    -- Add image parts
    for i, img in ipairs(prompt_data.images or {}) do
      table.insert(user_message.parts, {
        type = 'file',
        id = message_id .. '-image-' .. i,
        messageID = message_id,
        sessionID = session_id,
        filename = 'image-' .. i,
        mime = img.mimeType or 'image/png',
      })
    end

    -- Emit events so the renderer shows the user message immediately
    self:_emit_event('message.updated', { info = user_message.info })
    for _, part in ipairs(user_message.parts) do
      self:_emit_event('message.part.updated', { part = part })
    end

    return { info = user_message.info, parts = user_message.parts }
  end):catch(function(err)
    log.error('pi api_client: create_message failed: %s', vim.inspect(err))
    return Promise.new():reject(err)
  end)
end

---@param id string
---@param messageID string
---@param directory string|nil
---@return Promise<OpencodeMessage>
function PiApiClient:get_message(id, messageID, directory)
  -- Pi doesn't support getting individual messages; fetch all and filter
  return self:list_messages(id, directory):and_then(function(messages)
    for _, msg in ipairs(messages) do
      if msg.info and msg.info.id == messageID then
        return msg
      end
    end
    return Promise.new():reject('Message not found')
  end)
end

---@param id string
---@param command_data {arguments: string, command: string}
---@param directory string|nil
---@return Promise<OpencodeMessage>
function PiApiClient:send_command(id, command_data, directory)
  -- Commands in pi are sent via prompt with a / prefix
  local prompt = '/' .. command_data.command
  if command_data.arguments and command_data.arguments ~= '' then
    prompt = prompt .. ' ' .. command_data.arguments
  end

  return self:create_message(id, { parts = { { type = 'text', text = prompt } } }, directory)
end

---@param id string
---@param shell_data {command: string}
---@param directory string|nil
---@return Promise<MessageInfo>
function PiApiClient:run_shell(id, shell_data, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self.server:send_command({
    type = 'bash',
    command = shell_data.command,
  }):and_then(function(data)
    return {
      id = 'bash-' .. os.time(),
      sessionID = self.session_id or id,
      role = 'tool',
      time = { created = os.time() * 1000, completed = os.time() * 1000 },
      tokens = { input = 0, output = 0, cache = { read = 0, write = 0 } },
      cost = 0,
    }
  end)
end

---@param id string
---@param revert_data {messageID: string, partID?: string}
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:revert_message(id, revert_data, directory)
  return Promise.new():reject('Revert not supported in pi mode')
end

---@param id string
---@param directory string|nil
---@return Promise<Session>
function PiApiClient:unrevert_messages(id, directory)
  return Promise.new():reject('Unrevert not supported in pi mode')
end

-- ============================================================================
-- Permissions (mapped to extension UI requests)
-- ============================================================================

---@param id string
---@param permissionID string
---@param response_data {response: "once"|"always"|"reject"}
---@param directory string|nil
---@return Promise<boolean>
function PiApiClient:respond_to_permission(id, permissionID, response_data, directory)
  -- For pi, permissions are handled via extension_ui_response.
  -- The permissionID is the pi extension UI request id.
  if self.server then
    local value
    if response_data.response == 'reject' then
      value = false
    else
      value = true
    end

    return self.server:send_command({
      type = 'extension_ui_response',
      id = permissionID,
      confirmed = value,
    }):and_then(function()
      return true
    end)
  end

  return Promise.new():resolve(true)
end

-- ============================================================================
-- Commands
-- ============================================================================

---@param directory string|nil
---@return Promise<OpencodeCommand[]>
function PiApiClient:list_commands(directory)
  if not self.server then
    return Promise.new():resolve({})
  end

  return self.server:send_command({ type = 'get_commands' }):and_then(function(data)
    local commands = (data and data.commands) or {}
    local result = {}
    for _, cmd in ipairs(commands) do
      table.insert(result, {
        name = cmd.name,
        description = cmd.description or '',
        agent = cmd.source or 'extension',
        model = '',
        template = '',
      })
    end
    return result
  end)
end

-- ============================================================================
-- Find / File (not supported by pi RPC)
-- ============================================================================

function PiApiClient:find_text(pattern, directory)
  return Promise.new():resolve({})
end

function PiApiClient:find_files(query, directory)
  return Promise.new():resolve({})
end

function PiApiClient:find_symbols(query, directory)
  return Promise.new():resolve({})
end

function PiApiClient:list_files(path, directory)
  return Promise.new():resolve({})
end

function PiApiClient:read_file(path, directory)
  return Promise.new():resolve({})
end

function PiApiClient:get_file_status(directory)
  return Promise.new():resolve({})
end

-- ============================================================================
-- Log
-- ============================================================================

function PiApiClient:write_log(log_data, directory)
  return Promise.new():resolve(true)
end

-- ============================================================================
-- Agent
-- ============================================================================

function PiApiClient:list_agents(directory)
  -- Pi doesn't have an agents endpoint in RPC mode
  return Promise.new():resolve({})
end

-- ============================================================================
-- Question (mapped to extension UI requests)
-- ============================================================================

function PiApiClient:list_questions(directory)
  return Promise.new():resolve({})
end

function PiApiClient:reply_question(requestID, answers, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  -- Find the first non-empty answer
  local value
  for _, ans in ipairs(answers or {}) do
    if ans and #ans > 0 then
      value = ans[1]
      break
    end
  end

  return self.server:send_command({
    type = 'extension_ui_response',
    id = requestID,
    value = value,
  }):and_then(function()
    return true
  end)
end

function PiApiClient:reject_question(requestID, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self.server:send_command({
    type = 'extension_ui_response',
    id = requestID,
    cancelled = true,
  }):and_then(function()
    return true
  end)
end

-- ============================================================================
-- Event streaming (pi uses stdout, not HTTP SSE)
-- ============================================================================

---@param directory string|nil
---@param on_event fun(event: table)
---@return table
function PiApiClient:subscribe_to_events(directory, on_event)
  if not self.server then
    return { shutdown = function() end }
  end

  self:unsubscribe_from_events()
  self._event_emitter = on_event
  self:_flush_pending_events()

  local adapter = require('opencode.pi.event_adapter').new()
  adapter:set_session_id(self.session_id or 'pi-session')

  -- Create a lightweight event manager wrapper for the adapter
  local wrapper = {
    emit = function(_, event_name, data)
      on_event({ type = event_name, properties = data })
    end,
  }
  adapter:set_event_manager(wrapper)

  self._event_callback = function(event)
    adapter:handle_event(event)
  end

  self.server:on_event(self._event_callback)
  log.debug('pi api_client: subscribed to pi events')

  -- Return a handle that unsubscribes when shutdown
  local client = self
  return {
    shutdown = function()
      client:unsubscribe_from_events()
    end,
  }
end

-- ============================================================================
-- Tool / MCP (not supported by pi RPC)
-- ============================================================================

function PiApiClient:list_tool_ids(directory)
  return Promise.new():resolve({})
end

function PiApiClient:list_tools(provider, model, directory)
  return Promise.new():resolve({})
end

function PiApiClient:list_mcp_servers(directory)
  return Promise.new():resolve({})
end

function PiApiClient:connect_mcp(name, directory)
  return Promise.new():reject('MCP not supported in pi mode')
end

function PiApiClient:disconnect_mcp(name, directory)
  return Promise.new():reject('MCP not supported in pi mode')
end

-- ============================================================================
-- Project / Config (not supported by pi RPC)
-- ============================================================================

function PiApiClient:list_projects(directory)
  return Promise.new():resolve({})
end

function PiApiClient:get_current_project(directory)
  return Promise.new():resolve({
    id = 'pi-project',
    worktree = directory or vim.fn.getcwd(),
    vcs = 'git',
    time = { created = os.time() },
  })
end

function PiApiClient:get_config(directory)
  return Promise.new():resolve({})
end

function PiApiClient:update_config(config_obj, directory)
  return Promise.new():resolve(config_obj)
end

function PiApiClient:list_providers(directory)
  if not self.server then
    return Promise.new():resolve({ providers = {}, default = {} })
  end

  return self.server:send_command({ type = 'get_available_models' }):and_then(function(data)
    local models = (data and data.models) or {}
    local providers = {}
    local defaults = {}

    for _, model in ipairs(models) do
      local provider_id = model.provider or 'unknown'
      if not providers[provider_id] then
        providers[provider_id] = {
          id = provider_id,
          name = provider_id:gsub('^%l', string.upper),
          env = {},
          npm = '',
          api = model.baseUrl,
          doc = nil,
          models = {},
        }
      end
      providers[provider_id].models[model.id] = {
        id = model.id,
        name = model.name or model.id,
        attachment = vim.tbl_contains(model.input or {}, 'image'),
        reasoning = model.reasoning or false,
        temperature = false,
        tool_call = true,
        knowledge = nil,
        release_date = '',
        last_updated = '',
        modalities = {
          input = model.input or { 'text' },
          output = { 'text' },
        },
        open_weights = false,
        limit = {
          context = model.contextWindow or 0,
          output = model.maxTokens or 0,
        },
        cost = {
          input = model.cost and model.cost.input or 0,
          output = model.cost and model.cost.output or 0,
          cache_read = model.cost and model.cost.cacheRead or nil,
          cache_write = model.cost and model.cost.cacheWrite or nil,
        },
        variants = nil,
      }
    end

    local provider_list = {}
    for _, provider in pairs(providers) do
      table.insert(provider_list, provider)
    end

    return { providers = provider_list, default = defaults }
  end)
end

function PiApiClient:get_path(directory)
  return Promise.new():resolve({
    state = '',
    config = '',
    worktree = directory or vim.fn.getcwd(),
    directory = directory or vim.fn.getcwd(),
  })
end

-- ============================================================================
-- Stats / Export
-- ============================================================================

function PiApiClient:get_session_stats(id, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  return self.server:send_command({ type = 'get_session_stats' }):and_then(function(data)
    return data or {}
  end)
end

function PiApiClient:export_html(id, outputPath, directory)
  if not self.server then
    return Promise.new():reject('Pi server not running')
  end

  local cmd = { type = 'export_html' }
  if outputPath then
    cmd.outputPath = outputPath
  end

  return self.server:send_command(cmd):and_then(function(data)
    return data or {}
  end)
end

return PiApiClient
