--!nonstrict
-- iCalendar (RFC 5545) reader/writer, scoped to the VTODO components CalDAV
-- task lists are made of.
--
-- Parsing keeps the *whole* component tree, properties and parameters included,
-- rather than extracting a handful of fields. Editing a task then rewrites only
-- the properties this plugin manages and re-serializes everything else
-- untouched, so round-tripping a task through the panel never discards
-- alarms, recurrence rules, attachments, or the VTIMEZONE blocks a task from
-- Reminders or Tasks may carry.

local M = {}

-- ── Line handling ────────────────────────────────────────────────────────────

-- RFC 5545 folds long lines by inserting CRLF + a single space or tab. Unfold
-- before anything else, since a fold can land mid-property or mid-UTF-8.
-- Walks the source once instead of rewriting every line ending first: the two
-- whole-document gsubs this replaces each allocated another copy of the object,
-- which is real money under the host's per-callback CPU budget. Continuation
-- pieces are collected and joined once per property rather than concatenated
-- onto a growing string, so a heavily folded DESCRIPTION stays linear.
local function unfold(source: string)
  local lines = {}
  local parts = nil -- accumulating pieces of the line being unfolded
  local pos = 1
  local length = #source

  local function flush()
    if parts ~= nil then
      lines[#lines] = table.concat(parts)
      parts = nil
    end
  end

  while pos <= length do
    local breakAt = source:find("[\r\n]", pos)
    local lineEnd = (breakAt or (length + 1)) - 1
    local rawLine = source:sub(pos, lineEnd)

    local leading = rawLine:byte(1)
    if (leading == 32 or leading == 9) and #lines > 0 then
      if parts == nil then
        parts = { lines[#lines] }
      end
      parts[#parts + 1] = rawLine:sub(2)
    elseif rawLine ~= "" then
      flush()
      lines[#lines + 1] = rawLine
    end

    if breakAt == nil then
      break
    end
    -- CRLF is one separator, not two empty lines.
    pos = breakAt + 1
    if source:byte(breakAt) == 13 and source:byte(pos) == 10 then
      pos += 1
    end
  end

  flush()
  return lines
end

-- Folds at 75 octets. The split never lands inside a UTF-8 sequence: octets
-- 0x80..0xBF are continuation bytes, so back up until the boundary is a lead.
local function fold(line: string)
  if #line <= 75 then
    return line
  end
  local parts = {}
  local pos = 1
  local limit = 75
  while pos <= #line do
    local stop = math.min(pos + limit - 1, #line)
    if stop < #line then
      while stop > pos do
        local byte = line:byte(stop + 1)
        if byte == nil or byte < 0x80 or byte >= 0xC0 then
          break
        end
        stop -= 1
      end
    end
    table.insert(parts, line:sub(pos, stop))
    pos = stop + 1
    limit = 74 -- continuation lines carry a leading space
  end
  return table.concat(parts, "\r\n ")
end

-- ── Value escaping ───────────────────────────────────────────────────────────

function M.unescapeText(value: string): string
  if not value:find("\\", 1, true) then
    return value
  end
  local out = {}
  local pos = 1
  while pos <= #value do
    local char = value:sub(pos, pos)
    if char == "\\" then
      local next = value:sub(pos + 1, pos + 1)
      if next == "n" or next == "N" then
        table.insert(out, "\n")
      elseif next == "" then
        table.insert(out, "\\")
      else
        table.insert(out, next) -- \\ \; \, and any stray escape
      end
      pos += 2
    else
      table.insert(out, char)
      pos += 1
    end
  end
  return table.concat(out)
end

function M.escapeText(value: string): string
  return (value
    :gsub("\\", "\\\\")
    :gsub("\r\n", "\\n")
    :gsub("\n", "\\n")
    :gsub("\r", "\\n")
    :gsub(";", "\\;")
    :gsub(",", "\\,"))
end

-- ── Property lines ───────────────────────────────────────────────────────────

-- Splits "NAME;PARAM=a;OTHER=\"b;c\":value" honouring quoted parameter values,
-- which may legally contain the ':' and ';' that otherwise delimit the line.
--
-- The character loop is the slow path and is reached only when the line
-- actually contains a quote. Scanning a line one `sub(i, i)` at a time
-- allocates a string per character, which under the host's budget-instrumented
-- interpreter is the single most expensive thing this module used to do --
-- and virtually no real property line is quoted.
local function splitPropertyLine(line: string)
  local quote = line:find('"', 1, true)
  local colon = line:find(":", 1, true)
  if colon == nil then
    return line, ""
  end
  if quote == nil or colon < quote then
    return line:sub(1, colon - 1), line:sub(colon + 1)
  end

  local inQuotes = false
  for index = 1, #line do
    local char = line:sub(index, index)
    if char == '"' then
      inQuotes = not inQuotes
    elseif char == ":" and not inQuotes then
      return line:sub(1, index - 1), line:sub(index + 1)
    end
  end
  return line, ""
end

local function parseParameters(segment: string)
  local params = {}
  local order = {}
  -- Most properties carry no parameters at all, and almost none quote them.
  if segment == "" then
    return params, order
  end
  if segment:find('"', 1, true) == nil then
    for chunk in segment:gmatch("[^;]+") do
      local name, value = chunk:match("^([^=]+)=(.*)$")
      if name == nil then
        name, value = chunk, ""
      end
      local key = name:upper()
      if params[key] == nil then
        table.insert(order, key)
      end
      params[key] = value
    end
    return params, order
  end

  local pos = 1
  while pos <= #segment do
    local semicolon = nil
    local inQuotes = false
    for index = pos, #segment do
      local char = segment:sub(index, index)
      if char == '"' then
        inQuotes = not inQuotes
      elseif char == ";" and not inQuotes then
        semicolon = index
        break
      end
    end
    local chunk = segment:sub(pos, (semicolon or (#segment + 1)) - 1)
    if chunk ~= "" then
      local name, value = chunk:match("^([^=]+)=(.*)$")
      if name == nil then
        name, value = chunk, ""
      end
      if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
        value = value:sub(2, -2)
      end
      local key = name:upper()
      if params[key] == nil then
        table.insert(order, key)
      end
      params[key] = value
    end
    pos = (semicolon or #segment) + 1
  end
  return params, order
end

-- ── Component tree ───────────────────────────────────────────────────────────

-- A component is { name, props = { {name, params, paramOrder, value} }, children = {} }.
function M.parse(source: string)
  -- Deliberately not `trim(source) == ""`: trimming allocates a copy of the
  -- whole calendar object just to test it for content, and the obvious
  -- `gsub("%s+$", "")` spelling is quadratic in a trailing whitespace run.
  if type(source) ~= "string" or source:find("%S") == nil then
    return nil, "empty calendar object"
  end
  local root = { name = "ROOT", props = {}, children = {} }
  local stack = { root }

  for _, line in ipairs(unfold(source)) do
    local nameSegment, value = splitPropertyLine(line)
    local name = nameSegment:match("^([^;]+)") or nameSegment
    name = name:upper()
    if name == "BEGIN" then
      local component = { name = value:upper(), props = {}, children = {} }
      table.insert(stack[#stack].children, component)
      table.insert(stack, component)
    elseif name == "END" then
      if #stack > 1 and stack[#stack].name == value:upper() then
        table.remove(stack)
      end
    else
      local params, paramOrder = parseParameters(nameSegment:sub(#name + 2))
      table.insert(stack[#stack].props, {
        name = name,
        params = params,
        paramOrder = paramOrder,
        value = value,
      })
    end
  end

  local calendar = root.children[1]
  if calendar == nil then
    return nil, "no calendar component"
  end
  return calendar
end

function M.serialize(component): string
  local lines = {}
  local function emit(current)
    table.insert(lines, "BEGIN:" .. current.name)
    for _, prop in ipairs(current.props) do
      local segments = { prop.name }
      for _, key in ipairs(prop.paramOrder or {}) do
        local value = prop.params[key]
        if value ~= nil then
          -- Quote whenever the value carries a delimiter, per RFC 5545 §3.2.
          if value:find('[;:,]') then
            value = '"' .. value:gsub('"', "") .. '"'
          end
          table.insert(segments, key .. "=" .. value)
        end
      end
      table.insert(lines, fold(table.concat(segments, ";") .. ":" .. prop.value))
    end
    for _, child in ipairs(current.children) do
      emit(child)
    end
    table.insert(lines, "END:" .. current.name)
  end
  emit(component)
  table.insert(lines, "")
  return table.concat(lines, "\r\n")
end

function M.findComponent(component, name: string)
  for _, child in ipairs(component.children) do
    if child.name == name then
      return child
    end
  end
  return nil
end

function M.getProp(component, name: string)
  for _, prop in ipairs(component.props) do
    if prop.name == name then
      return prop
    end
  end
  return nil
end

function M.getValue(component, name: string): string?
  local prop = M.getProp(component, name)
  return prop ~= nil and prop.value or nil
end

-- Replaces a property, or appends it when absent. A nil value removes it.
-- Existing parameters are dropped with the old property: callers pass the
-- parameters that belong with the new value (a DATE due date must not inherit
-- the TZID of the DATE-TIME it replaces).
function M.setProp(component, name: string, value: string?, params: { [string]: string }?, paramOrder: { string }?)
  for index, prop in ipairs(component.props) do
    if prop.name == name then
      if value == nil then
        table.remove(component.props, index)
      else
        prop.value = value
        prop.params = params or {}
        prop.paramOrder = paramOrder or {}
      end
      return
    end
  end
  if value ~= nil then
    table.insert(component.props, {
      name = name,
      params = params or {},
      paramOrder = paramOrder or {},
      value = value,
    })
  end
end

-- ── Dates ────────────────────────────────────────────────────────────────────

-- Seconds to add to a local-time os.time() result to reinterpret it as UTC.
local function utcOffsetAt(approx: number): number
  local utc = os.date("!*t", approx)
  utc.isdst = false
  return os.difftime(approx, os.time(utc))
end

-- Parses DATE ("20260315") and DATE-TIME ("20260315T140000" / "...Z").
--
-- Values with a TZID parameter are read as local time: the plugin runtime has
-- no timezone database to resolve an arbitrary IANA zone with, and a task's
-- zone is the user's own in every ordinary case. A zoned task authored
-- elsewhere can therefore be off by that zone's offset -- it affects display
-- and sorting only, never what is written back, since the original property is
-- preserved verbatim unless the user edits the due date.
function M.parseDate(value: string, params: { [string]: string }?)
  if value == nil or value == "" then
    return nil
  end
  local year, month, day = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
  if year == nil then
    return nil
  end
  local hour, minute, second = value:match("^%d%d%d%d%d%d%d%dT(%d%d)(%d%d)(%d%d)")
  local dateOnly = hour == nil
  local fields = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour) or 0,
    min = tonumber(minute) or 0,
    sec = tonumber(second) or 0,
    isdst = false,
  }
  local epoch = os.time(fields)
  if epoch == nil then
    return nil
  end
  if value:sub(-1) == "Z" then
    epoch += utcOffsetAt(epoch)
  end
  return {
    epoch = epoch,
    dateOnly = dateOnly,
    -- A DATE value, or a DATE-TIME the user's own clock agrees with, is
    -- comparable against "today" without qualification.
    floating = not dateOnly and value:sub(-1) ~= "Z" and (params == nil or params.TZID == nil),
  }
end

function M.formatDate(epoch: number): string
  return os.date("%Y%m%d", epoch)
end

function M.formatDateTimeUtc(epoch: number): string
  return os.date("!%Y%m%dT%H%M%SZ", epoch)
end

-- ── VTODO projection ─────────────────────────────────────────────────────────

local PRIORITY_HIGH = 4 -- RFC 5545: 1-4 high, 5 normal, 6-9 low

-- Flattens a VTODO into the plain record the UI renders, keeping a reference to
-- the parsed calendar so an edit can be written back without re-parsing.
function M.readTodo(calendar)
  local vtodo = M.findComponent(calendar, "VTODO")
  if vtodo == nil then
    return nil
  end
  local status = (M.getValue(vtodo, "STATUS") or ""):upper()
  local percent = tonumber(M.getValue(vtodo, "PERCENT-COMPLETE") or "") or 0
  local completedProp = M.getProp(vtodo, "COMPLETED")
  local dueProp = M.getProp(vtodo, "DUE")
  local startProp = M.getProp(vtodo, "DTSTART")
  local priority = tonumber(M.getValue(vtodo, "PRIORITY") or "") or 0

  return {
    uid = M.getValue(vtodo, "UID") or "",
    summary = M.unescapeText(M.getValue(vtodo, "SUMMARY") or ""),
    description = M.unescapeText(M.getValue(vtodo, "DESCRIPTION") or ""),
    status = status,
    -- Clients disagree on how "done" is recorded: STATUS:COMPLETED, a
    -- COMPLETED timestamp, or PERCENT-COMPLETE:100. Any of them counts.
    completed = status == "COMPLETED" or completedProp ~= nil or percent >= 100,
    cancelled = status == "CANCELLED",
    completedAt = completedProp ~= nil and M.parseDate(completedProp.value, completedProp.params) or nil,
    due = dueProp ~= nil and M.parseDate(dueProp.value, dueProp.params) or nil,
    start = startProp ~= nil and M.parseDate(startProp.value, startProp.params) or nil,
    priority = priority,
    important = priority > 0 and priority <= PRIORITY_HIGH,
    -- RELATED-TO;RELTYPE=PARENT is how both Reminders and Tasks nest subtasks.
    parentUid = (function()
      for _, prop in ipairs(vtodo.props) do
        if prop.name == "RELATED-TO" and (prop.params.RELTYPE == nil or prop.params.RELTYPE:upper() == "PARENT") then
          return prop.value
        end
      end
      return nil
    end)(),
    recurring = M.getProp(vtodo, "RRULE") ~= nil,
    sortOrder = tonumber(M.getValue(vtodo, "X-APPLE-SORT-ORDER") or "") or nil,
    calendar = calendar,
    vtodo = vtodo,
  }
end

function M.markComplete(vtodo, complete: boolean, now: number)
  if complete then
    M.setProp(vtodo, "STATUS", "COMPLETED")
    M.setProp(vtodo, "COMPLETED", M.formatDateTimeUtc(now))
    M.setProp(vtodo, "PERCENT-COMPLETE", "100")
  else
    M.setProp(vtodo, "STATUS", "NEEDS-ACTION")
    M.setProp(vtodo, "COMPLETED", nil)
    M.setProp(vtodo, "PERCENT-COMPLETE", nil)
  end
  M.touch(vtodo, now)
end

-- Bumps the revision fields every CalDAV server expects to move on a write.
function M.touch(vtodo, now: number)
  local sequence = tonumber(M.getValue(vtodo, "SEQUENCE") or "0") or 0
  M.setProp(vtodo, "SEQUENCE", tostring(sequence + 1))
  M.setProp(vtodo, "LAST-MODIFIED", M.formatDateTimeUtc(now))
  M.setProp(vtodo, "DTSTAMP", M.formatDateTimeUtc(now))
end

-- Due dates written by this plugin are all-day DATE values. That sidesteps the
-- timezone database the runtime does not have, and matches how both Reminders
-- and Tasks record a day-granularity due date.
function M.setDueDate(vtodo, epoch: number?, now: number)
  if epoch == nil then
    M.setProp(vtodo, "DUE", nil)
  else
    M.setProp(vtodo, "DUE", M.formatDate(epoch), { VALUE = "DATE" }, { "VALUE" })
  end
  M.touch(vtodo, now)
end

function M.setSummary(vtodo, summary: string, now: number)
  M.setProp(vtodo, "SUMMARY", M.escapeText(summary))
  M.touch(vtodo, now)
end

function M.setDescription(vtodo, description: string, now: number)
  if description == "" then
    M.setProp(vtodo, "DESCRIPTION", nil)
  else
    M.setProp(vtodo, "DESCRIPTION", M.escapeText(description))
  end
  M.touch(vtodo, now)
end

function M.setPriority(vtodo, priority: number, now: number)
  if priority <= 0 then
    M.setProp(vtodo, "PRIORITY", nil)
  else
    M.setProp(vtodo, "PRIORITY", tostring(priority))
  end
  M.touch(vtodo, now)
end

-- Builds a fresh VCALENDAR/VTODO for a task created in the panel or launcher.
function M.newTodo(uid: string, summary: string, now: number, dueEpoch: number?)
  local vtodo = { name = "VTODO", props = {}, children = {} }
  local calendar = {
    name = "VCALENDAR",
    props = {
      { name = "VERSION", params = {}, paramOrder = {}, value = "2.0" },
      { name = "PRODID", params = {}, paramOrder = {}, value = "-//duchovs//noctalia-tasks//EN" },
    },
    children = { vtodo },
  }
  M.setProp(vtodo, "UID", uid)
  M.setProp(vtodo, "DTSTAMP", M.formatDateTimeUtc(now))
  M.setProp(vtodo, "CREATED", M.formatDateTimeUtc(now))
  M.setProp(vtodo, "LAST-MODIFIED", M.formatDateTimeUtc(now))
  M.setProp(vtodo, "SEQUENCE", "0")
  M.setProp(vtodo, "SUMMARY", M.escapeText(summary))
  M.setProp(vtodo, "STATUS", "NEEDS-ACTION")
  if dueEpoch ~= nil then
    M.setProp(vtodo, "DUE", M.formatDate(dueEpoch), { VALUE = "DATE" }, { "VALUE" })
  end
  return calendar, vtodo
end

return M
