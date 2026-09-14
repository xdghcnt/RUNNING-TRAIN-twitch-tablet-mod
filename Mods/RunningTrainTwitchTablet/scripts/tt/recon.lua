--[[
    Milestone 0 -- reconnaissance. Log-only.

    Two questions this module answers in the real game:

      1. Which UE4SS game-thread mechanism actually delivers callbacks in RUNNING
         TRAIN? HeadTracking saw ExecuteInGameThread (EngineTick) stop delivering
         after two callbacks. Spawning actors, creating components and LoadAsset
         must run on the game thread, so this is the first unknown.       [Ctrl+F9]

      2. What is in the world: PlayerController, world, pawn, view target, the
         driver actor and whatever it is attached to (train/cab candidates),
         engine classes/functions we will need, and which /Engine meshes,
         materials, textures and fonts are cooked into the game.          [Ctrl+F7]

    Threading: all Lua contexts of a mod share one lua_State (see
    HEADTRACKING_REFERENCE.md). Keybind callbacks only queue work; the sweeps run
    on the game thread via EngineTick, proven in Milestone 0. The spawn test that
    lived here became the visible test object of Milestone 1 (tt/testobject.lua).
]]

local U = require("tt.util")
local GT = require("tt.gamethread")
local log, try, isValid, fullName = U.log, U.try, U.isValid, U.fullName

local M = {}

local S = { probeSeq = 0 }

--------------------------------------------------------------------------------
-- game-thread delivery
--------------------------------------------------------------------------------

function M.probeGameThread()
    S.probeSeq = S.probeSeq + 1
    local seq = S.probeSeq
    local t0 = U.nowMs()

    log("== probe #%d: game-thread delivery (queued from %s) ==", seq, U.threadTag())
    log("EngineTickAvailable=%s ProcessEventAvailable=%s EGameThreadMethod=%s",
        tostring(EngineTickAvailable), tostring(ProcessEventAvailable), tostring(EGameThreadMethod ~= nil))

    local function probe(name)
        return function()
            local gt = try(function() return IsInGameThread() end)
            log("probe #%d %-34s delivered after %5d ms, IsInGameThread=%s",
                seq, name, U.nowMs() - t0, tostring(gt))
        end
    end

    local function queue(name, method)
        local ok, err
        if method == nil then
            ok, err = pcall(ExecuteInGameThread, probe(name))
        else
            ok, err = pcall(ExecuteInGameThread, probe(name), method)
        end
        if not ok then log("probe #%d %s: could not queue: %s", seq, name, tostring(err)) end
    end

    if EGameThreadMethod ~= nil then
        if EngineTickAvailable then queue("ExecuteInGameThread(EngineTick)", EGameThreadMethod.EngineTick) end
        if ProcessEventAvailable then queue("ExecuteInGameThread(ProcessEvent)", EGameThreadMethod.ProcessEvent) end
    end
    queue("ExecuteInGameThread(default)", nil)

    local ok, err = pcall(ExecuteInGameThreadWithDelay, 250, probe("ExecuteInGameThreadWithDelay(250)"))
    if not ok then log("probe #%d ExecuteInGameThreadWithDelay: %s", seq, tostring(err)) end

    -- A loop tells us whether delivery is sustained, not just whether one
    -- callback got through (HeadTracking saw exactly that failure mode).
    local count, handle = 0, nil
    ok, handle = pcall(LoopInGameThreadWithDelay, 100, function()
        count = count + 1
        local elapsed = U.nowMs() - t0
        if elapsed >= 3000 then
            pcall(CancelDelayedAction, handle)
            log("probe #%d LoopInGameThreadWithDelay(100): %d deliveries in %d ms (expect ~30)",
                seq, count, elapsed)
        end
    end)
    if not ok then log("probe #%d LoopInGameThreadWithDelay: %s", seq, tostring(handle)) end

    log("probe #%d queued; results arrive over ~3 s", seq)
end

--------------------------------------------------------------------------------
-- world / player
--------------------------------------------------------------------------------

