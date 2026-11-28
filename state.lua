-- Inspection and read-only local state helpers for Antigravity CLI.

local json = require("bazaar.json")
local okFs, fsMod = pcall(require, "bazaar.fs")
local fs = (okFs and type(fsMod) == "table") and fsMod or nil

local DEFAULT_PROFILE_ROOT = "~/.gemini/antigravity-cli"
local MAX_JSON_FILE_BYTES = 1048576
local MAX_DETACHED_CHILDREN = 64
local MAX_MESSAGE_FILES = 2048
local TRANSCRIPT_MAX_TAIL_BYTES = 262144

local EFFORT_SUFFIXES = {
  low = true,
  medium = true,
  high = true,
  xhigh = true,
  max = true,
}

local HIGH_PRIORITY_MESSAGE = "MESSAGE_PRIORITY_HIGH"
local LOW_PRIORITY_MESSAGE = "MESSAGE_PRIORITY_LOW"
local KILLED_SUBAGENT_STATE = "SUBAGENT_STATE_KILLED"

local UTF8_REPLACEMENT = "\xEF\xBF\xBD"

local ARRAY_MT = (type(getmetatable) == "function" and json.array)
  and getmetatable(json.array({}))
  or nil
local JSON_NULL = json.null

local function isNull(v)
  return v == nil or (JSON_NULL ~= nil and v == JSON_NULL)
end

local function makeArray(tbl)
  if json.array then
    return json.array(tbl or {})
  end
  return tbl or {}
end

local function trim(s)
  if isNull(s) then
    return ""
  end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
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

local function validSessionId(sessionId)
  if type(sessionId) ~= "string" then
    return nil
  end
  local n = #sessionId
  if n < 1 or n > 64 then
    return nil
  end
  if sessionId:find("^[A-Za-z0-9%-]+$") then
    return sessionId
  end
  return nil
end

