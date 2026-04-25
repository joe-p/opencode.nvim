local log = require('opencode.log')
local util = require('opencode.util')

---@class PiEventAdapter
---@field session_id string|nil
---@field current_message_id string|nil
---@field current_assistant_parts table<string, OpencodeMessagePart>
---@field tool_outputs table<string, {content: string, start_time: number}>
---@field event_manager EventManager|nil
local PiEventAdapter = {}
PiEventAdapter.__index = PiEventAdapter

function PiEventAdapter.new()
  return setmetatable({
    session_id = nil,
    current_message_id = nil,
    current_assistant_parts = {},
    tool_outputs = {},
    event_manager = nil,
  }, PiEventAdapter)
end

---@param event_manager EventManager
function PiEventAdapter:set_event_manager(event_manager)
  self.event_manager = event_manager
end

---@param session_id string
function PiEventAdapter:set_session_id(session_id)
  self.session_id = session_id
end

---@private
---@param event_name OpencodeEventName
---@param data table
function PiEventAdapter:_emit(event_name, data)
  if not self.event_manager then
    return
  end
  self.event_manager:emit(event_name, data)
end

---@param event table Pi event from stdout
function PiEventAdapter:handle_event(event)
  if not event or not event.type then
    return
  end

  local handler = self['_' .. event.type]
  if handler then
    local ok, err = pcall(handler, self, event)
    if not ok then
      log.error('pi event adapter: error handling %s: %s', event.type, tostring(err))
    end
  else
    log.debug('pi event adapter: unhandled event type: %s', event.type)
  end
end

-- ============================================================================
-- Agent lifecycle
-- ============================================================================

function PiEventAdapter:_agent_start(event)
  self:_emit('session.status', {
    sessionID = self.session_id or '',
    status = { type = 'running' },
  })
end

function PiEventAdapter:_agent_end(event)
  -- Finalize any pending assistant message
  if self.current_message_id then
    self:_finalize_current_message()
  end

  -- If pi sends messages in agent_end, sync them
  if event.messages and type(event.messages) == 'table' then
    self:_sync_messages(event.messages)
  end

  self:_emit('session.status', {
    sessionID = self.session_id or '',
    status = { type = 'idle' },
  })

  self:_emit('session.idle', {
    sessionID = self.session_id or '',
  })
end

-- ============================================================================
-- Turn lifecycle
-- ============================================================================

function PiEventAdapter:_turn_start(event)
  -- Turn boundaries are lower-level than message boundaries; we mostly ignore them
  -- but use them to ensure clean state
end

function PiEventAdapter:_turn_end(event)
  if event.message then
    self:_sync_assistant_message(event.message)
  end
  if event.toolResults and type(event.toolResults) == 'table' then
    for _, toolResult in ipairs(event.toolResults) do
      self:_sync_tool_result(toolResult)
    end
  end
end

-- ============================================================================
-- Message streaming
-- ============================================================================

function PiEventAdapter:_message_start(event)
  local message = event.message
  if not message then
    return
  end

  local session_id = self.session_id or 'pi-session'
  local message_id = self:_ensure_message_id(message, session_id)
  self.current_message_id = message_id
  self.current_assistant_parts = {}

  local role = message.role == 'user' and 'user' or 'assistant'

  self:_emit('message.updated', {
    info = {
      id = message_id,
      sessionID = session_id,
      role = role,
      time = { created = message.timestamp or (os.time() * 1000), completed = 0 },
      tokens = { input = 0, output = 0, cache = { read = 0, write = 0 } },
      cost = 0,
      path = { cwd = vim.fn.getcwd(), root = vim.fn.getcwd() },
      modelID = message.model or '',
      providerID = message.provider or '',
    },
  })
end

