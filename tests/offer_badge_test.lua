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
        "Window", "ScrollArea", "Button", "ToolButton", "ToggleButtonGroup", "ColumnDesc", "DataTable"}) do
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
    local api = {type = {ComponentType = {GAME_SCRIPT = 1}}, engine = {
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
