-- Runs in the original subsidy game script's simulation context. GUI code only
-- sends commands; it never writes an engine component or supplies contract data.
local util = ug_require "::/scripts/util.tl"
local NAMESPACE = "tf3SubsidyManager"
local AUTO_SOURCE = "tf3_subsidy_manager:auto"
local FIELD = "tf3SubsidyManagerArchive"
local supported = {}
for _, kind in ipairs({"deliver_cargo", "deliver_cargo_town", "deliver_passengers", "deliver_workers"}) do
    supported["::/game_mechanics/subventions/" .. kind .. "/" .. kind .. ".res"] = true
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function finite(value)
    return type(value) == "number" and math.abs(value) < math.huge
end

local function now()
    return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
end

local function archive(data)
    local value = data[FIELD]
    if value == nil then
        value = {version = 1, nextKey = 1, entries = {}, response = {sequence = 0}}
        data[FIELD] = value
    end
    -- Never replace unknown/newer archive formats, potentially destroying data.
    assert(type(value) == "table" and value.version == 1 and type(value.entries) == "table"
        and finite(value.nextKey) and value.nextKey >= 1 and value.nextKey == math.floor(value.nextKey)
        and type(value.response) == "table" and finite(value.response.sequence), "Unsupported subsidy archive")
    return value
end

local function remember(data, uid, automatic)
    for _, record in ipairs(data.proposedSubventions or {}) do
        if record.uid == uid then
            assert(type(record.id) == "string" and type(record.data) == "table"
                and finite(record.uid) and record.uid >= 0 and record.uid == math.floor(record.uid)
                and finite(record.spawnTime) and finite(record.data.expireDurationProposed), "Invalid subsidy record")
            local saved = archive(data)
            local duration = record.data.expireDurationProposed
            local remaining = duration < 0 and -1 or math.max(0, record.spawnTime + duration - now())
            saved.entries[#saved.entries + 1] = {
                key = tostring(saved.nextKey), record = copy(record), remaining = remaining,
                source = automatic and "automatic" or "manual", status = "saved",
            }
            saved.nextKey = saved.nextKey + 1
            return
        end
    end
end

