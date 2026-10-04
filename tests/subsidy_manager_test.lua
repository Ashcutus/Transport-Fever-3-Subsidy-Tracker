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
local warnings, states = {}, {}
local stateIndex, reads = 0, 0
local component, entity, exists, readFailure = nil, 123, true, false
local visible, mounted, added = true, false, 0
local translations = {
    tf3_subsidy_manager_progress = "%g / %g transported  |  %.0f%%",
}
local function translate(key)
    assert(type(key) == "string")
    return translations[key] or key
end
local windowRecipe, managerTool
local events, replacements = {}, {}
local gameBar = { GameBar = function(params) return {kind = "GameBar", params = params} end }
local react = {}
function react.RegisterRecipe(_, fn)
    return function(...)
        local node = fn(...)
        assert(node.kind == "BoxLayout" or node.kind == "FloatingLayout", "Recipe child must be a layout")
        return node
    end
end
function react.CallOriginalRecipe(fn, params) return fn(params) end
function react.fireEvent(_, name, params) events[#events + 1] = {name = name, params = params} end
function react.RegisterWrapperRecipe(name, wrapped, fn)
    if name == "TF3SubsidyManagerWindow" then windowRecipe = fn end
    if name == "TF3SubsidyManagerGameBar" then
        assert(wrapped == gameBar.GameBar, "GameBar wrapper must preserve the native recipe metadata")
    end
    return fn
end
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
local builtin = {type = {Orientation = {Vertical = 1, Horizontal = 2}, ImageViewScaling = {AutoFit = 1}, ScrollBarPolicy = {AlwaysOff = 1, AsNeededButAlwaysReserveSpace = 2}}}
for _, name in ipairs({"TextView", "BoxLayout", "Button", "ImageView", "Window", "ProgressBar", "ToolButton", "ScrollArea"}) do
    builtin[name] = function(...) local args = {...}; local params = args[#args]; params.kind = name; return params end
end
local api = {
    type = {ComponentType = {GAME_SCRIPT = 1, GAME_TIME = 2, GAME_SPEED = 3}},
    engine = {
        util = {getWorld = function() return 999 end},
        system = {gameScriptSystem = {getEntityForGameScript = function(name)
            reads = reads + 1
            assert(name == source)
            if readFailure then error("engine not ready") end
            return entity
        end}},
        entityExists = function(id) assert(id == entity); return exists end,
        getComponent = function(id, kind)
            if id == 999 and kind == 2 then return {gameTime = 500} end
            if id == 999 and kind == 3 then return {millisPerDay = 100} end
            assert(id == entity and kind == 1); return component
        end,
        forEachEntityWithComponent = function() error("Cannot loop over this component type") end,
    },
    gui = {byId = {
        setVisible = function(_, nextVisible) assert(mounted, "visibility before mount"); visible = nextVisible end,
        isVisible = function() return visible end,
    }},
}
local toolUtil = {registerToolWithWindow = function(name, id, recipe)
    managerTool = {name = name, recipe = recipe, id = id}
    return managerTool
end}
local util = {formatDurationWithCurrentCalenderSpeed = function(duration, millisPerDay)
    assert(millisPerDay == 100)
    return "Native duration: " .. duration
end, useFn = function(path)
    assert(path == "subsidy.script.getCardData")
    return function(recordCopy, lightweight)
        assert(not lightweight, "complex effects require full card data")
        if recordCopy.data.name == "broken-card" then error("bad card") end
        recordCopy.data.migrated = true -- legacy helpers must only see detached data
        return {title = {name = recordCopy.data.name}, cargoIcons = {"fish.tga"}, cargoToDeliver = 30,
            location = {to = {77, "Castle Cary"}},
            complete = {{text = "$9.90 M Payment"}, {text = "2x Income for 4 Years 6 Months 1 Day"}},
            failure = {{text = "Actual failure consequence"}},
            expireDuration = {value = 0.5, name = "9 Months"}}
    end
end}
api.res = {genericRep = {find = function(id) return id == "real-subsidy" and 1 or -1 end,
    get = function() return {data = {scriptFile = "subsidy.script"}} end}}
local env = setmetatable({api = api, _ = translate,
    log = {warning = function(message) warnings[#warnings + 1] = message end},
    ug_require = function(path)
        if path:find("tool_react_util", 1, true) then return toolUtil end
        if path:find("game_bar.tl", 1, true) then return gameBar end
        if path:find("lang_util.tl", 1, true) then return {formatInt = tostring} end
        if path:find("/scripts/util.tl", 1, true) then return util end
        if path:find("react.lua", 1, true) then return react end
        if path:find("builtin.lua", 1, true) then return builtin end
        return {}
    end,
}, {__index = _G})
local exports = assert(load(generated, "subsidy-manager", "t", env))()
local function render()
    stateIndex = 0
    return windowRecipe({})
end
local function reset(nextComponent)
    component = nextComponent
    entity, exists, readFailure = 123, true, false
    states = {}
end
local function texts(node)
    local result = {}
    local function visit(child)
        if child.text then result[#result + 1] = child.text end
        if child.label then result[#result + 1] = child.label end
        if child.content then visit(child.content) end
        for _, nextChild in ipairs(child.children or {}) do visit(nextChild) end
    end
    visit(node)
    return table.concat(result, "\n")
end
local function content(tree) return tree.content.children[2].content end
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
assert(texts(content(tree).children[1]) == "active\n5 / 10 transported  |  50%")
local before = reads
render()
assert(reads == before, "render reread engine state")
component.state.activeSubventions[1].data.delivered = 9
assert(texts(content(render()).children[1]):find("5 / 10", 1, true), "snapshot retained engine table")
refresh(tree)
assert(texts(content(render()).children[1]):find("9 / 10", 1, true))
clickTab(tree, 2)
assert(texts(content(render()).children[1]):find("offer", 1, true))
clickTab(tree, 3)
tree = render()
assert(texts(content(tree).children[1]):find("tf3_subsidy_manager_completed", 1, true))
assert(texts(content(tree).children[2]):find("tf3_subsidy_manager_failed", 1, true))

for _, value in ipairs({false, {}, {state = 7},
    {state = {proposedSubventions = {}, activeSubventions = false}},
    {state = {proposedSubventions = {}, activeSubventions = {}, failedSubventions = 42}}}) do
    reset(value)
    assert(content(render()).text == "tf3_subsidy_manager_unavailable")
end
reset(nil)
assert(content(render()).text == "tf3_subsidy_manager_unavailable")
reset(validState()); entity = nil
assert(content(render()).text == "tf3_subsidy_manager_unavailable")
reset(validState()); exists = false
assert(content(render()).text == "tf3_subsidy_manager_unavailable")
reset(validState()); readFailure = true
tree = render()
assert(content(tree).text == "tf3_subsidy_manager_read_error")
assert(warnings[#warnings]:find("engine not ready", 1, true))
readFailure = false; refresh(tree)
assert(texts(content(render()).children[1]):find("active", 1, true))
reset({state = {proposedSubventions = {}, activeSubventions = {}}})
tree = render()
assert(content(tree).text == "tf3_subsidy_manager_no_active")
clickTab(tree, 3)
assert(texts(content(render()).children[1]) == "tf3_subsidy_manager_no_history")
reset({state = {proposedSubventions = {}, activeSubventions = {
    false, {}, {data = false}, record("", nil, nil), record("decimal", 1.5, 3),
    record("negative", -1, 10), record("infinite", math.huge, 10), record("nan", 0/0, 10),
    record("overflow", 1e308, 1e-308), record("zero", 0, 0),
}}})
tree = render()
assert(#content(tree).children == 10)
assert(texts(content(tree).children[5]) == "decimal\n1.5 / 3 transported  |  50%")
assert(texts(content(tree).children[9]):find("unknown_progress", 1, true))
assert(texts(content(tree).children[10]):find("0%%"))

-- Native card dispatch preserves complex effects and isolates legacy helper writes.
reset(validState())
local subsidy = component.state.activeSubventions[1]
subsidy.id, subsidy.uid = "real-subsidy", 42
local failed = component.state.failedSubventions[1]
failed.id, failed.uid = "real-subsidy", 43
local incomplete = record("broken-card", 0, 1)
incomplete.id, incomplete.uid = "real-subsidy", 44
component.state.activeSubventions[2] = incomplete
tree = render()
local row = content(tree).children[1]
assert(texts(row):find("Castle Cary", 1, true))
assert(texts(row):find("2x Income for 4 Years 6 Months 1 Day", 1, true))
assert(texts(row):find("9 Months", 1, true))
assert(not subsidy.data.migrated, "card helper mutated engine record")
assert(content(tree).children[2].meta.enabled == false)
row.onClick()
local event = events[#events]
assert(event.name == "selectViewKey" and event.params.nonEntity == "subsidy_42")
assert(event.params.extraParam ~= subsidy and event.params.extraParam.uid == 42)
event.params.extraParam.data.delivered = 99
assert(subsidy.data.delivered == 5)
clickTab(tree, 3)
assert(texts(content(render()).children[2]):find("Actual failure consequence", 1, true))
assert(not texts(content(render()).children[2]):find("$9.90", 1, true))

-- Proposed expiry uses the actual offered timestamp, never task duration.
reset(validState())
local offered = component.state.proposedSubventions[1]
offered.id, offered.uid, offered.spawnTime = "real-subsidy", 55, 200
offered.data.expireDurationProposed = 1000
tree = render(); clickTab(tree, 2)
assert(texts(content(render()).children[1]):find("Native duration: 700", 1, true))
offered.data.expireDurationProposed = -1
refresh(tree)
assert(not texts(content(render()).children[1]):find("Native duration:", 1, true))
assert(not texts(content(render()).children[1]):find("9 Months", 1, true))

-- Bootstrap installs once; unrelated buttons and refs pass through unchanged.
local oldToolButton = builtin.ToolButton
local toolCalls = {}
builtin.ToolButton = function(...)
    toolCalls[#toolCalls + 1] = {...}
    return oldToolButton(...)
end
local replacementApi = {ReplaceRecipe = function(original, replacement) replacements[original] = replacement end}
exports.installToolbar(replacementApi)
local hooked = builtin.ToolButton
exports.installToolbar(replacementApi)
assert(builtin.ToolButton == hooked)
assert(replacements[gameBar.GameBar])
local toolStack
toolStack = {push = function(tool, _, params)
    assert(tool == managerTool)
    added = added + 1
    stateIndex = 0; states = {}
    tree = tool.recipe({onClose = function() toolStack.pop(tool) end, payload = {toolParam = params}})
    mounted, visible = true, true
end}
function toolStack.pop(tool) assert(tool == managerTool); mounted, visible = false, false end
local gameCtx = {toolStack = {get = function() return {getApi = function() return toolStack end} end}}
replacements[gameBar.GameBar]({gameCtx = gameCtx})
local unrelated = {meta = {id = "menu.fileMenu"}}
assert(builtin.ToolButton(unrelated) == unrelated)
assert(builtin.ToolButton({}, {}, unrelated) == unrelated)
assert(builtin.ToolButton({}, {}, {}, unrelated) == unrelated)
local ref = {}
local industry = {meta = {id = "menu.industry-statistics.button"}, toolStack = gameCtx.toolStack}
local pair = builtin.ToolButton(ref, industry)
assert(toolCalls[#toolCalls - 1][1] == ref and toolCalls[#toolCalls - 1][2] == industry)
assert(pair.children[1] == industry, "native industry button replaced")
local button = pair.children[2]
assert(button.meta.tooltip == "tf3_subsidy_manager_button_tooltip")
assert(button.toolStack == industry.toolStack and button.toolDefinition == managerTool)
assert(button.content.path:find("contract_26.tga", 1, true))
assert(added == 0, "window created persistently before user opens it")
button.showFn(); assert(visible and added == 1)
assert(tree.tool == managerTool.name)
button.hideFn(); assert(not visible and not mounted)
button.showFn(); tree.onClose(); assert(not visible and not mounted)
print("PASS: state reads, malformed data, snapshots, native effects/detail dispatch, toolbar hook, and tool close lifecycle")
