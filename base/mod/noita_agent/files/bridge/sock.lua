-- Lua-side socket server, via LuaJIT FFI and Winsock.
--
-- Why this exists: the file bridge is polled once per frame, so its floor is one
-- frame (~16.7 ms) plus fsync/rename overhead. A socket lets the game answer
-- within the same frame and, more importantly, lets it PUSH events instead of
-- being asked. Measured in-game: LuaJIT 2.0.4 is present and `require("ffi")`
-- works, so no external DLL is needed -- ws2_32 is already in the process.
--
-- STATUS: OPT-IN AND NOT YET TRUSTED. A run that enabled it unconditionally
-- ended with the game's main thread unresponsive and the listener stuck on
-- 0.0.0.0 with a CLOSE_WAIT client, so it is off by default until it has been
-- switched on deliberately and observed. The file bridge remains the default
-- transport and is unaffected by anything in this file.
--
-- Design constraints, all forced by living inside the game loop:
--   * NOTHING may block. Every call is non-blocking and the whole server is
--     driven by one `poll()` per frame from OnWorldPreUpdate.
--   * Work per frame is HARD BOUNDED (accepts, bytes read, bytes written,
--     clients), so a noisy or hostile local client cannot stretch a frame.
--   * A connection that errors or is half-closed is closed immediately, never
--     left in CLOSE_WAIT.
--   * If anything fails to initialise, the module reports it and the file
--     bridge keeps working. A failed socket must never take the bridge down.
--
-- Protocol: POST newline-delimited-or-plain JSON bodies, same methods as the
-- file bridge. Batches are supported via {"calls":[...]}.

sock = sock or {}

local ffi_ok, ffi = pcall(require, "ffi")
local S = {}

-- ---------------------------------------------------------------- bindings
--
-- Three separate traps live in this block, all of which produced a silently
-- broken socket at some point:
--
--   1. Everything must be in ONE ffi.cdef call. Each call is parsed alone, so a
--      struct declared in a later call cannot see a typedef from an earlier one
--      ("declaration specifier expected near 'SOCKET'").
--   2. ffi.cdef parses C declarations, NOT Lua: a `--` comment inside it is read
--      as two minus signs ("declaration specifier expected near '-'"). No Lua
--      comments may appear inside the string.
--   3. The command parameter of ioctlsocket must be 32-bit. Declaring it as
--      `long` makes LuaJIT pass 8 bytes on 32-bit Windows, the option fails with
--      WSAEOPNOTSUPP (10045), the listener stays BLOCKING, and the next accept()
--      freezes the game.
--
-- The result is checked rather than swallowed: a cdef failure here used to leave
-- the mod erroring out during game initialisation with no working bridge.
local cdef_error = nil
if ffi_ok then
  local ok, err = pcall(ffi.cdef, [[
    typedef unsigned int   u_int;
    typedef unsigned short u_short;
    typedef unsigned char  u_char;
    typedef uintptr_t      SOCKET;
    typedef struct { u_char data[512]; } WSADATA_PAD;
    typedef struct { unsigned int fd_count; SOCKET fd_array[64]; } fd_set_t;
    typedef struct { unsigned short family; unsigned short port; unsigned int addr; char zero[8]; } sockaddr_in_t;

    int      WSAStartup(unsigned short wVersionRequested, WSADATA_PAD* lpWSAData);
    int      WSACleanup(void);
    int      WSAGetLastError(void);
    SOCKET   socket(int af, int type, int protocol);
    int      bind(SOCKET s, const void* name, int namelen);
    int      listen(SOCKET s, int backlog);
    SOCKET   accept(SOCKET s, void* addr, int* addrlen);
    int      closesocket(SOCKET s);
    int      send(SOCKET s, const char* buf, int len, int flags);
    int      recv(SOCKET s, char* buf, int len, int flags);
    int      ioctlsocket(SOCKET s, int32_t cmd, unsigned long* argp);
    int      WSAEventSelect(SOCKET s, void* hEventObject, int32_t lNetworkEvents);
    int      setsockopt(SOCKET s, int level, int optname, const char* optval, int optlen);
    int      getsockname(SOCKET s, void* name, int* namelen);
    int      select(int nfds, void* rd, void* wr, void* ex, void* tv);
    unsigned short htons(unsigned short hostshort);
    unsigned int   htonl(unsigned int hostlong);
    unsigned short ntohs(unsigned short netshort);
    unsigned int   ntohl(unsigned int netlong);
  ]])
  if not ok then cdef_error = tostring(err) end

  -- Everything below depends on the declarations above actually existing, so it
  -- must not run when cdef failed (ffi.cast on an undeclared type would throw).
  if not cdef_error then
    S.AF_INET = 2
    S.SOCK_STREAM = 1
    S.IPPROTO_TCP = 6
    S.SOL_SOCKET = 0xFFFF
    S.SO_REUSEADDR = 0x0004
    S.FIONBIO = 0x8004667E
    S.INVALID = ffi.cast("SOCKET", -1)
    S.nonblocking_failed = false

    local ok_load, ws = pcall(ffi.load, "ws2_32")
    if not ok_load then ok_load, ws = pcall(ffi.load, "ws2_32.dll") end
    if ok_load then S.ws = ws end
  end
