--!nonstrict
-- Taskwarrior — bar widget that toggles the task panel.
--
-- The glyph is configurable (widget setting). It lights up while the panel is
-- open (shared "todo_open" state, published by panel.luau) and its tooltip
-- shows how many tasks are still pending. The count comes from a 2-second
-- `task status:pending -WAITING export` poll, so it reflects edits made
-- outside noctalia too. Polls never overlap: a slow export skips a tick.

local taskwarrior = require("./taskwarrior.luau")

local PANEL_ID = "lpzchr/taskwarrior:panel"
local open = false
local pending = 0
local polling = false
local missing = false
local missingNotified = false
local unavailable = false
local errorNotified = false

local function render()
	barWidget.setGlyph(noctalia.getConfig("glyph"))
	barWidget.setGlyphColor(open and "primary" or "on_surface")
	if missing then
		barWidget.setTooltip(noctalia.tr("tooltip_missing"))
	elseif unavailable then
		barWidget.setTooltip(noctalia.tr("tooltip_unavailable"))
	else
		barWidget.setTooltip(noctalia.tr("tooltip", { count = pending }))
	end
end

local function poll()
	if polling then
		return
	end
	polling = true
	taskwarrior.export("", function(tasks, err)
		polling = false
		if err ~= nil then
			if not errorNotified then
				noctalia.notifyError(noctalia.tr("title"), err)
			end
			errorNotified = true
			unavailable = true
			pending = 0
			render()
			return
		end
		errorNotified = false
		unavailable = false
		pending = #tasks
		render()
	end)
end

local function checkTask()
	local wasMissing = missing
	missing = not taskwarrior.available()
	if missing then
		pending = 0
		unavailable = false
		if not wasMissing and not missingNotified then
			missingNotified = true
			noctalia.notifyError(noctalia.tr("title"), noctalia.tr("task_missing"))
		end
	else
		missingNotified = false
	end
	render()
end

noctalia.state.watch("todo_open", function(value)
	open = value == true
	render()
end)

function update()
	poll()
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
	checkTask()
	if not missing then
		poll()
	end
end

noctalia.setUpdateInterval(2000)
checkTask()
if not missing then
	poll()
end