function PiEventAdapter:_message_update(event)
  local ame = event.assistantMessageEvent
  if not ame then
    return
  end

  local session_id = self.session_id or 'pi-session'
  local message_id = self.current_message_id or (session_id .. '-current')

  if ame.type == 'start' then
    self.current_message_id = message_id
    self.current_assistant_parts = {}
  elseif ame.type == 'text_start' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-text-' .. content_index
    self.current_assistant_parts[part_id] = {
      type = 'text',
      id = part_id,
      messageID = message_id,
      sessionID = session_id,
      text = '',
    }
  elseif ame.type == 'text_delta' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-text-' .. content_index
    local part = self.current_assistant_parts[part_id]
    if part then
      part.text = (part.text or '') .. (ame.delta or '')
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
    end
  elseif ame.type == 'text_end' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-text-' .. content_index
    local part = self.current_assistant_parts[part_id]
    if part then
      part.text = ame.content or part.text or ''
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
    end
  elseif ame.type == 'thinking_start' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-thinking-' .. content_index
    self.current_assistant_parts[part_id] = {
      type = 'reasoning',
      id = part_id,
      messageID = message_id,
      sessionID = session_id,
      text = '',
      time = { start = os.time() },
    }
  elseif ame.type == 'thinking_delta' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-thinking-' .. content_index
    local part = self.current_assistant_parts[part_id]
    if part then
      part.text = (part.text or '') .. (ame.delta or '')
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
    end
  elseif ame.type == 'thinking_end' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-thinking-' .. content_index
    local part = self.current_assistant_parts[part_id]
    if part then
      part.time = part.time or {}
      part.time['end'] = os.time()
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
    end
  elseif ame.type == 'toolcall_start' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-toolcall-' .. content_index
    local partial = ame.partial or {}
    self.current_assistant_parts[part_id] = {
      type = 'tool',
      id = part_id,
      messageID = message_id,
      sessionID = session_id,
      tool = partial.name or 'unknown',
      callID = partial.id or '',
      state = {
        input = {},
        status = 'pending',
        title = partial.name or 'tool',
        output = '',
        metadata = {},
        time = { start = os.time() },
      },
    }
  elseif ame.type == 'toolcall_delta' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-toolcall-' .. content_index
    local part = self.current_assistant_parts[part_id]
    if part then
      -- Pi sends partial arguments as JSON string fragments
      local delta = ame.delta or ''
      local partial = ame.partial or {}
      local current_args = part.state.input or {}

      if type(current_args) == 'table' then
        -- Try to merge the partial arguments
        local ok, parsed = pcall(vim.json.decode, partial.arguments or '{}')
        if ok and type(parsed) == 'table' then
          part.state.input = parsed
        else
          -- Accumulate as raw string if we can't parse yet
          part.state._raw_args = (part.state._raw_args or '') .. delta
        end
      end

      part.tool = partial.name or part.tool or 'unknown'
      part.callID = partial.id or part.callID or ''
      part.state.title = partial.name or part.state.title or 'tool'
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
    end
  elseif ame.type == 'toolcall_end' then
    local content_index = ame.contentIndex or 0
    local part_id = message_id .. '-toolcall-' .. content_index
    local part = self.current_assistant_parts[part_id]
    if part then
      local toolCall = ame.toolCall or {}
      part.tool = toolCall.name or part.tool or 'unknown'
      part.callID = toolCall.id or part.callID or ''
      part.state.input = toolCall.arguments or part.state.input or {}
      part.state.title = toolCall.name or part.state.title or 'tool'
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
    end
  elseif ame.type == 'done' then
    self:_finalize_current_message()
  elseif ame.type == 'error' then
    self:_finalize_current_message(ame.reason or 'error')
  end
end

function PiEventAdapter:_message_end(event)
  if event.message then
    self:_sync_assistant_message(event.message)
  end
  self:_finalize_current_message()
end

-- ============================================================================
-- Tool execution
-- ============================================================================

function PiEventAdapter:_tool_execution_start(event)
  local tool_call_id = event.toolCallId
  local session_id = self.session_id or 'pi-session'

  -- Find the tool part by callID
  for part_id, part in pairs(self.current_assistant_parts) do
    if part.callID == tool_call_id then
      part.state.status = 'running'
      part.state.time = part.state.time or {}
      part.state.time.start = os.time()
      self.tool_outputs[tool_call_id] = { content = '', start_time = os.time() }
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
      return
    end
  end

  -- Tool execution started for a tool we haven't seen yet (shouldn't happen often)
  local message_id = self.current_message_id or (session_id .. '-current')
  local part_id = message_id .. '-toolexec-' .. tool_call_id
  local part = {
    type = 'tool',
    id = part_id,
    messageID = message_id,
    sessionID = session_id,
    tool = event.toolName or 'unknown',
    callID = tool_call_id,
    state = {
      input = event.args or {},
      status = 'running',
      title = event.toolName or 'tool',
      output = '',
      metadata = {},
      time = { start = os.time() },
    },
  }
  self.current_assistant_parts[part_id] = part
  self.tool_outputs[tool_call_id] = { content = '', start_time = os.time() }
  self:_emit('message.part.updated', { part = vim.deepcopy(part) })
end

