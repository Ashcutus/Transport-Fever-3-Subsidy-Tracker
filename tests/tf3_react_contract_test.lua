-- Uses TF3's shipped Lua React implementation; the C++ transform boundary is mocked.
-- TEAL_DIR=/path/to/tl TF3_REACT_LUA=/path/to/extracted/gui/main/react.lua lua5.4 tests/tf3_react_contract_test.lua
local tealDir = assert(os.getenv("TEAL_DIR"), "Set TEAL_DIR to a Teal checkout")
local reactPath = assert(os.getenv("TF3_REACT_LUA"), "Set TF3_REACT_LUA to the shipped React Lua file")
package.path = tealDir .. "/?.lua;" .. package.path
local tl = require("teal.api.v2")
local file = assert(io.open("mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/main.script.tl"))
local source = file:read("*a")
file:close()

local function check(code, expectWrapper)
    local registry = {builtin = {Window = 1, ToolButton = 2, BoxLayout = 3, ImageView = 4, FloatingLayout = 5, WithComponentParams = 6, Button = 7, Component = 8, TextView = 9, ProgressBar = 10, FloatingLayoutChild = 11, ToolStack = 12},
        recipes = {}, recipeMetas = {}, originalRecipeFn = {}, recipeReplace = {}, tools = {}, recipeReplacementAllowed = true, extensionPoints = {}}
    local ids, nextRecipeId, nodes, nextNodeId = {}, 100, {}, 0
    local nativeParams = {}
    for name in pairs(registry.builtin) do nativeParams[name] = {new = function() return {} end} end
    local nativeApi = {gui = {react = {params = {builtin = nativeParams}, detail = {makeRecipeId = function(name)
        if not ids[name] then nextRecipeId = nextRecipeId + 1; ids[name] = nextRecipeId end
        return ids[name]
    end}}}}
    local function format(message, values)
        return (message:gsub("{(.-)}", function(key) return tostring(values[key]) end))
    end
    local logger = {verbose = function() end, warning = function() end, error = function(message) error(message) end}
    local reactEnv = setmetatable({_react = registry, api = nativeApi, log = logger,
        require = function(path) assert(path == "/scripts/string_util.tl"); return {format = format} end,
        ug_require = function(path) assert(path == "/scripts/util.tl"); return {} end,
    }, {__index = _G})
    local react = assert(loadfile(reactPath, "t", reactEnv))()
    local builtin = {type = {Orientation = {Horizontal = 1}, ImageViewScaling = {AutoFit = 1}, FloatingLayoutOverflowMode = {Overflow = 1}}}
    for name in pairs(registry.builtin) do builtin[name] = react.DeclareBuiltin(name, function() end) end
    local originalGameBar = react.RegisterRecipe("GameBar", function() return builtin.FloatingLayout {} end)
    local modEnv = setmetatable({api = nativeApi, log = logger, _ = function(key) return key end,
        ug_require = function(path)
            if path:find("/main/react.lua", 1, true) then return react end
            if path:find("/main/builtin.lua", 1, true) then return builtin end
            if path:find("/game_bar/game_bar.tl", 1, true) then error("Launcher must not load/replace GameBar") end
            if path:find("main_mod_button_area.tl", 1, true) then return {MainModButtonAreaExtension = {id = "::MainModButtonAreaExtension"}} end
            if path:find("engine_react_util", 1, true) then
                return {useStepStateTimer = function(_, interval)
                    assert(interval == 5)
                    return {old = function() return true end, set = function() end}
                end}
            end
            if path:find("/main/tool_react_util.tl", 1, true) then
                return {registerToolWithWindow = function(name) return {name = name} end}
            end
            return {}
        end,
    }, {__index = _G})
    local generated, result = tl.gen(code)
    assert(generated and #result.syntax_errors == 0)
    local exports = assert(load(generated, "subsidy-manager", "t", modEnv))()
    exports.installToolbar({ReplaceRecipe = react.GloballyReplaceRecipeBeforeInitInternal})
    local originalId = react.GetRecipeId(originalGameBar)
    assert(registry.recipeReplace[originalId] == nil, "Launcher must not replace GameBar")
    -- Preserve the historical revision-5 layout mutation as a legacy fixture:
    -- production now avoids GameBar delegation altogether.
    local delegate = function(params) return react.CallOriginalRecipe(originalGameBar, params) end
    local legacy = expectWrapper and react.RegisterWrapperRecipe("LegacyGameBarWrapper", originalGameBar, delegate)
        or react.RegisterRecipe("LegacyGameBarWrapper", delegate)
    react.GloballyReplaceRecipeBeforeInitInternal(originalGameBar, legacy)
    local replacement = assert(registry.recipeReplace[originalId])
    local replacementId = react.GetRecipeId(replacement)
    local metadata = registry.recipeMetas[replacementId]
    assert((metadata ~= nil) == expectWrapper)
    if expectWrapper then assert(metadata.innerRecipeId == originalId) end

    -- The actual Lua React module creates opaque node IDs and calls setResult.
    -- Model the native default-transform rule seen in the user's startup error:
    -- ordinary recipes require layout children; wrappers delegate to their declared recipe.
    local context = {currentRecipeId = nil, result = nil}
    function context:makeNodeWithProps(recipeId, _, props)
        nextNodeId = nextNodeId + 1
        nodes[nextNodeId] = {recipeId = recipeId, props = props}
        return nextNodeId
    end
    function context:checkRecipeMatch(node, recipeId)
        assert(nodes[node].recipeId == recipeId, "Wrapper returned the wrong recipe")
        return true
    end
    function context:setResult(children)
        local inner = registry.recipeMetas[self.currentRecipeId]
        for _, child in ipairs(children or {}) do
            local id = nodes[child].recipeId
            if inner then
                assert(id == inner.innerRecipeId, "Wrong wrapped child")
            else
                assert(id == registry.builtin.FloatingLayout or id == registry.builtin.BoxLayout,
                    "Recipe child must be a layout")
            end
        end
        self.result = children
    end
    local params = {gameCtx = {}}
    context.currentRecipeId = replacementId
    local ok, err = pcall(registry.recipes[replacementId], context, {props = {params}})
    if not expectWrapper then
        assert(not ok and tostring(err):find("Recipe child must be a layout", 1, true), tostring(err))
        return
    end
    assert(ok, err)
    local originalNode = nodes[context.result[1]]
    assert(originalNode.recipeId == originalId and originalNode.props.props[1] == params,
        "Original GameBar or its parameters were changed")
    -- Execute the original recipe through the shipped module, too: it returns a layout.
    context.currentRecipeId = originalId
    registry.recipes[originalId](context, originalNode.props)
    assert(nodes[context.result[1]].recipeId == registry.builtin.FloatingLayout)
    -- Badge wrapper must return a Component; its FloatingLayout owns widget children.
    local badgeId = assert(ids.TF3SubsidyManagerOfferBadgeIcon)
    assert(registry.recipeMetas[badgeId].innerRecipeId == registry.builtin.Component)
    function context:declareRef(value) return {get = function() return value end, set = function(_, nextValue) value = nextValue end} end
    function context:declareRefLazy(fn) local value = fn(); return {get = function() return value end} end
    local eventHandlers, visualState = {}, nil
    function context:onEvent(fn, name)
        assert(name == "tf3SubsidyManagerBadgeChanged" or name == "tf3SubsidyManagerOffersOpened"
            or name == "tf3SubsidyManagerAutoDecline" or name == "tf3SubsidyManagerArchiveRequest" or name == "tf3SubsidyManagerArchiveReply")
        eventHandlers[name] = fn
    end
    function context:onMount() end
    function context:declareState(value)
        if self.currentRecipeId == badgeId and visualState then return visualState end
        local state = {old = function() return value end, set = function(_, v) value = v end}
        if self.currentRecipeId == badgeId then visualState = state end
        return state
    end
    context.currentRecipeId = badgeId
    registry.recipes[badgeId](context, {props = {{}}})
    -- Execute the shipped two-phase queues. Restricted engine reads must not
    -- execute GUI effects until the separate main-thread join phase.
    local restricted, applied = true, 0
    react.enqueueDeferredStep(function()
        assert(restricted)
        react.enqueueJoin(function()
            assert(not restricted, 'GUI effect executed in restricted deferred phase')
            applied = applied + 1
        end, 'contract-test:main-effects')
    end)
    reactEnv._reactDoExecuteDeferredSteps()
    assert(applied == 0)
    restricted = false
    reactEnv._reactDoExecuteJoins()
    assert(applied == 1)
    local badgeComponent = nodes[context.result[1]]
    assert(badgeComponent.recipeId == registry.builtin.Component)
    local layout = nodes[badgeComponent.props.props[1].layout]
    assert(layout.recipeId == registry.builtin.FloatingLayout)
    local children = layout.props.props[1].children
    assert(#children == 1)
    for _, child in ipairs(children) do assert(nodes[child].recipeId == registry.builtin.FloatingLayoutChild) end
    assert(nodes[nodes[children[1]].props.props[1].item].recipeId == registry.builtin.ImageView)
    eventHandlers.tf3SubsidyManagerBadgeChanged("tf3SubsidyManagerBadgeChanged", true)
    context.currentRecipeId = badgeId
    registry.recipes[badgeId](context, {props = {{}}})
    local marked = nodes[nodes[context.result[1]].props.props[1].layout].props.props[1].children
    assert(#marked == 2 and nodes[marked[2]].recipeId == registry.builtin.FloatingLayoutChild)
    assert(nodes[nodes[marked[2]].props.props[1].item].recipeId == registry.builtin.Component)
    -- Create the native stack before any GameBar/Industry button executes.
    -- The hook must preserve opaque nodes, params, styles and native refs.
    local pushes = {}
    local gameCtx = {windowContainer = {}, toolStack = {get = function() return {getApi = function()
        return {push = function(tool, key, param, stacking)
            pushes[#pushes + 1] = {tool = tool, key = key, param = param, stacking = stacking}
        end}
    end} end}}
    local nativeParams = {defaultToolParam = {gameCtx = gameCtx}, defaultToolKey = "__pinned__"}
    local ref = {set = function(self, value) self.value = value end}
    local style = {class = "native-stack-style"}
    function context:makeNodeRef(node) return {node = node} end
    local stackFixture = react.RegisterRecipe("NativeStackFixture", function()
        return builtin.BoxLayout {children = {builtin.ToolStack(react.ref({ref}), react.style(style), nativeParams)}}
    end)
    local stackFixtureId = react.GetRecipeId(stackFixture)
    context.currentRecipeId = stackFixtureId
    registry.recipes[stackFixtureId](context, {props = {{}}})
    local stackNode = nodes[nodes[context.result[1]].props.props[1].children[1]]
    assert(stackNode.recipeId == registry.builtin.ToolStack and stackNode.props.props[1] == nativeParams)
    assert(stackNode.props.style == style and nodes[ref.value.node] == stackNode)
    local pluginId = assert(ids.TF3SubsidyManagerControllerHost)
    assert(registry.recipeMetas[pluginId] == nil)
    context.currentRecipeId = pluginId
    registry.recipes[pluginId](context, {props = {{}}})
    local pluginLayout = nodes[context.result[1]]
    assert(pluginLayout.recipeId == registry.builtin.BoxLayout)
    local pluginChildren = pluginLayout.props.props[1].children
    assert(#pluginChildren == 1 and nodes[pluginChildren[1]].recipeId == ids.TF3SubsidyManagerController)
    assert(#pushes == 0, "Background host must not open a window")
    -- Controller returns an empty layout; no visible overlay or extra window.
    context.currentRecipeId = ids.TF3SubsidyManagerController
    registry.recipes[context.currentRecipeId](context, {props = {{}}})
    assert(nodes[context.result[1]].recipeId == registry.builtin.BoxLayout)
    assert(#nodes[context.result[1]].props.props[1].children == 0)
    -- Table cells are ordinary recipes, unlike GameBar/Window delegation.
    -- Execute each through shipped Lua registration and opaque node construction.
    for _, key in ipairs({"type", "resource", "destination", "requirement", "progress", "reward", "time", "status"}) do
        local id = assert(ids["TF3SubsidyManagerCell_" .. key])
        assert(registry.recipeMetas[id] == nil, "Table cells must use ordinary layout recipes")
        context.currentRecipeId = id
        registry.recipes[id](context, {props = {{rowKey = 1, colKey = 1, userParam = {entries = {{
            name = "Supply Town", resourceName = "Fish", outcome = "successful", required = 35, delivered = 21,
            recordCopy = {uid = 1}, card = {progress = {value = 0.6, text = "21 / 35"},
                cargoIcons = {"fish.tga"}, location = {to = {77, "Castle Cary"}}, complete = {{text = "Native reward"}},
                expireDuration = {name = "Native duration"}},
        }}}}}})
        assert(nodes[context.result[1]].recipeId == registry.builtin.BoxLayout)
    end
end

-- Legacy mutation still reproduces revision 5's invalid layout delegation.
check(source, false)
check(source, true)
print("PASS: shipped React plugin/wrapper registration and table cells; legacy layout mutation remains rejected")
