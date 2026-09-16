-- ============================================================
-- BPM Archipelago v1.5.0
-- First Real Patch Release
--
-- Production scope:
--   * Direct IPC location checks.
--   * Proven coin pickup checks (10 individual + 5/10/25 milestones).
--   * Confirmed Treasure reward checks (10 locations).
--   * Confirmed Challenge reward checks (10 locations).
--   * Event-driven incoming AP item delivery; no timers/ticks.
--   * Manual BPMAP_PROCESS_ITEMS fallback remains available.
--
-- Confirmed reward functions:
--   /Script/BPM.BPMGameInstance:ConsumeAndReturnRandomTreasureItem
--   /Script/BPM.BPMGameInstance:ConsumeAndReturnRandomChallengeItem
--
-- Deliberately NOT used:
--   TrySpawnRewards (tested and did not fire for the relevant path).
--   GiveHealth(25) for AP healing (tested behavior is full-heal).
--   Delayed actions / ticking / custom events.
-- ============================================================

local function Log(msg)
    print("[BPMArchipelago] " .. tostring(msg) .. "\n")
end

local SCRIPT_DIR = debug.getinfo(1).source:sub(2):match("(.*[\\/])")
local PATH_SEP = package.config:sub(1, 1)
local IPC_DIR = SCRIPT_DIR .. ".." .. PATH_SEP .. "IPC" .. PATH_SEP

local function valid(obj)
    return obj and obj.IsValid and obj:IsValid()
end

local function fullname(obj)
    if not valid(obj) then return "<invalid>" end
    local ok, s = pcall(function() return obj:GetFullName() end)
    return ok and tostring(s) or "<fullname-error>"
end

