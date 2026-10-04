-- Run from the repository root with Lua 5.3+ and TEAL_DIR pointing to a Teal checkout.
local tealDir = assert(os.getenv("TEAL_DIR"), "Set TEAL_DIR to a Teal checkout")
package.path = tealDir .. "/?.lua;" .. tealDir .. "/?/init.lua;" .. package.path
local ok, tl = pcall(require, "teal.api.v2")
if not ok then tl = require("tl") end
local file = assert(io.open("mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/main.script.tl"))
local generated, result = tl.gen(file:read("*a"))
file:close()
assert(#result.syntax_errors == 0, "Teal syntax errors")
assert(generated)

local source = "::/game_mechanics/subventions/subventions.gs"
local warnings, queue, mounts, timers, states, refs = {}, {}, {}, {}, {}, {}
local stateIndex, refIndex, reads = 0, 0, 0
local component, entity, exists, readFailure = nil, 123, true, false
local visible, mounted, added = true, false, 0
local translations = {
    copilot_subsidy_manager_progress = "%g / %g transported  |  %.0f%%",
}
local function translate(key)
    assert(type(key) == "string")
    return translations[key] or key
end
local function flush()
    while #queue > 0 do
        local current = queue
        queue = {}
        for _, fn in ipairs(current) do fn() end
    end
end
local windowRecipe
local react = {}
function react.RegisterWrapperRecipe(_, _, fn) windowRecipe = fn; return fn end
function react.RegisterPluginRecipe(_, _, fn) return fn end
local function state(value)
    return {value = value, old = function(self) return self.value end,
        set = function(self, nextValue) self.value = nextValue end}
end
function react.useStateLazy(fn)
    stateIndex = stateIndex + 1
    if not states[stateIndex] then states[stateIndex] = state(fn()) end
    return states[stateIndex]
end
function react.useState(value) return react.useStateLazy(function() return value end) end
function react.useRef(value)
    refIndex = refIndex + 1
    if not refs[refIndex] then
        refs[refIndex] = state(value)
        refs[refIndex].get = refs[refIndex].old
        refs[refIndex].hasExpired = function() return false end
    end
    return refs[refIndex]
end
function react.onMount(fn) mounts[#mounts + 1] = fn end
function react.onStepTimer(fn) timers[#timers + 1] = fn end
function react.enqueueJoin(fn) queue[#queue + 1] = fn end
local builtin = {type = {Orientation = {Vertical = 1, Horizontal = 2}, ImageViewScaling = {AutoFit = 1}}}
for _, name in ipairs({"TextView", "BoxLayout", "Button", "ImageView", "Window"}) do
    builtin[name] = function(params) params.kind = name; return params end
end
local windowApi = {addSingletonWindow = function(fn)
    added = added + 1
    -- TF3 updates React state here; the native widget is not mounted yet.
    queue[#queue + 1] = function()
        stateIndex = 0
        fn({})
        mounted = true
        for _, onMount in ipairs(mounts) do onMount() end
        mounts = {}
    end
end}
local api = {
    type = {ComponentType = {GAME_SCRIPT = 1}},
    engine = {
        system = {gameScriptSystem = {getEntityForGameScript = function(name)
            reads = reads + 1
            assert(name == source)
            if readFailure then error("engine not ready") end
            return entity
        end}},
        entityExists = function(id) assert(id == entity); return exists end,
        getComponent = function(id, kind) assert(id == entity and kind == 1); return component end,
        forEachEntityWithComponent = function() error("Cannot loop over this component type") end,
    },
    gui = {byId = {
        setVisible = function(_, nextVisible) assert(mounted, "visibility before mount"); visible = nextVisible end,
        isVisible = function() return visible end,
    }},
}
local env = setmetatable({api = api, _ = translate,
    log = {warning = function(message) warnings[#warnings + 1] = message end},
    ug_require = function(path)
        if path:find("react.lua", 1, true) then return react end
        if path:find("builtin.lua", 1, true) then return builtin end
        if path:find("game_react_globals", 1, true) then
            return {getDefaultWindowApi = function() return windowApi end}
        end
        return {}
    end,
}, {__index = _G})
local exports = assert(load(generated, "subsidy-manager", "t", env))()
local function render()
    stateIndex = 0
    mounts = {}
    return windowRecipe({})
end
local function reset(nextComponent)
    component = nextComponent
    entity, exists, readFailure = 123, true, false
    states, mounts = {}, {}
end
local function content(tree) return tree.content.children[2] end
local function clickTab(tree, index) tree.content.children[1].children[index].onClick() end
local function refresh(tree) tree.content.children[1].children[4].onClick() end
local function record(name, delivered, required)
    return {data = {name = name, delivered = delivered, toDeliver = required}}
end
local function validState()
    return {state = {proposedSubventions = {record("offer", 0, 10)},
        activeSubventions = {record("active", 5, 10)},
        completedSubventions = {record("complete", 10, 10)},
        failedSubventions = {record("failed", 2, 10)}}}
end

reset(validState())
local tree = render()
assert(content(tree).children[1].text == "active\n5 / 10 transported  |  50%")
local before = reads
render()
assert(reads == before, "render reread engine state")
component.state.activeSubventions[1].data.delivered = 9
assert(content(render()).children[1].text:find("5 / 10", 1, true), "snapshot retained engine table")
refresh(tree)
assert(content(render()).children[1].text:find("9 / 10", 1, true))
clickTab(tree, 2)
assert(content(render()).children[1].text:find("offer", 1, true))
clickTab(tree, 3)
tree = render()
assert(content(tree).children[1].text:find("copilot_subsidy_manager_completed", 1, true))
assert(content(tree).children[2].text:find("copilot_subsidy_manager_failed", 1, true))

for _, value in ipairs({false, {}, {state = 7},
    {state = {proposedSubventions = {}, activeSubventions = false}},
    {state = {proposedSubventions = {}, activeSubventions = {}, failedSubventions = 42}}}) do
    reset(value)
    assert(content(render()).text == "copilot_subsidy_manager_unavailable")
end
reset(nil)
assert(content(render()).text == "copilot_subsidy_manager_unavailable")
reset(validState()); entity = nil
assert(content(render()).text == "copilot_subsidy_manager_unavailable")
reset(validState()); exists = false
assert(content(render()).text == "copilot_subsidy_manager_unavailable")
reset(validState()); readFailure = true
tree = render()
assert(content(tree).text == "copilot_subsidy_manager_read_error")
assert(warnings[#warnings]:find("engine not ready", 1, true))
readFailure = false; refresh(tree)
assert(content(render()).children[1].text:find("active", 1, true))
reset({state = {proposedSubventions = {}, activeSubventions = {}}})
tree = render()
assert(content(tree).text == "copilot_subsidy_manager_no_active")
clickTab(tree, 3)
assert(content(render()).children[1].text == "copilot_subsidy_manager_no_history")
reset({state = {proposedSubventions = {}, activeSubventions = {
    false, {}, {data = false}, record("", nil, nil), record("decimal", 1.5, 3),
    record("negative", -1, 10), record("infinite", math.huge, 10), record("nan", 0/0, 10),
    record("overflow", 1e308, 1e-308), record("zero", 0, 0),
}}})
tree = render()
assert(#content(tree).children == 10)
assert(content(tree).children[5].text == "decimal\n1.5 / 3 transported  |  50%")
assert(content(tree).children[9].text:find("unknown_progress", 1, true))
assert(content(tree).children[10].text:find("0%%"))

-- Host registration waits for native mounting before hiding; repeated ticks do not add duplicates.
reset(validState())
refs, timers, queue, mounts = {}, {}, {}, {}
refIndex = 0
exports.SubsidyManagerHost()
for _, fn in ipairs(timers) do fn() end
assert(added == 0)
flush()
assert(added == 1 and not visible)
for _, fn in ipairs(timers) do fn() end
flush()
assert(added == 1)
local button = exports.SubsidyManagerButton().children[1]
button.onClick(); assert(visible)
button.onClick(); assert(not visible)
print("PASS: snapshot reads, history, malformed data, refresh recovery, lazy rendering, and window lifecycle")
