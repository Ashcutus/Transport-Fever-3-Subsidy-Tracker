local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local util = ug_require "::/scripts/util.tl" as Util
local toolUtil = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local gameBar = ug_require "::/gui/game_bar/game_bar.tl" as GameBar
local engineReactUtil = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil

local WINDOW_ID = "tf3-subsidy-manager.window"
local DEBUG_LOGGING = false

local SUBVENTION_SCRIPT = "::/game_mechanics/subventions/subventions.gs"
local MOD_ID = "tf3_subsidy_manager"
local OFFERS_OPENED_EVENT = "tf3SubsidyManagerOffersOpened"

local record OfferBadgeState
	initialized : boolean
	offers : {string : boolean}
	pending : boolean
	dirty : boolean
end

local function offerIdentity(record : ISubvention) : string
	if type(record) ~= "table" or type(record.id) ~= "string" or record.id == "" then return nil end
	if type(record.uid) ~= "number" or record.uid < 0 or record.uid >= math.huge or record.uid ~= math.floor(record.uid) then return nil end
	if type(record.spawnTime) ~= "number" or not (math.abs(record.spawnTime) < math.huge) then return nil end
	return string.format("%d:%s|%.17g|%.17g", #record.id, record.id, record.uid, record.spawnTime)
end

local function queryOfferIdentities() : {string : boolean}
	local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SUBVENTION_SCRIPT)
	if not entity or not api.engine.entityExists(entity) then return nil end
	local component = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT) as Engine.Component.GameScript<SubventionState>
	if not component or type(component.state) ~= "table" or type(component.state.proposedSubventions) ~= "table" then return nil end
	local offers : {string : boolean} = {}
	-- Read only identity fields; never format cards or copy other subsidy collections.
	for _index, record in ipairs(component.state.proposedSubventions) do
		local key = offerIdentity(record)
		if key then offers[key] = true end
	end
	return offers
end

local function loadOfferBadge() : OfferBadgeState
	local initial : OfferBadgeState = { initialized = false, offers = {}, pending = false, dirty = false }
	local ok, saved = pcall(function() : any return api.gui.game.getGuiSaveData(MOD_ID) end)
	if not ok or type(saved) ~= "table" then return initial end
	local badge = (saved as table).offerBadge as table
	if type(badge) ~= "table" or badge.version ~= 1 or type(badge.pending) ~= "boolean" or type(badge.offers) ~= "table" then return initial end
	local offers : {string : boolean} = {}
	for key, value in pairs(badge.offers as {any : any}) do
		if type(key) ~= "string" or value ~= true then return initial end
		offers[key as string] = true
	end
	return { initialized = true, offers = offers, pending = badge.pending as boolean, dirty = false }
end

local function saveOfferBadge(badge : OfferBadgeState) : boolean
	-- Keep other mod-owned GUI fields intact. Persistence failure must not break UI.
	local ok = pcall(function()
		local saved = api.gui.game.getGuiSaveData(MOD_ID)
		local data : {any : any} = {}
		if type(saved) == "table" then
			for key, value in pairs(saved) do data[key] = value end
		end
		local offers : {string : boolean} = {}
		for key, value in pairs(badge.offers) do offers[key] = value end
		data.offerBadge = { version = 1, offers = offers, pending = badge.pending }
		api.gui.game.setGuiSaveData(MOD_ID, data)
	end)
	return ok
end

