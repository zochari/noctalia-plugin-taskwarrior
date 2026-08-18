--!nonstrict
-- Taskwarrior — pending-task panel backed by the `task` CLI.
--
-- Every item is a pending taskwarrior task { uuid, description, priority }.
-- The panel owns a FIFO of task processes: the next command is launched only
-- after the previous callback fires, so taskwarrior's data file is never
-- written by two processes at once. Reads share the queue, so a refresh can
-- never interleave with a write. After writes drain, one coalesced
-- `task status:pending export` refreshes the model.
--
-- UI interactions are optimistic (the row updates immediately) and the queued
-- write confirms; a failed write raises an error notification and the
-- coalesced refresh restores the real state. Inline edits commit on Enter or
-- ✓ only — there is no draft state in taskwarrior. Completing a task removes
-- its row: the panel shows pending tasks only.

local taskwarrior = require("./taskwarrior.luau")

local PANEL_WIDTH = 560 -- keep in sync with [[panel]] width in plugin.toml
local PANEL_PADDING = 16
local SCROLLBAR_GUTTER = 14
local ROW_GAP = 10
local CHIP_W = 22
local GLYPH_BTN_W = 36
local ROW_CONTENT_W = PANEL_WIDTH - (2 * PANEL_PADDING) - SCROLLBAR_GUTTER

-- Width left for the task text once the chip and the three trailing glyph
-- buttons (each preceded by a gap) have taken their share.
local function taskTextWidth(trailing)
	return ROW_CONTENT_W - CHIP_W - ROW_GAP - (trailing * (GLYPH_BTN_W + ROW_GAP))
end

local NEW_ID = "__new__"
local RANK = { H = 1, M = 2, L = 3, [""] = 4 }
local CYCLE = { H = "M", M = "L", L = "", [""] = "H" }
local COLORS = { H = "#e06c75", M = "#e5c07b", L = "#98c379", [""] = "#6c7086" }
local PRIORITY_KEYS = { H = "important", M = "medium", L = "low", [""] = "none" }

local items = {} -- pending tasks, kept in display order (priority, text, uuid)
local loaded = false
local loadError = nil
local lastNotifiedError = nil
local editingId = nil -- item uuid, or NEW_ID for the transient new-task row
local editingText = ""
local panelOpen = false

-- Serial launch queue. A job is { argv, rev? } where rev marks reads; a read
-- whose revision is stale (a write was queued after it) is discarded.
local queue = {}
local running = false
local refreshWanted = false
local revision = 0

local render

local function tr(key, args)
	return noctalia.tr(key, args)
end

local function findItem(uuid)
	for _, item in ipairs(items) do
		if item.uuid == uuid then
			return item
		end
	end
	return nil
end

local function removeItem(uuid)
	for index, item in ipairs(items) do
		if item.uuid == uuid then
			table.remove(items, index)
			return true
		end
	end
	return false
end

local function sortItems()
	table.sort(items, function(a, b)
		local ra, rb = RANK[a.priority], RANK[b.priority]
		if ra ~= rb then
			return ra < rb
		end
		local da, db = a.description:lower(), b.description:lower()
		if da ~= db then
			return da < db
		end
		return a.uuid < b.uuid -- uuid is unique: deterministic final tie-break
	end)
end

-- ── Serial task queue ────────────────────────────────────────────────────────

local function makeReadJob()
	return { argv = taskwarrior.exportArgs(), rev = revision }
end

local function pump()
	if running then
		return
	end
	if #queue == 0 and refreshWanted then
		refreshWanted = false
		table.insert(queue, makeReadJob())
	end
	if #queue == 0 then
		return
	end
	local job = table.remove(queue, 1)
	running = true
	taskwarrior.run(job.argv, function(result)
		running = false
		if job.rev ~= nil then
			if job.rev == revision then
				local tasks, err = taskwarrior.parseExport(result)
				if err ~= nil then
					loadError = tr("load_failed")
					if lastNotifiedError ~= err then
						lastNotifiedError = err
						noctalia.notifyError(tr("title"), err)
					end
				else
					items = tasks
					sortItems()
					loadError = nil
					lastNotifiedError = nil
					if editingId ~= NEW_ID and editingId ~= nil and findItem(editingId) == nil then
						editingId = nil
						editingText = ""
					end
				end
				loaded = true
				render()
			end
		else
			if result.exitCode ~= 0 then
				local message = taskwarrior.describeFailure(result)
				if lastNotifiedError ~= message then
					lastNotifiedError = message
					noctalia.notifyError(tr("title"), message)
				end
			end
		end
		pump()
	end)
end

local function refresh()
	table.insert(queue, makeReadJob())
	pump()
