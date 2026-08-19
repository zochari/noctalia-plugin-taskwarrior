--!nonstrict
-- Taskwarrior client shared by the bar widget and the panel.
--
-- All commands go through the string form of noctalia.runAsync, but every
-- argv element is POSIX single-quoted first, so a task description is always
-- exactly one argument: no shell metacharacter can escape it. (The argv-array
-- form needs plugin_api 24, which no released Noctalia build provides yet;
-- this plugin targets 22 so it runs on Noctalia 5.0.0-beta.8+.) Reads ask for
-- pending tasks only (`task status:pending export`) and parse the JSON with
-- the host's decoder. Writes are arg builders; callers decide when to run
-- them (the panel serializes them, the bar widget only ever reads).

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

-- POSIX single-quote an argv element: `foo'bar` becomes 'foo'\''bar'.
local function shellQuote(arg)
	return "'" .. tostring(arg):gsub("'", "'\\''") .. "'"
end

-- One argv vector as a /bin/sh command; every element is quoted, so task text
-- cannot become an operator, redirect, expansion, or extra argument.
local function shellCommand(argv)
	local parts = {}
	for _, arg in ipairs(argv) do
		table.insert(parts, shellQuote(arg))
	end
	return table.concat(parts, " ")
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
	local accepted = noctalia.runAsync(shellCommand(argv), finish)
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
local function isValidPriority(value)
	return value == "H" or value == "M" or value == "L"
end

local function normalizePriority(value)
	if isValidPriority(value) then
		return value
	end
	return ""
end

-- Parse a runAsync result of `task status:pending export` into a plain array
-- of { uuid, description, priority }. Returns nil plus an error message on
-- failure. Malformed rows are skipped rather than crashing the render.
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
				priority = normalizePriority(entry.priority),
			})
		end
	end
	return tasks
end

function taskwarrior.exportArgs()
	return baseArgv({ "status:pending", "export" })
end

-- Convenience single-shot read for entries that do not serialize writes.
function taskwarrior.export(cb)
	taskwarrior.run(taskwarrior.exportArgs(), function(result)
		local tasks, err = taskwarrior.parseExport(result)
		cb(tasks, err)
	end)
end

-- `--` tells taskwarrior everything after it is description text, so a task
-- such as "-mail bob" or "project:looks-like-attr" cannot be parsed as a
-- modification.
function taskwarrior.addArgs(description, priority)
	local tail = { "add" }
	if isValidPriority(priority) then
		table.insert(tail, "priority:" .. priority)
	end
	table.insert(tail, "--")
	table.insert(tail, description)
	return baseArgv(tail)
end

function taskwarrior.modifyDescriptionArgs(uuid, description)
	return baseArgv({ uuid, "modify", "--", description })
end

-- An empty priority clears the attribute (`task <uuid> modify priority:`).
function taskwarrior.priorityArgs(uuid, priority)
	if priority == "" then
		return baseArgv({ uuid, "modify", "priority:" })
	end
	return baseArgv({ uuid, "modify", "priority:" .. priority })
end

function taskwarrior.doneArgs(uuid)
	return baseArgv({ uuid, "done" })
end

-- confirmation=off makes delete non-interactive (stdin-less spawns would
-- otherwise hang on the yes/no prompt).
function taskwarrior.deleteArgs(uuid)
	return baseArgv({ "rc.confirmation=off", uuid, "delete" })
end

return taskwarrior
