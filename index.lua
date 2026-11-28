-- Official Antigravity CLI (ACP) harness plugin for Bazaar Compute 0.4.

local task = require("bazaar.task")
local timers = require("bazaar.timers")
local process = require("bazaar.process")
local json = require("bazaar.json")
local time = require("bazaar.time")
local log = require("bazaar.log")
local crypto = require("bazaar.crypto")
local secrets = require("bazaar.secrets")
local okFs, fsMod = pcall(require, "bazaar.fs")
local fs = (okFs and type(fsMod) == "table") and fsMod or nil

local state = require("./state")

local PLUGIN_VERSION = "0.4.0-rc.1"
local EXECUTOR_ERROR_PREFIX = "\n⚠ "
local SCHEDULE_TITLES = { ["Run schedule"] = true, ["Running schedule"] = true }
local SUBAGENT_TITLES = { ["Run invoke_subagent"] = true, ["Running invoke_subagent"] = true }

local MAX_APPROVAL_DETAIL = 4000
local MAX_LINE_BUFFER_BYTES = 16 * 1024 * 1024
local DEFERRED_POLL_MS = 1000
local DEFERRED_QUIET_MS = 500
local POST_WORK_WAKE_GRACE_MS = 3000
local DEFERRED_REPLY_TIMEOUT_MS = 900000
local MCP_DISCOVERY_DELAY_MS = 2000
local INSTRUCTION_WATCH_INTERVAL_MS = 5000
local DEFAULT_STARTUP_TIMEOUT_SEC = 60
local DEFAULT_SHUTDOWN_TIMEOUT_SEC = 5

local USAGE_FIELD_MAP = {
  inputTokens = "inputTokens",
  cachedReadTokens = "cachedInputTokens",
  cachedWriteTokens = "cacheWriteInputTokens",
  outputTokens = "outputTokens",
  thoughtTokens = "reasoningOutputTokens",
  totalTokens = "totalTokens",
}

local MIME_BY_EXT = {
  [".png"] = "image/png",
  [".jpg"] = "image/jpeg",
  [".jpeg"] = "image/jpeg",
  [".gif"] = "image/gif",
  [".webp"] = "image/webp",
  [".svg"] = "image/svg+xml",
  [".bmp"] = "image/bmp",
  [".ico"] = "image/x-icon",
  [".pdf"] = "application/pdf",
  [".txt"] = "text/plain",
  [".md"] = "text/markdown",
  [".markdown"] = "text/markdown",
  [".json"] = "application/json",
  [".yaml"] = "text/yaml",
  [".yml"] = "text/yaml",
  [".toml"] = "text/plain",
  [".xml"] = "application/xml",
  [".csv"] = "text/csv",
  [".html"] = "text/html",
  [".htm"] = "text/html",
  [".css"] = "text/css",
  [".js"] = "text/javascript",
  [".mjs"] = "text/javascript",
  [".cjs"] = "text/javascript",
  [".ts"] = "text/plain",
  [".tsx"] = "text/plain",
  [".py"] = "text/x-python",
  [".go"] = "text/plain",
  [".rs"] = "text/plain",
  [".sh"] = "text/x-shellscript",
  [".sql"] = "text/plain",
  [".log"] = "text/plain",
  [".mp3"] = "audio/mpeg",
  [".wav"] = "audio/wav",
  [".ogg"] = "audio/ogg",
  [".opus"] = "audio/opus",
  [".mp4"] = "video/mp4",
  [".webm"] = "video/webm",
  [".zip"] = "application/zip",
  [".gz"] = "application/gzip",
  [".tar"] = "application/x-tar",
}

local ARRAY_MT = (type(getmetatable) == "function" and json.array)
  and getmetatable(json.array({}))
  or nil
local JSON_NULL = json.null

local sessions = {}

local function isNull(v)
  return v == nil or (JSON_NULL ~= nil and v == JSON_NULL)
end

local function makeArray(tbl)
  if json.array then
    return json.array(tbl or {})
  end
  return tbl or {}
end

local function makeRpcError(message, code)
  return {
    __kind = "RpcError",
    message = tostring(message or ""),
    code = code,
  }
end

local function makeInvalidParamsError(message)
  return {
    __kind = "InvalidParamsError",
    message = tostring(message or ""),
  }
end

