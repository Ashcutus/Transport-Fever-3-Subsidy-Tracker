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
local AUTO_DECLINE_EVENT = "tf3SubsidyManagerAutoDecline"
local OFFERS_OPENED_EVENT = "tf3SubsidyManagerOffersOpened"
local ARCHIVE_REQUEST_EVENT = "tf3SubsidyManagerArchiveRequest"
local ARCHIVE_REPLY_EVENT = "tf3SubsidyManagerArchiveReply"
local ARCHIVE_RECOVER_EVENT = "tf3SubsidyManagerArchiveRecover"
local pendingArchiveRequest : {any : any} = nil
local archiveRequestSession = tostring({})
local archiveRequestSerial = 0

local function sendArchiveRequest(action : string, key : string, sequence : number, enabled? : boolean, review? : boolean)
	if pendingArchiveRequest then return end
	archiveRequestSerial = archiveRequestSerial + 1
	local requestId = archiveRequestSession .. ":" .. tostring(archiveRequestSerial)
	pendingArchiveRequest = { action = action, key = key, sequence = sequence, attempts = 0, enabled = enabled, review = review, requestId = requestId }
	local ok = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(MOD_ID, "tf3SubsidyManager", "tf3SubsidyManager", { action = action, key = key, enabled = enabled, review = review, requestId = requestId }))
	end)
	if not ok then
		pendingArchiveRequest = nil
		react.fireEvent(nil, ARCHIVE_REPLY_EVENT, { action = action, key = key, success = false, reason = "unavailable", sequence = sequence, enabled = enabled, review = review })
	end
end

local function readArchiveReply() : {any : any}
	local nativeEnabled : boolean = nil
	local ok, value = pcall(function() : any
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SUBVENTION_SCRIPT)
		if not entity or not api.engine.entityExists(entity) then return nil end
		local component = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT) as Engine.Component.GameScript<SubventionState>
		local state = component and component.state as {any : any}
		local archive = state and state.tf3SubsidyManagerArchive as {any : any}
		if archive and type(archive.automatic) == "table" and type((archive.automatic as table).enabled) == "boolean" then nativeEnabled = (archive.automatic as table).enabled as boolean end
		return archive and archive.response
	end)
	local response : {any : any} = {}
	if ok and type(value) == "table" then
		for key, child in pairs(value as {any : any}) do
			if type(child) == "string" or type(child) == "number" or type(child) == "boolean" then response[key] = child end
		end
	end
	if nativeEnabled ~= nil then response.modeEnabled = nativeEnabled end
	return response
end

local function checkArchiveReply(request : {any : any}, response : {any : any})
	if not request or request ~= pendingArchiveRequest then return end
	pendingArchiveRequest.attempts = (pendingArchiveRequest.attempts as number) + 1
	local matches = response.requestId == request.requestId and type(response.sequence) == "number" and (response.sequence as number) < math.huge and (response.sequence as number) > (pendingArchiveRequest.sequence as number) and response.action == pendingArchiveRequest.action
	if response.action == "recover" and response.key ~= pendingArchiveRequest.key then matches = false end
	if not matches then
		if (pendingArchiveRequest.attempts as number) < 4 then return end
		response = { action = pendingArchiveRequest.action, key = pendingArchiveRequest.key, sequence = pendingArchiveRequest.sequence, success = false, reason = "unavailable", enabled = pendingArchiveRequest.enabled, review = pendingArchiveRequest.review }
	end
	pendingArchiveRequest = nil
	react.fireEvent(nil, ARCHIVE_REPLY_EVENT, response)
end

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

local function queryOfferIdentities(uids : {string : integer}) : {string : boolean}
	local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SUBVENTION_SCRIPT)
	if not entity or not api.engine.entityExists(entity) then return nil end
	local component = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT) as Engine.Component.GameScript<SubventionState>
	if not component or type(component.state) ~= "table" or type(component.state.proposedSubventions) ~= "table" then return nil end
	local offers : {string : boolean} = {}
	-- Read only identity fields; never format cards or copy other subsidy collections.
	for _index, record in ipairs(component.state.proposedSubventions) do
		local key = offerIdentity(record)
		if key then
			offers[key] = true
			if uids then uids[key] = record.uid as integer end
		end
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