local function reconPlayer()
    log("-- player / world --")
    local pc = try(function() return FindFirstOf("PlayerController") end)
    if not isValid(pc) then
        log("PlayerController: none (menu or loading?)")
        return nil
    end
    log("PlayerController: %s", fullName(pc))

    local world = try(function() return pc:GetWorld() end)
    log("World: %s", fullName(world))
    if isValid(world) then
        log("  PersistentLevel  : %s", fullName(try(function() return world.PersistentLevel end)))
        log("  AuthorityGameMode: %s", fullName(try(function() return world.AuthorityGameMode end)))
        log("  GameState        : %s", fullName(try(function() return world.GameState end)))
    end

    local pawn = try(function() return pc.Pawn end)
    log("Pawn: %s", fullName(pawn))
    if isValid(pawn) then
        log("  location %s", U.vecStr(try(function() return pawn:K2_GetActorLocation() end)))
    end

    local pcm = try(function() return pc.PlayerCameraManager end)
    log("PlayerCameraManager: %s", fullName(pcm))
    if isValid(pcm) then
        log("  camera %s %s", U.vecStr(try(function() return pcm:GetCameraLocation() end)),
            U.rotStr(try(function() return pcm:GetCameraRotation() end)))
        log("  ViewTarget.Target: %s", fullName(try(function() return pcm.ViewTarget.Target end)))
    end
    return pc
end

--------------------------------------------------------------------------------
-- actors: attachment, components, blueprint properties
--------------------------------------------------------------------------------