local OfferBadgeIcon = react.RegisterWrapperRecipe("TF3SubsidyManagerOfferBadgeIcon", builtin.Component, function(_params : Builtin.ComponentParam) : TreeNodeId
	local tracked : ReactRefT<OfferBadgeState> = react.useRefLazy(loadOfferBadge)
	local pending : ReactStateT<boolean> = engineReactUtil.useStepStateTimer(function() : boolean
		local badge = tracked:get()
		local ok, result = pcall(queryOfferIdentities)
		if not ok or not result then return badge.pending end
		local offers = result as {string : boolean}
		local changed = not badge.initialized
		for key, _value in pairs(offers) do
			if not badge.offers[key] then
				if badge.initialized then badge.pending = true end
				changed = true
			end
		end
		for key, _value in pairs(badge.offers) do if not offers[key] then changed = true end end
		badge.initialized, badge.offers = true, offers
		if changed or badge.dirty then badge.dirty = not saveOfferBadge(badge) end
		return badge.pending
	end, 5)
	react.onEvent(OFFERS_OPENED_EVENT, function(_name : string, data : any)
		if type(data) ~= "table" then return end
		local offers : {string : boolean} = {}
		for key, value in pairs(data as {any : any}) do
			if type(key) ~= "string" or value ~= true then return end
			offers[key as string] = true
		end
		local badge = tracked:get()
		badge.initialized, badge.offers, badge.pending = true, offers, false
		badge.dirty = not saveOfferBadge(badge)
		pending:set(false)
	end)
	local children : {TreeNodeId} = {
		builtin.FloatingLayoutChild { item = builtin.ImageView { path = "tf3_subsidy_manager::/plugins/subsidy_manager/icons/contract_26.tga" } },
	}
	if pending:old() then
		children[#children + 1] = builtin.FloatingLayoutChild {
			-- Shipped builtin.lua uses this enum; the installed Teal field still says boolean.
			h = 1.3, v = -0.3, overflowMode = builtin.type.FloatingLayoutOverflowMode.Overflow as boolean,
			item = builtin.Component {
				meta = { class = "tf3-subsidy-offer-badge" }, mouseTransparent = true,
				layout = builtin.BoxLayout { children = { builtin.TextView { text = "●" } } },
			},
		}
	end
	return builtin.Component {
		meta = { class = "tf3-subsidy-toolbar-icon" }, mouseTransparent = true,
		layout = builtin.FloatingLayout { children = children },
	}
end)

local record Entry
	name : string
	required : number
	delivered : number
	recordCopy : ISubvention
	card : SubventionCardData
	resourceName : string
	outcome : string
end

local record Snapshot
	readError : boolean
	stateFound : boolean
	scriptName : string
	offered : {Entry}
	active : {Entry}
	completed : {Entry}
	failed : {Entry}
end

local function emptySnapshot() : Snapshot
	return {
		readError = false,
		stateFound = false,
		scriptName = "",
		offered = {},
		active = {},
		completed = {},
		failed = {},
	}
end

-- The shipped getCardData dispatch is also used by subventions_gui.tl.
-- Copy records first: some shipped helpers migrate legacy fields in-place.
local function copyTable(value : any) : any
	if type(value) ~= "table" then return value end
	local result : {any : any} = {}
	for key, child in pairs(value as {any : any}) do result[key] = copyTable(child) end
	return result
end

local function getCard(recordCopy : ISubvention, offered : boolean) : SubventionCardData
	if type(recordCopy.id) ~= "string" then return nil end
	local id = api.res.genericRep.find(recordCopy.id)
	if id < 0 then return nil end
	local resource = api.res.genericRep.get(id)
	local desc = resource.data as SubventionDesc
	if not desc or type(desc.scriptFile) ~= "string" then return nil end
	local getCardData = util.useFn(desc.scriptFile .. ".getCardData") as function(ISubvention, boolean) : SubventionCardData
	if not getCardData then return nil end
	local formatted = getCardData(recordCopy, false)
	if type(formatted) ~= "table" then return nil end
	local card = copyTable(formatted) as SubventionCardData
	if offered and card then
		-- Vanilla card.deadline is the task duration, not the offer timeout.
		-- Use defaultTimeout's proposed timestamp contract and the native formatter.
		card.deadline = nil
		card.expireDuration = nil
		local duration = recordCopy.data.expireDurationProposed
		local spawnTime = recordCopy.spawnTime
		if type(duration) == "number" and duration >= 0 and duration < math.huge and type(spawnTime) == "number" and math.abs(spawnTime) < math.huge then
			local world = api.engine.util.getWorld()
			local time = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
			local speed = api.engine.getComponent(world, api.type.ComponentType.GAME_SPEED) as Engine.Component.GameSpeed
			if time and speed then
				local remaining = duration - (time.gameTime - spawnTime)
				card.expireDuration = {
					value = duration > 0 and remaining / duration or 0,
					name = util.formatDurationWithCurrentCalenderSpeed(math.floor(remaining), speed.millisPerDay),
				}
			end
		end
	end
	return card
end

