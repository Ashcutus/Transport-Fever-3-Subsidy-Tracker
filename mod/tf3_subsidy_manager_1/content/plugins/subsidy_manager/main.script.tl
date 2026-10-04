local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local modArea = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local entryPoint = ug_require "::/gui/main/mod_entry_point.tl" as ModEntryPoint

local MOD_ID = "copilot_subsidy_manager"
local WINDOW_ID = "copilot-subsidy-manager.window"
local DEBUG_LOGGING = false

local record Snapshot
	stateFound : boolean
	scriptName : string
	offered : {ISubvention}
	active : {ISubvention}
	completed : {ISubvention}
	failed : {ISubvention}
end

local function emptySnapshot() : Snapshot
	return {
		stateFound = false,
		scriptName = "",
		offered = {},
		active = {},
		completed = {},
		failed = {},
	}
end

local function readSnapshot() : Snapshot
	local snapshot = emptySnapshot()
	local componentType = api.type.ComponentType.GAME_SCRIPT

	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if not api.engine.entityExists(entity) then return end
		local component = api.engine.getComponent(entity, componentType) as Engine.Component.GameScript<any>
		if not component then return end

		local state = component.state as SubventionState
		if not state or state.proposedSubventions == nil or state.activeSubventions == nil then return end

		snapshot.stateFound = true
		snapshot.scriptName = component.gameScript
		snapshot.offered = state.proposedSubventions
		snapshot.active = state.activeSubventions
		snapshot.completed = state.completedSubventions or {}
		snapshot.failed = state.failedSubventions or {}
	end, componentType)

	if DEBUG_LOGGING and snapshot.stateFound then
		log.warning("[copilot_subsidy_manager] Read subsidy state from " .. snapshot.scriptName)
	end
	return snapshot
end

local function renderEntry(item : ISubvention, outcome : string) : TreeNodeId
	local data = item.data
	local required = data.toDeliver
	local delivered = data.delivered
	local progress = required > 0 and math.floor(delivered / required * 100) or 0
	local details = string.format("%d / %d transported  |  %d%%", delivered, required, progress)
	return builtin.TextView {
		text = outcome .. "  " .. _(data.name) .. "\n" .. details,
	}
end

local function renderList(items : {ISubvention}, emptyText : string, outcome : string) : TreeNodeId
	if #items == 0 then
		return builtin.TextView { text = emptyText }
	end
	local children : {TreeNodeId} = {}
	for _, item in ipairs(items) do
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
	local snapshot : ReactStateT<Snapshot> = react.useState(readSnapshot())
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
	if not current.stateFound then
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
			for _, item in ipairs(current.completed) do
				history[#history + 1] = renderEntry(item, _("copilot_subsidy_manager_completed"))
			end
			for _, item in ipairs(current.failed) do
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
			api.gui.byId.setVisible(WINDOW_ID, false)
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