function PiEventAdapter:_tool_execution_update(event)
  local tool_call_id = event.toolCallId
  local tool_output = self.tool_outputs[tool_call_id]
  if not tool_output then
    return
  end

  local partial_result = event.partialResult or {}
  local content = partial_result.content or {}
  local text_parts = {}
  for _, block in ipairs(content) do
    if block.type == 'text' then
      table.insert(text_parts, block.text or '')
    end
  end
  local full_text = table.concat(text_parts, '\n')
  tool_output.content = full_text

  -- Find and update the tool part
  for part_id, part in pairs(self.current_assistant_parts) do
    if part.callID == tool_call_id then
      part.state.output = full_text
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
      return
    end
  end
end

function PiEventAdapter:_tool_execution_end(event)
  local tool_call_id = event.toolCallId
  local result = event.result or {}
  local content = result.content or {}
  local text_parts = {}
  for _, block in ipairs(content) do
    if block.type == 'text' then
      table.insert(text_parts, block.text or '')
    end
  end
  local full_text = table.concat(text_parts, '\n')

  -- Find and finalize the tool part
  for part_id, part in pairs(self.current_assistant_parts) do
    if part.callID == tool_call_id then
      part.state.output = full_text
      part.state.status = event.isError and 'failed' or 'completed'
      part.state.error = event.isError and full_text or nil
      part.state.time = part.state.time or {}
      part.state.time['end'] = os.time()
      self:_emit('message.part.updated', { part = vim.deepcopy(part) })
      return
    end
  end
end

-- ============================================================================
-- Compaction
-- ============================================================================

function PiEventAdapter:_compaction_start(event)
  self:_emit('session.compacted', {
    sessionID = self.session_id or '',
  })
end

function PiEventAdapter:_compaction_end(event)
  -- Compaction finished; optionally emit session.updated
end

-- ============================================================================
-- Queue updates
-- ============================================================================

function PiEventAdapter:_queue_update(event)
  -- Steering/follow-up queue changed. For now we ignore this or could render
  -- it as a synthetic system message part in the future.
end

-- ============================================================================
-- Auto retry
-- ============================================================================

function PiEventAdapter:_auto_retry_start(event)
  self:_emit('session.status', {
    sessionID = self.session_id or '',
    status = {
      type = 'retrying',
      message = event.errorMessage or 'Retrying...',
      attempt = event.attempt,
    },
  })
end

function PiEventAdapter:_auto_retry_end(event)
  -- Status will be updated by agent_start or agent_end
end

-- ============================================================================
-- Extension UI requests
-- ============================================================================

function PiEventAdapter:_extension_ui_request(event)
  local method = event.method
  if not method then
    return
  end

  if method == 'select' or method == 'confirm' then
    -- Map to permission.asked for blocking UI requests
    local title = event.title or 'Pi Request'
    local options = event.options or {}
    local is_confirm = method == 'confirm'

    self:_emit('permission.asked', {
      id = event.id,
      type = 'pi_extension_ui',
      pattern = title,
      sessionID = self.session_id or '',
      messageID = '',
      callID = '',
      title = title,
      metadata = {
        pi_method = method,
        pi_options = options,
        pi_message = event.message,
        pi_request_id = event.id,
      },
      time = { created = os.time() },
    })
  elseif method == 'input' then
    -- Use vim.ui.input for non-blocking text input
    vim.schedule(function()
      vim.ui.input({
        prompt = event.title or 'Input: ',
        default = event.placeholder or '',
      }, function(value)
        if value ~= nil then
          self:_send_ui_response(event.id, { value = value })
        else
          self:_send_ui_response(event.id, { cancelled = true })
        end
      end)
    end)
  elseif method == 'editor' then
    -- Open a temp buffer for multi-line input
    vim.schedule(function()
      local prefill = event.prefill or ''
      local lines = vim.split(prefill, '\n')
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })

      vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = math.floor(vim.o.columns * 0.6),
        height = math.floor(vim.o.lines * 0.4),
        col = math.floor(vim.o.columns * 0.2),
        row = math.floor(vim.o.lines * 0.2),
        style = 'minimal',
        border = 'rounded',
        title = event.title or 'Edit',
      })

      vim.keymap.set('n', '<cr>', function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
        pcall(vim.api.nvim_win_close, 0, true)
        self:_send_ui_response(event.id, { value = text })
      end, { buffer = buf, noremap = true, silent = true })

      vim.keymap.set('n', '<esc>', function()
        pcall(vim.api.nvim_win_close, 0, true)
        self:_send_ui_response(event.id, { cancelled = true })
      end, { buffer = buf, noremap = true, silent = true })
    end)
  elseif method == 'notify' then
    local level = event.notifyType == 'error' and vim.log.levels.ERROR
      or event.notifyType == 'warning' and vim.log.levels.WARN
      or vim.log.levels.INFO
    vim.notify(event.message or '', level)
  elseif method == 'set_editor_text' then
    vim.schedule(function()
      local input_window = require('opencode.ui.input_window')
      input_window.set_content(event.text or '')
    end)
  elseif method == 'setStatus' then
    -- Fire-and-forget status update; could be wired to a custom status line
    log.debug('pi extension status: %s = %s', event.statusKey or '?', event.statusText or 'nil')
  elseif method == 'setWidget' then
    -- Fire-and-forget widget update; could be rendered as a synthetic part
    log.debug('pi extension widget: %s', event.widgetKey or '?')
  end
