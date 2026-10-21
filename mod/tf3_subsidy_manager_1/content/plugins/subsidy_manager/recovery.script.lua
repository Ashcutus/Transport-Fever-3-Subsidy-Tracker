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

local function respond(saved, action, key, success, reason, count)
    saved.response = {sequence = saved.response.sequence + 1, action = action,
        key = key, success = success, reason = reason, count = count}
end

local function command(state, param)
    if type(param) ~= "table" then return end
    local data = state:get()
    -- Do not make an uninitialized native state nonempty: the original
    -- initStateIfEmpty would then skip creating its required collections.
    if type(data) ~= "table" or type(data.proposedSubventions) ~= "table"
        or type(data.activeSubventions) ~= "table" then return end
    local saved = archive(data)
    if param.action == "review" then
        local count = 0
        local unavailable = false
        for _, entry in ipairs(saved.entries) do
            if entry.status == "saved" and entry.source == "automatic" then
                -- Exceptions mean temporarily unreadable, not an expired offer.
                local ok, record, reason = pcall(candidate, entry, data)
                if ok and record then count = count + 1
                elseif ok then entry.status, entry.reason = "expired", reason end
                if not ok then unavailable = true end
            end
        end
        respond(saved, "review", nil, not unavailable, unavailable and count == 0 and "unavailable" or nil, count)
    elseif param.action == "recover" and type(param.key) == "string" then
        for index, entry in ipairs(saved.entries) do
            if entry.key == param.key and entry.status == "saved" then
                local ok, record, reason = pcall(candidate, entry, data)
                if not ok then
                    respond(saved, "recover", entry.key, false, "unavailable")
                elseif not record then
                    entry.status, entry.reason = "expired", reason
                    respond(saved, "recover", entry.key, false, reason)
                else
                    data.usedUids = data.usedUids or {}
                    data.usedUids[record.id] = data.usedUids[record.id] or {}
                    data.usedUids[record.id][tostring(record.uid)] = true
                    table.insert(data.proposedSubventions, record)
                    table.remove(saved.entries, index)
                    respond(saved, "recover", param.key, true)
                end
                state:set(data)
                return
            end
        end
        respond(saved, "recover", param.key, false, "not_found")
    else
        return
    end
    state:set(data)
end

local function original(params)
    return assert(util.useFn(params.original), "Original subsidy callback unavailable")
end

function data()
    local subscribed = false
    return {
        update = function(params, state, dt)
            local result = original(params)(params.originalParams or {}, state, dt)
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
            local result = original(params)(params.originalParams or {}, state, src, id, name, param)
            if not subscribed or id == "" then state:subscribeToEvent(NAMESPACE); subscribed = true end
            return result
        end,
    }
end
