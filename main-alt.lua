-- ============================================================
-- BPM Archipelago v1.5.0
-- Expanded Location Catalog + Stable Runtime + Automatic Item Delivery
--
-- IMPORTANT v1.5.0 first real patch runtime design:
--   * Location checks use the previously proven direct
--     outgoing.txt path.
--   * Gameplay callbacks do not scan actors or perform
--     diagnostic logging.
--   * Coin/key/stat/item/weapon counters are kept in memory.
--   * AP incoming items are processed automatically outside
--     gameplay hooks.
--   * The incoming reader uses the LAST SESSION block in
--     incoming.txt, so stale sessions cannot hide the current one.
--   * Automatic item processing uses UE4SS game-thread delayed
--     actions when available.
--   * Manual BPMAP_PROCESS_ITEMS remains available.
-- ============================================================

local function Log(msg)
    print("[BPMArchipelago] " .. tostring(msg) .. "\n")
end

local SCRIPT_DIR = debug.getinfo(1).source:sub(2):match("(.*[\\/])")
local PATH_SEP = package.config:sub(1, 1)
local IPC_DIR = SCRIPT_DIR .. ".." .. PATH_SEP .. "IPC" .. PATH_SEP

-- ============================================================
-- Basic file helpers
-- ============================================================

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

local function ipc_ready()
    return write_file(".bpm_ipc_probe", "ok\n")
end

local IPC_READY = ipc_ready()

if IPC_READY then
    os.remove(IPC_DIR .. ".bpm_ipc_probe")
end

write_file(
    "boot.txt",
    "BPMArchipelago v1.5.1 loaded\n" ..
    "IPC_READY=" .. tostring(IPC_READY) .. "\n" ..
    "IPC_DIR=" .. IPC_DIR .. "\n"
)