end

-- Every write invalidates in-flight reads (revision) and schedules exactly
-- one refresh once the queue drains (refreshWanted).
local function queueWrite(argv)
	revision += 1
	refreshWanted = true
	table.insert(queue, { argv = argv })
	pump()
end

-- ── Model operations (optimistic) ───────────────────────────────────────────

local function enterEdit(uuid)
	editingId = uuid
	local item = findItem(uuid)
	editingText = item ~= nil and item.description or ""
	render()
end

local function commitEdit(uuid, value)
	local text = noctalia.string.trim(value or "")
	if uuid == NEW_ID then
		editingId = nil
		editingText = ""
		if text ~= "" then
			queueWrite(taskwarrior.addArgs(text, "M"))
		end
		render()
		return
	end
	local item = findItem(uuid)
	editingId = nil
	editingText = ""
	if item ~= nil and text ~= "" and text ~= item.description then
		item.description = text
		sortItems()
		queueWrite(taskwarrior.modifyDescriptionArgs(uuid, text))
	end
	render()
end

local function cyclePriority(uuid)
	local item = findItem(uuid)
	if item == nil then
		return
	end
	item.priority = CYCLE[item.priority] or "H"
	sortItems()
	queueWrite(taskwarrior.priorityArgs(uuid, item.priority))
	render()
end

local function completeTask(uuid)
	if findItem(uuid) == nil then
		return
	end
	if editingId == uuid then
		editingId = nil
		editingText = ""
	end
	removeItem(uuid)
	queueWrite(taskwarrior.doneArgs(uuid))
	render()
end

local function deleteTask(uuid)
	if uuid == NEW_ID then
		editingId = nil
		editingText = ""
		render()
		return
	end
	if findItem(uuid) == nil then
		return
	end
	if editingId == uuid then
		editingId = nil
		editingText = ""
	end
	removeItem(uuid)
	queueWrite(taskwarrior.deleteArgs(uuid))
	render()
end

-- ── UI ───────────────────────────────────────────────────────────────────────

-- Transient row for the task being typed. Nothing reaches taskwarrior until
-- Enter/✓; the trash (close) button discards it.
local function newTaskRow()
	local children = {
		ui.box({
			key = "chip-new-M",
			width = CHIP_W,
			height = 22,
			radius = 4,
			fill = COLORS.M,
		}),
		ui.input({
			key = "text-new",
			value = editingText,
			placeholder = tr("placeholder"),
			focus = true,
			fontSize = 18,
			controlHeight = 54,
			flexGrow = 1,
			onChange = function(value)
				editingText = value
			end,
			onSubmit = function(value)
				commitEdit(NEW_ID, value)
			end,
		}),
		ui.button({
			glyph = "check",
			variant = "primary",
			width = GLYPH_BTN_W,
			height = GLYPH_BTN_W,
			tooltip = tr("tip_commit"),
			onClick = function()
				commitEdit(NEW_ID, editingText)
			end,
		}),
		ui.button({
			glyph = "close",
			variant = "ghost",
			width = GLYPH_BTN_W,
			height = GLYPH_BTN_W,
			tooltip = tr("tip_cancel"),
			onClick = function()
				deleteTask(NEW_ID)
			end,
		}),
	}
	return ui.row({ key = "row-new-edit", gap = 10, align = "center" }, children)
end

