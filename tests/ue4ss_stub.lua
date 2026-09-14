--[[
    Minimal fake of the UE4SS Lua API, enough to execute the mod's code paths
    outside the game. It catches Lua mistakes (nil arithmetic, typos, wrong
    upvalues) that would otherwise cost a full game launch. It proves nothing
    about Unreal behaviour.
]]

local Stub = { printed = {}, queued = {}, binds = {}, gameThread = true }

print = function(s) table.insert(Stub.printed, (tostring(s):gsub("\n$", ""))) end

Key = setmetatable({}, { __index = function(_, k) return k end })
ModifierKey = { CONTROL = "CONTROL", SHIFT = "SHIFT", ALT = "ALT" }

function RegisterKeyBind(key, mods, fn)
    if fn == nil then fn, mods = mods, {} end
    table.insert(Stub.binds, { key = key, mods = mods, fn = fn })
end
function RegisterLoadMapPreHook(fn) end
function RegisterLoadMapPostHook(fn) end
function IsInGameThread() return Stub.gameThread end
function FName(s) assert(type(s) == "string"); return { s = s } end

EngineTickAvailable, ProcessEventAvailable = true, true
EGameThreadMethod = { EngineTick = 0, ProcessEvent = 1 }
function ExecuteInGameThread(fn) table.insert(Stub.queued, fn) end
function ExecuteInGameThreadWithDelay(ms, fn) table.insert(Stub.queued, fn) end
-- Loops keep running: every Stub.drain() is one tick of every active loop.
Stub.loops, Stub.nextHandle = {}, 100
local function addLoop(fn)
    Stub.nextHandle = Stub.nextHandle + 1
    Stub.loops[Stub.nextHandle] = fn
    return Stub.nextHandle
end
function LoopInGameThreadWithDelay(ms, fn) return addLoop(fn) end
function LoopInGameThreadAfterFrames(n, fn) return addLoop(fn) end
function CancelDelayedAction(h) local had = Stub.loops[h] ~= nil; Stub.loops[h] = nil; return had end
function ClearAllDelayedActions() Stub.cleared = true; Stub.loops = {}; return 0 end
function ExecuteAsync(fn) table.insert(Stub.queued, fn) end
function RestartCurrentMod() Stub.restarted = (Stub.restarted or 0) + 1 end

-- Fake RunningTrainTwitchTabletNative: call Stub.registerNative() to simulate
-- on_lua_start registering RTTT_* after main.lua ran.
function Stub.registerNative()
    local q, pushed, running = {}, 0, false
    Stub.nativeQueue = q
    function RTTT_Version() return "0.8.0-stub" end
    function RTTT_StartSynthetic(ms, every, size) running = true; return true end
    function RTTT_StopSynthetic() local was = running; running = false; return was end
    function RTTT_Status() return #q, pushed, 0, running end
    function RTTT_PopMessage()
        local m = table.remove(q, 1)
        if not m then return nil end
        return m[1], m[2], m[3] or "", m[4] or ""
    end
    -- Emotes: the first request "downloads" (writes a PNG header of 75x84, like
    -- Kappa) and reports pending; later requests report ready.
    local emoteReq = {}
    Stub.emoteRequests = emoteReq
    function RTTT_EmoteRequest(id, path)
        assert(type(id) == "string" and type(path) == "string")
        if emoteReq[id] then return "ready" end
        emoteReq[id] = path
        local f = assert(io.open(path, "wb"))
        f:write("\137PNG\r\n\26\n" .. string.pack(">I4", 13) .. "IHDR" .. string.pack(">I4>I4", 75, 84))
        f:close()
        return "pending"
    end
    function RTTT_EmoteStats() return 1, 0, 0, 0, "" end
    local twitch = { state = "stopped", channel = "", received = 0, connects = 0, err = "" }
    Stub.twitch = twitch
    function RTTT_TwitchStart(ch) twitch.channel = ch; twitch.state = "joined"; twitch.connects = twitch.connects + 1; return true end
    function RTTT_TwitchStop() local was = twitch.state ~= "stopped"; twitch.state = "stopped"; return was end
    function RTTT_TwitchDrop() twitch.state = "waiting"; twitch.err = "recv failed (10053)" end
    function RTTT_TwitchStatus() return twitch.state, twitch.channel, twitch.received, twitch.connects, twitch.err end
    function Stub.nativePush(user, text, color, emotes) pushed = pushed + 1; table.insert(q, { user, text, color, emotes }) end
end

function Stub.drain()
    local q = Stub.queued
    Stub.queued = {}
    for _, fn in ipairs(q) do fn() end
    local handles = {}
    for h in pairs(Stub.loops) do table.insert(handles, h) end
    table.sort(handles)
    for _, h in ipairs(handles) do
        local fn = Stub.loops[h]
        if fn then fn() end
    end
end

-- Keys polled through PlayerController:IsInputKeyDown(FKey): pressKey holds a
-- key down for one drain (one frame), then releases it.
Stub.keysDown = {}
function Stub.pressKey(ueName)
    Stub.keysDown[ueName] = true
    Stub.drain()
    Stub.keysDown[ueName] = nil
    Stub.drain()
