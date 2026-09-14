--[[
    The tablet actor.

    Milestone 4 -- minimal geometry (PASS).
    Milestone 5 -- the screen material shows our texture (tt/screen.lua, PASS).
    Milestone 6 -- a runtime texture redrawn in place (tt/dyntexture.lua, PASS).
    Milestone 7 -- the fake chat on that texture (tt/chatmodel.lua, tt/chatrender.lua).

        Actor
          TabletRoot  SceneComponent          attached to the cab (BaseUntendai, M2)
            Body      StaticMeshComponent     engine cube, thin slab
            Screen    StaticMeshComponent     engine plane, just in front of the body

    Tablet local axes (TabletRoot space):
        +X  out of the screen, toward the viewer
        +Y  width (right, as seen by the viewer)
        +Z  height (up)

    Size: a 10" class tablet -- 24 x 16 x 0.8 cm body, 22.4 x 14.4 cm screen.

    Ctrl+F8 spawns it ~60 cm in front of the camera, facing the camera, attached to
    the cab with KeepWorld rules; again removes it. The screen shows the chat and
    is redrawn only when the chat changed. The M5/M6 test modes stay available
    through M.nextMode() (not bound to a key). Proper placement comes with the
    transform config (M10) and calibration (M11).
]]

local U = require("tt.util")
local GT = require("tt.gamethread")
local Cab = require("tt.cab")
local Screen = require("tt.screen")
local Dyn = require("tt.dyntexture")
local Emotes = require("tt.emotes")
local makeEmoteAtlas   -- defined below, before spawn
local Perf = require("tt.perf")
local ChatModel = require("tt.chatmodel")
local ChatRender = require("tt.chatrender")
local FakeChat = require("tt.fakechat")
local Config = require("tt.config")
local TrainId = require("tt.trainid")
local log, try, isValid, fullName = U.log, U.try, U.isValid, U.fullName

local M = {}

-- Preferred anchor is the cab interior (M2). Other trains may name their
-- components differently; the rest are fallbacks so the tablet still appears
-- (proper per-train handling: M12/M15). The anchor used is logged.
local ANCHORS = { "BaseUntendai", "BaseTrain", "Base_CHASIS", "pawn attach parent" }
local SPAWN_DISTANCE_CM = 30      -- was 60; the user asked for twice as close

-- Body size is adjustable at runtime (keys 1-4); the screen follows with a fixed bezel.
local BODY_DEPTH = 0.8
local BEZEL = 0.8                 -- cm on each side between body edge and screen
local SCREEN_GAP = 0.05           -- screen in front of the body face, against z-fighting
local SIZE_STEP_CM = 1.0
local SIZE_MIN_CM, SIZE_MAX_CM = 6.0, 60.0

local MESH_CUBE = "/Engine/BasicShapes/Cube.Cube"      -- 100 uu, centred
local MESH_PLANE = "/Engine/BasicShapes/Plane.Plane"   -- 100 x 100 uu in XY, normal +Z, one-sided
local MATERIAL_BASIC = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"

-- Yaw 90 / Roll -90 got the axes right but showed the M6 test pattern upside
-- down; this is the same axes turned 180 degrees about the screen normal.
local SCREEN_ROTATION = { Pitch = 0, Yaw = -90, Roll = 90 }

-- Slightly lifted from near-black so the body and the black-ish screen stay distinguishable.
local BODY_COLOR = { R = 0.06, G = 0.06, B = 0.065, A = 1 }
local SCREEN_FALLBACK_COLOR = { R = 0.05, G = 0.25, B = 0.8, A = 1 }   -- only if the screen material fails

-- The render target follows the screen's aspect at a fixed pixel density, so
-- text keeps its physical size and is not stretched. 53.3 px/cm is what M6-M7
-- had vertically (768 px on 14.4 cm); the old fixed 1024x768 on a 22.4 x 14.4 cm
-- screen stretched everything 17 % horizontally.
-- M16: now [Screen] PixelsPerCm (default the same 53.3).
local function pxPerCm()
    return math.max(10, math.min(150, Config.values.screen.pixelspercm))