end

-- ---------------------------------------------------------------- state

local server = nil          -- SOCKET
local port = nil
local clients = {}          -- [SOCKET] = { rx = {}, rxlen, tx = {}, txhead, drop }

-- Hard per-frame bounds. These exist so no client behaviour can stretch a frame.
local MAX_CLIENTS = 4
local MAX_ACCEPTS_PER_FRAME = 1
local MAX_RX = 512 * 1024          -- per connection
local MAX_TX = 256 * 1024          -- per connection
local MAX_RECV_PER_FRAME = 65536   -- per connection per frame
local MAX_SEND_PER_FRAME = 65536   -- per connection per frame
local READ_CHUNK = 8192

local counters = { accepted = 0, closed = 0, requests = 0, bytes_in = 0, bytes_out = 0, errors = 0 }
local last_error = nil

local function note_error(where)
  counters.errors = counters.errors + 1
  local code = S.ws and S.ws.WSAGetLastError() or -1
  last_error = string.format("%s: WSA error %d", where, code)
end

local function close_client(cs)
  clients[cs] = nil
  pcall(function() S.ws.closesocket(cs) end)
  counters.closed = counters.closed + 1
end

-- Put a socket into non-blocking mode.
--
-- ioctlsocket(FIONBIO) does NOT work in this process: every variant (the classic
-- 0x8004667E, a derived value, and passing the mode directly) returns
-- WSAEOPNOTSUPP (10045). Measured in-game, not assumed.
--
-- WSAEventSelect with a null event object and zero network events is the
-- documented way to request non-blocking mode, and it returns 0 here. That is
-- what we use.
--
-- This matters more than style: a socket left in blocking mode makes the next
-- accept()/recv() freeze the game's main thread, which is exactly the hang that
-- was observed earlier.
local function set_nonblocking(s)
  local rc = S.ws.WSAEventSelect(s, nil, 0)

  if rc ~= 0 then
    -- fall back to ioctlsocket in case a future build differs, and record which
    -- one was needed so the choice is never a guess
    local mode = ffi.new("unsigned long[1]", 1)
    local rc2 = S.ws.ioctlsocket(s, S.FIONBIO, mode)
    if rc2 ~= 0 then
      note_error("set_nonblocking (WSAEventSelect and ioctlsocket both failed)")
      S.nonblocking_failed = true
      return false, string.format("WSAEventSelect=%d ioctlsocket=%d", rc, rc2)
    end
    S.nonblocking_via = "ioctlsocket"
    return true
  end

  S.nonblocking_via = "WSAEventSelect"
  return true
end