end

function Stub.press(key, mods)
    for _, b in ipairs(Stub.binds) do
        if b.key == key and table.concat(b.mods, "+") == table.concat(mods or {}, "+") then
            b.fn()
            return
        end
    end
    error("no keybind for " .. tostring(key))
end

-- Fake UObject: any unknown field reads nil, a few methods return plausible data.
local FName = {}
FName.__index = FName
function FName:ToString() return self.s end

local Obj = {}
local function obj(name, cls, fields)
    return setmetatable({ _name = name, _cls = cls or "Object", _fields = fields or {} }, Obj)
end
Stub.obj = obj

Obj.__index = function(self, k)
    local m = rawget(Obj, k)
    if m ~= nil then return m end
    return rawget(self, "_fields")[k]
end
function Obj:IsValid() return not self._destroyed end
function Obj:GetFullName() return self._cls .. " " .. self._name end
function Obj:GetFName() return setmetatable({ s = self._name:match("[^./:]+$") }, FName) end
function Obj:GetClass() return obj("/Game/Fake/" .. self._cls .. "." .. self._cls, "BlueprintGeneratedClass") end
function Obj:GetSuperStruct() return obj("/Script/Engine.Actor", "Class") end
function Obj:ForEachProperty(cb)
    cb(obj("TrainRef", "ObjectProperty"))
    cb(obj("TrainName", "NameProperty"))
end
function Obj:GetWorld() return obj("/Game/_MainMaps/_MainPresistent._MainPresistent", "World") end
function Obj:K2_GetActorLocation() return { X = 1, Y = 2, Z = 3 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 90, Roll = 0 } end
function Obj:GetCameraLocation() return { X = 1, Y = 2, Z = 3 } end
function Obj:GetCameraRotation() return { Pitch = 0, Yaw = 90, Roll = 0 } end
function Obj:K2_GetComponentsByClass()
    return { obj("DefaultSceneRoot", "SceneComponent"), obj("CameraUnten", "CameraComponent") }
end
function Obj:GetAttachParentActor() return obj("PyBP_Train_C_1", "PyBP_Train_C") end
function Obj:GetOwner() return obj("Owner", "Actor") end
function Obj:SpawnActor() return obj("Actor_1", "Actor") end
function Obj:AddComponentByClass(cls, manual, transform, deferred)
    local q = transform.Rotation
    assert(math.abs(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W - 1) < 1e-6, "rotation is not a unit quaternion")
    assert(type(transform.Translation.X) == "number" and type(transform.Scale3D.Z) == "number", "bad FTransform table")
    return obj("Component_" .. tostring(math.random(1000)), "StaticMeshComponent")
end
function Obj:K2_DestroyActor() self._destroyed = true end
function Obj:SetMobility(m) assert(type(m) == "number"); self._fields.Mobility = m end
function Obj:SetStaticMesh(mesh) assert(mesh:IsValid()); return true end
function Obj:SetCollisionEnabled(c) assert(type(c) == "number") end
function Obj:SetWorldScale3D(v) assert(type(v.X) == "number"); self._scale = v end
function Obj:SetRelativeScale3D(v)
    assert(type(v.X) == "number" and type(v.Z) == "number")
    self._scale = v
    self._fields.RelativeScale3D = v
end
function Obj:K2_GetComponentScale() return self._scale or { X = 1, Y = 1, Z = 1 } end
function Obj:K2_SetActorLocationAndRotation(loc, rot, sweep, hit, teleport)
    assert(type(loc.X) == "number" and type(rot.Yaw) == "number" and type(hit) == "table")
    return true
end
function Obj:IsActorBeingDestroyed() return true end
function Obj:K2_SetRelativeLocationAndRotation(loc, rot, sweep, hit, teleport)
    assert(type(loc.X) == "number" and type(rot.Pitch) == "number" and type(hit) == "table")
    self._fields.RelativeLocation = { X = loc.X, Y = loc.Y, Z = loc.Z }
    self._fields.RelativeRotation = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
end
function Obj:CreateDynamicMaterialInstance(index, base, name)
    assert(index == 0 and base:IsValid() and type(name) == "table")
    return obj("MID_" .. base._name, "MaterialInstanceDynamic")
end
function Obj:SetTextureParameterValue(name, tex)
    assert(type(name) == "table" and tex:IsValid())
    self._tex = tex
end
function Obj:K2_GetTextureParameterValue(name) return self._tex end
function Obj:CreateRenderTarget2D(world, w, h, fmt, clear, mips, uav)
    assert(type(w) == "number" and type(fmt) == "number" and type(clear.A) == "number" and uav == false)
    Stub.renderTargets = (Stub.renderTargets or 0) + 1
    return obj("TextureRenderTarget2D_0", "TextureRenderTarget2D", { SizeX = w, SizeY = h })