end
local RT_MAX = 2048
-- Checked 5 times per second, redrawn only when needed.
local DYN_PERIOD_MS = 200

local MODES = {
    { name = "chat", dynamic = "chat" },
    { name = "dynamic test pattern", dynamic = "pattern" },
    { name = "static checker", texture = 1 },
    { name = "static default texture", texture = 2 },
}

local EComponentMobility_Movable = 2
local ECollisionEnabled_NoCollision = 0
local EAttachmentRule_KeepRelative = 0
local EAttachmentRule_KeepWorld = 1

local AUTOSPAWN_PERIOD_MS = 1000
local AUTOSPAWN_RETRY_AFTER_FAIL_MS = 10000

local S = { actor = nil, parts = nil, mode = 1, surface = nil, loop = nil, frame = 0, drawnVersion = nil,
            size = { width = 16.0, height = 12.0 },     -- overwritten from the config at spawn
            hidden = false,                              -- hidden by key: no auto-spawn until shown again
            screenOff = false,                           -- M16: screen dark, tablet stays
            overlay = nil,                               -- calibration status line on the screen (M11)
            pausedUntil = 0, nextAutoTry = 0, autoFailLogged = false }

local function screenSize()
    return S.size.width - 2 * BEZEL, S.size.height - 2 * BEZEL
end

local function renderTargetSize()
    local w, h = screenSize()
    local ppc = pxPerCm()
    return math.min(RT_MAX, math.floor(w * ppc + 0.5)), math.min(RT_MAX, math.floor(h * ppc + 0.5))
end

local function bodyScale()
    return { X = BODY_DEPTH / 100, Y = S.size.width / 100, Z = S.size.height / 100 }
end

