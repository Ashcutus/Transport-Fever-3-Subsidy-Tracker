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
local commands, archiveCommands, commandFailure = {}, {}, false
local saved, component, writes, cardReads, engineReads = nil, nil, 0, 0, 0
local getFailure, setFailure, engineFailure, unavailable = false, false, false, false
local function world(offers)
    return {state = {proposedSubventions = offers, activeSubventions = {}, completedSubventions = {}, failedSubventions = {}}}
end
local function context() return {refs = {}, states = {}, events = {}, mounts = {}, timers = {}} end
local badgeContext, windowContext, activeContext
local badgeRecipe, windowRecipe, toolbar, replacements, builtin, react
local function boot()
    badgeContext, windowContext, replacements = context(), context(), {}
    builtin = {type = {Orientation = {Horizontal = 1, Vertical = 2}, ImageViewScaling = {AutoFit = 1},
        FloatingLayoutOverflowMode = {Overflow = 1}, ScrollBarPolicy = {AlwaysOff = 1, AsNeededButAlwaysReserveSpace = 2}}}
    for _, name in ipairs({"Component", "FloatingLayout", "FloatingLayoutChild", "BoxLayout", "ImageView", "TextView",
        "Window", "ScrollArea", "Button", "ToolButton", "ToggleButtonGroup", "CheckBox", "ColumnDesc", "DataTable"}) do
        builtin[name] = function(...) local args = {...}; local node = args[#args]; node.kind = name; return node end
    end
    react = {}
    function react.RegisterRecipe(_, fn) return fn end
    function react.RegisterWrapperRecipe(name, wrapped, fn)
        if name == "TF3SubsidyManagerOfferBadgeIcon" then
            assert(wrapped == builtin.Component); badgeRecipe = fn
            return function(params) return {kind = "BadgeRecipe", params = params} end
        end
        if name == "TF3SubsidyManagerWindow" then assert(wrapped == builtin.Window); windowRecipe = fn end
        return fn
    end
    function react.CallOriginalRecipe(fn, params) return fn(params) end
    function react.useRefLazy(fn)
        local ctx = activeContext; ctx.refIndex = ctx.refIndex + 1
        if not ctx.refs[ctx.refIndex] then
            ctx.refs[ctx.refIndex] = {value = fn(), get = function(self) return self.value end}
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
    function react.onEvent(name, fn) activeContext.events[name] = fn end
    function react.onMount(fn) activeContext.mounts[#activeContext.mounts + 1] = fn end
    function react.fireEvent(_, name, data)
        local listener = badgeContext.events[name]
        if listener then listener(name, data) end
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
            return {uid = data.uid, action = data.action, key = data.key}
        end,
        sendCommand = function(command)
            if commandFailure then error("command unavailable") end
            if command.action then
                archiveCommands[#archiveCommands + 1] = command
            else commands[#commands + 1] = command end
        end,
    }, type = {ComponentType = {GAME_SCRIPT = 1}}, engine = {
        system = {gameScriptSystem = {getEntityForGameScript = function(path)
            assert(path == "::/game_mechanics/subventions/subventions.gs")
            engineReads = engineReads + 1
            if engineFailure then error("engine unavailable") end
            return unavailable and nil or 123
        end}}, entityExists = function() return not unavailable end,
        getComponent = function(_, kind) assert(kind == 1); return component end,
        forEachEntityWithComponent = function() error("Do not enumerate GAME_SCRIPT") end,
    }, gui = {game = {
        getGuiSaveData = function(id)
            assert(id == "tf3_subsidy_manager")
            if getFailure then error("bad GUI data read") end
            return copy(saved)
        end,
        setGuiSaveData = function(id, data)
            assert(id == "tf3_subsidy_manager")
            if setFailure then error("bad GUI data write") end
            writes = writes + 1; saved = copy(data)
        end,
    }}, res = {genericRep = {find = function() cardReads = cardReads + 1; return -1 end}}}
    local gameBar = {GameBar = function(params) return params end}
    local env = setmetatable({api = api, _ = function(key) return key end, log = {warning = function() end},
        ug_require = function(path)
            if path:find("engine_react_util", 1, true) then return engineReact end
            if path:find("/main/react.lua", 1, true) then return react end
            if path:find("/main/builtin.lua", 1, true) then return builtin end
            if path:find("/game_bar/game_bar.tl", 1, true) then return gameBar end
            if path:find("tool_react_util", 1, true) then
                return {registerToolWithWindow = function(name, _, recipe) return {name = name, recipe = recipe} end}
            end
            return {}
        end,
    }, {__index = _G})
    local exports = assert(load(generated, "subsidy-manager", "t", env))()
    exports.installToolbar({ReplaceRecipe = function(original, replacement) replacements[original] = replacement end})
    local gameCtx = {toolStack = {get = function() return {getApi = function()
        return {push = function() error("Window failed to open") end, pop = function() end}
    end} end}}
    replacements[gameBar.GameBar]({gameCtx = gameCtx})
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
    return recipe({})
end
local function badge()
    local node = render(badgeRecipe, badgeContext)
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
    local timer = assert(badgeContext.timers[1]); timer.tick()
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

-- Auto-decline shares the native timer and only acts on future valid proposed offers.
local loadEnabled = false
local function toggle(value)
    local tree = render(windowRecipe, windowContext)
    local checkbox = tree.content.children[1].children[3]
    assert(tree.content.children[1].children[2].kind == "Button", "Toggle follows Refresh on the same row")
    assert(checkbox.kind == "CheckBox" and checkbox.value == (loadEnabled and 1 or 0))
    assert(checkbox.meta.tooltip == "tf3_subsidy_manager_auto_decline_tooltip")
    checkbox.onValueChange(value and 1 or 0)
    loadEnabled = value
    if not value and #archiveCommands > 0 then
        component.state.tf3SubsidyManagerArchive = {version = 1, entries = {}, response = {sequence = #archiveCommands, action = "review", count = 0}}
        poll()
    end
end
reset({offer(1)}, {unrelated = {keep = true}}); commands = {}; loadEnabled = false
assert(not badge()); poll(); assert(#commands == 0)
toggle(true); assert(saved.autoDecline.enabled and saved.unrelated.keep)
poll(); assert(#commands == 0, "Existing offers must survive enabling")
component = world({offer(1), offer(2), offer(-1), offer(0/0), offer(3, "", 100)})
component.state.activeSubventions = {offer(8)}
local beforeCards = cardReads
poll(); assert(#commands == 1 and commands[1].uid == 2 and cardReads == beforeCards)
poll(); assert(#commands == 1, "Do not repeatedly send while engine delivery is pending")
-- Opening/acknowledging the badge must not erase the separate auto-decline baseline.
component = world({offer(1), offer(2), offer(4)})
open(); poll(); assert(#commands == 2 and commands[2].uid == 4)
boot(); badge(); poll(); assert(#commands == 2, "Persist dispatched identities across reload")
toggle(false); component = world({offer(5)}); poll(); assert(#commands == 2)
toggle(true); poll(); assert(#commands == 2, "Re-enabling establishes a fresh baseline")
component = world({offer(5), offer(6)}); commandFailure = true
poll(); assert(#commands == 2)
commandFailure = false; poll(); assert(#commands == 3 and commands[3].uid == 6)
setFailure = true; toggle(false); assert(saved.autoDecline.enabled)
setFailure = false; poll(); assert(not saved.autoDecline.enabled, "Retry saving disabled preference")
-- Failed enable reads baseline the first valid result instead of declining existing offers.
engineFailure = true; toggle(true); poll(); engineFailure = false
component = world({offer(7)}); poll(); assert(#commands == 3)
component = world({offer(7), offer(9)}); poll(); assert(#commands == 4 and commands[4].uid == 9)
for _, malformed in ipairs({false, {version = 0}, {version = 1, enabled = "yes", offers = {}},
    {version = 1, enabled = true, offers = {bad = false}}}) do
    reset({offer(10)}, {autoDecline = malformed}); loadEnabled = false
    badge(); poll(); assert(#commands == 4, "Malformed preferences default off")
    toggle(false)
end
print("PASS: auto-decline default off, future-only commands, validation, no duplicate dispatch, independent acknowledgement, reload, disable/re-enable, command/save/query failures")

-- Quiet suppression and the explicit review/recovery acknowledgement path.
local function findNode(node, predicate)
    if type(node) ~= 'table' then return nil end
    if predicate(node) then return node end
    for _, key in ipairs({'children', 'layout', 'content'}) do
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
local function button(tree, text)
    return assert(findNode(tree, function(n) return n.kind == 'Button' and n.content and n.content.text == text end), text)
end
local function tableNode(tree) return assert(findNode(tree, function(n) return n.kind == 'DataTable' end)) end
reset({}, {unrelated = 'keep'}); commands, archiveCommands, loadEnabled = {}, {}, false
assert(not badge()); toggle(true)
component.state.proposedSubventions = {offer(101)}
assert(not poll() and not saved.offerBadge.pending, 'Suppressed offers must not set the toolbar dot')
assert(#commands == 1 and #archiveCommands == 0 and not feedback(render(windowRecipe, windowContext)))
local hidden1, hidden2, manual, expired = offer(101), offer(102), offer(103), offer(104)
for _, r in ipairs({hidden1, hidden2, manual, expired}) do r.data.name = 'Saved contract' end
component.state.proposedSubventions = {}
component.state.tf3SubsidyManagerArchive = {version = 1, entries = {
    {key = '1', record = hidden1, source = 'automatic', status = 'saved'},
    {key = '2', record = hidden2, source = 'automatic', status = 'saved'},
    {key = '3', record = manual, source = 'manual', status = 'saved'},
    {key = '4', record = expired, source = 'automatic', status = 'expired', reason = 'invalid_destination'},
}, response = {sequence = 0}}
local tree = render(windowRecipe, windowContext)
assert(not feedback(tree), 'No recovery notice while suppression remains on')
tree.content.children[1].children[3].onValueChange(0); loadEnabled = false
assert(#archiveCommands == 1 and archiveCommands[1].action == 'review', 'Disabling must request a simulation check')
assert(not feedback(render(windowRecipe, windowContext)), 'Do not announce saved offers before the availability check completes')
component.state.tf3SubsidyManagerArchive.response = {sequence = 1, action = 'review', count = 2, success = true}
poll(); tree = render(windowRecipe, windowContext)
assert(feedback(tree).children[1].text == 'tf3_subsidy_manager_hidden_available')
assert(#component.state.proposedSubventions == 0, 'Review must not recreate any offer')
button(tree, 'tf3_subsidy_manager_review_offers').onClick()
tree = render(windowRecipe, windowContext)
assert(not feedback(tree) and saved.archiveAcknowledged == 1 and saved.unrelated == 'keep')
local tableView = tableNode(tree)
assert(#tableView.rowKeys == 3 and #tableView.columns == 6)
assert(tableView.columns[1].name == 'tf3_subsidy_manager_column_status')
local actionColumn = tableView.columns[6]
assert(actionColumn.name == 'tf3_subsidy_manager_column_action')
local action = actionColumn.recipe({userParam = tableView.userParam, rowKey = 1})
assert(action.children[1].meta.enabled and action.children[1].content.layout.children[1].text == 'tf3_subsidy_manager_recover')
action.children[1].onClick()
assert(#archiveCommands == 2 and archiveCommands[2].action == 'recover' and archiveCommands[2].key == '1')
-- The snapshot stays unchanged until the simulation confirms recovery.
assert(#tableNode(render(windowRecipe, windowContext)).rowKeys == 3)
component.state.proposedSubventions = {copy(hidden1)}
table.remove(component.state.tf3SubsidyManagerArchive.entries, 1)
component.state.tf3SubsidyManagerArchive.response = {sequence = 2, action = 'recover', key = '1', success = true}
poll(); tree = render(windowRecipe, windowContext)
assert(feedback(tree).children[1].text == 'tf3_subsidy_manager_recovered')
local previousKey = tableView.meta.localKey
tableView = tableNode(tree)
assert(tableView.meta.localKey ~= previousKey and #tableView.rowKeys == 3, 'Acknowledgement must rebuild cells')
-- Recovery failure moves the archived row to History, preserving native failed tasks.
action = tableView.columns[6].recipe({userParam = tableView.userParam, rowKey = 2})
action.children[1].onClick()
assert(archiveCommands[3].key == '2')
component.state.tf3SubsidyManagerArchive.entries[1].status = 'expired'
component.state.tf3SubsidyManagerArchive.entries[1].reason = 'invalid_destination'
component.state.tf3SubsidyManagerArchive.response = {sequence = 3, action = 'recover', key = '2', success = false, reason = 'invalid_destination'}
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
for _ = 1, 4 do poll() end
tree = render(windowRecipe, windowContext)
assert(feedback(tree).children[1].text == 'tf3_subsidy_manager_recovery_unavailable')
assert(component.state.tf3SubsidyManagerArchive.entries[2].status == 'saved')
print('PASS: quiet suppression/no dot, review only when resuming flow, async confirmation, Show declined/status/recover, refreshed cells, expired History/reasons, persisted dismissal and bounded transient-error feedback')