-- Names come from the same cargo repository as shipped subsidy icon helpers.
local function resourceName(recordCopy : ISubvention) : string
	local data = recordCopy.data as table
	local names : {string} = {}
	local function append(value : any)
		local id : CargoTypeId = nil
		if type(value) == "string" then id = api.res.cargoTypeRep.find(value as string)
		elseif type(value) == "number" then
			local numeric = value as number
			if numeric >= 0 and numeric < math.huge and numeric == math.floor(numeric) then id = numeric as CargoTypeId end
		end
		if id and id >= 0 then
			local cargo = api.res.cargoTypeRep.get(id)
			if cargo and type(cargo.name) == "string" then names[#names + 1] = _(cargo.name) end
		end
	end
	append(data.cargoType)
	if type(data.cargoTypes) == "table" then
		for _index, value in ipairs(data.cargoTypes as {any}) do append(value) end
	end
	return table.concat(names, ", ")
end

-- Keep detached records and card data: engine-owned tables never become React state.
local function copyEntries(items : {ISubvention}, offered? : boolean, outcome? : string) : {Entry}
	local entries : {Entry} = {}
	for _index, item in ipairs(items) do
		local data = type(item) == "table" and item.data or nil
		local entry : Entry = { name = _("tf3_subsidy_manager_unknown_name"), outcome = outcome or "" }
		if type(data) == "table" then
			if type(data.name) == "string" and data.name ~= "" then entry.name = _(data.name) end
			local required = data.toDeliver
			local delivered = data.delivered
			if type(required) == "number" and required >= 0 and required < math.huge then entry.required = required end
			if type(delivered) == "number" and delivered >= 0 and delivered < math.huge then entry.delivered = delivered end
		end
		if type(item) == "table" and type(data) == "table" then
			entry.recordCopy = copyTable(item) as ISubvention
			local named, name = pcall(resourceName, entry.recordCopy)
			if named then entry.resourceName = name as string end
			local ok, card = pcall(getCard, entry.recordCopy, offered or false)
			if ok then entry.card = card as SubventionCardData
			else log.warning("[tf3_subsidy_manager] Unable to format subsidy: " .. tostring(card)) end
		end
		entries[#entries + 1] = entry
	end
	return entries
end

local function querySnapshot() : Snapshot
	local snapshot = emptySnapshot()
	-- GAME_SCRIPT is readable by entity, but TF3 cannot enumerate this component.
	local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SUBVENTION_SCRIPT)
	if not entity or not api.engine.entityExists(entity) then return snapshot end
	local component = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT) as Engine.Component.GameScript<SubventionState>
	if not component then return snapshot end
	local state = component.state
	if type(state) ~= "table" then return snapshot end
	if type(state.proposedSubventions) ~= "table" or type(state.activeSubventions) ~= "table" then return snapshot end
	if state.completedSubventions ~= nil and type(state.completedSubventions) ~= "table" then return snapshot end
	if state.failedSubventions ~= nil and type(state.failedSubventions) ~= "table" then return snapshot end

	snapshot.stateFound = true
	snapshot.scriptName = SUBVENTION_SCRIPT
	snapshot.offered = copyEntries(state.proposedSubventions, true)
	snapshot.active = copyEntries(state.activeSubventions)
	snapshot.completed = copyEntries(state.completedSubventions or {}, false, "successful")
	snapshot.failed = copyEntries(state.failedSubventions or {}, false, "failed")
	return snapshot
end

local function readSnapshot() : Snapshot
	local ok, result = pcall(querySnapshot)
	if not ok then
		log.warning("[tf3_subsidy_manager] Unable to read subsidy state: " .. tostring(result))
		local snapshot = emptySnapshot()
		snapshot.readError = true
		return snapshot
	end
	local snapshot = result as Snapshot
	if DEBUG_LOGGING and snapshot.stateFound then
		log.warning("[tf3_subsidy_manager] Read subsidy state from " .. snapshot.scriptName)
	end
	return snapshot
end

local function canOpenDetail(item : Entry) : boolean
	if not item or not item.card or not item.recordCopy then return false end
	local uid = item.recordCopy.uid
	return type(uid) == "number" and uid >= 0 and uid < math.huge and uid == math.floor(uid)
end

local function openDetail(item : Entry)
	if not canOpenDetail(item) then return end
	-- Preserve the UAT-confirmed vanilla notification dispatch and detached record.
	react.fireEvent(nil, "selectViewKey", {
		nonEntity = "subsidy_" .. item.recordCopy.uid,
		stack = false,
		extraParam = copyTable(item.recordCopy),
	})