-- Is a connection waiting? Only call accept() when this says yes, so that even a
-- mistakenly-blocking listener cannot stall a frame.
local function has_pending_connection(listen_socket)
  local set = ffi.new("fd_set_t")
  set.fd_count = 1
  set.fd_array[0] = listen_socket
  local tv = ffi.new("struct { int32_t sec; int32_t usec; }")
  tv.sec = 0
  tv.usec = 0
  local rc = S.ws.select(0, ffi.cast("void*", set), nil, nil, ffi.cast("void*", tv))
  return rc == 1
end

local function sockaddr(host_be, port_be)
  local sa = ffi.new("sockaddr_in_t")
  sa.family = S.AF_INET
  sa.port = port_be
  sa.addr = host_be
  return sa
end

-- Winsock insists on exactly sizeof(sockaddr_in) == 16 here. LuaJIT aligns
-- structs to their largest member, so the padded size is not guaranteed to be
-- 16; passing the wrong length can silently bind differently (an earlier version
-- ended up on 0.0.0.0). Use the literal and verify the layout once.
local SOCKADDR_LEN = 16
local function layout_ok()
  if ffi.sizeof("sockaddr_in_t") ~= SOCKADDR_LEN then return false end
  -- field offsets must match the C layout: family@0 port@2 addr@4 zero@8
  local probe = ffi.new("sockaddr_in_t")
  probe.family = 0x1234
  probe.port = 0x5678
  probe.addr = 0x9ABCDEF0
  local bytes = ffi.cast("unsigned char*", probe)
  return bytes[0] == 0x34 and bytes[1] == 0x12
    and bytes[2] == 0x78 and bytes[3] == 0x56
    and bytes[4] == 0xF0 and bytes[7] == 0x9A
end

-- ---------------------------------------------------------------- lifecycle

function sock.available()
  if not ffi_ok then return false end
  if cdef_error then return false end          -- declarations failed: unusable
  return S.ws ~= nil
end

-- Why the socket is unavailable, for the panel / logs.
function sock.unavailable_reason()
  if not ffi_ok then return "LuaJIT FFI is not available in this sandbox" end
  if cdef_error then return "ffi.cdef failed: " .. cdef_error end
  if not S.ws then return "ws2_32 could not be loaded" end
  return nil
end

-- Full initialisation diagnostic. Kept because "it just says unavailable" is not
-- an acceptable answer when the same process can `require("ffi")` successfully.
function sock.diag()
  local d = {
    ffi_ok = ffi_ok,
    ffi_type = type(ffi),
    cdef_error = cdef_error,
    ws_loaded = S.ws ~= nil,
    available = sock.available(),
    reason = sock.unavailable_reason(),
  }
  if ffi_ok and not cdef_error then
    local ok, v = pcall(function() return ffi.sizeof("sockaddr_in_t") end)
    d.sockaddr_size = ok and v or ("error: " .. tostring(v))
    local ok2, v2 = pcall(function() return ffi.sizeof("fd_set_t") end)
    d.fd_set_size = ok2 and v2 or ("error: " .. tostring(v2))
    local ok3, v3 = pcall(function() return ffi.sizeof("SOCKET") end)
    d.socket_size = ok3 and v3 or ("error: " .. tostring(v3))
  end
  return d
end

function sock.stats()
  local n = 0
  for _ in pairs(clients) do n = n + 1 end
  return {
    started = server ~= nil,
    port = port,
    clients = n,
    accept = counters.accepted,
    close = counters.closed,
    requests = counters.requests,
    bytes_in = counters.bytes_in,
    bytes_out = counters.bytes_out,
    errors = counters.errors,
    last_error = last_error,
  }
end