local function taskRow(item)
	local uuid = item.uuid
	local editing = editingId == uuid
	local chip = ui.box({
		-- priority in the key forces a fresh box on cycle in case the host
		-- retains the node and would not repaint the new fill colour
		key = "chip-" .. uuid .. "-" .. item.priority,
		width = CHIP_W,
		height = 22,
		radius = 4,
		fill = COLORS[item.priority],
		onClick = function()
			cyclePriority(uuid)
		end,
	})
	local children = { chip }
	if editing then
		table.insert(
			children,
			ui.input({
				key = "text-" .. uuid,
				value = editingText,
				placeholder = tr("placeholder"),
				focus = true,
				fontSize = 18,
				controlHeight = 54,
				flexGrow = 1,
				onChange = function(value)
					editingText = value
				end,
				onSubmit = function(value)
					commitEdit(uuid, value)
				end,
			})
		)
		table.insert(
			children,
			ui.button({
				glyph = "check",
				variant = "primary",
				width = GLYPH_BTN_W,
				height = GLYPH_BTN_W,
				tooltip = tr("tip_commit"),
				onClick = function()
					commitEdit(uuid, editingText)
				end,
			})
		)
	else
		table.insert(
			children,
			ui.button({
				key = "view-" .. uuid,
				text = item.description,
				variant = "ghost",
				contentAlign = "start",
				fontSize = 18,
				controlHeight = 54,
				paddingH = 8,
				width = taskTextWidth(3),
				onClick = function()
					enterEdit(uuid)
				end,
			})
		)
		table.insert(
			children,
			ui.button({
				glyph = "square",
				variant = "ghost",
				width = GLYPH_BTN_W,
				height = GLYPH_BTN_W,
				tooltip = tr("tip_done"),
				onClick = function()
					completeTask(uuid)
				end,
			})
		)
		table.insert(
			children,
			ui.button({
				glyph = "pencil",
				variant = "ghost",
				width = GLYPH_BTN_W,
				height = GLYPH_BTN_W,
				tooltip = tr("tip_edit"),
				onClick = function()
					enterEdit(uuid)
				end,
			})
		)
	end
	table.insert(
		children,
		ui.button({
			glyph = "trash",
			variant = "ghost",
			width = GLYPH_BTN_W,
			height = GLYPH_BTN_W,
			tooltip = tr("tip_delete"),
			onClick = function()
				deleteTask(uuid)
			end,
		})
	)
	return ui.row({
		-- edit/priority state flips the row's controls; key it to recreate cleanly
		key = "row-" .. uuid .. (editing and "-edit" or "-view") .. "-" .. item.priority,
		gap = 8,
		align = "center",
	}, children)
end

local function legendEntry(priority)
	return ui.row({ gap = 8, align = "center" }, {
		ui.box({ width = 16, height = 16, radius = 4, fill = COLORS[priority] }),
		ui.label({ text = tr("prio_" .. PRIORITY_KEYS[priority]), fontSize = 13, color = "on_surface_variant" }),
	})
end

local function legendBlock()
	return ui.column({ gap = 8, align = "stretch" }, {
		ui.separator({}),
		ui.row({ gap = 20, align = "center", justify = "center" }, {
			legendEntry("H"),
			legendEntry("M"),
			legendEntry("L"),
			legendEntry(""),
		}),
	})
end

render = function()
	local header = ui.row({ align = "center", gap = 8 }, {
		ui.label({ text = tr("title"), fontSize = 22, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({
			key = "header-add",
			glyph = "plus",
			variant = "primary",
			width = 36,
			height = 36,
			tooltip = tr("tip_add"),
			onClick = "onAdd",
		}),
		ui.button({
			key = "header-settings",
			glyph = "settings",
			variant = "ghost",
			width = 36,
			height = 36,
			tooltip = tr("tip_settings"),
			onClick = "onOpenSettings",
		}),
		ui.button({
			key = "header-close",
			glyph = "close",
			variant = "ghost",
			width = 36,
			height = 36,
			tooltip = tr("tip_close"),
			onClick = "onClosePanel",
		}),
	})

	local body
	if not loaded then
		body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
			ui.label({ text = tr("loading"), color = "on_surface_variant" }),
		})
	elseif loadError ~= nil then
		body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
			ui.label({ text = loadError, color = "error" }),
		})
	else
		local rows = {}
		if editingId == NEW_ID then
			table.insert(rows, newTaskRow())
		end
		for _, item in ipairs(items) do
			table.insert(rows, taskRow(item))
		end
		if #rows == 0 then
			body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
				ui.label({ text = tr("empty"), color = "on_surface_variant" }),
			})
		else
			-- Legend lives directly under the last row (not pinned to the panel
			-- bottom), so there is no dead band between tasks and legend.
			table.insert(rows, legendBlock())
			body = ui.scroll({ flexGrow = 1, gap = 12 }, rows)
		end
	end

	if panelOpen then
		panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, { header, body }))
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function startLoad()
	editingId = nil
	editingText = ""
	if not taskwarrior.available() then
		loaded = true
		loadError = noctalia.tr("task_missing")
		if lastNotifiedError ~= loadError then
			lastNotifiedError = loadError
			noctalia.notifyError(tr("title"), loadError)
		end
	else
		loaded = false
		loadError = nil
		refresh()
	end
end

function onOpen(_context)
	panelOpen = true
	noctalia.state.set("todo_open", true)
	startLoad()
	render()
end

function onClose()
	-- No draft state: an uncommitted inline edit is discarded.
	panelOpen = false
	editingId = nil
	editingText = ""
	noctalia.state.set("todo_open", false)
end

function onConfigChanged()
	startLoad()
	render()
end

function onAdd()
	if editingId == NEW_ID then
		return
	end
	editingId = NEW_ID
	editingText = ""
	render()
end

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own).
function onOpenSettings()
	noctalia.openSettings()
end

function onClosePanel()
	panel.close()
end
