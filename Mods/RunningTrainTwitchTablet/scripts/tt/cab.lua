--[[
    Milestone 2 -- the cab coordinate system.

    Found in Milestone 0 (RESEARCH.md):

        PlayerController.Pawn = PyBP_Base_Unten_Actor_C      (driver / camera actor)
          .BaseTrain          = Cpy_KuHa115_C                (the car the player drives)
          RootComponent.AttachParent = Cpy_KuHa115_C.Base_CHASIS

        Cpy_KuHa115_C
          Base_CHASIS  StaticMeshComponent   (root)
            BaseTrain  StaticMeshComponent
              BaseUntendai StaticMeshComponent   (運転台, driver's desk)

    Candidate anchors are read as the car's Blueprint component properties, so
    nothing is searched by name across the world. Everything is resolved fresh on
    each use: the car is recreated on every route load.

    Must be called on the game thread.
]]

local U = require("tt.util")
local log, try, isValid, fullName = U.log, U.try, U.isValid, U.fullName

local M = {}

-- Most specific first: the desk is where the tablet will eventually sit.
M.ANCHORS = { "BaseUntendai", "BaseTrain", "Base_CHASIS", "pawn attach parent" }

local sceneComponentClass

local function isSceneComponent(o)
    if not isValid(o) then return false end
    sceneComponentClass = sceneComponentClass or try(function() return StaticFindObject("/Script/Engine.SceneComponent") end)
    return try(function() return o:IsA(sceneComponentClass) end) == true
end

--- Returns { pc, pawn, car, how } or nil, reason. The reason names the pawn class,
--- so a train that is not supported yet shows up in the log with what it is.
function M.resolve()
    local pc = try(function() return FindFirstOf("PlayerController") end)
    if not isValid(pc) then return nil, "no PlayerController" end
    local pawn = try(function() return pc.Pawn end)
    if not isValid(pawn) then return nil, "no pawn" end

    local car, how = try(function() return pawn.BaseTrain end), "pawn.BaseTrain"
    if not isValid(car) then
        car, how = try(function() return pawn:GetAttachParentActor() end), "pawn:GetAttachParentActor()"
    end
    if not isValid(car) then
        return nil, string.format("pawn %s is not in a train", U.className(pawn))
    end
    return { pc = pc, pawn = pawn, car = car, how = how }
end

--- Anchor component by candidate name, or nil.
function M.anchor(cab, name)
    if name == "pawn attach parent" then
        local parent = try(function() return cab.pawn.RootComponent.AttachParent end)
        return isSceneComponent(parent) and parent or nil
    end
    local c = try(function() return cab.car[name] end)
    return isSceneComponent(c) and c or nil
end

--------------------------------------------------------------------------------
-- diagnostics
--------------------------------------------------------------------------------

local function children(comp)
    local out = {}
    local arr = try(function() return comp.AttachChildren end)
    if arr == nil then return out, "no AttachChildren" end
    local ok = pcall(function()
        arr:ForEach(function(_, elem) table.insert(out, elem:get()) end)
    end)
    if ok then return out, "ForEach" end
    local n = try(function() return #arr end) or 0
    for i = 1, n do
        local c = try(function() return arr[i] end)
        if isValid(c) then table.insert(out, c) end
    end
    return out, "index"
end

local function shortName(o)
    return try(function() return o:GetFName():ToString() end) or "?"
end

local function dumpTree(comp, depth, budget)
    if budget.left <= 0 or not isValid(comp) then return end
    budget.left = budget.left - 1
    local mesh = try(function() return comp.StaticMesh end)
    log("%s%-24s %-28s rel %s %s%s", string.rep("  ", depth + 2), shortName(comp), U.className(comp),
        U.vecStr(try(function() return comp.RelativeLocation end)),
        U.rotStr(try(function() return comp.RelativeRotation end)),
        isValid(mesh) and ("  mesh " .. shortName(mesh)) or "")
    local kids, how = children(comp)
    if depth == 0 then budget.how = how end
    for _, k in ipairs(kids) do dumpTree(k, depth + 1, budget) end
end

--- Component tree of the car plus where the pawn hangs. Cheap, no world sweep.
function M.dump()
    local cab, why = M.resolve()
    if not cab then log("cab: %s", why); return end

    log("== cab ==")
    log("pawn %s", fullName(cab.pawn))
    log("car  %s (via %s)", fullName(cab.car), cab.how)
    log("  location %s rotation %s", U.vecStr(try(function() return cab.car:K2_GetActorLocation() end)),
        U.rotStr(try(function() return cab.car:K2_GetActorRotation() end)))
    for _, name in ipairs(M.ANCHORS) do
        local a = M.anchor(cab, name)
        log("  anchor %-20s %s", name, isValid(a) and fullName(a) or "MISSING")
    end

    log("component tree (AttachChildren):")
    local budget = { left = 200 }
    dumpTree(try(function() return cab.car.RootComponent end), 0, budget)
    log("  (%s, %d nodes left of 200)", budget.how or "?", budget.left)
end

--- Samples the anchors' relative transforms for a while. If the game animates
--- body sway on BaseTrain / BaseUntendai relative to the chassis, it shows up here.
function M.sampleAnchors(durationMs, periodMs)
    local cab, why = M.resolve()
    if not cab then log("cab sample: %s", why); return end

    local stats, t0, handle = {}, U.nowMs(), nil
    for _, name in ipairs(M.ANCHORS) do
        local a = M.anchor(cab, name)
        if a then stats[name] = { comp = a, n = 0, maxLoc = 0, maxRot = 0 } end
    end
    local chassis = stats["Base_CHASIS"] and stats["Base_CHASIS"].comp
    local pitchMin, pitchMax, rollMin, rollMax = 1e9, -1e9, 1e9, -1e9

    log("cab sample: %d ms every %d ms, car %s", durationMs, periodMs, fullName(cab.car))
    handle = LoopInGameThreadWithDelay(periodMs, function()
        local ok, err = pcall(function()
            for name, st in pairs(stats) do
                local loc = U.vec(try(function() return st.comp.RelativeLocation end))
                local rot = U.rot(try(function() return st.comp.RelativeRotation end))
                if loc and rot then
                    if not st.loc then
                        st.loc, st.rot = loc, rot
                    else
                        st.maxLoc = math.max(st.maxLoc, math.abs(loc.X - st.loc.X), math.abs(loc.Y - st.loc.Y), math.abs(loc.Z - st.loc.Z))
                        st.maxRot = math.max(st.maxRot, math.abs(rot.Pitch - st.rot.Pitch), math.abs(rot.Yaw - st.rot.Yaw), math.abs(rot.Roll - st.rot.Roll))
                    end
                    st.n = st.n + 1
                end
            end
            if chassis then
                local wr = U.rot(try(function() return chassis:K2_GetComponentRotation() end))
                if wr then
                    pitchMin, pitchMax = math.min(pitchMin, wr.Pitch), math.max(pitchMax, wr.Pitch)
                    rollMin, rollMax = math.min(rollMin, wr.Roll), math.max(rollMax, wr.Roll)
                end
            end
        end)
        if not ok then log("cab sample error: %s", tostring(err)) end

        if not ok or U.nowMs() - t0 >= durationMs then
            pcall(CancelDelayedAction, handle)
            for _, name in ipairs(M.ANCHORS) do
                local st = stats[name]
                if st then
                    log("cab sample: %-20s %3d samples, relative drift max %.3f cm / %.3f deg, rel %s %s",
                        name, st.n, st.maxLoc, st.maxRot, U.vecStr(st.loc), U.rotStr(st.rot))
                end
            end
            if pitchMax >= pitchMin then
                log("cab sample: chassis world pitch %.2f..%.2f, roll %.2f..%.2f", pitchMin, pitchMax, rollMin, rollMax)
            end
        end
    end)
end

return M