end
function Obj:ClearRenderTarget2D(world, rt, color) assert(rt:IsValid() and type(color.R) == "number") end
function Obj:BeginDrawCanvasToRenderTarget(world, rt, canvasOut, sizeOut, context)
    assert(type(canvasOut) == "table" and type(sizeOut) == "table" and type(context) == "table")
    canvasOut.Canvas = obj("Canvas_0", "Canvas")
    sizeOut.X, sizeOut.Y = 1024, 768
    context.RenderTarget = rt
    Stub.openDraws = (Stub.openDraws or 0) + 1
end
function Obj:EndDrawCanvasToRenderTarget(world, context)
    assert(context.RenderTarget ~= nil)
    Stub.openDraws = Stub.openDraws - 1
end
function Obj:K2_DrawText(font, text, pos, scale, color, kerning, shadow, shadowOffset, cx, cy, outlined, outline)
    assert(font:IsValid() and type(text) == "string" and type(pos.X) == "number" and type(color.A) == "number" and outline ~= nil)
    Stub.texts = (Stub.texts or 0) + 1
end
function Obj:K2_DrawTexture(tex, pos, size, uvPos, uvSize, color, blend, rotation, pivot)
    assert(tex:IsValid() and type(size.Y) == "number" and type(blend) == "number" and pivot ~= nil)
    assert(type(uvPos.X) == "number" and type(uvSize.Y) == "number" and type(color.A) == "number")
    -- Opaque draws are atlas slots going onto the screen (emotes).
    if blend == 0 then Stub.emoteDraws = (Stub.emoteDraws or 0) + 1 end
end
function Obj:ImportFileAsTexture2D(world, file)
    local f = assert(io.open(file, "rb"), "import of a missing file: " .. tostring(file))
    f:close()
    Stub.imports = (Stub.imports or 0) + 1
    return obj("Texture2D_" .. Stub.imports, "Texture2D")
end
function Obj:GetWorldDeltaSeconds(world) return 0.016 end
function Obj:IsInputKeyDown(key)
    assert(type(key) == "table" and type(key.KeyName) == "table", "FKey must be { KeyName = FName }")
    return Stub.keysDown[key.KeyName.s] == true
end
function Obj:K2_TextSize(font, text, scale)
    assert(font:IsValid() and type(text) == "string" and type(scale.X) == "number")
    Stub.measures = (Stub.measures or 0) + 1
    return { X = utf8.len(text) * 14 * scale.X, Y = 28 * scale.Y }
end
function Obj:SetVectorParameterValue(name, color)
    assert(type(name) == "table" and type(color.R) == "number")
end
function Obj:IsA(cls) return self._cls:find("Component") ~= nil end
function Obj:K2_GetComponentLocation() return { X = 1, Y = 2, Z = 3 } end
function Obj:K2_GetComponentRotation() return { Pitch = 0.1, Yaw = 90, Roll = -0.04 } end
function Obj:K2_AttachToComponent(parent, socket, lr, rr, sr, weld)
    assert(parent:IsValid() and type(socket) == "table" and (lr == 0 or lr == 1) and weld == false)
    self._fields.AttachParent = parent
    self._fields.RelativeLocation = { X = 10, Y = 0, Z = 5 }
    self._fields.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }
    return true
end

local function tarray(items)
    return setmetatable({}, { __index = {
        ForEach = function(_, cb) for i, v in ipairs(items) do cb(i, { get = function() return v end }) end end,
    }, __len = function() return #items end })
end
local untendai = obj("BaseUntendai", "StaticMeshComponent", { RelativeLocation = { X = 1, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }, AttachChildren = tarray({}) })
local baseTrain = obj("BaseTrain", "StaticMeshComponent", { RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }, AttachChildren = tarray({ untendai }) })
local chassis = obj("Base_CHASIS", "StaticMeshComponent", { RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }, AttachChildren = tarray({ baseTrain }) })
local car = obj("Cpy_KuHa115_C_1", "Cpy_KuHa115_C", { RootComponent = chassis, Base_CHASIS = chassis, BaseTrain = baseTrain, BaseUntendai = untendai })
local unten = obj("/Game/_MainMaps/_MainPresistent._MainPresistent:PersistentLevel.PyBP_Base_Unten_Actor_C_1",
    "PyBP_Base_Unten_Actor_C", { RootComponent = obj("DefaultSceneRoot", "SceneComponent", { AttachParent = chassis }), BaseTrain = car })
local pcm = obj("PlayerCameraManager_1", "PlayerCameraManager", { ViewTarget = { Target = unten } })
local pc = obj("PlayerController_1", "PlayerController", { PlayerCameraManager = pcm, Pawn = unten })

function FindFirstOf() return pc end
function FindAllOf(name)
    if name == "Actor" then return { unten, obj("PyBP_TrainCar_C_1", "PyBP_TrainCar_C") } end
    return { obj("/Engine/BasicShapes/Cube.Cube", name) }
end
function StaticFindObject(path) return obj(path, "Class") end
function LoadAsset(path) return obj(path, "StaticMesh"), true, true end

return Stub
