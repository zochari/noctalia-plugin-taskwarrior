--!nonstrict
-- Taskwarrior client shared by the bar widget and the panel.
--
-- Commands are argv vectors passed to noctalia.runAsync's argument-array form
-- (plugin_api 24), which execs the binary directly: no shell, so no quoting
-- and no way for task text to become an operator, redirect or extra argument.
-- Reads ask for actionable pending tasks (`status:pending -WAITING`) and parse
-- the JSON with the host's decoder. Writes are arg builders; callers decide
-- when to run them (the panel serializes them, the bar widget only reads).

local taskwarrior = {}

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return noctalia.string.trim(value)
end

local function cleanConfiguredPath(value)
	local t = trim(value)
	if type(value) ~= "string" or t == "" then
		return nil
	end
	return noctalia.expandPath(t)
end

local function binary()
	return cleanConfiguredPath(noctalia.getConfig("task_binary")) or "task"
end

-- Optional taskwarrior instance overrides, placed immediately after the
-- binary: `task rc:/path/taskrc rc.data.location=/path/data ...`. Empty
-- settings produce no override and taskwarrior uses its own defaults.
local function contextArgs()
	local args = {}
	local rc = cleanConfiguredPath(noctalia.getConfig("task_rc"))
	if rc ~= nil then
		table.insert(args, "rc:" .. rc)
	end
	local dataDir = cleanConfiguredPath(noctalia.getConfig("task_data_dir"))
	if dataDir ~= nil then
		table.insert(args, "rc.data.location=" .. dataDir)
	end
	-- Never wait on a yes/no prompt: these processes have no stdin.
	table.insert(args, "rc.confirmation=off")
	-- Hooks can print to stdout and corrupt the JSON export.
	table.insert(args, "rc.hooks=off")
	return args
end

-- Every command starts with the binary plus the configured context.
local function baseArgv(tail)
	local argv = { binary() }
	for _, arg in ipairs(contextArgs()) do
		table.insert(argv, arg)
	end
	for _, arg in ipairs(tail) do
		table.insert(argv, arg)
	end
	return argv
end

-- PATH lookup for a bare command name, file existence for a path.
function taskwarrior.available()
	local bin = binary()
	if bin:find("/", 1, true) ~= nil then
		return noctalia.fileExists(bin)
	end
	return noctalia.commandExists(bin)
end

-- Run one task command. cb is called exactly once with the host's result
-- table ({ exitCode, stdout, stderr, timedOut, ... }), including when the
-- launch itself is rejected.
function taskwarrior.run(argv, cb)
	if type(cb) ~= "function" then
		return false
	end
	local done = false
	local function finish(result)
		if done then
			return
		end
		done = true
		cb(result)
	end
	local accepted = noctalia.runAsync(argv, finish)
	if not accepted then
		finish({
			exitCode = nil,
			stdout = "",
			stderr = "Failed to launch " .. binary(),
			timedOut = false,
			stdoutTruncated = false,
			stderrTruncated = false,
		})
	end
	return accepted
end

-- Human-readable failure text for an error notification.
local function describeFailure(result)
	if type(result) ~= "table" then
		return "Failed to run task"
	end
	if result.timedOut then
		return "task timed out"
	end
	local message = trim(result.stderr)
	if message == "" then
		message = trim(result.stdout)
	end
	if message == "" then
		local code = result.exitCode
		if type(code) == "number" then
			return "task exited with code " .. tostring(code)
		end
		return "Failed to run task"
	end
	return message
end

function taskwarrior.failureMessage(result)
	if type(result) == "table" and result.exitCode == 0 and not result.timedOut then
		return nil
	end
	return describeFailure(result)
end

-- ── Export ──────────────────────────────────────────────────────────────────

local function stringList(value)
	local list = {}
	if type(value) ~= "table" then
		return list
	end
	for _, entry in ipairs(value) do
		if type(entry) == "string" and entry ~= "" then
			table.insert(list, entry)
		end
	end
	return list
end

local function annotationCount(value)
	if type(value) ~= "table" then
		return 0
	end
	return #value
end

-- Parse a runAsync result of `task ... export` into a plain array of tasks.
-- Returns nil plus an error message on failure. Malformed rows are skipped
-- rather than crashing the render.
function taskwarrior.parseExport(result)
	if type(result) ~= "table" then
		return nil, "task did not return a result"
	end
	local msg = taskwarrior.failureMessage(result)
	if msg ~= nil then
		return nil, msg
	end
	local raw = type(result.stdout) == "string" and result.stdout or ""
	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		noctalia.log("task export returned invalid JSON: " .. tostring(decodeErr))
		return nil, "task export returned invalid JSON"
	end
	local tasks = {}
	for _, entry in ipairs(decoded) do
		if type(entry) == "table" and type(entry.uuid) == "string" then
			table.insert(tasks, {
				uuid = entry.uuid,
				description = type(entry.description) == "string" and entry.description or "",
				project = type(entry.project) == "string" and entry.project or "",
				tags = stringList(entry.tags),
				urgency = type(entry.urgency) == "number" and entry.urgency or 0,
				due = type(entry.due) == "string" and entry.due or "",
				entry = type(entry.entry) == "string" and entry.entry or "",
				notes = annotationCount(entry.annotations),
			})
		end
	end
	return tasks
end

-- Split a user-typed taskwarrior filter into argv elements. Quoted runs stay
-- together so `project:"two words"` survives.
local function splitFilter(text)
	local tokens = {}
	local current = nil
	local quote = nil
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if char == quote then
				quote = nil
			else
				current = (current or "") .. char
			end
		elseif char == '"' or char == "'" then
			quote = char
			current = current or ""
		elseif char == " " or char == "\t" then
			if current ~= nil then
				table.insert(tokens, current)
				current = nil
			end
		else
			current = (current or "") .. char
		end
	end
	if current ~= nil then
		table.insert(tokens, current)
	end
	return tokens
