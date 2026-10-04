local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
    local result = {}
    local a = ssu.makeAdder(result)
    -- game_bar.css.lua uses 10 between buttons, 508 for seven 52px icons.
    -- Extend the native tray by one icon + gap; stylesheet units follow UI scale.
    a("R::GameBarMenuRight !statistics", { minSize = { 570, -1 } })
    a("R::GameBarMenuRight !copilot-subsidy-tray-pair", { innerSpacing = { 10, 0 } })
    a("#copilot-subsidy-manager.window", { minSize = { 560, 240 }, maxSize = { 720, 800 } })
    a("#copilot-subsidy-manager.window ImageView", { maxSize = { 24, 24 } })
    return result
end
