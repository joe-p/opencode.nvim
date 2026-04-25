local M = {}

---Convert pi AgentMessage to OpencodeMessage
---@param agentMsg table Pi AgentMessage (UserMessage, AssistantMessage, ToolResultMessage, or BashExecutionMessage)
---@param session_id string
---@return OpencodeMessage
function M.pi_agent_message_to_opencode(agentMsg, session_id)
  if not agentMsg or not agentMsg.role then
    return {
      info = {
        id = 'unknown',
        sessionID = session_id,
        role = 'system',
        time = { created = 0, completed = 0 },
        tokens = { input = 0, output = 0, cache = { read = 0, write = 0 } },
        cost = 0,
        path = { cwd = vim.fn.getcwd(), root = vim.fn.getcwd() },
        modelID = '',
        providerID = '',
      },
      parts = {},
    }
  end

  local msg_id = M._make_message_id(agentMsg, session_id)
  local role = agentMsg.role
  local timestamp = agentMsg.timestamp or (os.time() * 1000)

  ---@type OpencodeMessage
  local message = {
    info = {
      id = msg_id,
      sessionID = session_id,
      role = role == 'user' and 'user' or role == 'assistant' and 'assistant' or 'system',
      time = { created = timestamp, completed = timestamp },
      tokens = { input = 0, output = 0, cache = { read = 0, write = 0 } },
      cost = 0,
      path = { cwd = vim.fn.getcwd(), root = vim.fn.getcwd() },
      modelID = agentMsg.model or '',
      providerID = agentMsg.provider or '',
    },
    parts = {},
  }

  if role == 'user' then
    M._convert_user_message(agentMsg, message, session_id)
  elseif role == 'assistant' then
    M._convert_assistant_message(agentMsg, message, session_id)
  elseif role == 'toolResult' then
    M._convert_tool_result_message(agentMsg, message, session_id)
  elseif role == 'bashExecution' then
    M._convert_bash_execution_message(agentMsg, message, session_id)
  end

  return message
end

---@private
function M._make_message_id(agentMsg, session_id)
  -- Pi messages don't have stable IDs in the event stream, so we synthesize one
  -- from timestamp and role. For get_messages responses, the messages are in order.
  return string.format('%s-%s-%d', session_id, agentMsg.role or 'unknown', agentMsg.timestamp or 0)
end

---@private
function M._convert_user_message(agentMsg, message, session_id)
  local content = agentMsg.content
  if type(content) == 'string' then
    table.insert(message.parts, {
      type = 'text',
      id = message.info.id .. '-text-0',
      messageID = message.info.id,
      sessionID = session_id,
      text = content,
    })
  elseif type(content) == 'table' then
    for i, block in ipairs(content) do
      if block.type == 'text' then
        table.insert(message.parts, {
          type = 'text',
          id = message.info.id .. '-text-' .. i,
          messageID = message.info.id,
          sessionID = session_id,
          text = block.text or '',
        })
      elseif block.type == 'image' then
        table.insert(message.parts, {
          type = 'file',
          id = message.info.id .. '-image-' .. i,
          messageID = message.info.id,
          sessionID = session_id,
          filename = block.fileName or 'image',
          mime = block.mimeType or 'image/png',
        })
      end
    end
  end

  -- Handle attachments
  if agentMsg.attachments then
    for i, att in ipairs(agentMsg.attachments) do
      if att.type == 'image' then
        table.insert(message.parts, {
          type = 'file',
          id = message.info.id .. '-att-' .. i,
          messageID = message.info.id,
          sessionID = session_id,
          filename = att.fileName or 'attachment',
          mime = att.mimeType or 'image/png',
        })
      end
    end
  end
end

---@private
function M._convert_assistant_message(agentMsg, message, session_id)
  local content = agentMsg.content or {}
  if type(content) ~= 'table' then
    content = {}
  end

  for i, block in ipairs(content) do
    if block.type == 'text' then
      table.insert(message.parts, {
        type = 'text',
        id = message.info.id .. '-text-' .. i,
        messageID = message.info.id,
        sessionID = session_id,
        text = block.text or '',
      })
    elseif block.type == 'thinking' then
      table.insert(message.parts, {
        type = 'reasoning',
        id = message.info.id .. '-thinking-' .. i,
        messageID = message.info.id,
        sessionID = session_id,
        text = block.thinking or '',
        time = { start = agentMsg.timestamp, ['end'] = agentMsg.timestamp },
      })
    elseif block.type == 'toolCall' then
      table.insert(message.parts, {
        type = 'tool',
        id = message.info.id .. '-toolcall-' .. i,
        messageID = message.info.id,
        sessionID = session_id,
        tool = block.name or 'unknown',
        callID = block.id or '',
        state = {
          input = block.arguments or {},
          status = 'pending',
          title = block.name or 'tool',
          output = '',
          metadata = {},
          time = { start = os.time() },
        },
      })
    end
  end

  if agentMsg.usage then
    local usage = agentMsg.usage
    message.info.tokens = {
      input = usage.input or 0,
      output = usage.output or 0,
      cache = {
        read = usage.cacheRead or 0,
        write = usage.cacheWrite or 0,
      },
    }
    if usage.cost then
      message.info.cost = usage.cost.total or 0
    end
  end
