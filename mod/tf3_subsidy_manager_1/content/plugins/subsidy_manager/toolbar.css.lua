local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
    local result = {}
    local a = ssu.makeAdder(result)
    -- Native icons are _26@2x assets: 26 logical units, 52 physical pixels.
    -- Keep eight buttons within the original seven-button row, with 10-unit gaps.
    -- floor((7 * 26 + 6 * 10 - 7 * 10) / 8) = 21 logical units.
    -- Keep the native tray/background width, surfaces and state transforms.
    local trayButtonSize = math.floor((7 * 26 + 6 * 10 - 7 * 10) / 8)
    a([[R::GameBarMenuRight !statistics ToolButton,
        R::GameBarMenuRight !notifications ToolButton,
        R::GameBarMenuRight !menu ToolButton]], { size = { trayButtonSize, trayButtonSize } })
    a([[R::GameBarMenuRight !statistics ToolButton ImageView,
        R::GameBarMenuRight !notifications ToolButton ImageView,
        R::GameBarMenuRight !menu ToolButton ImageView]], { size = { trayButtonSize, trayButtonSize } })
    a("R::GameBarMenuRight !tf3-subsidy-tray-pair", { innerSpacing = { 10, 0 } })

    a("#tf3-subsidy-manager.window", { size = { 1180, 640 }, minSize = { 1180, 640 }, maxSize = { 1180, 640 } })
    -- Match native statistics: padding belongs to the Window content widget.
    a("#tf3-subsidy-manager.window Window::Content", { padding = { 16, 12, 16, 12 } })
    a("!tf3-subsidy-content", { gravity = { -1, -1 }, innerSpacing = { 0, 12 } })
    a("!tf3-subsidy-controls", { innerSpacing = { 16, 0 } })
    a("!tf3-subsidy-data-region", { size = { -1, 490 }, gravity = { -1, -1 } })
    a("!tf3-subsidy-data-region R::Component", { gravity = { -1, -1 } })
    a("!tf3-subsidy-data-region BoxLayout", { gravity = { -1, -1 } })
    a("!tf3-subsidy-table", { size = { -1, 490 }, gravity = { -1, -1 } })
    -- DataTable creates an internal Table; native Statistics stretches both layers.
    -- Recipe size alone does not allocate the weighted columns their usable width.
    a("!tf3-subsidy-table Table", { gravity = { -1, -1 }, margin = { 0, 0, 0, 0 } })
    a("!tf3-subsidy-table Table::Layout", { gravity = { -1, -1 } })
    a("!tf3-subsidy-cell", { gravity = { -1, -1 }, padding = { 4, 4, 4, 4 } })
    a("!tf3-subsidy-cell ImageView", { size = { 20, 20 } })
    a("!tf3-subsidy-cell TextView", { gravity = { -1, 0.5 } })
    a("!tf3-subsidy-cell ProgressBar", { minSize = { 90, 20 }, gravity = { -1, 0.5 } })
    return result
end