-- Starts the listener. Returns ok, port_or_error.
function sock.start(want_port)
  if not sock.available() then
    return false, sock.unavailable_reason() or "socket unavailable"
  end
  if server then return true, port end

  local wsa = ffi.new("WSADATA_PAD")
  local rc = S.ws.WSAStartup(0x0202, wsa)
  if rc ~= 0 then
    last_error = "WSAStartup failed: " .. tostring(rc)
    return false, last_error
  end

  local s = S.ws.socket(S.AF_INET, S.SOCK_STREAM, S.IPPROTO_TCP)
  if s == S.INVALID then
    note_error("socket")
    return false, last_error
  end

  -- refuse to run with a sockaddr layout we have not verified: binding with the
  -- wrong struct silently produces the wrong address
  if not layout_ok() then
    S.ws.closesocket(s)
    last_error = string.format(
      "sockaddr_in_t layout is wrong (size %d, expected %d); refusing to bind",
      ffi.sizeof("sockaddr_in_t"), SOCKADDR_LEN)
    return false, last_error
  end

  local one = ffi.new("int[1]", 1)
  S.ws.setsockopt(s, S.SOL_SOCKET, S.SO_REUSEADDR, ffi.cast("const char*", one), 4)

  -- Loopback only. This is a local control channel and must never be reachable
  -- from the network; a previous version ended up on 0.0.0.0, which is the
  -- symptom that made the bind path suspect.
  local sa = sockaddr(S.ws.htonl(0x7F000001), S.ws.htons(want_port or 0))
  local brc = S.ws.bind(s, ffi.cast("const void*", sa), SOCKADDR_LEN)
  if brc ~= 0 then
    note_error("bind")
    S.ws.closesocket(s)
    return false, last_error
  end
  if S.ws.listen(s, 4) ~= 0 then
    note_error("listen")
    S.ws.closesocket(s)
    return false, last_error
  end
  if not set_nonblocking(s) then
    -- Refuse to serve a blocking listener: the first accept() with no pending
    -- connection would freeze the game. Better to have no socket at all.
    S.ws.closesocket(s)
    return false, "could not set the listener non-blocking (" .. tostring(last_error) .. ")"
  end

  -- Discover the port the OS picked when we asked for 0, and verify the bind
  -- address actually took. A wrong sockaddr layout is a silent failure mode that
  -- would leave the listener reachable from the network, so it is checked here
  -- rather than assumed.
  local out = ffi.new("sockaddr_in_t")
  local outlen = ffi.new("int[1]", SOCKADDR_LEN)
  local bound_addr = nil
  if S.ws.getsockname(s, ffi.cast("void*", out), outlen) == 0 then
    port = S.ws.ntohs(out.port)
    bound_addr = S.ws.ntohl(out.addr)
  else
    port = want_port
  end

  server = s
  local addr_note = (bound_addr == 0x7F000001) and "127.0.0.1"
    or string.format("addr=%s (expected 127.0.0.1!)", tostring(bound_addr))
  return true, port, addr_note
end

function sock.stop()
  for cs in pairs(clients) do pcall(function() S.ws.closesocket(cs) end) end
  clients = {}
  if server then pcall(function() S.ws.closesocket(server) end) server = nil end
  port = nil
  return true
end

-- ---------------------------------------------------------------- io helpers

