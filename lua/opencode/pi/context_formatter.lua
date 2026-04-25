local M = {}

---Format opencode context parts into a pi prompt string.
---Pi's prompt command only accepts a text string + optional images,
---so we inline file contents, selections, diagnostics, etc. as markdown text.
---@param prompt string The raw user prompt
---@param parts OpencodeMessagePart[] The context parts from opencode's context module
---@return { message: string, images: table[] }
function M.format_parts_for_pi(prompt, parts)
  local sections = {}
  local images = {}

  -- Add the user prompt first (it will be at the end after context)
  -- Actually, let's put context first, then prompt at the end
  local prompt_text = vim.trim(prompt or '')

  for _, part in ipairs(parts or {}) do
    if part.type == 'text' and part.text then
      if part.synthetic then
        -- Synthetic text parts contain context data as JSON
        local ok, ctx = pcall(vim.json.decode, part.text)
        if ok and ctx then
          local ctx_text = M._format_context_block(ctx)
          if ctx_text and ctx_text ~= '' then
            table.insert(sections, ctx_text)
          end
        else
          -- Not JSON context, just regular text
          table.insert(sections, part.text)
        end
      else
        -- User prompt text — save for later
        prompt_text = part.text
      end
    elseif part.type == 'file' and part.filename then
      local file_section = M._format_file_block(part)
      if file_section then
        table.insert(sections, file_section)
      end

      -- Check if it's an image
      local mime = part.mime or ''
      if mime:match('^image/') then
        local img = M._encode_image(part.filename)
        if img then
          table.insert(images, img)
        end
      end
    elseif part.type == 'agent' then
      -- Subagent mentions; inline as text reference
      if part.name then
        table.insert(sections, string.format('(Using subagent: %s)', part.name))
      end
    end
  end

  -- Add the user prompt at the end
  if prompt_text ~= '' then
    table.insert(sections, prompt_text)
  end

  local message = table.concat(sections, '\n\n')
  return { message = message, images = images }
end

---@private
function M._format_context_block(ctx)
  if not ctx or type(ctx) ~= 'table' then
    return nil
  end

  local context_type = ctx.context_type

  if context_type == 'selection' then
    return M._format_selection_block(ctx)
  elseif context_type == 'cursor-data' then
    return M._format_cursor_block(ctx)
  elseif context_type == 'diagnostics' then
    return M._format_diagnostics_block(ctx)
  elseif context_type == 'current-file' then
    return M._format_current_file_block(ctx)
  elseif context_type == 'git_diff' then
    return M._format_git_diff_block(ctx)
  elseif context_type == 'buffer' then
    return M._format_buffer_block(ctx)
  end

  -- Generic context: just return the content if present
  if ctx.content then
    return tostring(ctx.content)
  end

  return nil
end

---@private
function M._format_selection_block(ctx)
  local file = ctx.file
  local content = ctx.content or ''
  local lines = ctx.lines or ''

  if not file then
    return nil
  end

  local parts = {
    string.format('**Selection from `%s` (lines %s):**', file.name or file.path or 'unknown', lines),
    '```' .. (file.extension or ''),
    content,
    '```',
  }
  return table.concat(parts, '\n')
end

---@private
function M._format_cursor_block(ctx)
  local parts = {
    '**Cursor position:**',
    string.format('- Line %d, Column %d', ctx.line or 0, ctx.column or 0),
  }

  if ctx.line_content then
    table.insert(parts, '- Current line: `' .. ctx.line_content .. '`')
  end

  if ctx.lines_before and #ctx.lines_before > 0 then
    table.insert(parts, '- Lines before cursor:')
    table.insert(parts, '```')
    for _, line in ipairs(ctx.lines_before) do
      table.insert(parts, line)
    end
    table.insert(parts, '```')
  end

  if ctx.lines_after and #ctx.lines_after > 0 then
    table.insert(parts, '- Lines after cursor:')
    table.insert(parts, '```')
    for _, line in ipairs(ctx.lines_after) do
      table.insert(parts, line)
    end
    table.insert(parts, '```')
  end

  return table.concat(parts, '\n')
end

---@private
function M._format_diagnostics_block(ctx)
  local diagnostics = ctx.content
  if not diagnostics or type(diagnostics) ~= 'table' or #diagnostics == 0 then
    return nil
  end

  local parts = { '**Diagnostics:**' }
  for _, diag in ipairs(diagnostics) do
    local severity = vim.diagnostic.severity[diag.severity] or 'Unknown'
    local msg = string.format(
      '- [%s] %s (line %d, col %d)',
      severity,
      diag.message or '',
      diag.lnum and diag.lnum + 1 or 0,
      diag.col and diag.col + 1 or 0
    )
    table.insert(parts, msg)
  end

  return table.concat(parts, '\n')
end

---@private
function M._format_current_file_block(ctx)
  local path = ctx.path
  if not path then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines then
    return string.format('**Current file:** `%s` (could not read)', path)
  end

  local ext = vim.fn.fnamemodify(path, ':e')
  local parts = {
    string.format('**Current file `%s`:**', path),
    '```' .. ext,
    table.concat(lines, '\n'),
    '```',
  }
  return table.concat(parts, '\n')
end

---@private
function M._format_git_diff_block(ctx)
  local diff = ctx.content or ctx.diff
  if not diff or diff == '' then
    return nil
  end

  local parts = {
    '**Git diff:**',
    '```diff',
    diff,
    '```',
  }
  return table.concat(parts, '\n')
end

---@private
function M._format_buffer_block(ctx)
  local content = ctx.content
  if not content or content == '' then
    return nil
  end

  local parts = {
    '**Buffer content:**',
    '```',
    content,
    '```',
  }
  return table.concat(parts, '\n')
end

---@private
function M._format_file_block(part)
  if not part.filename then
    return nil
  end

  -- For images, just reference them
  local mime = part.mime or ''
  if mime:match('^image/') then
    return string.format('**Attached image:** `%s`', part.filename)
  end

  -- For text files, inline the content
  local ok, lines = pcall(vim.fn.readfile, part.filename)
  if not ok or not lines then
    return string.format('**File:** `%s` (could not read)', part.filename)
  end

  local ext = vim.fn.fnamemodify(part.filename, ':e')
  local parts = {
    string.format('**File `%s`:**', part.filename),
    '```' .. ext,
    table.concat(lines, '\n'),
    '```',
  }
  return table.concat(parts, '\n')
end

---@private
function M._encode_image(filepath)
  local ok, data = pcall(function()
    if vim.fn.filereadable(filepath) ~= 1 then
      return nil
    end
    local bytes = vim.fn.readfile(filepath, 'b')
    if type(bytes) == 'table' then
      bytes = table.concat(bytes, '\n')
    end
    local result = vim.fn.system({ 'base64' }, bytes)
    if vim.v.shell_error ~= 0 then
      return nil
    end
    return result:gsub('%s+$', '')
  end)

  if not ok or not data or data == '' then
    return nil
  end

  local ext = vim.fn.fnamemodify(filepath, ':e'):lower()
  local mime_types = {
    png = 'image/png',
    jpg = 'image/jpeg',
    jpeg = 'image/jpeg',
    gif = 'image/gif',
    webp = 'image/webp',
  }

  return {
    type = 'image',
    data = data,
    mimeType = mime_types[ext] or 'image/png',
  }
end

return M