local function valueToString(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local s = try(function() return v:ToString() end)
        if type(s) == "string" then return string.format("%q", s) end
        if isValid(v) then
            local n = try(function() return v:GetFullName() end)
            if type(n) == "string" then return n end
        end
    end
    return "<" .. t .. ">"
end

local function describeAttachment(actor, indent)
    local root = try(function() return actor.RootComponent end)
    log("%sRootComponent: %s", indent, fullName(root))
    local c, depth = root, 0
    while isValid(c) and depth < 12 do
        local parent = try(function() return c.AttachParent end)
        if not isValid(parent) then break end
        log("%s  -> attached to %s (owner %s)", indent, fullName(parent),
            fullName(try(function() return parent:GetOwner() end)))
        c, depth = parent, depth + 1
    end
    log("%sGetAttachParentActor: %s", indent, fullName(try(function() return actor:GetAttachParentActor() end)))
    log("%sOwner: %s", indent, fullName(try(function() return actor.Owner end)))
end

local function describeComponents(actor, indent)
    local sceneClass = try(function() return StaticFindObject("/Script/Engine.SceneComponent") end)
    if not isValid(sceneClass) then return end
    local arr = try(function() return actor:K2_GetComponentsByClass(sceneClass) end)
    if arr == nil then
        log("%scomponents: K2_GetComponentsByClass failed", indent)
        return
    end

    local function one(c)
        if not isValid(c) then return end
        local parent = try(function() return c.AttachParent end)
        log("%s  %-28s %-40s parent=%s rel=%s", indent, U.className(c),
            try(function() return c:GetFName():ToString() end) or "?",
            isValid(parent) and (try(function() return parent:GetFName():ToString() end) or "?") or "-",
            U.vecStr(try(function() return c.RelativeLocation end)))
    end

    log("%scomponents:", indent)
    if type(arr) == "table" then
        for _, c in ipairs(arr) do one(c) end
    else
        try(function() arr:ForEach(function(_, elem) one(elem:get()) end) end)
    end
end

local SIMPLE_PROPS = {
    ObjectProperty = true, WeakObjectProperty = true, SoftObjectProperty = true, ClassProperty = true,
    NameProperty = true, StrProperty = true, TextProperty = true,
    IntProperty = true, Int64Property = true, FloatProperty = true, DoubleProperty = true,
    BoolProperty = true, ByteProperty = true, EnumProperty = true,
}

--- Blueprint-declared properties only: these are where a train/cab reference or
--- a train identifier would live. Native parents are skipped.
local function describeBlueprintProperties(obj, indent)
    local cls = try(function() return obj:GetClass() end)
    local depth = 0
    while isValid(cls) and depth < 8 do
        local cname = fullName(cls)
        if not cname:find("/Game/", 1, true) then break end
        log("%sproperties of %s", indent, cname)
        try(function()
            cls:ForEachProperty(function(p)
                local pname = try(function() return p:GetFName():ToString() end) or "?"
                local ptype = try(function() return p:GetClass():GetFName():ToString() end) or "?"
                local line = ptype .. " " .. pname
                if SIMPLE_PROPS[ptype] then
                    line = line .. " = " .. valueToString(try(function() return obj[pname] end))
                end
                log("%s  %s", indent, line)
            end)
        end)
        cls = try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
end

local function describeActor(actor, detailed)
    log("  %s", fullName(actor))
    log("    location %s rotation %s", U.vecStr(try(function() return actor:K2_GetActorLocation() end)),
        U.rotStr(try(function() return actor:K2_GetActorRotation() end)))
    describeAttachment(actor, "    ")
    if detailed then
        describeComponents(actor, "    ")
        describeBlueprintProperties(actor, "    ")
    end
end

local TRAINISH = { "train", "car", "unten", "cab", "vehicle", "consist", "formation",
                   "bogie", "rail", "seat", "driver", "mascon", "body", "tetsu", "sharyo" }

local function isTrainish(name)
    local l = name:lower()
    for _, w in ipairs(TRAINISH) do
        if l:find(w, 1, true) then return true end
    end
    return false
end

local function reconActors()
    log("-- actors --")
    local all = try(function() return FindAllOf("Actor") end)
    if all == nil then
        log("no actors")
        return
    end

    local counts, examples = {}, {}
    for _, a in ipairs(all) do
        local cn = U.className(a)
        counts[cn] = (counts[cn] or 0) + 1
        examples[cn] = examples[cn] or {}
        if #examples[cn] < 3 then table.insert(examples[cn], a) end
    end

    local names = {}
    for cn in pairs(counts) do table.insert(names, cn) end
    table.sort(names)
    log("%d actors, %d classes. Game (PyBP_*) and train-like classes:", #all, #names)
    for _, cn in ipairs(names) do
        if cn:find("^PyBP_") or isTrainish(cn) then
            log("  %4d x %s", counts[cn], cn)
        end
    end

    log("-- driver actor (camera owner) in detail --")
    for _, a in ipairs(examples["PyBP_Base_Unten_Actor_C"] or {}) do
        describeActor(a, true)
    end

    log("-- other train-like actors --")
    for _, cn in ipairs(names) do
        if cn ~= "PyBP_Base_Unten_Actor_C" and isTrainish(cn) then
            for _, a in ipairs(examples[cn]) do describeActor(a, false) end
        end
    end
end

--------------------------------------------------------------------------------
-- classes, functions, assets
--------------------------------------------------------------------------------

local CLASSES = {
    "/Script/Engine.Actor",
    "/Script/Engine.StaticMeshActor",
    "/Script/Engine.SceneComponent",
    "/Script/Engine.StaticMeshComponent",
    "/Script/Engine.TextRenderComponent",
    "/Script/UMG.WidgetComponent",
    "/Script/Engine.MaterialInstanceDynamic",
    "/Script/Engine.Texture2D",
    "/Script/Engine.Texture2DDynamic",
    "/Script/Engine.TextureRenderTarget2D",
    "/Script/Engine.CanvasRenderTarget2D",
    "/Script/Engine.Canvas",
    "/Script/Engine.KismetRenderingLibrary",
    "/Script/Engine.KismetMaterialLibrary",
    "/Script/Engine.GameplayStatics",
}

-- Signatures are logged, not assumed: HeadTracking learned that the hard way.
local FUNCTIONS = {
    "/Script/Engine.Actor:AddComponentByClass",
    "/Script/Engine.Actor:K2_DestroyActor",
    "/Script/Engine.Actor:K2_AttachToComponent",
    "/Script/Engine.SceneComponent:K2_AttachToComponent",
    "/Script/Engine.SceneComponent:K2_SetRelativeTransform",
    "/Script/Engine.StaticMeshComponent:SetStaticMesh",
    "/Script/Engine.PrimitiveComponent:SetMaterial",
    "/Script/Engine.PrimitiveComponent:CreateDynamicMaterialInstance",
    "/Script/Engine.MaterialInstanceDynamic:SetTextureParameterValue",
    "/Script/Engine.KismetRenderingLibrary:CreateRenderTarget2D",
    "/Script/Engine.KismetRenderingLibrary:BeginDrawCanvasToRenderTarget",
    "/Script/Engine.KismetRenderingLibrary:ImportBufferAsTexture2D",
    "/Script/Engine.Canvas:K2_DrawText",
    "/Script/Engine.Canvas:K2_DrawTexture",
    "/Script/Engine.PlayerController:IsInputKeyDown",
}

local ASSETS = {
    "/Engine/BasicShapes/Cube.Cube",
    "/Engine/BasicShapes/Plane.Plane",
    "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial",
    "/Engine/EngineMeshes/Cube.Cube",
    "/Engine/EngineMaterials/DefaultMaterial.DefaultMaterial",
    "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial",
    "/Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough",
    "/Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque",
    "/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque",
    "/Engine/EngineResources/DefaultTexture.DefaultTexture",
    "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture",
    "/Engine/EngineFonts/Roboto.Roboto",
    "/Engine/EngineFonts/RobotoDistanceField.RobotoDistanceField",
}

local function reconClassesAndFunctions()
    log("-- classes --")
    for _, path in ipairs(CLASSES) do
        local o = try(function() return StaticFindObject(path) end)
        log("  %-55s %s", path, isValid(o) and "present" or "MISSING")
    end

    log("-- function signatures --")
    for _, path in ipairs(FUNCTIONS) do
        local fn = try(function() return StaticFindObject(path) end)
        if not isValid(fn) then
            log("  %s MISSING", path)
        else
            local parts = {}
            try(function()
                fn:ForEachProperty(function(p)
                    local ptype = try(function() return p:GetClass():GetFName():ToString() end) or "?"
                    local pname = try(function() return p:GetFName():ToString() end) or "?"
                    table.insert(parts, ptype .. " " .. pname)
                end)
            end)
            log("  %s(%s)", path, table.concat(parts, ", "))
        end
    end
end

local function reconAssets(allowLoad)
    log("-- engine assets (allowLoad=%s) --", tostring(allowLoad))
    for _, path in ipairs(ASSETS) do
        local o = try(function() return StaticFindObject(path) end)
        if isValid(o) then
            log("  %-80s in memory (%s)", path, U.className(o))
        elseif allowLoad then
            local ok, obj, found, loaded = pcall(LoadAsset, path)
            if not ok then
                log("  %-80s LoadAsset error: %s", path, tostring(obj))
            else
                log("  %-80s LoadAsset found=%s loaded=%s -> %s", path, tostring(found), tostring(loaded),
                    isValid(obj) and U.className(obj) or "<invalid>")
            end
        else
            log("  %-80s not in memory", path)
        end
    end
end

local function listObjects(className, filter, limit)
    local all = try(function() return FindAllOf(className) end)
    if all == nil then
        log("  %s: none", className)
        return
    end
    local matched, shown = 0, 0
    for _, o in ipairs(all) do
        local name = fullName(o)
        if filter == nil or name:find(filter, 1, true) then
            matched = matched + 1
            if shown < limit then
                log("    %s", name)
                shown = shown + 1
            end
        end
    end
    log("  %s: %d in memory, %d match %q, %d shown", className, #all, matched, filter or "*", shown)
end

local function reconLoadedEngineContent()
    log("-- /Engine content already in memory --")
    listObjects("StaticMesh", "/Engine/", 40)
    listObjects("MaterialInterface", "/Engine/", 60)
    listObjects("Texture2D", "/Engine/", 40)
    listObjects("Font", nil, 30)
end

--------------------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------------------

function M.run()
    GT.run("recon", function()
        log("== recon (%s) ==", U.threadTag())
        reconPlayer()
        reconClassesAndFunctions()
        reconAssets(true)
        reconLoadedEngineContent()
        reconActors()
        log("== recon end ==")
    end)
end

return M
