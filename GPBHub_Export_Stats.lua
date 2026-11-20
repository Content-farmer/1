--[[
    GPBHub_Export_Stats.lua v3 - companion exporter for gpbhub-account-stats.html
    --------------------------------------------------------------------------------
    Compatible with GPBHub / Generic Hub 2026-11-16_v4 (and still works on v3).

    Run with your executor while you are in the game. It will:
      1. Find the game's ECS world + your player entity (same technique the hub uses).
      2. Read your account data: Coins, Molten Obsidian, Stardust, Wishes,
         PlayerLevel/Class, Fishing (stash/bait/charms/rods), Rings, Potions,
         EquippedCharm/Weapon/Armor, Item/Weapon/Armor entities with the hub's
         exact v4 gear score (skills + passives weighted DPS), Mythical forge
         progress, relics, equipped title, etc.
      3. Track this session: coins earned, wishes earned and an average
         coins/hour rate (only increases count, so spending is never counted
         as negative farming). State survives reloads via
         GPBHub/data/session_<userId>.json and resets after a 30-min gap.
      4. Save GPBHub/stats.json, and LIVE-PUSH the JSON to your stats server.
      5. Survive lobby changes: arms queue_on_teleport so the script re-runs
         itself automatically after every teleport/server hop (session totals
         carry over - they only reset after a 30-min gap).

    Live tracking:
      - Default: posts straight to the hosted dashboard server
        https://gpbhub.onrender.com/report  -> open https://gpbhub.onrender.com/
        in a browser for the LIVE dashboard (no local server needed).
        NOTE: Render's free tier sleeps after ~15 min idle; the FIRST push
        after a sleep can take up to ~60s while the server wakes up. The
        push loop retries automatically - just give it a minute.
      - Or run the included GPBHub_Live_Server.js locally
        (node GPBHub_Live_Server.js, dashboard at http://127.0.0.1:8787/).

    Config (set on getgenv() before/while running):
      getgenv().GPBHubStatsUrl      = "https://gpbhub.onrender.com/report"
                                    -- (a bare base like "https://gpbhub.onrender.com"
                                    --  also works: /report is appended automatically)
      getgenv().GPBHubStatsInterval = 5        -- seconds between pushes (min 2)
      getgenv().GPBHubStatsToken    = ""       -- bearer token, if the server uses one
      getgenv().GPBHubStatsAutoReload = true   -- re-run automatically after lobby changes/teleports
      getgenv().GPBHubStatsSelfUrl    = "https://raw.githubusercontent.com/Content-farmer/1/main/GPBHub_Export_Stats.lua"
                                               -- where the auto-reloader re-downloads the script from
      getgenv().GPBHubStatsLive()             -- toggle live loop on/off
      getgenv().GPBHubExportStats()           -- one-shot export (also copies to clipboard)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- ------------------------------------------------------------------ settings
local DEFAULT_URL = "https://gpbhub.onrender.com/report"
local DEFAULT_SELF_URL = "https://raw.githubusercontent.com/Content-farmer/1/main/GPBHub_Export_Stats.lua"
local DEFAULT_INTERVAL = 5

-- Accept a bare base ("https://gpbhub.onrender.com", "http://127.0.0.1:8787",
-- with or without trailing slash) and always end up on the /report endpoint.
local function normalizeUrl(u)
        u = tostring(u or ""):gsub("%s+", "")
        if u == "" then
                return DEFAULT_URL
        end
        if not (u:match("^https?://")) then
                u = "https://" .. u
        end
        u = u:gsub("/+$", "") -- strip trailing slashes
        if not u:match("/report$") then
                u = u .. "/report"
        end
        return u
end

local function liveCfg()
        local g = (type(getgenv) == "function" and getgenv()) or {}
        local interval = tonumber(g.GPBHubStatsInterval) or DEFAULT_INTERVAL
        if interval < 2 then
                interval = 2
        end
        return normalizeUrl(g.GPBHubStatsUrl or DEFAULT_URL), interval, tostring(g.GPBHubStatsToken or "")
end

-- ------------------------------------------------------------------- helpers
local LP = Players.LocalPlayer
while not LP do
        task.wait()
        LP = Players.LocalPlayer
end

local function notify(msg)
        print("[GPBHub Export] " .. tostring(msg))
        pcall(function()
                game:GetService("StarterGui"):SetCore("SendNotification", {
                        Title = "GPBHub Stats Export",
                        Text = tostring(msg),
                        Duration = 8,
                })
        end)
end

local src = ReplicatedStorage:FindFirstChild("src")
if not src then
        notify("ReplicatedStorage.src not found - run this inside the GPB game, not the executor console.")
        return
end

local function req(...)
        local node = src
        for _, name in ipairs({ ... }) do
                node = node and node:FindFirstChild(name)
        end
        if not node then
                return nil
        end
        local ok, mod = pcall(require, node)
        if ok and type(mod) == "table" then
                return mod
        end
        return nil
end

local comps = req("ecs", "components")
if not comps then
        notify("Could not load ecs/components - is this the right game?")
        return
end
local findOwner = req("ecs", "utils", "find_first_ancestor_w_component")
local upgradeUtil = req("upgrade_util")
local ringCfg = req("configs", "ring_config")
local stashCap = req("stash_capacity_util")
local potionFish = req("potion_fish_util")
local placeKind = req("place_kind_util")
local WeaponStat = req("types", "enums", "WeaponStat")
local PlaceEnum = req("types", "enums", "PlaceId")

-- v4 gear-score dependencies (all optional; missing ones degrade gracefully)
local tierUtil = req("armor_tier_util")
local knockbackCfg = req("configs", "knockback_config")
local armoryMenuCfg = req("configs", "armory_menu_config")
local elkCfg = req("configs", "elk_config")
local gameplayCfg = req("configs", "gameplay")
local mythConf = req("configs", "mythical_config")
local forgeCfg = req("configs", "forge_config")
local titleConf = req("configs", "title_config")

local function num(v)
        if type(v) == "number" and v == v and math.abs(v) < math.huge then
                return v
        end
        return nil
end

local function valid(v)
        return type(v) == "number" and v == v and math.abs(v) < math.huge
end

local RANK = { Mythical = -1, Vaulted = 0, Legendary = 1, Epic = 2, Rare = 3, Common = 4 }
local function rankOf(r)
        return RANK[tostring(r)] or 9
end

local function jsonSafe(v, depth)
        depth = depth or 0
        local t = type(v)
        if t == "boolean" then
                return v
        elseif t == "number" then
                return num(v)
        elseif t == "string" then
                return v
        elseif t ~= "table" then
                return nil
        end
        if depth >= 4 then
                return nil
        end
        local isArray, maxI, count = true, 0, 0
        for k in pairs(v) do
                count = count + 1
                if type(k) ~= "number" then
                        isArray = false
                elseif k > maxI then
                        maxI = k
                end
        end
        if count == 0 then
                return nil
        end
        if isArray and maxI == count then
                local out = {}
                for i = 1, count, 1 do
                        local sv = jsonSafe(v[i], depth + 1)
                        if sv ~= nil then
                                out[#out + 1] = sv
                        end
                end
                return out
        end
        local map = {}
        for k, sv in pairs(v) do
                if type(k) == "string" then
                        local s2 = jsonSafe(sv, depth + 1)
                        if s2 ~= nil then
                                map[k] = s2
                        end
                end
        end
        if next(map) == nil then
                return nil
        end
        return map
end

-- -------------------------------------------------------------- v4 score port
-- Constants copied from the hub (2026-11-16_v4). Skill and passive multipliers
-- are identical to the hub's tables so the exported score matches Equip Best.
local gpPlayers = (type(gameplayCfg) == "table" and type(gameplayCfg.players) == "table" and gameplayCfg.players) or {}
local SCORE_K = {
        AURA_HZ = 20,
        CRIT_BONUS = 0.5,
        BUFF_DMG_SHARE = 0.5,
        E_WINDOW = 60,
        W_DASH_RATE = 0.1,
        W_SKILL_USE = 3,
        DODGE_SHARE = 0.3,
        DODGE_THREAT = 0.6,
        DASH_COST = tonumber(gpPlayers.dash_energy_cost) or 12.5,
        DASH_MAX = 1 / (tonumber(gpPlayers.dash_refill_interval) or 1.5),
        WALK_REF = 18,
        W_WALK_TWEEN = 0.02,
        W_WALK_FREE = 0.12,
        W_HP = 1,
        W_HP_GODMODE = 0.1,
        KB_REF = 3,
        W_KB_AURA = 0.01,
        CD_MIN = 0.5,
        UNKNOWN_PASSIVE_E = 1.1,
        UNKNOWN_SKILL_W = 1.5,
        REF_ENERGY = 125,
        REF_FILL = 5,
}

local SKILL_W = {
        ablaze = { 1.12, 0, 0.16, 10 },
        adrenaline = { 0, 0, 0, 0 },
        angels_bane = { 1, 0, 0.17, 7 },
        arctic_wind = { 0, 0, 0, 0 },
        astral_projection = { 2.6, 0, 0.5, 8 },
        berserk = { 0, 0, 0.5, 5 },
        black_hole = { 2.55, 0, 0, 0 },
        blade_storm = { 5.79, 0, 0, 0 },
        bladedash = { 2, 0, 0, 0 },
        blind = { 0, 0, 0, 0 },
        blood_snowstorm = { 0, 0, 0.2, 8 },
        blood_thirst = { 0, 0, 0.5, 5 },
        bloody_gunpowder = { 0, 0.72, 0, 0 },
        bloody_nightmare = { 0, 0, 0.39, 12.5 },
        blue_streak = { 3.9, 0, 0.2, 8, h = 0 },
        bone_break = { 0, 0, 0, 0 },
        bone_strength = { 0, 0, 0.21, 18 },
        chain_reaction = { 2.1, 0, 0, 0 },
        clockwork = { 0, 0, 0, 4 },
        constellation = { 2.77, 0, 0, 0 },
        cosmic_beam = { 4.7, 0, 0, 0 },
        cosmic_vision = { 0, 0, 0.25, 13 },
        death_grasp = { 0.7, 0, 0, 0 },
        death_sentence = { 2.4, 0, 0, 0 },
        demon_impale = { 0, 0.41, 0, 0, cd = 6 },
        earthquake = { 0.71, 0, 0, 0 },
        fire_dragon = { 3, 0, 0, 0 },
        flame_choke = { 1.82, 0, 0, 0 },
        fractured_time = { 0, 0, 0.21, 6 },
        frost_shock = { 1.5, 0, 0, 0 },
        frozen_wall = { 0, 0, 0, 0 },
        gemstone = { 0.45, 0, 0, 0 },
        golden_army = { 0, 2.56, 0, 0 },
        golden_eclipse = { 5, 0, 0, 0 },
        inferno = { 0.75, 0, 0.05, 5.3 },
        ink_decoy = { 3.5, 0, 0, 0 },
        katar_dash = { 5.3, 0, 0, 7 },
        lightning = { 1.41, 0, 0, 0 },
        lightning_balls = { 3.3, 0, 0, 0 },
        lost_souls = { 0, 0, 0, 0 },
        lunar_spell = { 3.46, 0, 0, 0 },
        mark_of_death = { 7.1, 0, 0, 0 },
        marking_punch = { 3.5, 0, 0, 0, cd = 9 },
        molten_beam = { 11.5, 0, 0, 0 },
        mothers_blessing = { 0, 0.6, 0, 0 },
        oblivion = { 4.74, 0, 0, 0 },
        obsidian_stick = { 0, 0.32, 0, 0 },
        pickle = { 0, 0, 0.2, 9.9 },
        pierce = { 2, 0, 0, 0 },
        python = { 0, 0.35, 0, 0, cd = 15 },
        raise_the_dead = { 0, 2, 0, 0, cd = 12 },
        raven_sense = { 0, 0, 0, 0 },
        rejuvenate = { 0, 0, 0, 0 },
        sand_tornado = { 3.54, 0, 0, 0 },
        shadow_hook = { 5.25, 0, 0, 0 },
        shroom = { 0, 0.32, 0, 0 },
        slash = { 2, 0, 0, 0 },
        smash = { 1.4, 0, 0, 0 },
        smite = { 3.39, 0, 0, 0 },
        smokebomb = { 0, 0, 0, 0 },
        soar = { 2.65, 0, 0, 0 },
        solar = { 4.24, 0, 0, 0 },
        specter = { 0, 0.13, 0, 0, cd = 10 },
        spikes = { 4.03, 0, 0, 0 },
        spiritual_warp = { 0, 0.22, 0, 0, cd = 7 },
        sprint = { 0, 0, 0, 7.2 },
        subzero = { 0.6, 0, 0.05, 5.3 },
        titan = { 0, 0, 0.6, 6 },
        tornado = { 3.35, 0, 0, 0 },
        tsunami = { 1.94, 0, 0, 0 },
        venom = { 0.6, 0, 0.05, 5.3 },
        venom_strike = { 3.22, 0, 0, 3, cd = 10 },
        void_grip = { 2.74, 0, 0, 0 },
        void_slashes = { 13.64, 0, 0, 0, en = 99, h = 7.37 },
        void_warp = { 4.4, 0, 0, 1.5, cd = 12, h = 2 },
        weeping_touch = { 0, 0.67, 0, 0 },
        whirlpool = { 8.91, 0, 0, 0 },
        wing_smash = { 4.58, 0, 0, 0 },
}

local PASSIVE_W = {
        ["Elden Wind"] = { 1.02, 1 },
        ["Onyx Aegis"] = { 1.12, 1 },
        ["Rebirth"] = { 1.08, 1 },
        ["Mineral Fortification"] = { 1.01, 1 },
        ["Stealthy Ambush"] = { 1.01, 1 },
        ["Soul Charge"] = { 1.05, 1.01 },
        ["Blood Harvest"] = { 1.14, 1 },
        ["Void Rift"] = { 1, 1.01 },
        ["Soul Seeker"] = { 1, 1.01 },
        ["Golden Shield"] = { 1.2, 1 },
        ["Wings of the Guardian"] = { 1, 1 },
        ["Shadow Boots"] = { 1.04, 1 },
        ["Glide"] = { 1, 1 },
        ["Ancient Roots"] = { 1.05, 1 },
        ["Glowing Antlers"] = { 1.17, 1 },
        ["Ferocity"] = { 1, 1.14, h = true },
        ["Golden Champion"] = { 1.22, 1.02, h = true },
        ["Shellguard"] = { 1.4, 1.02 },
        ["Blessing of the Sea"] = { 1.19, 1 },
        ["Shroom Protection"] = { 1.24, 1 },
        ["Time Traveller"] = { 1.15, 1 },
        ["Hour Glass of Vitality"] = { 1.02, 1 },
        ["Poisonous Spit"] = { 1.34, 1.1 },
        ["Second Nature"] = { 1, 1 },
}

local function hubOn(key)
        local g = (type(getgenv) == "function" and getgenv()) or {}
        local cfg = g.GPBHub
        return type(cfg) == "table" and cfg[key] == true or false
end

local function parseNum(x)
        if type(x) == "number" then
                return valid(x) and x or nil
        end
        if type(x) ~= "string" then
                return nil
        end
        local n = tonumber(string.match(x, "[%d%.]+"))
        if n and string.find(x, "%", 1, true) then
                n = n / 100
        end
        return n
end

local function skillLoad(weapon)
        local out = { demand = 0, add = 0, buff = 0 }
        local skills = type(weapon) == "table" and weapon.skills
        if type(skills) ~= "table" then
                return out
        end
        for _, w in pairs(skills) do
                if type(w) == "table" then
                        local desc = (type(w.description) == "table" and w.description) or w
                        local key = type(desc.key) == "string" and string.match(desc.key, "^ui%.skill%.([%w_]+)%.") or nil
                        local k = (key and SKILL_W[key]) or { SCORE_K.UNKNOWN_SKILL_W, 0, 0, 0 }
                        local args = (type(desc.args) == "table" and desc.args) or w
                        local f, t, q = k[1], k[3], k[4]
                        if f > 0 and k.h ~= 0 then
                                local x = parseNum(args.damage_multiplier) or parseNum(args.pull_damage) or parseNum(args.burst_damage)
                                if x then
                                        f = x * (k.h or 1)
                                end
                        end
                        if t > 0 then
                                t = parseNum(args.damage_boost) or t
                        end
                        if q > 0 then
                                q = parseNum(args.buff_duration) or parseNum(args.buff_seconds) or parseNum(args.duration)
                                        or parseNum(args.speed_duration) or q
                        end
                        local cd = math.max(valid(weapon.cooldown) and weapon.cooldown or 0, k.cd or 0, SCORE_K.CD_MIN)
                        local en = k.en or (valid(w.energy_cost) and w.energy_cost or 0)
                        out.demand = out.demand + en / cd
                        out.add = out.add + (f / cd + k[2])
                        out.buff = out.buff + t * math.min(1, q / cd)
                end
        end
        return out
end

local function weaponData(world, ent)
        local w, item = world:get(ent, comps.Weapon), world:get(ent, comps.Item)
        local stats = type(w) == "table" and type(w.stats) == "table" and w.stats or nil
        if not stats then
                return nil
        end
        local dmg = WeaponStat and stats[WeaponStat.Damage] or nil
        local crit = WeaponStat and stats[WeaponStat.CriticalChance] or nil
        if not (valid(dmg) and valid(crit)) then
                return nil
        end
        local f = skillLoad(w)
        local kb = SCORE_K.KB_REF
        if type(knockbackCfg) == "table" and type(knockbackCfg.for_weapon) == "function" and type(item) == "table" then
                local ok, r = pcall(knockbackCfg.for_weapon, item.id)
                if ok and type(r) == "table" and valid(r.force) and valid(r.duration) then
                        kb = math.clamp(r.force * r.duration, 0, 10)
                end
        end
        return {
                dmg = dmg,
                crit = math.clamp(crit, 0, 1),
                kb = kb,
                attackSpeed = WeaponStat and num(stats[WeaponStat.AttackSpeed]) or nil,
                demand = f.demand,
                add = f.add,
                buff = f.buff,
        }
end

local function dps(wd, refEnergy, refFill, mult)
        local u = 1
        if wd.demand > 0 then
                u = math.clamp(
                        (refEnergy + (refFill - SCORE_K.W_DASH_RATE * SCORE_K.DASH_COST)) * SCORE_K.E_WINDOW
                                / (wd.demand * SCORE_K.E_WINDOW),
                        0,
                        1
                )
        end
        return (wd.dmg * ((SCORE_K.AURA_HZ * (1 + SCORE_K.CRIT_BONUS * wd.crit)) * (1 + (SCORE_K.BUFF_DMG_SHARE * u) * wd.buff) * mult + u * wd.add))
                * (1 + SCORE_K.W_KB_AURA * (wd.kb - SCORE_K.KB_REF))
end

local function stepValue(base, steps, tier)
        if type(steps) ~= "table" then
                return base
        end
        for _, st in pairs(steps) do
                if type(st) ~= "table" or not valid(st.tier) or tier < st.tier then
                        break
                end
                base = st.value
        end
        return base
end

local function antlersMult(tier)
        local e = type(elkCfg) == "table" and elkCfg.glowing_antlers or nil
        if type(e) ~= "table" then
                return nil
        end
        local dmgTaken = stepValue(e.damage_taken, e.damage_taken_steps, tier)
        local cool = stepValue(e.cooldown, e.cooldown_steps, tier)
        if not (valid(dmgTaken) and valid(cool) and valid(e.duration)) then
                return nil
        end
        if dmgTaken < 0 or dmgTaken >= 1 or cool < 0 or e.duration <= 0 then
                return nil
        end
        local eff = 1 - math.min(1, e.duration / (cool + 2)) * (1 - dmgTaken)
        if eff <= 0.05 then
                return nil
        end
        return 1 / eff
end

local function armorData(world, ent)
        local a, item = world:get(ent, comps.Armor), world:get(ent, comps.Item)
        if not (tierUtil and type(a) == "table" and type(item) == "table") then
                return nil
        end
        if not (valid(a.health) and a.health > 0 and valid(item.tier)) or tostring(a.id) == "None" then
                return nil
        end
        local ok, hpF, enF, fillF, passives = pcall(function()
                return tierUtil.health_bonus_fraction(a.rarity, item.tier, a.id),
                        tierUtil.max_energy_bonus_fraction(a.rarity, item.tier, a.id),
                        (type(tierUtil.energy_fill_rate_bonus_fraction) == "function"
                                and tierUtil.energy_fill_rate_bonus_fraction(a.rarity, item.tier, a.id)
                                or 0),
                        tierUtil.unlocked_passives(a.rarity, item.tier, a.id)
        end)
        if not (ok and valid(hpF) and valid(enF) and valid(fillF) and valid(passives)) then
                return nil
        end
        local passiveList = nil
        if type(armoryMenuCfg) == "table" and type(armoryMenuCfg.armor_passives) == "table" then
                passiveList = armoryMenuCfg.armor_passives[a.id]
        end
        local ferocity = hubOn("autoparry") or hubOn("autododge")
        local eMult, dodgeMult = 1, 1
        local count = (type(passiveList) == "table" and #passiveList) or passives
        for i = 1, count, 1 do
                local okT, unlockTier = pcall(tierUtil.passive_unlock_tier, a.rarity, i, a.id)
                local unlocked = i <= passives
                if okT and valid(unlockTier) then
                        unlocked = item.tier >= unlockTier
                end
                if unlocked then
                        local name = (type(passiveList) == "table" and type(passiveList[i]) == "table" and passiveList[i].name) or nil
                        local u = PASSIVE_W[name or false] or PASSIVE_W[tostring(a.id) .. "." .. i]
                        local em, dm = SCORE_K.UNKNOWN_PASSIVE_E, 1
                        if u then
                                em, dm = u[1], u[2]
                        end
                        if name == "Glowing Antlers" then
                                em = antlersMult(item.tier) or em
                        end
                        if u and u.h and not ferocity then
                                em, dm = 1, 1
                        end
                        eMult, dodgeMult = eMult * em, dodgeMult * dm
                end
        end
        return {
                hp = math.floor(a.health * (1 + hpF) + 0.5),
                e = eMult,
                da = dodgeMult,
                en = (valid(a.energy) and a.energy or 0) * (1 + enF),
                fill = (valid(a.energy_fill_rate) and a.energy_fill_rate or 0) * (1 + fillF),
                walk = (valid(a.walk_speed) and a.walk_speed or SCORE_K.WALK_REF),
                passives = passives,
        }
end

local function armorCore(ad, energyMult)
        local w = math.min(
                SCORE_K.DASH_MAX,
                math.max(0, ad.fill - SCORE_K.W_SKILL_USE) / SCORE_K.DASH_COST + (ad.en / SCORE_K.DASH_COST) / SCORE_K.E_WINDOW
        )
        local dodgeE = 1 / (1 - SCORE_K.DODGE_SHARE * math.min(1, w / SCORE_K.DODGE_THREAT))
        local walkW = hubOn("tp") and SCORE_K.W_WALK_TWEEN or SCORE_K.W_WALK_FREE
        return (ad.hp * energyMult * dodgeE) ^ (hubOn("godmode") and SCORE_K.W_HP_GODMODE or SCORE_K.W_HP)
                * (1 + (walkW * (ad.walk - SCORE_K.WALK_REF)) / SCORE_K.WALK_REF)
end

-- ------------------------------------------------------------------- world
local world, replicator, playerEnt

local function scanWorld()
        local reps, worlds = {}, {}
        for _, v in getgc(true) do
                if type(v) == "table" then
                        if type(rawget(v, "replicator")) == "table" and rawget(v, "local_player_entity") ~= nil then
                                reps[#reps + 1] = v
                        elseif rawget(v, "entity_index") ~= nil and rawget(v, "archetypes") ~= nil then
                                worlds[#worlds + 1] = v
                        end
                end
        end
        for _, r in ipairs(reps) do
                local e = r.local_player_entity
                for _, w in ipairs(worlds) do
                        local ok, res = pcall(function()
                                return w:contains(e) and w:has(e, comps.Player)
                        end)
                        if ok and res == true then
                                replicator, world, playerEnt = r, w, e
                                return true
                        end
                end
        end
        return false
end

local function worldValid()
        if not (world and playerEnt) then
                return false
        end
        local ok, res = pcall(function()
                return world:contains(playerEnt) and world:has(playerEnt, comps.Player)
        end)
        return ok and res == true
end

local function ensureWorld()
        if worldValid() then
                return true
        end
        world, replicator, playerEnt = nil, nil, nil
        for _ = 1, 10, 1 do
                if scanWorld() then
                        return true
                end
                task.wait(0.5)
        end
        return false
end

local function get(c, ent)
        if not world or not (ent or playerEnt) or c == nil then
                return nil
        end
        local ok, v = pcall(world.get, world, ent or playerEnt, c)
        return ok and v or nil
end

local function has(c, ent)
        local ok, v = pcall(world.has, world, ent or playerEnt, c)
        return ok and v == true
end

local function owner(ent)
        if not findOwner then
                return nil
        end
        local ok, v = pcall(findOwner, world, ent, comps.Player)
        return ok and v or nil
end

local function rawComp(c, depth)
        local v = get(c)
        if type(v) ~= "table" then
                return nil
        end
        return jsonSafe(v, depth or 2)
end

-- scalar components (Coins / MoltenObsidian / Wishes) are tables with a
-- .value field; tolerate a bare number too, in case the game changes
local function scalarComp(c)
        local v = get(c)
        if type(v) == "table" then
                return num(v.value)
        end
        return num(v)
end

-- ------------------------------------------------------- session tracking
-- Feeds the dashboard's "coins/hr" line and the "+N wishes this session"
-- counter on the wishes card. Mirrors the hub's own session counters:
-- only increases are accumulated (spending / deaths / resets never count
-- as negative earnings), and the session resets after a 30-minute gap.
local SESSION_GAP = 1800
local sessionCache = nil

local function hasFs()
        return type(writefile) == "function" and type(readfile) == "function"
                and type(isfolder) == "function" and type(makefolder) == "function"
end

local function sessionPath(uid)
        return "GPBHub/data/session_" .. tostring(uid) .. ".json"
end

local function loadSession(uid)
        if sessionCache then
                return sessionCache
        end
        if hasFs() then
                local okR, txt = pcall(readfile, sessionPath(uid))
                if okR and type(txt) == "string" and #txt > 0 then
                        local okJ, data = pcall(function()
                                return HttpService:JSONDecode(txt)
                        end)
                        if okJ and type(data) == "table" then
                                sessionCache = data
                        end
                end
        end
        return sessionCache
end

local function saveSession(uid, s)
        sessionCache = s
        if hasFs() then
                pcall(function()
                        if not isfolder("GPBHub") then
                                makefolder("GPBHub")
                        end
                        if not isfolder("GPBHub/data") then
                                makefolder("GPBHub/data")
                        end
                        writefile(sessionPath(uid), HttpService:JSONEncode(s))
                end)
        end
end

local function updateSession(uid, coins, wishes)
        local now = os.time()
        local s = loadSession(uid)
        if
                type(s) ~= "table"
                or not valid(s.startedAt)
                or not valid(s.seenAt)
                or now - s.seenAt > SESSION_GAP
                or now < s.startedAt
        then
                s = {
                        startedAt = now,
                        seenAt = now,
                        coinsEarned = 0,
                        wishesEarned = 0,
                        lastCoins = coins,
                        lastWishes = wishes,
                }
        end
        if valid(coins) and valid(s.lastCoins) and coins > s.lastCoins then
                s.coinsEarned = (s.coinsEarned or 0) + (coins - s.lastCoins)
        end
        if valid(wishes) and valid(s.lastWishes) and wishes > s.lastWishes then
                s.wishesEarned = (s.wishesEarned or 0) + (wishes - s.lastWishes)
        end
        s.lastCoins = valid(coins) and coins or s.lastCoins
        s.lastWishes = valid(wishes) and wishes or s.lastWishes
        s.seenAt = now
        s.secondsActive = now - s.startedAt
        saveSession(uid, s)

        local coinsPerHour = nil
        local hours = s.secondsActive / 3600
        if s.secondsActive >= 60 and hours > 0 and (s.coinsEarned or 0) > 0 then
                coinsPerHour = math.floor(s.coinsEarned / hours + 0.5)
        end
        return {
                startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", s.startedAt),
                secondsActive = s.secondsActive,
                coinsEarned = s.coinsEarned,
                coinsPerHour = coinsPerHour,
                wishesEarned = s.wishesEarned,
        }
end

-- ---------------------------------------------------------------- myth meta
local MYTH_ITEMS = { "InkGauntlets", "DragonSpear", "Volt", "Valor", "Elk" }
local MYTH_ARMOR = { Valor = true, Elk = true }
local MYTH_NAME = {
        InkGauntlets = "Ink Gauntlets",
        DragonSpear = "Dragon Spear",
        Volt = "Volt",
        Valor = "Valor",
        Elk = "Elk",
}
local MYTH_PIECES = {
        weapon = { "Blade", "Handle", "Gem" },
        armor = { "Helmet", "Chestplate", "Leggings" },
}

local function pieceLabel(item, piece)
        if mythConf and type(mythConf.piece_name) == "function" then
                local ok, name = pcall(mythConf.piece_name, item, piece)
                if ok and type(name) == "string" and name ~= "" then
                        return name
                end
        end
        return piece
end

-- ------------------------------------------------------------ build the stats
local function buildStats()
        local placeName, isHub = nil, nil
        do
                local okP, place = pcall(function()
                        return world:get(comps.Place, comps.Place)
                end)
                local id = okP and type(place) == "table" and place.id or nil
                if id ~= nil then
                        if PlaceEnum then
                                for name, value in pairs(PlaceEnum) do
                                        if tostring(value) == tostring(id) then
                                                placeName = tostring(name)
                                                break
                                        end
                                end
                        end
                        placeName = placeName or tostring(id)
                end
                if placeKind and id ~= nil then
                        local okH, hub = pcall(placeKind.is_hub, id)
                        isHub = okH and hub == true or nil
                end
        end

        -- items ----------------------------------------------------------------
        local weapons, armor = {}, {}
        local equippedWeaponEnt = get(comps.EquippedWeapon)
        local equippedArmorEnt = get(comps.EquippedArmor)
        local mythSlotEnt = get(comps.MythicalSlot)
        if mythSlotEnt ~= nil and not pcall(world.contains, world, mythSlotEnt) then
                mythSlotEnt = nil
        end

        local function upgradeReq(ent)
                if not upgradeUtil then
                        return nil
                end
                local ok, r = pcall(upgradeUtil.get_upgrade_requirement, world, ent)
                if ok and type(r) == "table" and r.resolved then
                        return r
                end
                return nil
        end

        local function collectItem(ent, item)
                if type(item) ~= "table" or tostring(item.id) == "None" then
                        return
                end
                if owner(ent) ~= playerEnt then
                        return
                end
                local isWeapon = has(comps.Weapon, ent)
                local isArmor = has(comps.Armor, ent)
                if not isWeapon and not isArmor then
                        return
                end

                local rec = {
                        kind = isWeapon and "weapon" or "armor",
                        id = tostring(item.id),
                        tier = num(item.tier) or 1,
                        count = num(item.count) or 0,
                }

                local reqData = upgradeReq(ent)
                if reqData then
                        rec.rarity = tostring(reqData.rarity)
                        rec.maxTier = num(reqData.max_tier)
                        rec.copies = num(reqData.current_copies)
                        rec.neededCopies = num(reqData.needed_copies)
                        rec.neededCoins = num(reqData.needed_coins)
                        rec.neededObsidian = num(reqData.needed_obsidian)
                        rec.maxed = reqData.maxed == true
                        rec.canUpgrade = reqData.can_upgrade == true
                end

                if isWeapon then
                        local wComp = get(comps.Weapon, ent)
                        rec.name = tostring(type(wComp) == "table" and wComp.name or rec.id)
                        local wd = weaponData(world, ent)
                        if wd then
                                rec.damage = wd.dmg
                                rec.attackSpeed = wd.attackSpeed
                                rec.critChance = wd.crit
                                rec.score = math.floor(dps(wd, SCORE_K.REF_ENERGY, SCORE_K.REF_FILL, 1) * 100 + 0.5) / 100
                        end
                        rec.equipped = equippedWeaponEnt ~= nil and ent == equippedWeaponEnt
                        weapons[#weapons + 1] = rec
                else
                        local aComp = get(comps.Armor, ent)
                        if type(aComp) ~= "table" then
                                return
                        end
                        rec.name = tostring(aComp.name or rec.id)
                        rec.rarity = tostring(aComp.rarity or rec.rarity or "Common")
                        rec.health = num(aComp.health)
                        rec.energy = num(aComp.energy)
                        rec.walkSpeed = num(aComp.walk_speed)
                        rec.energyFillRate = num(aComp.energy_fill_rate)
                        rec.equipped = equippedArmorEnt ~= nil and ent == equippedArmorEnt
                        rec.equippedMyth = mythSlotEnt ~= nil and ent == mythSlotEnt or nil
                        local ad = armorData(world, ent)
                        if ad then
                                rec.passives = ad.passives
                                rec.score = math.floor(armorCore(ad, ad.e) * ad.da * 100 + 0.5) / 100
                        end
                        armor[#armor + 1] = rec
                end
        end

        local seen = {}
        local function handle(ent, item)
                local key = tostring(ent)
                if seen[key] then
                        return
                end
                seen[key] = true
                collectItem(ent, item)
        end
        local okQ = pcall(function()
                for ent, item in world:query(comps.Item) do
                        handle(ent, item)
                end
        end)
        if not okQ then
                pcall(function()
                        for ent in world:query(comps.Item) do
                                handle(ent, get(comps.Item, ent))
                        end
                end)
        end

        local bestWeapon, bestArmor = nil, nil
        for _, r in ipairs(weapons) do
                if (r.tier > 1 or r.count > 0) and num(r.score) and (bestWeapon == nil or r.score > bestWeapon.score) then
                        bestWeapon = r
                end
        end
        for _, r in ipairs(armor) do
                if (r.tier > 1 or r.count > 0) and num(r.score) and (bestArmor == nil or r.score > bestArmor.score) then
                        bestArmor = r
                end
        end

        -- fishing ----------------------------------------------------------------
        local fishOut = {}
        do
                local f = get(comps.Fishing)
                if type(f) == "table" then
                        fishOut.stash = jsonSafe(f.stash, 2) or {}
                        fishOut.bait = jsonSafe(f.bait, 2) or {}
                        fishOut.ownedRods = jsonSafe(f.owned_rods, 2) or {}
                        local charms = {}
                        if type(f.charms) == "table" then
                                for key, ch in pairs(f.charms) do
                                        if type(ch) == "table" then
                                                local id, rarity = ch.id, ch.rarity
                                                if (not id or not rarity) and type(key) == "string" then
                                                        id, rarity = key:match("^([^:/]+)[:/](.+)$")
                                                end
                                                if id and rarity then
                                                        charms[#charms + 1] = {
                                                                id = tostring(id),
                                                                rarity = tostring(rarity),
                                                                count = num(ch.count) or 1,
                                                        }
                                                end
                                        end
                                end
                                table.sort(charms, function(a, b)
                                        local ra, rb = rankOf(a.rarity), rankOf(b.rarity)
                                        if ra ~= rb then
                                                return ra < rb
                                        end
                                        if (a.count or 0) ~= (b.count or 0) then
                                                return (a.count or 0) > (b.count or 0)
                                        end
                                        return a.id < b.id
                                end)
                        end
                        fishOut.charms = charms
                        if stashCap then
                                local okC, cap = pcall(stashCap.capacity, f)
                                fishOut.stashCapacity = okC and num(cap) or nil
                        end
                        if fishOut.stashCapacity == nil then
                                local okF, fcfg = pcall(function()
                                        return require(src:FindFirstChild("configs") and src.configs:FindFirstChild("fishing_config"))
                                end)
                                if okF and type(fcfg) == "table" then
                                        fishOut.stashCapacity = tonumber(fcfg.stash_capacity) or 50
                                else
                                        fishOut.stashCapacity = 50
                                end
                        end
                        if potionFish and type(potionFish.held) == "function" then
                                local okH, held = pcall(potionFish.held, f)
                                fishOut.potionFishHeld = okH and num(held) or nil
                        end
                end
        end

        -- rings ------------------------------------------------------------------
        local ringsOut = {}
        do
                local r = get(comps.Rings)
                if type(r) == "table" then
                        ringsOut.stardust = num(r.stardust)
                        ringsOut.unveils = num(r.unveils)
                        ringsOut.superUnveils = num(r.super_unveils)
                        ringsOut.equippedIndex = num(r.equipped_index)
                        if ringCfg and type(ringCfg.unveil) == "table" then
                                ringsOut.unveilCost = num(ringCfg.unveil.coin_cost)
                        end
                        local ownedRings = {}
                        if type(r.owned) == "table" then
                                for i, ring in ipairs(r.owned) do
                                        if type(ring) == "table" then
                                                local id = tostring(ring.id)
                                                local name = id
                                                if ringCfg and type(ringCfg.rings) == "table" and type(ringCfg.rings[ring.id]) == "table" then
                                                        name = tostring(ringCfg.rings[ring.id].name or id)
                                                end
                                                ownedRings[#ownedRings + 1] = {
                                                        index = i,
                                                        id = id,
                                                        name = name,
                                                        rarity = tostring(ring.rarity or "Common"),
                                                        quality = num(ring.quality),
                                                        tier = num(ring.tier) or 1,
                                                }
                                        end
                                end
                                table.sort(ownedRings, function(a, b)
                                        local ra, rb = rankOf(a.rarity), rankOf(b.rarity)
                                        if ra ~= rb then
                                                return ra < rb
                                        end
                                        return (a.quality or 0) > (b.quality or 0)
                                end)
                        end
                        ringsOut.owned = ownedRings
                end
        end

        -- potions ------------------------------------------------------------------
        local potionsOut = {}
        do
                local ownedP = get(comps.OwnedPotions)
                if type(ownedP) == "table" then
                        potionsOut.owned = jsonSafe(ownedP, 2) or {}
                end
                local ids = {}
                local list = get(comps.Potions)
                if type(list) == "table" then
                        for _, entry in ipairs(list) do
                                local id = type(entry) == "table" and entry.id or entry
                                if id ~= nil then
                                        ids[#ids + 1] = tostring(id)
                                end
                        end
                end
                potionsOut.ids = ids
        end

        -- myth forge ----------------------------------------------------------------
        local mythOut = {}
        do
                local mp = get(comps.MythicalProgress)
                local pieces = type(mp) == "table" and type(mp.pieces) == "table" and mp.pieces or {}
                local relics = type(mp) == "table" and type(mp.relics) == "table" and mp.relics or {}
                local relicTotal = 0
                for _, v in pairs(relics) do
                        relicTotal = relicTotal + (tonumber(v) or 0)
                end
                mythOut.relics = jsonSafe(relics, 2) or {}
                mythOut.relicTotal = relicTotal
                local relicCharm = nil
                local f = get(comps.Fishing)
                if type(f) == "table" and type(f.charms) == "table" and type(f.charms["RelicCharm:Mythical"]) == "table" then
                        relicCharm = num(f.charms["RelicCharm:Mythical"].count)
                end
                mythOut.relicCharms = relicCharm
                if type(forgeCfg) == "table" and type(forgeCfg.cost) == "table" then
                        mythOut.forgeCost = {
                                moltenObsidian = tonumber(forgeCfg.cost.molten_obsidian) or 100,
                                stardust = tonumber(forgeCfg.cost.stardust) or 2500,
                        }
                end
                local mythForged = {}
                for _, r in ipairs(weapons) do
                        if r.rarity == "Mythical" then
                                mythForged[r.id] = r
                        end
                end
                for _, r in ipairs(armor) do
                        if r.rarity == "Mythical" then
                                mythForged[r.id] = r
                        end
                end
                local items = {}
                for _, id in ipairs(MYTH_ITEMS) do
                        local pieceList = MYTH_PIECES[MYTH_ARMOR[id] and "armor" or "weapon"]
                        local held, missing = 0, {}
                        for _, piece in ipairs(pieceList) do
                                local c = 0
                                local slot = pieces[id]
                                if type(slot) == "table" then
                                        c = tonumber(slot[piece]) or 0
                                end
                                if c > 0 then
                                        held = held + 1
                                else
                                        missing[#missing + 1] = pieceLabel(id, piece)
                                end
                        end
                        local forged = mythForged[id]
                        local rec = {
                                id = id,
                                name = MYTH_NAME[id] or id,
                                armor = MYTH_ARMOR[id] == true or nil,
                                piecesTotal = #pieceList,
                                piecesHeld = held,
                                missing = missing,
                                forged = forged ~= nil or nil,
                        }
                        if forged then
                                rec.tier = forged.tier
                                rec.maxTier = forged.maxTier
                                rec.maxed = forged.maxed == true or nil
                                rec.nextCopies = forged.neededCopies
                                rec.nextObs = forged.neededObsidian
                                rec.nextCoins = forged.neededCoins
                        end
                        items[#items + 1] = rec
                end
                mythOut.items = items
        end

        -- title --------------------------------------------------------------------
        local titleOut = nil
        do
                local t = get(comps.EquippedTitle)
                if t ~= nil and type(t) ~= "table" then
                        local id = tostring(t)
                        titleOut = { id = id, name = id }
                        if type(titleConf) == "table" and type(titleConf[id]) == "table" then
                                local conf = titleConf[id]
                                if type(conf.name) == "string" and conf.name ~= "" then
                                        titleOut.name = conf.name
                                end
                                if type(conf.color) == "table" and pcall(function()
                                        return conf.color.R + conf.color.G + conf.color.B
                                end) then
                                        titleOut.color = string.format(
                                                "%02X%02X%02X",
                                                math.floor(conf.color.R * 255 + 0.5),
                                                math.floor(conf.color.G * 255 + 0.5),
                                                math.floor(conf.color.B * 255 + 0.5)
                                        )
                                end
                        end
                end
        end

        -- daily rewards --------------------------------------------------------------
        local daily = nil
        do
                local d = rawComp(comps.DailyRewards, 3)
                if d then
                        daily = {
                                pendingPeriod = type(d.pending) == "table" and num(d.pending.period) or nil,
                                lastClaimTime = num(d.last_claim_time),
                                fast = d.fast == true or nil,
                        }
                end
        end

        -- hub config snapshot ----------------------------------------------------------
        local cfgOut = nil
        do
                local g = (type(getgenv) == "function" and getgenv()) or {}
                local cfg = g.GPBHub
                if type(cfg) == "table" then
                        local out = {}
                        for k, v in pairs(cfg) do
                                local tv = type(v)
                                if tv == "boolean" or tv == "number" or tv == "string" then
                                        out[k] = v
                                end
                        end
                        for _, key in ipairs({ "cards", "sell", "keep", "charm", "keepcharm", "melt" }) do
                                local m = cfg[key]
                                if type(m) == "table" then
                                        local mm = {}
                                        for k, v in pairs(m) do
                                                local tv = type(v)
                                                if type(k) == "string" and (tv == "boolean" or tv == "number" or tv == "string") then
                                                        mm[k] = v
                                                end
                                        end
                                        if next(mm) ~= nil then
                                                out[key] = mm
                                        end
                                end
                        end
                        if next(out) ~= nil then
                                cfgOut = out
                        end
                end
        end

        local coinsValue = scalarComp(comps.Coins)
        local obsidianValue = scalarComp(comps.MoltenObsidian)
        local wishesValue = scalarComp(comps.Wishes)
        local sessionOut = updateSession(LP.UserId, coinsValue, wishesValue)

        local stats = {
                schema = "gpbhub-stats/1",
                exportedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                game = {
                        robloxPlaceId = game.PlaceId,
                        jobId = type(game.JobId) == "string" and game.JobId or nil,
                        place = placeName,
                        isHub = isHub,
                },
                player = {
                        name = LP.Name,
                        displayName = LP.DisplayName,
                        userId = LP.UserId,
                        level = num(get(comps.PlayerLevel)),
                        class = (function()
                                local pc = get(comps.PlayerClass)
                                if type(pc) == "table" and pc.id ~= nil then
                                        return tostring(pc.id)
                                end
                                if pc ~= nil and type(pc) ~= "table" then
                                        return tostring(pc)
                                end
                                return ""
                        end)(),
                        title = titleOut,
                },
                currencies = {
                        coins = coinsValue,
                        stardust = ringsOut.stardust,
                        moltenObsidian = obsidianValue,
                },
                wishes = { total = wishesValue },
                session = sessionOut,
                gear = { bestWeapon = bestWeapon, bestArmor = bestArmor },
                items = { weapons = weapons, armor = armor },
                equipped = { charm = rawComp(comps.EquippedCharm, 3) },
                fishing = fishOut,
                rings = ringsOut,
                potions = potionsOut,
                myth = mythOut,
                misc = {
                        dailyRewards = daily,
                        worldUnlocks = rawComp(comps.WorldUnlocks, 3),
                        loot = rawComp(comps.Loot, 3),
                        gamepasses = rawComp(comps.Gamepasses, 3),
                        claimedCodes = rawComp(comps.ClaimedCodes, 3),
                        banners = rawComp(comps.Banners, 3),
                        armoryState = rawComp(comps.ArmoryState, 3),
                },
                config = cfgOut,
        }
        return stats
end

-- ------------------------------------------------------------------- output
local clipboardDone = false
local failCount = 0
local wroteLast = nil

local function pushStats(encoded)
        local url, _, token = liveCfg()
        local httpFn = nil
        pcall(function()
                httpFn = (type(request) == "function" and request) or (type(http_request) == "function" and http_request) or nil
        end)
        if type(httpFn) ~= "function" then
                return false, "no http function in this executor"
        end
        local headers = { ["Content-Type"] = "application/json" }
        if token ~= "" then
                headers["Authorization"] = "Bearer " .. token
        end

        -- Render free tier sleeps after ~15 min idle: the first request can
        -- take up to ~60s while the server wakes up. Retry a few times so a
        -- cold start (or a hiccup) never silently kills the live feed.
        local lastErr = nil
        for attempt = 1, 3 do
                if attempt > 1 then
                        task.wait(5)
                end
                local ok, res = pcall(httpFn, { Url = url, Method = "POST", Headers = headers, Body = encoded })
                if not ok then
                        lastErr = res
                elseif type(res) == "table" and valid(res.StatusCode) and (res.StatusCode < 200 or res.StatusCode > 299) then
                        if res.StatusCode == 405 then
                                lastErr = "HTTP 405 (wrong endpoint - url should end in /report)"
                        elseif res.StatusCode == 404 then
                                lastErr = "HTTP 404 (wrong endpoint - url should end in /report)"
                        else
                                lastErr = "HTTP " .. tostring(res.StatusCode)
                        end
                else
                        return true
                end
        end
        return false, lastErr
end

local worldFailCount = 0

local function sendOnce(withClipboard)
        if not ensureWorld() then
                -- don't spam notifications while the world/entity is still
                -- spawning (e.g. right after a lobby change)
                worldFailCount = worldFailCount + 1
                if worldFailCount <= 2 or worldFailCount % 12 == 0 then
                        notify("Could not find the ECS world. Join the game first, then run this again.")
                end
                return false
        end
        worldFailCount = 0
        local okB, stats = pcall(buildStats)
        if not okB or type(stats) ~= "table" then
                notify("Collecting stats failed: " .. tostring(stats))
                return false
        end
        local okE, encoded = pcall(function()
                return HttpService:JSONEncode(stats)
        end)
        if not okE or type(encoded) ~= "string" then
                notify("JSON encode failed: " .. tostring(encoded))
                return false
        end

        wroteLast = nil
        pcall(function()
                if type(isfolder) == "function" and type(writefile) == "function" then
                        if not isfolder("GPBHub") then
                                makefolder("GPBHub")
                        end
                        writefile("GPBHub/stats.json", encoded)
                        wroteLast = "GPBHub/stats.json"
                end
        end)

        local okP, why = pushStats(encoded)
        if okP then
                failCount = 0
        else
                failCount = failCount + 1
                if failCount == 1 or failCount % 12 == 0 then
                        warn("[GPBHub Export] live server not reachable (" .. tostring(why) .. ") - still saving stats.json")
                end
        end

        if withClipboard and not clipboardDone then
                pcall(function()
                        local cands = { setclipboard, toclipboard }
                        if type(getgenv) == "function" then
                                local g = getgenv()
                                if type(g) == "table" then
                                        cands[#cands + 1] = g.setclipboard
                                        cands[#cands + 1] = g.toclipboard
                                end
                        end
                        for _, fn in ipairs(cands) do
                                if type(fn) == "function" and not clipboardDone then
                                        local okC = pcall(fn, encoded)
                                        if okC then
                                                clipboardDone = true
                                                print("[GPBHub Export] JSON copied to clipboard.")
                                        end
                                end
                        end
                end)
        end

        print(
                string.format(
                        "[GPBHub Export] %s | coins %s (+%s this session, ~%s/hr) | wishes %s (+%s) | obsidian %s | weapons %d | armor %d | rings %d | charms %d | myth forged %d/%d",
                        stats.exportedAt or "?",
                        tostring(stats.currencies.coins or "?"),
                        tostring(stats.session.coinsEarned or 0),
                        tostring(stats.session.coinsPerHour or "..."),
                        tostring(stats.wishes.total or "?"),
                        tostring(stats.session.wishesEarned or 0),
                        tostring(stats.currencies.moltenObsidian or "0"),
                        #(stats.items.weapons or {}),
                        #(stats.items.armor or {}),
                        #(stats.rings.owned or {}),
                        #(stats.fishing.charms or {}),
                        #(function()
                                local n = 0
                                for _, m in ipairs(stats.myth.items or {}) do
                                        if m.forged then
                                                n = n + 1
                                        end
                                end
                                return n
                        end)(),
                        #(stats.myth.items or {})
                )
        )
        if wroteLast then
                print("[GPBHub Export] Saved to " .. wroteLast .. " (inside your executor workspace folder).")
        end
        return true, stats, encoded
end

-- ------------------------------------------------------------------- live loop
local liveOn = false

-- If an older instance of this script is still running in this executor
-- session (auto-exec + manual run, or a double load), stop its push loop
-- first so pushes never double up.
pcall(function()
        local oldStop = getgenv().GPBHubStatsStopLive
        if type(oldStop) == "function" then
                oldStop()
        end
end)
getgenv().GPBHubStatsStopLive = function()
        liveOn = false
end
getgenv().GPBHubStatsInstances = (tonumber(getgenv().GPBHubStatsInstances) or 0) + 1

getgenv().GPBHubExportStats = function()
        local ok = sendOnce(true)
        if ok then
                notify("Stats exported - paste or drop the JSON, or check the live dashboard.")
        end
end

getgenv().GPBHubStatsLive = function(on)
        if on == nil then
                on = not liveOn
        end
        if on and not liveOn then
                liveOn = true
                task.spawn(function()
                        while liveOn do
                                pcall(sendOnce, false)
                                local _, interval = liveCfg()
                                task.wait(interval)
                        end
                end)
                local url, interval = liveCfg()
                notify("Live tracking ON - pushing to " .. url .. " every " .. interval .. "s")
        elseif not on and liveOn then
                liveOn = false
                notify("Live tracking OFF")
        end
        return liveOn
end

-- --------------------------------------------------------------- auto reload
-- Lobby changes / server hops destroy this script's context. Arm
-- queue_on_teleport so the script re-runs itself automatically after every
-- teleport; tracking then resumes on its own (session totals carry over via
-- GPBHub/data/session_<userId>.json). Set getgenv().GPBHubStatsAutoReload =
-- false before running to disable, or GPBHubStatsSelfUrl to change where the
-- reload fetches the script from.
local function armAutoReload()
        local g = (type(getgenv) == "function" and getgenv()) or {}
        if g.GPBHubStatsAutoReload == false then
                return false
        end
        local selfUrl = tostring(g.GPBHubStatsSelfUrl or DEFAULT_SELF_URL)
        local chunk = string.format('task.wait(3) loadstring(game:HttpGet(%q))()', selfUrl)

        local queuers = {}
        if type(queue_on_teleport) == "function" then
                queuers[#queuers + 1] = queue_on_teleport
        end
        if type(queueonteleport) == "function" then
                queuers[#queuers + 1] = queueonteleport
        end
        if type(g.queue_on_teleport) == "function" then
                queuers[#queuers + 1] = g.queue_on_teleport
        end
        if type(g.queueonteleport) == "function" then
                queuers[#queuers + 1] = g.queueonteleport
        end
        pcall(function()
                if type(syn) == "table" and type(syn.queue_on_teleport) == "function" then
                        queuers[#queuers + 1] = syn.queue_on_teleport
                end
        end)

        for _, q in ipairs(queuers) do
                local ok = pcall(q, chunk)
                if ok then
                        return true
                end
        end
        return false
end

-- boot: one export now, then live tracking on by default
local armed = armAutoReload()
sendOnce(true)
notify("Exported (instance #" .. tostring(getgenv().GPBHubStatsInstances or 1) .. "). Live tracking on"
        .. (armed and " - auto-restart armed for lobby changes." or " - auto-restart NOT supported by this executor."))
getgenv().GPBHubStatsLive(true)
if not armed then
        warn("[GPBHub Export] queue_on_teleport not found - after a lobby change, re-run the script or enable your executor's auto-exec for this URL.")
end