end

taskwarrior.splitFilter = splitFilter

-- Actionable pending tasks: `-WAITING` hides anything deferred with `wait:`,
-- which is the whole point of deferring it. An optional user filter is
-- appended verbatim.
function taskwarrior.exportArgs(filter)
	local tail = { "status:pending", "-WAITING" }
	for _, token in ipairs(splitFilter(trim(filter or ""))) do
		table.insert(tail, token)
	end
	table.insert(tail, "export")
	return baseArgv(tail)
end

-- Convenience single-shot read for entries that do not serialize writes.
function taskwarrior.export(filter, cb)
	taskwarrior.run(taskwarrior.exportArgs(filter), function(result)
		local tasks, err = taskwarrior.parseExport(result)
		cb(tasks, err)
	end)
end

-- ── Compose parsing ─────────────────────────────────────────────────────────

-- Attribute names a typed line may set. Anything else keeps its colon and
-- stays part of the description, so `Read: How to think` is not a command.
local ATTRIBUTES = {
	project = true,
	due = true,
	wait = true,
	scheduled = true,
	["until"] = true,
	recur = true,
	priority = true,
	pri = true,
	depends = true,
	start = true,
	["end"] = true,
}

local function isAttribute(token)
	local name = token:match("^([%a_]+):")
	if name == nil then
		return false
	end
	return ATTRIBUTES[name] == true
end

-- Only `+tag` sets a tag on a captured task. A leading minus stays literal,
-- so a line such as "-mail bob" keeps its first word in the description.
local function isTag(token)
	return token:match("^%+[%w_%.%-]+$") ~= nil
end

-- Split a typed line into taskwarrior attributes and literal description
-- text. Tags and known `name:value` attributes are lifted out wherever they
-- appear; everything else keeps its position in the description.
function taskwarrior.parseCompose(text)
	local parsed = { tags = {}, attributes = {}, words = {} }
	for _, token in ipairs(splitFilter(trim(text or ""))) do
		if isTag(token) then
			table.insert(parsed.tags, token)
		elseif isAttribute(token) then
			table.insert(parsed.attributes, token)
		else
			table.insert(parsed.words, token)
		end
	end
	parsed.description = table.concat(parsed.words, " ")
	return parsed
end

-- `--` tells taskwarrior everything after it is description text, so the
-- words a line leaves behind reach the task verbatim.
function taskwarrior.addArgs(parsed, defaultTags)
	local tail = { "add" }
	local tagged = #parsed.tags > 0
	for _, tag in ipairs(parsed.tags) do
		table.insert(tail, tag)
	end
	if not tagged then
		for _, tag in ipairs(defaultTags or {}) do
			table.insert(tail, "+" .. tag)
		end
	end
	for _, attribute in ipairs(parsed.attributes) do
		table.insert(tail, attribute)
	end
	table.insert(tail, "--")
	table.insert(tail, parsed.description)
	return baseArgv(tail)
end

function taskwarrior.modifyDescriptionArgs(uuid, description)
	return baseArgv({ uuid, "modify", "--", description })
end

function taskwarrior.doneArgs(uuid)
	return baseArgv({ uuid, "done" })
end

function taskwarrior.deleteArgs(uuid)
	return baseArgv({ uuid, "delete" })
end

-- Reverts the last taskwarrior change, whoever made it.
function taskwarrior.undoArgs()
	return baseArgv({ "undo" })
end

-- ── Dates ───────────────────────────────────────────────────────────────────

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil), so due dates need no os.date and no timezone database.
local function daysFromCivil(year, month, day)
	local y = year
	if month <= 2 then
		y -= 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (month + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

-- Taskwarrior stamps look like 20260924T170000Z. Returns unix seconds, or nil.
function taskwarrior.parseStamp(stamp)
	local year, month, day, hour, minute, second =
		tostring(stamp):match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
	if year == nil then
		return nil
	end
	local days = daysFromCivil(tonumber(year), tonumber(month), tonumber(day))
	return days * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

-- Local calendar day of a unix timestamp, as days since the epoch. The host's
-- strftime formatter renders in the system timezone, so "tomorrow" stays
-- tomorrow east and west of UTC.
local function localDay(atSeconds)
	local stamp = noctalia.formatTime("%Y%m%d", atSeconds)
	local year, month, day = tostring(stamp):match("^(%d%d%d%d)(%d%d)(%d%d)$")
	if year == nil then
		return math.floor(atSeconds / 86400)
	end
	return daysFromCivil(tonumber(year), tonumber(month), tonumber(day)), tonumber(month), tonumber(day)
end

-- Classify a due date relative to now. Returns a kind ("overdue", "today",
-- "tomorrow", "days", "date", "none") plus a detail: the day count for
-- "days", a short "12 Mar" for "date". The caller renders the wording.
function taskwarrior.dueKind(stamp, nowSeconds)
	local at = taskwarrior.parseStamp(stamp)
	if at == nil then
		return "none", nil
	end
	local now = nowSeconds or math.floor(noctalia.nowMs() / 1000)
	if at < now then
		return "overdue", nil
	end
	local dueDay, month, day = localDay(at)
	local delta = dueDay - localDay(now)
	if delta <= 0 then
		return "today", nil
	elseif delta == 1 then
		return "tomorrow", nil
	elseif delta < 7 then
		return "days", delta
	end
	return "date", tostring(day) .. " " .. (MONTHS[month] or "?")
end

return taskwarrior
