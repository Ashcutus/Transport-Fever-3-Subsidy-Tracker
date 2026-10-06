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
    a("#tf3-subsidy-manager.button !tf3-subsidy-toolbar-icon", { size = { trayButtonSize, trayButtonSize } })
    a("#tf3-subsidy-manager.button !tf3-subsidy-toolbar-icon FloatingLayout", { gravity = { -1, -1 } })
    -- Floating overlay: no row allocation or changes to native button state surfaces.
    a("#tf3-subsidy-manager.button !tf3-subsidy-offer-badge", { size = { 8, 8 }, minSize = { 8, 8 }, maxSize = { 8, 8 } })
    a("#tf3-subsidy-manager.button !tf3-subsidy-offer-badge TextView", { fontSize = 10, color = { 1, 0.8, 0.2, 1 }, gravity = { 0.5, 0.5 } })

    a("#tf3-subsidy-manager.window", { size = { 1180, 640 }, minSize = { 1180, 640 }, maxSize = { 1180, 640 } })
    -- Empty snapshots use a compact preset; populated snapshots keep revision 9 dimensions.
    a("#tf3-subsidy-manager.window!tf3-subsidy-empty", { size = { 640, 260 }, minSize = { 640, 260 }, maxSize = { 640, 260 } })
    a("#tf3-subsidy-manager.window!tf3-subsidy-empty !tf3-subsidy-data-region", { size = { -1, 110 } })
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
    -- Separate native effects with line breaks; wrap long durations within the cell.
    -- Shipped content_card.css.lua uses textAutoWrap with a bounded width.
    -- Leave height unconstrained so the native table can allocate taller rows.
    a("#tf3-subsidy-manager.window !tf3-subsidy-reward-cell TextView", {
        textAutoWrap = true, maxSize = { 240, -1 }, gravity = { -1, 0.5 },
    })
    -- Native duration labels can include years, months and days; keep them complete.
    a("#tf3-subsidy-manager.window !tf3-subsidy-time-cell TextView", {
        textAutoWrap = true, maxSize = { 220, -1 }, gravity = { -1, 0.5 },
    })
    -- One compact illustrated panel also fits the all-empty 110-unit body.
    a("#tf3-subsidy-manager.window !tf3-subsidy-empty-state", {
        size = { -1, 490 }, gravity = { 0.5, 0.5 }, maxSize = { 560, -1 },
    })
    a("#tf3-subsidy-manager.window!tf3-subsidy-empty !tf3-subsidy-empty-state", { size = { -1, 110 } })
    a("#tf3-subsidy-manager.window !tf3-subsidy-empty-state BoxLayout", { gravity = { -1, 0.5 }, innerSpacing = { 18, 6 } })
    a("#tf3-subsidy-manager.window !tf3-subsidy-empty-state ImageView", { size = { 64, 64 }, gravity = { 0.5, 0.5 } })
    a("#tf3-subsidy-manager.window !tf3-subsidy-empty-title", { fontSize = 18, color = { 0.93, 0.96, 0.98, 1 }, textAutoWrap = true, maxSize = { 440, -1 } })
    a("#tf3-subsidy-manager.window !tf3-subsidy-empty-hint", { fontSize = 14, color = { 0.72, 0.80, 0.85, 1 }, textAutoWrap = true, maxSize = { 440, -1 } })
    return result
end
