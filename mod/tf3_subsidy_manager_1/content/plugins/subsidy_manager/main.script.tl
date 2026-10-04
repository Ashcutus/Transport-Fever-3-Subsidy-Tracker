local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local util = ug_require "::/scripts/util.tl" as Util
local langUtil = ug_require "::/scripts/lang_util.tl" as LangUtil
local toolUtil = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local gameBar = ug_require "::/gui/game_bar/game_bar.tl" as GameBar

local WINDOW_ID = "copilot-subsidy-manager.window"
local DEBUG_LOGGING = false

local SUBVENTION_SCRIPT = "::/game_mechanics/subventions/subventions.gs"

local record Entry
	name : string
	required : number
	delivered : number
	recordCopy : ISubvention
	card : SubventionCardData
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
	local card = copyTable(getCardData(recordCopy, false)) as SubventionCardData
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

-- Keep detached records and card data: engine-owned tables never become React state.
local function copyEntries(items : {ISubvention}, offered? : boolean) : {Entry}
	local entries : {Entry} = {}
	for _index, item in ipairs(items) do
		local data = type(item) == "table" and item.data or nil
		local entry : Entry = { name = _("copilot_subsidy_manager_unknown_name") }
		if type(data) == "table" then
			if type(data.name) == "string" and data.name ~= "" then entry.name = _(data.name) end
			local required = data.toDeliver
			local delivered = data.delivered
			if type(required) == "number" and required >= 0 and required < math.huge then entry.required = required end
			if type(delivered) == "number" and delivered >= 0 and delivered < math.huge then entry.delivered = delivered end
		end
		if type(item) == "table" and type(data) == "table" then
			entry.recordCopy = copyTable(item) as ISubvention
			local ok, card = pcall(getCard, entry.recordCopy, offered or false)
			if ok then entry.card = card as SubventionCardData
			else log.warning("[copilot_subsidy_manager] Unable to format subsidy: " .. tostring(card)) end
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
	snapshot.completed = copyEntries(state.completedSubventions or {})
	snapshot.failed = copyEntries(state.failedSubventions or {})
	return snapshot
end

local function readSnapshot() : Snapshot
	local ok, result = pcall(querySnapshot)
	if not ok then
		log.warning("[copilot_subsidy_manager] Unable to read subsidy state: " .. tostring(result))
		local snapshot = emptySnapshot()
		snapshot.readError = true
		return snapshot
	end
	local snapshot = result as Snapshot
	if DEBUG_LOGGING and snapshot.stateFound then
		log.warning("[copilot_subsidy_manager] Read subsidy state from " .. snapshot.scriptName)
	end
	return snapshot
end