local function isFiniteNumber(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function trim(s)
  if isNull(s) then
    return ""
  end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function startsWith(str, prefix)
  if type(str) ~= "string" or type(prefix) ~= "string" then
    return false
  end
  return str:sub(1, #prefix) == prefix
end

local function endsWith(str, suffix)
  if type(str) ~= "string" or type(suffix) ~= "string" then
    return false
  end
  local n = #suffix
  if n == 0 then
    return true
  end
  return #str >= n and str:sub(#str - n + 1) == suffix
end

local function isNonEmptyString(v)
  return type(v) == "string" and v ~= ""
end

local function isTruthyValue(v)
  if isNull(v) or v == false or v == "" or v == 0 then
    return false
  end
  return true
end

local function firstNonEmpty(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" and v ~= "" then
      return v
    end
  end
  return ""
end

local function isArray(value)
  if type(value) ~= "table" then
    return false
  end
  if ARRAY_MT ~= nil and getmetatable(value) == ARRAY_MT then
    return true
  end
  local count = 0
  local maxIdx = 0
  for k in pairs(value) do
    if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 then
      return false
    end
    count = count + 1
    if k > maxIdx then
      maxIdx = k
    end
  end
  return count > 0 and maxIdx == count
end

local function isPlainObject(value)
  if type(value) ~= "table" then
    return false
  end
  if ARRAY_MT ~= nil and getmetatable(value) == ARRAY_MT then
    return false
  end
  local count = 0
  local allSeqInt = true
  local maxIdx = 0
  for k in pairs(value) do
    count = count + 1
    if allSeqInt then
      if type(k) == "number" and math.type(k) == "integer" and k >= 1 then
        if k > maxIdx then
          maxIdx = k
        end
      else
        allSeqInt = false
      end
    end
  end
  if count > 0 and allSeqInt and maxIdx == count then
    return false
  end
  return true
end

local function errorToString(err)
  if type(err) == "table" and not isNull(err.message) then
    return tostring(err.message)
  end
  if isNull(err) then
    return ""
  end
  return tostring(err)
end

local function nowMs()
  if type(timers.nowMs) == "function" then
    return timers.nowMs()
  end
  return time.nowMs()
end

local function clampTimerDelayMs(ms)
  local rawMax = tonumber(timers.maxDelayMs)
  local maxDelay = (isFiniteNumber(rawMax) and rawMax > 0) and math.floor(rawMax) or 2147483647
  local n = tonumber(ms)
  if not isFiniteNumber(n) or n <= 1 then
    return 1
  end
  local ceiled = math.ceil(n)
  if ceiled > maxDelay then
    return maxDelay
  end
  return ceiled
end

local function createTimer(ms)
  return timers.create(clampTimerDelayMs(ms))
end

local function cancelTimerSafe(timer)
  if not timer then
    return
  end
  pcall(timer.cancel, timer)
end

local function positiveTimeoutSec(raw, fallbackSec)
  local n = tonumber(raw)
  if isFiniteNumber(n) and n > 0 then
    return n
  end
  return fallbackSec
end

local function resolveApiKey(config)
  local s1, s2 = nil, nil
  if type(secrets.get) == "function" then
    s1 = secrets.get("apiKey")
    s2 = secrets.get("api_key")
  end
  local cfg = type(config) == "table" and config or nil
  local raw = firstNonEmpty(s1, s2, cfg and cfg.apiKey, cfg and cfg.api_key)
  local key = (trim(raw) ~= "") and raw or ""
  if key ~= "" and type(secrets.register) == "function" then
    pcall(secrets.register, key)
  end
  if key ~= "" then
    return key
  end
  return nil
end

local function currentOption(packet, id)
  local opts = type(packet) == "table" and packet.configOptions or nil
  if not isArray(opts) then
    return nil
  end
  for _, entry in ipairs(opts) do
    if type(entry) == "table" and entry.id == id then
      if isNull(entry.currentValue) then
        return nil
      end
      return entry.currentValue
    end
  end
  return nil
end

local function optionChoices(packet, id)
  local out = makeArray({})
  local opts = type(packet) == "table" and packet.configOptions or nil
  if not isArray(opts) then
    return out
  end
  for _, entry in ipairs(opts) do
    if type(entry) == "table" and entry.id == id and isArray(entry.options) then
      for _, o in ipairs(entry.options) do
        if type(o) == "table" then
          local val = firstNonEmpty(o.value, o.id)
          if val ~= "" then
            out[#out + 1] = val
          end
        end
      end
      return out
    end
  end
  return out
end

local function truncateDetail(value)
  local str = isNull(value) and "" or tostring(value)
  if #str <= MAX_APPROVAL_DETAIL then
    return str
  end
  if utf8 and type(utf8.len) == "function" and type(utf8.offset) == "function" then
    local charLen = utf8.len(str)
    if charLen then
      if charLen <= MAX_APPROVAL_DETAIL then
        return str
      end
      local cutByte = utf8.offset(str, MAX_APPROVAL_DETAIL)
      if cutByte and cutByte > 1 then
        return str:sub(1, cutByte - 1) .. "…"
      end
    end
  end
  return str:sub(1, MAX_APPROVAL_DETAIL - 1) .. "…"
end

local function approvalAction(tool, args)
  if tool.name == "call_mcp_tool" and isPlainObject(args) then
    local server = args.ServerName
    local mcpTool = args.ToolName
    if isNonEmptyString(server) and isNonEmptyString(mcpTool) then
      return "mcp__" .. server .. "__" .. mcpTool
    end
  end
  local kind = tool.kind
  if isNonEmptyString(kind) then
    if kind == "execute" then
      return "command_execution"
    end
    if kind == "edit" then
      return "file_change"
    end
    return kind
  end
  return "tool_permission"
end

local function approvalDetails(params, tool, args, action)
  local details = {}
  if type(params) == "table" then
    for k, v in pairs(params) do
      details[k] = v
    end
  end
  local kind = tool.kind
  local name = tool.name
  local title = tool.title

  if kind == "execute" then
    local command = isPlainObject(args) and args.CommandLine or nil
    if type(command) ~= "string" or trim(command) == "" then
      command = type(title) == "string" and title or nil
    end
    if type(command) == "string" and trim(command) ~= "" and isNull(details.command) then
      details.command = truncateDetail(trim(command))
    end
    local cwd = isPlainObject(args) and args.Cwd or nil
    if type(cwd) == "string" and trim(cwd) ~= "" and isNull(details.cwd) then
      details.cwd = trim(cwd)
    end
    local summary = isPlainObject(args) and args.toolSummary or nil
    if type(summary) == "string"
      and trim(summary) ~= ""
      and trim(summary) ~= details.command
      and isNull(details.reason)
    then
      details.reason = truncateDetail(trim(summary))
    end
    return details
  end

  if type(title) == "string" and trim(title) ~= "" and isNull(details.reason) then
    details.reason = truncateDetail(trim(title))
  end

  local rawInput
  if name == "call_mcp_tool" then
    if isNull(details.tool_name) then
      details.tool_name = action
    end
    if isPlainObject(args) then
      if args.Arguments ~= nil then
        rawInput = args.Arguments
      else
        rawInput = args
      end
    else
      rawInput = nil
    end
  else
    if type(name) == "string" and trim(name) ~= "" and isNull(details.tool_name) then
      details.tool_name = trim(name)
    end
    rawInput = args
  end

  if not isNull(rawInput) and isNull(details.tool_input) then
    local ok, encoded = pcall(json.encode, rawInput)
    if ok and isNonEmptyString(encoded) then
      details.tool_input = truncateDetail(encoded)
    end
  end
  return details
end

local function approvalDescription(tool, details)
  if tool.kind == "execute" then
    local lines = {}
    if isTruthyValue(details.command) then
      lines[#lines + 1] = tostring(details.command)
    end
    if isTruthyValue(details.cwd) then
      lines[#lines + 1] = "cwd: " .. tostring(details.cwd)
    end
    if isTruthyValue(details.reason) then
      lines[#lines + 1] = tostring(details.reason)
    end
    if #lines > 0 then
      return truncateDetail(table.concat(lines, "\n"))
    end
  end
  local parts = {}
  if isTruthyValue(details.tool_name) then
    parts[#parts + 1] = "tool: " .. tostring(details.tool_name)
  end
  if isTruthyValue(details.reason) and details.reason ~= details.tool_name then
    parts[#parts + 1] = tostring(details.reason)
  end
  if isTruthyValue(details.tool_input) then
    parts[#parts + 1] = tostring(details.tool_input)
  end
  if #parts > 0 then
    return truncateDetail(table.concat(parts, "\n"))
  end
  local fallback = isTruthyValue(tool.kind) and tostring(tool.kind) or "Approve tool execution?"
  return truncateDetail(fallback)
end

local function toolOutlivesPrompt(record)
  if type(record) ~= "table" then
    return false
  end
  local rawInput = record.rawInput
  if isPlainObject(rawInput) and rawInput.IsDaemon == true then
    return false
  end
  if record.name == "schedule" or SCHEDULE_TITLES[record.title] then
    return true
  end
  return record.kind == "execute"
end

local function isSubagentLaunch(record)
  if type(record) ~= "table" then
    return false
  end
  return record.name == "invoke_subagent" or SUBAGENT_TITLES[record.title] == true
end

local function extractExecutorError(update)
  if type(update) ~= "table" or update.sessionUpdate ~= "agent_message_chunk" then
    return nil
  end
  local content = update.content
  if not isPlainObject(content) or content.type ~= "text" then
    return nil
  end
  local text = content.text
  if type(text) == "string" and startsWith(text, EXECUTOR_ERROR_PREFIX) and endsWith(text, "\n") then
    local message = trim(text:sub(#EXECUTOR_ERROR_PREFIX + 1, -2))
    if message ~= "" then
      return message
    end
  end
  return nil
end

local function guessMimeType(filePath)
  local s = tostring(filePath or "")
  local base = s:match("([^\\/]+)$") or ""
  local dot = base:match(".*()%.")
  if not dot or dot <= 1 then
    return "application/octet-stream"
  end
  local ext = base:sub(dot):lower()
  return MIME_BY_EXT[ext] or "application/octet-stream"
end

local function encodeUriComponent(seg)
  return (tostring(seg or ""):gsub("([^A-Za-z0-9%-_%.!~%*'%(%)])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function encodePathSegments(pathStr)
  local parts = {}
  local pos = 1
  local len = #pathStr
  while true do
    local slash = pathStr:find("/", pos, true)
    if not slash then
      parts[#parts + 1] = encodeUriComponent(pathStr:sub(pos))
      break
    end
    parts[#parts + 1] = encodeUriComponent(pathStr:sub(pos, slash - 1))
    pos = slash + 1
    if pos > len then
      parts[#parts + 1] = ""
      break
    end
  end
  return table.concat(parts, "/")
end

local function pathToFileUri(filePath)
  local normalized = tostring(filePath or ""):gsub("\\", "/")
  if normalized:find("^[A-Za-z]:/") then
    local drive = normalized:sub(1, 2)
    local rest = encodePathSegments(normalized:sub(3))
    return "file:///" .. drive .. rest
  end
  local encoded = encodePathSegments(normalized)
  if startsWith(encoded, "/") then
    return "file://" .. encoded
  end
  return "file:///" .. encoded
end

local function normalizeAttachments(input)
  local out = {}
  local seen = {}
  if type(input) ~= "table" then
    return out
  end
  if isArray(input.attachmentDetails) then
    for _, item in ipairs(input.attachmentDetails) do
      if isPlainObject(item) and isNonEmptyString(item.path) then
        seen[item.path] = true
        out[#out + 1] = {
          path = item.path,
          mediaType = type(item.mediaType) == "string" and item.mediaType or "",
        }
      end
    end
  end
  if isArray(input.attachments) then
    for _, item in ipairs(input.attachments) do
      if isNonEmptyString(item) and not seen[item] then
        seen[item] = true
        out[#out + 1] = { path = item, mediaType = "" }
      elseif isPlainObject(item) and isNonEmptyString(item.path) and not seen[item.path] then
        seen[item.path] = true
        out[#out + 1] = {
          path = item.path,
          mediaType = type(item.mediaType) == "string" and item.mediaType or "",
        }
      end
    end
  end
  return out
end

local function buildAttachmentBlock(att)
  if not fs then
    error("bazaar.fs is unavailable to read attachment: " .. tostring(att.path), 0)
  end
  local mime = (isNonEmptyString(att.mediaType) and att.mediaType) or guessMimeType(att.path)
  local bytes = fs.readFile(att.path)
  if startsWith(mime, "image/") then
    return {
      type = "image",
      mimeType = mime,
      data = crypto.base64Encode(bytes),
    }
  end
  local resource = {
    uri = pathToFileUri(att.path),
    mimeType = mime,
  }
  if startsWith(mime, "text/") then
    resource.text = state.decodeUtf8(bytes, true)
  else
    resource.blob = crypto.base64Encode(bytes)
  end
  return {
    type = "resource",
    resource = resource,
  }
end

local function instructionCandidatePaths(workspace, env)
  local roots = {}
  if type(workspace) == "string" and trim(workspace) ~= "" then
    local cleanWs = trim(workspace):gsub("[\\/]+$", "")
    roots[#roots + 1] = cleanWs
    roots[#roots + 1] = cleanWs .. "/.agents"
  end
  local geminiHome = "~/.gemini"
  if type(env) == "table" then
    local home = trim(env.HOME)
    if home == "" then
      home = trim(env.USERPROFILE)
    end
    if home ~= "" then
      geminiHome = home:gsub("[\\/]+$", "") .. "/.gemini"
    end
  end
  roots[#roots + 1] = geminiHome
  roots[#roots + 1] = geminiHome .. "/config"
  local paths = {}
  for _, root in ipairs(roots) do
    paths[#paths + 1] = root .. "/AGENTS.md"
    paths[#paths + 1] = root .. "/GEMINI.md"
  end
  return paths
end

local function statInstructionSnapshot(paths)
  local snap = {}
  if not (fs and type(fs.stat) == "function") then
    return snap
  end
  for _, p in ipairs(paths) do
    local ok, st = pcall(fs.stat, p)
    if not ok then
      snap[p] = "err"
    elseif type(st) == "table" and st.exists and not st.isDir then
      snap[p] = "1:" .. tostring(st.modTimeMs or 0) .. ":" .. tostring(st.size or 0)
    else
      snap[p] = "0"
    end
  end
  return snap
end

local function runCommandCollect(command, args, env, timeoutMs, cwd)
  local execOpts = {
    command = command,
    args = makeArray(args or {}),
    env = env or {},
    timeoutMs = clampTimerDelayMs(timeoutMs),
  }
  if isNonEmptyString(cwd) then
    execOpts.cwd = cwd
  end

  local ok, res = pcall(process.exec, execOpts)
  if not ok then
    return {
      code = -1,
      timedOut = false,
      stdout = "",
      stderr = errorToString(res),
    }
  end

  local resTbl = type(res) == "table" and res or {}
  local timedOut = resTbl.timedOut == true
  local stderr = type(resTbl.stderr) == "string" and resTbl.stderr or ""
  if stderr == "" and timedOut then
    stderr = "command " .. tostring(command) .. " timed out"
  elseif stderr == "" and isNonEmptyString(resTbl.error) then
    stderr = resTbl.error
  end

  return {
    code = type(resTbl.code) == "number" and resTbl.code or -1,
    signal = isNonEmptyString(resTbl.signal) and resTbl.signal or nil,
    timedOut = timedOut,
    stdout = type(resTbl.stdout) == "string" and resTbl.stdout or "",
    stderr = stderr,
  }
end

-- ---------- UsageAccumulator ----------

local UsageAccumulator = {}
UsageAccumulator.__index = UsageAccumulator

function UsageAccumulator.new()
  return setmetatable({
    totals = {},
    contextWindow = nil,
  }, UsageAccumulator)
end

function UsageAccumulator:account(rawUsage)
  local last = {}
  if isPlainObject(rawUsage) then
    for srcKey, dstKey in pairs(USAGE_FIELD_MAP) do
      local val = rawUsage[srcKey]
      if isFiniteNumber(val) then
        last[dstKey] = val
        self.totals[dstKey] = (self.totals[dstKey] or 0) + val
      end
    end
  end
  return self:snapshot(last)
end

function UsageAccumulator:snapshot(last)
  local totalCopy = {}
  for k, v in pairs(self.totals) do
    totalCopy[k] = v
  end
  local out = {
    total = totalCopy,
    cumulative = true,
  }
  if type(last) == "table" and next(last) ~= nil then
    out.last = last
  end
  if self.contextWindow ~= nil then
    out.contextWindow = self.contextWindow
    out.modelContextWindow = self.contextWindow
  end
  return out
end

-- ---------- AcpTurn ----------

local AcpTurn = {}
AcpTurn.__index = AcpTurn

function AcpTurn.new(session, turnId)
  return setmetatable({
    session = session,
    id = turnId,
    tools = {}, -- toolCallId -> merged record
    subagentCalls = {}, -- set: callId -> true
    trailingError = nil,
    pending = {}, -- set: active session/prompt RPC IDs -> true
    replies = {}, -- rpcId -> packet
    finished = false,
    completed = false,
    cancelRequested = false,
    promptSettled = false,
    settledReason = nil,
    settledPacket = nil,

    _settleGen = 0,
    _woken = false,
    _wakeToken = nil,
    _postSettleReplyOpen = false,
    _postWorkGraceDeadlineMs = nil,
    _quietDeadlineMs = nil,
    _replyInactivityDeadlineMs = nil,

    _doneOk = nil,
    _doneResult = nil,
    _doneToken = nil,
  }, AcpTurn)
end

function AcpTurn:outlivingToolIds()
  local ids = {}
  for callId, rec in pairs(self.tools) do
    if rec.status == "in_progress" and toolOutlivesPrompt(rec) then
      ids[#ids + 1] = callId
    end
  end
  return ids
end

function AcpTurn:hasLiveDaemonTool()
  for _, rec in pairs(self.tools) do
    if rec.status == "in_progress" and isPlainObject(rec.rawInput) and rec.rawInput.IsDaemon == true then
      return true
    end
  end
  return false
end

function AcpTurn:signalWake()
  self._woken = true
  local tok = self._wakeToken
  if tok ~= nil then
    self._wakeToken = nil
    task.wakeup(tok)
  end
end

function AcpTurn:onPromptSubmitted(rpcId)
  self.pending[rpcId] = true
  self.promptSettled = false
  self.settledReason = nil
  self.settledPacket = nil
  self._postSettleReplyOpen = false
  self._postWorkGraceDeadlineMs = nil
  self._quietDeadlineMs = nil
  self._replyInactivityDeadlineMs = nil
  self._settleGen = self._settleGen + 1
  self:signalWake()
end

function AcpTurn:handleUpdate(update)
  local kind = update.sessionUpdate
  local hadOutliving = #self:outlivingToolIds() > 0

  local execErr = extractExecutorError(update)
  if execErr ~= nil then
    self.trailingError = execErr
  elseif kind ~= "config_option_update" then
    self.trailingError = nil
  end

  if kind == "agent_message_chunk" then
    local content = update.content
    local text = (type(content) == "table" and content.type == "text" and not isNull(content.text))
      and tostring(content.text)
      or ""
    if text ~= "" then
      self.session.emit({
        type = "content_delta",
        sessionId = self.session.localId,
        turnId = self.id,
        text = text,
      })
    end
  elseif kind == "agent_thought_chunk" then
    local content = update.content
    local text = (type(content) == "table" and content.type == "text" and not isNull(content.text))
      and tostring(content.text)
      or ""
    if text ~= "" then
      self.session.emit({
        type = "thought_delta",
        sessionId = self.session.localId,
        turnId = self.id,
        text = text,
      })
    end
  elseif kind == "plan" then
    if isArray(update.entries) then
      local lines = {}
      for _, e in ipairs(update.entries) do
        if type(e) == "table" and isNonEmptyString(e.content) then
          lines[#lines + 1] = e.content
        end
      end
      local text = table.concat(lines, "\n")
      if text ~= "" then
        self.session.emit({
          type = "thought_delta",
          sessionId = self.session.localId,
          turnId = self.id,
          text = text,
        })
      end
    end
  elseif kind == "tool_call" or kind == "tool_call_update" then
    local callId = not isNull(update.toolCallId) and tostring(update.toolCallId) or ""
    local prev = self.tools[callId]
    local isNew = (prev == nil)
    local merged = {}
    if prev then
      for k, v in pairs(prev) do
        merged[k] = v
      end
    end
    for k, v in pairs(update) do
      if not isNull(v) or prev == nil then
        merged[k] = v
      end
    end
    self.tools[callId] = merged

    if callId ~= "" and isSubagentLaunch(merged) then
      self.subagentCalls[callId] = true
      self.session.subagentCalls[callId] = true
    end

    local name = firstNonEmpty(
      type(merged.name) == "string" and merged.name or "",
      type(merged.title) == "string" and merged.title or "",
      type(merged.kind) == "string" and merged.kind or "",
      "tool"
    )
    if isNew then
      self.session.emit({
        type = "tool_started",
        sessionId = self.session.localId,
        turnId = self.id,
        toolName = name,
        toolCallId = callId,
      })
    end
    if update.status == "completed" or update.status == "failed" then
      local rawOut = merged.rawOutput
      local errMsg = ""
      if update.status == "failed" then
        if isPlainObject(rawOut) and type(rawOut.error) == "string" then
          errMsg = rawOut.error
        else
          errMsg = "tool failed"
        end
      end
      self.session.emit({
        type = "tool_completed",
        sessionId = self.session.localId,
        turnId = self.id,
        toolName = name,
        toolCallId = callId,
        error = errMsg,
      })
    end
  elseif kind == "usage_update" then
    if isFiniteNumber(update.size) then
      self.session.usage.contextWindow = update.size
    end
    self.session.emit({
      type = "usage_updated",
      sessionId = self.session.localId,
      turnId = self.id,
      usage = self.session.usage:snapshot(),
    })
  elseif kind == "config_option_update" then
    local model = currentOption(update, "model")
    if isNonEmptyString(model) then
      self.session.model = model
      self.session.emit({
        type = "model_updated",
        sessionId = self.session.localId,
        turnId = self.id,
        model = model,
      })
    end
  end

  if not self.promptSettled then
    return
  end

  local now = nowMs()
  if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
    if isPlainObject(update.content) and isTruthyValue(update.content.text) then
      if self.trailingError ~= nil then
        self._postSettleReplyOpen = false
        self._postWorkGraceDeadlineMs = nil
        self._quietDeadlineMs = now + DEFERRED_QUIET_MS
      else
        self._postSettleReplyOpen = true
        self._quietDeadlineMs = nil
        self._postWorkGraceDeadlineMs = nil
        self._replyInactivityDeadlineMs = now + DEFERRED_REPLY_TIMEOUT_MS
      end
    end
  elseif kind == "usage_update" then
    self._postSettleReplyOpen = false
    self._replyInactivityDeadlineMs = nil
    self._postWorkGraceDeadlineMs = nil
    self._quietDeadlineMs = now + DEFERRED_QUIET_MS
  elseif kind == "tool_call" or kind == "tool_call_update" then
    local nowOutliving = #self:outlivingToolIds() > 0
    if nowOutliving then
      self._quietDeadlineMs = nil
      self._postWorkGraceDeadlineMs = nil
      self._replyInactivityDeadlineMs = nil
    elseif hadOutliving and not nowOutliving then
      self._postWorkGraceDeadlineMs = now + POST_WORK_WAKE_GRACE_MS
      self._quietDeadlineMs = nil
    elseif kind == "tool_call" then
      self._postSettleReplyOpen = true
      self._quietDeadlineMs = nil
      self._postWorkGraceDeadlineMs = nil
      self._replyInactivityDeadlineMs = now + DEFERRED_REPLY_TIMEOUT_MS
    end
  end
  self:signalWake()
end

function AcpTurn:noteApprovalResolved()
  if self.promptSettled and not self.finished then
    local now = nowMs()
    self._postSettleReplyOpen = true
    self._quietDeadlineMs = nil
    self._postWorkGraceDeadlineMs = nil
    self._replyInactivityDeadlineMs = now + DEFERRED_REPLY_TIMEOUT_MS
    self:signalWake()
  end
end

function AcpTurn:handlePromptReply(rpcId, packet)
  if self.finished or not self.pending[rpcId] then
    return
  end
  self.pending[rpcId] = nil
  self.replies[rpcId] = packet

  if type(packet) == "table" and type(packet.result) == "table" and isPlainObject(packet.result.usage) then
    local usagePayload = self.session.usage:account(packet.result.usage)
    self.session.emit({
      type = "usage_updated",
      sessionId = self.session.localId,
      turnId = self.id,
      usage = usagePayload,
    })
  end

  if next(self.pending) ~= nil then
    return
  end

  -- Multiple session/prompt RPCs (steers): select latest reply ignoring -32602 on steer replies.
  local keys = {}
  for k in pairs(self.replies) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local first = keys[1]
  local final = self.replies[first]
  for i = #keys, 1, -1 do
    local k = keys[i]
    local rep = self.replies[k]
    if k == first or not (type(rep) == "table" and type(rep.error) == "table" and rep.error.code == -32602) then
      final = rep
      break
    end
  end

  if type(final) == "table" and type(final.error) == "table" then
    local msg = firstNonEmpty(
      type(final.error.message) == "string" and final.error.message or "",
      "ACP error " .. tostring(final.error.code)
    )
    self:finishFailed(msg, "execution", false)
    return
  end

  local reason = (type(final) == "table" and type(final.result) == "table") and final.result.stopReason or nil
  if reason == "end_turn" or reason == "refusal" then
    self.promptSettled = true
    self.settledReason = reason
    self.settledPacket = final
    self:_startSettleLoop()
    return
  end
  if reason == "cancelled" then
    self:finishCancelled()
    return
  end
  if reason == "max_tokens" or reason == "max_turn_requests" then
    self:finishFailed("Antigravity stopped the turn with " .. tostring(reason), "execution", false)
    return
  end
  local encodedReason = reason == nil and "undefined" or json.encode(reason)
  self:finishFailed(
    "Unrecognized Antigravity stop reason: " .. encodedReason,
    "protocol",
    false
  )
end

function AcpTurn:_stillSettling(gen)
  return (not self.finished)
    and (not self.cancelRequested)
    and (not self.session.closed)
    and self.promptSettled
    and (next(self.pending) == nil)
    and (self._settleGen == gen)
end

function AcpTurn:_waitOrWake(delayMs)
  if self._woken then
    return
  end
  local tok = {}
  self._wakeToken = tok
  pcall(task.wait, tok, clampTimerDelayMs(delayMs))
  if self._wakeToken == tok then
    self._wakeToken = nil
  end
end

function AcpTurn:_startSettleLoop()
  self._settleGen = self._settleGen + 1
  local gen = self._settleGen
  task.fork(function()
    self:_runSettleLoop(gen)
  end)
end

function AcpTurn:_runSettleLoop(gen)
  local deferred = false
  local sawSubagents = false

  local function finishClassifiedError(classified)
    if classified.sessionBroken then
      self.session.broken = true
      self.session:emitSessionExpired()
      self:finishFailed(classified.message, "execution", true)
    else
      self:finishFailed(classified.message, "execution", false)
    end
  end

  local function settleStep()
    self._woken = false
    local reason = self.settledReason
    local profileRoot = self.session.profileRoot

    local hasOpenTools = #self:outlivingToolIds() > 0
    local hasIncoming = next(self.session.incomingRequests) ~= nil
      or next(self.session.pendingApprovals) ~= nil
    local subagents = {}
    if next(self.subagentCalls) ~= nil then
      subagents = state.activeSubagentCalls(self.session.providerSessionId, self.subagentCalls, profileRoot)
    end
    if not self:_stillSettling(gen) then
      return false
    end

    local hasSubagents = #subagents > 0
    if hasSubagents then
      sawSubagents = true
    elseif sawSubagents then
      sawSubagents = false
      if self._postWorkGraceDeadlineMs == nil then
        self._postWorkGraceDeadlineMs = nowMs() + POST_WORK_WAKE_GRACE_MS
      end
    end

    -- 0.3 parity (_settle_loop): NEVER block turn settlement on hasDetachedChildren().
    -- Only outliving non-daemon tools, incoming permission requests, and active subagents defer settlement.
    if hasOpenTools or hasIncoming or hasSubagents then
      deferred = true
      self._replyInactivityDeadlineMs = nil
      self:_waitOrWake(DEFERRED_POLL_MS)
      return true
    end

    if reason == "refusal" then
      local rawErr = self.trailingError or "Antigravity stopped the turn with refusal"
      finishClassifiedError(state.classifyErrorText(rawErr))
      return false
    end

    if self.trailingError ~= nil then
      local now = nowMs()
      if deferred and self._quietDeadlineMs ~= nil and now < self._quietDeadlineMs then
        self:_waitOrWake(self._quietDeadlineMs - now)
        return true
      end
      finishClassifiedError(state.classifyErrorText(self.trailingError))
      return false
    end

    local now = nowMs()
    local pendingReply = state.hasPendingReply(self.session.providerSessionId, profileRoot)
    if not self:_stillSettling(gen) then
      return false
    end

    if self._postSettleReplyOpen or pendingReply then
      deferred = true
      if self._replyInactivityDeadlineMs == nil then
        self._replyInactivityDeadlineMs = now + DEFERRED_REPLY_TIMEOUT_MS
      end
      local remaining = self._replyInactivityDeadlineMs - now
      if remaining > 0 then
        self:_waitOrWake(math.min(DEFERRED_POLL_MS, remaining))
        return true
      end
      local transcriptErr = state.readLastTranscriptError(self.session.providerSessionId, profileRoot)
      if transcriptErr then
        finishClassifiedError(transcriptErr)
        return false
      end
      self:finishCompleted()
      return false
    end

    if self._postWorkGraceDeadlineMs ~= nil then
      local remaining = self._postWorkGraceDeadlineMs - now
      if remaining > 0 then
        deferred = true
        self:_waitOrWake(math.min(DEFERRED_POLL_MS, remaining))
        return true
      end
      self._postWorkGraceDeadlineMs = nil
    end

    if self._quietDeadlineMs ~= nil then
      local remaining = self._quietDeadlineMs - now
      if remaining > 0 then
        deferred = true
        self:_waitOrWake(remaining)
        return true
      end
      self._quietDeadlineMs = nil
    end

    if self._woken then
      return true
    end
    local transcriptErr = state.readLastTranscriptError(self.session.providerSessionId, profileRoot)
    if transcriptErr then
      finishClassifiedError(transcriptErr)
      return false
    end
    self:finishCompleted()
    return false
  end

  local ok, err = pcall(function()
    while self:_stillSettling(gen) do
      if not settleStep() then
        return
      end
    end
  end)
  if not ok then
    log.warn("Antigravity deferred turn settlement error", {
      error = errorToString(err),
    })
    if self:_stillSettling(gen) then
      self:finishCompleted()
    end
  end
end

function AcpTurn:_resolveDone(ok, val)
  if self._doneOk ~= nil then
    return
  end
  self._doneOk = ok
  self._doneResult = val
  local tok = self._doneToken
  if tok ~= nil then
    self._doneToken = nil
    if ok then
      task.wakeup(tok, val)
    else
      task.interrupt(tok, val)
    end
  end
end

function AcpTurn:awaitDone()
  if self._doneOk ~= nil then
    if self._doneOk then
      return self._doneResult
    end
    error(self._doneResult, 0)
  end
  local tok = {}
  self._doneToken = tok
  local ok, res = pcall(task.wait, tok)
  if self._doneToken == tok then
    self._doneToken = nil
  end
  if self._doneOk ~= nil then
    if self._doneOk then
      return self._doneResult
    end
    error(self._doneResult, 0)
  end
  if not ok then
    error(res, 0)
  end
  return res
end

function AcpTurn:finishCompleted()
  if self.finished then
    return
  end
  self.finished = true
  self.completed = true
  self._settleGen = self._settleGen + 1
  self:signalWake()
  self.session.emit({
    type = "turn_completed",
    sessionId = self.session.localId,
    turnId = self.id,
  })
  self:_resolveDone(true, {
    stopReason = self.settledReason or "end_turn",
  })
end

function AcpTurn:finishCancelled()
  if self.finished then
    return
  end
  self.finished = true
  self.completed = false
  self._settleGen = self._settleGen + 1
  self:signalWake()
  local msg = "Antigravity turn was cancelled"
  self.session.emit({
    type = "turn_failed",
    sessionId = self.session.localId,
    turnId = self.id,
    error = msg,
    failureReason = "interrupted",
  })
  self:_resolveDone(false, msg)
end

function AcpTurn:finishFailed(message, failureReason, reconcile)
  if self.finished then
    return
  end
  self.finished = true
  self.completed = false
  self._settleGen = self._settleGen + 1
  self:signalWake()
  local errText = firstNonEmpty(
    type(message) == "string" and message or tostring(message or ""),
    "Antigravity turn failed"
  )
  self.session.emit({
    type = "turn_failed",
    sessionId = self.session.localId,
    turnId = self.id,
    error = errText,
    failureReason = failureReason or "execution",
    reconcile = reconcile == true,
  })
  self:_resolveDone(false, errText)
end

-- ---------- AcpSession ----------

local function settlePendingRpc(entry, ok, val)
  if entry.settled then
    return
  end
  entry.settled = true
  entry.ok = ok
  entry.val = val
  local tok = entry.token
  if tok ~= nil then
    entry.token = nil
    if ok then
      task.wakeup(tok, val)
    else
      task.interrupt(tok, val)
    end
  end
end

local AcpSession = {}
AcpSession.__index = AcpSession

function AcpSession.new(localId, proc, emit, shutdownTimeoutMs, profileRoot, env)
  return setmetatable({
    localId = localId,
    providerSessionId = nil,
    proc = proc,
    emit = emit,
    shutdownTimeoutMs = shutdownTimeoutMs,
    profileRoot = profileRoot or state.DEFAULT_PROFILE_ROOT,
    env = env,
    model = "",
    seq = 0,
    usage = UsageAccumulator.new(),
    pendingRpc = {}, -- id -> { settled, ok, val, token }
    incomingRequests = {}, -- packet.id -> { cancelled, requestId }
    pendingApprovals = {}, -- requestId -> wait token
    subagentCalls = {}, -- set: callId -> true
    activeTurn = nil,
    startingTurn = false,
    started = false,
    closed = false,
    closing = false,
    broken = false,
    protocolFailed = false,
    expiredEmitted = false,
    _watchTimer = nil,
    _watchPaths = {},
    _watchSnapshot = nil,
    _closeWaiters = {},
  }, AcpSession)
end

function AcpSession:nextRequestId()
  self.seq = self.seq + 1
  return self.seq
end

function AcpSession:emitSessionExpired()
  if not self.started or self.expiredEmitted then
    return
  end
  self.expiredEmitted = true
  self.emit({
    type = "session_expired",
    sessionId = self.localId,
  })
end

function AcpSession:stopWatcher()
  local t = self._watchTimer
  self._watchTimer = nil
  cancelTimerSafe(t)
end

function AcpSession:notifyClosedWaiters()
  local waiters = self._closeWaiters
  self._closeWaiters = {}
  for i = 1, #waiters do
    task.wakeup(waiters[i], true)
  end
end

function AcpSession:waitClosed(timeoutMs)
  if self.closed then
    return true
  end
  if (tonumber(timeoutMs) or 0) <= 0 then
    return false
  end
  local tok = {}
  self._closeWaiters[#self._closeWaiters + 1] = tok
  local ok, res = pcall(task.wait, tok, clampTimerDelayMs(timeoutMs))
  if not self.closed then
    for i = #self._closeWaiters, 1, -1 do
      if self._closeWaiters[i] == tok then
        table.remove(self._closeWaiters, i)
        break
      end
    end
  end
  return self.closed or (ok and res == true)
end

function AcpSession:startReaders()
  local proc = self.proc

  task.fork(function()
    while not self.closed and not self.protocolFailed do
      local ok, line = pcall(proc.readLine, proc, MAX_LINE_BUFFER_BYTES)
      if not ok then
        if not self.closing and not self.closed then
          local msg = errorToString(line)
          if msg:find("byte limit", 1, true) then
            self:handleProtocolError("Antigravity ACP output line exceeded maximum buffer size")
          else
            self:handleProtocolError("Antigravity ACP stdout read error: " .. msg)
          end
        end
        break
      end
      if line == nil then
        break
      end
      self:processStdoutLine(line)
    end
    local wok, exitInfo = pcall(proc.wait, proc)
    self:onExit(wok and exitInfo or { code = -1, error = errorToString(exitInfo) })
  end)

  task.fork(function()
    while true do
      local ok, line = pcall(proc.readStderrLine, proc)
      if not ok or line == nil then
        break
      end
      local trimmed = trim(line)
      if trimmed ~= "" then
        log.debug("agy acp stderr", { text = trimmed:sub(1, 500) })
      end
    end
  end)
end

function AcpSession:startInstructionWatcher(workspace)
  self._watchPaths = instructionCandidatePaths(workspace, self.env)
  if #self._watchPaths == 0 or not (fs and type(fs.stat) == "function") then
    return
  end
  self._watchSnapshot = statInstructionSnapshot(self._watchPaths)
  task.fork(function()
    self:_watchLoop()
  end)
end

function AcpSession:_watchLoop()
  pcall(function()
    while not self.closed and not self.closing and not self.expiredEmitted do
      local ok, tm = pcall(createTimer, INSTRUCTION_WATCH_INTERVAL_MS)
      if not ok or not tm then
        return
      end
      local timer <close> = tm
      self._watchTimer = timer
      local waitOk = pcall(timer.wait, timer)
      if self._watchTimer == timer then
        self._watchTimer = nil
      end
      if not waitOk or self.closed or self.closing or self.expiredEmitted then
        return
      end
      local nextSnap = statInstructionSnapshot(self._watchPaths)
      for p, prevVal in pairs(self._watchSnapshot) do
        if nextSnap[p] ~= prevVal then
          self:emitSessionExpired()
          return
        end
      end
    end
  end)
end

function AcpSession:processStdoutLine(rawLine)
  local line = trim(tostring(rawLine or ""):gsub("\r$", ""))
  if line == "" then
    return
  end
  local ok, packet = pcall(json.decode, line)
  if not ok then
    if not self.closing then
      self:handleProtocolError("Invalid Antigravity ACP JSON: " .. errorToString(packet))
    end
    return
  end
  if not isPlainObject(packet) or packet.jsonrpc ~= "2.0" then
    if not self.closing then
      self:handleProtocolError("Invalid Antigravity ACP message: expected JSON-RPC 2.0 object")
    end
    return
  end
  self:handlePacket(packet)
end

function AcpSession:cancelAllPendingWaiters(errMessage)
  local pendingRpc = self.pendingRpc
  self.pendingRpc = {}
  for _, entry in pairs(pendingRpc) do
    settlePendingRpc(entry, false, errMessage)
  end

  local incoming = self.incomingRequests
  self.incomingRequests = {}
  for _, reqState in pairs(incoming) do
    reqState.cancelled = true
  end

  local approvals = self.pendingApprovals
  self.pendingApprovals = {}
  for _, tok in pairs(approvals) do
    task.wakeup(tok, "cancelled")
  end
end

function AcpSession:handleProtocolError(message)
  if self.protocolFailed then
    return
  end
  self.protocolFailed = true
  self.broken = true
  self:stopWatcher()

  self:cancelAllPendingWaiters(message)

  self:emitSessionExpired()
  if self.activeTurn and not self.activeTurn.finished then
    self.activeTurn:finishFailed(message, "protocol", true)
  end
  pcall(self.proc.kill, self.proc)
end

function AcpSession:onExit(info)
  if self.closed then
    return
  end
  self.closed = true
  self:stopWatcher()

  local code = (type(info) == "table" and info.code ~= nil) and info.code or -1
  local signal = (type(info) == "table" and isNonEmptyString(info.signal)) and info.signal or nil
  local errMsg = "agy acp exited (code=" .. tostring(code)
    .. (signal and (", signal=" .. signal) or "")
    .. ")"

  self:cancelAllPendingWaiters(errMsg)

  if not self.closing then
    self.broken = true
    self:emitSessionExpired()
    if self.activeTurn and not self.activeTurn.finished then
      self.activeTurn:finishFailed(errMsg, "connection_lost", true)
    end
  elseif self.activeTurn and not self.activeTurn.finished then
    self.activeTurn:finishCancelled()
  end

  self:notifyClosedWaiters()
end

function AcpSession:sendPacket(obj)
  if self.closed or self.protocolFailed then
    error("The Antigravity ACP process is unavailable", 0)
  end
  local packet = { jsonrpc = "2.0" }
  for k, v in pairs(obj) do
    packet[k] = v
  end
  local line = json.encode(packet) .. "\n"
  self.proc:writeStdin(line)
end

function AcpSession:request(method, params, timeoutMs)
  if timeoutMs == nil then
    timeoutMs = 60000
  end
  local id = self:nextRequestId()
  local entry = {
    settled = false,
    ok = false,
    val = nil,
    token = nil,
  }
  self.pendingRpc[id] = entry

  local sendOk, sendErr = pcall(self.sendPacket, self, { id = id, method = method, params = params })
  if not sendOk then
    if self.pendingRpc[id] == entry then
      self.pendingRpc[id] = nil
    end
    error(errorToString(sendErr), 0)
  end

  if not entry.settled then
    local tok = {}
    entry.token = tok
    local waitTimeout = timeoutMs > 0 and clampTimerDelayMs(timeoutMs) or nil
    local wok, wres = pcall(task.wait, tok, waitTimeout)
    if entry.token == tok then
      entry.token = nil
    end
    if self.pendingRpc[id] == entry then
      self.pendingRpc[id] = nil
    end
    if entry.settled then
      if entry.ok then
        return entry.val
      end
      error(entry.val, 0)
    end
    if not wok then
      entry.settled = true
      if wres == "timeout" then
        error("ACP request " .. tostring(method) .. " timed out", 0)
      end
      error(wres, 0)
    end
    return wres
  end

  if self.pendingRpc[id] == entry then
    self.pendingRpc[id] = nil
  end
  if entry.ok then
    return entry.val
  end
  error(entry.val, 0)
end

function AcpSession:submitPrompt(turn, promptBlocks)
  local id = self:nextRequestId()
  turn:onPromptSubmitted(id)
  local ok, err = pcall(function()
    self:sendPacket({
      id = id,
      method = "session/prompt",
      params = {
        sessionId = self.providerSessionId,
        prompt = makeArray(promptBlocks),
      },
    })
  end)
  if not ok then
    turn.pending[id] = nil
    error(err, 0)
  end
end

function AcpSession:handlePacket(packet)
  -- 1. Server-initiated JSON-RPC request.
  if type(packet.method) == "string" and not isNull(packet.id) then
    task.fork(function()
      self:handleIncomingRequest(packet)
    end)
    return
  end

  -- 2. Server-initiated request cancellation notification.
  if packet.method == "$/cancel_request" then
    local reqId = type(packet.params) == "table" and packet.params.requestId or nil
    local reqState = not isNull(reqId) and self.incomingRequests[reqId] or nil
    if reqState then
      reqState.cancelled = true
      self.incomingRequests[reqId] = nil
      if reqState.requestId then
        local tok = self.pendingApprovals[reqState.requestId]
        self.pendingApprovals[reqState.requestId] = nil
        if tok ~= nil then
          task.wakeup(tok, "cancelled")
        end
      end
      if self.activeTurn then
        self.activeTurn:signalWake()
      end
    end
    return
  end

  -- 3. Response to an outgoing JSON-RPC request (control RPC or active turn prompt RPC).
  if isNull(packet.method) and not isNull(packet.id) then
    local entry = self.pendingRpc[packet.id]
    if entry then
      self.pendingRpc[packet.id] = nil
      if type(packet.error) == "table" then
        local msg = firstNonEmpty(
          type(packet.error.message) == "string" and packet.error.message or "",
          "ACP error " .. tostring(packet.error.code)
        )
        settlePendingRpc(entry, false, msg)
      else
        if isNull(packet.result) or packet.result == false then
          settlePendingRpc(entry, true, {})
        else
          settlePendingRpc(entry, true, packet.result)
        end
      end
      return
    end
    if self.activeTurn and not self.activeTurn.finished and self.activeTurn.pending[packet.id] then
      self.activeTurn:handlePromptReply(packet.id, packet)
    end
    return
  end

  -- 4. Session update notification.
  if packet.method == "session/update" then
    if not isPlainObject(packet.params) or packet.params.sessionId ~= self.providerSessionId then
      return
    end
    local update = packet.params.update
    if not isPlainObject(update) or type(update.sessionUpdate) ~= "string" then
      return
    end
    if update.sessionUpdate == "config_option_update" then
      local model = currentOption(update, "model")
      if isNonEmptyString(model) then
        self.model = model
      end
    end
    if self.activeTurn and not self.activeTurn.finished then
      self.activeTurn:handleUpdate(update)
    elseif update.sessionUpdate == "config_option_update" and self.model ~= "" then
      self.emit({
        type = "model_updated",
        sessionId = self.localId,
        turnId = "",
        model = self.model,
      })
    end
  end
end

function AcpSession:handleIncomingRequest(packet)
  local reqState = { cancelled = false, requestId = nil }
  self.incomingRequests[packet.id] = reqState

  pcall(function()
    local response
    local ok, res = pcall(self.answerIncomingRequest, self, packet, reqState)
    if ok then
      response = { result = res }
    else
      if type(res) == "table" and res.__kind == "RpcError" then
        response = { error = { code = res.code, message = res.message } }
      elseif type(res) == "table" and res.__kind == "InvalidParamsError" then
        response = { error = { code = -32602, message = res.message } }
      else
        local msg = errorToString(res)
        if msg == "" then
          msg = "Internal error"
        end
        log.warn("Antigravity ACP client request failed", {
          id = packet.id,
          method = packet.method,
          error = msg,
        })
        response = {
          error = {
            code = -32603,
            message = msg,
          },
        }
      end
    end

    if not reqState.cancelled and not self.closed and not self.protocolFailed then
      pcall(function()
        local out = { id = packet.id }
        for k, v in pairs(response) do
          out[k] = v
        end
        self:sendPacket(out)
      end)
    end
  end)

  if self.incomingRequests[packet.id] == reqState then
    self.incomingRequests[packet.id] = nil
  end
  if reqState.requestId then
    self.pendingApprovals[reqState.requestId] = nil
  end
  if self.activeTurn then
    self.activeTurn:signalWake()
  end
end

function AcpSession:answerIncomingRequest(packet, reqState)
  if packet.method ~= "session/request_permission" then
    error(makeRpcError("ACP client method is unavailable: " .. tostring(packet.method), -32601))
  end
  if not isPlainObject(packet.params) then
    error(makeInvalidParamsError("session/request_permission requires params object"))
  end

  local cancelled = { outcome = { outcome = "cancelled" } }
  local turn = self.activeTurn
  if not turn
    or turn.cancelRequested
    or (turn.finished and not turn.completed)
    or packet.params.sessionId ~= self.providerSessionId
  then
    return cancelled
  end

  local rawOptions = packet.params.options
  if not isArray(rawOptions) then
    return cancelled
  end

  local optionsByKind = {}
  for _, opt in ipairs(rawOptions) do
    if isPlainObject(opt) and type(opt.kind) == "string" and type(opt.optionId) == "string" then
      optionsByKind[opt.kind] = opt.optionId
    end
  end

  local allow = {}
  local allowedScopes = makeArray({})
  if isNonEmptyString(optionsByKind.allow_once) then
    allow.once = optionsByKind.allow_once
    allowedScopes[#allowedScopes + 1] = "once"
  end
  if isNonEmptyString(optionsByKind.allow_always) then
    allow.always = optionsByKind.allow_always
    allowedScopes[#allowedScopes + 1] = "always"
  end
  local reject = firstNonEmpty(optionsByKind.reject_once, optionsByKind.reject_always)
  if reject == "" then
    reject = nil
  end

  local choice = reject
  if #allowedScopes > 0 then
    local tool = isPlainObject(packet.params.toolCall) and packet.params.toolCall or {}
    local args = nil
    if isPlainObject(tool.rawInput) then
      args = tool.rawInput
    elseif isPlainObject(tool.args) then
      args = tool.args
    end
    local action = approvalAction(tool, args)
    local details = approvalDetails(packet.params, tool, args, action)
    local title = truncateDetail(firstNonEmpty(
      type(tool.title) == "string" and tool.title or "",
      type(tool.name) == "string" and tool.name or "",
      action,
      "Permission Required"
    ))
    local description = approvalDescription(tool, details)

    local requestId = "acp-" .. tostring(packet.id)
    reqState.requestId = requestId
    local activeBefore = not turn.finished

    local tok = {}
    self.pendingApprovals[requestId] = tok
    self.emit({
      type = "approval_requested",
      sessionId = self.localId,
      turnId = turn.id,
      requestId = requestId,
      title = title,
      description = description,
      action = action,
      allowedScopes = allowedScopes,
      details = details,
    })

    local decision = task.wait(tok)
    if reqState.cancelled or turn.cancelRequested or (activeBefore and turn.finished) then
      return cancelled
    end

    local norm = trim(decision):lower()
    if norm == "approve:always" then
      choice = allow.always or reject
    elseif norm == "approve:once" then
      choice = allow.once or reject
    elseif norm == "approve" then
      choice = allow.once or allow.always or reject
    else
      choice = reject
    end
  end

  if not choice then
    return cancelled
  end
  turn:noteApprovalResolved()
  return {
    outcome = {
      outcome = "selected",
      optionId = choice,
    },
  }
end

function AcpSession:hasOutlivingTools()
  return self.activeTurn ~= nil and #self.activeTurn:outlivingToolIds() > 0
end

function AcpSession:hasDetachedChildren()
  if self.closed or not (self.proc and type(self.proc.hasDetachedChildren) == "function") then
    return false
  end
  local ok, res = pcall(self.proc.hasDetachedChildren, self.proc)
  return ok and res == true
end

local function sleepSessionWithinDeadline(sess, ms, deadlineMs)
  local remaining = deadlineMs - nowMs()
  if remaining <= 0 then
    error("Antigravity startup timed out", 0)
  end
  local waitMs = math.min(ms, remaining)
  sess:waitClosed(waitMs)
  if sess.closed or sess.protocolFailed then
    error("Antigravity ACP exited during startup", 0)
  end
  if nowMs() >= deadlineMs then
    error("Antigravity startup timed out", 0)
  end
end

-- ---------- Exported harness plugin contract ----------

local closeSession

local function inspect(_ctx, config)
  local cfg = type(config) == "table" and config or {}
  local env = {}
  local apiKey = resolveApiKey(cfg)
  if apiKey then
    env.GEMINI_API_KEY = apiKey
  end

  local totalTimeoutMs = positiveTimeoutSec(cfg.startupTimeoutSec, DEFAULT_STARTUP_TIMEOUT_SEC) * 1000
  local deadlineMs = nowMs() + totalTimeoutMs
  local function remainingMs()
    return math.max(1, deadlineMs - nowMs())
  end

  local ver = runCommandCollect("agy", { "--version" }, env, remainingMs())
  if ver.code ~= 0 then
    local errText = trim(ver.stderr)
    return {
      available = false,
      version = "",
      models = makeArray({}),
      skills = makeArray({}),
      mcpServers = makeArray({}),
      error = errText ~= "" and errText or ("agy exited with code " .. tostring(ver.code)),
    }
  end
  local firstLine = trim(ver.stdout):match("^([^\r\n]+)") or ""
  local version = firstLine ~= "" and firstLine or "unknown"

  if nowMs() >= deadlineMs then
    return {
      available = true,
      version = version,
      models = makeArray({}),
      skills = makeArray({}),
      mcpServers = makeArray({}),
      error = "agy inspect timed out",
    }
  end

  local modelsRes = runCommandCollect("agy", { "models" }, env, remainingMs())
  if modelsRes.code ~= 0 then
    local errText = trim(modelsRes.stderr)
    return {
      available = true,
      version = version,
      models = makeArray({}),
      skills = makeArray({}),
      mcpServers = makeArray({}),
      error = errText ~= "" and errText or ("agy models exited with code " .. tostring(modelsRes.code)),
    }
  end
  local models = state.parseModelsOutput(modelsRes.stdout)

  if nowMs() >= deadlineMs then
    return {
      available = true,
      version = version,
      models = models,
      skills = makeArray({}),
      mcpServers = makeArray({}),
      error = "agy inspect timed out",
    }
  end

  local mcpRes = runCommandCollect("agy", { "mcp", "list" }, env, remainingMs())
  if mcpRes.code ~= 0 then
    local errText = trim(mcpRes.stderr)
    return {
      available = true,
      version = version,
      models = models,
      skills = makeArray({}),
      mcpServers = makeArray({}),
      error = errText ~= "" and errText or ("agy mcp list exited with code " .. tostring(mcpRes.code)),
    }
  end

  local okMcp, mcpServers = pcall(state.readMcpServers, mcpRes.stdout)
  if not okMcp then
    return {
      available = true,
      version = version,
      models = models,
      skills = makeArray({}),
      mcpServers = makeArray({}),
      error = errorToString(mcpServers),
    }
  end

  return {
    available = true,
    version = version,
    models = models,
    skills = makeArray({}),
    mcpServers = mcpServers,
    error = "",
  }
end

local function openSession(_ctx, config, input, emit)
  local cfg = type(config) == "table" and config or {}
  local inp = type(input) == "table" and input or {}

  local args = makeArray({ "acp", "--process-per-session" })
  if inp.sandboxPolicy == "workspace-write" then
    args[#args + 1] = "--sandbox"
  elseif inp.sandboxPolicy == "danger-full-access" then
    args[#args + 1] = "--dangerously-skip-permissions"
  end

  local env = {}
  if type(inp.env) == "table" then
    for k, v in pairs(inp.env) do
      env[k] = v
    end
  end
  local apiKey = resolveApiKey(cfg)
  if apiKey then
    env.GEMINI_API_KEY = apiKey
  end

  local localId = isNonEmptyString(inp.sessionId) and inp.sessionId or ("agy-" .. tostring(time.nowMs()))
  if sessions[localId] then
    closeSession(localId)
  end

  local configStartupMs = positiveTimeoutSec(cfg.startupTimeoutSec, DEFAULT_STARTUP_TIMEOUT_SEC) * 1000
  local inputStartupMs = tonumber(inp.startupTimeoutMs)
  local startupTimeoutMs = (isFiniteNumber(inputStartupMs) and inputStartupMs > 0)
    and math.min(inputStartupMs, configStartupMs)
    or configStartupMs

  local configShutdownMs = positiveTimeoutSec(cfg.shutdownTimeoutSec, DEFAULT_SHUTDOWN_TIMEOUT_SEC) * 1000
  local inputShutdownMs = tonumber(inp.shutdownTimeoutMs)
  local shutdownTimeoutMs = (isFiniteNumber(inputShutdownMs) and inputShutdownMs > 0)
    and inputShutdownMs
    or configShutdownMs

  local deadlineMs = nowMs() + startupTimeoutMs
  local function remainingStartupMs()
    local rem = deadlineMs - nowMs()
    if rem <= 0 then
      error("Antigravity startup timed out", 0)
    end
    return rem
  end

  local proc = process.spawn({
    command = "agy",
    args = args,
    cwd = type(inp.workspace) == "string" and inp.workspace or "",
    env = env,
  })
  local profileRoot = state.resolveProfileRoot(env)
  local sess = AcpSession.new(localId, proc, emit, shutdownTimeoutMs, profileRoot, env)
  sess:startReaders()

  local ok, result = pcall(function()
    local initRes = sess:request(
      "initialize",
      {
        protocolVersion = 1,
        clientCapabilities = {},
        clientInfo = { name = "bazaar-plugin-antigravity", version = PLUGIN_VERSION },
      },
      remainingStartupMs()
    )
    if type(initRes) ~= "table" or initRes.protocolVersion ~= 1 then
      error("Unsupported Antigravity ACP version: " .. tostring(type(initRes) == "table" and initRes.protocolVersion or nil), 0)
    end

    local params = {
      cwd = type(inp.workspace) == "string" and inp.workspace or "",
      mcpServers = makeArray({}),
    }

    local instructionsText = ""
    if isArray(inp.instructions) then
      local parts = {}
      for _, s in ipairs(inp.instructions) do
        if isNonEmptyString(s) then
          parts[#parts + 1] = s
        end
      end
      instructionsText = table.concat(parts, "\n\n")
    elseif type(inp.instructions) == "string" then
      instructionsText = inp.instructions
    end

    if instructionsText ~= "" then
      local caps = type(initRes.agentCapabilities) == "table" and initRes.agentCapabilities or nil
      local meta = caps and type(caps._meta) == "table" and caps._meta or nil
      local ag = meta and type(meta.antigravity) == "table" and meta.antigravity or nil
      local sp = ag and type(ag.systemPrompt) == "table" and ag.systemPrompt or nil
      local canAppend = sp and sp.append == true
      if not canAppend then
        error("Antigravity cannot append BCN session instructions", 0)
      end
      params._meta = {
        antigravity = {
          systemPrompt = { append = instructionsText },
        },
      }
    end

    local configured
    if isNonEmptyString(inp.resumeSessionId) then
      params.sessionId = inp.resumeSessionId
      configured = sess:request("session/resume", params, remainingStartupMs())
      sess.providerSessionId = inp.resumeSessionId
    else
      configured = sess:request("session/new", params, remainingStartupMs())
      if not (type(configured) == "table" and isNonEmptyString(configured.sessionId)) then
        error("Antigravity session/new did not return a sessionId", 0)
      end
      sess.providerSessionId = configured.sessionId
      -- agy discovers globally configured MCP tools after session/new.
      sleepSessionWithinDeadline(sess, MCP_DISCOVERY_DELAY_MS, deadlineMs)
    end

    local optionPairs = {
      { "model", cfg.model },
      { "thought_level", cfg.effort },
    }
    for _, pair in ipairs(optionPairs) do
      local key, val = pair[1], pair[2]
      if isNonEmptyString(val) and currentOption(configured, key) ~= val then
        configured = sess:request(
          "session/set_config_option",
          {
            sessionId = sess.providerSessionId,
            configId = key,
            value = val,
          },
          remainingStartupMs()
        )
        if currentOption(configured, key) ~= val then
          error("Antigravity did not select " .. key .. "=" .. val, 0)
        end
      end
    end

    if sess.closed or sess.protocolFailed then
      error("Antigravity ACP exited during startup", 0)
    end

    sess.model = firstNonEmpty(currentOption(configured, "model"), cfg.model)
    sess.started = true
    sessions[localId] = sess
    sess:startInstructionWatcher(type(inp.workspace) == "string" and inp.workspace or "")

    emit({
      type = "session_started",
      sessionId = localId,
      providerThreadId = sess.providerSessionId,
      model = sess.model,
      metadata = {
        providerThreadId = sess.providerSessionId,
        providerSessionId = sess.providerSessionId,
        availableModels = optionChoices(configured, "model"),
      },
    })
    return {
      sessionId = localId,
      providerThreadId = sess.providerSessionId,
      model = sess.model,
    }
  end)

  if not ok then
    sess.closing = true
    sess:stopWatcher()
    pcall(proc.closeStdin, proc)
    pcall(proc.kill, proc)
    sess:waitClosed(1000)
    error(result, 0)
  end
  return result
end

local function startTurn(sessionId, input)
  local sess = sessions[sessionId]
  if not sess or sess.closed then
    error("antigravity: session " .. tostring(sessionId) .. " is not open", 0)
  end
  if sess.broken then
    error("antigravity: session " .. tostring(sessionId) .. " is corrupted and must be reopened", 0)
  end
  if sess.startingTurn or (sess.activeTurn and not sess.activeTurn.finished) then
    error("antigravity: session " .. tostring(sessionId) .. " already owns an active turn", 0)
  end

  sess.startingTurn = true
  local turn = nil
  local ok, result = pcall(function()
    local inp = type(input) == "table" and input or {}
    local turnId = tostring(inp.turnId or "")
    local prompt = makeArray({
      { type = "text", text = tostring(inp.inputText or "") },
    })

    local attachments = normalizeAttachments(inp)
    for _, att in ipairs(attachments) do
      local aok, block = pcall(buildAttachmentBlock, att)
      if not aok then
        local msg = errorToString(block)
        sess.emit({
          type = "turn_failed",
          sessionId = sessionId,
          turnId = turnId,
          error = msg,
          failureReason = "execution",
        })
        error(msg, 0)
      end
      prompt[#prompt + 1] = block
    end

    if sess.closed then
      error("antigravity: session " .. tostring(sessionId) .. " is not open", 0)
    end
    if sess.broken then
      error("antigravity: session " .. tostring(sessionId) .. " is corrupted and must be reopened", 0)
    end

    turn = AcpTurn.new(sess, turnId)
    sess.activeTurn = turn
    sess.startingTurn = false

    local subOk, subErr = pcall(function()
      sess:submitPrompt(turn, prompt)
    end)
    if not subOk then
      sess.broken = true
      sess:emitSessionExpired()
      turn:finishFailed(errorToString(subErr), "connection_lost", true)
    end
    return turn:awaitDone()
  end)

  sess.startingTurn = false
  -- 0.3 parity (runtime.py:264-266,723-729): retain completed turn on sess.activeTurn so
  -- post-turn permission requests from background daemons/subagents are still accepted.
  if turn and sess.activeTurn == turn and (not turn.completed or sess.closed) then
    sess.activeTurn = nil
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local function steerTurn(sessionId, turnId, inputText)
  local sess = sessions[sessionId]
  if not sess or sess.closed or sess.broken then
    error("antigravity: session " .. tostring(sessionId) .. " is not open", 0)
  end
  local turn = sess.activeTurn
  if not turn or turn.finished or turn.cancelRequested then
    error("antigravity: session " .. tostring(sessionId) .. " has no active turn to steer", 0)
  end
  if isNonEmptyString(turnId) and turn.id ~= turnId then
    error("antigravity: turn " .. tostring(turnId) .. " is not the active turn", 0)
  end
  if next(sess.incomingRequests) ~= nil or next(sess.pendingApprovals) ~= nil then
    error("antigravity: cannot steer turn while an approval request is pending", 0)
  end
  sess:submitPrompt(turn, makeArray({
    { type = "text", text = tostring(inputText or "") },
  }))
end

local function cancelTurn(sessionId, turnId)
  local sess = sessions[sessionId]
  if not sess or sess.closed then
    return
  end

  local turn = sess.activeTurn
  if turn and (not isNonEmptyString(turnId) or turn.id == turnId) and not turn.finished then
    turn.cancelRequested = true
    turn._settleGen = turn._settleGen + 1
    turn:signalWake()

    local approvals = sess.pendingApprovals
    sess.pendingApprovals = {}
    for _, tok in pairs(approvals) do
      task.wakeup(tok, "cancelled")
    end

    if (next(turn.pending) ~= nil or turn.promptSettled) and isNonEmptyString(sess.providerSessionId) then
      pcall(function()
        sess:sendPacket({
          method = "session/cancel",
          params = { sessionId = sess.providerSessionId },
        })
      end)
    end

    if next(turn.pending) == nil then
      turn:finishCancelled()
    end
    return
  end

  if isNonEmptyString(sess.providerSessionId) then
    pcall(function()
      sess:sendPacket({
        method = "session/cancel",
        params = { sessionId = sess.providerSessionId },
      })
    end)
  end
end

local function respondApproval(sessionId, requestId, decision)
  local sess = sessions[sessionId]
  if not sess then
    return
  end
  local tok = sess.pendingApprovals[requestId]
  if tok ~= nil then
    sess.pendingApprovals[requestId] = nil
    task.wakeup(tok, decision)
  end
end

local function hasBackgroundJob(sessionId)
  local sess = sessions[sessionId]
  if not sess or sess.closed then
    return false
  end
  if next(sess.incomingRequests) ~= nil
    or next(sess.pendingApprovals) ~= nil
    or (sess.activeTurn and not sess.activeTurn.finished)
    or sess:hasOutlivingTools()
  then
    return true
  end
  if sess:hasDetachedChildren() then
    return true
  end
  return state.hasLiveDiskBackgroundWork(sess.providerSessionId, sess.subagentCalls, sess.profileRoot)
end

closeSession = function(sessionId)
  local sess = sessions[sessionId]
  if not sess then
    return
  end
  sessions[sessionId] = nil
  sess.closing = true
  sess:stopWatcher()

  if sess.activeTurn and not sess.activeTurn.finished then
    sess.activeTurn.cancelRequested = true
    sess.activeTurn._settleGen = sess.activeTurn._settleGen + 1
    sess.activeTurn:signalWake()
  end

  local incoming = sess.incomingRequests
  sess.incomingRequests = {}
  for _, reqState in pairs(incoming) do
    reqState.cancelled = true
  end

  local approvals = sess.pendingApprovals
  sess.pendingApprovals = {}
  for _, tok in pairs(approvals) do
    task.wakeup(tok, "cancelled")
  end

  local totalTimeoutMs = (isFiniteNumber(sess.shutdownTimeoutMs) and sess.shutdownTimeoutMs > 0)
    and sess.shutdownTimeoutMs
    or (DEFAULT_SHUTDOWN_TIMEOUT_SEC * 1000)
  local deadlineMs = nowMs() + totalTimeoutMs

  if not sess.closed and isNonEmptyString(sess.providerSessionId) then
    local closeRpcBudget = math.min(3000, math.max(1, deadlineMs - nowMs()))
    pcall(function()
      sess:request(
        "session/close",
        { sessionId = sess.providerSessionId },
        closeRpcBudget
      )
    end)
  end

  if not sess.closed then
    pcall(sess.proc.closeStdin, sess.proc)
    local remainingAfterClose = deadlineMs - nowMs()
    if remainingAfterClose > 0 then
      sess:waitClosed(remainingAfterClose)
    end
  end

  if not sess.closed then
    pcall(function()
      if type(sess.proc.signal) == "function" then
        sess.proc:signal("SIGTERM")
        sess:waitClosed(math.min(1500, totalTimeoutMs))
      end
    end)
  end

  if not sess.closed then
    pcall(sess.proc.kill, sess.proc)
    sess:waitClosed(1000)
  end

  if sess.activeTurn and not sess.activeTurn.finished then
    sess.activeTurn:finishCancelled()
  end
end

return {
  inspect = inspect,
  openSession = openSession,
  startTurn = startTurn,
  steerTurn = steerTurn,
  respondApproval = respondApproval,
  hasBackgroundJob = hasBackgroundJob,
  cancelTurn = cancelTurn,
  closeSession = closeSession,
}