local function decodeUtf8(raw, fatal)
  if type(raw) ~= "string" then
    return ""
  end
  if utf8 and type(utf8.len) == "function" then
    if utf8.len(raw) ~= nil then
      return raw
    end
    if fatal then
      error("Invalid UTF-8 byte sequence", 0)
    end
  end

  local out = {}
  local i = 1
  local len = #raw
  while i <= len do
    local b0 = string.byte(raw, i)
    if b0 < 0x80 then
      out[#out + 1] = string.char(b0)
      i = i + 1
    elseif (b0 & 0xE0) == 0xC0 then
      local b1 = string.byte(raw, i + 1)
      if not b1 or (b1 & 0xC0) ~= 0x80 then
        if fatal then
          error("Invalid UTF-8 byte sequence", 0)
        end
        out[#out + 1] = UTF8_REPLACEMENT
        i = i + 1
      else
        local cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
        if cp < 0x80 then
          if fatal then
            error("Overlong UTF-8 byte sequence", 0)
          end
          out[#out + 1] = UTF8_REPLACEMENT
          i = i + 1
        else
          out[#out + 1] = raw:sub(i, i + 1)
          i = i + 2
        end
      end
    elseif (b0 & 0xF0) == 0xE0 then
      local b1, b2 = string.byte(raw, i + 1, i + 2)
      if not b1 or not b2 or (b1 & 0xC0) ~= 0x80 or (b2 & 0xC0) ~= 0x80 then
        if fatal then
          error("Invalid UTF-8 byte sequence", 0)
        end
        out[#out + 1] = UTF8_REPLACEMENT
        i = i + 1
      else
        local cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
        if cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF) then
          if fatal then
            error("Invalid UTF-8 code point", 0)
          end
          out[#out + 1] = UTF8_REPLACEMENT
          i = i + 1
        else
          out[#out + 1] = raw:sub(i, i + 2)
          i = i + 3
        end
      end
    elseif (b0 & 0xF8) == 0xF0 then
      local b1, b2, b3 = string.byte(raw, i + 1, i + 3)
      if not b1 or not b2 or not b3
        or (b1 & 0xC0) ~= 0x80
        or (b2 & 0xC0) ~= 0x80
        or (b3 & 0xC0) ~= 0x80
      then
        if fatal then
          error("Invalid UTF-8 byte sequence", 0)
        end
        out[#out + 1] = UTF8_REPLACEMENT
        i = i + 1
      else
        local cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
        if cp < 0x10000 or cp > 0x10FFFF then
          if fatal then
            error("Invalid UTF-8 code point", 0)
          end
          out[#out + 1] = UTF8_REPLACEMENT
          i = i + 1
        else
          out[#out + 1] = raw:sub(i, i + 3)
          i = i + 4
        end
      end
    else
      if fatal then
        error("Invalid UTF-8 leading byte", 0)
      end
      out[#out + 1] = UTF8_REPLACEMENT
      i = i + 1
    end
  end
  return table.concat(out)
end

-- ---------- Inspection parsers ----------

local function parseModelsOutput(listing)
  local models = {}
  local modelOrder = {}
  local efforts = {}
  local effortSeen = {}

  local text = tostring(listing or "")
  for rawLine in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = trim(rawLine:gsub("\r$", ""))
    if trimmed ~= "" then
      local identifier, rawName = trimmed:match("^(%S+)%s+(.+)$")
      if identifier and rawName then
        local name = trim(rawName)
        local dash = identifier:match(".*()%-")
        if dash and dash > 1 then
          local base = identifier:sub(1, dash - 1)
          local effort = identifier:sub(dash + 1)
          if EFFORT_SUFFIXES[effort] then
            identifier = base
            local paren = name:find(" (", 1, true)
            if paren then
              name = name:sub(1, paren - 1)
            end
            local list = efforts[identifier]
            local seen = effortSeen[identifier]
            if not list then
              list = {}
              seen = {}
              efforts[identifier] = list
              effortSeen[identifier] = seen
            end
            if not seen[effort] then
              seen[effort] = true
              list[#list + 1] = effort
            end
          end
        end
        if models[identifier] == nil then
          modelOrder[#modelOrder + 1] = identifier
        end
        models[identifier] = name
      end
    end
  end

  local out = makeArray({})
  for _, id in ipairs(modelOrder) do
    out[#out + 1] = {
      id = id,
      name = models[id],
      efforts = makeArray(efforts[id] or {}),
      defaultEffort = "",
      default = false,
    }
  end
  return out
end

local function splitMcpColumns(line)
  local trimmed = trim(line)
  if trimmed == "" then
    return {}
  end
  local cols = {}
  local pos = 1
  while #cols < 3 do
    local s, e = trimmed:find("%s%s+", pos)
    if not s then
      break
    end
    cols[#cols + 1] = trimmed:sub(pos, s - 1)
    pos = e + 1
  end
  cols[#cols + 1] = trimmed:sub(pos)
  return cols
end

local function parseMcpListOutput(listing)
  local configured = {}
  local order = {}
  local text = tostring(listing or "")
  for rawLine in (text .. "\n"):gmatch("(.-)\n") do
    local cols = splitMcpColumns(rawLine:gsub("\r$", ""))
    if #cols == 4 and (cols[3] == "enabled" or cols[3] == "disabled") then
      if configured[cols[1]] == nil then
        order[#order + 1] = cols[1]
      end
      configured[cols[1]] = cols[3]
    end
  end
  return configured, order
end

local function safeLstat(path)
  if not fs then
    return nil
  end
  if type(fs.lstat) == "function" then
    local ok, st = pcall(fs.lstat, path)
    if ok then
      return st
    end
    return nil
  end
  if type(fs.stat) == "function" then
    local ok, st = pcall(fs.stat, path)
    if ok then
      return st
    end
    return nil
  end
  return nil
end

local function managedPath(root, parts, wantDir)
  local rootSt = safeLstat(root)
  if not rootSt or not rootSt.exists or rootSt.isSymlink or not rootSt.isDir then
    return nil
  end
  local current = root:gsub("/+$", "")
  local lastSt = rootSt
  for _, part in ipairs(parts) do
    if type(part) ~= "string"
      or part == ""
      or part == "."
      or part == ".."
      or part:find("/", 1, true)
      or part:find("\\", 1, true)
    then
      return nil
    end
    current = current .. "/" .. part
    local st = safeLstat(current)
    if not st or not st.exists or st.isSymlink then
      return nil
    end
    lastSt = st
  end
  if wantDir then
    return lastSt.isDir and current or nil
  end
  return (not lastSt.isDir) and current or nil
end

local function readJsonFile(path)
  if not fs then
    return nil
  end
  local st = safeLstat(path)
  if not st or not st.exists or st.isSymlink or st.isDir then
    return nil
  end
  if type(st.size) == "number" and st.size > MAX_JSON_FILE_BYTES then
    return nil
  end
  local ok, raw = pcall(fs.readFile, path)
  if not ok or type(raw) ~= "string" then
    return nil
  end
  local dok, parsed = pcall(json.decode, raw)
  if not dok then
    return nil
  end
  return parsed
end

local function readMcpServers(listing, profileRoot)
  if profileRoot == nil then
    profileRoot = DEFAULT_PROFILE_ROOT
  end
  local configured, order = parseMcpListOutput(listing)
  local toolsByServer = {}
  local enabledCount = 0
  for _, name in ipairs(order) do
    if configured[name] == "enabled" then
      toolsByServer[name] = {}
      enabledCount = enabledCount + 1
    end
  end

  if enabledCount > 0 and fs then
    local cacheDir = managedPath(profileRoot, { "mcp" }, true)
    if cacheDir then
      pcall(function()
        local serverDirs = fs.readDir(cacheDir) or {}
        table.sort(serverDirs, function(a, b)
          return tostring(a and a.name or "") < tostring(b and b.name or "")
        end)
        for _, dir in ipairs(serverDirs) do
          if type(dir) == "table" and dir.isDir and toolsByServer[dir.name] ~= nil then
            local serverPath = managedPath(profileRoot, { "mcp", dir.name }, true)
            if serverPath then
              local toolFiles = fs.readDir(serverPath) or {}
              table.sort(toolFiles, function(a, b)
                return tostring(a and a.name or "") < tostring(b and b.name or "")
              end)
              local bucket = toolsByServer[dir.name]
              for _, file in ipairs(toolFiles) do
                if type(file) == "table" and not file.isDir and endsWith(file.name, ".json") then
                  local schema = readJsonFile(serverPath .. "/" .. file.name)
                  if isPlainObject(schema) and type(schema.name) == "string" and schema.name ~= "" then
                    local tool = {
                      name = schema.name,
                      description = type(schema.description) == "string" and schema.description or "",
                    }
                    if isPlainObject(schema.parameters) then
                      tool.parameters = schema.parameters
                    end
                    bucket[#bucket + 1] = tool
                  end
                end
              end
            end
          end
        end
      end)
    end
  end

  local servers = makeArray({})
  for _, name in ipairs(order) do
    local status = configured[name]
    servers[#servers + 1] = {
      name = name,
      status = status == "disabled" and "disabled" or "enabled",
      tools = makeArray(toolsByServer[name] or {}),
    }
  end
  return servers
end

-- ---------- Subagent & disk background-work detection ----------

local function inboxEntries(profileRoot, conversationId)
  if not fs then
    return nil
  end
  local inbox = managedPath(
    profileRoot,
    { "brain", conversationId, ".system_generated", "messages" },
    true
  )
  if not inbox then
    return nil
  end
  local ok, entries = pcall(fs.readDir, inbox)
  if not ok or type(entries) ~= "table" then
    return nil
  end
  local names = {}
  for _, ent in ipairs(entries) do
    local name = type(ent) == "table" and ent.name or nil
    if type(name) == "string" and endsWith(name, ".json") and name ~= "read.json" then
      names[#names + 1] = name
    end
  end
  if #names > MAX_MESSAGE_FILES then
    return nil
  end
  return { inbox = inbox, names = names }
end

local function readInboxMessages(profileRoot, conversationId)
  local listing = inboxEntries(profileRoot, conversationId)
  if not listing then
    return {}
  end
  local messages = {}
  for _, name in ipairs(listing.names) do
    local parsed = readJsonFile(listing.inbox .. "/" .. name)
    if isPlainObject(parsed) then
      messages[#messages + 1] = parsed
    end
  end
  return messages
end

local function detachedLaunchCallId(message, rootSessionId)
  if not isPlainObject(message) or message.sender ~= rootSessionId then
    return nil
  end
  local metadata = message.sourceMetadata
  if not isPlainObject(metadata) then
    return nil
  end
  local tool = metadata.tool
  if not isPlainObject(tool) then
    return nil
  end
  if not isNull(tool.conversationId) and tool.conversationId ~= rootSessionId then
    return nil
  end
  local call = tool.toolCall
  if not isPlainObject(call) or call.name ~= "invoke_subagent" then
    return nil
  end
  if type(call.id) == "string" and call.id ~= "" then
    return call.id
  end
  return nil
end

local function activeSubagentCalls(sessionId, toolCallIds, profileRoot)
  if profileRoot == nil then
    profileRoot = DEFAULT_PROFILE_ROOT
  end
  if not fs then
    return makeArray({})
  end
  local wanted = {}
  local wantedCount = 0
  if type(toolCallIds) == "table" then
    for k, v in pairs(toolCallIds) do
      if type(k) == "number" and type(v) == "string" and v ~= "" then
        if not wanted[v] then
          wanted[v] = true
          wantedCount = wantedCount + 1
        end
      elseif type(k) == "string" and k ~= "" and v == true then
        if not wanted[k] then
          wanted[k] = true
          wantedCount = wantedCount + 1
        end
      end
    end
  end
  if wantedCount == 0 then
    return makeArray({})
  end
  local validId = validSessionId(sessionId)
  if not validId then
    return makeArray({})
  end

  local subagentsDir = managedPath(
    profileRoot,
    { "brain", validId, ".system_generated", "subagents" },
    true
  )
  if not subagentsDir then
    return makeArray({})
  end

  local ok, entries = pcall(fs.readDir, subagentsDir)
  if not ok or type(entries) ~= "table" then
    return makeArray({})
  end

  local childIds = {}
  for _, ent in ipairs(entries) do
    local name = type(ent) == "table" and ent.name or nil
    if type(name) == "string" and endsWith(name, ".json") then
      local stem = name:sub(1, -6)
      if validSessionId(stem) then
        childIds[#childIds + 1] = stem
      end
    end
  end

  if #childIds == 0 or #childIds > MAX_DETACHED_CHILDREN then
    return makeArray({})
  end

  local reported = {}
  for _, msg in ipairs(readInboxMessages(profileRoot, validId)) do
    if type(msg.sender) == "string" then
      reported[msg.sender] = true
    end
  end

  local active = makeArray({})
  for _, childId in ipairs(childIds) do
    if not reported[childId] then
      local descriptor = readJsonFile(subagentsDir .. "/" .. childId .. ".json")
      if isPlainObject(descriptor)
        and (isNull(descriptor.conversationId) or descriptor.conversationId == childId)
        and descriptor.state ~= KILLED_SUBAGENT_STATE
      then
        for _, msg in ipairs(readInboxMessages(profileRoot, childId)) do
          local launchId = detachedLaunchCallId(msg, validId)
          if launchId and wanted[launchId] then
            active[#active + 1] = launchId
            break
          end
        end
      end
    end
  end
  return active
end

local function hasUnreadHighPriorityMessage(profileRoot, sessionId)
  local listing = inboxEntries(profileRoot, sessionId)
  if not listing or #listing.names == 0 then
    return false
  end
  local inbox = listing.inbox
  local names = listing.names
  local receipts = {}
  local readPath = inbox .. "/read.json"
  local readSt = safeLstat(readPath)
  if readSt and readSt.exists then
    local rawReceipts = readJsonFile(readPath)
    if not isPlainObject(rawReceipts) then
      return false
    end
    for k, v in pairs(rawReceipts) do
      if type(v) == "boolean" then
        receipts[k] = v
      end
    end
  end

  for _, name in ipairs(names) do
    local fileId = name:sub(1, -6)
    if receipts[fileId] ~= true then
      local parsed = readJsonFile(inbox .. "/" .. name)
      if isPlainObject(parsed) then
        if not (type(parsed.id) == "string" and receipts[parsed.id] == true) then
          if parsed.priority == HIGH_PRIORITY_MESSAGE then
            return true
          end
        end
      end
    end
  end
  return false
end

local function parseLastTranscriptLine(tailText, truncatedAtStart)
  local trimmed = tostring(tailText or ""):gsub("[\r\n]+$", "")
  if trimmed == "" then
    return nil
  end
  local nl = trimmed:match(".*()\n")
  if not nl and truncatedAtStart then
    return nil
  end
  local line = nl and trimmed:sub(nl + 1) or trimmed
  local ok, parsed = pcall(json.decode, line)
  if ok and isPlainObject(parsed) then
    return parsed
  end
  return nil
end

local function readLastTranscriptStep(profileRoot, sessionId)
  if not fs then
    return nil
  end
  local transcript = managedPath(
    profileRoot,
    { "brain", sessionId, ".system_generated", "logs", "transcript.jsonl" },
    false
  )
  if not transcript then
    return nil
  end
  local ok, step = pcall(function()
    local st = safeLstat(transcript)
    if not st or not st.exists or st.isSymlink or st.isDir or not (type(st.size) == "number" and st.size > 0) then
      return nil
    end
    local tailText
    local truncatedAtStart = false
    if type(fs.readFileTail) == "function" then
      tailText = fs.readFileTail(transcript, {
        maxBytes = TRANSCRIPT_MAX_TAIL_BYTES,
      })
      truncatedAtStart = st.size > TRANSCRIPT_MAX_TAIL_BYTES
    elseif st.size <= TRANSCRIPT_MAX_TAIL_BYTES then
      tailText = fs.readFile(transcript)
    else
      return nil
    end
    return parseLastTranscriptLine(tailText, truncatedAtStart)
  end)
  if not ok then
    return nil
  end
  return step
end

local function hasPendingReply(sessionId, profileRoot)
  if profileRoot == nil then
    profileRoot = DEFAULT_PROFILE_ROOT
  end
  if not fs then
    return false
  end
  local validId = validSessionId(sessionId)
  if not validId then
    return false
  end
  if hasUnreadHighPriorityMessage(profileRoot, validId) then
    return true
  end
  local lastStep = readLastTranscriptStep(profileRoot, validId)
  if not lastStep or lastStep.type ~= "SYSTEM_MESSAGE" then
    return false
  end
  local content = lastStep.content
  if type(content) ~= "string" then
    return true
  end
  return content:find("priority=" .. HIGH_PRIORITY_MESSAGE, 1, true) ~= nil
    or content:find("priority=" .. LOW_PRIORITY_MESSAGE, 1, true) == nil
end

local function hasLiveDiskBackgroundWork(sessionId, subagentCallIds, profileRoot)
  if profileRoot == nil then
    profileRoot = DEFAULT_PROFILE_ROOT
  end
  local ok, busy = pcall(function()
    local active = activeSubagentCalls(sessionId, subagentCallIds or {}, profileRoot)
    if #active > 0 then
      return true
    end
    if hasPendingReply(sessionId, profileRoot) then
      return true
    end
    return false
  end)
  if not ok then
    return false
  end
  return busy == true
end

local function resolveProfileRoot(env)
  if type(env) == "table" then
    local home = trim(env.HOME)
    if home == "" then
      home = trim(env.USERPROFILE)
    end
    if home ~= "" then
      return home:gsub("[\\/]+$", "") .. "/.gemini/antigravity-cli"
    end
  end
  return DEFAULT_PROFILE_ROOT
end

local function parseApiError(text)
  local status, message, code = text:match("Error (%d%d%d), Message: (.-), Status: ([A-Z_]+)")
  if status and message and code then
    return status, message, code
  end
  local stCode, httpCode, msg = text:match("([A-Z_]+) %(code (%d%d%d)%): ([^\0-\31\127]+)")
  if stCode and httpCode and msg then
    return httpCode, msg, stCode
  end
  return nil
end

local function extractResetHint(text)
  local ts = text:match("quotaResetTimeStamp:([^%s%]]+)")
  if ts and ts ~= "" then
    return "Resets at " .. ts .. "."
  end
  local delay = text:match("quotaResetDelay:([0-9%.a-zA-Zµμ]+)")
  if delay and delay ~= "" then
    return "Resets in " .. delay .. "."
  end
  local retry = text:match("retryDelay:([0-9%.a-zA-Zµμ]+)")
  if retry and retry ~= "" then
    return "Retry after " .. retry .. "."
  end
  return nil
end

-- Classify error text from trailing ACP error chunks or Antigravity error steps
-- (0.3 parity with bazaar_contrib_antigravity/state.py:classify_step_error).
local function classifyErrorText(rawText)
  local text = tostring(rawText or "")
  if text:find("messages%.%d+%.content%.%d+%.thinking%.signature: Field required")
    or text:find("messages%.%d+%.content%.%d+: Invalid `signature` in `thinking` block")
    or text:find("INVALID_THINKING_SIGNATURE", 1, true)
  then
    return {
      message = "Antigravity's saved conversation has an invalid thinking signature and can no longer be sent to the model. The next turn will start a fresh Antigravity session.",
      code = "INVALID_THINKING_SIGNATURE",
      sessionBroken = true,
    }
  end

  local httpStatus, rawMessage, status = parseApiError(text)
  local quotaExhausted = text:find("reason:QUOTA_EXHAUSTED", 1, true) ~= nil
    or text:find("QUOTA_EXHAUSTED", 1, true) ~= nil

  if httpStatus then
    local message = trim(rawMessage)
    if message == "" then
      message = "Antigravity API error (" .. httpStatus .. ")."
    end
    if quotaExhausted and not message:lower():find("reset", 1, true) then
      local hint = extractResetHint(text)
      if hint then
        message = message:gsub("%.+$", "") .. " (" .. hint .. ")"
      end
    end
    local code = (status ~= "" and status) or (quotaExhausted and "QUOTA_EXHAUSTED" or httpStatus)
    return {
      message = message,
      code = code,
      sessionBroken = false,
    }
  end

  if quotaExhausted then
    local message = "You have reached your Antigravity quota for this period."
    local hint = extractResetHint(text)
    if hint then
      message = message .. " " .. hint
    end
    return {
      message = message,
      code = "QUOTA_EXHAUSTED",
      sessionBroken = false,
    }
  end

  local cleaned = trim(text)
  return {
    message = cleaned ~= "" and cleaned or "Antigravity stopped this turn because of an error.",
    code = nil,
    sessionBroken = false,
  }
end

local function readLastTranscriptError(sessionId, profileRoot)
  if profileRoot == nil then
    profileRoot = DEFAULT_PROFILE_ROOT
  end
  local validId = validSessionId(sessionId)
  if not validId then
    return nil
  end
  local step = readLastTranscriptStep(profileRoot, validId)
  if not step then
    return nil
  end
  local stype = tostring(step.type or "")
  if stype == "ERROR" or stype == "ERROR_MESSAGE" or stype == "CORTEX_STEP_TYPE_ERROR_MESSAGE" then
    local content = type(step.content) == "string" and step.content
      or (type(step.error) == "string" and step.error)
      or (type(step.message) == "string" and step.message)
      or ""
    return classifyErrorText(content)
  end
  return nil
end

return {
  DEFAULT_PROFILE_ROOT = DEFAULT_PROFILE_ROOT,
  MAX_JSON_FILE_BYTES = MAX_JSON_FILE_BYTES,
  MAX_DETACHED_CHILDREN = MAX_DETACHED_CHILDREN,
  MAX_MESSAGE_FILES = MAX_MESSAGE_FILES,
  TRANSCRIPT_MAX_TAIL_BYTES = TRANSCRIPT_MAX_TAIL_BYTES,
  resolveProfileRoot = resolveProfileRoot,
  classifyErrorText = classifyErrorText,
  readLastTranscriptError = readLastTranscriptError,
  decodeUtf8 = decodeUtf8,
  parseModelsOutput = parseModelsOutput,
  parseMcpListOutput = parseMcpListOutput,
  readMcpServers = readMcpServers,
  detachedLaunchCallId = detachedLaunchCallId,
  activeSubagentCalls = activeSubagentCalls,
  parseLastTranscriptLine = parseLastTranscriptLine,
  hasPendingReply = hasPendingReply,
  hasLiveDiskBackgroundWork = hasLiveDiskBackgroundWork,
}
