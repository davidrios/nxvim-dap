-- The Debug Adapter Protocol wire codec: `Content-Length: N\r\n\r\n<N bytes JSON>`,
-- the exact framing LSP uses. The transport (`nx.process`) hands us RAW, un-split
-- byte chunks — a single read can carry half a header, several whole messages, or a
-- message split mid-body — so the decoder is a stateful accumulator that emits one
-- decoded table per complete frame and buffers the partial tail for the next chunk.
--
-- (This is why nxvim-dap needs the duplex `nx.process` and not `nx.run_stream`: the
-- latter newline-splits stdout, which shreds a frame whose JSON body or `\r\n\r\n`
-- separator the split falls inside.)

local M = {}

-- Frame a DAP message table into a wire string ready for `handle:write`.
function M.encode(msg)
  local body = nx.json.encode(msg)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

-- Parse the Content-Length out of a header block (case-insensitive, tolerant of an
-- accompanying Content-Type line). Returns the integer byte count or nil.
local function content_length(header)
  for line in (header .. "\r\n"):gmatch("(.-)\r\n") do
    local key, value = line:match("^%s*(%S+)%s*:%s*(%d+)%s*$")
    if key and key:lower() == "content-length" then
      return tonumber(value)
    end
  end
end

-- Build a stateful decoder. Feed it raw chunks via the returned `feed(chunk)`; it
-- invokes `on_message(table)` once per complete frame. A malformed header (no
-- Content-Length) or an undecodable body calls `on_error(msg)` (LOUD — never a
-- silent drop) and resyncs.
function M.decoder(on_message, on_error)
  local buf = ""
  local function fail(msg)
    if on_error then
      on_error(msg)
    end
  end
  return function(chunk)
    buf = buf .. chunk
    while true do
      local header_end = buf:find("\r\n\r\n", 1, true)
      if not header_end then
        return -- header still incomplete
      end
      local header = buf:sub(1, header_end - 1)
      local len = content_length(header)
      if not len then
        fail("nxvim-dap: missing Content-Length in DAP header: " .. header)
        buf = "" -- can't trust the stream position; resync from empty
        return
      end
      local body_start = header_end + 4 -- skip the "\r\n\r\n"
      if #buf - body_start + 1 < len then
        return -- body not fully arrived yet; wait for more chunks
      end
      local body = buf:sub(body_start, body_start + len - 1)
      buf = buf:sub(body_start + len)
      local ok, decoded = pcall(nx.json.decode, body)
      if ok then
        on_message(decoded)
      else
        fail("nxvim-dap: undecodable DAP body: " .. tostring(decoded))
      end
    end
  end
end

return M
