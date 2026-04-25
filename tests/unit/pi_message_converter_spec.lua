local converter = require('opencode.pi.message_converter')

describe('pi message converter', function()
  it('converts pi user message to opencode', function()
    local msg = {
      role = 'user',
      content = 'Hello world',
      timestamp = 1700000000000,
    }
    local result = converter.pi_agent_message_to_opencode(msg, 'test-session')
    assert.equals('user', result.info.role)
    assert.equals(1, #result.parts)
    assert.equals('text', result.parts[1].type)
    assert.equals('Hello world', result.parts[1].text)
  end)

  it('converts pi assistant text to opencode', function()
    local msg = {
      role = 'assistant',
      content = { { type = 'text', text = 'Hi there' } },
      timestamp = 1700000000000,
      model = 'claude-sonnet-4',
      provider = 'anthropic',
    }
    local result = converter.pi_agent_message_to_opencode(msg, 'test-session')
    assert.equals('assistant', result.info.role)
    assert.equals('claude-sonnet-4', result.info.modelID)
    assert.equals('anthropic', result.info.providerID)
    assert.equals(1, #result.parts)
    assert.equals('text', result.parts[1].type)
    assert.equals('Hi there', result.parts[1].text)
  end)

  it('converts pi assistant thinking to opencode reasoning', function()
    local msg = {
      role = 'assistant',
      content = { { type = 'thinking', thinking = 'Let me think...' } },
      timestamp = 1700000000000,
    }
    local result = converter.pi_agent_message_to_opencode(msg, 'test-session')
    assert.equals('reasoning', result.parts[1].type)
    assert.equals('Let me think...', result.parts[1].text)
  end)

  it('converts pi tool call to opencode tool part', function()
    local msg = {
      role = 'assistant',
      content = { { type = 'toolCall', id = 'call_123', name = 'bash', arguments = { command = 'ls' } } },
      timestamp = 1700000000000,
    }
    local result = converter.pi_agent_message_to_opencode(msg, 'test-session')
    assert.equals('tool', result.parts[1].type)
    assert.equals('bash', result.parts[1].tool)
    assert.equals('call_123', result.parts[1].callID)
    assert.equals('pending', result.parts[1].state.status)
  end)

  it('converts pi tool result to opencode tool part', function()
    local msg = {
      role = 'toolResult',
      toolCallId = 'call_123',
      toolName = 'bash',
      content = { { type = 'text', text = 'file.txt' } },
      isError = false,
      timestamp = 1700000000000,
    }
    local result = converter.pi_agent_message_to_opencode(msg, 'test-session')
    assert.equals('tool', result.parts[1].type)
    assert.equals('bash', result.parts[1].tool)
    assert.equals('completed', result.parts[1].state.status)
    assert.equals('file.txt', result.parts[1].state.output)
  end)

  it('formats opencode parts to pi prompt', function()
    local parts = {
      { type = 'text', text = 'Hello' },
    }
    local result = converter.opencode_parts_to_pi_prompt(parts)
    assert.equals('Hello', result.message)
    assert.equals(0, #result.images)
  end)
end)