write_file(
    "status.txt",
    "v1.4.4 runtime loaded IPC_READY=" .. tostring(IPC_READY) .. "\n" ..
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

local ProcessedItems = {}
local CurrentAPSession = ""

-- Forward declaration: assigned later after AP item helpers exist.
local process_one_ap_item
local automatic_process_items

-- Event-driven automatic item delivery state.
local AutoItemProcessing = false
local AutoItemTriggerCount = 0
local AutoItemSuccessCount = 0
local AutoItemErrorCount = 0
local AutoItemLastTrigger = "none"
local AutoItemLastResult = "none"
local AutoItemLastIndex = nil
local AutoItemLastID = nil
local IncomingSession = nil

local DEBUG_ITEM_CALLS = false

-- ============================================================
-- Archipelago Item Map
-- ============================================================

local ITEM_MAP = {
    [11927553] = { type = "COINS", amount = 5,  name = "Coins +5" },
    [11927554] = { type = "COINS", amount = 10, name = "Coins +10" },
    [11927555] = { type = "KEYS", amount = 1, name = "Keys +1" },
    [11927556] = { type = "KEYS", amount = 5, name = "Keys +5" },
    [11927557] = { type = "HEALTHCONTAINER", amount = 1, name = "Health Container (random +1 to +25; rare +76)" },
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

-- ============================================================
-- Gameplay hook targets
-- ============================================================

local TARGETS = {
    "OnPickupWeaponGeneric",
    "OnPickupAbilityGeneric",
    "OnRoomCleared",
    "OnVictory",
    "AddCoins",
    "AddKeys",
    "GiveKeys",
    "AddHealthContainer",
    "GiveHealth",
    "AddShieldHealth",
    "AddPlayerStatWeaponDamage",
    "AddPlayerStatWeaponCritical",
    "AddPlayerStatRange",
    "AddPlayerStatMovementSpeed",
    "AddPlayerStatLuck",
    "AddPlayerStatExtraAmmo",
    "AddPlayerStatAbilityPower"
}

local TARGET_PATHS = {}
for _, name in ipairs(TARGETS) do
    TARGET_PATHS[name] = "/Script/BPM.BPMCharacter:" .. name
end

-- ============================================================
-- Validation / player helpers
-- ============================================================

local function valid(obj)
    return obj and obj.IsValid and obj:IsValid()
end

local function fullname(obj)
    if not valid(obj) then return "<invalid>" end
    local ok, s = pcall(function() return obj:GetFullName() end)
    return ok and tostring(s) or "<fullname-error>"
end

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
-- Location state
-- ============================================================

local KeyPickupCount = 0
local KeyTotalCount = 0
local KeyMilestonesSent = {}

local StatPickupCount = 0
local StatStackCount = 0
local StatStackCompleteSent = false

local ItemPickupCount = 0
local WeaponPickupCount = 0

local BossChecksSent = {}
local AltarPickupCount = 0

-- ============================================================
-- Confirmed reward-event locations
--
-- Confirmed runtime hooks:
--   ConsumeAndReturnRandomTreasureItem
--   ConsumeAndReturnRandomChallengeItem
--
-- Each confirmed reward event checks the next corresponding AP
-- location, up to 10 per category per Archipelago session.
-- ============================================================

local TREASURE_LOCATION_IDS = {
    [1] = 11993206, [2] = 11993207, [3] = 11993208, [4] = 11993209, [5] = 11993210,
    [6] = 11993211, [7] = 11993212, [8] = 11993213, [9] = 11993214, [10] = 11993215
}

local CHALLENGE_REWARD_LOCATION_IDS = {
    [1] = 11993216, [2] = 11993217, [3] = 11993218, [4] = 11993219, [5] = 11993220,
    [6] = 11993221, [7] = 11993222, [8] = 11993223, [9] = 11993224, [10] = 11993225
}

local TreasureRewardCount = 0
local ChallengeRewardCount = 0
local RewardStateBySession = {}
local RewardActiveSession = ""


local KEY_LOCATION_IDS = {
    [1] = 11993116, [2] = 11993117, [3] = 11993118, [4] = 11993119, [5] = 11993120,
    [6] = 11993121, [7] = 11993122, [8] = 11993123, [9] = 11993124, [10] = 11993125
}

local KEY_MILESTONE_IDS = {
    [5] = 11993126, [10] = 11993127, [20] = 11993128
}

local STAT_LOCATION_IDS = {
    [1] = 11993129, [2] = 11993130, [3] = 11993131, [4] = 11993132, [5] = 11993133,
    [6] = 11993134, [7] = 11993135, [8] = 11993136, [9] = 11993137
}

local STAT_STACK_LOCATION_ID = 11993138

local ITEM_PICKUP_LOCATION_IDS = {
    [1] = 11993139, [2] = 11993140, [3] = 11993141, [4] = 11993142, [5] = 11993143,
    [6] = 11993144, [7] = 11993145, [8] = 11993146, [9] = 11993147, [10] = 11993148
}

local WEAPON_PICKUP_LOCATION_IDS = {
    [1] = 11993149, [2] = 11993150, [3] = 11993151, [4] = 11993152, [5] = 11993153,
    [6] = 11993154, [7] = 11993155, [8] = 11993156, [9] = 11993157, [10] = 11993158
}

local BOSS_LOCATION_IDS = {
    ["Surt"] = 11993159,
    ["Mistcalf"] = 11993160,
    ["Alvis"] = 11993161,
    ["Gullveig"] = 11993162,
    ["Vétt"] = 11993163,
    ["Ymir"] = 11993164,
    ["Fafnir"] = 11993165,
    ["Draugr"] = 11993166
}

local ALTAR_LOCATION_IDS = {
    [1] = 11993167, [2] = 11993168, [3] = 11993169,
    [4] = 11993170, [5] = 11993171
}

-- Expanded location groups added in v1.4.0.
local CHEST_LOCATION_IDS = {
    [1] = 11993172, [2] = 11993173, [3] = 11993174, [4] = 11993175, [5] = 11993176,
    [6] = 11993177, [7] = 11993178, [8] = 11993179, [9] = 11993180, [10] = 11993181
}

local CHALLENGE_ROOM_LOCATION_IDS = {
    [1] = 11993182, [2] = 11993183, [3] = 11993184, [4] = 11993185, [5] = 11993186,
    [6] = 11993187, [7] = 11993188, [8] = 11993189, [9] = 11993190, [10] = 11993191
}

local FLOOR_CLEAR_LOCATION_IDS = {
    [1] = 11993192, [2] = 11993193, [3] = 11993194, [4] = 11993195, [5] = 11993196,
    [6] = 11993197, [7] = 11993198, [8] = 11993199, [9] = 11993200, [10] = 11993201,
    [11] = 11993202, [12] = 11993203, [13] = 11993204, [14] = 11993205
}

-- ============================================================
-- Coin locations/state
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

local CoinIndividualCount = 0
local CoinTotalCount = 0
local CoinMilestonesSent = {}
local CoinStateBySession = {}
local CoinStateDirty = false

-- ============================================================
-- Direct AP location check IPC
--
-- This intentionally uses direct disk I/O because this exact path
-- was already proven to reach Archipelago. Only one short append is
-- performed for a qualifying event; no actor scanning/reflection/logs.
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
-- Coin persistence
-- ============================================================

local function reset_active_coin_state()
    CoinIndividualCount = 0
    CoinTotalCount = 0
    CoinMilestonesSent = {}
    CoinStateDirty = true
end

local function save_coin_state(session)
    session = tostring(session or "")
    if session == "" then return false end

    local state = {
        individual = CoinIndividualCount,
        total = CoinTotalCount,
        m5 = CoinMilestonesSent[5] and 1 or 0,
        m10 = CoinMilestonesSent[10] and 1 or 0,
        m25 = CoinMilestonesSent[25] and 1 or 0
    }

    CoinStateBySession[session] = state

    return append_file(
        "coin_state.txt",
        "STATE|" .. session .. "|" ..
        tostring(state.individual) .. "|" ..
        tostring(state.total) .. "|" ..
        tostring(state.m5) .. "|" ..
        tostring(state.m10) .. "|" ..
        tostring(state.m25) .. "\n"
    )
end

local function load_coin_state()
    CoinStateBySession = {}

    local f = io.open(IPC_DIR .. "coin_state.txt", "r")
    if not f then return end

    for line in f:lines() do
        local session, individual_text, total_text, m5_text, m10_text, m25_text =
            line:match("^STATE|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")

        if session then
            local individual = tonumber(individual_text)
            local total = tonumber(total_text)

            if individual and total then
                CoinStateBySession[session] = {
                    individual = individual,
                    total = total,
                    m5 = tonumber(m5_text) or 0,
                    m10 = tonumber(m10_text) or 0,
                    m25 = tonumber(m25_text) or 0
                }
            end
        end
    end

    f:close()
end

load_coin_state()

local function activate_coin_session(session)
    session = tostring(session or "")
    if session == "" then return false end

    if CurrentAPSession == session then
        return true
    end

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

    CoinStateDirty = false
    return true
end

-- ============================================================
-- Return the LAST SESSION in incoming.txt.
-- This fixes stale-session files where older SESSION blocks precede
-- the currently connected AP seed.
-- ============================================================

local function find_session_in_incoming()
    local f = io.open(IPC_DIR .. "incoming.txt", "r")
    if not f then return nil end

    local session = nil

    for line in f:lines() do
        local found = line:match("^SESSION|(.+)$")
        if found then
            found = tostring(found):gsub("^%s+", ""):gsub("%s+$", "")
            if found ~= "" then
                session = found
            end
        end
    end

    f:close()
    return session
end

local function sync_coin_session()
    local session = find_session_in_incoming()

    if session then
        activate_coin_session(session)
        IncomingSession = session
        return true, session
    end

    return false, "no SESSION found in incoming.txt"
end

local function ensure_ap_session()
    if CurrentAPSession ~= "" then return true end
    return sync_coin_session() == true
end

-- ============================================================
-- Coin pickup callback
-- ============================================================

local function process_coin_pickup()
    CoinPickupCallbackCount = CoinPickupCallbackCount + 1

    if CurrentAPSession == "" then
        return
    end

    CoinTotalCount = CoinTotalCount + 1

    if CoinIndividualCount < 10 then
        CoinIndividualCount = CoinIndividualCount + 1

        local location_id = COIN_LOCATION_IDS[CoinIndividualCount]
        if location_id then
            queue_ap_location_check(location_id)
        end
    end

    local milestone_id = COIN_MILESTONE_IDS[CoinTotalCount]

    if milestone_id and not CoinMilestonesSent[CoinTotalCount] then
        CoinMilestonesSent[CoinTotalCount] = true
        queue_ap_location_check(milestone_id)
    end

    CoinStateDirty = true
end

-- ============================================================
-- Generic pickup processors
-- ============================================================

local process_weapon_pickup
local process_item_pickup

local function process_key_pickup()
    if not ensure_ap_session() then return end

    KeyTotalCount = KeyTotalCount + 1

    if KeyPickupCount < 10 then
        KeyPickupCount = KeyPickupCount + 1

        local location_id = KEY_LOCATION_IDS[KeyPickupCount]
        if location_id then queue_ap_location_check(location_id) end
    end

    local milestone_id = KEY_MILESTONE_IDS[KeyTotalCount]

    if milestone_id and not KeyMilestonesSent[KeyTotalCount] then
        KeyMilestonesSent[KeyTotalCount] = true
        queue_ap_location_check(milestone_id)
    end
end

local function process_stat_pickup()
    if not ensure_ap_session() then return end

    StatPickupCount = StatPickupCount + 1
    StatStackCount = StatStackCount + 1

    if StatPickupCount <= 9 then
        local location_id = STAT_LOCATION_IDS[StatPickupCount]
        if location_id then queue_ap_location_check(location_id) end
    end

    if StatStackCount >= 9 and not StatStackCompleteSent then
        StatStackCompleteSent = true
        queue_ap_location_check(STAT_STACK_LOCATION_ID)
    end
end

process_item_pickup = function()
    if CurrentAPSession == "" then return end
    if ItemPickupCount >= 10 then return end

    ItemPickupCount = ItemPickupCount + 1

    local location_id = ITEM_PICKUP_LOCATION_IDS[ItemPickupCount]
    if location_id then queue_ap_location_check(location_id) end
end

process_weapon_pickup = function()
    if CurrentAPSession == "" then return end
    if WeaponPickupCount >= 10 then return end

    WeaponPickupCount = WeaponPickupCount + 1

    local location_id = WEAPON_PICKUP_LOCATION_IDS[WeaponPickupCount]
    if location_id then queue_ap_location_check(location_id) end
end

local function process_boss_check(boss_name)
    if not boss_name or CurrentAPSession == "" then return end
    if BossChecksSent[boss_name] then return end

    local location_id = BOSS_LOCATION_IDS[boss_name]
    if not location_id then return end

    BossChecksSent[boss_name] = true
    queue_ap_location_check(location_id)
end

local function process_altar_pickup()
    if CurrentAPSession == "" then return end
    if AltarPickupCount >= 5 then return end

    AltarPickupCount = AltarPickupCount + 1

    local location_id = ALTAR_LOCATION_IDS[AltarPickupCount]
    if location_id then queue_ap_location_check(location_id) end
end

-- ============================================================
-- Confirmed reward-event checker
-- ============================================================

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

local function load_reward_state()
    RewardStateBySession = {}
    local f = io.open(IPC_DIR .. "reward_state.txt", "r")
    if not f then return end

    for line in f:lines() do
        local session, treasure_text, challenge_text =
            line:match("^STATE|([^|]+)|([^|]+)|([^|]+)$")
        if session then
            RewardStateBySession[session] = {
                treasure = tonumber(treasure_text) or 0,
                challenge = tonumber(challenge_text) or 0
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

load_reward_state()

local function process_confirmed_reward(kind)
    local synced, session = sync_coin_session()
    if not synced then return false, "no active AP session" end

    if RewardActiveSession ~= session then
        activate_reward_session(session)
    end

    local count
    local location_id

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

    if not location_id then
        return false, "no location ID for reward index " .. tostring(count)
    end

    local ok = queue_ap_location_check(location_id)
    if not ok then
        return false, "could not queue location " .. tostring(location_id)
    end

    save_reward_state(session)
    return true, kind .. " reward " .. tostring(count) .. " -> location " .. tostring(location_id)
end

-- ============================================================
-- RegisterHook callback counters
--
-- These are memory-only diagnostics. They let us verify that the
-- exact Unreal function used by each AP item really executes.
-- No filesystem I/O is performed by these callbacks.
-- ============================================================

local RegisterHookCounts = {}

for _, name in ipairs(TARGETS) do
    RegisterHookCounts[name] = 0
end

local RegisterHookLastFunction = "none"

-- ============================================================
-- Hook callback
--
-- Automatic AP item delivery is event-driven. We do NOT depend
-- on UE4SS delayed-action/game-thread timers because this BPM
-- configuration reports no supported delayed-action execution
-- mode.
--
-- Coin pickup intentionally does NOT process incoming items here:
-- coin pickups are high-frequency and must remain lightweight.
-- Item/weapon pickups, room clears, and victory are suitable
-- game-thread trigger points for processing at most one AP item.
-- ============================================================

local function hook_callback(name)
    local pre_callback = function(...)
        RegisterHookCounts[name] = (RegisterHookCounts[name] or 0) + 1
        RegisterHookLastFunction = name
    end

    local post_callback = nil

    -- AddCoins/AddKeys are confirmed live RegisterHook callbacks and are
    -- the primary safe automatic AP-item trigger points. Process at most
    -- one queued AP item per callback.
    if name == "AddCoins" or name == "AddKeys" then
        post_callback = function(...)
            if automatic_process_items then
                automatic_process_items(name)
            end
        end
    elseif name == "OnPickupWeaponGeneric" then
        post_callback = function(...)
            if process_weapon_pickup then
                process_weapon_pickup()
            end

            if automatic_process_items then
                automatic_process_items(
                    "OnPickupWeaponGeneric"
                )
            end
        end

    elseif name == "OnPickupAbilityGeneric" then
        post_callback = function(...)
            if process_item_pickup then
                process_item_pickup()
            end

            if automatic_process_items then
                automatic_process_items(
                    "OnPickupAbilityGeneric"
                )
            end
        end
    end

    return pre_callback, post_callback
end

-- ============================================================
-- Confirmed reward hook installation
-- ============================================================

local ConfirmedRewardHookIDs = {}
local ConfirmedRewardHooksInstalled = false

local CONFIRMED_REWARD_HOOKS = {
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

local ConfirmedRewardCallbackCounts = {
    TREASURE = 0,
    CHALLENGE = 0
}

local ConfirmedRewardLast = "none"

local function install_confirmed_reward_hooks()
    if ConfirmedRewardHooksInstalled then
        return true, "already installed"
    end

    local installed, failed = 0, 0

    for _, target in ipairs(CONFIRMED_REWARD_HOOKS) do
        local ok, a, b = pcall(function()
            return RegisterHook(
                target.path,
                function(...)
                    ConfirmedRewardCallbackCounts[target.kind] =
                        (ConfirmedRewardCallbackCounts[target.kind] or 0) + 1
                    ConfirmedRewardLast = target.name

                    local reward_ok, reward_msg = process_confirmed_reward(target.kind)
                    if not reward_ok then
                        Log("Confirmed " .. target.kind .. " reward check failed: " .. tostring(reward_msg))
                    end

                    if automatic_process_items then
                        automatic_process_items(target.name)
                    end
                end
            )
        end)

        if ok then
            ConfirmedRewardHookIDs[target.kind] = { a, b }
            installed = installed + 1
        else
            failed = failed + 1
            Log("FAILED reward hook " .. target.path .. ": " .. tostring(a))
        end
    end

    ConfirmedRewardHooksInstalled = installed > 0
    return ConfirmedRewardHooksInstalled,
        "installed=" .. tostring(installed) .. " failed=" .. tostring(failed)
end

RegisterConsoleCommandHandler("BPMAP_REWARD_STATUS", function(_, _, output)
    output:Log(
        "BPMAP_REWARD_STATUS: installed=" .. tostring(ConfirmedRewardHooksInstalled) ..
        " treasure_callbacks=" .. tostring(ConfirmedRewardCallbackCounts.TREASURE or 0) ..
        " treasure_checks=" .. tostring(TreasureRewardCount) .. "/10" ..
        " challenge_callbacks=" .. tostring(ConfirmedRewardCallbackCounts.CHALLENGE or 0) ..
        " challenge_checks=" .. tostring(ChallengeRewardCount) .. "/10" ..
        " session=" .. tostring(RewardActiveSession) ..
        " last=" .. tostring(ConfirmedRewardLast) .. "\n"
    )
    return true
end)

-- ============================================================
-- Generic hook installation
-- ============================================================

local function install_hooks(player)
    if HooksInstalled then return true, "already installed" end
    if not valid(player) then return false, "player invalid" end

    write_file(
        "hook_status.txt",
        "BOOT\nPLAYER\t" .. fullname(player) .. "\n"
    )

    local installed = 0
    local failed = 0

    for _, name in ipairs(TARGETS) do
        local path = TARGET_PATHS[name]
        append_file("hook_status.txt", "TRY\t" .. name .. "\t" .. path .. "\n")

        local pre_callback, post_callback = hook_callback(name)

        local ok, a, b =
            pcall(
            function()
                return RegisterHook(path, pre_callback, post_callback)
            end
        )

        if ok then
            HookIDs[name] = { a, b }
            installed = installed + 1
            append_file("hook_status.txt", "INSTALLED\t" .. name .. "\t" .. tostring(a) .. "\t" .. tostring(b) .. "\n")
        else
            failed = failed + 1
            append_file("hook_status.txt", "FAILED\t" .. name .. "\t" .. tostring(a) .. "\n")
        end
    end

    if installed > 0 then
        HooksInstalled = true
    end

    append_file(
        "hook_status.txt",
        "HOOK_INSTALL_DONE\tinstalled=" .. tostring(installed) .. "\tfailed=" .. tostring(failed) .. "\n"
    )

    write_file(
        "status.txt",
        "v1.5.0 hooks installed=" .. tostring(installed) ..
        " failed=" .. tostring(failed) ..
        " IPC_READY=" .. tostring(IPC_READY) .. "\n" ..
        "IPC_DIR=" .. IPC_DIR .. "\n"
    )

    return true, "installed=" .. tostring(installed) .. " failed=" .. tostring(failed)
end

-- ============================================================
-- Coin hook installation
-- ============================================================

local function install_coin_pickup_check()
    if CoinPickupHookInstalled then return true, "already installed" end

    local synced, session = sync_coin_session()
    if synced then
        Log("Coin tracking session=" .. tostring(session))
    else
        Log("WARNING: coin hook installed without an AP SESSION; coin checks will wait")
    end

    local ok, a, b =
        pcall(
        function()
            return RegisterHook(
                COIN_PICKUP_PATH,
                function(...)
                    process_coin_pickup()
                end
            )
        end
    )

    if not ok then
        return false, "RegisterHook failed: " .. tostring(a)
    end

    CoinPickupHookID = { a, b }
    CoinPickupHookInstalled = true

    return true, "coin pickup check installed"
end

-- ============================================================
-- Numeric / AP item helpers
-- ============================================================

local function get_getter(player, getter_name)
    if not valid(player) then return nil end

    local fn = player[getter_name]
    if not fn or not fn.IsValid or not fn:IsValid() then return nil end

    local ok, value = pcall(function() return fn(player) end)
    return ok and value or nil
end

local function numeric_amount(parameters)
    if not parameters or parameters[1] == nil then return 1 end
    local n = tonumber(parameters[1])
    return n
end

local function call_numeric(player, function_name, amount)
    if amount == nil then return false, "invalid numeric amount" end
    if not valid(player) then return false, "player invalid" end

    local fn = player[function_name]
    if not fn or not fn.IsValid or not fn:IsValid() then
        return false, "function not valid: " .. function_name
    end

    local before = "<no-getter>"
    local after = "<no-getter>"

    local getter_name = ({
        AddCoins = "GetCoins",
        AddKeys = "GetKeys"
    })[function_name]

    if DEBUG_ITEM_CALLS and getter_name then
        local v = get_getter(player, getter_name)
        if v ~= nil then before = tostring(v) end
    end

    local ok, result = pcall(function() return fn(player, amount) end)

    if DEBUG_ITEM_CALLS and getter_name then
        local v = get_getter(player, getter_name)
        if v ~= nil then after = tostring(v) end
    end

    if DEBUG_ITEM_CALLS then
        append_file(
            "call_tests.txt",
            string.format(
                "TEST\t%s\tamount=%s\tok=%s\tbefore=%s\tafter=%s\tresult=%s\n",
                function_name,
                tostring(amount),
                tostring(ok),
                before,
                after,
                tostring(result)
            )
        )
    end

    return ok, tostring(result)
end

local STAT_FUNCTIONS = {
    ADDDAMAGE = "AddPlayerStatWeaponDamage",
    ADDCRIT = "AddPlayerStatWeaponCritical",
    ADDRANGE = "AddPlayerStatRange",
    ADDSPEED = "AddPlayerStatMovementSpeed",
    ADDLUCK = "AddPlayerStatLuck",
    ADEXTRAMMO = "AddPlayerStatExtraAmmo",
    ADDABILITYPOWER = "AddPlayerStatAbilityPower",
    ADDSHIELD = "AddShieldHealth",
    ADDHEALTH = "GiveHealth",
    ADDHEALTHCONTAINER = "AddHealthContainer"
}

-- Health Container AP reward roll:
-- Normal: one or more native AddHealthContainer calls, for a random
-- integer +1..+25 Max HP. Each native call is +1 Max HP.
-- Rare: +76 Max HP at 0.0076% probability (0.000076).
local HEALTH_CONTAINER_RARE_CHANCE = 0.000076

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
        local ok = append_file("outgoing.txt", "GOAL\n")
        if not ok then return false, "could not write GOAL to outgoing.txt" end
        return true, "Victory: GOAL queued"
    end

    local amount = tonumber(item.amount)
    if amount == nil and item_type ~= "HEALTHCONTAINER" then
        return false, "invalid amount for AP item " .. tostring(item_id)
    end

    local function_name
    local health_container_rare = false

    if item_type == "COINS" then function_name = "AddCoins"
    elseif item_type == "KEYS" then function_name = "AddKeys"
    elseif item_type == "HEALTHCONTAINER" then
        amount, health_container_rare = roll_health_container_amount()
        function_name = "AddHealthContainer"
    elseif item_type == "DAMAGE" then function_name = "AddPlayerStatWeaponDamage"
    elseif item_type == "CRIT" then function_name = "AddPlayerStatWeaponCritical"
    elseif item_type == "RANGE" then function_name = "AddPlayerStatRange"
    elseif item_type == "SPEED" then function_name = "AddPlayerStatMovementSpeed"
    elseif item_type == "LUCK" then function_name = "AddPlayerStatLuck"
    elseif item_type == "EXTRAMMO" then function_name = "AddPlayerStatExtraAmmo"
    elseif item_type == "ABILITYPOWER" then function_name = "AddPlayerStatAbilityPower"
    end

    if function_name then
        if item_type == "HEALTHCONTAINER" then
            -- BPM's native AddHealthContainer(n) was verified to add exactly
            -- n Max HP when called directly, but the tested native function
            -- itself behaves as +1 per call. Use one call per rolled point.
            -- This preserves the requested +1..+25 distribution and the rare
            -- +76 roll without assuming an unsupported larger native argument.
            for _ = 1, amount do
                local ok, result = call_numeric(player, function_name, 1)
                if not ok then
                    return false, "grant failed after " .. tostring(_ - 1) .. "/" .. tostring(amount) .. " Max HP: " .. tostring(result)
                end
            end

            if health_container_rare then
                return true, "Health Container +76 MAX HP (rare 0.0076% roll)"
            end
            return true, "Health Container +" .. tostring(amount) .. " MAX HP"
        end

        local ok, result = call_numeric(player, function_name, amount)
        if not ok then return false, "grant failed: " .. tostring(result) end
        return true, tostring(item.name or item_type) .. " +" .. tostring(amount)
    end

    return false, "unsupported AP item type: " .. item_type
end

-- ============================================================
-- Processed item persistence
-- ============================================================

local function load_processed_items()
    ProcessedItems = {}

    local f = io.open(IPC_DIR .. "processed_items.txt", "r")
    if not f then return end

    for line in f:lines() do
        local session, index_text = line:match("^([^|]+)|([^|]+)$")
        if session and index_text then
            local index = tonumber(index_text)
            if index ~= nil then
                ProcessedItems[session .. "|" .. tostring(index)] = true
            end
        end
    end

    f:close()
end

load_processed_items()

local function processed_item_key(session, absolute_index)
    return tostring(session) .. "|" .. tostring(absolute_index)
end

local function record_processed_item(session, absolute_index)
    local key = processed_item_key(session, absolute_index)
    if ProcessedItems[key] then return true end

    local ok = append_file(
        "processed_items.txt",
        tostring(session) .. "|" .. tostring(absolute_index) .. "\n"
    )

    if ok then ProcessedItems[key] = true end
    return ok
end

local function item_ack(absolute_index, result, detail)
    local safe_detail = tostring(detail or "")
    safe_detail = safe_detail:gsub("[\r\n|]", " ")

    append_file(
        "outgoing.txt",
        "ITEM_ACK|" .. tostring(absolute_index) .. "|" ..
        tostring(result) .. "|" .. safe_detail .. "\n"
    )
end

-- ============================================================
-- Find/process the current AP session block
--
-- We intentionally scan for the LAST SESSION in the file. The
-- Python client may append multiple SESSION markers over time.
-- Only ITEM lines after the latest SESSION belong to the current
-- connection/session.
-- ============================================================

process_one_ap_item = function()
    local f = io.open(IPC_DIR .. "incoming.txt", "r")
    if not f then
        return false, "incoming.txt could not be opened"
    end

    local latest_session = nil
    local latest_items = {}

    for line in f:lines() do
        local session = line:match("^SESSION|(.+)$")

        if session then
            session = tostring(session):gsub("^%s+", ""):gsub("%s+$", "")

            if session ~= "" then
                latest_session = session
                latest_items = {}
            end
        else
            local absolute_text, item_id_text, description =
                line:match("^ITEM|([^|]+)|([^|]+)|(.*)$")

            if absolute_text and item_id_text and latest_session then
                local absolute_index = tonumber(absolute_text)
                local item_id = tonumber(item_id_text)

                if absolute_index and item_id then
                    table.insert(
                        latest_items,
                        {
                            index = absolute_index,
                            item_id = item_id,
                            description = description
                        }
                    )
                end
            end
        end
    end

    f:close()

    if not latest_session then
        return false, "no Archipelago session found"
    end

    IncomingSession = latest_session
    activate_coin_session(latest_session)

    -- Process the first currently unprocessed item in the newest session.
    for _, item in ipairs(latest_items) do
        local key = processed_item_key(
            latest_session,
            item.index
        )

        if not ProcessedItems[key] then
            local player = get_player()

            if not player then
                item_ack(
                    item.index,
                    "ERROR",
                    "player not found"
                )
                return false, "player not found"
            end

            CurrentAPSession = latest_session
            AutoItemLastIndex = item.index
            AutoItemLastID = item.item_id

            local ok, result = grant_ap_item(
                player,
                item.item_id
            )

            if ok then
                local recorded = record_processed_item(
                    latest_session,
                    item.index
                )

                if not recorded then
                    item_ack(
                        item.index,
                        "ERROR",
                        "grant succeeded but processed_items.txt could not be written"
                    )
                    return false,
                        "grant succeeded but could not record item"
                end

                item_ack(
                    item.index,
                    "OK",
                    result
                )

                Log(
                    "AP item " ..
                    tostring(item.index) ..
                    " granted: " ..
                    tostring(result)
                )

                return true, "item processed"
            end

            item_ack(
                item.index,
                "ERROR",
                "grant failed: " .. tostring(result)
            )

            Log(
                "AP item " ..
                tostring(item.index) ..
                " failed: " ..
                tostring(result)
            )

            return false,
                "grant failed: " .. tostring(result)
        end
    end

    return false, "no new AP item"
end

-- ============================================================
-- Automatic AP item processing
--
-- Event-driven rather than timer-driven.
--
-- A BPM gameplay hook calls automatic_process_items(), which
-- processes at most ONE queued AP item on the game thread.
-- This preserves safe Unreal object access without requiring
-- ExecuteInGameThread/Delayed Actions, which are unavailable in
-- this UE4SS/BPM configuration.
-- ============================================================

local AUTOMATIC_ITEM_PROCESSING_ENABLED = true

automatic_process_items = function(trigger_name)
    if not AUTOMATIC_ITEM_PROCESSING_ENABLED then
        return
    end

    if AutoItemProcessing then
        return
    end

    AutoItemProcessing = true
    AutoItemTriggerCount = AutoItemTriggerCount + 1
    AutoItemLastTrigger = tostring(trigger_name or "unknown")

    local ok, processed, detail = pcall(process_one_ap_item)

    if not ok then
        AutoItemErrorCount = AutoItemErrorCount + 1
        AutoItemLastResult = "exception"
        Log("Automatic AP item processing error: " .. tostring(processed))
    else
        AutoItemLastResult = tostring(detail or "no new AP item")
        if processed then
            AutoItemSuccessCount = AutoItemSuccessCount + 1
        end
    end

    AutoItemProcessing = false
end

-- This command no longer starts a timer. It reports that
-- event-driven automatic processing is armed.
local function auto_items_command(_, _, output)
    output:Log(
        "BPMAP_AUTO_ITEMS: true event-driven item processing armed " ..
        "hooks=" .. tostring(HooksInstalled) ..
        " last_trigger=" .. tostring(AutoItemLastTrigger) ..
        "\n"
    )

    return true
end

RegisterConsoleCommandHandler(
    "BPMAP_AUTO_ITEMS",
    auto_items_command
)

RegisterConsoleCommandHandler(
    "BPMAP_AUTOITEMS",
    auto_items_command
)

-- ============================================================
-- Optional one-time startup probe
--
-- Do not process immediately here unless the AP session is
-- already loaded; normal event hooks will process the queue.
-- ============================================================

local function initialize_auto_item_processing()
    AUTOMATIC_ITEM_PROCESSING_ENABLED = true
    return true, "event-driven hooks armed"
end

local auto_items_ok, auto_items_msg =
    initialize_auto_item_processing()

Log(
    "Automatic item processing: " ..
    tostring(auto_items_ok) ..
    " " ..
    tostring(auto_items_msg)
)

-- Install the two confirmed low-frequency reward hooks.
local reward_hooks_ok, reward_hooks_msg = install_confirmed_reward_hooks()
Log("Confirmed reward hooks: " .. tostring(reward_hooks_ok) .. " " .. tostring(reward_hooks_msg))

-- ============================================================
-- Core status/path/test commands
-- ============================================================

RegisterConsoleCommandHandler(
    "BPMAP_STATUS",
    function(_, _, output)
        output:Log(
            string.format(
                "BPMArchipelago v1.5.1: bridge alive IPC_READY=%s hooks_installed=%s auto_items=%s mode=%s session=%s\n",
                tostring(IPC_READY),
                tostring(HooksInstalled),
                tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED),
                "event-hooks",
                tostring(CurrentAPSession)
            )
        )
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_RUNTIME_STATUS",
    function(_, _, output)
        output:Log(
            "BPMAP_RUNTIME_STATUS: " ..
            "mode=event-hooks" ..
            " enabled=" .. tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED) ..
            " busy=" .. tostring(AutoItemProcessing) ..
            " triggers=" .. tostring(AutoItemTriggerCount) ..
            " processed=" .. tostring(AutoItemSuccessCount) ..
            " errors=" .. tostring(AutoItemErrorCount) ..
            " last_trigger=" .. tostring(AutoItemLastTrigger) ..
            " session=" .. tostring(CurrentAPSession) ..
            " incoming_session=" .. tostring(IncomingSession) ..
            " direct_checks=true\n"
        )
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_PATH",
    function(_, _, output)
        output:Log("IPC=" .. IPC_DIR .. " ready=" .. tostring(IPC_READY) .. "\n")
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_WRITE_TEST",
    function(_, _, output)
        local ok = write_file("write_test.txt", "write test OK\n")
        output:Log("write test=" .. tostring(ok) .. "\n")
        return true
    end
)

-- ============================================================
-- Core coin commands
-- ============================================================

RegisterConsoleCommandHandler(
    "BPMAP_COIN_CHECK",
    function(_, _, output)
        local synced, session = sync_coin_session()

        if synced then
            output:Log("BPMAP_COIN_CHECK: AP session=" .. tostring(session) .. "\n")
        else
            output:Log("BPMAP_COIN_CHECK: no AP SESSION currently found; hook can still be installed\n")
        end

        local ok, msg = install_coin_pickup_check()

        output:Log(
            "BPMAP_COIN_CHECK: " ..
            tostring(ok) .. " " .. tostring(msg) .. "\n"
        )
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_COIN_STATUS",
    function(_, _, output)
        output:Log(
            "BPMAP_COIN_STATUS:" ..
            " installed=" .. tostring(CoinPickupHookInstalled) ..
            " callbacks=" .. tostring(CoinPickupCallbackCount) ..
            " session=" .. tostring(CurrentAPSession) ..
            " individual=" .. tostring(CoinIndividualCount) .. "/10" ..
            " total=" .. tostring(CoinTotalCount) ..
            " milestone5=" .. tostring(CoinMilestonesSent[5] == true) ..
            " milestone10=" .. tostring(CoinMilestonesSent[10] == true) ..
            " milestone25=" .. tostring(CoinMilestonesSent[25] == true) ..
            "\n"
        )
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_COIN_SESSION",
    function(_, _, output)
        local ok, session = sync_coin_session()

        if ok then
            output:Log(
                "BPMAP_COIN_SESSION: active=" ..
                tostring(session) ..
                " individual=" .. tostring(CoinIndividualCount) ..
                "/10 total=" .. tostring(CoinTotalCount) .. "\n"
            )
        else
            output:Log("BPMAP_COIN_SESSION: " .. tostring(session) .. "\n")
        end
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_COIN_RESET",
    function(_, _, output)
        if CurrentAPSession == "" then
            output:Log("BPMAP_COIN_RESET: no active AP session\n")
            return true
        end

        reset_active_coin_state()

        local ok = save_coin_state(CurrentAPSession)
        CoinStateDirty = false

        output:Log(
            "BPMAP_COIN_RESET: session=" ..
            tostring(CurrentAPSession) ..
            " saved=" .. tostring(ok) .. "\n"
        )
        return true
    end
)

-- ============================================================
-- Manual check commands
-- ============================================================

local LOCATION_MAP = {
    ["Room Clear 01"] = 11993089, ["Room Clear 02"] = 11993090,
    ["Room Clear 03"] = 11993091, ["Room Clear 04"] = 11993092,
    ["Room Clear 05"] = 11993093, ["Room Clear 06"] = 11993094,
    ["Room Clear 07"] = 11993095, ["Room Clear 08"] = 11993096,
    ["Room Clear 09"] = 11993097, ["Room Clear 10"] = 11993098,
    ["Room Clear 11"] = 11993099, ["Room Clear 12"] = 11993100,
    ["Room Clear 13"] = 11993101, ["Room Clear 14"] = 11993102,

    ["Coin 001"] = 11993103, ["Coin 002"] = 11993104,
    ["Coin 003"] = 11993105, ["Coin 004"] = 11993106,
    ["Coin 005"] = 11993107, ["Coin 006"] = 11993108,
    ["Coin 007"] = 11993109, ["Coin 008"] = 11993110,
    ["Coin 009"] = 11993111, ["Coin 010"] = 11993112,
    ["Collect 5 Coins"] = 11993113, ["Collect 10 Coins"] = 11993114,
    ["Collect 25 Coins"] = 11993115,

    ["Key 001"] = 11993116, ["Key 002"] = 11993117,
    ["Key 003"] = 11993118, ["Key 004"] = 11993119,
    ["Key 005"] = 11993120, ["Key 006"] = 11993121,
    ["Key 007"] = 11993122, ["Key 008"] = 11993123,
    ["Key 009"] = 11993124, ["Key 010"] = 11993125,
    ["Collect 5 Keys"] = 11993126, ["Collect 10 Keys"] = 11993127,
    ["Collect 20 Keys"] = 11993128,

    ["Stat Pickup 001"] = 11993129, ["Stat Pickup 002"] = 11993130,
    ["Stat Pickup 003"] = 11993131, ["Stat Pickup 004"] = 11993132,
    ["Stat Pickup 005"] = 11993133, ["Stat Pickup 006"] = 11993134,
    ["Stat Pickup 007"] = 11993135, ["Stat Pickup 008"] = 11993136,
    ["Stat Pickup 009"] = 11993137, ["Stat Stack Complete"] = 11993138,

    ["Item Pickup 001"] = 11993139, ["Item Pickup 002"] = 11993140,
    ["Item Pickup 003"] = 11993141, ["Item Pickup 004"] = 11993142,
    ["Item Pickup 005"] = 11993143, ["Item Pickup 006"] = 11993144,
    ["Item Pickup 007"] = 11993145, ["Item Pickup 008"] = 11993146,
    ["Item Pickup 009"] = 11993147, ["Item Pickup 010"] = 11993148,

    ["Weapon Pickup 001"] = 11993149, ["Weapon Pickup 002"] = 11993150,
    ["Weapon Pickup 003"] = 11993151, ["Weapon Pickup 004"] = 11993152,
    ["Weapon Pickup 005"] = 11993153, ["Weapon Pickup 006"] = 11993154,
    ["Weapon Pickup 007"] = 11993155, ["Weapon Pickup 008"] = 11993156,
    ["Weapon Pickup 009"] = 11993157, ["Weapon Pickup 010"] = 11993158,

    ["Defeat Surt"] = 11993159, ["Defeat Mistcalf"] = 11993160,
    ["Defeat Alvis"] = 11993161, ["Defeat Gullveig"] = 11993162,
    ["Defeat Vétt"] = 11993163, ["Defeat Ymir"] = 11993164,
    ["Defeat Fafnir"] = 11993165, ["Defeat Draugr"] = 11993166,

    ["Altar 001"] = 11993167, ["Altar 002"] = 11993168,
    ["Altar 003"] = 11993169, ["Altar 004"] = 11993170,
    ["Altar 005"] = 11993171,

    ["Chest 001"] = 11993172, ["Chest 002"] = 11993173,
    ["Chest 003"] = 11993174, ["Chest 004"] = 11993175,
    ["Chest 005"] = 11993176, ["Chest 006"] = 11993177,
    ["Chest 007"] = 11993178, ["Chest 008"] = 11993179,
    ["Chest 009"] = 11993180, ["Chest 010"] = 11993181,

    ["Challenge Room 001"] = 11993182, ["Challenge Room 002"] = 11993183,
    ["Challenge Room 003"] = 11993184, ["Challenge Room 004"] = 11993185,
    ["Challenge Room 005"] = 11993186, ["Challenge Room 006"] = 11993187,
    ["Challenge Room 007"] = 11993188, ["Challenge Room 008"] = 11993189,
    ["Challenge Room 009"] = 11993190, ["Challenge Room 010"] = 11993191,

    ["Floor Clear 01"] = 11993192, ["Floor Clear 02"] = 11993193,
    ["Floor Clear 03"] = 11993194, ["Floor Clear 04"] = 11993195,
    ["Floor Clear 05"] = 11993196, ["Floor Clear 06"] = 11993197,
    ["Floor Clear 07"] = 11993198, ["Floor Clear 08"] = 11993199,
    ["Floor Clear 09"] = 11993200, ["Floor Clear 10"] = 11993201,
    ["Floor Clear 11"] = 11993202, ["Floor Clear 12"] = 11993203,
    ["Floor Clear 13"] = 11993204, ["Floor Clear 14"] = 11993205,

    ["Treasure 001"] = 11993206, ["Treasure 002"] = 11993207,
    ["Treasure 003"] = 11993208, ["Treasure 004"] = 11993209,
    ["Treasure 005"] = 11993210, ["Treasure 006"] = 11993211,
    ["Treasure 007"] = 11993212, ["Treasure 008"] = 11993213,
    ["Treasure 009"] = 11993214, ["Treasure 010"] = 11993215,

    ["Challenge Reward 001"] = 11993216, ["Challenge Reward 002"] = 11993217,
    ["Challenge Reward 003"] = 11993218, ["Challenge Reward 004"] = 11993219,
    ["Challenge Reward 005"] = 11993220, ["Challenge Reward 006"] = 11993221,
    ["Challenge Reward 007"] = 11993222, ["Challenge Reward 008"] = 11993223,
    ["Challenge Reward 009"] = 11993224, ["Challenge Reward 010"] = 11993225,

    ["Defeat Nidhogg"] = 12058623
}

local LOCATION_NAME_BY_ID = {}
for name, location_id in pairs(LOCATION_MAP) do
    LOCATION_NAME_BY_ID[location_id] = name
end

local function check_known_location(location_id)
    local name = LOCATION_NAME_BY_ID[location_id]
    if not name then
        return false, "unknown BPM AP location ID: " .. tostring(location_id)
    end

    local ok = queue_ap_location_check(location_id)
    if not ok then return false, "could not queue " .. name end

    return true, name .. " (" .. tostring(location_id) .. ") queued"
end

RegisterConsoleCommandHandler(
    "BPMAP_CHECK",
    function(_, params, output)
        local location_id = tonumber(params and params[1])
        if not location_id then
            output:Log("Usage: BPMAP_CHECK <numeric location id>\n")
            return true
        end

        local ok, msg = check_known_location(location_id)
        output:Log("BPMAP_CHECK: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
        return true
    end
)

RegisterConsoleCommandHandler("AP_CHECK", function(_, params, output)
    local location_id = tonumber(params and params[1])
    if not location_id then
        output:Log("Usage: AP_CHECK <numeric location id>\n")
        return true
    end

    local ok, msg = check_known_location(location_id)
    output:Log("AP_CHECK: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler(
    "BPMAP_CHECK_COIN",
    function(_, params, output)
        local n = tonumber(params and params[1])
        if not n or n < 1 or n > 10 or n ~= math.floor(n) then
            output:Log("Usage: BPMAP_CHECK_COIN <1-10>\n")
            return true
        end

        local ok, msg = check_known_location(COIN_LOCATION_IDS[n])
        output:Log("BPMAP_CHECK_COIN: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_CHECK_MILESTONE",
    function(_, params, output)
        local n = tonumber(params and params[1])
        if n ~= 5 and n ~= 10 and n ~= 25 then
            output:Log("Usage: BPMAP_CHECK_MILESTONE <5|10|25>\n")
            return true
        end

        local ok, msg = check_known_location(COIN_MILESTONE_IDS[n])
        output:Log("BPMAP_CHECK_MILESTONE: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_CHECK_ROOM",
    function(_, params, output)
        local n = tonumber(params and params[1])
        if not n or n < 1 or n > 14 or n ~= math.floor(n) then
            output:Log("Usage: BPMAP_CHECK_ROOM <1-14>\n")
            return true
        end

        local ok, msg = check_known_location(11993088 + n)
        output:Log("BPMAP_CHECK_ROOM: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_CHECK_BOSS",
    function(_, _, output)
        local ok, msg = check_known_location(12058623)
        output:Log("BPMAP_CHECK_BOSS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
        return true
    end
)

RegisterConsoleCommandHandler("BPMAP_CHECK_ALL_EXPANDED", function(_, _, output)
    local queued = 0
    for _, id in pairs(CHEST_LOCATION_IDS) do if check_known_location(id) then queued = queued + 1 end end
    for _, id in pairs(CHALLENGE_ROOM_LOCATION_IDS) do if check_known_location(id) then queued = queued + 1 end end
    for _, id in pairs(FLOOR_CLEAR_LOCATION_IDS) do if check_known_location(id) then queued = queued + 1 end end
    output:Log("BPMAP_CHECK_ALL_EXPANDED: queued " .. tostring(queued) .. " expanded checks\n")
    return true
end)

RegisterConsoleCommandHandler(
    "BPMAP_CHECK_ALL_ROOMS",
    function(_, _, output)
        local queued = 0
        for location_id = 11993089, 11993102 do
            local ok = check_known_location(location_id)
            if ok then queued = queued + 1 end
        end

        output:Log(
            "BPMAP_CHECK_ALL_ROOMS: queued " ..
            tostring(queued) .. " room checks\n"
        )
        return true
    end
)

-- ============================================================
-- Expanded location check commands
-- ============================================================

local function numeric_index(params, min_value, max_value)
    local n = tonumber(params and params[1])
    if not n or n < min_value or n > max_value or n ~= math.floor(n) then return nil end
    return n
end

local function register_indexed_check(command_name, usage, ids)
    RegisterConsoleCommandHandler(command_name, function(_, params, output)
        local max_index = 0
        for k, _ in pairs(ids) do if k > max_index then max_index = k end end
        local n = numeric_index(params, 1, max_index)
        if not n then
            output:Log("Usage: " .. usage .. "\n")
            return true
        end
        local ok, msg = check_known_location(ids[n])
        output:Log(command_name .. ": " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
        return true
    end)
end

register_indexed_check("BPMAP_CHECK_CHEST", "BPMAP_CHECK_CHEST <1-10>", CHEST_LOCATION_IDS)
register_indexed_check("BPMAP_CHECK_CHALLENGE", "BPMAP_CHECK_CHALLENGE <1-10>", CHALLENGE_ROOM_LOCATION_IDS)
register_indexed_check("BPMAP_CHECK_FLOOR", "BPMAP_CHECK_FLOOR <1-14>", FLOOR_CLEAR_LOCATION_IDS)
register_indexed_check("BPMAP_CHECK_ITEM", "BPMAP_CHECK_ITEM <1-10>", ITEM_PICKUP_LOCATION_IDS)
register_indexed_check("BPMAP_CHECK_WEAPON", "BPMAP_CHECK_WEAPON <1-10>", WEAPON_PICKUP_LOCATION_IDS)
register_indexed_check("BPMAP_CHECK_ALTAR", "BPMAP_CHECK_ALTAR <1-5>", ALTAR_LOCATION_IDS)

RegisterConsoleCommandHandler("BPMAP_CHECK_BOSS_NAME", function(_, params, output)
    local name = params and params[1] or ""
    if name == "" then
        output:Log("Usage: BPMAP_CHECK_BOSS_NAME <Surt|Mistcalf|Alvis|Gullveig|Vétt|Ymir|Fafnir|Draugr>\n")
        return true
    end
    local ok, msg = check_known_location(BOSS_LOCATION_IDS[name])
    output:Log("BPMAP_CHECK_BOSS_NAME: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

-- ============================================================
-- Player/function/equipment diagnostics
-- ============================================================

local function write_equipment(player)
    local f = io.open(IPC_DIR .. "equipment.txt", "w")
    if not f then return false, "cannot write equipment.txt" end

    f:write("PLAYER\t", fullname(player), "\n")

    for _, field in ipairs({
        "CurrentWeapon", "CurrentPocketWeapon", "CurrentSecondaryAbility",
        "CurrentAuxAbility", "CurrentUltimateAbility", "CurrentHeadItemAbility",
        "CurrentChestItemAbility", "CurrentArmsItemAbility", "CurrentLegsItemAbility",
        "CurrentBackpackAbility", "CurrentIntroBoss", "CachedNearestPickup"
    }) do
        local ok, v = pcall(function() return player[field] end)
        f:write(field, "\t", ok and fullname(v) or "<error>", "\n")
    end

    f:close()
    return true, "equipment.txt written"
end

local function write_player(player)
    local f = io.open(IPC_DIR .. "player.txt", "w")
    if not f then return false, "cannot write player.txt" end

    f:write("OBJECT\t", fullname(player), "\n")

    local class = player:GetClass()
    while valid(class) do
        f:write("CLASS\t", fullname(class), "\n")

        pcall(function()
            class:ForEachProperty(function(prop)
                local ok, line = pcall(function()
                    return string.format(
                        "PROP\t0x%04X\t%s\t%s",
                        prop:GetOffset_Internal(),
                        prop:GetClass():GetFName():ToString(),
                        prop:GetFName():ToString()
                    )
                end)

                if ok then f:write(line, "\n") end
            end)
        end)

        class = class:GetSuperStruct()
    end

    f:close()
    return true, "player.txt written"
end

local function write_function_list(player)
    local f = io.open(IPC_DIR .. "player_functions.txt", "w")
    if not f then return false, "cannot write player_functions.txt" end

    f:write("OBJECT\t", fullname(player), "\n")

    local class = player:GetClass()
    while valid(class) do
        f:write("CLASS\t", fullname(class), "\n")

        pcall(function()
            class:ForEachFunction(function(fn)
                local ok, name = pcall(function() return fn:GetFullName() end)
                if ok then f:write("FUNC\t", tostring(name), "\n") end
            end)
        end)

        class = class:GetSuperStruct()
    end

    f:close()
    return true, "player_functions.txt written"
end

local function write_function_names()
    local f = io.open(IPC_DIR .. "function_params.txt", "w")
    if not f then return false, "cannot write function_params.txt" end

    for _, name in ipairs(TARGETS) do
        f:write("FUNCTION\t", name, "\n")
        f:write("PATH\t", TARGET_PATHS[name], "\n")

        local fn = StaticFindObject(TARGET_PATHS[name])
        if fn and fn:IsValid() then
            f:write("FLAGS\t", tostring(fn:GetFunctionFlags()), "\n")
        else
            f:write("NOT_FOUND\n")
        end

        f:write("END\n")
    end

    f:close()
    return true, "function_params.txt written"
end

RegisterConsoleCommandHandler("BPMAP_PLAYER", function(_, _, output)
    local p = get_player()
    if not p then
        output:Log("BPMAP_PLAYER: false player not found\n")
        return true
    end

    local ok, msg = write_player(p)
    output:Log("BPMAP_PLAYER: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_FUNCTIONS", function(_, _, output)
    local p = get_player()
    if not p then
        output:Log("BPMAP_FUNCTIONS: false player not found\n")
        return true
    end

    local ok, msg = write_function_list(p)
    output:Log("BPMAP_FUNCTIONS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_PARAMS", function(_, _, output)
    local ok, msg = write_function_names()
    output:Log("BPMAP_PARAMS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_EQUIPMENT", function(_, _, output)
    local p = get_player()
    if not p then
        output:Log("BPMAP_EQUIPMENT: player not found\n")
        return true
    end

    local ok, msg = write_equipment(p)
    output:Log("BPMAP_EQUIPMENT: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

-- ============================================================
-- Stat / key verification diagnostics
--
-- Usage:
--   BPMAP_VERIFY_KEYS
--   BPMAP_VERIFY_DAMAGE
--   BPMAP_VERIFY_CRIT
--   BPMAP_VERIFY_RANGE
--   BPMAP_VERIFY_SPEED
--   BPMAP_VERIFY_LUCK
--   BPMAP_VERIFY_EXTRAMMO
--   BPMAP_VERIFY_ABILITYPOWER
--
-- Each command calls the exact AP grant function once with +1 and
-- reports whether the matching RegisterHook callback fired. For
-- keys we also report GetKeys() before/after because that getter is
-- known to exist.
--
-- This is a diagnostic build: verification commands intentionally
-- modify the player's state by +1.
-- ============================================================

local STAT_VERIFY_SPECS = {
    KEYS = {
        name = "Keys +1",
        function_name = "AddKeys",
        getter_name = "GetKeys"
    },
    HEALTH = {
        name = "Health +25",
        function_name = "GiveHealth",
        getter_name = "GetNormalHealth",
        amount = 25
    },
    HEALTHCONTAINER = {
        name = "Health Container +1",
        function_name = "AddHealthContainer",
        getter_name = "GetNormalHealthContainer",
        amount = 1
    },
    DAMAGE = {
        name = "Damage Up +1",
        function_name = "AddPlayerStatWeaponDamage"
    },
    CRIT = {
        name = "Critical Up +1",
        function_name = "AddPlayerStatWeaponCritical"
    },
    RANGE = {
        name = "Range Up +1",
        function_name = "AddPlayerStatRange"
    },
    SPEED = {
        name = "Movement Speed Up +1",
        function_name = "AddPlayerStatMovementSpeed"
    },
    LUCK = {
        name = "Luck Up +1",
        function_name = "AddPlayerStatLuck"
    },
    EXTRAMMO = {
        name = "Extra Ammo Up +1",
        function_name = "AddPlayerStatExtraAmmo"
    },
    ABILITYPOWER = {
        name = "Ability Power Up +1",
        function_name = "AddPlayerStatAbilityPower"
    },
    SHIELD = {
        name = "Shield +25",
        function_name = "AddShieldHealth",
        getter_name = "GetShieldHealth",
        amount = 25
    }
}

local function verify_one_stat(kind, output)
    local spec = STAT_VERIFY_SPECS[kind]

    if not spec then
        output:Log(
            "Unknown verify type. Use KEYS, HEALTH, HEALTHCONTAINER, DAMAGE, CRIT, RANGE, SPEED, LUCK, EXTRAMMO, ABILITYPOWER, or SHIELD\n"
        )
        return false
    end

    local player = get_player()

    if not valid(player) then
        output:Log("BPMAP_VERIFY: player not found\n")
        return false
    end

    local before_getter = nil
    local after_getter = nil

    if spec.getter_name then
        before_getter = get_getter(player, spec.getter_name)
    end

    local before_callback = RegisterHookCounts[spec.function_name] or 0
    local amount = tonumber(spec.amount) or 1

    local ok, result = call_numeric(player, spec.function_name, amount)

    local after_callback = RegisterHookCounts[spec.function_name] or 0

    if spec.getter_name then
        after_getter = get_getter(player, spec.getter_name)
    end

    local callback_delta = after_callback - before_callback
    local getter_text = ""

    if spec.getter_name then
        getter_text =
            " before=" .. tostring(before_getter) ..
            " after=" .. tostring(after_getter)
    end

    output:Log(
        "BPMAP_VERIFY " .. kind ..
        ": function=" .. spec.function_name ..
        " amount=" .. tostring(amount) ..
        " call_ok=" .. tostring(ok) ..
        " callback_delta=" .. tostring(callback_delta) ..
        getter_text ..
        " result=" .. tostring(result) ..
        "\n"
    )

    return ok and callback_delta > 0
end

local function register_verify_command(command_name, kind)
    RegisterConsoleCommandHandler(
        command_name,
        function(_, _, output)
            verify_one_stat(kind, output)
            return true
        end
    )
end

for kind in pairs(STAT_VERIFY_SPECS) do
    register_verify_command("BPMAP_VERIFY_" .. kind, kind)
end

-- Dedicated damaged-health test.
-- This command does NOT damage the player. First take damage normally in-game,
-- then run BPMAP_VERIFY_HEALTH_DAMAGED. It records the exact HP before/after
-- GiveHealth(25), which lets us determine whether the native call behaves like
-- the in-game +25-or-to-max pickup behavior.
RegisterConsoleCommandHandler("BPMAP_VERIFY_HEALTH_DAMAGED", function(_, _, output)
    local player = get_player()
    if not valid(player) then
        output:Log("BPMAP_VERIFY_HEALTH_DAMAGED: player not found\n")
        return true
    end

    local before = get_getter(player, "GetNormalHealth")
    local max_before = get_getter(player, "GetNormalHealthContainer")
    local callback_before = RegisterHookCounts["GiveHealth"] or 0

    local fn = player["GiveHealth"]
    if not fn or not fn.IsValid or not fn:IsValid() then
        output:Log("BPMAP_VERIFY_HEALTH_DAMAGED: GiveHealth is not valid\n")
        return true
    end

    local ok, result = pcall(function()
        return fn(player, 25)
    end)

    local after = get_getter(player, "GetNormalHealth")
    local max_after = get_getter(player, "GetNormalHealthContainer")
    local callback_after = RegisterHookCounts["GiveHealth"] or 0

    output:Log(
        "BPMAP_VERIFY_HEALTH_DAMAGED: " ..
        "GiveHealth amount=25" ..
        " call_ok=" .. tostring(ok) ..
        " callback_delta=" .. tostring(callback_after - callback_before) ..
        " hp_before=" .. tostring(before) ..
        " hp_after=" .. tostring(after) ..
        " max_before=" .. tostring(max_before) ..
        " max_after=" .. tostring(max_after) ..
        " hp_delta=" ..
            tostring(
                (type(before) == "number" and type(after) == "number")
                and (after - before)
                or "<n/a>"
            ) ..
        " result=" .. tostring(result) ..
        "\n"
    )
    return true
end)

-- Compatibility alias: accept the shorter spelling used in test notes.
RegisterConsoleCommandHandler("BPMAP_VERIFY_HEALTH_DAMAGE", function(_, _, output)
    local player = get_player()
    if not valid(player) then
        output:Log("BPMAP_VERIFY_HEALTH_DAMAGE: player not found\n")
        return true
    end

    local before = get_getter(player, "GetNormalHealth")
    local max_before = get_getter(player, "GetNormalHealthContainer")
    local callback_before = RegisterHookCounts["GiveHealth"] or 0
    local fn = player["GiveHealth"]

    if not fn or not fn.IsValid or not fn:IsValid() then
        output:Log("BPMAP_VERIFY_HEALTH_DAMAGE: GiveHealth is not valid\n")
        return true
    end

    local ok, result = pcall(function()
        return fn(player, 25)
    end)

    local after = get_getter(player, "GetNormalHealth")
    local max_after = get_getter(player, "GetNormalHealthContainer")
    local callback_after = RegisterHookCounts["GiveHealth"] or 0
    local delta = (type(before) == "number" and type(after) == "number") and (after - before) or "<n/a>"

    output:Log(
        "BPMAP_VERIFY_HEALTH_DAMAGE: GiveHealth amount=25" ..
        " call_ok=" .. tostring(ok) ..
        " callback_delta=" .. tostring(callback_after - callback_before) ..
        " hp_before=" .. tostring(before) ..
        " hp_after=" .. tostring(after) ..
        " max_before=" .. tostring(max_before) ..
        " max_after=" .. tostring(max_after) ..
        " hp_delta=" .. tostring(delta) ..
        " result=" .. tostring(result) .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_HEALTH_STATUS", function(_, _, output)
    local player = get_player()
    if not valid(player) then
        output:Log("BPMAP_HEALTH_STATUS: player not found\n")
        return true
    end

    local hp = get_getter(player, "GetNormalHealth")
    local max_hp = get_getter(player, "GetNormalHealthContainer")
    output:Log(
        "BPMAP_HEALTH_STATUS: current=" .. tostring(hp) ..
        " max=" .. tostring(max_hp) ..
        "\n"
    )
    return true
end)

-- ============================================================
-- Pickup-event verification
--
-- These commands are deliberately non-invasive: item/weapon pickup
-- events require Unreal object parameters and should not be called
-- with fabricated arguments. Instead, verify that the exact target
-- hook is valid/installed and report its live callback count.
-- ============================================================

local function verify_hook_target(kind, function_name, output)
    local p = get_player()

    if not valid(p) then
        output:Log(
            "BPMAP_VERIFY_" .. kind ..
            ": player not found\n"
        )
        return false
    end

    local fn = p[function_name]
    local function_valid = false

    if fn and fn.IsValid then
        local ok = pcall(function() return fn:IsValid() end)
        if ok then
            local ok2, value = pcall(function() return fn:IsValid() end)
            function_valid = ok2 and value == true
        end
    end

    output:Log(
        "BPMAP_VERIFY_" .. kind ..
        ": function=" .. function_name ..
        " function_valid=" .. tostring(function_valid) ..
        " hook_installed=" .. tostring(HooksInstalled) ..
        " callback_count=" .. tostring(RegisterHookCounts[function_name] or 0) ..
        "\n"
    )

    return function_valid
end

RegisterConsoleCommandHandler(
    "BPMAP_VERIFY_ITEM",
    function(_, _, output)
        verify_hook_target(
            "ITEM",
            "OnPickupAbilityGeneric",
            output
        )
        return true
    end
)

RegisterConsoleCommandHandler(
    "BPMAP_VERIFY_WEAPON",
    function(_, _, output)
        verify_hook_target(
            "WEAPON",
            "OnPickupWeaponGeneric",
            output
        )
        return true
    end
)

-- ============================================================
-- Chest verification
--
-- No confirmed chest gameplay function has been established yet.
-- This command performs a safe runtime object/class search and writes
-- the results to chest_verify.txt. It does not fabricate or invoke
-- an unknown Unreal function.
-- ============================================================

RegisterConsoleCommandHandler(
    "BPMAP_VERIFY_CHEST",
    function(_, _, output)
        local ok, msg =
            write_runtime_objects(
                "chest",
                "chest_verify.txt",
                100
            )

        output:Log(
            "BPMAP_VERIFY_CHEST: " ..
            tostring(ok) .. " " .. tostring(msg) .. "\n"
        )

        return true
    end
)


RegisterConsoleCommandHandler(
    "BPMAP_VERIFY_STATUS",
    function(_, _, output)
        output:Log(
            "BPMAP_VERIFY_STATUS: " ..
            "AddKeys=" .. tostring(RegisterHookCounts.AddKeys or 0) ..
            " GiveHealth=" .. tostring(RegisterHookCounts.GiveHealth or 0) ..
            " HealthContainer=" .. tostring(RegisterHookCounts.AddHealthContainer or 0) ..
            " Damage=" .. tostring(RegisterHookCounts.AddPlayerStatWeaponDamage or 0) ..
            " Crit=" .. tostring(RegisterHookCounts.AddPlayerStatWeaponCritical or 0) ..
            " Range=" .. tostring(RegisterHookCounts.AddPlayerStatRange or 0) ..
            " Speed=" .. tostring(RegisterHookCounts.AddPlayerStatMovementSpeed or 0) ..
            " Luck=" .. tostring(RegisterHookCounts.AddPlayerStatLuck or 0) ..
            " ExtraAmmo=" .. tostring(RegisterHookCounts.AddPlayerStatExtraAmmo or 0) ..
            " AbilityPower=" .. tostring(RegisterHookCounts.AddPlayerStatAbilityPower or 0) ..
            " Shield=" .. tostring(RegisterHookCounts.AddShieldHealth or 0) ..
            " Item=" .. tostring(RegisterHookCounts.OnPickupAbilityGeneric or 0) ..
            " Weapon=" .. tostring(RegisterHookCounts.OnPickupWeaponGeneric or 0) ..
            " last=" .. tostring(RegisterHookLastFunction) ..
            "\n"
        )
        return true
    end
)


RegisterConsoleCommandHandler(
    "BPMAP_VERIFY",
    function(_, params, output)
        local kind = params and params[1] and string.upper(params[1]) or ""
        verify_one_stat(kind, output)
        return true
    end
)


RegisterConsoleCommandHandler(
    "BPMAP_AUTO_LAST",
    function(_, _, output)
        output:Log(
            "BPMAP_AUTO_LAST: enabled=" .. tostring(AUTOMATIC_ITEM_PROCESSING_ENABLED) ..
            " triggers=" .. tostring(AutoItemTriggerCount) ..
            " processed=" .. tostring(AutoItemSuccessCount) ..
            " errors=" .. tostring(AutoItemErrorCount) ..
            " last_trigger=" .. tostring(AutoItemLastTrigger) ..
            " last_result=" .. tostring(AutoItemLastResult) ..
            " last_index=" .. tostring(AutoItemLastIndex) ..
            " last_item_id=" .. tostring(AutoItemLastID) ..
            "\n"
        )
        return true
    end
)

-- ============================================================
-- Debug numeric commands
-- ============================================================

RegisterConsoleCommandHandler("BPMAP_ADDCOINS", function(_, params, output)
    local p = get_player()
    local n = numeric_amount(params)
    if not p then output:Log("AddCoins: false player not found\n"); return true end

    local ok, msg = call_numeric(p, "AddCoins", n)
    output:Log("AddCoins: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_ADDKEYS", function(_, params, output)
    local p = get_player()
    local n = numeric_amount(params)
    if not p then output:Log("AddKeys: false player not found\n"); return true end

    local ok, msg = call_numeric(p, "AddKeys", n)
    output:Log("AddKeys: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_GIVE_HEALTH", function(_, params, output)
    local p = get_player()
    local n = numeric_amount(params)
    if not p then output:Log("GiveHealth: false player not found\n"); return true end

    local ok, msg = call_numeric(p, "GiveHealth", n)
    output:Log("GiveHealth: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_ADDHEALTHCONTAINER", function(_, params, output)
    local p = get_player()
    local n = numeric_amount(params)
    if not p then output:Log("AddHealthContainer: false player not found\n"); return true end

    local ok, msg = call_numeric(p, "AddHealthContainer", n)
    output:Log("AddHealthContainer: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_ADDSHIELD", function(_, params, output)
    local p = get_player()
    local n = numeric_amount(params)
    if not p then output:Log("AddShieldHealth: false player not found\n"); return true end

    local ok, msg = call_numeric(p, "AddShieldHealth", n)
    output:Log("AddShieldHealth: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_GIVE", function(_, params, output)
    params = params or {}

    local kind = params[1] and string.upper(params[1]) or ""
    local n = numeric_amount({ params[2] })
    local p = get_player()

    if not p then output:Log("GIVE: player not found\n"); return true end
    if n == nil then output:Log("GIVE: invalid amount\n"); return true end

    local fn
    if kind == "COINS" then fn = "AddCoins"
    elseif kind == "KEYS" then fn = "AddKeys"
    else fn = STAT_FUNCTIONS[kind]
    end

    if not fn then
        output:Log("Unknown BPMAP_GIVE type\n")
        return true
    end

    local ok, msg = call_numeric(p, fn, n)
    output:Log(
        string.format(
            "GIVE %s amount=%s ok=%s %s\n",
            kind, tostring(n), tostring(ok), tostring(msg)
        )
    )

    return true
end)

RegisterConsoleCommandHandler("BPMAP_PLAYER_CALL", function(_, params, output)
    params = params or {}
    local fn_name = params[1] or ""

    if fn_name == "" then
        output:Log("Usage: BPMAP_PLAYER_CALL <FunctionName> [args...]\n")
        return true
    end

    local player = get_player()
    if not valid(player) then
        output:Log("BPMAP_PLAYER_CALL: player not found\n")
        return true
    end

    local fn = player[fn_name]
    if not fn or not fn.IsValid or not fn:IsValid() then
        output:Log("BPMAP_PLAYER_CALL: function not valid: " .. fn_name .. "\n")
        return true
    end

    local args = {}
    for i = 2, #params do
        local n = tonumber(params[i])
        table.insert(args, n ~= nil and n or params[i])
    end

    local ok, result = pcall(function()
        return fn(table.unpack(args))
    end)

    output:Log(
        "BPMAP_PLAYER_CALL: " .. fn_name ..
        " ok=" .. tostring(ok) ..
        " result=" .. tostring(result) .. "\n"
    )

    return true
end)

-- ============================================================
-- Hook/status commands and keybinds
-- ============================================================

RegisterConsoleCommandHandler("BPMAP_HOOKS", function(_, _, output)
    local ok, msg = install_hooks(get_player())
    output:Log("BPMAP_HOOKS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_PROCESS_ITEMS", function(_, _, output)
    local ok, msg = process_one_ap_item()
    output:Log("BPMAP_PROCESS_ITEMS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterKeyBind(Key.F7, function()
    local p = get_player()
    if p then install_hooks(p) end
    Log("F7: hook install attempted")
end)

RegisterKeyBind(Key.F8, function()
    local p = get_player()
    if p then write_player(p) end
end)

RegisterKeyBind(Key.F9, function()
    local p = get_player()
    if p then write_function_list(p) end
end)

-- ============================================================
-- AP status
-- ============================================================

local function ap_status_command(_, _, output)
    local marker = read_text_file("ap_connected.flag")
    local client = read_text_file("client_status.txt")

    if marker == "connected" and client and client ~= "" then
        output:Log("AP CLIENT CONNECTED\n")
        output:Log(client .. "\n")
    elseif client and client ~= "" then
        output:Log("AP CLIENT STATUS (not marked connected):\n")
        output:Log(client .. "\n")
    else
        output:Log("AP CLIENT: offline or status file not found\n")
    end

    return true
end

RegisterConsoleCommandHandler("BPMAP_AP_STATUS", ap_status_command)
RegisterConsoleCommandHandler("AP_STATUS", ap_status_command)

-- ============================================================
-- Reflection diagnostic helpers
-- ============================================================

local function safe_fullname(obj)
    if not valid(obj) then return "<invalid>" end
    local ok, name = pcall(function() return fullname(obj) end)
    return ok and tostring(name) or "<unknown>"
end

local function safe_class_name(obj)
    if not valid(obj) then return "<invalid>" end
    local result = "<unknown>"
    pcall(function() result = safe_fullname(obj:GetClass()) end)
    return result
end

local function write_runtime_objects(filter_text, filename, limit)
    local f = io.open(IPC_DIR .. filename, "w")
    if not f then return false, "could not open " .. filename end

    local needle = string.lower(tostring(filter_text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    local matched = 0
    local scanned = 0

    f:write("BPM RUNTIME OBJECT DUMP\n")
    f:write("FILTER\t", tostring(filter_text or ""), "\n")
    f:write("LIMIT\t", tostring(limit), "\n---\n")

    if ForEachUObject then
        local ok, err = pcall(function()
            ForEachUObject(function(obj)
                scanned = scanned + 1
                if matched >= limit or not valid(obj) then return end

                local name = safe_fullname(obj)
                if needle ~= "" and not string.find(string.lower(name), needle, 1, true) then return end

                f:write("OBJECT\t", name, "\tCLASS\t", safe_class_name(obj), "\n")
                matched = matched + 1
            end)
        end)

        if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    else
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
    end

    f:write("---\nSCANNED\t", tostring(scanned), "\nMATCHED\t", tostring(matched), "\n")
    f:close()

    return true, filename .. " written; scanned=" .. tostring(scanned) .. " matched=" .. tostring(matched)
end

local function write_runtime_classes(filter_text)
    local f = io.open(IPC_DIR .. "runtime_classes.txt", "w")
    if not f then return false, "could not open runtime_classes.txt" end

    local needle = string.lower(tostring(filter_text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    local matched = 0
    local scanned = 0

    f:write("BPM RUNTIME CLASS DUMP\nFILTER\t", tostring(filter_text or ""), "\n---\n")

    if ForEachUObject then
        local ok, err = pcall(function()
            ForEachUObject(function(obj)
                scanned = scanned + 1
                if not valid(obj) then return end

                local name = safe_fullname(obj)
                if string.sub(name, 1, 6) ~= "Class " then return end
                if needle ~= "" and not string.find(string.lower(name), needle, 1, true) then return end

                f:write("CLASS\t", name, "\n")
                matched = matched + 1
            end)
        end)

        if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    else
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
    end

    f:write("---\nSCANNED\t", tostring(scanned), "\nMATCHED\t", tostring(matched), "\n")
    f:close()

    return true, "runtime_classes.txt written; scanned=" .. tostring(scanned) .. " matched=" .. tostring(matched)
end

local function write_class_instance_diagnostic(query)
    local requested = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if requested == "" then return false, "usage: BPMAP_CLASS <class/filter>" end

    local f = io.open(IPC_DIR .. "class_dump.txt", "w")
    if not f then return false, "could not open class_dump.txt" end

    local needle = string.lower(requested)
    local classes = {}
    local instances = {}
    local scanned = 0

    f:write("REQUESTED_CLASS\t", requested, "\nMODE\truntime class-name search\n---\n")

    if ForEachUObject then
        local ok, err = pcall(function()
            ForEachUObject(function(obj)
                scanned = scanned + 1
                if not valid(obj) then return end

                local name = safe_fullname(obj)
                local lower = string.lower(name)

                if string.sub(name, 1, 6) == "Class " and string.find(lower, needle, 1, true) then
                    table.insert(classes, name)
                    return
                end

                local cls = safe_class_name(obj)
                if string.find(string.lower(cls), needle, 1, true) then
                    table.insert(instances, { object = name, class = cls })
                end
            end)
        end)

        if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    else
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
    end

    f:write("CLASS_OBJECT_COUNT\t", tostring(#classes), "\n")
    for _, name in ipairs(classes) do f:write("CLASS\t", name, "\n") end

    f:write("INSTANCE_COUNT\t", tostring(#instances), "\n")
    for _, entry in ipairs(instances) do
        f:write("OBJECT\t", entry.object, "\tCLASS\t", entry.class, "\n")
    end

    f:write("---\nSCANNED\t", tostring(scanned), "\n")
    f:close()

    return true,
        "class_dump.txt written; class_objects=" .. tostring(#classes) ..
        " instances=" .. tostring(#instances) .. " scanned=" .. tostring(scanned)
end

local function write_function_diagnostic(query, filename)
    local requested = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if requested == "" then return false, "usage: BPMAP_FUNCTION <text>" end

    local f = io.open(IPC_DIR .. filename, "w")
    if not f then return false, "could not open " .. filename end

    local needle = string.lower(requested)
    local found = 0
    local scanned = 0

    f:write("BPM RUNTIME FUNCTION INSPECTION\nQUERY\t", requested, "\n---\n")

    if ForEachUObject then
        local ok, err = pcall(function()
            ForEachUObject(function(obj)
                scanned = scanned + 1
                if not valid(obj) then return end

                local name = safe_fullname(obj)
                if string.sub(name, 1, 9) ~= "Function " then return end
                if not string.find(string.lower(name), needle, 1, true) then return end

                found = found + 1
                f:write("FUNCTION\t", name, "\n")

                pcall(function()
                    f:write("FLAGS\t", tostring(obj:GetFunctionFlags()), "\n")
                end)

                pcall(function()
                    f:write("FNAME\t", tostring(obj:GetFName():ToString()), "\n")
                end)

                local prop_count = 0
                local prop_ok, prop_err = pcall(function()
                    obj:ForEachProperty(function(prop)
                        prop_count = prop_count + 1

                        local pname = "<unknown>"
                        local pclass = "<unknown>"
                        local poffset = "<unknown>"

                        pcall(function() pname = prop:GetFName():ToString() end)
                        pcall(function() pclass = safe_fullname(prop:GetClass()) end)
                        pcall(function() poffset = string.format("0x%04X", prop:GetOffset_Internal()) end)

                        f:write(
                            "PARAM\t", pname,
                            "\tCLASS\t", pclass,
                            "\tOFFSET\t", poffset,
                            "\n"
                        )
                    end)
                end)

                if not prop_ok then
                    f:write("PROPERTY_ENUMERATION_ERROR\t", tostring(prop_err), "\n")
                end

                f:write("PROPERTY_COUNT\t", tostring(prop_count), "\n---\n")
            end)
        end)

        if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    else
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
    end

    f:write("SCANNED\t", tostring(scanned), "\nFOUND\t", tostring(found), "\n")
    f:close()

    return true, filename .. " written; scanned=" .. tostring(scanned) .. " found=" .. tostring(found)
end

local function write_enum_diagnostic(query)
    local requested = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if requested == "" then return false, "usage: BPMAP_ENUM <text>" end

    local f = io.open(IPC_DIR .. "enum_dump.txt", "w")
    if not f then return false, "could not open enum_dump.txt" end

    local needle = string.lower(requested)
    local found = 0
    local scanned = 0

    f:write("BPM RUNTIME ENUM INSPECTION\nQUERY\t", requested, "\n---\n")

    if ForEachUObject then
        local ok, err = pcall(function()
            ForEachUObject(function(obj)
                scanned = scanned + 1
                if not valid(obj) then return end

                local name = safe_fullname(obj)
                if string.sub(name, 1, 5) ~= "Enum " then return end
                if not string.find(string.lower(name), needle, 1, true) then return end

                found = found + 1
                f:write("ENUM\t", name, "\n")

                local ok_names, names = pcall(function() return obj:GetNames() end)
                f:write("GETNAMES_OK\t", tostring(ok_names), "\n")

                if ok_names and names then
                    pcall(function()
                        for _, enum_name in pairs(names) do
                            f:write("VALUE\t", tostring(enum_name), "\n")
                        end
                    end)
                end

                f:write("---\n")
            end)
        end)

        if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    else
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
    end

    f:write("SCANNED\t", tostring(scanned), "\nFOUND\t", tostring(found), "\n")
    f:close()

    return true, "enum_dump.txt written; scanned=" .. tostring(scanned) .. " found=" .. tostring(found)
end

local function write_object_info(query)
    local requested = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if requested == "" then return false, "usage: BPMAP_OBJECT_INFO <text>" end

    local f = io.open(IPC_DIR .. "object_info.txt", "w")
    if not f then return false, "could not open object_info.txt" end

    local needle = string.lower(requested)
    local found = 0
    local scanned = 0
    local limit = 25

    f:write("BPM RUNTIME OBJECT INFO\nQUERY\t", requested, "\nLIMIT\t", tostring(limit), "\n---\n")

    if ForEachUObject then
        local ok, err = pcall(function()
            ForEachUObject(function(obj)
                scanned = scanned + 1
                if found >= limit or not valid(obj) then return end

                local name = safe_fullname(obj)
                local cls_name = safe_class_name(obj)

                if not string.find(string.lower(name), needle, 1, true)
                    and not string.find(string.lower(cls_name), needle, 1, true) then
                    return
                end

                found = found + 1
                f:write("OBJECT\t", name, "\nCLASS\t", cls_name, "\n")

                local cls = nil
                pcall(function() cls = obj:GetClass() end)

                local level = 0
                while valid(cls) and level < 12 do
                    level = level + 1
                    f:write("CLASS_LEVEL\t", tostring(level), "\t", safe_fullname(cls), "\n")

                    local prop_count = 0
                    pcall(function()
                        cls:ForEachProperty(function(prop)
                            prop_count = prop_count + 1

                            local pname = "<unknown>"
                            local pclass = "<unknown>"
                            local poffset = "<unknown>"

                            pcall(function() pname = prop:GetFName():ToString() end)
                            pcall(function() pclass = safe_fullname(prop:GetClass()) end)
                            pcall(function() poffset = string.format("0x%04X", prop:GetOffset_Internal()) end)

                            f:write(
                                "PROP\t", pname,
                                "\tCLASS\t", pclass,
                                "\tOFFSET\t", poffset,
                                "\n"
                            )
                        end)
                    end)

                    f:write("PROPERTY_COUNT\t", tostring(prop_count), "\n")

                    local super = nil
                    pcall(function() super = cls:GetSuperStruct() end)
                    cls = super
                end

                for _, prop_name in ipairs({
                    "RoomNumber", "RoomIndex", "RoomID", "RoomClearType", "ClearType",
                    "bRoomCleared", "bCleared", "bComplete", "RewardSpawned", "bRewardSpawned",
                    "CurrentRoom", "CurrentFloor"
                }) do
                    local pok, value = pcall(function() return obj[prop_name] end)
                    if pok and value ~= nil then
                        f:write("VALUE\t", prop_name, "\t", tostring(value), "\n")
                    end
                end

                f:write("END_OBJECT\n---\n")
            end)
        end)

        if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    else
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
    end

    f:write("SCANNED\t", tostring(scanned), "\nFOUND\t", tostring(found), "\n")
    f:close()

    return true, "object_info.txt written; scanned=" .. tostring(scanned) .. " found=" .. tostring(found)
end

RegisterConsoleCommandHandler("BPMAP_OBJECTS", function(_, params, output)
    local ok, msg = write_runtime_objects(params and params[1] or "", "runtime_objects.txt", 1000)
    output:Log("BPMAP_OBJECTS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_FIND_OBJECT", function(_, params, output)
    local query = params and params[1] or ""
    if query == "" then
        output:Log("Usage: BPMAP_FIND_OBJECT <text>\n")
        return true
    end

    local ok, msg = write_runtime_objects(query, "find_objects.txt", 250)
    output:Log("BPMAP_FIND_OBJECT: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_CLASSES", function(_, params, output)
    local ok, msg = write_runtime_classes(params and params[1] or "")
    output:Log("BPMAP_CLASSES: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_CLASS", function(_, params, output)
    local ok, msg = write_class_instance_diagnostic(params and params[1] or "")
    output:Log("BPMAP_CLASS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_FUNCTION", function(_, params, output)
    local ok, msg = write_function_diagnostic(params and params[1] or "", "function_dump.txt")
    output:Log("BPMAP_FUNCTION: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_INSPECT_FUNCTION", function(_, params, output)
    local ok, msg = write_function_diagnostic(params and params[1] or "", "function_inspect.txt")
    output:Log("BPMAP_INSPECT_FUNCTION: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_ENUM", function(_, params, output)
    local ok, msg = write_enum_diagnostic(params and params[1] or "")
    output:Log("BPMAP_ENUM: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_OBJECT_INFO", function(_, params, output)
    local ok, msg = write_object_info(params and params[1] or "")
    output:Log("BPMAP_OBJECT_INFO: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_PROPERTIES", function(_, params, output)
    local ok, msg = write_object_info(params and params[1] or "")
    output:Log("BPMAP_PROPERTIES: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)
-- Broad loot/event discovery. Manual-only: never called from gameplay callbacks.
local LOOT_DISCOVERY_TERMS = {
    "chest", "chests", "treasure", "treasures", "box", "boxes",
    "crate", "crates", "container", "containers", "coffer", "coffers",
    "cache", "caches", "casket", "caskets", "stash", "stashes",
    "locker", "lockers", "cabinet", "cabinets", "vault", "vaults",
    "hoard", "hoards", "barrel", "barrels", "urn", "urns",
    "loot", "reward", "rewards", "pickup", "pickups", "item", "items",
    "weapon", "weapons", "altar", "altars", "shrine", "shrines",
    "boss", "bosses", "defeat", "defeated", "death", "deaths", "kill", "killed",
    "victory", "clear", "cleared"
}

local function write_loot_event_discovery()
    local filename = "loot_event_discovery.txt"
    local f = io.open(IPC_DIR .. filename, "w")
    if not f then return false, "could not open " .. filename end
    f:write("BPM LOOT / PICKUP / EVENT DISCOVERY\n")
    f:write("TERMS\t", table.concat(LOOT_DISCOVERY_TERMS, ", "), "\n---\n")
    if not ForEachUObject then
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
        f:close()
        return false, filename .. " written; ForEachUObject unavailable"
    end
    local scanned, matched = 0, 0
    local max_results = 1000
    local ok, err = pcall(function()
        ForEachUObject(function(obj)
            scanned = scanned + 1
            if matched >= max_results or not valid(obj) then return end
            local name = safe_fullname(obj)
            local cls_name = safe_class_name(obj)
            local lower_name = string.lower(name)
            local lower_class = string.lower(cls_name)
            local hits = {}
            for _, term in ipairs(LOOT_DISCOVERY_TERMS) do
                if string.find(lower_name, term, 1, true) or string.find(lower_class, term, 1, true) then
                    table.insert(hits, term)
                end
            end
            if #hits > 0 then
                matched = matched + 1
                f:write("MATCH\t", tostring(matched), "\tNAME\t", name,
                    "\tCLASS\t", cls_name, "\tTERMS\t", table.concat(hits, ","), "\n")
            end
        end)
    end)
    if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    f:write("---\nSCANNED\t", tostring(scanned), "\nMATCHED\t", tostring(matched), "\n")
    f:close()
    return true, filename .. " written; scanned=" .. tostring(scanned) .. " matched=" .. tostring(matched)
end



-- ============================================================
-- Targeted BPM-only event discovery / watch helpers
--
-- The broad discovery pass is useful, but it is intentionally noisy
-- because Engine/AkAudio/UI objects can match generic words such as
-- "item", "box", "death", and "clear". These helpers narrow the
-- search to /Script/BPM and record only Functions/Classes/ScriptStructs
-- relevant to loot, rewards, pickups, rooms, bosses, altars, etc.
--
-- Nothing here runs automatically on gameplay events. Discovery and
-- candidate watches are manual commands only.
-- ============================================================

local BPM_EVENT_TERMS = {
    "chest", "chests", "treasure", "treasures",
    "box", "boxes", "crate", "crates",
    "container", "containers", "coffer", "cache",
    "casket", "stash", "locker", "cabinet", "vault", "hoard",
    "barrel", "barrels", "urn", "loot", "reward", "rewards",
    "pickup", "pickups", "item", "items", "weapon", "weapons",
    "altar", "altars", "shrine", "shrines",
    "boss", "defeat", "defeated", "death", "killed", "kill",
    "victory", "challenge", "room", "clear", "cleared",
    "floor", "spawnreward", "spawna", "consume"
}

local function object_kind(name)
    local first = tostring(name):match("^(%a+)")
    return first or ""
end

local function bpm_event_matches(name, class_name)
    local lower_name = string.lower(tostring(name or ""))
    local lower_class = string.lower(tostring(class_name or ""))

    if not string.find(lower_name, "/script/bpm", 1, true)
        and not string.find(lower_class, "/script/bpm", 1, true) then
        return nil
    end

    local hits = {}
    for _, term in ipairs(BPM_EVENT_TERMS) do
        if string.find(lower_name, term, 1, true)
            or string.find(lower_class, term, 1, true) then
            table.insert(hits, term)
        end
    end

    if #hits == 0 then return nil end
    return hits
end

local function write_bpm_event_discovery()
    local filename = "bpm_event_discovery.txt"
    local f = io.open(IPC_DIR .. filename, "w")
    if not f then return false, "could not open " .. filename end

    f:write("BPM-ONLY LOOT / PICKUP / EVENT DISCOVERY\n")
    f:write("TERMS\t", table.concat(BPM_EVENT_TERMS, ", "), "\n---\n")

    if not ForEachUObject then
        f:write("FOREACH_UOBJECT_UNAVAILABLE\n")
        f:close()
        return false, filename .. " written; ForEachUObject unavailable"
    end

    local scanned, matched = 0, 0
    local ok, err = pcall(function()
        ForEachUObject(function(obj)
            scanned = scanned + 1
            if matched >= 2500 or not valid(obj) then return end

            local name = safe_fullname(obj)
            local cls_name = safe_class_name(obj)
            local hits = bpm_event_matches(name, cls_name)
            if not hits then return end

            local kind = object_kind(name)
            if kind ~= "Function" and kind ~= "Class" and kind ~= "ScriptStruct" and kind ~= "Enum" then
                return
            end

            matched = matched + 1
            f:write(
                "MATCH\t", tostring(matched),
                "\tKIND\t", kind,
                "\tNAME\t", name,
                "\tCLASS\t", cls_name,
                "\tTERMS\t", table.concat(hits, ","),
                "\n"
            )
        end)
    end)

    if not ok then f:write("FOREACH_UOBJECT_ERROR\t", tostring(err), "\n") end
    f:write("---\nSCANNED\t", tostring(scanned), "\nMATCHED\t", tostring(matched), "\n")
    f:close()

    return true, filename .. " written; scanned=" .. tostring(scanned) .. " matched=" .. tostring(matched)
end

local BPM_EVENT_CANDIDATE_PATHS = {
    "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomTreasureItem",
    "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomChallengeItem",
    "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomBossItem",
    "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomWeaponItem",
    "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomShopItem",
    "/Script/BPM.BPMGameInstance:ReturnAndConsumeBossRewardItems",
    "/Script/BPM.BPMGameInstance:ReturnAndConsumeLargeEnemyRewardItems",
    "/Script/BPM.BPMGameInstance:ReturnAndConsumeMediumEnemyRewardItems",
    "/Script/BPM.BPMGameInstance:ReturnAndConsumeMinibossRewardItems",
    "/Script/BPM.BPMGameInstance:ReturnAndConsumeSmallEnemyRewardItems",
    "/Script/BPM.BPMGameInstance:OnChallengeVictory",
    "/Script/BPM.BPMGameInstance:GameEvent_DefeatedNidhogg",
    "/Script/BPM.BPMGameInstance:UnlockReward",
    "/Script/BPM.BPMFloorActor:SpawnRewards",
    "/Script/BPM.BPMFloorActor:BlueprintJumpPuzzleReward",
    "/Script/BPM.BPMEndlessRoomScriptActor:SpawnSetReward",
    "/Script/BPM.BPMAbility:OnEnemyKilledBlueprint"
}

local BPMEventCandidateHooks = {}
local BPMEventCandidateCounts = {}

local function watch_bpm_candidate(path)
    if BPMEventCandidateHooks[path] then
        return true, "already watched " .. path
    end

    local ok, a, b = pcall(function()
        return RegisterHook(
            path,
            function(...)
                BPMEventCandidateCounts[path] = (BPMEventCandidateCounts[path] or 0) + 1
            end
        )
    end)

    if not ok then
        return false, "RegisterHook failed: " .. path .. " :: " .. tostring(a)
    end

    BPMEventCandidateHooks[path] = { a, b }
    BPMEventCandidateCounts[path] = BPMEventCandidateCounts[path] or 0
    return true, "watching " .. path
end

RegisterConsoleCommandHandler("BPMAP_DISCOVER_BPM_EVENTS", function(_, _, output)
    local ok, msg = write_bpm_event_discovery()
    output:Log("BPMAP_DISCOVER_BPM_EVENTS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_WATCH_BPM_CANDIDATES", function(_, _, output)
    local installed, failed = 0, 0
    for _, path in ipairs(BPM_EVENT_CANDIDATE_PATHS) do
        local ok, msg = watch_bpm_candidate(path)
        if ok then installed = installed + 1 else failed = failed + 1 end
        output:Log("BPMAP_WATCH_BPM_CANDIDATES: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    end
    output:Log("BPMAP_WATCH_BPM_CANDIDATES: installed_or_existing=" .. tostring(installed) .. " failed=" .. tostring(failed) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_BPM_CANDIDATE_STATUS", function(_, _, output)
    local shown = 0
    for path, state in pairs(BPMEventCandidateHooks) do
        shown = shown + 1
        output:Log("BPM_CANDIDATE " .. path .. " count=" .. tostring(BPMEventCandidateCounts[path] or 0) .. " ids=" .. tostring(state[1]) .. "," .. tostring(state[2]) .. "\n")
    end
    if shown == 0 then output:Log("BPM_CANDIDATE: none watched\n") end
    return true
end)

RegisterConsoleCommandHandler("BPMAP_WATCH_CONFIRMED_REWARDS", function(_, _, output)
    local paths = {
            "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomTreasureItem",
        "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomChallengeItem"
    }

    local installed, failed = 0, 0
    for _, path in ipairs(paths) do
        local ok, msg = watch_bpm_candidate(path)
        if ok then installed = installed + 1 else failed = failed + 1 end
        output:Log("BPMAP_WATCH_CONFIRMED_REWARDS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    end

    output:Log(
        "BPMAP_WATCH_CONFIRMED_REWARDS: installed_or_existing=" ..
        tostring(installed) .. " failed=" .. tostring(failed) .. "\n"
    )
    return true
end)

RegisterConsoleCommandHandler("BPMAP_CONFIRMED_REWARD_STATUS", function(_, _, output)
    local paths = {
            "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomTreasureItem",
        "/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomChallengeItem"
    }

    for _, path in ipairs(paths) do
        output:Log(
            "BPM_REWARD " .. path ..
            " count=" .. tostring(BPMEventCandidateCounts[path] or 0) ..
            "\n"
        )
    end
    return true
end)

RegisterConsoleCommandHandler("BPMAP_DISCOVER_EVENTS", function(_, _, output)
    local ok, msg = write_loot_event_discovery()
    output:Log("BPMAP_DISCOVER_EVENTS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_FIND_CHEST", function(_, _, output)
    local ok, msg = write_runtime_objects("chest", "find_chest.txt", 250)
    output:Log("BPMAP_FIND_CHEST: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)
RegisterConsoleCommandHandler("BPMAP_FIND_CHESTS", function(_, _, output)
    local ok, msg = write_runtime_objects("chests", "find_chests.txt", 250)
    output:Log("BPMAP_FIND_CHESTS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)
RegisterConsoleCommandHandler("BPMAP_FIND_BOX", function(_, _, output)
    local ok, msg = write_runtime_objects("box", "find_box.txt", 250)
    output:Log("BPMAP_FIND_BOX: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)
RegisterConsoleCommandHandler("BPMAP_FIND_BOXES", function(_, _, output)
    local ok, msg = write_runtime_objects("boxes", "find_boxes.txt", 250)
    output:Log("BPMAP_FIND_BOXES: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_VERIFY_ALTAR", function(_, _, output)
    output:Log("ALTAR: no altar-specific function confirmed yet. Run BPMAP_DISCOVER_EVENTS, then BPMAP_WATCH with the exact discovered function path.\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_VERIFY_BOSS", function(_, _, output)
    output:Log("BOSS: no boss-defeat-specific function confirmed yet. Run BPMAP_DISCOVER_EVENTS, then BPMAP_WATCH with the exact discovered function path. Victory hook count=" .. tostring(RegisterHookCounts.OnVictory or 0) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_EVENT_STATUS", function(_, _, output)
    output:Log("BPMAP_EVENT_STATUS: Item=" .. tostring(RegisterHookCounts.OnPickupAbilityGeneric or 0) ..
        " Weapon=" .. tostring(RegisterHookCounts.OnPickupWeaponGeneric or 0) ..
        " RoomClear=" .. tostring(RegisterHookCounts.OnRoomCleared or 0) ..
        " Victory=" .. tostring(RegisterHookCounts.OnVictory or 0) ..
        " AddKeys=" .. tostring(RegisterHookCounts.AddKeys or 0) ..
        " GiveHealth=" .. tostring(RegisterHookCounts.GiveHealth or 0) ..
        " HealthContainer=" .. tostring(RegisterHookCounts.AddHealthContainer or 0) ..
        " Shield=" .. tostring(RegisterHookCounts.AddShieldHealth or 0) ..
        " Damage=" .. tostring(RegisterHookCounts.AddPlayerStatWeaponDamage or 0) ..
        " Crit=" .. tostring(RegisterHookCounts.AddPlayerStatWeaponCritical or 0) ..
        " Range=" .. tostring(RegisterHookCounts.AddPlayerStatRange or 0) ..
        " Speed=" .. tostring(RegisterHookCounts.AddPlayerStatMovementSpeed or 0) ..
        " Luck=" .. tostring(RegisterHookCounts.AddPlayerStatLuck or 0) ..
        " ExtraAmmo=" .. tostring(RegisterHookCounts.AddPlayerStatExtraAmmo or 0) ..
        " AbilityPower=" .. tostring(RegisterHookCounts.AddPlayerStatAbilityPower or 0) ..
        " last=" .. tostring(RegisterHookLastFunction) .. "\n")
    return true
end)


-- ============================================================
-- Game object / watcher diagnostics
-- ============================================================

local function find_first_of_any(names)
    for _, name in ipairs(names) do
        local ok, obj = pcall(function() return FindFirstOf(name) end)
        if ok and valid(obj) then return obj end
    end
    return nil
end

local GAMEOBJ_LOOKUPS = {
    instance = { "BPMGameInstance", "BPMBaseGameInstance" },
    state = { "BPMGameState" },
    mode = { "BPMGameMode", "BPMGameModeBase" }
}

local function write_gameobj_dump(which)
    local names = GAMEOBJ_LOOKUPS[string.lower(tostring(which or ""))]
    if not names then return false, "usage: BPMAP_GAMEOBJ <instance|state|mode>" end

    local obj = find_first_of_any(names)
    local filename = "gameobj_" .. string.lower(which) .. ".txt"

    local f = io.open(IPC_DIR .. filename, "w")
    if not f then return false, "could not open " .. filename end

    if not valid(obj) then
        f:write("NOT_FOUND\ttried: ", table.concat(names, " | "), "\n")
        f:close()
        return false, filename .. " written; no live instance found"
    end

    f:write("OBJECT\t", safe_fullname(obj), "\n")

    local cls = nil
    pcall(function() cls = obj:GetClass() end)

    local level = 0
    local total_props = 0

    while valid(cls) and level < 12 do
        level = level + 1
        f:write("CLASS_LEVEL\t", tostring(level), "\t", safe_fullname(cls), "\n")

        local prop_count = 0
        pcall(function()
            cls:ForEachProperty(function(prop)
                prop_count = prop_count + 1
                total_props = total_props + 1

                local pname = "<unknown>"
                local pclass = "<unknown>"
                local poffset = "<unknown>"

                pcall(function() pname = prop:GetFName():ToString() end)
                pcall(function() pclass = safe_fullname(prop:GetClass()) end)
                pcall(function() poffset = string.format("0x%04X", prop:GetOffset_Internal()) end)

                f:write("PROP\t", poffset, "\t", pclass, "\t", pname, "\n")
            end)
        end)

        f:write("PROPERTY_COUNT\t", tostring(prop_count), "\n")

        local super = nil
        pcall(function() super = cls:GetSuperStruct() end)
        cls = super
    end

    f:write("---\nTOTAL_PROPERTIES\t", tostring(total_props), "\n")
    f:close()

    return true, filename .. " written; total_properties=" .. tostring(total_props)
end

RegisterConsoleCommandHandler("BPMAP_GAMEOBJ", function(_, params, output)
    local ok, msg = write_gameobj_dump(params and params[1] or "")
    output:Log("BPMAP_GAMEOBJ: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

local WatchedFunctions = {}
local WatchEventCounts = {}

local function install_watch(name)
    if WatchedFunctions[name] then return true, name .. " already watched" end

    local path
    if string.find(name, ":", 1, true) then
        path = name
    else
        path = "/Script/BPM.BPMCharacter:" .. name
    end
    local ok, a, b = pcall(function()
        return RegisterHook(
            path,
            function(...)
                -- Manual event watches are counter-only so even a noisy
                -- candidate function does not perform filesystem I/O.
                WatchEventCounts[name] = (WatchEventCounts[name] or 0) + 1
            end
        )
    end)

    if not ok then
        return false, "RegisterHook failed for " .. path .. ": " .. tostring(a)
    end

    WatchedFunctions[name] = { a, b, path = path }
    WatchEventCounts[name] = WatchEventCounts[name] or 0
    return true, "watching " .. path
end

RegisterConsoleCommandHandler("BPMAP_WATCH", function(_, params, output)
    params = params or {}
    local name = table.concat(params, " ")
    if name == "" then
        output:Log("Usage: BPMAP_WATCH <FunctionName or FullFunctionPath>\n")
        return true
    end

    local ok, msg = install_watch(name)
    output:Log("BPMAP_WATCH: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

RegisterConsoleCommandHandler("BPMAP_WATCH_STATUS", function(_, _, output)
    local shown = 0
    for name, state in pairs(WatchedFunctions) do
        shown = shown + 1
        output:Log("WATCH " .. tostring(name) .. " count=" .. tostring(WatchEventCounts[name] or 0) .. " path=" .. tostring(state.path or "") .. "\n")
    end
    if shown == 0 then output:Log("WATCH: no custom functions watched\n") end
    return true
end)

-- ============================================================
-- World dump
-- ============================================================

RegisterConsoleCommandHandler("BPMAP_WORLD", function(_, _, output)
    local f = io.open(IPC_DIR .. "world_dump.txt", "w")
    if not f then
        output:Log("BPMAP_WORLD: could not open world_dump.txt\n")
        return true
    end

    local ok, world = pcall(function() return FindFirstOf("World") end)

    if ok and valid(world) then
        f:write("WORLD\t", safe_fullname(world), "\n")

        local level = nil
        pcall(function() level = world.PersistentLevel end)

        if valid(level) then
            f:write("PERSISTENT_LEVEL\t", safe_fullname(level), "\n")
        end
    else
        f:write("WORLD_NOT_FOUND\n")
    end

    f:close()
    output:Log("BPMAP_WORLD: wrote world_dump.txt\n")
    return true
end)

-- ============================================================
-- Class property dump
-- ============================================================

local function write_class_props_by_path(class_path, filename)
    local requested = tostring(class_path or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if requested == "" then return false, "usage: BPMAP_CLASS_PROPS </Script/BPM.ClassName>" end

    local f = io.open(IPC_DIR .. filename, "w")
    if not f then return false, "could not open " .. filename end

    f:write("BPM CLASS PROPERTY DUMP (force-resolved)\n")
    f:write("REQUESTED\t", requested, "\n---\n")

    local cls = nil
    local tried = {}

    for _, candidate in ipairs({ requested, "Class " .. requested }) do
        table.insert(tried, candidate)

        local ok, result = pcall(function() return StaticFindObject(candidate) end)
        if ok and valid(result) then
            cls = result
            f:write("RESOLVED_VIA\t", candidate, "\n")
            break
        end
    end

    if not valid(cls) then
        f:write("RESOLVE_FAILED\n")
        f:write("TRIED\t", table.concat(tried, " | "), "\n")
        f:close()
        return false, filename .. " written; class could not be resolved"
    end

    f:write("RESOLVED_CLASS\t", safe_fullname(cls), "\n---\n")

    local level = 0
    local total_props = 0

    while valid(cls) and level < 12 do
        level = level + 1
        f:write("CLASS_LEVEL\t", tostring(level), "\t", safe_fullname(cls), "\n")

        local prop_count = 0

        pcall(function()
            cls:ForEachProperty(function(prop)
                prop_count = prop_count + 1
                total_props = total_props + 1

                local pname = "<unknown>"
                local pclass = "<unknown>"
                local poffset = "<unknown>"

                pcall(function() pname = prop:GetFName():ToString() end)
                pcall(function() pclass = safe_fullname(prop:GetClass()) end)
                pcall(function() poffset = string.format("0x%04X", prop:GetOffset_Internal()) end)

                f:write("PROP\t", poffset, "\t", pclass, "\t", pname, "\n")
            end)
        end)

        f:write("PROPERTY_COUNT\t", tostring(prop_count), "\n")

        local super = nil
        pcall(function() super = cls:GetSuperStruct() end)
        cls = super
    end

    f:write("---\nTOTAL_PROPERTIES\t", tostring(total_props), "\n")
    f:close()

    return true, filename .. " written; total_properties=" .. tostring(total_props)
end

RegisterConsoleCommandHandler("BPMAP_CLASS_PROPS", function(_, params, output)
    local ok, msg = write_class_props_by_path(params and params[1] or "", "class_props_dump.txt")
    output:Log("BPMAP_CLASS_PROPS: " .. tostring(ok) .. " " .. tostring(msg) .. "\n")
    return true
end)

-- ============================================================
-- SaveGame probe
-- ============================================================

local SAVEGAME_PROBE_FIELDS = {
    "LatestCompletedFloor", "LatestHardCompletedFloor", "LatestHellishCompletedFloor",
    "HighScore", "Streak", "BestTime", "ShopSpend", "ArmourySpend",
    "FinalDishDonations", "TipIndex", "AllKills", "CharA", "CharB", "CharC", "CharD", "CharE"
}

RegisterConsoleCommandHandler("BPMAP_SAVEGAME_DUMP", function(_, _, output)
    local filename = "savegame_dump.txt"
    local f = io.open(IPC_DIR .. filename, "w")

    if not f then
        output:Log("BPMAP_SAVEGAME_DUMP: could not open " .. filename .. "\n")
        return true
    end

    local instance = find_first_of_any({ "BPMGameInstance", "BPMBaseGameInstance" })

    if not valid(instance) then
        f:write("GAME_INSTANCE_NOT_FOUND\n")
        f:close()
        output:Log("BPMAP_SAVEGAME_DUMP: game instance not found\n")
        return true
    end

    f:write("GAME_INSTANCE\t", safe_fullname(instance), "\n")

    local getter = instance["GetActiveGameSave"]
    if not getter or not getter.IsValid or not getter:IsValid() then
        f:write("GETTER_NOT_VALID\n")
        f:close()
        output:Log("BPMAP_SAVEGAME_DUMP: GetActiveGameSave not callable\n")
        return true
    end

    local ok, save_obj = pcall(function() return getter() end)

    if not ok or not valid(save_obj) then
        f:write("CALL_FAILED\t", tostring(save_obj), "\n")
        f:close()
        output:Log("BPMAP_SAVEGAME_DUMP: GetActiveGameSave() unavailable\n")
        return true
    end

    f:write("SAVE_OBJECT\t", safe_fullname(save_obj), "\n---\n")

    local cls = nil
    pcall(function() cls = save_obj:GetClass() end)

    local level = 0
    local total_props = 0

    while valid(cls) and level < 12 do
        level = level + 1
        f:write("CLASS_LEVEL\t", tostring(level), "\t", safe_fullname(cls), "\n")

        local prop_count = 0
        pcall(function()
            cls:ForEachProperty(function(prop)
                prop_count = prop_count + 1
                total_props = total_props + 1

                local pname = "<unknown>"
                local pclass = "<unknown>"
                local poffset = "<unknown>"

                pcall(function() pname = prop:GetFName():ToString() end)
                pcall(function() pclass = safe_fullname(prop:GetClass()) end)
                pcall(function() poffset = string.format("0x%04X", prop:GetOffset_Internal()) end)

                f:write("PROP\t", poffset, "\t", pclass, "\t", pname, "\n")
            end)
        end)

        f:write("PROPERTY_COUNT\t", tostring(prop_count), "\n")

        local super = nil
        pcall(function() super = cls:GetSuperStruct() end)
        cls = super
    end

    f:write("TOTAL_PROPERTIES\t", tostring(total_props), "\n---\n")
    f:write("LIVE_VALUES\n")

    for _, field in ipairs(SAVEGAME_PROBE_FIELDS) do
        local pok, value = pcall(function() return save_obj[field] end)
        if pok and value ~= nil then
            f:write("VALUE\t", field, "\t", tostring(value), "\n")
        end
    end

    f:close()
    output:Log("BPMAP_SAVEGAME_DUMP: wrote " .. filename .. " total_properties=" .. tostring(total_props) .. "\n")
    return true
end)

-- ============================================================
-- Generic GameInstance/GameState/GameMode caller
-- ============================================================

RegisterConsoleCommandHandler("BPMAP_CALL", function(_, params, output)
    params = params or {}

    local which = params[1] or ""
    local fn_name = params[2] or ""

    if which == "" or fn_name == "" then
        output:Log("Usage: BPMAP_CALL <instance|state|mode> <FunctionName> [args...]\n")
        return true
    end

    local names = GAMEOBJ_LOOKUPS[string.lower(which)]
    if not names then
        output:Log("BPMAP_CALL: unknown target '" .. which .. "'\n")
        return true
    end

    local obj = find_first_of_any(names)
    if not valid(obj) then
        output:Log("BPMAP_CALL: " .. which .. " not found\n")
        return true
    end

    local fn = obj[fn_name]
    if not fn or not fn.IsValid or not fn:IsValid() then
        output:Log("BPMAP_CALL: " .. fn_name .. " not valid on " .. which .. "\n")
        return true
    end

    local args = {}
    for i = 3, #params do
        local n = tonumber(params[i])
        table.insert(args, n ~= nil and n or params[i])
    end

    local ok, result = pcall(function() return fn(table.unpack(args)) end)
    output:Log(
        "BPMAP_CALL: " .. fn_name ..
        " ok=" .. tostring(ok) ..
        " result=" .. tostring(result) .. "\n"
    )
    return true
end)

-- ============================================================
-- Begin Play hook
-- ============================================================

RegisterBeginPlayPostHook(function(ContextParam)
    local context = ContextParam:get()

    if valid(context) then
        local full = fullname(context)

        if string.find(full, "BP_BPMPlayerCharacter_C", 1, true) then
            Player = context

            if not HooksInstalled then
                install_hooks(context)
            end
        end
    end
end)

-- ============================================================
-- Initial player/hook attempt
-- ============================================================

local p = get_player()
if p then install_hooks(p) end

-- ============================================================
-- Runtime initialization
-- ============================================================

Log(
    "v1.5.0 loaded IPC_READY=" ..
    tostring(IPC_READY) ..
    " hooks_installed=" ..
    tostring(HooksInstalled)
)

Log("BPMArchipelago v1.5.1 first real reward patch active")
Log("Automatic AP item delivery mode: event-hooks (AddCoins/AddKeys + pickup hooks + confirmed reward hooks)")
Log("MVP coin locations: 10 individual + milestones 5/10/25")
Log("First real reward patch: treasures=10 challenges=10; other expanded categories remain manual")
Log("Automatic reward checks enabled for confirmed Treasure and Challenge reward functions. Other expanded categories remain manual until separately verified.")
