-- Executes TF3's shipped selector parser; native C++ layout/painting stays untested.
-- TF3_STYLESHEETUTIL_LUA=/path/to/gui/main/stylesheetutil.lua lua5.4 tests/tf3_stylesheet_contract_test.lua
local parserPath = assert(os.getenv("TF3_STYLESHEETUTIL_LUA"), "Set TF3_STYLESHEETUTIL_LUA")
local function read(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end
-- Compatibility helpers used by the shipped parser (normally injected by TF3).
function string.split(value, separator)
    local result, start = {}, 1
    while true do
        local at = value:find(separator, start, true)
        if not at then result[#result + 1] = value:sub(start); return result end
        result[#result + 1] = value:sub(start, at - 1); start = at + #separator
    end
end
function string.strip(value) return value:match("^%s*(.-)%s*$") end
function string.ends(value, ending) return value:sub(-#ending) == ending end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for k, v in pairs(value) do result[k] = copy(v) end; return result
end
local parserEnv = setmetatable({require = function(path)
    assert(path == "/scripts/table_util.tl"); return {copy = copy}
end}, {__index = _G})
local ssu = assert(loadfile(parserPath, "t", parserEnv))()
local source = read("mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/toolbar.css.lua")
local function rules(code)
    local env = setmetatable({require = function(path)
        assert(path == "::/gui/main/stylesheetutil.lua"); return ssu
    end}, {__index = _G})
    assert(load(code, "manager-css", "t", env))()
    return env.data()
end
local function levelMatches(level, element, class, id)
    if element and level.element ~= element then return false end
    if id and level.id ~= id then return false end
    if class then
        for _, value in ipairs(level.classList) do if value == class then return true end end
        return false
    end
    return true
end
local function find(list, ancestor, element)
    for _, rule in ipairs(list) do
        local levels = rule.levels
        if #levels == 2 and levelMatches(levels[1], nil, ancestor) and levelMatches(levels[2], element) then return rule.styleSheet end
    end
end
local function stretch(style)
    assert(style and style.gravity and style.gravity[1] == -1 and style.gravity[2] == -1,
        "Native weighted table hierarchy must explicitly stretch")
end
local function validateTable(list)
    stretch(find(list, "tf3-subsidy-table", "Table"))
    stretch(find(list, "tf3-subsidy-table", "Table::Layout"))
    stretch(find(list, "tf3-subsidy-data-region", "R::Component"))
    stretch(find(list, "tf3-subsidy-data-region", "BoxLayout"))
end
local function validatePadding(list)
    for _, rule in ipairs(list) do
        local levels = rule.levels
        if #levels == 2 and levelMatches(levels[1], nil, nil, "tf3-subsidy-manager.window") and levelMatches(levels[2], "Window::Content") then
            local padding = rule.styleSheet.padding
            assert(padding and #padding == 4)
            for _, value in ipairs(padding) do assert(value > 0) end
            return
        end
    end
    error("Inset must target shared native Window::Content, not only a layout")
end
local list = rules(source)
validateTable(list); validatePadding(list)
local buttons, icons = {}, {}
for _, rule in ipairs(list) do
    local levels, style = rule.levels, rule.styleSheet
    if style.size and ((#levels == 3 and levels[3].element == "ToolButton") or
        (#levels == 4 and levels[3].element == "ToolButton" and levels[4].element == "ImageView")) then
        assert(levels[1].element == "R::GameBarMenuRight", "Toolbar size must not affect other game bars")
        local group = levels[2].classList[1]
        assert(group == "statistics" or group == "notifications" or group == "menu")
        assert(style.size[1] == style.size[2], "Square native icons must keep their aspect ratio")
        assert(not style.transform and not style.highlightMask and not style.backgroundImage1, "Preserve native state/surface styling")
        local target = #levels == 3 and buttons or icons; target[group] = style.size[1]
    end
    assert(not style.highlightMask, "Revision 8 checked mask override must be removed")
    if #levels == 2 and levels[1].element == "R::GameBarMenuRight" and levels[2].classList[1] == "statistics" then
        assert(not style.minSize and not style.size, "Do not widen the native tray")
    end
end
for _, group in ipairs({"statistics", "notifications", "menu"}) do
    assert(buttons[group] and buttons[group] == icons[group] and buttons[group] == buttons.statistics)
end
assert(8 * buttons.statistics + 7 * 10 <= 7 * 26 + 6 * 10, "Eight buttons must fit original seven-button logical row")
assert(buttons.statistics < 26 and buttons.statistics >= 20, "Reduce logical size, not physical @2x asset dimensions")
-- Mutation checks: explicitly missing either native requirement is rejected.
local missingTable = {}; for _, rule in ipairs(list) do
    if not (#rule.levels == 2 and rule.levels[2].element == "Table::Layout") then missingTable[#missingTable + 1] = rule end
end
assert(not pcall(validateTable, missingTable))
local missingPadding = {}; for _, rule in ipairs(list) do
    if rule.levels[#rule.levels].element ~= "Window::Content" then missingPadding[#missingPadding + 1] = rule end
end
assert(not pcall(validatePadding, missingPadding))
-- Fixed native presets preserve the populated baseline and shrink empty bodies only.
local baseWindow, emptyWindow, emptyRegion
for _, rule in ipairs(list) do
    local levels = rule.levels
    if levelMatches(levels[1], nil, nil, "tf3-subsidy-manager.window") then
        if #levels == 1 and #levels[1].classList == 0 then baseWindow = rule.styleSheet end
        if #levels == 1 and levels[1].classList[1] == "tf3-subsidy-empty" then emptyWindow = rule.styleSheet end
        if #levels == 2 and levels[1].classList[1] == "tf3-subsidy-empty" and levels[2].classList[1] == "tf3-subsidy-data-region" then emptyRegion = rule.styleSheet end
    end
end
assert(baseWindow and emptyWindow and emptyRegion)
assert(emptyWindow.size[1] < baseWindow.size[1] and emptyWindow.size[2] < baseWindow.size[2])
assert(baseWindow.size[1] == 1180 and baseWindow.size[2] == 640, "Retain UAT-confirmed populated dimensions")
for _, preset in ipairs({baseWindow, emptyWindow}) do
    for axis = 1, 2 do assert(preset.minSize[axis] == preset.size[axis] and preset.maxSize[axis] == preset.size[axis]) end
end
assert(emptyRegion.size[2] > 0 and emptyRegion.size[2] < emptyWindow.size[2])
print("PASS: shipped stylesheet selector parser, table stretch hierarchy, shared widget inset, scoped equal tray sizing and mutation checks")
