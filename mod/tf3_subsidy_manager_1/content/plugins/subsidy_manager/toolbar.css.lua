local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
    local result = {}
    local a = ssu.makeAdder(result)
    -- game_bar.css.lua uses 10 between buttons, 508 for seven 52px icons.
    -- Extend the native tray by one icon + gap; stylesheet units follow UI scale.
    a("R::GameBarMenuRight !statistics", { minSize = { 570, -1 } })
    a("R::GameBarMenuRight !tf3-subsidy-tray-pair", { innerSpacing = { 10, 0 } })
    -- Match the native small-button surface for the checked highlight mask as well.
    -- The existing native selectors still own colours, hover, pressed state and scale.
    a("R::GameBarMenuRight ToolButton!tf3-subsidy-toolbar!checked", {
        backgroundImage1 = { fileName = "::/gui/game_bar/design/tool_button/button_small_surface.tga" },
        highlightMask = { fileName = "::/gui/game_bar/design/tool_button/button_small_surface.tga" },
        borderImage = { fileName = "" },
    })
    a("#tf3-subsidy-manager.window", { size = { 1180, 640 }, minSize = { 1180, 640 }, maxSize = { 1180, 640 } })
    a("!tf3-subsidy-content", { padding = { 16, 12, 16, 12 }, innerSpacing = { 0, 12 } })
    a("!tf3-subsidy-controls", { innerSpacing = { 16, 0 } })
    a("!tf3-subsidy-data-region", { size = { -1, 490 } })
    a("!tf3-subsidy-table", { size = { -1, 490 } })
    a("!tf3-subsidy-cell", { gravity = { -1, -1 }, padding = { 4, 4, 4, 4 } })
    a("!tf3-subsidy-cell ImageView", { size = { 20, 20 } })
    a("!tf3-subsidy-cell TextView", { gravity = { -1, 0.5 } })
    a("!tf3-subsidy-cell ProgressBar", { minSize = { 90, 20 }, gravity = { -1, 0.5 } })
    return result
end