local function renderEntry(item : Entry, outcome : string, active? : boolean) : TreeNodeId
	local details = _("copilot_subsidy_manager_unknown_progress")
	if item.required ~= nil and item.delivered ~= nil then
		local progress = item.required > 0 and math.floor(item.delivered / item.required * 100) or 0
		if progress < math.huge then
			details = string.format(_("copilot_subsidy_manager_progress"), item.delivered, item.required, progress)
		end
	end
	local prefix = outcome ~= "" and outcome .. "  " or ""
	local children : {TreeNodeId} = { builtin.TextView { text = prefix .. item.name } }
	local card = item.card
	if card then
		local task : {TreeNodeId} = {}
		for _index, path in ipairs(card.cargoIcons or {}) do
			task[#task + 1] = builtin.ImageView { path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
		end
		if card.cargoToDeliver then task[#task + 1] = builtin.TextView { text = langUtil.formatInt(card.cargoToDeliver) } end
		if card.location then
			if card.location.from then task[#task + 1] = builtin.TextView { text = card.location.from[2] } end
			if card.location.to then task[#task + 1] = builtin.TextView { text = "→ " .. card.location.to[2] } end
		end
		children[#children + 1] = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = task }
		local effects = outcome == _("copilot_subsidy_manager_failed") and card.failure or card.complete
		for _index, effect in ipairs(effects or {}) do
			children[#children + 1] = builtin.TextView { text = effect.text }
		end
		if outcome == "" and card.expireDuration then
			children[#children + 1] = builtin.TextView { text = card.expireDuration.name }
		elseif outcome == "" and card.deadline then
			children[#children + 1] = builtin.TextView { text = card.deadline.name }
		end
	end
	if active and item.required and item.delivered then
		local value = item.required > 0 and item.delivered / item.required or 0
		if value < math.huge then
			children[#children + 1] = builtin.ProgressBar { value = math.min(1, value), label = details }
		else children[#children + 1] = builtin.TextView { text = details } end
	elseif not card then children[#children + 1] = builtin.TextView { text = details } end
	return builtin.Button {
		meta = { enabled = card ~= nil and item.recordCopy ~= nil and type(item.recordCopy.uid) == "number" },
		content = builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = children },
		onClick = function()
			if not card or not item.recordCopy or type(item.recordCopy.uid) ~= "number" then return end
			-- Same event/key/record contract as the game's subsidy notifications.
			-- The native detail window owns its normal acceptance action.
			react.fireEvent(nil, "selectViewKey", {
				nonEntity = "subsidy_" .. item.recordCopy.uid,
				stack = false,
				extraParam = copyTable(item.recordCopy),
			})
		end,
	}
end

local function renderList(items : {Entry}, emptyText : string, outcome : string, active? : boolean) : TreeNodeId
	if #items == 0 then
		return builtin.TextView { text = emptyText }
	end
	local children : {TreeNodeId} = {}
	for _index, item in ipairs(items) do
		children[#children + 1] = renderEntry(item, outcome, active)
	end
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end

local record WindowParams is ToolReactUtil.IToolWindowParam<ToolReactUtil.IToolParam>
end

local SubsidyManagerWindow = react.RegisterWrapperRecipe("CopilotSubsidyManagerWindow", builtin.Window, function(params : WindowParams) : TreeNodeId
	local snapshot : ReactStateT<Snapshot> = react.useStateLazy(readSnapshot)
	local selectedTab : ReactStateT<integer> = react.useState(1)

	local function refresh()
		snapshot:set(readSnapshot())
	end

	local function tabButton(label : string, index : integer) : TreeNodeId
		return builtin.Button {
			meta = { tooltip = label },
			content = builtin.TextView { text = label },
			onClick = function() selectedTab:set(index) end,
		}
	end

	local content : TreeNodeId
	local current = snapshot:old()
	if current.readError then
		content = builtin.TextView { text = _("copilot_subsidy_manager_read_error") }
	elseif not current.stateFound then
		content = builtin.TextView { text = _("copilot_subsidy_manager_unavailable") }
	elseif selectedTab:old() == 1 then
		content = renderList(current.active, _("copilot_subsidy_manager_no_active"), "", true)
	elseif selectedTab:old() == 2 then
		content = renderList(current.offered, _("copilot_subsidy_manager_no_offers"), "")
	else
		local history : {TreeNodeId} = {}
		if #current.completed == 0 and #current.failed == 0 then
			history[1] = builtin.TextView { text = _("copilot_subsidy_manager_no_history") }
		else
			for _index, item in ipairs(current.completed) do
				history[#history + 1] = renderEntry(item, _("copilot_subsidy_manager_completed"))
			end
			for _index, item in ipairs(current.failed) do
				history[#history + 1] = renderEntry(item, _("copilot_subsidy_manager_failed"))
			end
		end
		content = builtin.BoxLayout {
			orientation = builtin.type.Orientation.Vertical,
			children = history,
		}
	end

	local controls = builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			tabButton(_("copilot_subsidy_manager_active"), 1),
			tabButton(_("copilot_subsidy_manager_offered"), 2),
			tabButton(_("copilot_subsidy_manager_history"), 3),
			builtin.Button {
				meta = { tooltip = _("copilot_subsidy_manager_refresh_tooltip") },
				content = builtin.TextView { text = _("copilot_subsidy_manager_refresh") },
				onClick = refresh,
			},
		},
	}

	return builtin.Window {
		id = WINDOW_ID,
		tool = "CopilotSubsidyManager",
		title = _("copilot_subsidy_manager_title"),
		onClose = params.onClose,
		closable = true,
		movable = true,
		pinnable = true,
		initialX = 0.28,
		initialY = 0.2,
		autoFocusOnBecomingVisible = false,
		autoVisibilityOnFocusChange = false,
		content = builtin.BoxLayout {
			orientation = builtin.type.Orientation.Vertical,
			children = { controls, builtin.ScrollArea {
				horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
				verticalPolicy = builtin.type.ScrollBarPolicy.AsNeededButAlwaysReserveSpace,
				content = content,
			} },
		},
	}
end)

-- Native tools remove their windows on pop and shelve them under the pause menu.
local ManagerTool = toolUtil.registerToolWithWindow("CopilotSubsidyManager", WINDOW_ID, SubsidyManagerWindow)

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
	local WithContext = react.RegisterWrapperRecipe("CopilotSubsidyManagerGameBar", originalGameBar, function(params : GameBar.GameBarParam) : TreeNodeId
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
			meta = { class = "copilot-subsidy-tray-pair" },
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				node,
				originalToolButton {
					meta = {
						id = "copilot-subsidy-manager.button",
						tooltip = _("copilot_subsidy_manager_button_tooltip"),
						disableFocusableRecursive = true,
					},
					toolDefinition = ManagerTool,
					toolStack = params.toolStack,
					content = builtin.ImageView { path = "copilot_subsidy_manager::/plugins/subsidy_manager/icons/contract_26.tga" },
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