end

---@private
function M._convert_tool_result_message(agentMsg, message, session_id)
  local output_text = ''
  if type(agentMsg.content) == 'table' then
    local parts = {}
    for _, block in ipairs(agentMsg.content) do
      if block.type == 'text' then
        table.insert(parts, block.text or '')
      end
    end
    output_text = table.concat(parts, '\n')
  elseif type(agentMsg.content) == 'string' then
    output_text = agentMsg.content
  end

  table.insert(message.parts, {
    type = 'tool',
    id = message.info.id .. '-result',
    messageID = message.info.id,
    sessionID = session_id,
    tool = agentMsg.toolName or 'unknown',
    callID = agentMsg.toolCallId or '',
    state = {
      input = {},
      status = agentMsg.isError and 'failed' or 'completed',
      title = agentMsg.toolName or 'tool',
      output = output_text,
      error = agentMsg.isError and output_text or nil,
      metadata = {},
      time = { start = agentMsg.timestamp or 0, ['end'] = agentMsg.timestamp or 0 },
    },
  })
end

---@private
function M._convert_bash_execution_message(agentMsg, message, session_id)
  table.insert(message.parts, {
    type = 'tool',
    id = message.info.id .. '-bash',
    messageID = message.info.id,
    sessionID = session_id,
    tool = 'bash',
    state = {
      input = { command = agentMsg.command or '', description = '' },
      status = agentMsg.exitCode == 0 and 'completed' or 'failed',
      title = 'bash',
      output = agentMsg.output or '',
      error = agentMsg.exitCode ~= 0 and string.format('exit code %d', agentMsg.exitCode) or nil,
      metadata = {
        output = agentMsg.output or '',
      },
      time = { start = agentMsg.timestamp or 0, ['end'] = agentMsg.timestamp or 0 },
    },
  })
end

---Convert opencode message parts to a pi prompt
---@param parts OpencodeMessagePart[]
---@return { message: string, images: table[] }
function M.opencode_parts_to_pi_prompt(parts)
  local text_parts = {}
  local images = {}

  for _, part in ipairs(parts or {}) do
    if part.type == 'text' and part.text then
      table.insert(text_parts, part.text)
    elseif part.type == 'file' and part.filename then
      -- Try to read and encode the file as base64 if it's an image
      local mime = part.mime or 'image/png'
      if mime:match('^image/') then
        local ok, data = pcall(function()
          local path = part.filename
          if vim.fn.filereadable(path) == 1 then
            local bytes = vim.fn.readfile(path, 'b')
            if type(bytes) == 'table' then
              bytes = table.concat(bytes, '\n')
            end
            return vim.fn.system({ 'base64' }, bytes):gsub('%s+$', '')
          end
          return nil
        end)
        if ok and data then
          table.insert(images, {
            type = 'image',
            data = data,
            mimeType = mime,
          })
        end
      else
        -- For non-image files, inline as text
        local ok, content = pcall(function()
          if vim.fn.filereadable(part.filename) == 1 then
            local lines = vim.fn.readfile(part.filename)
            return table.concat(lines, '\n')
          end
          return nil
        end)
        if ok and content then
          local ext = vim.fn.fnamemodify(part.filename, ':e')
          table.insert(text_parts, string.format('```%s\n%s\n```', ext, content))
        end
      end
    end
  end

  return {
    message = table.concat(text_parts, '\n\n'),
    images = images,
  }
end

---Convert pi content blocks to opencode parts
---@param contentBlocks table[]
---@param messageId string
---@param sessionId string
---@return OpencodeMessagePart[]
function M.pi_content_blocks_to_opencode_parts(contentBlocks, messageId, sessionId)
  local parts = {}
  for i, block in ipairs(contentBlocks or {}) do
    if block.type == 'text' then
      table.insert(parts, {
        type = 'text',
        id = messageId .. '-text-' .. i,
        messageID = messageId,
        sessionID = sessionId,
        text = block.text or '',
      })
    elseif block.type == 'thinking' then
      table.insert(parts, {
        type = 'reasoning',
        id = messageId .. '-thinking-' .. i,
        messageID = messageId,
        sessionID = sessionId,
        text = block.thinking or '',
      })
    elseif block.type == 'toolCall' then
      table.insert(parts, {
        type = 'tool',
        id = messageId .. '-toolcall-' .. i,
        messageID = messageId,
        sessionID = sessionId,
        tool = block.name or 'unknown',
        callID = block.id or '',
        state = {
          input = block.arguments or {},
          status = 'pending',
          title = block.name or 'tool',
          output = '',
          metadata = {},
          time = { start = os.time() },
        },
      })
    end
  end
  return parts
end

return M