local function identity(record)
    if type(record) ~= "table" or type(record.id) ~= "string" or not finite(record.uid)
        or record.uid < 0 or record.uid ~= math.floor(record.uid) or not finite(record.spawnTime) then return nil end
    return string.format("%d:%s|%.17g|%.17g", #record.id, record.id, record.uid, record.spawnTime)
end

local function configure(saved, data, enabled)
    -- Offers already shown while the setting was off stay available. This
    -- also migrates archives created before per-offer visibility was saved.
    if enabled and type(saved.automatic) == "table" and saved.automatic.enabled == false then
        for _, entry in ipairs(saved.entries) do
            if type(entry) == "table" and entry.status == "saved" and entry.source == "automatic" then entry.revealed = true end
        end
    end
    if type(saved.automatic) ~= "table" or saved.automatic.enabled ~= enabled or type(saved.automatic.protected) ~= "table" then
        saved.automatic = {enabled = enabled, protected = {}}
        if enabled then
            for _, record in ipairs(data.proposedSubventions) do
                local key = identity(record)
                if key then saved.automatic.protected[key] = true end
            end
        end
    end
end

local function candidate(entry, data)
    local record = entry.record
    if type(record) ~= "table" or not supported[record.id] or type(record.data) ~= "table"
        or not finite(record.uid) or record.uid < 0 or record.uid ~= math.floor(record.uid)
        or record.acceptedTime ~= nil or record.completedTime ~= nil
        or not finite(entry.remaining) or not finite(record.data.expireDurationProposed) then
        return nil, "unsupported"
    end
    if entry.remaining == 0 or entry.remaining < -1 then return nil, "timeout" end
    for _, collection in ipairs({"proposedSubventions", "activeSubventions", "completedSubventions", "failedSubventions"}) do
        for _, current in ipairs(data[collection] or {}) do
            if current.uid == record.uid then return nil, "duplicate" end
        end
    end
    local resourceId = api.res.genericRep.find(record.id)
    if resourceId < 0 then return nil, "missing_resource" end
    local desc = api.res.genericRep.get(resourceId).data
    if type(desc) ~= "table" or type(desc.scriptFile) ~= "string" then return nil, "missing_resource" end
    local restored = copy(record)
    -- Preserve duration and all contract data; shift only the offer's time origin
    -- so time spent hidden does not consume its saved remaining offer time.
    restored.spawnTime = entry.remaining == -1 and now() or now() - (record.data.expireDurationProposed - entry.remaining)
    local shouldDespawn = util.useFn(desc.scriptFile .. ".shouldDespawn")
    local isComplete = util.useFn(desc.scriptFile .. ".isComplete")
    if type(shouldDespawn) ~= "function" then return nil, "unsupported" end
    local reason = shouldDespawn(copy(restored), now())
    if reason then return nil, reason == "Timeout" and "timeout" or "invalid_destination" end
    if type(isComplete) == "function" and isComplete(copy(restored)) then return nil, "already_complete" end
    return restored
end

local function respond(saved, param, action, key, success, reason, count)
    saved.response = {sequence = saved.response.sequence + 1, action = action,
        key = key, success = success, reason = reason, count = count,
        requestId = type(param.requestId) == "string" and param.requestId or nil}
end

local function command(state, param)
    if type(param) ~= "table" then return end
    local data = state:get()
    -- Do not make an uninitialized native state nonempty: the original
    -- initStateIfEmpty would then skip creating its required collections.
    if type(data) ~= "table" or type(data.proposedSubventions) ~= "table"
        or type(data.activeSubventions) ~= "table" then return end
    local saved = archive(data)
    if param.action == "configure" then
        if type(param.enabled) ~= "boolean" then return end
        configure(saved, data, param.enabled)
        if param.enabled or param.review ~= true then
            respond(saved, param, "configure", nil, true)
            saved.response.enabled, saved.response.review = param.enabled, false
            state:set(data)
            return
        end
    end
    if param.action == "review" or (param.action == "configure" and param.review == true) then
        local count, newCount = 0, 0
        local unavailable = false
        for _, entry in ipairs(saved.entries) do
            if type(entry) == "table" and entry.status == "saved" and entry.source == "automatic" then
                -- Exceptions mean temporarily unreadable, not an expired offer.
                local ok, record, reason = pcall(candidate, entry, data)
                if ok and record then
                    count = count + 1
                    if entry.revealed ~= true then newCount = newCount + 1 end
                    entry.revealed = true
                elseif ok then entry.status, entry.reason = "expired", reason end
                if not ok then unavailable = true end
            end
        end
        respond(saved, param, param.action, nil, param.action == "configure" or not unavailable, unavailable and count == 0 and "unavailable" or nil, count)
        if param.action == "configure" then saved.response.enabled, saved.response.review = false, true end
        saved.response.newCount = newCount
        saved.notice = copy(saved.response)
    elseif param.action == "recover" and type(param.key) == "string" then
        for index, entry in ipairs(saved.entries) do
            if type(entry) == "table" and entry.key == param.key and entry.status == "saved" then
                if type(saved.automatic) == "table" and saved.automatic.enabled and entry.revealed ~= true then
                    respond(saved, param, "recover", entry.key, false, "unavailable")
                    state:set(data)
                    return
                end
                local ok, record, reason = pcall(candidate, entry, data)
                if not ok then
                    respond(saved, param, "recover", entry.key, false, "unavailable")
                elseif not record then
                    entry.status, entry.reason = "expired", reason
                    respond(saved, param, "recover", entry.key, false, reason)
                else
                    data.usedUids = data.usedUids or {}
                    data.usedUids[record.id] = data.usedUids[record.id] or {}
                    data.usedUids[record.id][tostring(record.uid)] = true
                    table.insert(data.proposedSubventions, record)
                    if type(saved.automatic) == "table" and saved.automatic.enabled then
                        configure(saved, data, true)
                        saved.automatic.protected[identity(record)] = true
                    end
                    table.remove(saved.entries, index)
                    respond(saved, param, "recover", param.key, true)
                end
                state:set(data)
                return
            end
        end
        respond(saved, param, "recover", param.key, false, "not_found")
    else
        return
    end
    state:set(data)
end

local function original(params)
    return assert(util.useFn(params.original), "Original subsidy callback unavailable")
end

local suppressionWarnings = {}
local function runNative(params, state, fn, ...)
    -- Buffer the native script's writes, suppress new offers using its
    -- own decline handler, then expose one final state to other scripts.
    -- Notifications can never observe the intermediate proposed offers.
    local staged, wrote
    local proxy = setmetatable({
        get = function() return wrote and copy(staged) or state:get() end,
        set = function(_, value) staged, wrote = value, true end,
    }, {__index = function(_, key)
        local member = state[key]
        if type(member) == "function" then return function(_, ...) return member(state, ...) end end
        return member
    end})
    local result = fn(params.originalParams or {}, proxy, ...)
    if wrote then
        local saved = staged[FIELD]
        local automatic = type(saved) == "table" and saved.version == 1 and saved.automatic
        if type(automatic) == "table" and automatic.enabled == true and type(automatic.protected) == "table" then
            local keep = {}
            for _, record in ipairs(copy(staged.proposedSubventions)) do
                local key = identity(record)
                if key and automatic.protected[key] then keep[key] = true
                elseif key then
                    local before = copy(staged)
                    local ok, err = pcall(function()
                        remember(staged, record.uid, true)
                        local decline = assert(util.useFn(params.nativeEvent))
                        decline(params.nativeEventParams or {}, proxy, AUTO_SOURCE, "Subvention", "onDecline", {uid = record.uid})
                        for _, remaining in ipairs(staged.proposedSubventions) do
                            assert(remaining.uid ~= record.uid, "Native decline did not remove offer")
                        end
                    end)
                    if not ok then
                        staged = before
                        if not suppressionWarnings[key] then log.warning("[tf3_subsidy_manager] Suppression unavailable: " .. tostring(err)) end
                        suppressionWarnings[key] = true
                    else suppressionWarnings[key] = nil end
                end
            end
            staged[FIELD].automatic.protected = keep
        end
        state:set(staged)
    end
    return result
end

function data()
    local subscribed = false
    return {
        update = function(params, state, dt)
            local result = runNative(params, state, original(params), dt)
            if not subscribed then state:subscribeToEvent(NAMESPACE); subscribed = true end
            return result
        end,
        handleEvent = function(params, state, src, id, name, param)
            if id == NAMESPACE and name == NAMESPACE then
                -- Only identifiers/actions cross the GUI boundary, never a
                -- replacement record, payment, progress or simulation table.
                local ok, err = pcall(command, state, param)
                if not ok then log.warning("[tf3_subsidy_manager] Archive request unavailable: " .. tostring(err)) end
                return
            end
            if id == "Subvention" and name == "onDecline" and type(param) == "table" then
                local saved = state:get()
                local automatic = src == AUTO_SOURCE
                local ok, err = pcall(remember, saved, param.uid, automatic)
                if not ok then
                    log.warning("[tf3_subsidy_manager] Could not archive offer: " .. tostring(err))
                    -- Preserve an automatic offer we could not save, but never
                    -- block a deliberate native decline (including campaign
                    -- contracts with fractional UIDs, outside recovery scope).
                    if automatic then return end
                else
                    state:set(saved)
                end
            end
            local result = runNative(params, state, original(params), src, id, name, param)
            if not subscribed or id == "" then state:subscribeToEvent(NAMESPACE); subscribed = true end
            return result
        end,
    }
end
