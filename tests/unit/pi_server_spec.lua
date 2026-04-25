describe('pi server', function()
  local PiServer

  before_each(function()
    PiServer = require('opencode.pi.server')
  end)

  it('can be created', function()
    local server = PiServer.new()
    assert.is_not_nil(server)
    assert.is_false(server:is_running())
  end)

  it('tracks pending commands', function()
    local server = PiServer.new()
    server.pending_commands['test-id'] = require('opencode.promise').new()
    assert.is_not_nil(server.pending_commands['test-id'])
  end)
end)