end

local function countText(item : Entry) : string
	if item.required ~= nil and item.delivered ~= nil then
		local value = item.required > 0 and item.delivered / item.required or 0
		if value < math.huge then return string.format("%g / %g", item.delivered, item.required) end
	end
	return _("tf3_subsidy_manager_unknown_progress")
end

local function isTransportWorkers(item : Entry) : boolean
	return item.recordCopy ~= nil and item.recordCopy.id == "::/game_mechanics/subventions/deliver_workers/deliver_workers.res"
end

local function columnText(item : Entry, key : string) : string
	local card = item.card
	if key == "type" then return item.name end
	if key == "status" then return _(item.outcome == "failed" and "tf3_subsidy_manager_failed" or "tf3_subsidy_manager_completed") end
	if key == "resource" then return item.resourceName and item.resourceName ~= "" and item.resourceName or "—" end
	if key == "requirement" then
		local required = card and card.cargoToDeliver or item.required
		return type(required) == "number" and required >= 0 and required < math.huge and tostring(required) or "—"
	end
	if key == "progress" or key == "result" then
		if key == "progress" and card and card.progress and type(card.progress.value) == "number" and card.progress.value >= 0 and card.progress.value < math.huge and type(card.progress.text) == "string" then
			if isTransportWorkers(item) then
				-- Native value is normalized workforce progress toward the industry boost, not a worker count.
				if card.progress.value > 1 then return countText(item) end
				return string.format("%g%% %s", card.progress.value * 100, card.progress.text)
			end
			return card.progress.text
		end
		return countText(item)
	end
	if key == "destination" and card and card.location then
		local from = card.location.from and card.location.from[2] or ""
		local to = card.location.to and card.location.to[2] or ""
		return from ~= "" and to ~= "" and from .. " → " .. to or (to ~= "" and to or from)
	end
	if key == "reward" and card then
		local texts : {string} = {}
		local effects = item.outcome == "failed" and card.failure or card.complete
		for _index, effect in ipairs(effects or {}) do
			if type(effect.text) == "string" then texts[#texts + 1] = effect.text end
		end
		return #texts > 0 and table.concat(texts, " + ") or "—"
	end
	if key == "time" and card and card.expireDuration then return card.expireDuration.name or "—" end
	return "—"
end

local record TableRows
	entries : {Entry}
end

-- Native statistics tables use ColumnDesc cell recipes returning layouts.
-- Each cell is clickable, so selection anywhere in a row delegates to native detail.
local function makeCell(key : string) : Recipe<Builtin.TableCellParam>
	return react.RegisterRecipe("TF3SubsidyManagerCell_" .. key, function(params : Builtin.TableCellParam) : TreeNodeId
		local rows = params.userParam as TableRows
		local item = rows.entries[params.rowKey]
		local text = item and columnText(item, key) or "—"
		local parts : {TreeNodeId} = {}
		if item and key == "resource" and item.card then
			for _index, path in ipairs(item.card.cargoIcons or {}) do
				parts[#parts + 1] = builtin.ImageView { path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
			end
		elseif item and key == "status" then
			parts[#parts + 1] = builtin.ImageView {
				path = item.outcome == "failed" and "::/game_mechanics/subventions/icons/mark_failed.tga" or "::/game_mechanics/subventions/icons/mark_complete.tga",
				scaling = builtin.type.ImageViewScaling.AutoFit,
			}
		end
		if item and key == "progress" and item.card and item.card.progress and type(item.card.progress.value) == "number" and item.card.progress.value >= 0 and item.card.progress.value < math.huge and type(item.card.progress.text) == "string" and (not isTransportWorkers(item) or item.card.progress.value <= 1) then
			-- Some native tasks report a qualitative label (e.g. Workers), not counts.
			parts[#parts + 1] = builtin.ProgressBar { value = math.min(1, item.card.progress.value), label = text }
		else
			parts[#parts + 1] = builtin.TextView { text = text, tooltipWhenClipped = text }
		end
		return builtin.BoxLayout {
			children = { builtin.Button {
				meta = { class = "tf3-subsidy-cell", tooltip = text, enabled = canOpenDetail(item) },
				content = builtin.Component { layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = parts } },
				onClick = function() if item then openDetail(item) end end,
			} },
		}
	end)
end

local cellRecipes : {string : Recipe<Builtin.TableCellParam>} = {}
for _index, key in ipairs({"type", "resource", "destination", "requirement", "progress", "result", "reward", "time", "status"}) do cellRecipes[key] = makeCell(key) end

local function renderTable(items : {Entry}, section : integer, generation : integer, emptyText : string) : TreeNodeId
	if #items == 0 then return builtin.TextView { text = emptyText } end
	local keys = section == 3 and {"status", "type", "resource", "destination", "result", "reward"} or
		{"type", "resource", "destination", section == 1 and "progress" or "requirement", "reward", "time"}
	local columns : {TreeNodeId} = {}
	for _index, key in ipairs(keys) do
		local label = key == "reward" and section == 3 and "reward_consequence" or key == "time" and section == 1 and "deadline" or key
		columns[#columns + 1] = builtin.ColumnDesc {
			name = _("tf3_subsidy_manager_column_" .. label),
			recipe = cellRecipes[key],
			weight = key == "reward" and 2.5 or key == "destination" and 1.5 or 1,
			getCompareValue = function(rowKey : integer) : string return columnText(items[rowKey], key) end,
		}
	end
	local rowKeys : {integer} = {}
	for index = 1, #items do rowKeys[index] = index end
	return builtin.DataTable {
		-- TF3 only sends userParam to new cells. Recreate on tab/Refresh, not on a timer.
		meta = { class = "tf3-subsidy-table", localKey = tostring(section) .. ":" .. tostring(generation) },
		columns = columns,
		rowKeys = rowKeys,
		userParam = { entries = items },
		disableSortKey = true,
		keyboardNavigation = false,
		scrollPolicyHorizontal = builtin.type.ScrollBarPolicy.AlwaysOff,
		scrollPolicyVertical = builtin.type.ScrollBarPolicy.AsNeededButAlwaysReserveSpace,
	}
end

local record WindowParams is ToolReactUtil.IToolWindowParam<ToolReactUtil.IToolParam>
end

local SubsidyManagerWindow = react.RegisterWrapperRecipe("TF3SubsidyManagerWindow", builtin.Window, function(params : WindowParams) : TreeNodeId
	local snapshot : ReactStateT<Snapshot> = react.useStateLazy(readSnapshot)
	local selectedTab : ReactStateT<integer> = react.useState(1)

	local generation : ReactStateT<integer> = react.useState(0)
	local function refresh()
		snapshot:set(readSnapshot())
		generation:set(generation:old() + 1)
	end
	local current = snapshot:old()
	-- Acknowledge only after successful mounting, never merely on the toolbar click.
	react.onMount(function()
		if not current.stateFound or current.readError then return end
		local offers : {string : boolean} = {}
		for _index, item in ipairs(current.offered) do
			local key = offerIdentity(item.recordCopy)
			if key then offers[key] = true end
		end
		react.fireEvent(nil, OFFERS_OPENED_EVENT, offers)
	end)
	local section = selectedTab:old()
	local history : {Entry} = {}
	for _index, item in ipairs(current.completed) do history[#history + 1] = item end
	for _index, item in ipairs(current.failed) do history[#history + 1] = item end
	local content : TreeNodeId
	if current.readError then content = builtin.TextView { text = _("tf3_subsidy_manager_read_error") }
	elseif not current.stateFound then content = builtin.TextView { text = _("tf3_subsidy_manager_unavailable") }
	elseif section == 1 then content = renderTable(current.active, section, generation:old(), _("tf3_subsidy_manager_no_active"))
	elseif section == 2 then content = renderTable(current.offered, section, generation:old(), _("tf3_subsidy_manager_no_offers"))
	else content = renderTable(history, section, generation:old(), _("tf3_subsidy_manager_no_history")) end
	local buttons : {Builtin.ToggleButtonGroupChildParam} = {}
	local counts = {#current.active, #current.offered, #history}
	for index, label in ipairs({"active", "offered", "history"}) do
		local count = current.stateFound and (" (" .. counts[index] .. ")") or ""
		buttons[index] = { content = builtin.TextView { text = _("tf3_subsidy_manager_" .. label) .. count } }
	end
	local controls = builtin.BoxLayout {
		meta = { class = "tf3-subsidy-controls" },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.ToggleButtonGroup {
				buttons = buttons,
				selected = section,
				deselectAllowed = false,
				onValueChange = function(index : integer) if index >= 1 and index <= 3 then selectedTab:set(index) end end,
			},
			builtin.Button {
				meta = { class = "secondary", tooltip = _("tf3_subsidy_manager_refresh_tooltip") },
				content = builtin.TextView { text = _("tf3_subsidy_manager_refresh") },
				onClick = refresh,
			},
		},
	}

	-- Choose once per snapshot, not per selected tab; keep populated revision 9 sizing.
	local hasRecords = #current.active + #current.offered + #history > 0
	return builtin.Window {
		meta = { class = hasRecords and "tf3-subsidy-populated" or "tf3-subsidy-empty" },
		id = WINDOW_ID,
		tool = "TF3SubsidyManager",
		title = _("tf3_subsidy_manager_title"),
		onClose = params.onClose,
		closable = true,
		movable = true,
		pinnable = true,
		initialX = 0.28,
		initialY = 0.2,
		autoFocusOnBecomingVisible = false,
		autoVisibilityOnFocusChange = false,
		content = builtin.BoxLayout {
			meta = { class = "tf3-subsidy-content" },
			orientation = builtin.type.Orientation.Vertical,
			children = { controls, builtin.ScrollArea {
				meta = { class = "tf3-subsidy-data-region" },
				horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
				verticalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
				-- The native DataTable owns its scrolling/header; keep the component boundary.
				-- ScrollArea requires a component, even when the selected tab is a layout.
				content = builtin.Component {
					layout = builtin.BoxLayout {
						orientation = builtin.type.Orientation.Vertical,
						children = { content },
					},
				},
			} },
		},
	}
end)

-- Native tools remove their windows on pop and shelve them under the pause menu.
local ManagerTool = toolUtil.registerToolWithWindow("TF3SubsidyManager", WINDOW_ID, SubsidyManagerWindow)

-- No tray extension is shipped. The bootstrap callback wraps only creation of the
-- Industry ToolButton; all native calls/refs are forwarded unchanged. This is an
-- undocumented module hook, deliberately guarded and installed only once.
local record ToolbarParams
	meta : Meta
	toolStack : ReactRefWrapApiT<Builtin.ToolStackParam, Builtin.ToolStackAPI>
end

local installed = false
local function installToolbar(_replacementApi : ReactReplacementApi)
	if installed then return end
	installed = true
	local originalToolButton = builtin.ToolButton
	local currentGameCtx : GameContext = nil
	local originalGameBar = gameBar.GameBar
	-- CallOriginalRecipe creates a GameBar recipe node, not its layout.
	-- Register the delegation as a wrapper so the native transform can unwrap it.
	local WithContext = react.RegisterWrapperRecipe("TF3SubsidyManagerGameBar", originalGameBar, function(params : GameBar.GameBarParam) : TreeNodeId
		currentGameCtx = params.gameCtx
		return react.CallOriginalRecipe(originalGameBar, params)
	end)
	_replacementApi.ReplaceRecipe(originalGameBar, WithContext)

	-- Recipe calls support both (params) and (ref, params).
	local builtinTable = builtin as table
	builtinTable.ToolButton = function(... : any) : TreeNodeId
		local args : {any} = {...}
		local params = args[#args] as ToolbarParams
		local originalCall = originalToolButton as function(... : any) : TreeNodeId
		local node = originalCall(...)
		if type(params) ~= "table" or not params.meta or params.meta.id ~= "menu.industry-statistics.button" or not currentGameCtx then return node end
		local gameCtx = currentGameCtx
		return builtin.BoxLayout {
			meta = { class = "tf3-subsidy-tray-pair" },
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				node,
				originalToolButton {
					meta = {
						id = "tf3-subsidy-manager.button",
						class = "tf3-subsidy-toolbar",
						tooltip = _("tf3_subsidy_manager_button_tooltip"),
						disableFocusableRecursive = true,
					},
					toolDefinition = ManagerTool,
					toolStack = params.toolStack,
					content = OfferBadgeIcon {},
					showFn = function()
						gameCtx.toolStack:get():getApi().push(ManagerTool, nil, { gameCtx = gameCtx }, true)
					end,
					hideFn = function()
						gameCtx.toolStack:get():getApi().pop(ManagerTool, nil)
					end,
				},
			},
		}
	end
end

return { installToolbar = installToolbar }