local record AutoDeclineState
	enabled : boolean
	initialized : boolean
	offers : {string : boolean}
	dirty : boolean
end

local function loadAutoDecline() : AutoDeclineState
	local initial : AutoDeclineState = { enabled = false, initialized = false, offers = {}, dirty = false }
	local ok, saved = pcall(function() : any return api.gui.game.getGuiSaveData(MOD_ID) end)
	if not ok or type(saved) ~= "table" then return initial end
	local setting = (saved as table).autoDecline as table
	if type(setting) ~= "table" or setting.version ~= 1 or type(setting.enabled) ~= "boolean" or type(setting.offers) ~= "table" then return initial end
	for key, value in pairs(setting.offers as {any : any}) do
		if type(key) ~= "string" or value ~= true then return initial end
	end
	initial.enabled = setting.enabled as boolean
	initial.initialized = setting.initialized == true
	for key, _value in pairs(setting.offers as {string : boolean}) do initial.offers[key] = true end
	return initial
end

local function saveAutoDecline(setting : AutoDeclineState) : boolean
	return pcall(function()
		local saved = api.gui.game.getGuiSaveData(MOD_ID)
		local data : {any : any} = {}
		if type(saved) == "table" then for key, value in pairs(saved) do data[key] = value end end
		local offers : {string : boolean} = {}
		for key, value in pairs(setting.offers) do offers[key] = value end
		data.autoDecline = { version = 1, enabled = setting.enabled, initialized = setting.initialized, offers = offers }
		api.gui.game.setGuiSaveData(MOD_ID, data)
	end)
end

