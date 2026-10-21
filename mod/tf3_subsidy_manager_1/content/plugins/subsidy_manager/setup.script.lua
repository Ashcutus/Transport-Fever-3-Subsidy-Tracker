-- Keep the native .gs identity and its saved state. Delegate each callback rather
-- than copying the game's subsidy implementation or replacing other scripts.
function data()
    return {
        runFn = function()
            addModifier("loadGameScript", function(fileName, resource)
                if fileName ~= "::/game_mechanics/subventions/subventions.gs"
                    and fileName ~= "::/game_mechanics/subventions/subventions.gs.lua" then return resource end
                if resource.updateScript and resource.updateScript.fileName == "tf3_subsidy_manager::/plugins/subsidy_manager/recovery.script@update" then return resource end
                for _, callback in ipairs({{"updateScript", "update"}, {"handleEventScript", "handleEvent"}}) do
                    local ref = resource[callback[1]]
                    if not ref or type(ref.fileName) ~= "string" or ref.fileName == "" then
                        error("Subsidy Manager: native subsidy callback missing")
                    end
                    local path = ref.fileName
                    if not path:find("::", 1, true) then
                        path = path:sub(1, 1) == "/" and "::" .. path or "::/game_mechanics/subventions/" .. path
                    end
                    resource[callback[1]] = {
                        fileName = "tf3_subsidy_manager::/plugins/subsidy_manager/recovery.script@" .. callback[2],
                        params = {original = path, originalParams = ref.params},
                    }
                end
                return resource
            end)
        end,
    }
end