local function write_file(name, text, mode)
    local f = io.open(IPC_DIR .. name, mode or "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function append_file(name, text)
    return write_file(name, text, "a")
end

local function read_text_file(name)
    local f = io.open(IPC_DIR .. name, "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    return text:gsub("%s+$", "")
end

local IPC_READY = write_file(".bpm_ipc_probe", "ok\n")
if IPC_READY then
    os.remove(IPC_DIR .. ".bpm_ipc_probe")
end

write_file(
    "boot.txt",
    "BPMArchipelago v1.5.0 loaded\n" ..
    "IPC_READY=" .. tostring(IPC_READY) .. "\n" ..
    "IPC_DIR=" .. IPC_DIR .. "\n"
)

write_file(
    "status.txt",
    "BPMArchipelago v1.5.0 first real patch loaded\n" ..
    "IPC_READY=" .. tostring(IPC_READY) .. "\n" ..
    "IPC_DIR=" .. IPC_DIR .. "\n"
)

-- ============================================================
-- Runtime state
-- ============================================================

local Player = nil
local HooksInstalled = false
local HookIDs = {}
local CoinPickupHookInstalled = false
local CoinPickupHookID = nil
local CoinPickupCallbackCount = 0

local CurrentAPSession = ""
local IncomingSession = nil
local ProcessedItems = {}

local AutoItemProcessing = false
local AutoItemTriggerCount = 0
local AutoItemSuccessCount = 0
local AutoItemErrorCount = 0
local AutoItemLastTrigger = "none"
local AutoItemLastResult = "none"
local AutoItemLastIndex = nil
local AutoItemLastID = nil
local AUTOMATIC_ITEM_PROCESSING_ENABLED = true

local TreasureRewardCount = 0
local ChallengeRewardCount = 0
local RewardStateBySession = {}
local RewardActiveSession = ""
local TreasureRewardCallbackCount = 0
local ChallengeRewardCallbackCount = 0
local LastRewardEvent = "none"

local CoinIndividualCount = 0
local CoinTotalCount = 0
local CoinMilestonesSent = {}
local CoinStateBySession = {}

local process_one_ap_item
local automatic_process_items

-- ============================================================
-- AP item map
-- ============================================================

local ITEM_MAP = {
    [11927553] = { type = "COINS", amount = 5,  name = "Coins +5" },
    [11927554] = { type = "COINS", amount = 10, name = "Coins +10" },
    [11927555] = { type = "KEYS", amount = 1,  name = "Keys +1" },
    [11927556] = { type = "KEYS", amount = 5,  name = "Keys +5" },
    [11927557] = { type = "HEALTHCONTAINER", name = "Health Container" },
    [11927558] = { type = "DAMAGE", amount = 1, name = "Damage Up" },
    [11927559] = { type = "CRIT", amount = 1, name = "Critical Up" },
    [11927560] = { type = "RANGE", amount = 1, name = "Range Up" },
    [11927561] = { type = "SPEED", amount = 1, name = "Movement Speed Up" },
    [11927562] = { type = "LUCK", amount = 1, name = "Luck Up" },
    [11927563] = { type = "EXTRAMMO", amount = 1, name = "Extra Ammo Up" },
    [11927564] = { type = "ABILITYPOWER", amount = 1, name = "Ability Power Up" },
    [11927566] = { type = "DAMAGE", amount = 2, name = "Damage Up +2" },
    [11993087] = { type = "VICTORY", amount = 0, name = "Victory" }
}

local HEALTH_CONTAINER_RARE_CHANCE = 0.000076

local function get_player()
    if valid(Player) then return Player end

    Player = FindFirstOf("BPMPlayerCharacter")
    if not valid(Player) then Player = FindFirstOf("BP_BPMPlayerCharacter_C") end
    if not valid(Player) then Player = FindFirstOf("BPMCharacter") end

    if valid(Player) then return Player end
    Player = nil
    return nil
end

-- ============================================================
-- Location IDs
-- ============================================================

local COIN_PICKUP_PATH =
    "/Game/Blueprints/Abilities/Item/Upgrades/BP_SpawnedCoin.BP_SpawnedCoin_C:Pickup"

local COIN_LOCATION_IDS = {
    [1] = 11993103, [2] = 11993104, [3] = 11993105, [4] = 11993106, [5] = 11993107,
    [6] = 11993108, [7] = 11993109, [8] = 11993110, [9] = 11993111, [10] = 11993112
}

local COIN_MILESTONE_IDS = {
    [5] = 11993113,
    [10] = 11993114,
    [25] = 11993115
}

local TREASURE_LOCATION_IDS = {
    [1] = 11993206, [2] = 11993207, [3] = 11993208, [4] = 11993209, [5] = 11993210,
    [6] = 11993211, [7] = 11993212, [8] = 11993213, [9] = 11993214, [10] = 11993215
}

local CHALLENGE_REWARD_LOCATION_IDS = {
    [1] = 11993216, [2] = 11993217, [3] = 11993218, [4] = 11993219, [5] = 11993220,
    [6] = 11993221, [7] = 11993222, [8] = 11993223, [9] = 11993224, [10] = 11993225
}

-- ============================================================
-- AP location IPC
-- ============================================================

local function queue_ap_location_check(location_id)
    location_id = tonumber(location_id)
    if not location_id then return false end

    local f = io.open(IPC_DIR .. "outgoing.txt", "a")
    if not f then return false end

    f:write("CHECK|" .. tostring(location_id) .. "\n")
    f:close()
    return true
end

-- ============================================================
-- Session helpers
-- ============================================================

local function find_session_in_incoming()
    local f = io.open(IPC_DIR .. "incoming.txt", "r")
    if not f then return nil end

    local session = nil
    for line in f:lines() do
        local found = line:match("^SESSION|(.+)$")
        if found then
            found = tostring(found):gsub("^%s+", ""):gsub("%s+$", "")
            if found ~= "" then session = found end
        end
    end

    f:close()
    return session
end

local function activate_coin_session(session)
    session = tostring(session or "")
    if session == "" then return false end
    if CurrentAPSession == session then return true end

    CurrentAPSession = session

    local state = CoinStateBySession[session]
    if state then
        CoinIndividualCount = tonumber(state.individual) or 0
        CoinTotalCount = tonumber(state.total) or 0
        CoinMilestonesSent = {
            [5] = (tonumber(state.m5) or 0) ~= 0,
            [10] = (tonumber(state.m10) or 0) ~= 0,
            [25] = (tonumber(state.m25) or 0) ~= 0
        }
    else
        CoinIndividualCount = 0
        CoinTotalCount = 0
        CoinMilestonesSent = {}
    end

    return true
end

local function activate_reward_session(session)
    session = tostring(session or "")
    if session == "" then return false end
    RewardActiveSession = session

    local state = RewardStateBySession[session]
    if state then
        TreasureRewardCount = tonumber(state.treasure) or 0
        ChallengeRewardCount = tonumber(state.challenge) or 0
    else
        TreasureRewardCount = 0
        ChallengeRewardCount = 0
    end
    return true
end

local function sync_session()
    local session = find_session_in_incoming()
    if not session then return false, "no SESSION found in incoming.txt" end

    activate_coin_session(session)
    activate_reward_session(session)
    IncomingSession = session
    return true, session
end

-- ============================================================
-- Persistent coin/reward state
-- ============================================================

local function load_coin_state()
    local f = io.open(IPC_DIR .. "coin_state.txt", "r")
    if not f then return end
    for line in f:lines() do
        local session, individual, total, m5, m10, m25 =
            line:match("^STATE|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        if session then
            CoinStateBySession[session] = {
                individual = tonumber(individual) or 0,
                total = tonumber(total) or 0,
                m5 = tonumber(m5) or 0,
                m10 = tonumber(m10) or 0,
                m25 = tonumber(m25) or 0
            }
        end
    end
    f:close()
end

local function save_coin_state(session)
    session = tostring(session or "")
    if session == "" then return false end

    CoinStateBySession[session] = {
        individual = CoinIndividualCount,
        total = CoinTotalCount,
        m5 = CoinMilestonesSent[5] and 1 or 0,
        m10 = CoinMilestonesSent[10] and 1 or 0,
        m25 = CoinMilestonesSent[25] and 1 or 0
    }

    return append_file(
        "coin_state.txt",
        "STATE|" .. session .. "|" ..
        tostring(CoinIndividualCount) .. "|" ..
        tostring(CoinTotalCount) .. "|" ..
        tostring(CoinMilestonesSent[5] and 1 or 0) .. "|" ..
        tostring(CoinMilestonesSent[10] and 1 or 0) .. "|" ..
        tostring(CoinMilestonesSent[25] and 1 or 0) .. "\n"
    )
end

local function load_reward_state()
    local f = io.open(IPC_DIR .. "reward_state.txt", "r")
    if not f then return end
    for line in f:lines() do
        local session, treasure, challenge =
            line:match("^STATE|([^|]+)|([^|]+)|([^|]+)$")
        if session then
            RewardStateBySession[session] = {
                treasure = tonumber(treasure) or 0,
                challenge = tonumber(challenge) or 0
            }
        end
    end
    f:close()
end

local function save_reward_state(session)
    session = tostring(session or "")
    if session == "" then return false end

    RewardStateBySession[session] = {
        treasure = TreasureRewardCount,
        challenge = ChallengeRewardCount
    }

    return append_file(
        "reward_state.txt",
        "STATE|" .. session .. "|" ..
        tostring(TreasureRewardCount) .. "|" ..
        tostring(ChallengeRewardCount) .. "\n"
    )
end

load_coin_state()
load_reward_state()

-- ============================================================
-- Coin checks
-- ============================================================

local function process_coin_pickup()
    CoinPickupCallbackCount = CoinPickupCallbackCount + 1

    if CurrentAPSession == "" then
        sync_session()
    end
    if CurrentAPSession == "" then return end

    CoinTotalCount = CoinTotalCount + 1

    if CoinIndividualCount < 10 then
        CoinIndividualCount = CoinIndividualCount + 1
        queue_ap_location_check(COIN_LOCATION_IDS[CoinIndividualCount])
    end

    local milestone_id = COIN_MILESTONE_IDS[CoinTotalCount]
    if milestone_id and not CoinMilestonesSent[CoinTotalCount] then
        CoinMilestonesSent[CoinTotalCount] = true
        queue_ap_location_check(milestone_id)
    end

    save_coin_state(CurrentAPSession)
end

local function install_coin_pickup_check()
    if CoinPickupHookInstalled then return true, "already installed" end

    sync_session()

    local ok, a, b = pcall(function()
        return RegisterHook(
            COIN_PICKUP_PATH,
            function(...)
                process_coin_pickup()
            end
        )
    end)

    if not ok then return false, "RegisterHook failed: " .. tostring(a) end

    CoinPickupHookID = { a, b }
    CoinPickupHookInstalled = true
    return true, "coin pickup check installed"
end

-- ============================================================
-- Confirmed reward checks
-- ============================================================

local function process_confirmed_reward(kind)
    local synced, session = sync_session()
    if not synced then return false, session end

    local count, location_id

    if kind == "TREASURE" then
        if TreasureRewardCount >= 10 then
            return false, "treasure location limit reached"
        end
        TreasureRewardCount = TreasureRewardCount + 1
        count = TreasureRewardCount
        location_id = TREASURE_LOCATION_IDS[count]
    elseif kind == "CHALLENGE" then
        if ChallengeRewardCount >= 10 then
            return false, "challenge reward location limit reached"
        end
        ChallengeRewardCount = ChallengeRewardCount + 1
        count = ChallengeRewardCount
        location_id = CHALLENGE_REWARD_LOCATION_IDS[count]
    else
        return false, "unknown reward kind"
    end

    if not location_id then return false, "missing location ID" end

    if not queue_ap_location_check(location_id) then
        return false, "could not queue location " .. tostring(location_id)
    end

    save_reward_state(session)
    return true, kind .. " reward " .. tostring(count) .. " checked"
end

local function install_confirmed_reward_hooks()
    local targets = {
        {
            kind = "TREASURE",
            name = "ConsumeAndReturnRandomTreasureItem",
            path = "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomTreasureItem"
        },
        {
            kind = "CHALLENGE",
            name = "ConsumeAndReturnRandomChallengeItem",
            path = "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomChallengeItem"
        }
    }

    local installed = 0

    for _, target in ipairs(targets) do
        local ok, a, b = pcall(function()
            return RegisterHook(
                target.path,
                function(...)
                    if target.kind == "TREASURE" then
                        TreasureRewardCallbackCount = TreasureRewardCallbackCount + 1
                    else
                        ChallengeRewardCallbackCount = ChallengeRewardCallbackCount + 1
                    end
                    LastRewardEvent = target.name

                    local reward_ok, reward_msg = process_confirmed_reward(target.kind)
                    if not reward_ok then
                        Log(target.name .. " check failed: " .. tostring(reward_msg))
                    end

                    if automatic_process_items then
                        automatic_process_items(target.name)
                    end
                end
            )
        end)

        if ok then
            HookIDs["REWARD_" .. target.kind] = { a, b }
            installed = installed + 1
        else
            Log("Failed reward hook " .. target.path .. ": " .. tostring(a))
        end
    end

    return installed == #targets, installed
end

-- ============================================================
-- AP incoming item delivery
-- ============================================================

local function get_getter(player, getter_name)
    if not valid(player) then return nil end

    local fn = player[getter_name]
    if not fn or not fn.IsValid or not fn:IsValid() then return nil end

    local ok, value = pcall(function() return fn(player) end)
    return ok and value or nil
end

local function call_numeric(player, function_name, amount)
    if amount == nil then return false, "invalid numeric amount" end
    if not valid(player) then return false, "player invalid" end

    local fn = player[function_name]
    if not fn or not fn.IsValid or not fn:IsValid() then
        return false, "function not valid: " .. function_name
    end

    local ok, result = pcall(function()
        return fn(player, amount)
    end)

    return ok, tostring(result)
end

local function roll_health_container_amount()
    if math.random() < HEALTH_CONTAINER_RARE_CHANCE then
        return 76, true
    end
    return math.random(1, 25), false
end

local function grant_ap_item(player, item_id)
    if not valid(player) then return false, "player invalid" end

    local item = ITEM_MAP[item_id]
    if not item then return false, "unknown AP item ID: " .. tostring(item_id) end

    local item_type = string.upper(tostring(item.type or ""))

    if item_type == "VICTORY" then
        if not append_file("outgoing.txt", "GOAL\n") then
            return false, "could not queue GOAL"
        end
        return true, "Victory: GOAL queued"
    end

    if item_type == "HEALTHCONTAINER" then
        local amount, rare = roll_health_container_amount()
        for _ = 1, amount do
            local ok, result = call_numeric(player, "AddHealthContainer", 1)
            if not ok then
                return false, "Health Container failed after " .. tostring(_ - 1) .. "/" .. tostring(amount) .. ": " .. tostring(result)
            end
        end

        if rare then
            return true, "Health Container +76 MAX HP (rare 0.0076% roll)"
        end
        return true, "Health Container +" .. tostring(amount) .. " MAX HP"
    end

    local fn
    if item_type == "COINS" then fn = "AddCoins"
    elseif item_type == "KEYS" then fn = "AddKeys"
    elseif item_type == "DAMAGE" then fn = "AddPlayerStatWeaponDamage"
    elseif item_type == "CRIT" then fn = "AddPlayerStatWeaponCritical"
    elseif item_type == "RANGE" then fn = "AddPlayerStatRange"
    elseif item_type == "SPEED" then fn = "AddPlayerStatMovementSpeed"
    elseif item_type == "LUCK" then fn = "AddPlayerStatLuck"
    elseif item_type == "EXTRAMMO" then fn = "AddPlayerStatExtraAmmo"
    elseif item_type == "ABILITYPOWER" then fn = "AddPlayerStatAbilityPower"
    end

    if not fn then return false, "unsupported AP item type: " .. item_type end

    local ok, result = call_numeric(player, fn, tonumber(item.amount))
    if not ok then return false, "grant failed: " .. tostring(result) end

    return true, tostring(item.name or item_type) .. " granted"
end

local function load_processed_items()
    local f = io.open(IPC_DIR .. "processed_items.txt", "r")
    if not f then return end

    for line in f:lines() do
        local session, index_text = line:match("^([^|]+)|([^|]+)$")
        if session and index_text then
            local index = tonumber(index_text)
            if index then ProcessedItems[session .. "|" .. tostring(index)] = true end
        end
    end
    f:close()
end

local function record_processed_item(session, index)
    local key = tostring(session) .. "|" .. tostring(index)
    if ProcessedItems[key] then return true end

    if not append_file("processed_items.txt", key .. "\n") then
        return false
    end

    ProcessedItems[key] = true
    return true
end

local function item_ack(index, result, detail)
    detail = tostring(detail or ""):gsub("[\r\n|]", " ")
    append_file(
        "outgoing.txt",
        "ITEM_ACK|" .. tostring(index) .. "|" .. tostring(result) .. "|" .. detail .. "\n"
    )
end

load_processed_items()

process_one_ap_item = function()
    local f = io.open(IPC_DIR .. "incoming.txt", "r")
    if not f then return false, "incoming.txt could not be opened" end

    local latest_session = nil
    local latest_items = {}

    for line in f:lines() do
        local session = line:match("^SESSION|(.+)$")
        if session then
            latest_session = tostring(session):gsub("^%s+", ""):gsub("%s+$", "")
            latest_items = {}
        else
            local index_text, item_id_text, description =
                line:match("^ITEM|([^|]+)|([^|]+)|(.*)$")
            if index_text and item_id_text and latest_session then
                local index = tonumber(index_text)
                local item_id = tonumber(item_id_text)
                if index and item_id then
                    table.insert(latest_items, {
                        index = index,
                        item_id = item_id,
                        description = description
                    })
                end
            end
        end
    end

    f:close()

    if not latest_session then return false, "no Archipelago session found" end

    IncomingSession = latest_session
    activate_coin_session(latest_session)
    activate_reward_session(latest_session)
    CurrentAPSession = latest_session

    for _, item in ipairs(latest_items) do
        local key = tostring(latest_session) .. "|" .. tostring(item.index)
        if not ProcessedItems[key] then
            local player = get_player()
            if not player then
                item_ack(item.index, "ERROR", "player not found")
                return false, "player not found"
            end

            AutoItemLastIndex = item.index
            AutoItemLastID = item.item_id

            local ok, result = grant_ap_item(player, item.item_id)
            if ok then
                if not record_processed_item(latest_session, item.index) then
                    item_ack(item.index, "ERROR", "could not record processed item")
                    return false, "could not record processed item"
                end

                item_ack(item.index, "OK", result)
                Log("AP item " .. tostring(item.index) .. " granted: " .. tostring(result))
                return true, "item processed"
            end

            item_ack(item.index, "ERROR", "grant failed: " .. tostring(result))
            Log("AP item " .. tostring(item.index) .. " failed: " .. tostring(result))
            return false, "grant failed: " .. tostring(result)
        end
    end

    return false, "no new AP item"
end

-- ============================================================
-- Event-driven automatic AP item processing
-- ============================================================

automatic_process_items = function(trigger_name)
    if not AUTOMATIC_ITEM_PROCESSING_ENABLED then return end
    if AutoItemProcessing then return end

    AutoItemProcessing = true
    AutoItemTriggerCount = AutoItemTriggerCount + 1
    AutoItemLastTrigger = tostring(trigger_name or "unknown")

    local ok, processed, detail = pcall(process_one_ap_item)
    if not ok then
        AutoItemErrorCount = AutoItemErrorCount + 1
        AutoItemLastResult = "exception"
        Log("Automatic AP item processing exception: " .. tostring(processed))
    else
        AutoItemLastResult = tostring(detail or "no new AP item")
        if processed then AutoItemSuccessCount = AutoItemSuccessCount + 1 end
    end

    AutoItemProcessing = false
end

-- ============================================================
-- Gameplay hooks
-- ============================================================

local TARGETS = {
    "AddCoins",
    "AddKeys",
    "OnPickupWeaponGeneric",
    "OnPickupAbilityGeneric"
}

local function hook_callback(name)
    local pre = function(...) end
    local post = nil

    if name == "AddCoins" or name == "AddKeys" then
        post = function(...)
            automatic_process_items(name)
        end
    elseif name == "OnPickupWeaponGeneric" then
        post = function(...)
            automatic_process_items(name)
        end
    elseif name == "OnPickupAbilityGeneric" then
        post = function(...)
            automatic_process_items(name)
        end
    end

    return pre, post
end

local function install_hooks(player)
    if HooksInstalled then return true, "already installed" end
    if not valid(player) then return false, "player invalid" end

    local installed = 0
    for _, name in ipairs(TARGETS) do
        local pre, post = hook_callback(name)
        local path = "/Script/BPM.BPMCharacter:" .. name

        local ok, a, b = pcall(function()
            return RegisterHook(path, pre, post)
        end)

        if ok then
            HookIDs[name] = { a, b }
            installed = installed + 1
        end
    end

    if installed > 0 then HooksInstalled = true end
    return HooksInstalled, "installed=" .. tostring(installed)
end

-- ============================================================
-- Runtime status commands
-- ============================================================

RegisterConsoleCommandHandler("BPMAP_STATUS", function(_, _, output)
    output:Log(
        "BPMArchipelago v1.5.0: bridge alive " ..
        "IPC_READY=" .. tostring(IPC_READY) ..
        " hooks_installed=" .. tostring(HooksInstalled) ..
        " auto_items=" .. tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED) ..
        " mode=event-hooks" ..
        " session=" .. tostring(CurrentAPSession) .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_RUNTIME_STATUS", function(_, _, output)
    output:Log(
        "BPMAP_RUNTIME_STATUS: mode=event-hooks" ..
        " enabled=" .. tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED) ..
        " busy=" .. tostring(AutoItemProcessing) ..
        " triggers=" .. tostring(AutoItemTriggerCount) ..
        " processed=" .. tostring(AutoItemSuccessCount) ..
        " errors=" .. tostring(AutoItemErrorCount) ..
        " last_trigger=" .. tostring(AutoItemLastTrigger) ..
        " last_result=" .. tostring(AutoItemLastResult) ..
        " session=" .. tostring(CurrentAPSession) .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_PATH", function(_, _, output)
    output:Log("IPC=" .. IPC_DIR .. " ready=" .. tostring(IPC_READY) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_AP_STATUS", function(_, _, output)
    local marker = read_text_file("ap_connected.flag")
    local client = read_text_file("client_status.txt")

    if marker == "connected" and client and client ~= "" then
        output:Log("AP CLIENT CONNECTED\n")
        output:Log(client .. "\n")
    elseif client and client ~= "" then
        output:Log("AP CLIENT STATUS\n")
        output:Log(client .. "\n")
    else
        output:Log("AP CLIENT: offline or status file not found\n")
    end
    return true
end)
RegisterConsoleCommandHandler("AP_STATUS", function(_, _, output)
    local marker = read_text_file("ap_connected.flag")
    local client = read_text_file("client_status.txt")
    if marker == "connected" and client and client ~= "" then
        output:Log("AP CLIENT CONNECTED\n")
        output:Log(client .. "\n")
    elseif client and client ~= "" then
        output:Log("AP CLIENT STATUS\n")
        output:Log(client .. "\n")
    else
        output:Log("AP CLIENT: offline or status file not found\n")
    end
    return true
end)

RegisterConsoleCommandHandler("BPMAP_COIN_CHECK", function(_, _, output)
    local synced, session = sync_session()
    local ok, msg = install_coin_pickup_check()
    output:Log(
        "BPMAP_COIN_CHECK: " .. tostring(ok) .. " " .. tostring(msg) ..
        " session=" .. tostring(session or "none") .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_COIN_STATUS", function(_, _, output)
    output:Log(
        "BPMAP_COIN_STATUS: installed=" .. tostring(CoinPickupHookInstalled) ..
        " callbacks=" .. tostring(CoinPickupCallbackCount) ..
        " session=" .. tostring(CurrentAPSession) ..
        " individual=" .. tostring(CoinIndividualCount) .. "/10" ..
        " total=" .. tostring(CoinTotalCount) ..
        " milestone5=" .. tostring(CoinMilestonesSent[5] == true) ..
        " milestone10=" .. tostring(CoinMilestonesSent[10] == true) ..
        " milestone25=" .. tostring(CoinMilestonesSent[25] == true) .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_REWARD_STATUS", function(_, _, output)
    output:Log(
        "BPMAP_REWARD_STATUS: installed=" .. tostring(HookIDs.REWARD_TREASURE ~= nil and HookIDs.REWARD_CHALLENGE ~= nil) ..
        " treasure_callbacks=" .. tostring(TreasureRewardCallbackCount) ..
        " treasure_checks=" .. tostring(TreasureRewardCount) .. "/10" ..
        " challenge_callbacks=" .. tostring(ChallengeRewardCallbackCount) ..
        " challenge_checks=" .. tostring(ChallengeRewardCount) .. "/10" ..
        " session=" .. tostring(RewardActiveSession) ..
        " last=" .. tostring(LastRewardEvent) .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_AUTO_ITEMS", function(_, params, output)
    params = params or {}
    local mode = params[1] and string.upper(params[1]) or "STATUS"

    if mode == "ON" or mode == "1" or mode == "TRUE" then
        AUTOMATIC_ITEM_PROCESSING_ENABLED = true
        output:Log("BPMAP_AUTO_ITEMS: enabled\n")
    elseif mode == "OFF" or mode == "0" or mode == "FALSE" then
        AUTOMATIC_ITEM_PROCESSING_ENABLED = false
        output:Log("BPMAP_AUTO_ITEMS: disabled\n")
    else
        output:Log(
            "BPMAP_AUTO_ITEMS: enabled=" .. tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED) ..
            " triggers=" .. tostring(AutoItemTriggerCount) ..
            " processed=" .. tostring(AutoItemSuccessCount) ..
            " errors=" .. tostring(AutoItemErrorCount) .. "\n"
        )
    end
    return true
end)
RegisterConsoleCommandHandler("BPMAP_AUTOITEMS", function(_, params, output)
    params = params or {}
    local mode = params[1] and string.upper(params[1]) or "STATUS"
    if mode == "ON" or mode == "1" or mode == "TRUE" then
        AUTOMATIC_ITEM_PROCESSING_ENABLED = true
        output:Log("BPMAP_AUTOITEMS: enabled\n")
    elseif mode == "OFF" or mode == "0" or mode == "FALSE" then
        AUTOMATIC_ITEM_PROCESSING_ENABLED = false
        output:Log("BPMAP_AUTOITEMS: disabled\n")
    else
        output:Log("BPMAP_AUTOITEMS: enabled=" .. tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED) ..
            " triggers=" .. tostring(AutoItemTriggerCount) ..
            " processed=" .. tostring(AutoItemSuccessCount) ..
            " errors=" .. tostring(AutoItemErrorCount) .. "\n")
    end
    return true
end)

RegisterConsoleCommandHandler("BPMAP_PROCESS_ITEMS", function(_, _, output)
    local ok, msg = process_one_ap_item()
    output:Log("BPMAP_PROCESS_ITEMS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

-- ============================================================
-- Begin Play / initialization
-- ============================================================

RegisterBeginPlayPostHook(function(ContextParam)
    local context = ContextParam:get()
    if valid(context) then
        local full = fullname(context)
        if string.find(full, "BP_BPMPlayerCharacter_C", 1, true) then
            Player = context
            if not HooksInstalled then install_hooks(context) end
        end
    end
end)

local p = get_player()
if p then install_hooks(p) end

local reward_ok, reward_installed = install_confirmed_reward_hooks()
if reward_ok then
    Log("Confirmed reward hooks installed: " .. tostring(reward_installed))
else
    Log("WARNING: confirmed reward hook installation incomplete: " .. tostring(reward_installed))
end

install_coin_pickup_check()

Log("BPMArchipelago v1.5.0 first real patch active")
Log("Confirmed automatic reward triggers: Treasure + Challenge")
Log("Automatic AP item delivery: event-driven")
