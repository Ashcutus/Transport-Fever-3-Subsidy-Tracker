-- TEAL_DIR=/path/to/teal lua5.4 tests/offer_badge_test.lua
-- Models timer scheduling/mounts; C++ badge painting and save I/O still need UAT.
local tealDir = assert(os.getenv("TEAL_DIR"), "Set TEAL_DIR")
package.path = tealDir .. "/?.lua;" .. package.path
local tl = require("teal.api.v2")
local file = assert(io.open("mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/main.script.tl"))
local generated, result = tl.gen(file:read("*a")); file:close()
assert(generated and #result.syntax_errors == 0)
local nativeEngineCode
local nativeEnginePath = os.getenv("TF3_ENGINE_REACT_TL")
if nativeEnginePath then
    local nativeFile = assert(io.open(nativeEnginePath))
    local nativeResult
    nativeEngineCode, nativeResult = tl.gen(nativeFile:read("*a")); nativeFile:close()
    assert(nativeEngineCode and #nativeResult.syntax_errors == 0)
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[key] = copy(child) end; return out
end
local function offer(uid, id, time)
    return {id = id or "native-offer.res", uid = uid, spawnTime = time or 100, data = {}}
end
local commands, archiveCommands, configCommands, commandFailure = {}, {}, {}, false
local cardAvailable, detailEvents = false, {}
local saved, component, writes, cardReads, engineReads = nil, nil, 0, 0, 0
local getFailure, setFailure, engineFailure, unavailable = false, false, false, false
local function world(offers)
    return {state = {proposedSubventions = offers, activeSubventions = {}, completedSubventions = {}, failedSubventions = {}}}
end
local function context() return {refs = {}, states = {}, events = {}, mounts = {}, timers = {}} end
local restricted, joins, forbidden = false, {}, {}
local function requireMain(name)
    if restricted then
        forbidden[#forbidden + 1] = name
        error('API is currently restricted: ' .. name)
    end
end
local function flushJoins()
    assert(not restricted)
    while #joins > 0 do
        local batch = joins; joins = {}
        for _, fn in ipairs(batch) do fn() end
    end
end
local badgeContext, iconContext, windowContext, activeContext
local badgeRecipe, iconRecipe, windowRecipe, toolbar, replacements, builtin, react
local function boot()
    badgeContext, iconContext, windowContext, replacements = context(), context(), context(), {}
    builtin = {type = {Orientation = {Horizontal = 1, Vertical = 2}, ImageViewScaling = {AutoFit = 1},
        FloatingLayoutOverflowMode = {Overflow = 1}, ScrollBarPolicy = {AlwaysOff = 1, AsNeededButAlwaysReserveSpace = 2}}}
    for _, name in ipairs({"Component", "FloatingLayout", "FloatingLayoutChild", "BoxLayout", "ImageView", "TextView",
        "Window", "ScrollArea", "Button", "ToolButton", "ToolStack", "ToggleButtonGroup", "CheckBox", "ColumnDesc", "DataTable"}) do
        builtin[name] = function(...) local args = {...}; local node = args[#args]; node.kind = name; return node end
    end
    react = {}
    function react.RegisterRecipe(name, fn)
        if name == "TF3SubsidyManagerController" then
            badgeRecipe = fn
            return function() return {kind = "ControllerRecipe"} end
        end
        return fn
    end
    function react.RegisterPluginRecipe(extension, _, fn) assert(extension.id == "::MainModButtonAreaExtension"); return fn end
    function react.RegisterWrapperRecipe(name, wrapped, fn)
        if name == "TF3SubsidyManagerOfferBadgeIcon" then
            assert(wrapped == builtin.Component); iconRecipe = fn
            return function(params) return {kind = "BadgeRecipe", params = params} end
        end
        if name == "TF3SubsidyManagerWindow" then assert(wrapped == builtin.Window); windowRecipe = fn end
        return fn
    end
    function react.CallOriginalRecipe(fn, params) return fn(params) end
    function react.useRefLazy(fn)
        local ctx = activeContext; ctx.refIndex = ctx.refIndex + 1
        if not ctx.refs[ctx.refIndex] then
            ctx.refs[ctx.refIndex] = {value = fn(), get = function(self) return self.value end, set = function(self, value) self.value = value end}
        end
        return ctx.refs[ctx.refIndex]
    end
    function react.useStateLazy(fn)
        local ctx = activeContext; ctx.stateIndex = ctx.stateIndex + 1
        if not ctx.states[ctx.stateIndex] then
            ctx.states[ctx.stateIndex] = {value = fn(), old = function(self) return self.value end,
                set = function(self, nextValue) self.value = nextValue end,
                hasExpired = function() return ctx.expired == true end}
        end
        return ctx.states[ctx.stateIndex]
    end
    function react.useState(value) return react.useStateLazy(function() return value end) end
    function react.useRef(value) return react.useRefLazy(function() return value end) end
    function react.onStepTimer(fn, interval)
        assert(interval == 5, "Badge must use conservative native timer, not every frame")
        activeContext.timers[1] = {tick = fn, interval = interval}
    end
    function react.enqueueJoin(fn) joins[#joins + 1] = fn end
    function react.onEvent(name, fn) activeContext.events[name] = fn end
    function react.onMount(fn) activeContext.mounts[#activeContext.mounts + 1] = fn end
    function react.fireEvent(_, name, data)
        requireMain("react.fireEvent")
        if name == 'selectViewKey' then detailEvents[#detailEvents + 1] = copy(data) end
        local listener = badgeContext.events[name]
        if listener then listener(name, data) end
        local iconListener = iconContext.events[name]
        if iconListener then iconListener(name, data) end
        local windowListener = windowContext.events[name]
        if windowListener then windowListener(name, data) end
    end
    local engineReact = {useStepStateTimer = function(fn, interval)
        local state = react.useStateLazy(fn)
        react.onStepTimer(function() state:set(fn()) end, interval)
        return state
    end}
    if nativeEngineCode then
        local nativeEnv = setmetatable({ug_require = function(path)
            if path:find("/main/react.lua", 1, true) then return react end
            if path:find("table_util", 1, true) then return {deepEquals = function(a, b) return a == b end} end
            return {}
        end}, {__index = _G})
        engineReact = assert(load(nativeEngineCode, "native-engine-react", "t", nativeEnv))()
    end
    local api = {cmd = {
        makeScriptingSendEventCmd = function(namespace, target, event, data)
            assert((namespace == "tf3_subsidy_manager:auto" and target == "Subvention" and event == "onDecline")
                or (namespace == "tf3_subsidy_manager" and target == "tf3SubsidyManager" and event == target))
            return {uid = data.uid, action = data.action, key = data.key, enabled = data.enabled, review = data.review, requestId = data.requestId}
        end,
        sendCommand = function(command)
            requireMain("sendCommand")
            if commandFailure then error("command unavailable") end
            if command.action == 'configure' then
                configCommands[#configCommands + 1] = command
                if command.review then archiveCommands[#archiveCommands + 1] = command end
                -- Model simulation acknowledgement, not a GUI write to gameplay.
                local a = component.state.tf3SubsidyManagerArchive or {version = 1, entries = {}, response = {sequence = 0}}
                if command.review or (command.enabled and a.automatic and a.automatic.enabled == false) then
                    for _, entry in ipairs(a.entries) do
                        if entry.status == 'saved' and entry.source == 'automatic' then entry.revealed = true end
                    end
                end
                a.automatic = a.automatic or {}
                a.automatic.enabled = command.enabled
                a.response = {sequence = a.response.sequence + 1, action = 'configure', enabled = command.enabled, review = command.review, success = true, count = 0, requestId = command.requestId}
                component.state.tf3SubsidyManagerArchive = a
            elseif command.action then archiveCommands[#archiveCommands + 1] = command
            else commands[#commands + 1] = command end
        end,
    }, type = {ComponentType = {GAME_SCRIPT = 1, GAME_TIME = 2, GAME_SPEED = 3}}, engine = {
        util = {getWorld = function() return 1 end},
        system = {gameScriptSystem = {getEntityForGameScript = function(path)
            assert(path == "::/game_mechanics/subventions/subventions.gs")
            engineReads = engineReads + 1
            if engineFailure then error("engine unavailable") end
            return unavailable and nil or 123
        end}}, entityExists = function() return not unavailable end,
        getComponent = function(_, kind)
            if kind == 2 then return {gameTime = 1000} end
            if kind == 3 then return {millisPerDay = 10} end
            assert(kind == 1); return component
        end,
        forEachEntityWithComponent = function() error("Do not enumerate GAME_SCRIPT") end,
    }, gui = {game = {
        getGuiSaveData = function(id)
            assert(id == "tf3_subsidy_manager")
            if getFailure then error("bad GUI data read") end
            return copy(saved)
        end,
        setGuiSaveData = function(id, data)
            requireMain("setGuiSaveData")
            assert(id == "tf3_subsidy_manager")
            if setFailure then error("bad GUI data write") end
            writes = writes + 1; saved = copy(data)
        end,
    }}, res = {genericRep = {
        find = function() cardReads = cardReads + 1; return cardAvailable and 1 or -1 end,
        get = function() return {data = {scriptFile = 'test-helper.script'}} end,
    }}}
    local gameBar = {GameBar = function(params) return params end}
    local env = setmetatable({api = api, _ = function(key) return key end, log = {warning = function() end},
        ug_require = function(path)
            if path:find("engine_react_util", 1, true) then return engineReact end
            if path:find("/main/react.lua", 1, true) then return react end
            if path:find("/main/builtin.lua", 1, true) then return builtin end
            if path:find("/game_bar/game_bar.tl", 1, true) then error("No GameBar dependency allowed") end
            if path:find("main_mod_button_area.tl", 1, true) then return {MainModButtonAreaExtension = {id = "::MainModButtonAreaExtension"}} end
            if path:find("tool_react_util", 1, true) then
                return {registerToolWithWindow = function(name, _, recipe) return {name = name, recipe = recipe} end}
            end
            if path:find('/scripts/util.tl', 1, true) then return {
                useFn = function(ref)
                    assert(ref == 'test-helper.script.getCardData')
                    return function() return {expireDuration = {name = 'Task deadline'}, complete = {{text = 'Native reward'}}} end
                end,
                formatDurationWithCurrentCalenderSpeed = function(duration, speed)
                    assert(speed == 10); return 'Native remaining ' .. tostring(duration)
                end,
            } end
            return {}
        end,
    }, {__index = _G})
    local exports = assert(load(generated, "subsidy-manager", "t", env))()
    exports.installToolbar({ReplaceRecipe = function(original, replacement) replacements[original] = replacement end})
    local gameCtx = {windowContainer = {}, toolStack = {get = function() return {getApi = function()
        return {push = function() error("Window failed to open") end, pop = function() end}
    end} end}}
    assert(next(replacements) == nil)
    builtin.ToolStack({defaultToolParam = {gameCtx = gameCtx}})
    local neighbour = {meta = {id = "menu.industry-statistics.button"}, toolStack = gameCtx.toolStack}
    local pair = builtin.ToolButton({}, neighbour)
    assert(pair.children[1] == neighbour and #pair.children == 2)
    toolbar = pair.children[2]
    assert(toolbar.content.kind == "BadgeRecipe" and toolbar.meta.class == "tf3-subsidy-toolbar")
    local unrelated = {meta = {id = "menu.fileMenu"}}
    assert(builtin.ToolButton({}, unrelated) == unrelated)
end
local function render(recipe, ctx)
    activeContext = ctx; ctx.refIndex, ctx.stateIndex, ctx.mounts = 0, 0, {}
    local node = recipe({}); flushJoins(); return node
end
local function badge()
    render(badgeRecipe, badgeContext)
    local node = render(iconRecipe, iconContext)
    assert(next(iconContext.timers) == nil, "Icon must not own a second polling timer")
    assert(node.kind == "Component" and node.mouseTransparent)
    assert(node.layout.kind == "FloatingLayout")
    local children = node.layout.children
    assert(children[1].item.kind == "ImageView" and children[1].item.path:find("contract_26.tga", 1, true))
    assert(#children == 1 or #children == 2)
    if children[2] then
        assert(children[2].h > 1 and children[2].v < 0, "Badge belongs outside the icon's upper-right edge")
        assert(children[2].item.mouseTransparent)
        assert(children[2].item.layout.children[1].text == "●", "No numeric badge count")
    end
    return #children == 2
end
local function poll()
    local timer = assert(badgeContext.timers[1])
    restricted = true
    local ok, err = pcall(timer.tick)
    restricted = false
    assert(ok, err)
    assert(#forbidden == 0, 'Restricted API calls (even if swallowed): ' .. table.concat(forbidden, ', '))
    flushJoins()
    return badge()
end
local function open(mount)
    windowContext = context()
    local window = render(windowRecipe, windowContext)
    assert(window.kind == "Window")
    if mount ~= false then for _, fn in ipairs(windowContext.mounts) do fn() end end
    return badge()
end
local function reset(offers, data)
    saved, component, writes, cardReads, engineReads = copy(data), world(offers), 0, 0, 0
    getFailure, setFailure, engineFailure, unavailable = false, false, false, false
    boot()
end
local function trackedCount()
    local count = 0; for _ in pairs(saved.offerBadge.offers) do count = count + 1 end; return count
end

-- Baseline existing/empty offers; unchanged offers and rendering do no repeated work.
reset({offer(1)}, {unrelatedSetting = "preserved"})
assert(not badge() and trackedCount() == 1 and writes == 1)
assert(saved.unrelatedSetting == "preserved")
local readsBefore = engineReads
assert(not badge() and engineReads == readsBefore, "Renders must not poll")
assert(not poll() and writes == 1 and cardReads == 0)
reset({}); assert(not badge() and trackedCount() == 0)
-- Polling must not inspect active/history or detail data.
component.state = setmetatable({proposedSubventions = {}}, {__index = function(_, key) error("Unexpected collection: " .. key) end})
assert(not poll() and cardReads == 0)
component = world({offer(2)}); assert(poll())
assert(saved.offerBadge.pending and trackedCount() == 1)
local stableWrites = writes
assert(poll() and writes == stableWrites)
component.state.proposedSubventions = {offer(2), offer(3)}
assert(poll() and trackedCount() == 2)
-- Native toast dismissal never participates in detection.
component.state.notifications = {dismissed = true}
assert(poll() and saved.offerBadge.pending)
-- Accepted, declined and expired offers clean tracking, preserving the pending latch.
for _, reason in ipairs({"accepted", "declined", "expired"}) do
    reset({offer(1)}); assert(not badge())
    component.state.proposedSubventions = {offer(1), offer(2)}; assert(poll())
    component.state.proposedSubventions = {}
    if reason == "accepted" then component.state.activeSubventions = {offer(2)} end
    assert(poll() and trackedCount() == 0 and saved.offerBadge.pending, reason)
end
-- Failed click/render/unreadable mount does not acknowledge. Successful mount does.
assert(not pcall(toolbar.showFn) and badge())
assert(open(false) and saved.offerBadge.pending)
engineFailure = true; assert(open() and saved.offerBadge.pending)
engineFailure = false; assert(not open() and not saved.offerBadge.pending)
component.state.activeSubventions = {offer(8)}; component.state.completedSubventions = {offer(9)}
component.state.failedSubventions = {offer(10)}
assert(not poll())
component.state.proposedSubventions = {offer(4)}; assert(poll())
-- Reload restores pending and known offers; clearing persists immediately.
boot(); assert(badge() and saved.offerBadge.pending)
assert(not open() and not saved.offerBadge.pending)
boot(); assert(not badge() and not poll())
component.state.proposedSubventions = {offer(4), offer(5)}; assert(poll())
-- Each identity component matters; numeric formatting stays stable after reload.
assert(not open())
component.state.proposedSubventions = {offer(5, "other.res", 100)}; assert(poll())
assert(not open())
component.state.proposedSubventions = {offer(5, "other.res", 101)}; assert(poll())
assert(not open())
boot(); assert(not badge() and not poll())
-- Corrupt/old persistence establishes a safe baseline, without breaking either UI.
for _, data in ipairs({false, 7, {}, {offerBadge = false}, {offerBadge = {version = 0}},
    {offerBadge = {version = 1, pending = "yes", offers = {}}},
    {offerBadge = {version = 1, pending = true, offers = false}},
    {offerBadge = {version = 1, pending = true, offers = {bad = false}}}}) do
    reset({offer(1)}, data); assert(not badge() and not open())
end
-- Missing/invalid identity fields are ignored; transient engine errors never prune.
reset({offer(1), false, {}, offer(0/0), offer(math.huge), offer(-1), offer(2, "", 100), offer(3, "native", math.huge)})
assert(not badge() and trackedCount() == 1)
component.state.proposedSubventions = {offer(2)}; assert(poll())
engineFailure = true; assert(poll() and trackedCount() == 1)
engineFailure = false; unavailable = true; assert(poll() and trackedCount() == 1)
unavailable = false; component = {}; assert(poll() and trackedCount() == 1)
-- Failed persistence is isolated, retained in memory, and retried without changes.
reset({}); getFailure = true; assert(not badge())
component = world({offer(1)}); assert(poll())
getFailure = false; setFailure = true; assert(poll())
setFailure = false; assert(poll() and saved.offerBadge.pending)
assert(not open() and not saved.offerBadge.pending)
if nativeEngineCode then
    badgeContext.expired = true
    local before = engineReads; badgeContext.timers[1].tick()
    assert(engineReads == before, "Native timer must stop reading when component expires")
end
print("PASS: offer badge baseline/new/unchanged offers, sticky dismissal/removal, mount acknowledgement, GUI persistence/reload/errors, identity-only native timer and scoped toolbar overlay")

-- Auto-decline configuration is a main-thread command. Future suppression is
-- tested in subsidy_recovery_test against the native simulation callbacks.
local loadEnabled = false
local function toggle(value)
    poll() -- Complete any initial saved-preference synchronization.
    local tree = render(windowRecipe, windowContext)
    local checkbox = tree.content.children[1].children[3]
    assert(checkbox.kind == 'CheckBox' and checkbox.value == (loadEnabled and 1 or 0))
    checkbox.onValueChange(value and 1 or 0)
    loadEnabled = value
    poll()
end
reset({offer(1)}, {unrelated = {keep = true}})
commands, archiveCommands, configCommands, loadEnabled = {}, {}, {}, false
assert(not badge())
local waitingTree = render(windowRecipe, windowContext)
local waitingCheckbox = waitingTree.content.children[1].children[3]
assert(waitingCheckbox.meta.enabled == true, 'Waiting must not dim Auto-decline')
assert(waitingCheckbox.label == 'tf3_subsidy_manager_auto_decline_waiting')
assert(waitingCheckbox.meta.tooltip == 'tf3_subsidy_manager_auto_decline_wait_updating')
local configsBefore = #configCommands
waitingCheckbox.onValueChange(1)
assert(#configCommands == configsBefore and not saved.autoDecline, 'A blocked click must not change the setting or send another command')
assert(render(windowRecipe, windowContext).content.children[1].children[3].value == 0)
poll()
waitingCheckbox = render(windowRecipe, windowContext).content.children[1].children[3]
assert(waitingCheckbox.meta.enabled and waitingCheckbox.label == 'tf3_subsidy_manager_auto_decline')
assert(waitingCheckbox.meta.tooltip == 'tf3_subsidy_manager_auto_decline_tooltip')
toggle(true)
assert(saved.autoDecline.enabled and saved.unrelated.keep)
assert(configCommands[#configCommands].enabled == true)
component.state.proposedSubventions = {offer(1), offer(2)}
local before = #configCommands
assert(not poll() and #commands == 0 and #configCommands == before,
    'GUI timer must not issue decline commands or repeatedly configure simulation')
assert(not saved.offerBadge.pending)
toggle(false)
assert(not saved.autoDecline.enabled and configCommands[#configCommands].review == true)
for _, malformed in ipairs({false, {version = 0}, {version = 1, enabled = 'yes', offers = {}},
    {version = 1, enabled = true, offers = {bad = false}}}) do
    reset({offer(10)}, {autoDecline = malformed}); loadEnabled = false
    badge(); poll()
    assert(configCommands[#configCommands].enabled == false, 'Malformed preferences default off')
end
print('PASS: main-thread saved-preference synchronization/configuration, future-only simulation policy, quiet badge and no GUI timer decline commands')

-- Quiet suppression and the explicit review/recovery acknowledgement path.
local function findNode(node, predicate)
    if type(node) ~= 'table' then return nil end
    if predicate(node) then return node end
    for _, key in ipairs({'children', 'layout', 'content', 'buttons'}) do
        local child = node[key]
        if type(child) == 'table' then
            if child.kind then
                local found = findNode(child, predicate); if found then return found end
            else
                for _, item in ipairs(child) do local found = findNode(item, predicate); if found then return found end end
            end
        end
    end
end
local function feedback(tree)
    return findNode(tree, function(n) return n.meta and n.meta.class == 'tf3-subsidy-feedback' end)
end
local function offeredDot(tree)
    return findNode(tree, function(n) return n.meta and n.meta.class == 'tf3-subsidy-offered-dot' end)
end
local function button(tree, text)
    return assert(findNode(tree, function(n) return n.kind == 'Button' and n.content and n.content.text == text end), text)
end
local function tableNode(tree) return assert(findNode(tree, function(n) return n.kind == 'DataTable' end)) end
reset({}, {unrelated = 'keep'}); commands, archiveCommands, loadEnabled = {}, {}, false
cardAvailable, detailEvents = true, {}
assert(not badge()); toggle(true)
component.state.proposedSubventions = {offer(101)}
assert(not poll() and not saved.offerBadge.pending, 'Suppressed offers must not set the toolbar dot')
assert(#commands == 0 and #archiveCommands == 0 and not feedback(render(windowRecipe, windowContext)))
local hidden1, hidden2, manual, expired = offer(101), offer(102), offer(103), offer(104)
for _, r in ipairs({hidden1, hidden2, manual, expired}) do
    r.data.name, r.data.expireDurationProposed = 'Saved contract', 100
end
component.state.proposedSubventions = {}
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {
    {key = '1', record = hidden1, remaining = 50, source = 'automatic', status = 'saved'},
    {key = '2', record = hidden2, remaining = 25, source = 'automatic', status = 'saved'},
    {key = '3', record = manual, remaining = -1, source = 'manual', status = 'saved'},
    {key = '4', record = expired, source = 'automatic', status = 'expired', reason = 'invalid_destination'},
}, response = {sequence = 0}}
local tree = render(windowRecipe, windowContext)
assert(not feedback(tree) and not offeredDot(tree), 'No recovery notice or Offered dot while suppression remains on')
tree.content.children[1].children[3].onValueChange(0); loadEnabled = false
assert(#archiveCommands == 1 and archiveCommands[1].action == 'configure' and archiveCommands[1].review, 'Disabling must request a simulation check')
assert(not feedback(render(windowRecipe, windowContext)), 'Do not announce saved offers before the availability check completes')
component.state.tf3SubsidyManagerArchive.response = {sequence = 1, action = 'configure', enabled = false, review = true, count = 2, success = true, requestId = archiveCommands[1].requestId}
component.state.tf3SubsidyManagerArchive.notice = copy(component.state.tf3SubsidyManagerArchive.response)
poll(); tree = render(windowRecipe, windowContext)
assert(not feedback(tree) and offeredDot(tree).text == ' ●', 'Resume availability belongs on Offered, without a banner')
assert(badge() and saved.offerBadge.pending, 'A confirmed positive missed-offer review must also light the toolbar dot')
local offeredButton = tree.content.children[1].children[1].buttons[2]
assert(offeredButton.content.layout.children[1].text == 'tf3_subsidy_manager_offered (2)')
assert(offeredButton.meta.tooltip == 'tf3_subsidy_manager_hidden_available')
assert(#component.state.proposedSubventions == 0, 'Review must not recreate any offer')
-- The unread Offered marker survives closing/reloading the manager.
boot(); assert(badge() and saved.offerBadge.pending); poll(); tree = render(windowRecipe, windowContext)
assert(offeredDot(tree) and not feedback(tree))
-- Match the normal new-offer badge: successful manager opening clears the
-- toolbar marker, while Offered keeps its separate unread marker until visited.
for _, fn in ipairs(windowContext.mounts) do fn() end
assert(not badge() and not saved.offerBadge.pending)
assert(offeredDot(render(windowRecipe, windowContext)))
tree.content.children[1].children[1].onValueChange(2)
tree = render(windowRecipe, windowContext)
assert(not feedback(tree) and not offeredDot(tree) and saved.archiveAcknowledged == 1 and saved.unrelated == 'keep')
local tableView = tableNode(tree)
assert(#tableView.rowKeys == 2, 'Hidden offers appear automatically; manual declines remain filtered')
assert(tableView.userParam.entries[1].outcome == 'hidden')
tree.content.children[1].children[4].onValueChange(1)
tree = render(windowRecipe, windowContext)
tableView = tableNode(tree)
assert(#tableView.rowKeys == 3 and #tableView.columns == 6)
for i, name in ipairs({'type', 'resource', 'destination', 'requirement', 'reward', 'time'}) do
    assert(tableView.columns[i].name == 'tf3_subsidy_manager_column_' .. name)
    for row = 1, 3 do
        local cell = tableView.columns[i].recipe({userParam = tableView.userParam, rowKey = row})
        assert(cell.children[1].meta.enabled, 'Saved offers must look and select like ordinary new offers in every column')
    end
end
local timeCell = tableView.columns[6].recipe({userParam = tableView.userParam, rowKey = 1})
assert(timeCell.children[1].content.layout.children[1].text == 'Native remaining 50')
timeCell = tableView.columns[6].recipe({userParam = tableView.userParam, rowKey = 3})
assert(timeCell.children[1].content.layout.children[1].text == '—', 'Unlimited saved offers must not use an accepted-task deadline')
local action = tableView.columns[1].recipe({userParam = tableView.userParam, rowKey = 1})
assert(action.children[1].content.layout.children[1].text == 'Saved contract')
action.children[1].onClick()
assert(#archiveCommands == 2 and archiveCommands[2].action == 'recover' and archiveCommands[2].key == '1')
assert(#detailEvents == 0, 'Native details must wait for the simulation confirmation')
local openingCheckbox = render(windowRecipe, windowContext).content.children[1].children[3]
assert(openingCheckbox.meta.enabled and openingCheckbox.label == 'tf3_subsidy_manager_auto_decline_waiting')
assert(openingCheckbox.meta.tooltip == 'tf3_subsidy_manager_auto_decline_wait_opening')
configsBefore = #configCommands
openingCheckbox.onValueChange(1)
assert(#configCommands == configsBefore and not saved.autoDecline.enabled, 'Opening a subsidy must keep the waiting toggle unchanged')
action.children[1].onClick()
assert(#archiveCommands == 2, 'Repeated clicks while opening must not duplicate the request')
-- The snapshot stays unchanged until the simulation confirms recovery.
assert(#tableNode(render(windowRecipe, windowContext)).rowKeys == 3)
component.state.proposedSubventions = {copy(hidden1)}
component.state.proposedSubventions[1].spawnTime = 950
table.remove(component.state.tf3SubsidyManagerArchive.entries, 1)
component.state.tf3SubsidyManagerArchive.response = {sequence = 3, action = 'recover', key = '1', success = true, requestId = archiveCommands[2].requestId}
poll(); tree = render(windowRecipe, windowContext)
assert(not feedback(tree), 'Opening an offer must not show recovery implementation messages')
assert(tree.content.children[1].children[3].label == 'tf3_subsidy_manager_auto_decline')
assert(#detailEvents == 1 and detailEvents[1].nonEntity == 'subsidy_101')
local previousKey = tableView.meta.localKey
tableView = tableNode(tree)
assert(tableView.meta.localKey ~= previousKey and #tableView.rowKeys == 3, 'Acknowledgement must rebuild cells')
-- Recovery failure moves the archived row to History, preserving native failed tasks.
action = tableView.columns[2].recipe({userParam = tableView.userParam, rowKey = 2})
action.children[1].onClick()
assert(archiveCommands[3].key == '2')
component.state.tf3SubsidyManagerArchive.entries[1].status = 'expired'
component.state.tf3SubsidyManagerArchive.entries[1].reason = 'invalid_destination'
component.state.tf3SubsidyManagerArchive.response = {sequence = 4, action = 'recover', key = '2', success = false, reason = 'invalid_destination', requestId = archiveCommands[3].requestId}
poll(); tree = render(windowRecipe, windowContext)
assert(feedback(tree).children[1].text == 'tf3_subsidy_manager_recovery_expired')
assert(#component.state.failedSubventions == 0)
button(tree, 'tf3_subsidy_manager_dismiss').onClick()
tree = render(windowRecipe, windowContext)
tree.content.children[1].children[1].onValueChange(3)
tableView = tableNode(render(windowRecipe, windowContext))
assert(#tableView.rowKeys == 2)
local status = tableView.columns[1].recipe({userParam = tableView.userParam, rowKey = 1})
assert(not status.children[1].meta.enabled)
assert(status.children[1].content.layout.children[1].text == 'tf3_subsidy_manager_expired')
local reason = tableView.columns[5].recipe({userParam = tableView.userParam, rowKey = 1})
assert(reason.children[1].content.layout.children[1].text == 'tf3_subsidy_manager_recovery_reason_invalid_destination')
-- Dismissal persists, and ordinary incoming offers never repeat this notice.
boot(); badge(); assert(not feedback(render(windowRecipe, windowContext)))
component.state.proposedSubventions[#component.state.proposedSubventions + 1] = offer(105)
assert(poll() and not feedback(render(windowRecipe, windowContext)))
-- A missing adapter/late or failed response has bounded pending UI, not false expiry.
toggle(true)
tree = render(windowRecipe, windowContext)
tree.content.children[1].children[3].onValueChange(0); loadEnabled = false
component.state.tf3SubsidyManagerArchive.response.sequence = -1
for _ = 1, 4 do poll() end
tree = render(windowRecipe, windowContext)
assert(feedback(tree).children[1].text == 'tf3_subsidy_manager_configuration_unavailable')
assert(tree.content.children[1].children[3].meta.enabled and tree.content.children[1].children[3].label == 'tf3_subsidy_manager_auto_decline', 'Timeout must release the waiting label and keep the setting readable')
assert(component.state.tf3SubsidyManagerArchive.entries[2].status == 'saved')
print('PASS: quiet suppression, confirmed Offered dot/count, automatic hidden rows, optional manual declines, recovery, refreshed cells, expired History and persisted review acknowledgement')

-- A delayed response from an earlier request must not satisfy its retry.
local staleId = archiveCommands[#archiveCommands].requestId
button(tree, 'tf3_subsidy_manager_retry').onClick()
local retried = archiveCommands[#archiveCommands]
assert(retried.requestId ~= staleId)
component.state.tf3SubsidyManagerArchive.entries[#component.state.tf3SubsidyManagerArchive.entries + 1] = {key = '5', record = offer(106), source = 'automatic', status = 'saved'}
component.state.tf3SubsidyManagerArchive.response = {sequence = 100, action = 'configure', enabled = false, review = true, success = true, count = 1, requestId = staleId}
poll()
assert(not feedback(render(windowRecipe, windowContext)), 'Stale reply must leave the retry pending')
component.state.tf3SubsidyManagerArchive.response.requestId = retried.requestId
poll()
assert(offeredDot(render(windowRecipe, windowContext)) and not feedback(render(windowRecipe, windowContext)))

-- Reviewing while Offered is already selected needs no reminder. A later
-- zero-count review must neither show a banner nor leave a misleading dot.
tree = render(windowRecipe, windowContext)
tree.content.children[1].children[1].onValueChange(2)
loadEnabled = false
toggle(true)
assert(not offeredDot(render(windowRecipe, windowContext)))
toggle(false)
tree = render(windowRecipe, windowContext)
assert(not offeredDot(tree) and not feedback(tree))
assert(saved.archiveAcknowledged == component.state.tf3SubsidyManagerArchive.response.sequence)
assert(#tableNode(tree).rowKeys == #component.state.proposedSubventions + 1, 'Available and hidden offers are visible without Show declined')

-- A reply must not mark the review seen when the Offered snapshot cannot load.
toggle(true)
tree = render(windowRecipe, windowContext)
tree.content.children[1].children[3].onValueChange(0); loadEnabled = false
component.state.tf3SubsidyManagerArchive.response.count = 1
component.state.failedSubventions = 'unreadable'
local reviewSequence = component.state.tf3SubsidyManagerArchive.response.sequence
poll(); tree = render(windowRecipe, windowContext)
assert(saved.archiveAcknowledged < reviewSequence and not offeredDot(tree))
component.state.failedSubventions = {}
tree.content.children[1].children[2].onClick()
assert(saved.archiveAcknowledged == reviewSequence and not offeredDot(render(windowRecipe, windowContext)))

-- An older unread review must stay quiet after re-enabling suppression/reload.
reset({}, {autoDecline = {version = 1, enabled = true, offers = {}}})
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {
    {key = '1', record = offer(200), source = 'automatic', status = 'saved'},
}, automatic = {enabled = true}, response = {sequence = 10},
notice = {sequence = 9, action = 'configure', enabled = false, review = true, success = true, count = 1}}
badge(); poll(); tree = render(windowRecipe, windowContext)
assert(not offeredDot(tree) and not feedback(tree))
assert(tree.content.children[1].children[1].buttons[2].content.text == 'tf3_subsidy_manager_offered (0)')

-- No hidden offers means no dot, even with an old positive review response.
component.state.tf3SubsidyManagerArchive.entries = {}
saved.autoDecline.enabled = false
component.state.tf3SubsidyManagerArchive.automatic.enabled = false
boot(); badge(); poll(); tree = render(windowRecipe, windowContext)
assert(not offeredDot(tree) and not feedback(tree))

-- Saved simulation configuration wins over stale GUI preferences on reload.
reset({}, {autoDecline = {version = 1, enabled = false, offers = {}}})
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {}, automatic = {enabled = true}, response = {sequence = 5}}
badge(); poll()
assert(saved.autoDecline.enabled and configCommands[#configCommands].enabled)

-- Deferred work that outlives its toolbar must not fire events or persist state.
local beforeWrites, beforeCommands = writes, #configCommands
component.state.proposedSubventions = {offer(999)}
restricted = true
badgeContext.timers[1].tick()
restricted = false
badgeContext.expired = true
flushJoins()
assert(writes == beforeWrites and #configCommands == beforeCommands and #forbidden == 0)
-- A legacy success acknowledgement is implementation detail, including when
-- reopening a save whose archive predates the separate notice field.
reset({}, {})
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {}, response = {
    sequence = 200, action = 'recover', key = 'old', success = true,
}}
assert(not feedback(render(windowRecipe, windowContext)))

-- Previously revealed offers are ordinary existing offers across mode changes,
-- Refresh and reload; future suppressed entries must stay out of this list.
reset({offer(300)}, {autoDecline = {version = 1, enabled = false, offers = {}}})
local firstVisible = offer(301)
firstVisible.data.expireDurationProposed = 100
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {
    {key = 'visible', record = firstVisible, remaining = 50, source = 'automatic', status = 'saved'},
}, automatic = {enabled = false}, response = {sequence = 0}}
loadEnabled = false
badge(); poll(); tree = render(windowRecipe, windowContext)
tree.content.children[1].children[1].onValueChange(2)
tree = render(windowRecipe, windowContext)
assert(#tableNode(tree).rowKeys == 2)
tree.content.children[1].children[3].onValueChange(1); loadEnabled = true
assert(#tableNode(render(windowRecipe, windowContext)).rowKeys == 2, 'Enabling must not remove already displayed legacy offers even during confirmation')
poll()
component.state.tf3SubsidyManagerArchive.entries[#component.state.tf3SubsidyManagerArchive.entries + 1] = {
    key = 'future', record = offer(302), remaining = 50, source = 'automatic', status = 'saved',
}
tree = render(windowRecipe, windowContext)
tree.content.children[1].children[2].onClick()
tree = render(windowRecipe, windowContext)
assert(#tableNode(tree).rowKeys == 2 and not offeredDot(tree), 'Refresh must preserve revealed rows without leaking future suppressed offers')
assert(tableNode(tree).userParam.entries[2].recordCopy.uid == 301)
boot(); badge(); poll(); tree = render(windowRecipe, windowContext)
tree.content.children[1].children[1].onValueChange(2)
tree = render(windowRecipe, windowContext)
assert(#tableNode(tree).rowKeys == 2 and not offeredDot(tree), 'Revealed visibility must survive reload with Auto-decline enabled')
local openBefore, requestBefore = #detailEvents, #archiveCommands
tableNode(tree).columns[1].recipe({userParam = tableNode(tree).userParam, rowKey = 2}).children[1].onClick()
assert(#archiveCommands == requestBefore + 1 and archiveCommands[#archiveCommands].key == 'visible')
assert(feedback(render(windowRecipe, windowContext)).children[1].text == 'tf3_subsidy_manager_checking_saved')
component.state.proposedSubventions[#component.state.proposedSubventions + 1] = copy(firstVisible)
component.state.proposedSubventions[2].spawnTime = 950
table.remove(component.state.tf3SubsidyManagerArchive.entries, 1)
local replySequence = component.state.tf3SubsidyManagerArchive.response.sequence + 1
component.state.tf3SubsidyManagerArchive.response = {
    sequence = replySequence, action = 'recover', key = 'visible', success = true,
    requestId = archiveCommands[#archiveCommands].requestId,
}
poll(); tree = render(windowRecipe, windowContext)
assert(#detailEvents == openBefore + 1 and detailEvents[#detailEvents].nonEntity == 'subsidy_301')
assert(#tableNode(tree).rowKeys == 2 and not feedback(tree))

-- A revealed archive-only snapshot must keep the populated window preset on.
component.state.proposedSubventions = {}
component.state.tf3SubsidyManagerArchive.entries[1].revealed = true
boot(); badge(); poll(); tree = render(windowRecipe, windowContext)
assert(tree.meta.class == 'tf3-subsidy-populated')
tree.content.children[1].children[1].onValueChange(2)
tree = render(windowRecipe, windowContext)
tableNode(tree).columns[1].recipe({userParam = tableNode(tree).userParam, rowKey = 1}).children[1].onClick()
component.state.tf3SubsidyManagerArchive.entries[1].status = 'expired'
component.state.tf3SubsidyManagerArchive.entries[1].reason = 'invalid_destination'
component.state.tf3SubsidyManagerArchive.response = {
    sequence = component.state.tf3SubsidyManagerArchive.response.sequence + 1,
    action = 'recover', key = 'future', success = false, reason = 'invalid_destination',
    requestId = archiveCommands[#archiveCommands].requestId,
}
poll(); tree = render(windowRecipe, windowContext)
assert(feedback(tree).children[1].text == 'tf3_subsidy_manager_recovery_expired', 'A revealed offer failure must stay understandable with suppression enabled')
print('PASS: revealed offers persist through enable/Refresh/reload and open normally with suppression enabled; future offers stay hidden and window sizing remains populated')

-- Disabling refreshes immediately, before the later simulation acknowledgement,
-- retaining the selected tab and rebuilding cells with the latest identities.
reset({offer(400)}, {autoDecline = {version = 1, enabled = true, offers = {}}})
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {}, automatic = {enabled = true}, response = {sequence = 0}}
badge(); poll(); tree = render(windowRecipe, windowContext)
tree.content.children[1].children[1].onValueChange(2)
tree = render(windowRecipe, windowContext)
local beforeDisableKey = tableNode(tree).meta.localKey
component.state.proposedSubventions = {offer(401)}
component.state.activeSubventions = {offer(402)}
component.state.completedSubventions = {offer(403)}
component.state.tf3SubsidyManagerArchive.entries = {
    {key = 'missed', record = offer(404), remaining = 50, source = 'automatic', status = 'saved'},
}
tree.content.children[1].children[3].onValueChange(0)
tree = render(windowRecipe, windowContext) -- No poll/confirmation yet.
local tabControl = tree.content.children[1].children[1]
assert(tabControl.selected == 2, 'Auto-refresh must retain the selected tab')
assert(tabControl.buttons[1].content.text == 'tf3_subsidy_manager_active (1)')
assert(tabControl.buttons[2].content.text == 'tf3_subsidy_manager_offered (2)')
assert(tabControl.buttons[3].content.text == 'tf3_subsidy_manager_history (1)')
local automaticTable = tableNode(tree)
assert(automaticTable.meta.localKey ~= beforeDisableKey)
assert(#automaticTable.rowKeys == 2 and automaticTable.userParam.entries[1].recordCopy.uid == 401 and automaticTable.userParam.entries[2].recordCopy.uid == 404)
local confirmationKey = automaticTable.meta.localKey
component.state.tf3SubsidyManagerArchive.entries[1].status = 'expired'
component.state.tf3SubsidyManagerArchive.entries[1].reason = 'invalid_destination'
poll(); tree = render(windowRecipe, windowContext)
automaticTable = tableNode(tree)
assert(automaticTable.meta.localKey ~= confirmationKey and #automaticTable.rowKeys == 1, 'Confirmed review must refresh again and remove invalid saved offers')
assert(tree.content.children[1].children[1].selected == 2)
local detailCount = #detailEvents
automaticTable.columns[1].recipe({userParam = automaticTable.userParam, rowKey = 1}).children[1].onClick()
assert(#detailEvents == detailCount + 1 and detailEvents[#detailEvents].nonEntity == 'subsidy_401', 'Auto-refreshed cells must select the new record')
print('PASS: immediate disable refresh before confirmation, latest counts/rows, stable tab, rebuilt cells and confirmed review refresh')

-- Toolbar reminders come only from a successful, positive resume review.
reset({}, {unrelated = 'preserve'})
badge(); poll()
local replyListener = badgeContext.events.tf3SubsidyManagerArchiveReply
for _, reply in ipairs({
    {action = 'configure', enabled = false, review = true, success = true, count = 0},
    {action = 'configure', enabled = false, review = true, success = false, count = 2},
    {action = 'review', success = true, reason = 'unavailable', count = 2},
    {action = 'configure', enabled = true, review = false, success = true, count = 2},
    {action = 'configure', enabled = false, review = false, success = true, count = 2},
    {action = 'recover', success = true, count = 2},
    {action = 'review', success = true, count = math.huge},
    {action = 'review', success = true, count = 0/0},
    {action = 'review', success = true, count = 0.5},
}) do
    replyListener('tf3SubsidyManagerArchiveReply', reply)
    assert(not badge() and not saved.offerBadge.pending)
end
setFailure = true
replyListener('tf3SubsidyManagerArchiveReply', {action = 'review', success = true, count = 2})
assert(badge() and not saved.offerBadge.pending, 'A failed save must not hide the in-memory reminder')
setFailure = false
assert(poll() and saved.offerBadge.pending and saved.unrelated == 'preserve', 'Reminder persistence must retry without losing other fields')
reset({}, {autoDecline = {version = 1, enabled = true, offers = {}}})
badge(); poll()
badgeContext.events.tf3SubsidyManagerArchiveReply('tf3SubsidyManagerArchiveReply', {action = 'review', success = true, count = 2})
assert(not badge() and not saved.offerBadge.pending, 'Never raise a missed-offer reminder while suppression is enabled')
print('PASS: toolbar dot for confirmed revealed offers, quiet zero/failed/sync replies, valid counts and persistence retries')
print('PASS: stale acknowledgement rejection, authoritative saved simulation mode and expired-toolbar join cancellation')

-- No toolbar icon is ever mounted: the native Mods controller still owns the
-- configuration/recovery bridge and acknowledgements, with one timer only.
reset({}, {autoDecline = {version = 1, enabled = true, offers = {}}})
render(badgeRecipe, badgeContext)
assert(next(iconContext.events) == nil and next(iconContext.timers) == nil)
local function pollWithoutIcon()
    restricted = true
    local ok, err = pcall(assert(badgeContext.timers[1]).tick)
    restricted = false
    assert(ok, err); assert(#forbidden == 0)
    flushJoins(); render(badgeRecipe, badgeContext)
end
pollWithoutIcon()
badgeContext.events.tf3SubsidyManagerAutoDecline('tf3SubsidyManagerAutoDecline', false)
pollWithoutIcon()
assert(saved.autoDecline.enabled == false and component.state.tf3SubsidyManagerArchive.automatic.enabled == false)
assert(not next(iconContext.events), 'Test accidentally mounted the toolbar icon')
badgeContext.events.tf3SubsidyManagerArchiveRequest('tf3SubsidyManagerArchiveRequest', {action = 'recover', key = 'saved-offer', sequence = component.state.tf3SubsidyManagerArchive.response.sequence})
assert(archiveCommands[#archiveCommands].action == 'recover' and archiveCommands[#archiveCommands].key == 'saved-offer')
print('PASS: native Mods controller configures and requests recovery without a toolbar icon or duplicate timer')
