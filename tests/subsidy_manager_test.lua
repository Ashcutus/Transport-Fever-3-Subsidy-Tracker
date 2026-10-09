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
local workerSubsidyId = "::/game_mechanics/subventions/deliver_workers/deliver_workers.res"
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
function react.onMount(_) end -- Mount acknowledgement is exercised by offer_badge_test.lua.
function react.fireEvent(_, name, params) events[#events + 1] = {name = name, params = params} end
function react.RegisterWrapperRecipe(name, wrapped, fn)
    if name == "TF3SubsidyManagerOfferBadgeIcon" then
        assert(wrapped ~= nil)
        return function(params) return {kind = "OfferBadgeIcon", params = params} end
    end
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
for _, name in ipairs({"TextView", "BoxLayout", "Button", "ImageView", "Window", "ProgressBar", "ToolButton", "ScrollArea", "Component", "ToggleButtonGroup", "ColumnDesc", "DataTable"}) do
    builtin[name] = function(...) local args = {...}; local params = args[#args]; params.kind = name
        if name == "ProgressBar" then
            assert(params.text == nil and type(params.label) == "string", "Native ProgressBar uses label, not text")
            assert(params.value >= 0 and params.value <= 1)
        end
        if name == "ScrollArea" then
            assert(params.content and params.content.kind ~= "BoxLayout" and params.content.kind ~= "FloatingLayout",
                "DeferredCellTree child must not be a Layout")
        end
        if name == "DataTable" then
            assert(params.disableSortKey and params.keyboardNavigation == false)
            assert(params.scrollPolicyHorizontal == builtin.type.ScrollBarPolicy.AlwaysOff)
            assert(params.scrollPolicyVertical == builtin.type.ScrollBarPolicy.AsNeededButAlwaysReserveSpace)
            params.children = {}
            for _, rowKey in ipairs(params.rowKeys) do
                local cells = {}
                for colKey, col in ipairs(params.columns) do
                    assert(col.kind == "ColumnDesc" and col.weight > 0)
                    cells[colKey] = col.recipe({rowKey = rowKey, colKey = colKey, userParam = params.userParam})
                    assert(cells[colKey].kind == "BoxLayout", "Native cell recipes must return a layout")
                end
                params.children[#params.children + 1] = {children = cells}
            end
        end
        return params
    end
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
        if recordCopy.data.name == "paused-card" then
            assert(recordCopy.data.migrated == nil, "failed full helper contaminated retry")
            if not lightweight then
                recordCopy.data.migrated = true
                error("map overlay not initialized")
            end
        elseif recordCopy.data.name ~= "broken-card" then
            assert(not lightweight, "complex effects require full card data")
        end
        if recordCopy.data.name == "broken-card" then error("bad card") end
        if recordCopy.data.name == "invalid-card" then return false end
        if recordCopy.data.name == "partial-card" then return {} end
        recordCopy.data.migrated = true -- legacy helpers must only see detached data
        return {title = {name = recordCopy.data.name}, cargoIcons = {"fish.tga"}, cargoToDeliver = recordCopy.data.toDeliver,
            progress = recordCopy.data.nativeProgress,
            location = {to = {77, "Castle Cary"}},
            complete = {{text = "$9.90 M Payment"}, {text = "2x Income for 4 Years 6 Months 1 Day"}},
            failure = {{text = "Actual failure consequence"}},
            expireDuration = {value = 0.5, name = "9 Months"}}
    end
end}
api.res = {cargoTypeRep = {find = function(key) return key == "FISH" and 1 or -1 end,
    get = function(id) assert(id == 1); return {name = "Fish", icon = "fish.tga"} end}, genericRep = {find = function(id) return (id == "real-subsidy" or id == workerSubsidyId) and 1 or -1 end,
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
    local tree = windowRecipe({})
    assert(tree.content.kind == "BoxLayout" and tree.content.meta.class == "tf3-subsidy-content",
        "Every section/fallback must retain the shared window content layout")
    return tree
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
        if child.layout then visit(child.layout) end
        for _, nextChild in ipairs(child.children or {}) do visit(nextChild) end
    end
    visit(node)
    return table.concat(result, "\n")
end
local function content(tree) return tree.content.children[2].content.layout.children[1] end
local function clickTab(tree, index) tree.content.children[1].children[1].onValueChange(index) end
local function refresh(tree) tree.content.children[1].children[2].onClick() end
local function record(name, delivered, required)
    return {data = {name = name, delivered = delivered, toDeliver = required}}
end
local function validState()
    return {state = {proposedSubventions = {record("offer", 0, 10)},
        activeSubventions = {record("active", 5, 10)},
        completedSubventions = {record("complete", 10, 10)},
        failedSubventions = {record("failed", 2, 10)}}}
end

-- Mutation-style boundary check: the reported direct-layout content is rejected.
local accepted, scrollError = pcall(builtin.ScrollArea, {content = builtin.BoxLayout {children = {}}})
assert(not accepted and tostring(scrollError):find("DeferredCellTree child must not be a Layout", 1, true))

reset(validState())
local tree = render()
assert(texts(content(tree).children[1].children[1]) == "active")
assert(texts(content(tree).children[1].children[4]) == "5 / 10")
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
assert(texts(content(tree)):find("tf3_subsidy_manager_no_active", 1, true))
clickTab(tree, 3)
assert(texts(content(render())):find("tf3_subsidy_manager_no_history", 1, true))
reset({state = {proposedSubventions = {}, activeSubventions = {
    false, {}, {data = false}, record("", nil, nil), record("decimal", 1.5, 3),
    record("negative", -1, 10), record("infinite", math.huge, 10), record("nan", 0/0, 10),
    record("overflow", 1e308, 1e-308), record("zero", 0, 0),
}}})
tree = render()
assert(#content(tree).children == 10)
assert(texts(content(tree).children[5].children[4]) == "1.5 / 3")
assert(texts(content(tree).children[9].children[4]) == "—")
assert(content(tree).children[9].children[4].children[1].meta.tooltip == "tf3_subsidy_manager_missing_value_tooltip")
assert(texts(content(tree).children[10].children[4]) == "0 / 0")

-- All tabs must provide component content, including empty Offered and empty History.
reset({state = {proposedSubventions = {}, activeSubventions = {}}})
tree = render()
for index = 1, 3 do
    clickTab(tree, index)
    local emptyTree = render()
    assert(emptyTree.content.children[2].content.kind == "Component")
    local panel = content(emptyTree)
    assert(panel.kind == "Component" and panel.meta.class == "tf3-subsidy-empty-state")
    assert(panel.layout.children[1].path == "tf3_subsidy_manager::/plugins/subsidy_manager/icons/empty_contract_64.tga")
    local suffix = ({"active", "offers", "history"})[index]
    assert(texts(panel):find("tf3_subsidy_manager_empty_" .. suffix .. "_hint", 1, true))
end

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
assert(content(tree).children[2].children[1].children[1].meta.enabled == false)
row.children[1].children[1].onClick()
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
assert(button.content.kind == "OfferBadgeIcon")
assert(added == 0, "window created persistently before user opens it")
button.showFn(); assert(visible and added == 1)
assert(tree.tool == managerTool.name)
button.hideFn(); assert(not visible and not mounted)
button.showFn(); tree.onClose(); assert(not visible and not mounted)
-- Native segmented control state/counts and separate manual Refresh.
reset(validState())
tree = render()
local controls = tree.content.children[1]
local tabs = controls.children[1]
assert(tabs.kind == "ToggleButtonGroup" and tabs.selected == 1 and not tabs.deselectAllowed)
assert(tabs.buttons[1].content.text == "tf3_subsidy_manager_active (1)")
assert(tabs.buttons[2].content.text == "tf3_subsidy_manager_offered (1)")
assert(tabs.buttons[3].content.text == "tf3_subsidy_manager_history (2)")
assert(controls.children[2].kind == "Button" and controls.children[2].meta.class == "secondary")
clickTab(tree, 2); tree = render()
assert(tree.content.children[1].children[1].selected == 2)
assert(content(tree).columns[4].name == "tf3_subsidy_manager_column_requirement")
local oldKey = content(tree).meta.localKey
refresh(tree); tree = render()
assert(content(tree).meta.localKey ~= oldKey, "Refresh must recreate native cells: userParam is only applied to new cells")

-- Fixtures only: 20 active/offered/history rows, native formatting, missing fields.
local large = {state = {activeSubventions = {}, proposedSubventions = {}, completedSubventions = {}, failedSubventions = {}}}
for index = 1, 20 do
    local item = record("Supply Town " .. index, 21, 35)
    item.id, item.uid, item.spawnTime = "real-subsidy", index, 200
    item.data.cargoType, item.data.expireDurationProposed = "FISH", 1000
    large.state.activeSubventions[index] = item
    large.state.proposedSubventions[index] = item
    if index <= 10 then large.state.completedSubventions[index] = item
    else large.state.failedSubventions[index - 10] = item end
end
reset(large); tree = render()
for section = 1, 3 do
    clickTab(tree, section); tree = render()
    local tableView = content(tree)
    assert(#tableView.rowKeys == 20 and #tableView.children == 20 and #tableView.columns == (section == 3 and 5 or 6))
    assert(tableView.columns[1].name == (section == 3 and "tf3_subsidy_manager_column_status" or "tf3_subsidy_manager_column_type"))
    if section == 3 then
        for _, column in ipairs(tableView.columns) do
            assert(column.name ~= "tf3_subsidy_manager_column_result")
        end
    end
    local first = tableView.children[1]
    local resourceColumn = section == 3 and 3 or 2
    assert(texts(first.children[resourceColumn]) == "Fish")
    assert(texts(first):find("Castle Cary", 1, true))
    assert(texts(first):find("$9.90 M Payment\n2x Income for 4 Years 6 Months 1 Day", 1, true))
    local rewardColumn = 5
    assert(tableView.columns[rewardColumn].weight == 1.75)
    if section ~= 3 then
        assert(tableView.columns[6].weight == tableView.columns[rewardColumn].weight,
            "Rewards must share the original combined width budget with deadlines/expiry")
        assert(first.children[6].children[1].meta.class:find("tf3-subsidy-time-cell", 1, true))
    end
    local rewardCell = first.children[rewardColumn].children[1]
    assert(rewardCell.meta.class:find("tf3-subsidy-reward-cell", 1, true))
    assert(rewardCell.meta.tooltip == "$9.90 M Payment\n2x Income for 4 Years 6 Months 1 Day")
    assert(texts(first.children[rewardColumn]) == rewardCell.meta.tooltip,
        "Reward values and durations must remain complete, on separate lines")
    for _, row in ipairs(tableView.children) do
        for _, cell in ipairs(row.children) do
            cell.children[1].onClick()
            assert(events[#events].name == "selectViewKey")
        end
    end
    if section == 1 then assert(texts(first.children[4]) == "21 / 35") end
    if section == 2 then
        assert(texts(first.children[4]) == "35")
        assert(texts(first.children[6]) == "Native duration: 700")
    end
    if section == 3 then
        assert(texts(tableView.children[11].children[1]) == "tf3_subsidy_manager_failed")
        assert(texts(tableView.children[11].children[5]) == "Actual failure consequence")
        assert(not texts(tableView.children[11]):find("$9.90", 1, true))
    end
end
-- Native non-count progress, partial helper data and invalid helper output.
reset(validState())
local native = component.state.activeSubventions[1]
native.id, native.uid, native.data.nativeProgress = "real-subsidy", 71, {value = 0.6, text = "Workers"}
local partial = record("partial-card", nil, nil)
partial.id, partial.uid = "real-subsidy", 72
local invalid = record("invalid-card", 2, 5)
invalid.id, invalid.uid = "real-subsidy", 73
component.state.activeSubventions[2], component.state.activeSubventions[3] = partial, invalid
tree = render()
local progress = content(tree).children[1].children[4].children[1].content.layout.children[1]
assert(progress.kind == "ProgressBar" and progress.value == 0.6 and progress.label == "Workers")
assert(texts(content(tree).children[2].children[2]) == "—")
assert(texts(content(tree).children[2].children[5]) == "—")
assert(content(tree).children[3].children[1].children[1].meta.enabled == false)
native.data.nativeProgress.value = math.huge
refresh(tree); tree = render()
assert(texts(content(tree).children[1].children[4]) == "5 / 10")
-- Only Transport Workers gets numeric native boost progress, without invented counts.
reset(validState())
local workers = record("Transport Workers", nil, nil)
workers.id, workers.uid = workerSubsidyId, 74
component.state.activeSubventions = {workers}
tree = render()
for _, case in ipairs({{0.0, "0% Workers"}, {0.125, "12.5% Workers"}, {0.6, "60% Workers"}, {1.0, "100% Workers"}}) do
    workers.data.nativeProgress = {value = case[1], text = "Workers"}
    refresh(tree); tree = render()
    local cell = content(tree).children[1].children[4].children[1]
    local bar = cell.content.layout.children[1]
    assert(bar.kind == "ProgressBar" and bar.value == case[1] and bar.label == case[2])
    assert(cell.meta.tooltip == case[2])
    assert(workers.data.delivered == nil and workers.data.toDeliver == nil and workers.data.migrated == nil)
end
for _, invalidProgress in ipairs({{}, {value = 0.6}, {text = "Workers"}, {value = false, text = "Workers"}, {value = "0.6", text = "Workers"},
    {value = -0.1, text = "Workers"}, {value = 1.1, text = "Workers"},
    {value = math.huge, text = "Workers"}, {value = -math.huge, text = "Workers"}, {value = 0/0, text = "Workers"}}) do
    workers.data.nativeProgress = invalidProgress
    refresh(tree); tree = render()
    local cell = content(tree).children[1].children[4]
    assert(cell.children[1].content.layout.children[1].kind == "TextView")
    assert(texts(cell) == (invalidProgress.text or "—"))
end
workers.data.nativeProgress = nil
refresh(tree); tree = render()
assert(texts(content(tree).children[1].children[4]) == "—")
-- Unavailable state must not imply known zero counts; corrupt UIDs never dispatch.
-- Pre-tick full-card failure retains genuine native zero/nonzero progress.
reset(validState())
local paused = record("paused-card", nil, nil)
paused.id, paused.uid, paused.acceptedTime = workerSubsidyId, 75, 0
component.state.activeSubventions = {paused}
for _, value in ipairs({0, 0.25}) do
    paused.data.nativeProgress = {value = value, text = "Workers"}
    tree = render()
    refresh(tree); tree = render()
    local cell = content(tree).children[1].children[4].children[1]
    local bar = cell.content.layout.children[1]
    assert(bar.kind == "ProgressBar" and bar.value == value)
    assert(bar.label == string.format("%g%% Workers", value * 100))
    assert(paused.data.migrated == nil and paused.acceptedTime == 0)
end
-- The same recovery covers count-based tasks; both failing paths stay unavailable.
paused.id, paused.data.nativeProgress = "real-subsidy", {value = 0, text = "0 / 10"}
refresh(tree); tree = render()
assert(texts(content(tree).children[1].children[4]) == "0 / 10")
paused.data.name = "broken-card"
refresh(tree); tree = render()
assert(texts(content(tree).children[1].children[4]) == "—")
reset(nil); tree = render()
assert(tree.content.children[1].children[1].buttons[1].content.text == "tf3_subsidy_manager_active")
for _, uid in ipairs({math.huge, 0/0, -1, 1.5}) do
    reset(validState())
    local item = component.state.activeSubventions[1]
    item.id, item.uid = "real-subsidy", uid
    tree = render()
    local cell = content(tree).children[1].children[1].children[1]
    assert(cell.meta.enabled == false)
    local eventCount = #events
    cell.onClick()
    assert(#events == eventCount, "Invalid subsidy UID dispatched native detail")
end
-- Refresh then select must use the new detached record.
reset(validState())
local item = component.state.activeSubventions[1]
item.id, item.uid = "real-subsidy", 80
tree = render()
item.uid, item.data.delivered = 81, 7
refresh(tree); tree = render()
content(tree).children[1].children[1].children[1].onClick()
assert(events[#events].params.nonEntity == "subsidy_81")
assert(events[#events].params.extraParam.data.delivered == 7)
assert(button.meta.class == "tf3-subsidy-toolbar" and button.toolDefinition == managerTool)
-- Size follows the whole detached snapshot, never the selected tab.
reset({state = {activeSubventions = {}, proposedSubventions = {}, completedSubventions = {}, failedSubventions = {}}})
tree = render()
for section = 1, 3 do
    clickTab(tree, section); tree = render()
    assert(tree.meta.class == "tf3-subsidy-empty")
end
component.state.proposedSubventions[1] = record("offer", 0, 10)
assert(render().meta.class == "tf3-subsidy-empty", "Engine changes must not resize without Refresh")
refresh(tree); tree = render()
for section = 1, 3 do
    clickTab(tree, section); tree = render()
    assert(tree.meta.class == "tf3-subsidy-populated", "An empty selected tab must retain the snapshot's table size")
end
component.state.proposedSubventions = {}
refresh(tree); assert(render().meta.class == "tf3-subsidy-empty")
for _, collection in ipairs({"activeSubventions", "proposedSubventions", "completedSubventions", "failedSubventions"}) do
    local only = {state = {activeSubventions = {}, proposedSubventions = {}, completedSubventions = {}, failedSubventions = {}}}
    only.state[collection][1] = record("only record", 0, 10)
    reset(only); tree = render()
    for section = 1, 3 do
        clickTab(tree, section); assert(render().meta.class == "tf3-subsidy-populated")
    end
end
reset(nil); assert(render().meta.class == "tf3-subsidy-empty")
reset(validState()); readFailure = true
assert(render().meta.class == "tf3-subsidy-empty")
print("PASS: snapshots, partial/nonfinite data, native table cells/20-row fixtures, tabs/counts, refresh, detail selection, toolbar refs and lifecycle")