-- The plane's X runs along the screen width, Y along its height (see SCREEN_ROTATION).
local function screenScale()
    local w, h = screenSize()
    return { X = w / 100, Y = h / 100, Z = 1 }
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function quatFromRotator(r)
    local p = math.rad(r.Pitch) * 0.5
    local y = math.rad(r.Yaw) * 0.5
    local o = math.rad(r.Roll) * 0.5
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(o), math.cos(o)
    -- FRotator::Quaternion() in UE
    return {
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

local function transform(loc, rot, scale)
    return {
        Translation = loc,
        Rotation = quatFromRotator(rot),
        Scale3D = scale,
    }
end

local function asset(path)
    local o = try(function() return StaticFindObject(path) end)
    if isValid(o) then return o end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and isValid(loaded) then return loaded end
    return nil
end

local function addMesh(actor, label, mesh, relTransform)
    local comp = actor:AddComponentByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"), false, relTransform, false)
    if not isValid(comp) then error("AddComponentByClass failed for " .. label) end
    try(function() comp:SetMobility(EComponentMobility_Movable) end)
    local meshOk = try(function() return comp:SetStaticMesh(mesh) end)
    try(function() comp:SetCollisionEnabled(ECollisionEnabled_NoCollision) end)
    return comp, meshOk
end

--- Independent material per part: a dynamic instance of the engine's basic shape
--- material with its own colour.
local function colorize(comp, label, base, color)
    local mid = try(function() return comp:CreateDynamicMaterialInstance(0, base, FName("None")) end)
    if not isValid(mid) then
        log("tablet: %s material instance FAILED", label)
        return nil
    end
    local ok, err = pcall(function() mid:SetVectorParameterValue(FName("Color"), color) end)
    log("tablet: %s material %s, SetVectorParameterValue(Color) ok=%s %s", label, fullName(mid), tostring(ok), err or "")
    return mid
end

--------------------------------------------------------------------------------
-- screen modes
--------------------------------------------------------------------------------

local function stopDynamic()
    if S.loop ~= nil then
        pcall(CancelDelayedAction, S.loop)
        S.loop = nil
    end
end

--- The M6 test pattern. Corner labels and a red top-left square make any flip or
--- mirror of the image obvious; the counter and the moving bar show it is live;
--- the second line checks Cyrillic and Japanese glyph coverage of the font.
local function paintTestPattern(d)
    local W, H = d.surface.width, d.surface.height
    local white = { R = 1, G = 1, B = 1, A = 1 }
    d:rect(0, 0, 90, 90, { R = 0.9, G = 0.1, B = 0.1, A = 1 })
    d:text(110, 20, "TOP LEFT", 2, white)
    d:text(W - 330, H - 70, "BOTTOM RIGHT", 2, white)
    d:text(W / 2 - 250, H / 2 - 110, string.format("FRAME %03d", S.frame % 1000), 5, { R = 1, G = 0.85, B = 0.2, A = 1 })
    d:text(W / 2 - 250, H / 2 + 40, "\u{41F}\u{440}\u{438}\u{432}\u{435}\u{442}, \u{447}\u{430}\u{442}! \u{3072}\u{3089}\u{304C}\u{306A}", 2,
           { R = 0.6, G = 0.9, B = 1, A = 1 })
    local x = (S.frame * 12) % (W - 120)
    d:rect(x, H - 150, 120, 30, { R = 0.2, G = 0.8, B = 0.3, A = 1 })
end

--- Height of the calibration band (0 without one), so other text can avoid it.
local function overlayText()
    return S.overlay or S.hint
end

local function overlayHeight(d)
    if not overlayText() then return 0 end
    return d:textSize("Ag", ChatRender.STYLE.scale).Y + 2 * 12 + 6
end

--- Calibration status band. The screen is emissive: a bright yellow band
--- bloomed over its own black text (M11 screenshot). Dark band, text at the chat
--- size in a name-like yellow -- the same contrast the chat itself reads with --
--- plus a thin yellow rule so the mode is visible at a glance.
local function paintOverlay(d)
    local text = overlayText()
    if not text then return end
    local style = ChatRender.STYLE
    local h = overlayHeight(d)
    d:rect(0, 0, d.surface.width, h - 6, { R = 0.02, G = 0.02, B = 0.02, A = 1 })
    d:rect(0, h - 6, d.surface.width, 4, { R = 0.9, G = 0.7, B = 0.05, A = 1 })
    d:text(style.padding, 12, text, style.scale, { R = 0.95, G = 0.8, B = 0.2, A = 1 })
end

local function paintChat(d)
    local messages = ChatModel.messages()
    if #messages == 0 then
        -- An empty black screen looks broken; say what it is waiting for.
        local ch = Config.values.twitch.channel
        local wait = (ch == nil or ch == "") and ("Set Channel in " .. Config.FILE_NAME)
                     or not Config.values.twitch.enabled and "Twitch is off (Enabled = false)"
                     or ("waiting for chat #" .. ch)
        d:text(ChatRender.STYLE.padding, ChatRender.STYLE.padding + overlayHeight(d),
               wait, ChatRender.STYLE.scale * 0.8,
               { R = 0.35, G = 0.35, B = 0.4, A = 1 })
        paintOverlay(d)
        return
    end
    ChatRender.paint(d, messages, d.surface.width, d.surface.height, 0)
    paintOverlay(d)
end

--- force: redraw even if nothing changed (first draw after the mode is set).
local function redrawDynamic(force)
    if not (S.parts and S.surface) then return end
    local kind = MODES[S.mode].dynamic
    local painter, background
    if kind == "chat" then
        -- Nothing changed, nothing to draw: the render target keeps its pixels.
        -- Redrawn when the chat changed or an emote image became ready.
        local key = ChatModel.version() .. ":" .. Emotes.version()
        if not force and S.drawnVersion == key then return end
        S.drawnVersion = key
        if S.screenOff then
            -- Dark screen; the calibration band still shows so calibrating works.
            painter, background = paintOverlay, { R = 0, G = 0, B = 0, A = 1 }
        else
            painter, background = paintChat, ChatRender.STYLE.background
        end
    else
        painter, background = paintTestPattern, { R = 0.02, G = 0.02, B = 0.05, A = 1 }
    end
    S.frame = S.frame + 1
    local t0 = Perf.clock()
    local ok, err = pcall(Dyn.redraw, S.surface, background, painter)
    Perf.recordUpdate(Perf.clock() - t0)
    if not ok then
        log("tablet: dynamic redraw FAILED at frame %d: %s -- stopping updates", S.frame, tostring(err))
        stopDynamic()
    end
end

--- Applies S.mode to the current tablet. Game thread only.
local function applyMode()
    local mode = MODES[S.mode]
    stopDynamic()
    if not (S.parts and S.parts.screenMaterial) then return end
    log("tablet: screen mode -> %s", mode.name)

    if mode.texture then
        Screen.showTexture(S.parts.screenMaterial, mode.texture)
        -- The material parameter was the only UPROPERTY reference to the render
        -- target. Once it is replaced, Unreal's GC may free the target at any
        -- time while our Lua pointer still looks fine -- M6 crashed exactly so
        -- (RESEARCH.md). Forget it now; a fresh one is made on the way back.
        S.surface = nil
        return
    end

    -- Created when entering dynamic mode, then redrawn in place on every update.
    -- It stays alive because the screen material references it.
    if not S.surface then
        local w, h = renderTargetSize()
        S.surface = Dyn.create(S.parts.world, w, h)
        if not S.surface then return end
    end
    Screen.setTexture(S.parts.screenMaterial, S.surface.rt, "render target")
    redrawDynamic(true)
    local handle
    handle = LoopInGameThreadWithDelay(DYN_PERIOD_MS, function()
        if S.loop ~= handle then return end
        local eok, eerr = pcall(Emotes.tick, Dyn); if not eok then log("emotes: tick failed: %s", tostring(eerr)) end
        redrawDynamic()
    end)
    S.loop = handle
    log("tablet: dynamic updates every %d ms", DYN_PERIOD_MS)
end

--------------------------------------------------------------------------------
-- spawn / remove
--------------------------------------------------------------------------------

--- Emote atlas (tt/emotes.lua): a render target set on the material of a
--- hidden plane inside the body, so the tablet's own components keep it alive
--- for Unreal's GC -- the same way the screen keeps its render target.
makeEmoteAtlas = function(actor, plane, world)
    if not (Config.values.screen.emotes and RTTT_EmoteRequest ~= nil) then return end
    local ok, err = pcall(function()
        local holder = addMesh(actor, "EmoteAtlas", plane, transform({ X = 0, Y = 0, Z = 0 },
            { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 0.01, Y = 0.01, Z = 1 }))
        try(function() holder:SetHiddenInGame(true, false) end)
        try(function() holder:SetVisibility(false, false) end)
        local mid = Screen.createMaterial(holder)
        if not mid then error("no material for the atlas holder") end
        local surface = Dyn.create(world, Emotes.ATLAS, Emotes.ATLAS)
        if not surface then error("atlas render target failed") end
        Screen.setTexture(mid, surface.rt, "emote atlas")
        S.parts.atlasHolder, S.parts.atlasMaterial = holder, mid
        Emotes.attach(surface, ChatRender.STYLE.background)
    end)
    if not ok then log("tablet: emote atlas FAILED (emotes stay text): %s", tostring(err)) end
end

--- placement: "config" (the [Tablet] transform relative to the anchor) or
--- "camera" (in front of the current view, facing it). Returns true on success.
local function spawn(placement)
    local cab, why = Cab.resolve()
    if not cab then log("tablet: %s", why); return false end
    -- M13/M14: the train's own profile. A train without a position in the
    -- config gets the tablet in front of the eyes plus an on-screen hint;
    -- calibrating and saving creates its profile.
    local trainClass = U.className(cab.car)
    local cfg, profile, hasPosition = Config.tabletFor(trainClass)
    S.profile, S.trainClass = profile, trainClass
    if placement == "config" and not hasPosition then
        placement = "camera"
        S.hint = string.format("NEW TRAIN: %s calibrate, %s save", Config.keyLabel("calibrate"), Config.keyLabel("calsave"))
        log("tablet: no saved position for %s -- placing it in front of the view; " .. Config.keyLabel("calibrate")
            .. " to calibrate, " .. Config.keyLabel("calsave") .. " to save",
            trainClass)
    elseif placement == "config" then
        S.hint = nil
    end
    S.size.width, S.size.height = cfg.width, cfg.height
    ChatRender.STYLE.scale = cfg.fontscale
    S.drawnVersion = nil
    local anchor, anchorName
    for _, name in ipairs(ANCHORS) do
        anchor = Cab.anchor(cab, name)
        if anchor then anchorName = name; break end
    end
    if not anchor then
        log("tablet: car %s (%s, via %s) has none of the anchors %s", fullName(cab.car), U.className(cab.car),
            cab.how, table.concat(ANCHORS, ", "))
        pcall(TrainId.report, nil)
        return false
    end
    if anchorName ~= ANCHORS[1] then
        log("tablet: car %s has no %s, using fallback anchor %s", U.className(cab.car), ANCHORS[1], anchorName)
    end

    local world = cab.pc:GetWorld()
    local pcm = cab.pc.PlayerCameraManager
    local camLoc = U.vec(try(function() return pcm:GetCameraLocation() end))
    local camRot = U.rot(try(function() return pcm:GetCameraRotation() end))
    local cube, plane, basic = asset(MESH_CUBE), asset(MESH_PLANE), asset(MATERIAL_BASIC)
    if not (isValid(world) and camLoc and camRot and cube and plane and basic) then
        log("tablet: missing world/camera/assets (cube=%s plane=%s material=%s)",
            tostring(cube ~= nil), tostring(plane ~= nil), tostring(basic ~= nil))
        return false
    end

    local actor = world:SpawnActor(StaticFindObject("/Script/Engine.Actor"), camLoc, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not isValid(actor) then log("tablet: SpawnActor failed"); return false end
    S.actor = actor

    local ok, err = pcall(function()
        local zero = { X = 0, Y = 0, Z = 0 }
        local noRot = { Pitch = 0, Yaw = 0, Roll = 0 }

        -- The first scene component added becomes the actor's root.
        local root = actor:AddComponentByClass(StaticFindObject("/Script/Engine.SceneComponent"), false,
                                               transform(zero, noRot, { X = 1, Y = 1, Z = 1 }), false)
        if not isValid(root) then error("TabletRoot failed") end
        try(function() root:SetMobility(EComponentMobility_Movable) end)

        -- Cube: 100 uu per side, so scale = cm / 100.
        local body, bodyMesh = addMesh(actor, "Body", cube, transform(zero, noRot,
            bodyScale()))

        -- Plane: lies in XY with normal +Z; texture U runs along the plane's X.
        -- M5 observed that Pitch -90 (normal +X, plane X -> down) showed the image
        -- turned 90 degrees; M6 then showed Yaw 90 / Roll -90 upside down.
        -- Yaw -90 / Roll 90 keeps the normal on +X and maps plane X -> -Y and
        -- plane Y -> -Z. Pitch +-90 is avoided: at that singularity the in-plane
        -- rotation cannot be expressed.
        local screen, screenMesh = addMesh(actor, "Screen", plane, transform(
            { X = BODY_DEPTH / 2 + SCREEN_GAP, Y = 0, Z = 0 },
            SCREEN_ROTATION,
            screenScale()))

        S.parts = { root = root, body = body, screen = screen, world = world }
        S.parts.bodyMaterial = colorize(body, "Body", basic, BODY_COLOR)
        S.parts.screenMaterial = Screen.createMaterial(screen)
        makeEmoteAtlas(actor, plane, world)
        if not S.parts.screenMaterial then
            colorize(screen, "Screen (fallback)", basic, SCREEN_FALLBACK_COLOR)
        end
        log("tablet: components root=%s body=%s (mesh %s) screen=%s (mesh %s)", U.className(root),
            U.className(body), tostring(bodyMesh), U.className(screen), tostring(screenMesh))

        local attached
        if placement == "camera" then
            -- Face the camera: tablet +X points back at the viewer.
            local p, y = math.rad(camRot.Pitch), math.rad(camRot.Yaw)
            local fwd = { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
            local loc = { X = camLoc.X + fwd.X * SPAWN_DISTANCE_CM, Y = camLoc.Y + fwd.Y * SPAWN_DISTANCE_CM,
                          Z = camLoc.Z + fwd.Z * SPAWN_DISTANCE_CM }
            actor:K2_SetActorLocationAndRotation(loc, { Pitch = -camRot.Pitch, Yaw = camRot.Yaw + 180, Roll = 0 }, false, {}, true)
            root:SetRelativeScale3D({ X = cfg.scale, Y = cfg.scale, Z = cfg.scale })
            attached = root:K2_AttachToComponent(anchor, FName("None"), EAttachmentRule_KeepWorld,
                                                 EAttachmentRule_KeepWorld, EAttachmentRule_KeepWorld, false)
        else
            -- Config transform: attach first (keeping the identity relative
            -- transform), then set it in the anchor's space.
            attached = root:K2_AttachToComponent(anchor, FName("None"), EAttachmentRule_KeepRelative,
                                                 EAttachmentRule_KeepRelative, EAttachmentRule_KeepRelative, false)
            root:K2_SetRelativeLocationAndRotation({ X = cfg.x, Y = cfg.y, Z = cfg.z },
                                                   { Pitch = cfg.pitch, Yaw = cfg.yaw, Roll = cfg.roll }, false, {}, true)
            root:SetRelativeScale3D({ X = cfg.scale, Y = cfg.scale, Z = cfg.scale })
        end
        local parent = fullName(try(function() return root.AttachParent end))
        log("tablet: Spawned %s", fullName(actor))
        log("tablet: Attached to %s of %s: %s (parent match %s)", anchorName, U.className(cab.car), tostring(attached),
            tostring(parent == fullName(anchor)))
        log("tablet: train %s -> profile %s", trainClass, profile)
        log("tablet: placed (%s) relative to %s: %s %s", placement, anchorName,
            U.vecStr(try(function() return root.RelativeLocation end)),
            U.rotStr(try(function() return root.RelativeRotation end)))

        applyMode()
        pcall(TrainId.report, anchorName)
    end)

    if not ok then
        log("tablet: spawn FAILED: %s -- removing partial actor", tostring(err))
        stopDynamic()
        pcall(function() actor:K2_DestroyActor() end)
        S.actor, S.parts, S.surface = nil, nil, nil
        Emotes.attach(nil)
        return false
    end
    return true
end

--- The current placement as a [Tablet] config block in the log.
local function logConfigBlock()
    if not S.parts then return end
    local loc = U.vec(try(function() return S.parts.root.RelativeLocation end))
    local rot = U.rot(try(function() return S.parts.root.RelativeRotation end))
    local scl = U.vec(try(function() return S.parts.root.RelativeScale3D end))
    if not (loc and rot) then log("tablet: cannot read the current transform"); return end
    local block = Config.tabletBlock({
        x = loc.X, y = loc.Y, z = loc.Z, pitch = rot.Pitch, yaw = rot.Yaw, roll = rot.Roll,
        scale = scl and scl.X or Config.values.tablet.scale, width = S.size.width, height = S.size.height,
        fontscale = ChatRender.STYLE.scale,
    }, S.trainClass and ("Train." .. S.trainClass) or nil)
    log("tablet: current placement -- paste into %s:", Config.FILE_NAME)
    for line in block:gmatch("[^\n]+") do log("    %s", line) end
end

local function despawn()
    local actor = S.actor
    stopDynamic()
    -- IsValid() stays true for a while after destroy (M1): drop the references
    -- first and never use them again. The render target goes with the material.
    S.actor, S.parts, S.surface = nil, nil, nil
    Emotes.attach(nil)
    local ok, err = pcall(function() actor:K2_DestroyActor() end)
    log("tablet: removed ok=%s %s", tostring(ok), err or "")
end

-- Everything below is called on the game thread (tt/input.lua polls keys there).

--------------------------------------------------------------------------------
-- placement API (Milestone 11 calibration)
--------------------------------------------------------------------------------

function M.exists() return S.parts ~= nil end

--- The profile the current tablet was placed with, and the train's class.
function M.profile() return S.profile, S.trainClass end

--- Calibration saved a profile for the current train: the hint goes away.
function M.profileSaved(profile)
    S.profile = profile
    S.hint = nil
    S.drawnVersion = nil
    if S.loop ~= nil then redrawDynamic(true) end
end

--- Live placement relative to the anchor: { x, y, z, pitch, yaw, roll, scale, width, height }.
function M.getPlacement()
    if not S.parts then return nil end
    local loc = U.vec(try(function() return S.parts.root.RelativeLocation end))
    local rot = U.rot(try(function() return S.parts.root.RelativeRotation end))
    local scl = U.vec(try(function() return S.parts.root.RelativeScale3D end))
    if not (loc and rot) then return nil end
    return { x = loc.X, y = loc.Y, z = loc.Z, pitch = rot.Pitch, yaw = rot.Yaw, roll = rot.Roll,
             scale = scl and scl.X or Config.values.tablet.scale, width = S.size.width, height = S.size.height,
             fontscale = ChatRender.STYLE.scale }
end

--- Applies position / rotation / scale (width and height go through M.resize).
function M.setPlacement(p)
    if not S.parts then return false end
    S.parts.root:K2_SetRelativeLocationAndRotation({ X = p.x, Y = p.y, Z = p.z },
        { Pitch = p.pitch, Yaw = p.yaw, Roll = p.roll }, false, {}, true)
    S.parts.root:SetRelativeScale3D({ X = p.scale, Y = p.scale, Z = p.scale })
    return true
end

--- Sets the absolute body size (cm), rebuilding the render target like M.resize.
function M.setSize(width, height)
    M.resize(width - S.size.width, height - S.size.height, 1)
end

--- One line drawn over the top of the screen, or nil to remove it.
function M.setOverlay(text)
    if S.overlay == text then return end
    S.overlay = text
    S.drawnVersion = nil
    if S.loop ~= nil then redrawDynamic(true) end
end

--- Hide / show key. Hiding also stops the auto-spawn until F1 is pressed again.
function M.toggle()
    if S.actor ~= nil then
        despawn()
        S.hidden = true
    else
        S.hidden = false
        spawn("config")
    end
end

--- Num5: put the tablet in front of the current view and log the config block
--- for that placement (the manual bridge to Milestone 11 calibration).
function M.placeInFrontOfCamera()
    if S.actor ~= nil then despawn() end
    S.hidden = false
    if spawn("camera") then logConfigBlock() end
end

--- Shows the tablet on its own when the player is in a cab (config AutoSpawn).
--- Runs every second on the game thread; quiet while there is no cab.
function M.startAutoSpawn()
    LoopInGameThreadWithDelay(AUTOSPAWN_PERIOD_MS, function()
        local ok, err = pcall(function()
            local now = U.nowMs()
            if S.actor ~= nil or S.hidden or not Config.values.tablet.autospawn then return end
            if now < S.pausedUntil or now < S.nextAutoTry then return end
            if not Cab.resolve() then return end        -- menu / loading: silently wait
            if spawn("config") then
                S.autoFailLogged = false
                log("tablet: auto-spawned")
            else
                S.nextAutoTry = now + AUTOSPAWN_RETRY_AFTER_FAIL_MS
                if not S.autoFailLogged then
                    S.autoFailLogged = true
                    log("tablet: auto-spawn failed, retrying every %d s", AUTOSPAWN_RETRY_AFTER_FAIL_MS / 1000)
                end
            end
        end)
        if not ok then log("tablet: auto-spawn error: %s", tostring(err)) end
    end)
end

--- A map load is starting or finished: stay away from the world for a while.
function M.pauseForMapLoad(ms)
    S.pausedUntil = U.nowMs() + ms
end

function M.nextMode()
    S.mode = S.mode % #MODES + 1
    if S.parts then
        applyMode()
    else
        log("tablet: screen mode %s is used on next spawn", MODES[S.mode].name)
    end
end

--- Body width/height change, in steps of `step` cm (default 1). Rescales the
--- body and the screen and rebuilds the render target for the new aspect: the
--- new one is set on the material right away, and the old Lua reference is
--- dropped first (M6 GC rule).
function M.resize(dWidth, dHeight, step)
    step = step or SIZE_STEP_CM
    local sz = S.size
    local w = math.max(SIZE_MIN_CM, math.min(SIZE_MAX_CM, sz.width + dWidth * step))
    local h = math.max(SIZE_MIN_CM, math.min(SIZE_MAX_CM, sz.height + dHeight * step))
    if w == sz.width and h == sz.height then return end
    sz.width, sz.height = w, h
    local rw, rh = renderTargetSize()
    log("tablet: size %.1f x %.1f cm, render target %dx%d", sz.width, sz.height, rw, rh)
    if not S.parts then return end
    try(function() S.parts.body:SetRelativeScale3D(bodyScale()) end)
    try(function() S.parts.screen:SetRelativeScale3D(screenScale()) end)
    if MODES[S.mode].dynamic then
        S.surface = nil
        applyMode()
    end
end

--- Font size of the chat, x factor per key press; redraws immediately.
function M.changeFontScale(factor)
    local scale = ChatRender.changeScale(factor)
    S.drawnVersion = nil
    log("chat: font scale %.2f", scale)
    if S.loop ~= nil then redrawDynamic(true) end
end

--- M16: screen off / on. The tablet stays; chat keeps arriving in the background.
function M.toggleScreen()
    S.screenOff = not S.screenOff
    log("tablet: screen %s", S.screenOff and "OFF" or "ON")
    S.drawnVersion = nil
    if S.loop ~= nil then redrawDynamic(true) end
end

--- M16: brightness x factor per key press, 0.05..1 (1 = full, see Dyn.brightness).
function M.changeBrightness(factor)
    local b = math.max(0.05, math.min(1, Dyn.brightness * factor))
    if b > 0.97 then b = 1 end
    Dyn.brightness = math.floor(b * 100 + 0.5) / 100
    log("tablet: brightness %.2f", Dyn.brightness)
    S.drawnVersion = nil
    if S.loop ~= nil then redrawDynamic(true) end
end

--- Milestone 7 debug: one fake message into the chat model.
function M.addFakeMessage()
    local user, text = FakeChat.addOne()
    log("chat: fake message #%d from %s (%d chars)", ChatModel.version(), user, utf8.len(text) or -1)
end

function M.perfSample(seconds)
    Perf.sample(S.actor and MODES[S.mode].name or "tablet off", seconds)
end

function M.logConfigBlock() logConfigBlock() end

--- Game thread only; before a dev reload drops this Lua state.
function M.shutdown()
    if S.actor ~= nil then despawn() end
end

--- LoadMap tears the level down; the old pointers must not be touched.
function M.forget()
    if S.actor ~= nil then log("tablet: forgotten on map change") end
    stopDynamic()
    S.actor, S.parts, S.surface = nil, nil, nil
    Emotes.attach(nil)
end

return M