end

function PiEventAdapter:_send_ui_response(request_id, data)
  if not self.event_manager then
    return
  end
  -- We need access to the PiServer to send the response.
  -- The event manager doesn't hold the server, but the state does.
  local state = require('opencode.state')
  local server = state.opencode_server
  if server and server.send_command then
    local cmd = vim.tbl_deep_extend('force', {
      type = 'extension_ui_response',
      id = request_id,
    }, data)
    server:send_command(cmd)
  end
end

-- ============================================================================
-- Extension errors
-- ============================================================================

function PiEventAdapter:_extension_error(event)
  self:_emit('session.error', {
    sessionID = self.session_id or '',
    error = {
      message = event.error or 'Extension error',
      extensionPath = event.extensionPath,
      event = event.event,
    },
  })
end

-- ============================================================================
-- Helpers
-- ============================================================================

function PiEventAdapter:_finalize_current_message(error_reason)
  if not self.current_message_id then
    return
  end

  -- Emit a final message update with completed timestamp
  self:_emit('message.updated', {
    info = {
      id = self.current_message_id,
      sessionID = self.session_id or '',
      role = 'assistant',
      time = { created = 0, completed = os.time() * 1000 },
      tokens = { input = 0, output = 0, cache = { read = 0, write = 0 } },
      cost = 0,
      path = { cwd = vim.fn.getcwd(), root = vim.fn.getcwd() },
      modelID = '',
      providerID = '',
      error = error_reason and { data = { message = error_reason } } or nil,
    },
  })

  self.current_message_id = nil
  self.current_assistant_parts = {}
end

function PiEventAdapter:_sync_messages(messages)
  local converter = require('opencode.pi.message_converter')
  local session_id = self.session_id or 'pi-session'

  for _, msg in ipairs(messages) do
    local opencode_msg = converter.pi_agent_message_to_opencode(msg, session_id)
    self:_emit('message.updated', { info = opencode_msg.info })
    for _, part in ipairs(opencode_msg.parts) do
      self:_emit('message.part.updated', { part = part })
    end
  end
end

function PiEventAdapter:_sync_assistant_message(message)
  if not message then
    return
  end

  local session_id = self.session_id or 'pi-session'
  local message_id = self:_ensure_message_id(message, session_id)
  self.current_message_id = message_id

  local converter = require('opencode.pi.message_converter')
  local opencode_msg = converter.pi_agent_message_to_opencode(message, session_id)

  self:_emit('message.updated', { info = opencode_msg.info })
  for _, part in ipairs(opencode_msg.parts) do
    self.current_assistant_parts[part.id] = part
    self:_emit('message.part.updated', { part = part })
  end
end

function PiEventAdapter:_sync_tool_result(toolResult)
  if not toolResult then
    return
  end

  local session_id = self.session_id or 'pi-session'
  local message_id = self.current_message_id or (session_id .. '-current')
  local part_id = message_id .. '-toolresult-' .. (toolResult.toolCallId or 'unknown')

  local content_text = ''
  if type(toolResult.content) == 'table' then
    local parts = {}
    for _, block in ipairs(toolResult.content) do
      if block.type == 'text' then
        table.insert(parts, block.text or '')
      end
    end
    content_text = table.concat(parts, '\n')
  elseif type(toolResult.content) == 'string' then
    content_text = toolResult.content
  end

  local part = {
    type = 'tool',
    id = part_id,
    messageID = message_id,
    sessionID = session_id,
    tool = toolResult.toolName or 'unknown',
    callID = toolResult.toolCallId or '',
    state = {
      input = {},
      status = toolResult.isError and 'failed' or 'completed',
      title = toolResult.toolName or 'tool',
      output = content_text,
      error = toolResult.isError and content_text or nil,
      metadata = {},
      time = { start = os.time(), ['end'] = os.time() },
    },
  }

  self:_emit('message.part.updated', { part = part })
end

function PiEventAdapter:_ensure_message_id(message, session_id)
  if message.id then
    return tostring(message.id)
  end
  return string.format('%s-%s-%d', session_id, message.role or 'msg', message.timestamp or os.time())
end

return PiEventAdapter