local function queue_response(cs, body)
  local c = clients[cs]
  if not c then return end
  local head = table.concat({
    "HTTP/1.1 200 OK\r\n",
    "Content-Type: application/json\r\n",
    "Content-Length: ", tostring(#body), "\r\n",
    "Connection: keep-alive\r\n",
    "\r\n",
  })
  local total = 0
  for i = c.txhead, #c.tx do total = total + #c.tx[i] end
  if total + #head + #body > MAX_TX then
    c.drop = true      -- client is not draining; drop it rather than grow
    return
  end
  c.tx[#c.tx + 1] = head
  c.tx[#c.tx + 1] = body
end

local function find_header_end(buf)
  local s, e = string.find(buf, "\r\n\r\n", 1, true)
  if s then return s, e end
  s, e = string.find(buf, "\n\n", 1, true)
  if s then return s, e end
  return nil
end

local function parse_request(head, body)
  local method, target = head:match("^(%u+)%s+(%S+)")
  return { method = method, target = target, body = body }
end

-- Handler installed by rpc.lua: function(body_string) -> response_body_string
--
-- The handler takes the raw BODY STRING, not the parsed request table: the
-- rpc side owns JSON decoding so the file bridge and the socket share one
-- code path. Passing the table here was a real bug (json.decode on a table
-- yields nil, so every socket request answered "malformed JSON body").
local handler = nil
function sock.set_handler(fn) handler = fn end
function sock.has_handler() return handler ~= nil end

local function handle_request(cs, req)
  if not handler then
    queue_response(cs, '{"ok":false,"error":"no handler installed"}')
    return
  end
  counters.requests = counters.requests + 1
  local ok, res = pcall(handler, req.body)
  if not ok then
    res = string.format('{"ok":false,"error":%q}', tostring(res))
  end
  if type(res) ~= "string" then res = '{"ok":false,"error":"handler returned non-string"}' end
  queue_response(cs, res)
end

-- ---------------------------------------------------------------- guard
--
-- The honest position on safety: the code below is non-blocking by construction
-- and bounded per frame, but that is an argument, not evidence. A previous run
-- left the game unresponsive and there was no crash dump or Lua error to explain
-- it, so it may equally have been Noita's own long world load. Rather than guess
-- twice, this guard makes the question measurable AND self-correcting:
--
--   * every socket operation is timed
--   * if one blocks for longer than BLOCK_BUDGET_MS, the socket is shut down
--     immediately and the event is recorded, so the worst case is one slow frame
--     and a disabled socket -- never a stuck game
--   * per-frame work is already capped (accepts, bytes, clients)
--
-- `sock.guard_report()` returns the evidence for whoever asks next.

local BLOCK_BUDGET_MS = 100
local guard = {
  worst_op_ms = 0,
  worst_op = nil,
  frames = 0,
  total_poll_ms = 0,
  trips = 0,
  tripped_reason = nil,
  history = {},
}

local function now_ms()
  -- os.clock is CPU time; wall time is what a stall shows up in, and Noita's
  -- mod sandbox has os.time but not sub-second resolution. os.clock is the only
  -- sub-second timer available, and for a busy-wait stall it is sufficient.
  local os_ = rawget(_G, "os")
  if type(os_) == "table" and type(os_.clock) == "function" then
    local ok, t = pcall(os_.clock)
    if ok and type(t) == "number" then return t * 1000 end
  end
  return nil
end

-- Runs one socket operation under the guard.
--
-- Returns a result table with an explicit `status` field, because an ambiguous
-- return value here would be dangerous: a WSA error message must never be
-- mistaken for a SOCKET handle. status is one of:
--   "ok"      -> result holds the value
--   "blocked" -> the guard fired and the socket has been shut down
--   "error"   -> the operation raised
local function timed(op_name, fn)
  local t0 = now_ms()
  local ok, value = pcall(fn)
  local t1 = now_ms()

  if t0 and t1 then
    local dt = t1 - t0
    guard.total_poll_ms = guard.total_poll_ms + dt
    if dt > guard.worst_op_ms then
      guard.worst_op_ms = dt
      guard.worst_op = op_name
    end
    if dt > BLOCK_BUDGET_MS then
      guard.trips = guard.trips + 1
      guard.tripped_reason = string.format(
        "%s blocked for %.0f ms (budget %d ms); socket shut down",
        op_name, dt, BLOCK_BUDGET_MS)
      guard.history[#guard.history + 1] = {
        op = op_name, ms = dt, frame = GameGetFrameNum(),
      }
      return { status = "blocked", ms = dt }
    end
  end

  if not ok then return { status = "error", error = tostring(value) } end
  return { status = "ok", value = value }
end

-- ---------------------------------------------------------------- poll

-- Called once per frame. Never blocks, never throws, and self-disables if it
-- ever does block: a socket problem must not be able to break the game.
function sock.poll()
  if not server then return end
  guard.frames = guard.frames + 1

  -- Accept new connections (hard bounded so a connection flood cannot stall).
  -- Guarded by a select() pre-check so accept() is only ever called when a
  -- connection is actually pending: even a mistakenly-blocking listener cannot
  -- stall a frame.
  local accepted = 0
  while accepted < MAX_ACCEPTS_PER_FRAME do
    if not has_pending_connection(server) then break end
    local r = timed("accept", function() return S.ws.accept(server, nil, nil) end)
    if r.status == "blocked" then sock.stop() return end
    if r.status == "error" then break end
    local cs = r.value
    if cs == nil or cs == S.INVALID then break end
    local n = 0
    for _ in pairs(clients) do n = n + 1 end
    if n >= MAX_CLIENTS then
      pcall(function() S.ws.closesocket(cs) end)
      counters.closed = counters.closed + 1
    else
      if not set_nonblocking(cs) then
        -- a blocking client socket would stall us on recv; drop it instead
        pcall(function() S.ws.closesocket(cs) end)
        counters.closed = counters.closed + 1
      else
        clients[cs] = { rx = {}, rxlen = 0, tx = {}, txhead = 1 }
        counters.accepted = counters.accepted + 1
      end
    end
    accepted = accepted + 1
  end

  for cs, c in pairs(clients) do
    if c.drop then
      close_client(cs)
    else
      local dead = false

      -- 1) flush queued output, bounded per frame
      local sent_budget = MAX_SEND_PER_FRAME
      while c.txhead <= #c.tx and sent_budget > 0 do
        local chunk = table.concat(c.tx, "", c.txhead)
        local r = timed("send", function() return S.ws.send(cs, chunk, #chunk, 0) end)
        if r.status == "blocked" then sock.stop() return end
        if r.status == "error" then dead = true break end
        local n = r.value
        if type(n) ~= "number" or n < 0 then dead = true break end
        counters.bytes_out = counters.bytes_out + n
        sent_budget = sent_budget - n
        c.tx = {}
        c.txhead = 1
      end

      -- 2) read at most MAX_RECV_PER_FRAME bytes, then stop (bounded work)
      if not dead then
        local budget = MAX_RECV_PER_FRAME
        local buf = ffi.new("char[?]", READ_CHUNK)
        while budget > 0 do
          local want = math.min(READ_CHUNK, budget)
          local r = timed("recv", function() return S.ws.recv(cs, buf, want, 0) end)
          if r.status == "blocked" then sock.stop() return end
          if r.status == "error" then dead = true break end
          local got = r.value
          if type(got) ~= "number" then dead = true break end
          if got > 0 then
            c.rx[#c.rx + 1] = ffi.string(buf, got)
            c.rxlen = c.rxlen + got
            counters.bytes_in = counters.bytes_in + got
            budget = budget - got
            if c.rxlen > MAX_RX then dead = true break end
          elseif got == 0 then
            dead = true       -- orderly close: never leave it in CLOSE_WAIT
            break
          else
            break             -- WSAEWOULDBLOCK: nothing more right now
          end
        end
      end

      -- 3) parse ONE complete request, keeping any pipelined remainder
      if not dead then
        local data = table.concat(c.rx)
        local hs, he = find_header_end(data)
        if hs then
          local head = data:sub(1, hs - 1)
          local len = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
          local body_start = he + 1
          if #data >= body_start - 1 + len then
            local body = data:sub(body_start, body_start + len - 1)
            local rest = data:sub(body_start + len)
            c.rx = rest ~= "" and { rest } or {}
            c.rxlen = #rest
            handle_request(cs, parse_request(head, body))
          end
        end
      end

      if dead then close_client(cs) end
    end
  end
end

function sock.guard_report()
  local avg = guard.frames > 0 and (guard.total_poll_ms / guard.frames) or 0
  return {
    frames_polled = guard.frames,
    avg_poll_ms = math.floor(avg * 1000) / 1000,
    worst_op = guard.worst_op,
    worst_op_ms = math.floor(guard.worst_op_ms * 1000) / 1000,
    block_budget_ms = BLOCK_BUDGET_MS,
    trips = guard.trips,
    tripped_reason = guard.tripped_reason,
    nonblocking_failed = S.nonblocking_failed,
    nonblocking_via = S.nonblocking_via,
    history = guard.history,
    verdict = (guard.trips == 0)
      and "no socket operation has ever exceeded the block budget"
      or "the socket blocked at least once and was shut down automatically",
  }
end

return sock

