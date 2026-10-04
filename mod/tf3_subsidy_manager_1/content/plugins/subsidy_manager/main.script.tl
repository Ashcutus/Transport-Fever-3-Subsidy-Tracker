local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local modArea = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local entryPoint = ug_require "::/gui/main/mod_entry_point.tl" as ModEntryPoint

local WINDOW_ID = "copilot-subsidy-manager.window"
local DEBUG_LOGGING = false

local SUBVENTION_SCRIPT = "::/game_mechanics/subventions/subventions.gs"

local record Entry
	name : string
	required : number
	delivered : number
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

-- Copy only display fields: engine-owned tables must not become React state.
local function copyEntries(items : {ISubvention}) : {Entry}
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
	snapshot.offered = copyEntries(state.proposedSubventions)
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

local function renderEntry(item : Entry, outcome : string) : TreeNodeId
	local details = _("copilot_subsidy_manager_unknown_progress")
	if item.required ~= nil and item.delivered ~= nil then
		local progress = item.required > 0 and math.floor(item.delivered / item.required * 100) or 0
		if progress < math.huge then
			details = string.format(_("copilot_subsidy_manager_progress"), item.delivered, item.required, progress)
		end
	end
	local prefix = outcome ~= "" and outcome .. "  " or ""
	return builtin.TextView { text = prefix .. item.name .. "\n" .. details }
end

local function renderList(items : {Entry}, emptyText : string, outcome : string) : TreeNodeId
	if #items == 0 then
		return builtin.TextView { text = emptyText }
	end
	local children : {TreeNodeId} = {}
	for _index, item in ipairs(items) do
		children[#children + 1] = renderEntry(item, outcome)
	end
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end

local record WindowParams
end

local SubsidyManagerWindow = react.RegisterWrapperRecipe("CopilotSubsidyManagerWindow", builtin.Window, function(_params : WindowParams) : TreeNodeId
	local snapshot : ReactStateT<Snapshot> = react.useStateLazy(readSnapshot)
	local selectedTab : ReactStateT<integer> = react.useState(1)
	react.onMount(function()
		react.enqueueJoin(function()
			api.gui.byId.setVisible(WINDOW_ID, false)
		end, "CopilotSubsidyManager:hideMountedWindow")
	end)

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
		content = renderList(current.active, _("copilot_subsidy_manager_no_active"), "")
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
		title = _("copilot_subsidy_manager_title"),
		closable = true,
		movable = true,
		pinnable = true,
		initialX = 0.28,
		initialY = 0.2,
		autoFocusOnBecomingVisible = false,
		autoVisibilityOnFocusChange = false,
		content = builtin.BoxLayout {
			orientation = builtin.type.Orientation.Vertical,
			children = { controls, content },
		},
	}
end)

local function getWindowApi() : Builtin.WindowAPI
	local globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
	return globals.getDefaultWindowApi()
end

local SubsidyManagerHost = react.RegisterPluginRecipe(entryPoint.ModEntryPointExtension, "CopilotSubsidyManagerHost", function() : TreeNodeId
	local created : ReactRefT<boolean> = react.useRef(false)
	react.onStepTimer(function()
		react.enqueueJoin(function()
			if created:hasExpired() or created:get() then return end
			local windows = getWindowApi()
			if not windows then return end
			windows.addSingletonWindow(SubsidyManagerWindow, {})
			created:set(true)
		end, "CopilotSubsidyManager:createWindow")
	end, 0.1, false)
	return builtin.BoxLayout { children = {} }
end)

local SubsidyManagerButton = react.RegisterPluginRecipe(modArea.MainModButtonAreaExtension, "CopilotSubsidyManagerButton", function() : TreeNodeId
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.Button {
				meta = {
					id = "copilot-subsidy-manager.button",
					tooltip = _("copilot_subsidy_manager_button_tooltip"),
				},
				content = builtin.ImageView {
					path = "::/gui/context_helper/icons/menu_subsidies@2x.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				onClick = function()
					local visible = api.gui.byId.isVisible(WINDOW_ID)
					api.gui.byId.setVisible(WINDOW_ID, not visible)
				end,
			},
		},
	}
end)

return {
	SubsidyManagerButton = SubsidyManagerButton,
	SubsidyManagerHost = SubsidyManagerHost,
}