local OfferBadgeIcon = react.RegisterWrapperRecipe("TF3SubsidyManagerOfferBadgeIcon", builtin.Component, function(_params : Builtin.ComponentParam) : TreeNodeId
	local tracked : ReactRefT<OfferBadgeState> = react.useRefLazy(loadOfferBadge)
	local automatic : ReactRefT<AutoDeclineState> = react.useRefLazy(loadAutoDecline)
	local synchronized : ReactRefT<boolean> = react.useRef(false)
	local pending : ReactStateT<boolean>
	pending = engineReactUtil.useStepStateTimer(function() : boolean
		-- Native timer callbacks execute in the restricted deferred-read phase.
		-- Only collect detached engine data here. All effects run in enqueueJoin.
		local requestAtRead = pendingArchiveRequest
		local response = requestAtRead and readArchiveReply() or nil
		local uids : {string : integer} = {}
		local ok, result = pcall(queryOfferIdentities, uids)
		local offers = ok and result as {string : boolean} or nil
		react.enqueueJoin(function()
			if pending:hasExpired() then return end
			checkArchiveReply(requestAtRead, response)
			local badge = tracked:get()
			if not offers then return end
			local setting = automatic:get()
			if not synchronized:get() and not pendingArchiveRequest then
				local previous = readArchiveReply()
				-- The simulation's saved choice is authoritative after migration.
				if type(previous.modeEnabled) == "boolean" and previous.modeEnabled ~= setting.enabled then
					setting.enabled = previous.modeEnabled as boolean
					setting.dirty = true
				end
				sendArchiveRequest("configure", nil, (previous.sequence or 0) as number, setting.enabled, false)
				synchronized:set(true)
			end
			if setting.dirty then setting.dirty = not saveAutoDecline(setting) end
			local changed = not badge.initialized
			for key, _value in pairs(offers) do
				if not badge.offers[key] then
					if badge.initialized and not setting.enabled then badge.pending = true end
					changed = true
				end
			end
			for key, _value in pairs(badge.offers) do if not offers[key] then changed = true end end
			badge.initialized, badge.offers = true, offers
			if changed or badge.dirty then badge.dirty = not saveOfferBadge(badge) end
			pending:set(badge.pending)
		end, "TF3SubsidyManager:offerRead")
		return tracked:get().pending
	end, 5)
	react.onEvent(ARCHIVE_REQUEST_EVENT, function(_name : string, value : any)
		if type(value) ~= "table" then return end
		local request = value as {any : any}
		sendArchiveRequest(request.action as string, request.key as string, request.sequence as number, request.enabled as boolean, request.review as boolean)
	end)
	react.onEvent(AUTO_DECLINE_EVENT, function(_name : string, value : any)
		if type(value) ~= "boolean" then return end
		local setting = automatic:get()
		setting.enabled = value as boolean
		-- Simulation takes the baseline when this configuration command arrives.
		-- Future offers are suppressed before commit, not by this GUI timer.
		setting.dirty = not saveAutoDecline(setting)
		local previous = readArchiveReply()
		sendArchiveRequest("configure", nil, (previous.sequence or 0) as number, setting.enabled, not setting.enabled)
		synchronized:set(true)
	end)
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
	archiveKey : string
	revealed : boolean
	reason : string
end

local record Snapshot
	readError : boolean
	stateFound : boolean
	scriptName : string
	offered : {Entry}
	active : {Entry}
	completed : {Entry}
	failed : {Entry}
	declined : {Entry}
	expired : {Entry}
	archiveResponse : {any : any}
	archiveNotice : {any : any}
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
		declined = {},
		expired = {},
		archiveResponse = { sequence = 0 },
		archiveNotice = { sequence = 0 },
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

local function getCard(recordCopy : ISubvention, offered : boolean, savedRemaining? : number) : SubventionCardData
	if type(recordCopy.id) ~= "string" then return nil end
	local id = api.res.genericRep.find(recordCopy.id)
	if id < 0 then return nil end
	local resource = api.res.genericRep.get(id)
	local desc = resource.data as SubventionDesc
	if not desc or type(desc.scriptFile) ~= "string" then return nil end
	local getCardData = util.useFn(desc.scriptFile .. ".getCardData") as function(ISubvention, boolean) : SubventionCardData
	if not getCardData then return nil end
	-- Full cards also build map overlays, which can fail before simulation data
	-- is ready. Retry the native overview path without inventing progress values.
	-- Each attempt gets its own copy: legacy helpers can migrate before failing.
	local ok, formatted = pcall(getCardData, copyTable(recordCopy) as ISubvention, false)
	if not ok then
		log.warning("[tf3_subsidy_manager] Full subsidy card unavailable; retrying native lightweight card: " .. tostring(formatted))
		formatted = getCardData(copyTable(recordCopy) as ISubvention, true)
	end
	if type(formatted) ~= "table" then return nil end
	local card = copyTable(formatted) as SubventionCardData
	if offered and card then
		-- Vanilla card.deadline is the task duration, not the offer timeout.
		-- Use defaultTimeout's proposed timestamp contract and the native formatter.
		card.deadline = nil
		card.expireDuration = nil
		local duration = recordCopy.data.expireDurationProposed
		local spawnTime = recordCopy.spawnTime
		if type(duration) == "number" and duration >= 0 and duration < math.huge then
			local world = api.engine.util.getWorld()
			local speed = api.engine.getComponent(world, api.type.ComponentType.GAME_SPEED) as Engine.Component.GameSpeed
			local remaining = savedRemaining
			if remaining == nil and type(spawnTime) == "number" and math.abs(spawnTime) < math.huge then
				local time = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
				if time then remaining = duration - (time.gameTime - spawnTime) end
			end
			if speed and type(remaining) == "number" and math.abs(remaining) < math.huge and (savedRemaining == nil or savedRemaining >= 0) then
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
local function copyEntries(items : {ISubvention}, offered? : boolean, outcome? : string, savedRemaining? : number) : {Entry}
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
			local ok, card = pcall(getCard, entry.recordCopy, offered or false, savedRemaining)
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
	local archive = (state as {any : any}).tf3SubsidyManagerArchive as {any : any}
	if type(archive) == "table" and archive.version == 1 and type(archive.entries) == "table" then
		if type(archive.response) == "table" then snapshot.archiveResponse = copyTable(archive.response) as {any : any} end
		local savedNotice = type(archive.notice) == "table" and archive.notice or archive.response
		if type(savedNotice) == "table" then snapshot.archiveNotice = copyTable(savedNotice) as {any : any} end
		for _index, value in ipairs(archive.entries as {{any : any}}) do
			if type(value) == "table" and type(value.record) == "table" and type(value.key) == "string" then
				local entries = copyEntries({value.record as ISubvention}, value.status == "saved", value.status == "expired" and "expired" or value.source == "automatic" and "hidden" or "declined", value.remaining as number)
				local entry = entries[1]
				entry.archiveKey = value.key as string
				entry.revealed = value.revealed == true
				entry.reason = type(value.reason) == "string" and value.reason as string or "unsupported"
				if value.status == "expired" then snapshot.expired[#snapshot.expired + 1] = entry
				elseif value.status == "saved" then snapshot.declined[#snapshot.declined + 1] = entry end
			end
		end
	end
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
	if item and item.archiveKey then return false end
	if not item or not item.card or not item.recordCopy then return false end
	local uid = item.recordCopy.uid
	return type(uid) == "number" and uid >= 0 and uid < math.huge and uid == math.floor(uid)
end

local function canRestoreOffer(item : Entry) : boolean
	if not item or not item.archiveKey or item.outcome == "expired" or not item.recordCopy then return false end
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
	return "—"
end

local function isTransportWorkers(item : Entry) : boolean
	return item.recordCopy ~= nil and item.recordCopy.id == "::/game_mechanics/subventions/deliver_workers/deliver_workers.res"
end

local function columnText(item : Entry, key : string) : string
	local card = item.card
	if key == "type" then return item.name end
	if key == "status" then
		if item.outcome == "" then return _("tf3_subsidy_manager_available") end
		if item.outcome == "expired" then return _("tf3_subsidy_manager_expired") end
		return _(item.outcome == "failed" and "tf3_subsidy_manager_failed" or "tf3_subsidy_manager_completed")
	end
	if item.outcome == "expired" and key == "reward" then return _("tf3_subsidy_manager_recovery_reason_" .. (item.reason or "unsupported")) end
	if key == "resource" then return item.resourceName and item.resourceName ~= "" and item.resourceName or "—" end
	if key == "requirement" then
		local required = card and card.cargoToDeliver or item.required
		return type(required) == "number" and required >= 0 and required < math.huge and tostring(required) or "—"
	end
	if key == "progress" then
		if key == "progress" and isTransportWorkers(item) and card and card.progress and type(card.progress.text) == "string" then
			-- Zero is valid native workforce progress; missing/invalid ratios retain the native label.
			local value = card.progress.value
			if type(value) == "number" and value >= 0 and value <= 1 then
				return string.format("%g%% %s", value * 100, card.progress.text)
			end
			return card.progress.text
		end
		if key == "progress" and card and card.progress and type(card.progress.value) == "number" and card.progress.value >= 0 and card.progress.value < math.huge and type(card.progress.text) == "string" then
			return card.progress.text
		end
		return countText(item)
	end
	if key == "destination" and card and card.location then
		local from = card.location.from and card.location.from[2] or ""
		local to = card.location.to and card.location.to[2] or ""
		return from ~= "" and to ~= "" and from .. " → " .. to or (to ~= "" and to or (from ~= "" and from or "—"))
	end
	if key == "reward" and card then
		local texts : {string} = {}
		local effects = item.outcome == "failed" and card.failure or card.complete
		for _index, effect in ipairs(effects or {}) do
			if type(effect.text) == "string" and effect.text ~= "" then texts[#texts + 1] = effect.text end
		end
		return #texts > 0 and table.concat(texts, "\n") or "—"
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
		local tooltip = text == "—" and _("tf3_subsidy_manager_missing_value_tooltip") or text
		local parts : {TreeNodeId} = {}
		if item and key == "resource" and item.card then
			for _index, path in ipairs(item.card.cargoIcons or {}) do
				parts[#parts + 1] = builtin.ImageView { path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
			end
		elseif item and key == "status" and (item.outcome == "failed" or item.outcome == "successful") then
			parts[#parts + 1] = builtin.ImageView {
				path = item.outcome == "failed" and "::/game_mechanics/subventions/icons/mark_failed.tga" or "::/game_mechanics/subventions/icons/mark_complete.tga",
				scaling = builtin.type.ImageViewScaling.AutoFit,
			}
		end
		if item and key == "progress" and item.card and item.card.progress and type(item.card.progress.value) == "number" and item.card.progress.value >= 0 and item.card.progress.value < math.huge and type(item.card.progress.text) == "string" and (not isTransportWorkers(item) or item.card.progress.value <= 1) then
			-- Some native tasks report a qualitative label (e.g. Workers), not counts.
			parts[#parts + 1] = builtin.ProgressBar { value = math.min(1, item.card.progress.value), label = text }
		else
			parts[#parts + 1] = builtin.TextView { text = text, tooltipWhenClipped = tooltip }
		end
		return builtin.BoxLayout {
			children = { builtin.Button {
				meta = { class = key == "reward" and "tf3-subsidy-cell, tf3-subsidy-reward-cell" or key == "time" and "tf3-subsidy-cell, tf3-subsidy-time-cell" or "tf3-subsidy-cell", tooltip = tooltip, enabled = canOpenDetail(item) or canRestoreOffer(item) },
				content = builtin.Component { layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = parts } },
				onClick = function()
					if canRestoreOffer(item) then
						react.fireEvent(nil, ARCHIVE_RECOVER_EVENT, item.archiveKey)
					elseif item then openDetail(item) end
				end,
			} },
		}
	end)
end

local cellRecipes : {string : Recipe<Builtin.TableCellParam>} = {}
for _index, key in ipairs({"type", "resource", "destination", "requirement", "progress", "reward", "time", "status"}) do cellRecipes[key] = makeCell(key) end

local function renderEmpty(section : integer) : TreeNodeId
	local title = section == 1 and _("tf3_subsidy_manager_no_active") or section == 2 and _("tf3_subsidy_manager_no_offers") or _("tf3_subsidy_manager_no_history")
	local hint = section == 1 and _("tf3_subsidy_manager_empty_active_hint") or section == 2 and _("tf3_subsidy_manager_empty_offers_hint") or _("tf3_subsidy_manager_empty_history_hint")
	return builtin.Component {
		meta = { class = "tf3-subsidy-empty-state" },
		mouseTransparent = true,
		layout = builtin.BoxLayout {
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView { path = "tf3_subsidy_manager::/plugins/subsidy_manager/icons/empty_contract_64.tga", scaling = builtin.type.ImageViewScaling.AutoFit },
				builtin.BoxLayout {
					orientation = builtin.type.Orientation.Vertical,
					children = {
						builtin.TextView { meta = { class = "tf3-subsidy-empty-title" }, text = title },
						builtin.TextView { meta = { class = "tf3-subsidy-empty-hint" }, text = hint },
					},
				},
			},
		},
	}
end

local function renderTable(items : {Entry}, section : integer, generation : integer) : TreeNodeId
	if #items == 0 then return renderEmpty(section) end
	local keys = section == 3 and {"status", "type", "resource", "destination", "reward"} or
		{"type", "resource", "destination", section == 1 and "progress" or "requirement", "reward", "time"}
	local columns : {TreeNodeId} = {}
	for _index, key in ipairs(keys) do
		local label = key == "reward" and section == 3 and "reward_consequence" or key == "time" and section == 1 and "deadline" or key
		columns[#columns + 1] = builtin.ColumnDesc {
			name = _("tf3_subsidy_manager_column_" .. label),
			recipe = cellRecipes[key],
			-- Split the old reward/time budget equally now that effects use multiple lines.
			weight = (key == "reward" or key == "time") and 1.75 or key == "destination" and 1.5 or 1,
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

local function acknowledgedArchiveSequence() : number
	local ok, saved = pcall(function() : any return api.gui.game.getGuiSaveData(MOD_ID) end)
	if ok and type(saved) == "table" and type((saved as table).archiveAcknowledged) == "number" then return (saved as table).archiveAcknowledged as number end
	return 0
end

local function acknowledgeArchive(sequence : number)
	pcall(function()
		local saved = api.gui.game.getGuiSaveData(MOD_ID)
		local data : {any : any} = {}
		if type(saved) == "table" then for key, value in pairs(saved) do data[key] = value end end
		data.archiveAcknowledged = sequence
		api.gui.game.setGuiSaveData(MOD_ID, data)
	end)
end

local SubsidyManagerWindow = react.RegisterWrapperRecipe("TF3SubsidyManagerWindow", builtin.Window, function(params : WindowParams) : TreeNodeId
	local snapshot : ReactStateT<Snapshot> = react.useStateLazy(readSnapshot)
	local selectedTab : ReactStateT<integer> = react.useState(1)

	local autoDecline : ReactStateT<boolean> = react.useStateLazy(function() : boolean return loadAutoDecline().enabled end)
	local generation : ReactStateT<integer> = react.useState(0)
	local showDeclined : ReactStateT<boolean> = react.useState(false)
	local busy : ReactStateT<boolean> = react.useState(pendingArchiveRequest ~= nil)
	local notice : ReactStateT<{any : any}> = react.useStateLazy(function() : {any : any}
		local response = snapshot:old().archiveNotice
		if response.action == "recover" and response.success == true then return nil end
		if response.action == "configure" and response.review == true and response.success == true then response.action = "review" end
		if (not autoDecline:old() or (response.action == "configure" and response.reason == "unavailable")) and type(response.sequence) == "number" and (response.sequence as number) > acknowledgedArchiveSequence() then return response end
		return nil
	end)
	local function acknowledgeVisibleReview(reply : {any : any}, updated : Snapshot) : boolean
		if not reply or reply.action ~= "review" or reply.success ~= true or reply.reason == "unavailable" or selectedTab:old() ~= 2 or not updated.stateFound or updated.readError then return false end
		acknowledgeArchive(reply.sequence as number)
		return true
	end
	local function refresh()
		local updated = readSnapshot()
		if acknowledgeVisibleReview(notice:old(), updated) then notice:set(nil) end
		snapshot:set(updated)
		generation:set(generation:old() + 1)
	end
	local function request(action : string, key : string, disabling? : boolean, enabled? : boolean, review? : boolean)
		if busy:old() or pendingArchiveRequest then return end
		if autoDecline:old() and not disabling then
			local visibleOffer = false
			if action == "recover" then
				for _index, entry in ipairs(snapshot:old().declined) do
					if entry.archiveKey == key and entry.revealed then visibleOffer = true end
				end
			end
			if not visibleOffer then return end
		end
		busy:set(true)
		react.fireEvent(nil, ARCHIVE_REQUEST_EVENT, { action = action, key = key, sequence = snapshot:old().archiveResponse.sequence or 0, enabled = enabled, review = review })
	end
	react.onEvent(ARCHIVE_RECOVER_EVENT, function(_name : string, key : any)
		if type(key) == "string" then request("recover", key as string) end
	end)
	react.onEvent(ARCHIVE_REPLY_EVENT, function(_name : string, value : any)
		if type(value) ~= "table" then return end
		local reply = value as {any : any}
		busy:set(false)
		if reply.action == "configure" then
			if reply.success == true then
				autoDecline:set(reply.enabled == true)
				if reply.review ~= true then return end
				reply.action = "review"
			end
		end
		local updated = readSnapshot()
		if acknowledgeVisibleReview(reply, updated) or (reply.action == "recover" and reply.success == true) then
			notice:set(nil)
		else
			notice:set(reply)
		end
		if reply.action == "recover" and reply.success == true then
			local uid : number = nil
			for _index, entry in ipairs(snapshot:old().declined) do if entry.archiveKey == reply.key and entry.recordCopy then uid = entry.recordCopy.uid end end
			for _index, entry in ipairs(updated.offered) do if entry.recordCopy and entry.recordCopy.uid == uid then openDetail(entry) end end
		end
		snapshot:set(updated)
		generation:set(generation:old() + 1)
	end)
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
	for _index, item in ipairs(current.expired) do history[#history + 1] = item end
	local offers : {Entry} = {}
	local hiddenCount, manualCount = 0, 0
	for _index, item in ipairs(current.offered) do offers[#offers + 1] = item end
	for _index, item in ipairs(current.declined) do
		if item.outcome == "hidden" and (item.revealed or not autoDecline:old()) then
			hiddenCount = hiddenCount + 1
			offers[#offers + 1] = item
		elseif item.outcome ~= "hidden" and not autoDecline:old() then
			manualCount = manualCount + 1
			if showDeclined:old() then offers[#offers + 1] = item end
		end
	end
	local content : TreeNodeId
	if current.readError then content = builtin.TextView { text = _("tf3_subsidy_manager_read_error") }
	elseif not current.stateFound then content = builtin.TextView { text = _("tf3_subsidy_manager_unavailable") }
	elseif section == 1 then content = renderTable(current.active, section, generation:old())
	elseif section == 2 then content = renderTable(offers, section, generation:old())
	else content = renderTable(history, section, generation:old()) end
	local message = notice:old()
	local unseenHidden = current.stateFound and not current.readError and not busy:old() and hiddenCount > 0 and message ~= nil and message.action == "review" and message.success == true and message.reason ~= "unavailable" and type(message.count) == "number" and (message.count as number) > 0 and type(message.sequence) == "number" and (message.sequence as number) > acknowledgedArchiveSequence()
	local buttons : {Builtin.ToggleButtonGroupChildParam} = {}
	local counts = {#current.active, #offers, #history}
	for index, label in ipairs({"active", "offered", "history"}) do
		local count = current.stateFound and (" (" .. counts[index] .. ")") or ""
		buttons[index] = { content = builtin.TextView { text = _("tf3_subsidy_manager_" .. label) .. count } }
		if index == 2 and unseenHidden then
			buttons[index] = {
				meta = { tooltip = string.format(_(message.count == 1 and "tf3_subsidy_manager_hidden_available_one" or "tf3_subsidy_manager_hidden_available"), message.count) },
				content = builtin.Component { mouseTransparent = true, layout = builtin.BoxLayout {
					orientation = builtin.type.Orientation.Horizontal,
					children = { builtin.TextView { text = _("tf3_subsidy_manager_offered") .. count },
						builtin.TextView { meta = { class = "tf3-subsidy-offered-dot" }, text = " ●" } },
				} },
			}
		end
	end
	local autoDeclineWaiting = busy:old() or pendingArchiveRequest ~= nil
	local autoDeclineTooltip = _("tf3_subsidy_manager_auto_decline_tooltip")
	if autoDeclineWaiting then
		autoDeclineTooltip = _(pendingArchiveRequest and pendingArchiveRequest.action == "recover" and "tf3_subsidy_manager_auto_decline_wait_opening" or "tf3_subsidy_manager_auto_decline_wait_updating")
	end
	local controlChildren : {TreeNodeId} = {
		builtin.ToggleButtonGroup {
			buttons = buttons, selected = section, deselectAllowed = false,
			onValueChange = function(index : integer)
				if index < 1 or index > 3 then return end
				selectedTab:set(index)
				if index == 2 and unseenHidden then
					acknowledgeArchive(message.sequence as number)
					notice:set(nil)
				end
			end,
		},
		builtin.Button {
			meta = { class = "secondary", tooltip = _("tf3_subsidy_manager_refresh_tooltip") },
			content = builtin.TextView { text = _("tf3_subsidy_manager_refresh") },
			onClick = refresh,
		},
		builtin.CheckBox {
			meta = { tooltip = autoDeclineTooltip, enabled = true },
			label = _(autoDeclineWaiting and "tf3_subsidy_manager_auto_decline_waiting" or "tf3_subsidy_manager_auto_decline"), value = autoDecline:old() and 1 or 0,
			onValueChange = function(value : integer)
				if busy:old() or pendingArchiveRequest then return end
				if value == 1 and not autoDecline:old() then
					-- Preserve the rows already displayed during confirmation,
					-- including older saves without per-offer visibility flags.
					local updated = copyTable(snapshot:old()) as Snapshot
					for _index, entry in ipairs(updated.declined) do
						if entry.outcome == "hidden" then entry.revealed = true end
					end
					snapshot:set(updated)
					generation:set(generation:old() + 1)
				end
				autoDecline:set(value == 1)
				showDeclined:set(false)
				notice:set(nil)
				react.fireEvent(nil, AUTO_DECLINE_EVENT, value == 1)
				busy:set(pendingArchiveRequest ~= nil)
			end,
		},
	}
	if section == 2 and not autoDecline:old() and manualCount > 0 then
		controlChildren[#controlChildren + 1] = builtin.CheckBox {
			label = _("tf3_subsidy_manager_show_declined"), value = showDeclined:old() and 1 or 0,
			onValueChange = function(value : integer)
				showDeclined:set(value == 1)
				generation:set(generation:old() + 1)
			end,
		}
	end
	local showNotice = (busy:old() and pendingArchiveRequest ~= nil and pendingArchiveRequest.action == "recover") or (not busy:old() and message ~= nil and (message.action == "recover" or (message.reason == "unavailable" and (not autoDecline:old() or message.action == "configure"))))
	local controls = builtin.BoxLayout {
		meta = { class = "tf3-subsidy-controls" }, orientation = builtin.type.Orientation.Horizontal,
		children = controlChildren,
	}
	local children : {TreeNodeId} = { controls }
	if showNotice then
		local text = _("tf3_subsidy_manager_checking_saved")
		if not busy:old() and message then
			if message.action == "configure" and message.reason == "unavailable" then text = _("tf3_subsidy_manager_configuration_unavailable")
			elseif message.reason == "unavailable" then text = _("tf3_subsidy_manager_recovery_unavailable")
			else text = _("tf3_subsidy_manager_recovery_expired") end
		end
		local feedback : {TreeNodeId} = { builtin.TextView { text = text } }
		if not busy:old() then
			if message and message.reason == "unavailable" then feedback[#feedback + 1] = builtin.Button {
				content = builtin.TextView { text = _("tf3_subsidy_manager_retry") },
				onClick = function() request(message.action as string, message.key as string, message.action == "configure", message.enabled as boolean, message.review as boolean) end,
			} end
			feedback[#feedback + 1] = builtin.Button {
				content = builtin.TextView { text = _("tf3_subsidy_manager_dismiss") },
				onClick = function() if message then acknowledgeArchive(message.sequence as number) end; notice:set(nil) end,
			}
		end
		children[#children + 1] = builtin.BoxLayout { meta = { class = "tf3-subsidy-feedback" }, orientation = builtin.type.Orientation.Horizontal, children = feedback }
	end
	children[#children + 1] = builtin.ScrollArea {
		meta = { class = "tf3-subsidy-data-region" },
		horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		verticalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		content = builtin.Component {
			layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = { content } },
		},
	}
	-- Archive rows also require the populated preset; tabs do not resize it.
	local hasRecords = #current.active + #offers + #history + manualCount > 0
	return builtin.Window {
		meta = { class = (hasRecords and "tf3-subsidy-populated" or "tf3-subsidy-empty") .. (showNotice and ", tf3-subsidy-feedback-visible" or "") },
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
			children = children,
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
