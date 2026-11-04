--[[
    SILK CORE v2.1  (Roblox / executor, Luau)

    - Menu: RightControl / RightShift abre e fecha (tecla extra em Config).
    - Roupa: troca cabeca, tronco, bracos e pernas por ID. O ApplyDescription e bloqueado no
      cliente em jogos reais, entao a peca e montada por cima das partes reais (so no seu cliente).
    - Catalogo: qualquer ID (acessorio, roupa, rosto, tool, efeito). Parte do corpo vai pra Roupa.
    - Efeitos: particulas e rastro. Looks: salva/aplica/exporta looks completos. Ambiente: filtros e modo foto.
    - Desempenho: graficos ao vivo. Paleta de comandos: Ctrl esquerdo + K (ou /). Config: tema, atalhos, registro.
    - Opcoes salvas em workspace/SilkcoreSettings.json. A aba Timebomb e o codigo original.
--]]

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
local GUI_NAME    = "SilkcoreAvatar"
local FOV_NAME    = "SilkcoreFOV"
local AIM_BIND    = "SilkcoreAimlock"
local STRETCH_BIND = "SilkcoreStretch"
local FOV_BIND     = "SilkcoreFovMod"
local VOL_BIND     = "SilkcoreVolley"
local VOL_STEP     = nil   -- o passo de render da aba Vôlei, exportado do bloco
local ESP_NAME     = "SilkcoreESP"

-- clean previous run (gui, render step, old connections)
local env = (getgenv and getgenv()) or nil
if env and env.SilkcoreCleanup then pcall(env.SilkcoreCleanup) end
pcall(RunService.UnbindFromRenderStep, RunService, AIM_BIND)
pcall(RunService.UnbindFromRenderStep, RunService, STRETCH_BIND)
pcall(RunService.UnbindFromRenderStep, RunService, FOV_BIND)
pcall(RunService.UnbindFromRenderStep, RunService, VOL_BIND)

local guiParent = (gethui and gethui()) or PlayerGui
for _, parent in ipairs({PlayerGui, guiParent}) do
    for _, n in ipairs({GUI_NAME, FOV_NAME, ESP_NAME, "SilkcoreVolleyLines", "SilkcoreToasts", "SilkcoreLoader"}) do
        local old = parent:FindFirstChild(n)
        if old then old:Destroy() end
    end
end
local oldBlur = game:GetService("Lighting"):FindFirstChild("SilkcoreBlur")
if oldBlur then oldBlur:Destroy() end

--------------------------------------------------------------------------------
-- SILK GUARD — a camada que segura o que existe
--------------------------------------------------------------------------------
-- Três frentes, só três:
--   1. a GUI volta sozinha se alguém desabilitar ou soltar da árvore
--   2. o loop de render é contado — se parar, o bind é refeito
--   3. o que existe não é achável: nada em _G, nada de tabela com nome óbvio
-- O que ela NÃO promete: esconder do servidor. Não existe tráfego pra esconder
-- porque o que a gente faz é leitura. Arma invisível se a arma não dispara.
local SilkGuard = { On = true, Beats = 0, Ghost = false } do
    local G = SilkGuard
    local roots, draws, binds = {}, {}, {}
    local lastBeats = 0

    function G.track(inst)
        if inst then roots[#roots + 1] = inst end
        return inst
    end

    function G.watch(d)
        if d then draws[#draws + 1] = d end
        return d
    end

    function G.hold(name, priority, fn)
        binds[#binds + 1] = { name = name, priority = priority, fn = fn }
    end

    function G.audit()
        return ("roots=%d drawings=%d binds=%d beats=%d gethui=%s ghost=%s")
            :format(#roots, #draws, #binds, G.Beats, tostring(gethui ~= nil), tostring(G.Ghost))
    end

    function G.ghost(v)
        G.Ghost = v and true or false
        if G.Ghost and gethui then
            for i = 1, #roots do
                pcall(function() if roots[i] then roots[i].Parent = gethui() end end)
            end
        end
        return G.Ghost
    end

    local stalls = 0
    task.spawn(function()
        while G.On do
            task.wait(1)
            if G.Beats == lastBeats then stalls = stalls + 1 else stalls = 0 end
            -- Dois segundos parado, não um. Um request() do catálogo segura o frame
            -- por mais de um segundo e isso NÃO é bind morto. Antes o vigia agia no
            -- primeiro tique e remarranhava o passo com um callback nil (a função
            -- estava fora de escopo naquele ponto), matando a linha de mira de vez.
            if stalls >= 2 then
                for i = 1, #binds do
                    local b = binds[i]
                    if type(b.fn) == "function" then
                        pcall(RunService.UnbindFromRenderStep, RunService, b.name)
                        pcall(RunService.BindToRenderStep, RunService, b.name, b.priority, b.fn)
                    end
                end
                for i = 1, #roots do
                    pcall(function()
                        local r = roots[i]
                        if r and r.Parent == nil then r.Parent = guiParent end
                        if r and r.Enabled == false then r.Enabled = true end
                    end)
                end
                stalls = 0
            end
            lastBeats = G.Beats
        end
    end)
end

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local State = {
    Wardrobe = {},          -- slot do corpo -> id (aba Roupa)
    Catalog = {},           -- itens do catalogo no personagem
    WardrobeReapply = nil,
    CatalogReapply = nil,
    FxReapply = nil,
    ColorsReapply = nil,
    WardApply = nil,
    WardClearAll = nil,
    WardHideHead = nil,
    OnWardChange = function(_field, _id) end,
    Touch = function() end,
    AutoReapplyOnRespawn = true,
    LastTargetUserId = nil,
    OriginalDescription = nil,
    IsHeadless = false,
    Korblox = {Right = false, Left = false},
    KorbloxIds = {Right = 139607718, Left = 0},
    GapFix = true,      -- stretch thigh + shin bones so nothing floats
    Straight = true,    -- keep every piece on the leg axis (no sideways lean)
    KorbloxMode = {},   -- "native" | "overlay" | "mesh" per side (shown in toast + dump)
    R6Orig = {},        -- original R6 leg SpecialMesh, so the toggle can be undone
    KorbloxGen = {Right = 0, Left = 0}, -- cancela montagens antigas se outra comecar antes dela terminar
}

local LEG_PARTS = {"UpperLeg", "LowerLeg", "Foot"}

local conns = {}      -- global connections, cleaned on destroy
local bodyConns = {}  -- head guard connections
local legConns = {Right = {}, Left = {}} -- per-leg guard connections

local function track(c) conns[#conns + 1] = c
return c end
local function clearConns(list)
    for i = #list, 1, -1 do list[i]:Disconnect()
    list[i] = nil end
end
local function clearAllBody()
    clearConns(bodyConns)
    clearConns(legConns.Right)
    clearConns(legConns.Left)
end

--------------------------------------------------------------------------------
-- AVATAR ENGINE
--------------------------------------------------------------------------------
local Morph = {}

function Morph.Char() return LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait() end
function Morph.Hum() return Morph.Char():WaitForChild("Humanoid", 5) end

function Morph.SaveOriginal()
    local hum = Morph.Hum()
    if hum and not State.OriginalDescription then
        pcall(function() State.OriginalDescription = hum:GetAppliedDescription() end)
    end
end

function Morph.ResolveUserId(text)
    text = (tostring(text):gsub("%s+", ""))
    if tonumber(text) then return tonumber(text) end
    local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, text)
    return ok and id or nil
end

function Morph.Thumb(userId)
    local ok, content = pcall(Players.GetUserThumbnailAsync, Players, userId,
        Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
    return ok and content or "rbxasset://textures/ui/GuiImagePlaceholder.png"
end

local function sanitize(inst)
    for _, p in ipairs(inst:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide, p.CanTouch, p.CanQuery, p.Massless = false, false, false, true end
    end
    if inst:IsA("BasePart") then inst.CanCollide, inst.CanTouch, inst.CanQuery, inst.Massless = false, false, false, true end
end

local function fetch(id, className)
    local ok, objs = pcall(game.GetObjects, game, "rbxassetid://" .. tostring(id))
    if not (ok and objs) then return nil end
    for _, o in ipairs(objs) do
        if o:IsA(className) then return o end
        local c = o:FindFirstChildOfClass(className)
        if c then return c end
    end
    return nil
end

function Morph.ApplyBodyColors(char, d)
    local bc = char:FindFirstChildOfClass("BodyColors") or Instance.new("BodyColors", char)
    bc.HeadColor3, bc.LeftArmColor3, bc.RightArmColor3 = d.HeadColor, d.LeftArmColor, d.RightArmColor
    bc.LeftLegColor3, bc.RightLegColor3, bc.TorsoColor3 = d.LeftLegColor, d.RightLegColor, d.TorsoColor
end

function Morph.ApplyScales(hum, d)
    if hum.RigType ~= Enum.HumanoidRigType.R15 then return end
    for name, v in pairs({
        BodyHeightScale = d.HeightScale, BodyWidthScale = d.WidthScale, BodyDepthScale = d.DepthScale,
        HeadScale = d.HeadScale, BodyProportionScale = d.ProportionScale, BodyTypeScale = d.BodyTypeScale,
    }) do
        local sv = hum:FindFirstChild(name)
        if sv and sv:IsA("NumberValue") then sv.Value = v end
    end
end

function Morph.ApplyClothing(char, d, model)
    for _, it in ipairs(char:GetChildren()) do
        if it:IsA("Shirt") or it:IsA("Pants") or it:IsA("ShirtGraphic") then it:Destroy() end
    end
    local found = {}
    if model then
        for _, c in ipairs(model:GetChildren()) do
            if c:IsA("Shirt") or c:IsA("Pants") or c:IsA("ShirtGraphic") then
                c:Clone().Parent = char
                found[c.ClassName] = true
            end
        end
    end
    if not d then return end
    for _, p in ipairs({{"Shirt", d.Shirt}, {"Pants", d.Pants}, {"ShirtGraphic", d.GraphicTShirt}}) do
        if not found[p[1]] and p[2] and p[2] ~= 0 then
            task.spawn(function()
                local obj = fetch(p[2], p[1])
                if obj then obj.Parent = char end
            end)
        end
    end
end

function Morph.Mount(char, acc)
    sanitize(acc)
    local handle = acc:FindFirstChild("Handle")
    if not handle then return end
    acc.Parent = char

    local accAtt = handle:FindFirstChildOfClass("Attachment")
    local charAtt
    if accAtt then
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") then
                local f = part:FindFirstChild(accAtt.Name)
                if f and f:IsA("Attachment") then charAtt = f
                break end
            end
        end
    end

    local weld = Instance.new("WeldConstraint")
    if charAtt then
        handle.CFrame = charAtt.WorldCFrame * accAtt.CFrame:Inverse()
        weld.Part1 = charAtt.Parent
    else
        local target = char:FindFirstChild("Head") or char:FindFirstChild("UpperTorso") or char.PrimaryPart
        if not target then return end
        handle.CFrame = target.CFrame
        weld.Part1 = target
    end
    weld.Part0 = handle
    weld.Parent = handle
end

function Morph.ApplyAccessories(char, d, model)
    for _, it in ipairs(char:GetChildren()) do
        if it:IsA("Accessory") then it:Destroy() end
    end

    -- Preferred source: appearance model (one source only, avoids duplicates)
    local mounted = false
    if model then
        for _, c in ipairs(model:GetChildren()) do
            if c:IsA("Accessory") then
                Morph.Mount(char, c:Clone())
                mounted = true
            end
        end
    end
    if mounted or not d then return end

    -- Fallback: ids from the description
    local ids, seen = {}, {}
    local function add(id)
        id = tostring(id)
        if id ~= "0" and #id > 0 and not seen[id] then seen[id] = true
        ids[#ids + 1] = id end
    end
    pcall(function() for _, a in ipairs(d:GetAccessories(true)) do add(a.AssetId) end end)
    for _, cat in ipairs({d.HatAccessory, d.HairAccessory, d.FaceAccessory, d.NeckAccessory,
        d.ShouldersAccessory, d.FrontAccessory, d.BackAccessory, d.WaistAccessory}) do
        if cat and #cat > 0 then
            for raw in string.gmatch(cat, "([^,]+)") do add((raw:gsub("%s+", ""))) end
        end
    end
    for _, id in ipairs(ids) do
        task.spawn(function()
            local acc = fetch(id, "Accessory")
            if acc then Morph.Mount(char, acc) end
        end)
    end
end

-- Keeps a part at a forced Transparency without a per-frame loop
local function lockTransparency(list, part, value)
    part.Transparency = value
    list[#list + 1] = part:GetPropertyChangedSignal("Transparency"):Connect(function()
        if part.Transparency ~= value then part.Transparency = value end
    end)
end

local function makeRig(d, rigType)
    rigType = rigType or Enum.HumanoidRigType.R15
    local ok, r = pcall(function() return Players:CreateHumanoidModelFromDescription(d, rigType) end)
    if ok and r then return r end
    ok, r = pcall(function() return Players:CreateHumanoidModelFromDescriptionAsync(d, rigType) end)
    return ok and r or nil
end

local DefaultRig -- empty R15 rig, used as the mesh/size reference (built once)

local function purgeGhosts(char, side)
    for _, c in ipairs(char:GetChildren()) do
        if c.Name == "SilkcoreKorblox" .. side then c:Destroy() end
    end
end

local function clearLeg(char, side)
    clearConns(legConns[side])
    purgeGhosts(char, side)
    for _, p in ipairs(LEG_PARTS) do
        local part = char:FindFirstChild(side .. p)
        if part then part.Transparency = 0 end
    end
end

-- Overlay legs (used when the engine path does not change the mesh, e.g. custom/UGC bodies).
-- Each Korblox piece is welded to ITS OWN real leg part (so knees still bend) but is placed from
-- the Korblox rig's native layout, scaled to this body's real hip->ankle length. That keeps the
-- pieces where the asset designer put them instead of spreading them over a taller/odd body.
-- With State.GapFix on, the shin is stretched from the thigh down to the foot (no loose feet).
local function ghostLeg(side, id, gen)
    local char = Morph.Char()
    local real = {}
    for _, p in ipairs(LEG_PARTS) do
        real[p] = char:FindFirstChild(side .. p)
        if not real[p] then State.Korblox[side] = false
        return false, "R15 rig required" end
    end

    DefaultRig = DefaultRig or makeRig(Instance.new("HumanoidDescription"))
    local d = Instance.new("HumanoidDescription")
    d[side .. "Leg"] = id
    local rig = makeRig(d)
    if gen and State.KorbloxGen[side] ~= gen then if rig then rig:Destroy() end
    return true, "superseded" end
    if not (rig and DefaultRig) then State.Korblox[side] = false
    return false, "Could not build leg rig" end

    local function att(part, kind) return part and part:FindFirstChild(side .. kind) end
    local hipR, kneeU = att(real.UpperLeg, "HipRigAttachment"), att(real.UpperLeg, "KneeRigAttachment")
    local kneeL, ankleL = att(real.LowerLeg, "KneeRigAttachment"), att(real.LowerLeg, "AnkleRigAttachment")
    local ankleF = att(real.Foot, "AnkleRigAttachment")
    local hipS = att(rig:FindFirstChild(side .. "UpperLeg"), "HipRigAttachment")
    local ankleS = att(rig:FindFirstChild(side .. "Foot"), "AnkleRigAttachment")
    if not (hipR and kneeU and kneeL and ankleL and ankleF and hipS and ankleS) then
        rig:Destroy()
        State.Korblox[side] = false
        return false, "Leg joints not found"
    end

    local rp = rig:FindFirstChild("HumanoidRootPart")
    local rootCF = rp and rp.CFrame or CFrame.new()
    local function nat(v) return rootCF:VectorToObjectSpace(v) end

    local nativeLen = -nat(ankleS.WorldPosition - hipS.WorldPosition).Y -- hip -> ankle on the asset rig
    local K = (hipR.Position - kneeU.Position).Magnitude                -- real thigh joint spacing
    local L = (kneeL.Position - ankleL.Position).Magnitude              -- real shin joint spacing
    local s = (nativeLen > 0.01) and (K + L) / nativeLen or 1           -- leg-length scale for this body
    local jointOff = {UpperLeg = 0, LowerLeg = K, Foot = K + L}
    local jointAtt = {UpperLeg = hipR, LowerLeg = kneeL, Foot = ankleF}

    -- native layout along the leg axis, relative to the hip (Y negative = down)
    local piece = {}
    for _, p in ipairs(LEG_PARTS) do
        local src, base = rig:FindFirstChild(side .. p), DefaultRig:FindFirstChild(side .. p)
        if src and base and src:IsA("MeshPart") then
            local v = nat(src.Position - hipS.WorldPosition)
            local sizeY = src.Size.Y * s
            piece[p] = {
                src = src, r = real[p].Size / base.Size, v = v,
                cy = v.Y * s, sizeY = sizeY, custom = src.MeshId ~= base.MeshId,
            }
        end
    end

    if State.GapFix and piece.UpperLeg and piece.LowerLeg and piece.Foot then
        -- stretch thigh + shin proportionally so they run from the thigh top straight down to the foot
        local u, sh, ft = piece.UpperLeg, piece.LowerLeg, piece.Foot
        local topY = u.cy + u.sizeY / 2
        local total = topY - (ft.cy + ft.sizeY / 2)
        local sum = u.sizeY + sh.sizeY
        if total > sum then
            local f = total / sum
            u.sizeY, sh.sizeY = u.sizeY * f, sh.sizeY * f
            u.cy = topY - u.sizeY / 2
            sh.cy = topY - u.sizeY - sh.sizeY / 2
        end
    end

    -- Straight: every piece shares the thigh's lateral offset, so the chain can't lean sideways
    local ax = State.Straight and piece.UpperLeg and piece.UpperLeg.v.X or nil
    local az = State.Straight and piece.UpperLeg and piece.UpperLeg.v.Z or nil

    purgeGhosts(char, side)

    local ghost = Instance.new("Folder")
    ghost.Name = "SilkcoreKorblox" .. side
    ghost.Parent = char -- in the world first, so welds capture the right offset
    local count, already = 0, 0

    for _, p in ipairs(LEG_PARTS) do
        local pc, realPart = piece[p], real[p]
        if pc and pc.custom then
            if realPart.MeshId == pc.src.MeshId then
                already = already + 1 -- engine already renders this mesh, no overlay needed
            else
                local clone = pc.src:Clone()
                for _, c in ipairs(clone:GetChildren()) do
                    if c:IsA("Motor6D") or c:IsA("Attachment") or c:IsA("Weld") then c:Destroy() end
                end
                clone.Name = "Korblox_" .. side .. p
                clone.Size = Vector3.new(pc.src.Size.X * pc.r.X, pc.sizeY, pc.src.Size.Z * pc.r.Z)
                clone.Transparency = 0

                -- centre relative to this part's own joint attachment, in the real part's local axes
                local rel = Vector3.new((ax or pc.v.X) * pc.r.X, pc.cy + jointOff[p], (az or pc.v.Z) * pc.r.Z)
                local relRot = rootCF:ToObjectSpace(pc.src.CFrame)
                relRot = relRot - relRot.Position
                local rot = realPart.CFrame - realPart.CFrame.Position
                clone.CFrame = CFrame.new(jointAtt[p].WorldPosition + realPart.CFrame:VectorToWorldSpace(rel)) * rot * relRot

                sanitize(clone)
                clone.Parent = ghost
                local w = Instance.new("WeldConstraint")
                w.Part0, w.Part1 = clone, realPart
                w.Parent = clone
                lockTransparency(legConns[side], realPart, 1)
                count = count + 1
            end
        end
    end
    rig:Destroy()

    if count == 0 then
        ghost:Destroy()
        if already > 0 then return true end
        State.Korblox[side] = false
        return false, "That asset has no leg mesh for the " .. side:lower() .. " leg"
    end
    return true
end

-- true when the real leg parts already use a non-default mesh (engine rendered a custom leg)
function Morph.LegIsCustom(char, side)
    local h = char:FindFirstChildOfClass("Humanoid")
    if h and h.RigType == Enum.HumanoidRigType.R6 then
        local leg = char:FindFirstChild(side .. " Leg")
        local m = leg and leg:FindFirstChildOfClass("SpecialMesh")
        return m ~= nil and m.MeshId ~= ""
    end
    DefaultRig = DefaultRig or makeRig(Instance.new("HumanoidDescription"))
    if not DefaultRig then return false end
    for _, p in ipairs(LEG_PARTS) do
        local part, base = char:FindFirstChild(side .. p), DefaultRig:FindFirstChild(side .. p)
        if part and base and part:IsA("MeshPart") and part.MeshId ~= base.MeshId then return true end
    end
    return false
end

-- PRIMARY path: let Roblox itself build the leg (correct joints, scale and angle).
-- Re-applies the CURRENT description with only that leg swapped, so nothing else changes.
local function engineLeg(side, legId)
    local char, hum = Morph.Char(), Morph.Hum()
    if not hum then return false end
    local ok, d = pcall(function() return hum:GetAppliedDescription() end)
    if not (ok and d) then return false end
    d[side .. "Leg"] = legId

    -- ApplyDescription can drop accessories it doesn't know about (the cloner mounts some by hand)
    local keep = {}
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Accessory") then keep[#keep + 1] = c:Clone() end
    end

    local applied = pcall(function() hum:ApplyDescription(d) end)
    if not applied then return false end

    char = Morph.Char()
    local have = {}
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Accessory") then have[c.Name] = true end
    end
    for _, acc in ipairs(keep) do
        if have[acc.Name] then acc:Destroy() else Morph.Mount(char, acc) end
    end
    return true
end

-- ===== R6 =====
-- R6 limbs are plain Parts; a package leg is a SpecialMesh on that Part.
local function clearR6(char, side)
    clearConns(legConns[side])
    purgeGhosts(char, side)
    local leg = char:FindFirstChild(side .. " Leg")
    if not leg then return end
    leg.Transparency = 0
    local had = false
    for _, c in ipairs(leg:GetChildren()) do
        if c:IsA("SpecialMesh") and c:GetAttribute("Silkcore") then c:Destroy()
        had = true end
    end
    local saved = State.R6Orig[side]
    if had and saved and saved.Part == leg and saved.Mesh then saved.Mesh:Clone().Parent = leg end
end

function Morph.SetKorbloxR6(side, enabled, assetId)
    local char = Morph.Char()
    local leg = char:FindFirstChild(side .. " Leg")
    if not leg then return false, "R6 " .. side:lower() .. " leg not found" end
    State.Korblox[side] = enabled
    local gen = (State.KorbloxGen[side] or 0) + 1
    State.KorbloxGen[side] = gen
    if assetId then State.KorbloxIds[side] = assetId end
    clearR6(char, side)
    Morph.SaveOriginal()

    if not enabled then
        if State.KorbloxMode[side] == "native" then
            local orig = State.OriginalDescription and tonumber(State.OriginalDescription[side .. "Leg"]) or 0
            engineLeg(side, orig)
        end
        State.KorbloxMode[side] = nil
        return true
    end

    local id = tonumber(State.KorbloxIds[side]) or 0
    if id == 0 then State.Korblox[side] = false
    return false, "Enter the leg asset ID first" end

    -- 1) let Roblox apply it
    local engineOk = engineLeg(side, id)
    if State.KorbloxGen[side] ~= gen then return true, "superseded" end
    if engineOk and Morph.LegIsCustom(Morph.Char(), side) then
        State.KorbloxMode[side] = "native"
        return true, "native"
    end

    -- 2) copy the mesh from a real R6 rig that has the asset equipped
    leg = Morph.Char():FindFirstChild(side .. " Leg")
    local d = Instance.new("HumanoidDescription")
    d[side .. "Leg"] = id
    local rig = makeRig(d, Enum.HumanoidRigType.R6)
    if State.KorbloxGen[side] ~= gen then if rig then rig:Destroy() end
    return true, "superseded" end
    local src = rig and rig:FindFirstChild(side .. " Leg")
    if not (leg and src) then
        if rig then rig:Destroy() end
        State.Korblox[side] = false
        return false, "Could not build R6 leg rig"
    end

    local mesh = src:FindFirstChildOfClass("SpecialMesh")
    if mesh and mesh.MeshId ~= "" then
        local existing = leg:FindFirstChildOfClass("SpecialMesh")
        if existing then
            State.R6Orig[side] = {Part = leg, Mesh = existing:Clone()}
            existing:Destroy()
        end
        local c = mesh:Clone()
        c:SetAttribute("Silkcore", true)
        c.Parent = leg
        rig:Destroy()
        State.KorbloxMode[side] = "mesh"
        return true, "mesh"
    end

    if src:IsA("MeshPart") then
        -- newer packages ship the R6 leg as a MeshPart: overlay it, positioned relative to the Torso
        local rt, ct = rig:FindFirstChild("Torso"), char:FindFirstChild("Torso")
        if rt and ct then
            purgeGhosts(char, side)
            local ghost = Instance.new("Folder")
            ghost.Name = "SilkcoreKorblox" .. side
            ghost.Parent = char
            local clone = src:Clone()
            for _, c in ipairs(clone:GetChildren()) do
                if c:IsA("Motor6D") or c:IsA("Attachment") or c:IsA("Weld") then c:Destroy() end
            end
            clone.Name = "Korblox_" .. side .. "Leg"
            clone.CFrame = ct.CFrame * rt.CFrame:ToObjectSpace(src.CFrame)
            sanitize(clone)
            clone.Parent = ghost
            local w = Instance.new("WeldConstraint")
            w.Part0, w.Part1 = clone, leg
            w.Parent = clone
            lockTransparency(legConns[side], leg, 1)
            rig:Destroy()
            State.KorbloxMode[side] = "overlay"
            return true, "overlay"
        end
    end

    rig:Destroy()

    -- 4) the asset only exists as an R15 leg (this is the usual case for Korblox ids):
    --    overlay the R15 meshes on the R6 leg. Rigid, so no knee bend, but shape/colors are exact.
    DefaultRig = DefaultRig or makeRig(Instance.new("HumanoidDescription"))
    local d15 = Instance.new("HumanoidDescription")
    d15[side .. "Leg"] = id
    local rig15 = makeRig(d15)
    if State.KorbloxGen[side] ~= gen then if rig15 then rig15:Destroy() end
    return true, "superseded" end
    local upper = rig15 and rig15:FindFirstChild(side .. "UpperLeg")
    local hipAtt = upper and upper:FindFirstChild(side .. "HipRigAttachment")
    if not (rig15 and DefaultRig and hipAtt) then
        if rig15 then rig15:Destroy() end
        State.Korblox[side] = false
        return false, "Could not build the leg for R6"
    end

    local changed = false
    for _, p in ipairs(LEG_PARTS) do
        local s15, b15 = rig15:FindFirstChild(side .. p), DefaultRig:FindFirstChild(side .. p)
        if s15 and b15 and s15:IsA("MeshPart") and s15.MeshId ~= b15.MeshId then changed = true end
    end
    if not changed then
        rig15:Destroy()
        State.Korblox[side] = false
        return false, "That asset has no leg mesh"
    end

    local rp = rig15:FindFirstChild("HumanoidRootPart")
    local rootCF = rp and rp.CFrame or CFrame.new()

    -- mede o conjunto (topo da coxa -> sola do pe) na rig do asset
    local pieces, topY, botY = {}, -math.huge, math.huge
    for _, p in ipairs(LEG_PARTS) do
        local s15 = rig15:FindFirstChild(side .. p)
        if s15 and s15:IsA("MeshPart") then
            local v = rootCF:VectorToObjectSpace(s15.Position - hipAtt.WorldPosition)
            pieces[#pieces + 1] = {src = s15, v = v}
            topY = math.max(topY, v.Y + s15.Size.Y / 2)
            botY = math.min(botY, v.Y - s15.Size.Y / 2)
        end
    end
    local total = topY - botY
    if #pieces == 0 or total < 0.05 then
        rig15:Destroy()
        State.Korblox[side] = false
        return false, "That asset has no leg mesh"
    end
    -- escala uniforme: o conjunto inteiro passa a ter exatamente o comprimento do leg R6,
    -- entao as 3 pecas ficam coladas uma na outra (sem pe solto la embaixo)
    local sc = leg.Size.Y / total
    local midY = (topY + botY) / 2

    purgeGhosts(char, side)
    local ghost = Instance.new("Folder")
    ghost.Name = "SilkcoreKorblox" .. side
    ghost.Parent = char
    for _, pc in ipairs(pieces) do
        local clone = pc.src:Clone()
        for _, c in ipairs(clone:GetChildren()) do
            if c:IsA("Motor6D") or c:IsA("Attachment") or c:IsA("Weld") then c:Destroy() end
        end
        clone.Name = "Korblox_" .. side .. pc.src.Name:sub(#side + 1)
        local relRot = rootCF:ToObjectSpace(pc.src.CFrame)
        relRot = relRot - relRot.Position
        local lx = State.Straight and 0 or pc.v.X * sc
        local lz = State.Straight and 0 or pc.v.Z * sc
        clone.Size = pc.src.Size * sc
        clone.CFrame = leg.CFrame * CFrame.new(lx, (pc.v.Y - midY) * sc, lz) * relRot
        sanitize(clone)
        clone.Parent = ghost
        local w = Instance.new("WeldConstraint")
        w.Part0, w.Part1 = clone, leg
        w.Parent = clone
    end
    lockTransparency(legConns[side], leg, 1)
    rig15:Destroy()
    State.KorbloxMode[side] = "r15-overlay"
    return true, "r15-overlay"
end

function Morph.SetKorblox(side, enabled, assetId)
    local char = Morph.Char()
    local h0 = char:FindFirstChildOfClass("Humanoid")
    if h0 and h0.RigType == Enum.HumanoidRigType.R6 then
        return Morph.SetKorbloxR6(side, enabled, assetId)
    end
    State.Korblox[side] = enabled
    local gen = (State.KorbloxGen[side] or 0) + 1
    State.KorbloxGen[side] = gen
    if assetId then State.KorbloxIds[side] = assetId end
    clearLeg(char, side) -- removes any ghost overlay and un-hides the real parts
    Morph.SaveOriginal()

    if not enabled then
        local orig = State.OriginalDescription and tonumber(State.OriginalDescription[side .. "Leg"]) or 0
        engineLeg(side, orig)
        State.KorbloxMode[side] = nil
        return true
    end

    local id = tonumber(State.KorbloxIds[side]) or 0
    if id == 0 then State.Korblox[side] = false
    return false, "Enter the leg asset ID first" end

    local engineOk = engineLeg(side, id)
    if State.KorbloxGen[side] ~= gen then return true, "superseded" end
    if engineOk and Morph.LegIsCustom(Morph.Char(), side) then
        State.KorbloxMode[side] = "native"
        return true, "native" -- Roblox rendered it itself
    end

    -- engine path did not change the mesh: fall back to the ghost overlay
    local ok, err = ghostLeg(side, id, gen)
    if err == "superseded" then return true, "superseded" end
    if not ok then State.Korblox[side] = false
    return false, err end
    State.KorbloxMode[side] = "overlay"
    return true, "overlay"
end

-- Diagnostic: everything about the character's rig, copied to clipboard / console / file
function Morph.Dump()
    local char = Morph.Char()
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local function v3(v) return string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) end

    add("== SILKCORE DUMP ==")
    add("PlaceId=%s  rig=%s", tostring(game.PlaceId), hum and tostring(hum.RigType) or "?")
    add("GapFix=%s Straight=%s", tostring(State.GapFix), tostring(State.Straight))
    add("Korblox  R=%s(%s) id=%s | L=%s(%s) id=%s",
        tostring(State.Korblox.Right), tostring(State.KorbloxMode.Right), tostring(State.KorbloxIds.Right),
        tostring(State.Korblox.Left), tostring(State.KorbloxMode.Left), tostring(State.KorbloxIds.Left))
    if hum then
        for _, c in ipairs(hum:GetChildren()) do
            if c:IsA("NumberValue") then add("scale %s = %.3f", c.Name, c.Value) end
        end
    end
    local inv = root and root.CFrame:Inverse()
    add("-- parts (pos relative to HumanoidRootPart)")
    for _, inst in ipairs(char:GetDescendants()) do
        if inst:IsA("BasePart") then
            local rel = inv and v3(inv * inst.Position) or "?"
            local extra = ""
            if inst:IsA("MeshPart") then extra = " mesh=" .. inst.MeshId .. " tex=" .. inst.TextureID end
            add("%-24s %-10s size=%s pos=%s transp=%.2f col=%s parent=%s%s",
                inst.Name, inst.ClassName, v3(inst.Size), rel, inst.Transparency,
                tostring(inst.BrickColor), inst.Parent and inst.Parent.Name or "nil", extra)
        elseif inst:IsA("SpecialMesh") then
            add("  SpecialMesh in %s: mesh=%s tex=%s scale=%s offset=%s silkcore=%s",
                inst.Parent and inst.Parent.Name or "?", inst.MeshId, inst.TextureId,
                v3(inst.Scale), v3(inst.Offset), tostring(inst:GetAttribute("Silkcore")))
        elseif inst:IsA("Motor6D") then
            add("  Motor6D %s: %s -> %s", inst.Name,
                inst.Part0 and inst.Part0.Name or "nil", inst.Part1 and inst.Part1.Name or "nil")
        elseif inst:IsA("Accessory") then
            local h = inst:FindFirstChild("Handle")
            add("  Accessory %s handle=%s", inst.Name, h and v3(h.Size) or "none")
        elseif inst:IsA("Folder") and inst.Name:find("Silkcore") then
            add("  Folder %s (%d children)", inst.Name, #inst:GetChildren())
        end
    end

    local text = table.concat(out, "\n")
    local copied = false
    if setclipboard then copied = pcall(setclipboard, text) end
    if writefile then pcall(writefile, "SilkcoreDump.txt", text) end
    for _, line in ipairs(out) do print(line) end
    return copied
end

-- Game dump (for building a per-game tab): place info, local player, character, tools,
-- other players, workspace / replicated trees, every remote, scripts, executor funcs.
-- mode "full" = everything, "net" = header + remotes + scripts + executor funcs only.
function Morph.DumpGame(mode)
    mode = mode or "full"
    local out, MAXLINES, truncated = {}, 2200, false
    local function add(fmt, ...)
        if #out >= MAXLINES then truncated = true
        return end
        out[#out + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    end
    local function section(title, fn)
        add("")
        add("== %s ==", title)
        local ok, err = pcall(fn)
        if not ok then add("  (section failed: %s)", tostring(err)) end
    end
    local function path(i) local ok, n = pcall(i.GetFullName, i)
    return ok and n or tostring(i) end
    local function valueOf(i)
        if i:IsA("ValueBase") then
            local ok, v = pcall(function() return i.Value end)
            return ok and tostring(v) or "?"
        end
        return nil
    end
    local function attrs(i)
        local ok, a = pcall(i.GetAttributes, i)
        if not ok or next(a) == nil then return "" end
        local t = {}
        for k, v in pairs(a) do t[#t + 1] = k .. "=" .. tostring(v) end
        table.sort(t)
        return "  {" .. table.concat(t, ", ") .. "}"
    end
    local function tree(root, maxDepth, perNode, skip)
        local function walk(inst, depth)
            local kids = inst:GetChildren()
            for idx, c in ipairs(kids) do
                if idx > perNode then add("%s... +%d more", string.rep("  ", depth + 1), #kids - perNode)
                break end
                if not (skip and skip(c)) then
                    local v = valueOf(c)
                    add("%s%s [%s]%s%s", string.rep("  ", depth + 1), c.Name, c.ClassName, v and (" = " .. v) or "", attrs(c))
                    if depth < maxDepth then walk(c, depth + 1) end
                end
            end
        end
        walk(root, 0)
    end
    local function isPlayerChar(i) return i:IsA("Model") and Players:GetPlayerFromCharacter(i) ~= nil end
    local function svc(name) local ok, s = pcall(game.GetService, game, name)
    return ok and s or nil end

    section("GAME", function()
        local name = "?"
        local MPS = svc("MarketplaceService")
        if MPS then
            local ok, info = pcall(MPS.GetProductInfo, MPS, game.PlaceId)
            if ok and info then name = tostring(info.Name) end
        end
        add("name=%s  PlaceId=%s  GameId=%s", name, tostring(game.PlaceId), tostring(game.GameId))
        local okEx, exName = false, nil
        if identifyexecutor then okEx, exName = pcall(identifyexecutor) end
        add("executor=%s", (okEx and exName ~= nil) and tostring(exName) or "unknown")
        add("players=%d  gravity=%.2f  streaming=%s", #Players:GetPlayers(), Workspace.Gravity, tostring(Workspace.StreamingEnabled))
        local cam = Workspace.CurrentCamera
        if cam then add("camera: type=%s fov=%.1f subject=%s", tostring(cam.CameraType), cam.FieldOfView, tostring(cam.CameraSubject)) end
        add("LocalPlayer=%s  team=%s", LocalPlayer.Name, tostring(LocalPlayer.Team))
    end)

    if mode == "full" then
        section("LOCAL PLAYER (children + attributes)", function()
            add("attrs:%s", attrs(LocalPlayer))
            for _, c in ipairs(LocalPlayer:GetChildren()) do
                if c.Name == "PlayerGui" then
                    add("  PlayerGui:")
                    for _, g in ipairs(c:GetChildren()) do add("    %s [%s]", g.Name, g.ClassName) end
                elseif c.Name == "Backpack" then
                    add("  Backpack:")
                    tree(c, 3, 30)
                else
                    local v = valueOf(c)
                    add("  %s [%s]%s", c.Name, c.ClassName, v and (" = " .. v) or "")
                    if c.Name == "leaderstats" then tree(c, 1, 20) end
                end
            end
        end)

        section("CHARACTER", function()
            local char = LocalPlayer.Character
            if not char then add("  no character")
            return end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                add("humanoid: rig=%s walk=%.1f usejp=%s jp=%.1f jh=%.2f hip=%.2f hp=%.0f/%.0f state=%s autorotate=%s",
                    tostring(hum.RigType), hum.WalkSpeed, tostring(hum.UseJumpPower), hum.JumpPower, hum.JumpHeight,
                    hum.HipHeight, hum.Health, hum.MaxHealth, tostring(hum:GetState()), tostring(hum.AutoRotate))
            end
            add("attrs:%s", attrs(char))
            local parts = {}
            for _, c in ipairs(char:GetChildren()) do
                if c:IsA("BasePart") then parts[#parts + 1] = c.Name end
            end
            add("parts: %s", table.concat(parts, ", "))
            tree(char, 3, 40, function(c)
                return c:IsA("BasePart") or c:IsA("Attachment") or c:IsA("Motor6D") or c:IsA("Accessory")
                    or c:IsA("Decal") or c:IsA("SpecialMesh") or c:IsA("Weld") or c:IsA("WeldConstraint")
            end)
        end)

        section("OTHER PLAYERS", function()
            for i, plr in ipairs(Players:GetPlayers()) do
                if i > 40 then add("  ... more")
                break end
                if plr ~= LocalPlayer then
                    local held = {}
                    local ch = plr.Character
                    if ch then
                        for _, c in ipairs(ch:GetChildren()) do if c:IsA("Tool") then held[#held + 1] = c.Name end end
                    end
                    add("  %s team=%s char=%s tools=[%s]%s", plr.Name, tostring(plr.Team), tostring(ch ~= nil),
                        table.concat(held, ","), attrs(plr))
                end
            end
        end)

        section("WORKSPACE (depth 2)", function()
            tree(Workspace, 2, 45, function(c)
                return c:IsA("Terrain") or c:IsA("Camera") or isPlayerChar(c)
            end)
        end)

        section("REPLICATED STORAGE (depth 4)", function()
            local rs = svc("ReplicatedStorage")
            if rs then tree(rs, 4, 60, function(c) return c.Name == "DefaultChatSystemChatEvents" end) end
        end)

        section("REPLICATED FIRST / STARTER PLAYER / TEAMS", function()
            for _, n in ipairs({"ReplicatedFirst", "StarterPlayer", "StarterGui", "Teams"}) do
                local s = svc(n)
                if s then add("  [%s]", n)
                tree(s, 3, 30) end
            end
        end)

        section("KEYWORD HITS (bomb/timer/round/duel/damage/hit/weapon/gun/knife/kill)", function()
            local pats = {"bomb", "timer", "round", "duel", "damage", "hitbox", "weapon", "gun", "knife", "kill", "holder", "explo"}
            local shown = 0
            for _, root in ipairs({Workspace, svc("ReplicatedStorage"), LocalPlayer:FindFirstChild("PlayerGui")}) do
                if root then
                    for _, d in ipairs(root:GetDescendants()) do
                        local n = d.Name:lower()
                        for _, p in ipairs(pats) do
                            if n:find(p, 1, true) and not isPlayerChar(d) then
                                shown = shown + 1
                                if shown > 220 then return end
                                local v = valueOf(d)
                                add("  %s [%s]%s", path(d), d.ClassName, v and (" = " .. v) or "")
                                break
                            end
                        end
                    end
                end
            end
        end)
    end

    section("REMOTES (RemoteEvent / RemoteFunction / UnreliableRemoteEvent)", function()
        local n = 0
        for _, d in ipairs(game:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d.ClassName == "UnreliableRemoteEvent" then
                local pth = path(d)
                if not (pth:find("^CoreGui") or pth:find("^RobloxReplicatedStorage") or pth:find("DefaultChatSystemChatEvents", 1, true)) then
                    n = n + 1
                    if n > 500 then add("  ... more")
                    break end
                    add("  %s [%s]", pth, d.ClassName)
                end
            end
        end
        add("  total shown: %d", math.min(n, 500))
    end)

    section("SCRIPTS (client-visible)", function()
        local seen = {}
        local function list(label, getter)
            if not getter then add("  (%s unavailable on this executor)", label)
            return end
            local ok, arr = pcall(getter)
            if not ok or type(arr) ~= "table" then return end
            add("  -- %s: %d", label, #arr)
            local shown = 0
            for _, sc in ipairs(arr) do
                local pth = path(sc)
                if not (pth:find("^CoreGui") or pth:find("RobloxGui", 1, true) or pth:find("^CorePackages")
                    or pth:find("PlayerModule", 1, true) or seen[sc]) then
                    seen[sc] = true
                    shown = shown + 1
                    if shown > 250 then add("  ... more")
                    break end
                    add("  %s [%s]", pth, sc.ClassName)
                end
            end
        end
        list("getscripts", getscripts)
        list("getloadedmodules", getloadedmodules)
    end)

    section("EXECUTOR FUNCTIONS", function()
        local names = {
            "hookmetamethod", "hookfunction", "getrawmetatable", "setreadonly", "newcclosure", "checkcaller",
            "getnamecallmethod", "firesignal", "fireclickdetector", "fireproximityprompt", "firetouchinterest",
            "getgc", "getconnections", "getnilinstances", "getinstances", "getupvalues", "getconstants",
            "getsenv", "getrenv", "getgenv", "request", "setclipboard", "writefile", "readfile", "Drawing",
            "gethui", "cloneref", "decompile", "saveinstance", "setfpscap", "mousemoverel", "mouse1click",
        }
        local have, miss = {}, {}
        for _, n in ipairs(names) do
            local ok, v = pcall(function() return getfenv()[n] or (getgenv and getgenv()[n]) end)
            if ok and v then have[#have + 1] = n else miss[#miss + 1] = n end
        end
        add("  have: %s", table.concat(have, ", "))
        add("  missing: %s", table.concat(miss, ", "))
    end)

    if truncated then add("-- output capped at %d lines --", MAXLINES) end
    local text = table.concat(out, "\n")
    local copied = false
    if setclipboard then copied = pcall(setclipboard, text) end
    local file = (mode == "full") and "SilkcoreGameDump.txt" or "SilkcoreNetDump.txt"
    local wrote = false
    if writefile then wrote = pcall(writefile, file, text) end
    for _, line in ipairs(out) do print(line) end
    return copied, #out, wrote and file or nil
end

-- Decompile the client-side logic that matters for this game (bomb pass, character replication,
-- explosions, arena rules) into one text file so the cheats can be tuned to the real code.
function Morph.DumpSource()
    if not decompile then return false, 0, nil, "decompile unavailable on this executor" end
    local function find(pathStr)
        local cur = game
        for part in pathStr:gmatch("[^%.]+") do
            cur = cur and cur:FindFirstChild(part)
            if not cur then return nil end
        end
        return cur
    end
    local list, seen = {}, {}
    local function push(sc)
        if sc and not seen[sc] and (sc:IsA("LocalScript") or sc:IsA("ModuleScript") or sc:IsA("Script")) then
            seen[sc] = true
            list[#list + 1] = sc
        end
    end
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    push(ps and ps:FindFirstChild("Client"))
    for _, rel in ipairs({
        "Controllers.CharacterReplicatorController", "Controllers.ReplicatorController", "Controllers.UIController",
        "Components.Character.CharacterComponent", "Components.Character.CharacterExtensions",
        "Components.Arena.ArenaComponent", "Components.Arena.ArenaExtensions",
        "Components.CameraSetup.CameraSetupComponent", "Components.CameraSetup.CameraSetupExtensions",
        "Components.Ragdoll.RagdollComponent", "Components.Ragdoll.RagdollExtensions",
        "CharacterReplication.Snapshots", "CharacterReplication.BufferUtils",
        "Calculate.getExplosionForces", "Calculate.smartRaycast", "FilterFunctions.defaultRaycastFilter",
        "Ragdoll.applyHitForce", "isPartHumanoidRigged", "findCharacterAncestor",
    }) do
        push(find("ReplicatedStorage.Modules." .. rel))
    end
    -- anything living inside a Bomb tool (character or backpack of any player)
    for _, plr in ipairs(Players:GetPlayers()) do
        for _, holder in ipairs({plr.Character, plr:FindFirstChildOfClass("Backpack")}) do
            local tool = holder and holder:FindFirstChild("Bomb")
            if tool then
                for _, d in ipairs(tool:GetDescendants()) do push(d) end
            end
        end
    end

    local chunks, okCount = {}, 0
    for _, sc in ipairs(list) do
        local ok, src = pcall(decompile, sc)
        local pth = (pcall(sc.GetFullName, sc)) and sc:GetFullName() or sc.Name
        chunks[#chunks + 1] = "\n\n-- ===================== " .. pth .. " [" .. sc.ClassName .. "] =====================\n"
        if ok and type(src) == "string" then
            okCount = okCount + 1
            chunks[#chunks + 1] = #src > 90000 and (src:sub(1, 90000) .. "\n-- [truncated]") or src
        else
            chunks[#chunks + 1] = "-- decompile failed: " .. tostring(src)
        end
    end
    local text = table.concat(chunks)
    local copied = false
    if setclipboard then copied = pcall(setclipboard, text) end
    local file = "SilkcoreTimebombSource.txt"
    local wrote = false
    if writefile then wrote = pcall(writefile, file, text) end
    print(string.format("[Silkcore] decompiled %d/%d scripts, %d chars", okCount, #list, #text))
    return copied, okCount, wrote and file or nil
end

-- Kill / death effects research: what the player owns, how items and effects are defined,
-- and the decompiled code that plays them. Read-only: nothing is equipped, bought or fired.
function Morph.DumpEffects()
    local out = {}
    local function add(fmt, ...) out[#out + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or fmt end
    local function find(pathStr)
        local cur = game
        for part in pathStr:gmatch("[^%.]+") do
            cur = cur and cur:FindFirstChild(part)
            if not cur then return nil end
        end
        return cur
    end
    local function attrs(i)
        local ok, a = pcall(i.GetAttributes, i)
        if not ok or next(a) == nil then return "" end
        local t = {}
        for k, v in pairs(a) do t[#t + 1] = k .. "=" .. tostring(v) end
        table.sort(t)
        return "  {" .. table.concat(t, ", ") .. "}"
    end
    local function tree(root, maxDepth, per)
        local function walk(inst, d)
            local kids = inst:GetChildren()
            for i, c in ipairs(kids) do
                if i > per then add("%s... +%d more", string.rep("  ", d + 1), #kids - per)
                break end
                local v = ""
                if c:IsA("ValueBase") then local ok, x = pcall(function() return c.Value end)
                v = " = " .. tostring(ok and x or "?") end
                add("%s%s [%s]%s%s", string.rep("  ", d + 1), c.Name, c.ClassName, v, attrs(c))
                if d < maxDepth then walk(c, d + 1) end
            end
        end
        walk(root, 0)
    end
    local function ser(v, depth, indent)
        if type(v) ~= "table" then add("%s%s", indent, tostring(v))
        return end
        if depth <= 0 then add("%s{...}", indent)
        return end
        local n = 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 80 then add("%s... more", indent)
            break end
            if type(x) == "table" then add("%s%s:", indent, tostring(k))
            ser(x, depth - 1, indent .. "  ")
            else add("%s%s = %s", indent, tostring(k), tostring(x)) end
        end
    end

    add("== PLAYER DATA (LocalPlayer.Data + leaderstats) ==")
    local data = LocalPlayer:FindFirstChild("Data")
    if data then add("attrs:%s", attrs(data))
    tree(data, 5, 80) else add("  no Data object") end

    add("")
    add("== GetData (the game's own read call, 5s timeout) ==")
    local gd = find("ReplicatedStorage.Remotes.Data.GetData")
    if gd and gd:IsA("RemoteFunction") then
        local done, res
        task.spawn(function()
            local ok, r = pcall(gd.InvokeServer, gd)
            res, done = {ok = ok, r = r}, true
        end)
        local t0 = os.clock()
        while not done and os.clock() - t0 < 5 do task.wait(0.1) end
        if not done then add("  timed out (probably needs arguments)")
        elseif not res.ok then add("  error: %s", tostring(res.r))
        else ser(res.r, 5, "  ") end
    else
        add("  remote not found")
    end

    add("")
    add("== RAGDOLL / DEATH EFFECT MODULES ==")
    local effects = find("ReplicatedStorage.Modules.Ragdoll.Effects")
    if effects then
        for _, m in ipairs(effects:GetChildren()) do add("  %s [%s]%s", m.Name, m.ClassName, attrs(m)) end
    end

    add("")
    add("== UI (shop / inventory / effect pickers) ==")
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        local shown = 0
        for _, d in ipairs(pg:GetDescendants()) do
            local n = d.Name:lower()
            if (n:find("shop", 1, true) or n:find("effect", 1, true) or n:find("inventory", 1, true) or n:find("kill", 1, true)
                or n:find("equip", 1, true) or n:find("locked", 1, true) or n:find("owned", 1, true)) and not d:IsA("UIBase") then
                shown = shown + 1
                if shown > 150 then add("  ... more")
                break end
                add("  %s [%s]%s", d:GetFullName(), d.ClassName, attrs(d))
            end
        end
    end

    -- decompiled logic
    local text
    if decompile then
        local list, seen = {}, {}
        local function push(sc) if sc and not seen[sc] and (sc:IsA("LuaSourceContainer")) then seen[sc] = true
        list[#list + 1] = sc end end
        local ps = LocalPlayer:FindFirstChild("PlayerScripts")
        push(ps and ps:FindFirstChild("Client"))
        for _, rel in ipairs({
            "Controllers.ReplicatorController", "Controllers.UIController",
            "Ragdoll.RagdollInfo", "Ragdoll.setupRagdoll", "Ragdoll.RagdollUtil", "Ragdoll.applyHitForce",
            "Components.Ragdoll.RagdollComponent", "Components.Ragdoll.RagdollExtensions",
            "Components.Character.CharacterComponent", "Components.Character.CharacterExtensions",
            "Ragdoll.Effects.Default", "Ragdoll.Effects.Explode", "Ragdoll.Effects.Burn", "Ragdoll.Effects.Classic",
            "Ragdoll.Effects.Gold", "Ragdoll.Effects.Gingerbread",
        }) do push(find("ReplicatedStorage.Modules." .. rel)) end
        for _, n in ipairs({"ItemData", "ShopData"}) do push(find("ReplicatedStorage.Assets." .. n)) end

        local chunks = {}
        for _, sc in ipairs(list) do
            local ok, src = pcall(decompile, sc)
            chunks[#chunks + 1] = "\n\n-- ===================== " .. sc:GetFullName() .. " [" .. sc.ClassName .. "] =====================\n"
            if ok and type(src) == "string" then
                chunks[#chunks + 1] = #src > 120000 and (src:sub(1, 120000) .. "\n-- [truncated]") or src
            else
                chunks[#chunks + 1] = "-- decompile failed: " .. tostring(src)
            end
        end
        text = table.concat(out, "\n") .. table.concat(chunks)
    else
        add("")
        add("(decompile unavailable: only the data sections above were dumped)")
        text = table.concat(out, "\n")
    end

    local copied = false
    if setclipboard then copied = pcall(setclipboard, text) end
    local file = "SilkcoreKillEffectsDump.txt"
    local wrote = false
    if writefile then wrote = pcall(writefile, file, text) end
    print(string.format("[Silkcore] effects dump: %d chars", #text))
    return copied, #out, wrote and file or nil
end

-- back to default proportions (the cloned avatar's scale values can make the torso huge)
function Morph.ResetScales()
    local hum = Morph.Hum()
    if not hum then return false end
    for name, v in pairs({
        BodyHeightScale = 1, BodyWidthScale = 1, BodyDepthScale = 1,
        HeadScale = 1, BodyProportionScale = 0, BodyTypeScale = 0,
    }) do
        local sv = hum:FindFirstChild(name)
        if sv and sv:IsA("NumberValue") then sv.Value = v end
    end
    return true
end

function Morph.SetHeadless(enabled)
    local char = Morph.Char()
    local head = char:FindFirstChild("Head")
    if not head then return end
    State.IsHeadless = enabled
    clearConns(bodyConns)

    local face = head:FindFirstChild("face")
    head.Transparency = enabled and 1 or 0
    if face then face.Transparency = enabled and 1 or 0 end
    for _, c in ipairs(head:GetChildren()) do
        if c:IsA("SpecialMesh") then c.Scale = enabled and Vector3.new(0.001, 0.001, 0.001) or Vector3.new(1.25, 1.25, 1.25) end
    end

    if enabled then
        bodyConns[#bodyConns + 1] = head:GetPropertyChangedSignal("Transparency"):Connect(function()
            if head.Transparency ~= 1 then head.Transparency = 1 end
        end)
        if face then
            bodyConns[#bodyConns + 1] = face:GetPropertyChangedSignal("Transparency"):Connect(function()
                if face.Transparency ~= 1 then face.Transparency = 1 end
            end)
        end
    end
    State.WardHideHead(enabled)
end

function Morph.ApplyFull(userId, notify)
    local char, hum = Morph.Char(), Morph.Hum()
    if not (char and hum) then return false end
    Morph.SaveOriginal()

    local d, model
    pcall(function() d = Players:GetHumanoidDescriptionFromUserId(userId) end)
    pcall(function() model = Players:GetCharacterAppearanceAsync(userId) end)
    if not (d or model) then
        if notify then notify("não consegui buscar esse avatar", false) end
        return false
    end

    clearAllBody()
    if notify then State.WardClearAll() end
    if d then
        pcall(function() hum:ApplyDescription(d) end)
        Morph.ApplyScales(hum, d)
        if d.HeadColor then Morph.ApplyBodyColors(char, d) end
    end
    Morph.ApplyClothing(char, d, model)
    Morph.ApplyAccessories(char, d, model)

    State.Korblox.Right, State.Korblox.Left, State.IsHeadless = false, false, false
    if d then
        -- ApplyDescription already built the legs; only fall back if the mesh did not change
        for _, side in ipairs({"Right", "Left"}) do
            local leg = tonumber(d[side .. "Leg"]) or 0
            if leg ~= 0 then
                if Morph.LegIsCustom(char, side) then
                    State.Korblox[side] = true
                    State.KorbloxMode[side] = "native"
                else
                    Morph.SetKorblox(side, true, leg)
                end
            end
        end
        local head = tonumber(d.Head) or 0
        if head == 134082579 or head == 134082512 then
            Morph.SetHeadless(true)
        elseif head ~= 0 then
            State.WardApply("Head", head)
        end
        for _, f in ipairs({"Torso", "LeftArm", "RightArm"}) do
            local pid = tonumber(d[f]) or 0
            if pid ~= 0 then State.WardApply(f, pid) end
        end
    end

    if model then model:Destroy() end
    State.LastTargetUserId = userId
    if notify then notify("avatar aplicado", true) end
    return true
end

function Morph.Reset(notify)
    local hum = Morph.Hum()
    if not hum then return end
    clearAllBody()
    State.IsHeadless, State.Korblox.Right, State.Korblox.Left, State.LastTargetUserId = false, false, false, nil
    State.KorbloxGen.Right, State.KorbloxGen.Left = State.KorbloxGen.Right + 1, State.KorbloxGen.Left + 1
    clearLeg(Morph.Char(), "Right")
    clearLeg(Morph.Char(), "Left")
    clearR6(Morph.Char(), "Right")
    clearR6(Morph.Char(), "Left")
    State.KorbloxMode = {}
    State.WardClearAll()
    if State.OriginalDescription then
        pcall(function() hum:ApplyDescription(State.OriginalDescription) end)
        if notify then notify("avatar original restaurado", true) end
    elseif notify then
        notify("sem snapshot salvo, renasça pra resetar", false)
    end
end

--------------------------------------------------------------------------------
-- WARDROBE: troca partes do corpo (R15) por ID, so no seu cliente.
-- ApplyDescription e bloqueado no cliente em jogos reais, entao a peca e montada por cima:
-- o Roblox monta uma rig com o ID (CreateHumanoidModelFromDescription) e a gente cola as
-- pecas diferentes do padrao nas partes reais, alinhadas pelas attachments de junta.
--------------------------------------------------------------------------------
local WARD = {
    {field = "Head",     label = "Cabeça",          parts = {"Head"}},
    {field = "Torso",    label = "Tronco",          parts = {"UpperTorso", "LowerTorso"}},
    {field = "LeftArm",  label = "Braço esquerdo",  parts = {"LeftUpperArm", "LeftLowerArm", "LeftHand"}},
    {field = "RightArm", label = "Braço direito",   parts = {"RightUpperArm", "RightLowerArm", "RightHand"}},
    {field = "LeftLeg",  label = "Perna esquerda",  parts = {"LeftUpperLeg", "LeftLowerLeg", "LeftFoot"}},
    {field = "RightLeg", label = "Perna direita",   parts = {"RightUpperLeg", "RightLowerLeg", "RightFoot"}},
}
local WARD_BY = {}
local wardConns = {}
for _, w in ipairs(WARD) do
    WARD_BY[w.field] = w
    wardConns[w.field] = {}
end
local Ward = {}

local function wardSig(p)
    if p:IsA("MeshPart") then
        local sa = p:FindFirstChildOfClass("SurfaceAppearance")
        return p.MeshId .. "|" .. p.TextureID .. "|" .. (sa and sa.ColorMap or "")
    end
    local m = p:FindFirstChildOfClass("SpecialMesh")
    if m then return m.MeshId .. "|" .. m.TextureId end
    return p.ClassName
end

local function wardRatio(real, base)
    local rs, bs = real.Size, base.Size
    return Vector3.new(
        bs.X > 0.001 and rs.X / bs.X or 1,
        bs.Y > 0.001 and rs.Y / bs.Y or 1,
        bs.Z > 0.001 and rs.Z / bs.Z or 1)
end

-- alinha a peca nova pela attachment da junta que prende a parte real ao resto do corpo.
-- busca primeiro no clone (attachments preservados), depois no src original como fallback.
local function wardPlace(clone, real, src, r)
    local mot = real:FindFirstChildOfClass("Motor6D")
    local attName = mot and (mot.Name .. "RigAttachment")
    local ra = attName and real:FindFirstChild(attName)
    -- preferência: attachment que está no clone (preservado); fallback: src ainda vivo
    local sa = attName and (clone:FindFirstChild(attName) or src:FindFirstChild(attName))
    if ra and sa and ra:IsA("Attachment") and sa:IsA("Attachment") then
        local rel = sa.CFrame
        local scaled = CFrame.new(rel.Position * r) * (rel - rel.Position)
        clone.CFrame = ra.WorldCFrame * scaled:Inverse()
    else
        -- sem attachment de junta: cola direto no CFrame da parte real
        clone.CFrame = real.CFrame
    end
end

local function wardPurge(char, field)
    clearConns(wardConns[field])
    for _, c in ipairs(char:GetChildren()) do
        if c.Name == "SilkcoreWard" .. field then c:Destroy() end
    end
    for _, pn in ipairs(WARD_BY[field].parts) do
        local p = char:FindFirstChild(pn)
        if p and not (field == "Head" and State.IsHeadless) then
            p.Transparency = 0
            if field == "Head" then
                local face = p:FindFirstChildOfClass("Decal")
                if face then face.Transparency = 0 end
            end
        end
    end
end

-- pega as pecas-fonte: primeiro pela rig que o Roblox monta, depois direto pelo asset
local function wardSources(def, id)
    DefaultRig = DefaultRig or makeRig(Instance.new("HumanoidDescription"))
    local d = Instance.new("HumanoidDescription")
    d[def.field] = id
    local rig = makeRig(d)
    local srcs = {}
    if rig then
        local changedAny = false
        for _, pn in ipairs(def.parts) do
            srcs[pn] = rig:FindFirstChild(pn)
            local base = DefaultRig and DefaultRig:FindFirstChild(pn)
            if srcs[pn] and base and wardSig(srcs[pn]) ~= wardSig(base) then
                changedAny = true
            end
        end
        if changedAny then return srcs, rig, "rig" end
        -- a rota rig voltou o padrão sem trocar nada (ID não resolveu via
        -- CreateHumanoidModelFromDescription, comum em cabeças tipo Korblox).
        -- descarta e tenta puxar a peça direto do asset.
        rig:Destroy()
        srcs = {}
    end
    local ok, objs = pcall(game.GetObjects, game, "rbxassetid://" .. tostring(id))
    if not (ok and objs) or #objs == 0 then return nil, nil, "asset não carregou" end
    local holder = Instance.new("Folder")
    for _, o in ipairs(objs) do o.Parent = holder end
    local first
    for _, d2 in ipairs(holder:GetDescendants()) do
        if d2:IsA("BasePart") then
            first = first or d2
            if table.find(def.parts, d2.Name) then srcs[d2.Name] = d2 end
        end
    end
    if next(srcs) == nil and first and #def.parts == 1 then srcs[def.parts[1]] = first end
    return srcs, holder, "asset"
end

local function wardBuild(char, def, id)
    local srcs, owner, how = wardSources(def, id)
    if not srcs then return false, how end
    local folder = Instance.new("Folder")
    folder.Name = "SilkcoreWard" .. def.field
    folder.Parent = char
    local conns = wardConns[def.field]
    local made, native = 0, 0
    for _, pn in ipairs(def.parts) do
        local real, src = char:FindFirstChild(pn), srcs[pn]
        local base = DefaultRig and DefaultRig:FindFirstChild(pn)
        if real and src and real:IsA("BasePart") and src:IsA("BasePart") then
            local differs = (not base) or wardSig(src) ~= wardSig(base)
            if differs and wardSig(real) == wardSig(src) then
                native = native + 1 -- o proprio jogo ja mostra essa malha
            elseif differs then
                local clone = src:Clone()
                -- remover vínculos de rig; PRESERVAR Attachments (usados pra posicionamento
                -- em wardPlace), ParticleEmitter, Fire, Smoke, Beam, Trail (efeitos visuais)
                for _, c in ipairs(clone:GetChildren()) do
                    if c:IsA("Motor6D") or c:IsA("Weld") or c:IsA("WeldConstraint")
                        or c:IsA("LuaSourceContainer") then
                        c:Destroy()
                    end
                end
                clone.Name = "SW_" .. pn
                clone.Anchored = false
                clone.Transparency = (def.field == "Head" and State.IsHeadless) and 1 or 0
                local r = wardRatio(real, base or src)
                clone.Size = Vector3.new(src.Size.X * r.X, src.Size.Y * r.Y, src.Size.Z * r.Z)
                wardPlace(clone, real, src, r)
                -- sanitize apenas a BasePart raiz — não desce nos filhos pra não matar efeitos
                clone.CanCollide  = false
                clone.CanTouch    = false
                clone.CanQuery    = false
                clone.Massless    = true
                clone.Parent = folder
                local w = Instance.new("WeldConstraint")
                w.Part0, w.Part1 = clone, real
                w.Parent = clone
                lockTransparency(conns, real, 1)
                if def.field == "Head" then
                    local face = real:FindFirstChildOfClass("Decal")
                    if face then lockTransparency(conns, face, 1) end
                end
                made = made + 1
            end
        end
    end
    if owner then owner:Destroy() end
    if made == 0 and native == 0 then
        folder:Destroy()
        clearConns(conns)
        return false, "esse ID não troca nada nessa peça (igual ao padrão?)"
    end
    if made == 0 then folder:Destroy() end
    return true, (native > 0 and "nativo" or how) .. " · " .. (made + native) .. " peça(s)"
end

function Ward.Apply(field, id)
    local def = WARD_BY[field]
    if not def then return false, "slot inválido" end
    id = tonumber(id)
    if not id or id <= 0 then return false, "ID inválido" end
    local hum = Morph.Hum()
    if not hum then return false, "humanoid não encontrado" end
    if hum.RigType ~= Enum.HumanoidRigType.R15 and field ~= "Head" then
        return false, "só funciona em R15 (Cabeça funciona em R15 e R6)"
    end
    local char = Morph.Char()
    Morph.SaveOriginal()
    if field == "LeftLeg" or field == "RightLeg" then
        local side = (field == "LeftLeg") and "Left" or "Right"
        State.Korblox[side] = false
        clearLeg(char, side)
    end
    wardPurge(char, field)
    local ok, info = wardBuild(char, def, id)
    if not ok then
        if State.Wardrobe[field] ~= nil then
            State.Wardrobe[field] = nil
            State.OnWardChange(field, nil)
        end
        return false, info
    end
    State.Wardrobe[field] = id
    State.OnWardChange(field, id)
    State.Touch()
    return true, info
end

function Ward.Clear(field)
    if not WARD_BY[field] then return false end
    wardPurge(Morph.Char(), field)
    State.Wardrobe[field] = nil
    State.OnWardChange(field, nil)
    State.Touch()
    return true
end

function Ward.ClearAll()
    for _, w in ipairs(WARD) do
        if State.Wardrobe[w.field] ~= nil or Morph.Char():FindFirstChild("SilkcoreWard" .. w.field) then
            Ward.Clear(w.field)
        end
    end
end

-- reaplica tudo que esta salvo; devolve quantos deram certo
function Ward.RestoreAll()
    local n = 0
    local list = {}
    for field, id in pairs(State.Wardrobe) do list[#list + 1] = {field, id} end
    for _, it in ipairs(list) do
        local ok = false
        local okc, res = pcall(Ward.Apply, it[1], it[2])
        if okc and res then ok = true end
        if ok then n = n + 1 end
        task.wait(0.1)
    end
    return n
end

-- quando o jogador renasce as pecas somem junto com o personagem antigo
function Ward.OnRespawn()
    for _, list in pairs(wardConns) do clearConns(list) end
end

-- headless por cima: some tambem com a cabeca trocada
function Ward.HideHead(hidden)
    local char = LocalPlayer.Character
    local folder = char and char:FindFirstChild("SilkcoreWardHead")
    if not folder then return end
    for _, c in ipairs(folder:GetChildren()) do
        if c:IsA("BasePart") then c.Transparency = hidden and 1 or 0 end
    end
end

State.WardApply = Ward.Apply
State.WardClearAll = Ward.ClearAll
State.WardHideHead = Ward.HideHead
State.WardrobeReapply = function()
    task.spawn(function()
        task.wait(0.4)
        Ward.RestoreAll()
    end)
end


do
    local function touching(name)
        local orig = Morph[name]
        Morph[name] = function(...)
            local a, b = orig(...)
            State.Touch()
            return a, b
        end
    end
    touching("SetKorblox")
    touching("SetHeadless")
    touching("ApplyFull")
    touching("Reset")
end

track(LocalPlayer.CharacterAdded:Connect(function(newChar)
    clearAllBody()
    Ward.OnRespawn()
    newChar:WaitForChild("Humanoid", 10)
    newChar:WaitForChild("HumanoidRootPart", 10)
    task.wait(1.0)
    local wasR, wasL, wasH = State.Korblox.Right, State.Korblox.Left, State.IsHeadless
    if State.AutoReapplyOnRespawn and State.LastTargetUserId then
        Morph.ApplyFull(State.LastTargetUserId)
    end
    if wasH then Morph.SetHeadless(true) end
    State.WardrobeReapply()
    State.CatalogReapply()
    State.ColorsReapply()
    State.FxReapply()
    if wasR then Morph.SetKorblox("Right", true) end
    if wasL then Morph.SetKorblox("Left", true) end
    State.Touch()
end))

--------------------------------------------------------------------------------
-- THEME + UI HELPERS
--------------------------------------------------------------------------------
local T = {
    Bg      = Color3.fromRGB(10, 8, 11),
    Panel   = Color3.fromRGB(16, 13, 17),
    Card    = Color3.fromRGB(25, 21, 27),
    Card2   = Color3.fromRGB(34, 29, 37),
    Card3   = Color3.fromRGB(46, 40, 50),
    Stroke  = Color3.fromRGB(44, 38, 47),
    Stroke2 = Color3.fromRGB(72, 63, 76),
    Accent  = Color3.fromRGB(255, 58, 96),     -- carmim (Silk Core)
    Accent2 = Color3.fromRGB(255, 176, 84),
    Text    = Color3.fromRGB(240, 233, 230),
    Sub     = Color3.fromRGB(150, 140, 148),
    Faint   = Color3.fromRGB(96, 88, 98),
    Good    = Color3.fromRGB(82, 214, 140),
    Bad     = Color3.fromRGB(255, 92, 92),
}

local THEMES = {
    {id = "carmim",   name = "Carmim",   a = Color3.fromRGB(255, 58, 96),   b = Color3.fromRGB(255, 176, 84)},
    {id = "ouro",     name = "Ouro",     a = Color3.fromRGB(255, 190, 64),  b = Color3.fromRGB(255, 112, 64)},
    {id = "jade",     name = "Jade",     a = Color3.fromRGB(46, 214, 150),  b = Color3.fromRGB(196, 255, 124)},
    {id = "gelo",     name = "Gelo",     a = Color3.fromRGB(86, 190, 255),  b = Color3.fromRGB(196, 242, 255)},
    {id = "orquidea", name = "Orquídea", a = Color3.fromRGB(190, 112, 255), b = Color3.fromRGB(255, 120, 200)},
    {id = "custom",   name = "Personalizado", a = Color3.fromRGB(236, 236, 240), b = Color3.fromRGB(160, 160, 172)},
}

-- papeis de fonte: display (titulos), corpo, negrito e mono (dados, ids, teclas)
local F = {
    Body    = Enum.Font.GothamMedium,
    Bold    = Enum.Font.GothamBold,
    Black   = Enum.Font.GothamBlack,
    Mono    = Enum.Font.RobotoMono,
    Display = Enum.Font.Michroma,
}
-- o codigo antigo (aba Timebomb) pede BuilderSans: mapeia pro mesmo conjunto, um pouco menor
local New
do
local FONT_MAP = {
    [Enum.Font.BuilderSans] = F.Body,
    [Enum.Font.BuilderSansMedium] = F.Body,
    [Enum.Font.BuilderSansBold] = F.Bold,
    [Enum.Font.BuilderSansExtraBold] = F.Black,
}
    function New(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        if k == "Font" and FONT_MAP[v] then
            o.Font = FONT_MAP[v]
        elseif k == "TextSize" and props.Font ~= nil and FONT_MAP[props.Font] then
            o.TextSize = math.max(8, math.floor(v * 0.92 + 0.5))
        else
            o[k] = v
        end
    end
    o.Parent = parent
        return o
    end
end
local function Round(o, r)
    return New("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o)
end
local function Stroke(o, c, t)
    return New("UIStroke", {Color = c or T.Stroke, Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, o)
end
local ANIM = {speed = 1, reduce = false}
local function Tween(o, t, props)
    TweenService:Create(o, TweenInfo.new(t * ANIM.speed, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), props):Play()
end
local function TweenEx(o, t, style, props)
    TweenService:Create(o, TweenInfo.new(t * ANIM.speed, style, Enum.EasingDirection.Out), props):Play()
end

-- cores de accent registradas: trocar o tema anima todas de uma vez
local accBinds = setmetatable({}, {__mode = "k"})
local gradBinds = setmetatable({}, {__mode = "k"})
local themeFns = {}
local function bindAcc(inst, prop, which, noSet)
    local m = accBinds[inst]
    if not m then
        m = {}
        accBinds[inst] = m
    end
    m[prop] = which or "Accent"
    if not noSet then inst[prop] = T[which or "Accent"] end
    return inst
end
local function unbindAcc(inst, prop)
    local m = accBinds[inst]
    if m then m[prop] = nil end
end
local function onTheme(fn)
    themeFns[#themeFns + 1] = fn
end
local function Grad(o, rot)
    local g = New("UIGradient", {Color = ColorSequence.new(T.Accent, T.Accent2), Rotation = rot or 0}, o)
    gradBinds[g] = true
    return g
end
local textOn
do
    local function lum(c)
        return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
    end
    function textOn(c)
        if lum(c) > 0.62 then return Color3.fromRGB(18, 14, 18) end
        return Color3.new(1, 1, 1)
    end
end
local function SetCustomAccent(c)
    local h, s, v = c:ToHSV()
    local th = THEMES[#THEMES]
    th.a = c
    th.b = Color3.fromHSV((h + 0.08) % 1, math.clamp(s * 0.8, 0, 1), math.clamp(v + 0.1, 0, 1))
end
local function SetTheme(id, instant)
    for _, th in ipairs(THEMES) do
        if th.id == id then
            T.Accent, T.Accent2 = th.a, th.b
            for inst, m in pairs(accBinds) do
                if inst.Parent then
                    for prop, which in pairs(m) do
                        if instant then inst[prop] = T[which] else Tween(inst, 0.4, {[prop] = T[which]}) end
                    end
                end
            end
            for g in pairs(gradBinds) do
                if g.Parent then g.Color = ColorSequence.new(T.Accent, T.Accent2) end
            end
            for _, fn in ipairs(themeFns) do pcall(fn) end
            return true
        end
    end
    return false
end

-- registro de eventos e erros: aparece na aba Config e vai pro clipboard quando algo quebra
local Log = {lines = {}, onChange = nil}
function Log.notify(_text, _ok) end -- trocado pelo Toast quando a UI existe
function Log.add(level, msg)
    local line = string.format("%s  %-5s %s", os.date("%H:%M:%S"), level, tostring(msg))
    Log.lines[#Log.lines + 1] = line
    if #Log.lines > 300 then table.remove(Log.lines, 1) end
    if Log.onChange then Log.onChange() end
end
local upperPT
do
    local MAP = {["ç"] = "Ç", ["ã"] = "Ã", ["õ"] = "Õ", ["á"] = "Á", ["à"] = "À", ["â"] = "Â", ["é"] = "É", ["ê"] = "Ê",
        ["í"] = "Í", ["ó"] = "Ó", ["ô"] = "Ô", ["ú"] = "Ú", ["ü"] = "Ü"}
    function upperPT(s)
        local r = s:gsub("[\195][\128-\191]", function(c) return MAP[c] or c end)
        return string.upper(r)
    end
end
local Safe
do
local lastErrAt = -10
function Safe(fn, tag)
    return function(...)
        local args = table.pack(...)
        local ok, err = xpcall(function()
            return fn(table.unpack(args, 1, args.n))
        end, function(e)
            return debug.traceback(tostring(e), 2)
        end)
        if not ok then
            Log.add("ERRO", (tag or "callback") .. ": " .. tostring(err))
            warn("[Silkcore] " .. tostring(err))
            if os.clock() - lastErrAt > 2 then
                lastErrAt = os.clock()
                if setclipboard then pcall(setclipboard, tostring(err)) end
                Log.notify("erro em " .. tostring(tag or "callback") .. " (copiado)", false)
            end
        end
    end
end
end

--------------------------------------------------------------------------------
-- PERSIST: salva as opcoes do menu em workspace/SilkcoreSettings.json
-- (a aba Timebomb nao entra: Persist.On fica false antes dela ser criada)
--------------------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local SAVE_FILE = "SilkcoreSettings.json"
local Persist = {Data = {}, On = true, Scope = "", Loading = false, Dirty = false, Pending = false}

do
    local ok, raw = pcall(function()
        if isfile and readfile and isfile(SAVE_FILE) then return readfile(SAVE_FILE) end
        return nil
    end)
    if ok and type(raw) == "string" and #raw > 1 then
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if ok2 and type(data) == "table" then Persist.Data = data end
    end
end

function Persist.Get(key, default)
    local v = Persist.Data[key]
    if v == nil then return default end
    return v
end

function Persist.Flush()
    if not (Persist.Dirty and writefile) then return end
    Persist.Dirty = false
    local ok, json = pcall(HttpService.JSONEncode, HttpService, Persist.Data)
    if ok then pcall(writefile, SAVE_FILE, json) end
end

function Persist.Set(key, value)
    if Persist.Loading then return end
    Persist.Data[key] = value
    Persist.Dirty = true
    if Persist.Pending then return end
    Persist.Pending = true
    task.delay(0.6, function() -- junta varias mudancas (slider arrastando) numa escrita so
        Persist.Pending = false
        Persist.Flush()
    end)
end

track(Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then Persist.Flush() end
end))
do
    local ct = Persist.Get("cfg:custom", nil)
    if type(ct) == "table" and tonumber(ct[1]) and tonumber(ct[2]) and tonumber(ct[3]) then
        SetCustomAccent(Color3.fromRGB(math.clamp(ct[1], 0, 255), math.clamp(ct[2], 0, 255), math.clamp(ct[3], 0, 255)))
    end
    local savedTheme = Persist.Get("cfg:theme", nil)
    if type(savedTheme) == "string" then SetTheme(savedTheme, true) end
end

--------------------------------------------------------------------------------
-- AIMLOCK (sticky: locks on press, stays until the target dies)
--------------------------------------------------------------------------------
local Aim = {
    Enabled   = false,
    Key       = Enum.UserInputType.MouseButton2, -- hold to lock (rebind in the menu)
    PartName  = "Head",
    FOV       = 220,   -- px radius around the cursor, used ONLY to pick the first target
    Smooth    = 0.25,  -- 0 = instant snap, higher = softer
    Predict   = 0,     -- seconds of target velocity to lead
    TeamCheck = true,
    WallCheck = false,
    ShowFOV   = true,
    Player    = nil,
    Char      = nil,   -- the exact character we locked (a respawn is a NEW character => lock ends)
    Holding   = false,
    Binding   = false,
    OnStatus  = function(_text) end,
    OnBind    = function() end,
    Filter    = nil, -- opcional; o Timebomb usa isso pro "holder-only"
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function liveHumanoid(char)
    if not (char and char.Parent) then return nil end
    local h = char:FindFirstChildOfClass("Humanoid")
    if h and h.Health > 0 then return h end
    return nil
end

local function aimPart(char)
    return char:FindFirstChild(Aim.PartName)
        or (Aim.PartName == "UpperTorso" and char:FindFirstChild("Torso"))
        or char:FindFirstChild("HumanoidRootPart")
end

local function isEnemy(plr)
    if plr == LocalPlayer then return false end
    if Aim.Filter and not Aim.Filter(plr) then return false end
    if not Aim.TeamCheck then return true end
    return not (plr.Team and plr.Team == LocalPlayer.Team)
end

local function visible(cam, part, char)
    local filter = {char}
    local mine = LocalPlayer.Character
    if mine then filter[2] = mine end
    rayParams.FilterDescendantsInstances = filter
    return Workspace:Raycast(cam.CFrame.Position, part.Position - cam.CFrame.Position, rayParams) == nil
end

-- runs ONCE per key press, never per frame
local function pickTarget()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local mouse = UserInputService:GetMouseLocation()
    local bestPlr, bestChar, bestD = nil, nil, Aim.FOV
    for _, plr in ipairs(Players:GetPlayers()) do
        if isEnemy(plr) then
            local char = plr.Character
            if liveHumanoid(char) then
                local part = aimPart(char)
                if part then
                    local v, onScreen = cam:WorldToViewportPoint(part.Position)
                    if onScreen then
                        local d = (Vector2.new(v.X, v.Y) - mouse).Magnitude
                        if d < bestD and (not Aim.WallCheck or visible(cam, part, char)) then
                            bestPlr, bestChar, bestD = plr, char, d
                        end
                    end
                end
            end
        end
    end
    return bestPlr, bestChar
end

local bound = false
local function unbindAim()
    if bound then
        bound = false
        RunService:UnbindFromRenderStep(AIM_BIND)
    end
end

local function stepAim(dt)
    local char = Aim.Char
    if not liveHumanoid(char) then
        -- target died / left: drop the lock and idle until the key is released and pressed again
        unbindAim()
        Aim.Player, Aim.Char = nil, nil
        Aim.OnStatus("Target down - release to pick another")
        return
    end
    local part, cam = aimPart(char), Workspace.CurrentCamera
    if not (part and cam) then return end

    local pos = part.Position
    if Aim.Predict > 0 then pos = pos + part.AssemblyLinearVelocity * Aim.Predict end
    local cf = cam.CFrame
    local goal = CFrame.lookAt(cf.Position, pos)
    if Aim.Smooth <= 0.001 then
        cam.CFrame = goal
    else
        cam.CFrame = cf:Lerp(goal, 1 - Aim.Smooth ^ (dt * 60)) -- framerate independent
    end
end

local function bindAim()
    if bound then return end
    bound = true
    -- one step, only alive while holding the key on a live target; runs after Roblox's camera
    RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 1, stepAim)
end

local function keyMatches(i)
    local k = Aim.Key
    if k.EnumType == Enum.KeyCode then return i.KeyCode == k end
    return i.UserInputType == k
end

local function releaseAim()
    Aim.Holding = false
    unbindAim()
    Aim.Player, Aim.Char = nil, nil
    Aim.OnStatus("Idle")
end

track(UserInputService.InputBegan:Connect(function(i, processed)
    if Aim.Binding then
        local t = i.UserInputType
        if t == Enum.UserInputType.Keyboard then
            if i.KeyCode ~= Enum.KeyCode.Escape then Aim.Key = i.KeyCode end
        elseif t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
            Aim.Key = t
        else
            return
        end
        Aim.Binding = false
        Aim.OnBind()
        return
    end
    if processed or not Aim.Enabled or Aim.Holding or not keyMatches(i) then return end

    Aim.Holding = true
    local plr, char = pickTarget()
    if plr then
        Aim.Player, Aim.Char = plr, char
        bindAim()
        Aim.OnStatus("Locked: " .. plr.DisplayName)
    else
        Aim.OnStatus("No target in FOV")
    end
end))

track(UserInputService.InputEnded:Connect(function(i)
    if Aim.Holding and keyMatches(i) then releaseAim() end
end))

-- FOV ring (event driven, no per-frame loop)
local FovGui = New("ScreenGui", {
    Name = FOV_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)
local FovRing = New("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Visible = false,
    Size = UDim2.fromOffset(Aim.FOV * 2, Aim.FOV * 2), Position = UDim2.fromScale(0.5, 0.5),
}, FovGui)
Round(FovRing, 9999)
bindAcc(Stroke(FovRing, T.Accent, 1.5), "Color")

local function refreshFov()
    FovRing.Visible = Aim.Enabled and Aim.ShowFOV
    FovRing.Size = UDim2.fromOffset(Aim.FOV * 2, Aim.FOV * 2)
    local m = UserInputService:GetMouseLocation()
    FovRing.Position = UDim2.fromOffset(m.X, m.Y)
end
refreshFov()

track(UserInputService.InputChanged:Connect(function(i)
    if FovRing.Visible and i.UserInputType == Enum.UserInputType.MouseMovement then
        local m = UserInputService:GetMouseLocation()
        FovRing.Position = UDim2.fromOffset(m.X, m.Y)
    end
end))

--------------------------------------------------------------------------------
-- MISC MODS: stretched screen + multi air-jump
--------------------------------------------------------------------------------
local Mods = {
    Stretch = {Enabled = false, Y = 0.65},      -- <1 squashes the picture vertically = "stretched res"
    DJ      = {Enabled = false, Max = 1, Used = 0, Last = 0},
}

-- runs AFTER the aimlock step (Camera+1) so aim math always sees the un-stretched camera.
-- Only the Y axis of the rotation is scaled, so look direction (and the default camera
-- script's reads of it) stay untouched.
local function stepStretch()
    local cam = Workspace.CurrentCamera
    if not cam then return end
    cam.CFrame = cam.CFrame * CFrame.new(0, 0, 0, 1, 0, 0, 0, Mods.Stretch.Y, 0, 0, 0, 1)
end

function Mods.SetStretch(on)
    Mods.Stretch.Enabled = on
    pcall(RunService.UnbindFromRenderStep, RunService, STRETCH_BIND)
    if on then
        RunService:BindToRenderStep(STRETCH_BIND, Enum.RenderPriority.Camera.Value + 2, stepStretch)
    end
end

local function jumpVelocity(hum)
    if hum.UseJumpPower then return hum.JumpPower end
    return math.sqrt(2 * Workspace.Gravity * hum.JumpHeight)
end

-- JumpRequest fires per press. Grounded press = refill the air-jump budget (the engine
-- does the normal jump); airborne press = spend one and kick the root upward.
track(UserInputService.JumpRequest:Connect(function()
    local dj = Mods.DJ
    if not dj.Enabled then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and root) or hum.Health <= 0 then return end

    local st = hum:GetState()
    if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then
        if dj.Used >= dj.Max or os.clock() - dj.Last < 0.12 then return end
        dj.Used, dj.Last = dj.Used + 1, os.clock()
        local v = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(v.X, jumpVelocity(hum), v.Z)
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    else
        dj.Used = 0
    end
end))

--------------------------------------------------------------------------------
-- TIMEBOMB DUELS ENGINE
-- From the dump: R6 rig, the client streams its own CFrame (CharacterReplicator.UpdateCFrame),
-- the bomb holder carries a Tool named "Bomb", arenas expose BombWalkSpeed / JumpingEnabled.
-- Speed is a tiny per-frame position nudge on top of whatever WalkSpeed the game currently
-- gives you (20 while holding the bomb), with a slow wobble so it never reads as a flat constant.
--------------------------------------------------------------------------------
local TB = {
    Speed = {Enabled = false, Boost = 0.12},   -- fraction on top of current WalkSpeed
    Turn = false, FaceCam = false, Stop = false,
    Sens = {Enabled = false, Mult = 1.5, Orig = nil},
    Fov = {Enabled = false, Value = 90, Orig = nil},
    ESP = {Holder = false, All = false, Objs = {}, Token = 0},
    HolderOnly = false,
    OnStatus = function(_text, _hot) end,
}
local MAX_BOOST = 0.45

local function bombHolder()
    for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        local t = ch and ch:FindFirstChild("Bomb")
        if t and t:IsA("Tool") then return plr end
    end
    return nil
end
TB.HolderOf = bombHolder
Aim.Filter = function(plr) return (not TB.HolderOnly) or bombHolder() == plr end

-- movement ---------------------------------------------------------------
local BAD_STATES = {
    [Enum.HumanoidStateType.Physics] = true, [Enum.HumanoidStateType.Ragdoll] = true,
    [Enum.HumanoidStateType.FallingDown] = true, [Enum.HumanoidStateType.PlatformStanding] = true,
    [Enum.HumanoidStateType.Seated] = true, [Enum.HumanoidStateType.Dead] = true,
}
local moveConn

local function moveStep(dt)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and root) or hum.Health <= 0 or BAD_STATES[hum:GetState()] then return end

    local md = hum.MoveDirection
    local moving = md.Magnitude > 0.05

    if TB.FaceCam or TB.Turn then
        if hum.AutoRotate then hum.AutoRotate = false end
        if TB.FaceCam then
            local cam = Workspace.CurrentCamera
            local look = cam and cam.CFrame.LookVector
            if look and (look.X ~= 0 or look.Z ~= 0) then
                root.CFrame = CFrame.lookAt(root.Position, root.Position + Vector3.new(look.X, 0, look.Z))
            end
        elseif moving then
            root.CFrame = CFrame.lookAt(root.Position, root.Position + Vector3.new(md.X, 0, md.Z))
        end
    end

    if hum.FloorMaterial == Enum.Material.Air then return end
    if moving then
        if TB.Speed.Enabled then
            local wobble = 1 + math.noise(os.clock() * 0.8, 17.3) * 0.6   -- slow +-30% drift
            local boost = math.clamp(TB.Speed.Boost * wobble, 0, MAX_BOOST)
            root.CFrame = root.CFrame + md * (hum.WalkSpeed * boost * dt)
        end
    elseif TB.Stop then
        local v = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
    end
end

function TB.RefreshMove()
    local need = TB.Speed.Enabled or TB.Turn or TB.FaceCam or TB.Stop
    if need and not moveConn then
        moveConn = RunService.Heartbeat:Connect(moveStep)
    elseif not need and moveConn then
        moveConn:Disconnect()
        moveConn = nil
    end
    if not (TB.Turn or TB.FaceCam) then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate = true end
    end
end

-- camera -----------------------------------------------------------------
local okUGS, UGS = pcall(function() return UserSettings():GetService("UserGameSettings") end)

function TB.ApplySens()
    if not (okUGS and UGS) then return end
    if TB.Sens.Enabled then
        TB.Sens.Orig = TB.Sens.Orig or UGS.MouseSensitivity
        UGS.MouseSensitivity = TB.Sens.Orig * TB.Sens.Mult
    elseif TB.Sens.Orig then
        UGS.MouseSensitivity = TB.Sens.Orig
        TB.Sens.Orig = nil
    end
end

function TB.SetFov(on)
    TB.Fov.Enabled = on
    pcall(RunService.UnbindFromRenderStep, RunService, FOV_BIND)
    local cam = Workspace.CurrentCamera
    if on then
        TB.Fov.Orig = TB.Fov.Orig or (cam and cam.FieldOfView)
        RunService:BindToRenderStep(FOV_BIND, Enum.RenderPriority.Camera.Value + 3, function()
            local c = Workspace.CurrentCamera
            if c then c.FieldOfView = TB.Fov.Value end
        end)
    elseif TB.Fov.Orig then
        if cam then cam.FieldOfView = TB.Fov.Orig end
        TB.Fov.Orig = nil
    end
end

-- ESP (Highlights live in a private folder, client only) -------------------
local espFolder = New("Folder", {Name = ESP_NAME}, guiParent)

local function espClear()
    for plr, hl in pairs(TB.ESP.Objs) do hl:Destroy()
    TB.ESP.Objs[plr] = nil end
end

local function espStep()
    local holder = bombHolder()
    local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if holder == LocalPlayer then
        TB.OnStatus("YOU have the bomb", true)
    elseif holder then
        local hr = holder.Character and holder.Character:FindFirstChild("HumanoidRootPart")
        local d = (hr and myRoot) and math.floor((hr.Position - myRoot.Position).Magnitude) or 0
        TB.OnStatus(string.format("%s  (%d studs)", holder.Name, d), true)
    else
        TB.OnStatus("nobody (no round)", false)
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local ch = plr.Character
            local isH = plr == holder
            local want = ch and ((TB.ESP.Holder and isH) or TB.ESP.All)
            local hl = TB.ESP.Objs[plr]
            if want then
                if not hl or not hl.Parent then
                    hl = New("Highlight", {DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, OutlineColor = Color3.new(1, 1, 1)}, espFolder)
                    TB.ESP.Objs[plr] = hl
                end
                hl.Adornee = ch
                hl.FillColor = isH and Color3.fromRGB(255, 60, 60) or T.Accent
                hl.FillTransparency = isH and 0.3 or 0.85
            elseif hl then
                hl:Destroy()
                TB.ESP.Objs[plr] = nil
            end
        end
    end
    for plr, hl in pairs(TB.ESP.Objs) do
        if not plr.Parent then hl:Destroy()
        TB.ESP.Objs[plr] = nil end
    end
end

function TB.RefreshESP()
    TB.ESP.Token = TB.ESP.Token + 1
    local token = TB.ESP.Token
    if not (TB.ESP.Holder or TB.ESP.All) then
        espClear()
        TB.OnStatus("enable an ESP to track", false)
        return
    end
    task.spawn(function()
        while TB.ESP.Token == token and (TB.ESP.Holder or TB.ESP.All) do
            pcall(espStep)
            task.wait(0.2)
        end
    end)
end

function TB.Cleanup()
    TB.ESP.Token = TB.ESP.Token + 1
    espClear()
    if espFolder then espFolder:Destroy() end
    if moveConn then moveConn:Disconnect()
    moveConn = nil end
    TB.Speed.Enabled, TB.Turn, TB.FaceCam, TB.Stop = false, false, false, false
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.AutoRotate = true end
    TB.Sens.Enabled = false
    TB.ApplySens()
    TB.SetFov(false)
    Aim.Filter = nil
end

--------------------------------------------------------------------------------
-- MENU
--------------------------------------------------------------------------------
local LAY = {W = 800, H = 630, TOP = 52, BODY_Y = 60, BODY_H = 530, RAIL = 188, PANEL_X = 212, Perf = {fps = {}, ping = {}, mem = 0}}

local lo = 0
local function nextOrder()
    lo = lo + 1
    return lo
end

local function Label(parent, text, size, color, font, xAlign, pos, sz)
    return New("TextLabel", {
        Text = text, Font = font or F.Body, TextSize = size or 13, TextColor3 = color or T.Text,
        TextXAlignment = xAlign or Enum.TextXAlignment.Left, BackgroundTransparency = 1,
        Position = pos or UDim2.fromOffset(14, 0), Size = sz or UDim2.new(0.6, 0, 1, 0),
    }, parent)
end

-- digita o texto letra por letra (cancela se outro texto chegar no mesmo label)
local typeTok = setmetatable({}, {__mode = "k"})
local function TypeText(label, full, speed)
    typeTok[label] = (typeTok[label] or 0) + 1
    local tok = typeTok[label]
    task.spawn(function()
        local n = utf8.len(full) or #full
        for i = 1, n do
            if typeTok[label] ~= tok or not label.Parent then return end
            label.Text = full:sub(1, (utf8.offset(full, i + 1) or (#full + 1)) - 1)
            task.wait(speed or 0.014)
        end
    end)
end

--------------------------------------------------------------------------------
-- GLITCH RGB: separacao de canais (vermelho/ciano), faixa deslocada e troca de letras
--------------------------------------------------------------------------------
local GlitchText
do
local GLYPHS = {"#", "%", "&", "@", "$", "0", "1", "<", ">", "/", "|", "+"}
local function scrambleText(s, n)
    local chars = {}
    for _, cp in utf8.codes(s) do chars[#chars + 1] = utf8.char(cp) end
    for _ = 1, n do
        local i = math.random(1, #chars)
        if chars[i] ~= " " then chars[i] = GLYPHS[math.random(1, #GLYPHS)] end
    end
    return table.concat(chars)
end

local Glitchers = {}
function GlitchText(parent, text, size, pos, boxSize, xAlign, font)
    local root = New("Frame", {Size = boxSize, Position = pos, BackgroundTransparency = 1, BorderSizePixel = 0}, parent)
    local align = xAlign or Enum.TextXAlignment.Left
    local function mk(col, tr, z)
        return New("TextLabel", {
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = text, Font = font or F.Display,
            TextSize = size, TextColor3 = col, TextTransparency = tr, ZIndex = z, TextXAlignment = align,
        }, root)
    end
    local red = mk(Color3.fromRGB(255, 40, 70), 1, 1)
    local cyan = mk(Color3.fromRGB(0, 230, 255), 1, 1)
    local main = mk(Color3.new(1, 1, 1), 0, 3)
    local mg = New("UIGradient", {Rotation = 0}, main)
    local function paintGrad()
        mg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
            ColorSequenceKeypoint.new(0.5, T.Text),
            ColorSequenceKeypoint.new(1, T.Accent),
        })
    end
    paintGrad()
    onTheme(paintGrad)
    local slice = New("Frame", {
        Size = UDim2.fromScale(1, 0.3), Position = UDim2.fromScale(0, 0.35), BackgroundTransparency = 1,
        ClipsDescendants = true, ZIndex = 4, Visible = false,
    }, root)
    local sliceTxt = New("TextLabel", {
        Size = UDim2.fromScale(1, 1 / 0.3), Position = UDim2.fromScale(0, -0.35 / 0.3), BackgroundTransparency = 1,
        Text = text, Font = font or F.Display, TextSize = size, TextColor3 = T.Accent, ZIndex = 4, TextXAlignment = align,
    }, slice)
    bindAcc(sliceTxt, "TextColor3")
    local g = {
        root = root, text = text, red = red, cyan = cyan, main = main, slice = slice, sliceTxt = sliceTxt,
        timer = 0, nextAt = 1.2 + math.random() * 2, burst = 0, scr = 0, intro = 0, introDur = 1,
    }
    function g.SetAll(s)
        red.Text, cyan.Text, main.Text = s, s, s
    end
    function g.Rest()
        red.Position, cyan.Position = UDim2.new(), UDim2.new()
        red.TextTransparency, cyan.TextTransparency = 1, 1
        slice.Visible = false
        g.SetAll(g.text)
    end
    function g.Burst(d)
        g.burst = d or 0.3
    end
    function g.Intro(d)
        g.intro, g.introDur = d or 0.8, d or 0.8
    end
    Glitchers[#Glitchers + 1] = g
    return g
end

track(RunService.Heartbeat:Connect(function(dt)
    for i = #Glitchers, 1, -1 do
        local g = Glitchers[i]
        if not g.root.Parent then
            table.remove(Glitchers, i)
        else
            g.timer = g.timer + dt
            if g.intro > 0 then
                g.intro = g.intro - dt
                local p = 1 - math.max(g.intro, 0) / g.introDur
                local n = utf8.len(g.text) or #g.text
                local shown = math.floor(p * n)
                local head = g.text:sub(1, (utf8.offset(g.text, shown + 1) or (#g.text + 1)) - 1)
                local tail = g.text:sub(#head + 1)
                g.SetAll(head .. scrambleText(tail, #tail * 2))
                g.red.TextTransparency, g.cyan.TextTransparency = 0.5, 0.5
                g.red.Position = UDim2.fromOffset(math.random(-3, 3), 0)
                g.cyan.Position = UDim2.fromOffset(math.random(-3, 3), 0)
                if g.intro <= 0 then g.Rest() end
            elseif g.burst > 0 then
                g.burst = g.burst - dt
                g.scr = g.scr - dt
                local ox = math.random(-6, 6)
                g.red.Position = UDim2.fromOffset(ox, math.random(-1, 1))
                g.cyan.Position = UDim2.fromOffset(-ox, math.random(-1, 1))
                g.red.TextTransparency, g.cyan.TextTransparency = 0.3, 0.3
                if g.scr <= 0 then
                    g.scr = 0.05
                    local sy = math.random(5, 60) / 100
                    g.slice.Visible = true
                    g.slice.Position = UDim2.fromScale(0, sy)
                    g.sliceTxt.Position = UDim2.new(0, math.random(-10, 10), -sy / 0.3, 0)
                    g.SetAll(scrambleText(g.text, math.random(0, 2)))
                end
                if g.burst <= 0 then g.Rest() end
            elseif g.timer >= g.nextAt and not ANIM.reduce then
                g.timer = 0
                g.nextAt = 3 + math.random() * 4
                g.burst = 0.18 + math.random() * 0.2
            end
        end
    end
end))
end

--------------------------------------------------------------------------------
-- LOGO 3D: cubo de arestas girando com o nucleo girando ao contrario (ViewportFrame)
--------------------------------------------------------------------------------
local Logos = {}
local function CoreLogo(parent, pos, size, rich)
    local vp = New("ViewportFrame", {
        Position = pos, Size = size, BackgroundTransparency = 1, Ambient = Color3.fromRGB(200, 190, 200),
        LightColor = Color3.new(1, 1, 1), LightDirection = Vector3.new(-1, -1, -1),
    }, parent)
    local cam = New("Camera", {FieldOfView = 38}, vp)
    cam.CFrame = CFrame.lookAt(Vector3.new(0, 0.5, rich and 8.8 or 5.6), Vector3.new(0, 0, 0))
    vp.CurrentCamera = cam
    local outer = New("Model", {Name = "Outer"}, vp)
    local inner = New("Model", {Name = "Inner"}, vp)
    local parts = {}
    local function bar(sx, sy, sz, x, y, z)
        parts[#parts + 1] = New("Part", {
            Anchored = true, CanCollide = false, Material = Enum.Material.Neon, Color = T.Accent,
            Size = Vector3.new(sx, sy, sz), CFrame = CFrame.new(x, y, z), CastShadow = false,
        }, outer)
    end
    local s, t = 0.95, 0.12
    for _, a in ipairs({-s, s}) do
        for _, b in ipairs({-s, s}) do
            bar(2 * s, t, t, 0, a, b)
            bar(t, 2 * s, t, a, 0, b)
            bar(t, t, 2 * s, a, b, 0)
        end
    end
    local core = New("Part", {
        Anchored = true, CanCollide = false, Material = Enum.Material.Neon, Color = T.Accent2,
        Size = Vector3.new(0.7, 0.7, 0.7), CFrame = CFrame.new(0, 0, 0), CastShadow = false,
    }, inner)
    -- versao rica (loader): anel de 36 pontos inclinado + 3 esferas em orbita
    local extra = nil
    local orbit, spheres = {}, {}
    if rich then
        local ringM = New("Model", {Name = "Orbit"}, vp)
        for i = 1, 36 do
            local a = (i / 36) * math.pi * 2
            orbit[i] = New("Part", {
                Anchored = true, CanCollide = false, CastShadow = false, Material = Enum.Material.Neon, Color = T.Accent2,
                Size = Vector3.new(0.12, 0.12, 0.12), CFrame = CFrame.new(math.cos(a) * 1.95, 0, math.sin(a) * 1.95),
            }, ringM)
        end
        for i = 1, 3 do
            spheres[i] = New("Part", {
                Anchored = true, CanCollide = false, CastShadow = false, Material = Enum.Material.Neon,
                Color = (i == 2) and T.Accent2 or T.Accent, Shape = Enum.PartType.Ball, Size = Vector3.new(0.3, 0.3, 0.3),
            }, vp)
        end
        extra = function(tt)
            ringM:PivotTo(CFrame.Angles(tt * 0.5, tt * 0.9, 0.3))
            for i, sp in ipairs(spheres) do
                local a = tt * (1.1 + i * 0.35) + i * 2.1
                sp.CFrame = CFrame.new(math.cos(a) * 2.5, math.sin(a * 1.3), math.sin(a) * 2.5)
            end
        end
    end
    onTheme(function()
        for _, p in ipairs(parts) do p.Color = T.Accent end
        core.Color = T.Accent2
        for _, p in ipairs(orbit) do p.Color = T.Accent2 end
        for i, sp in ipairs(spheres) do sp.Color = (i == 2) and T.Accent2 or T.Accent end
    end)
    local obj = {vp = vp, outer = outer, inner = inner, t = math.random() * 6, boost = 0, extra = extra}
    Logos[#Logos + 1] = obj
    return obj
end

--------------------------------------------------------------------------------
-- JANELA
--------------------------------------------------------------------------------
local Gui = New("ScreenGui", {
    Name = GUI_NAME, ResetOnSpawn = false, DisplayOrder = 10, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)
LAY.BASE = UDim2.fromOffset(LAY.W, LAY.H)
LAY.SHRUNK = UDim2.fromOffset(LAY.W - 30, LAY.H - 22)

local Shell = New("Frame", {
    Name = "Shell", Size = LAY.BASE, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    BackgroundTransparency = 1, BorderSizePixel = 0,
}, Gui)
local Main = New("Frame", {
    Name = "Main", Size = UDim2.fromScale(1, 1), BackgroundColor3 = T.Bg, BackgroundTransparency = 0.03,
    BorderSizePixel = 0, ClipsDescendants = true,
}, Shell)
Round(Main, 10)
Stroke(Main, T.Stroke2, 1)
do
    local sp = Persist.Get("cfg:pos", nil)
    if type(sp) == "table" and type(sp[1]) == "number" and type(sp[2]) == "number" then
        Shell.Position = UDim2.new(0.5, math.clamp(sp[1], -1200, 1200), 0.5, math.clamp(sp[2], -700, 700))
    end
end

-- cenario 3D de fundo (ViewportFrame real): grade em perspectiva andando, estilhacos neon e anel
-- orbitando. A camera segue o mouse (parallax de verdade) e leva um "tranco" ao abrir e trocar de aba.
do
    local vp = New("ViewportFrame", {
        Name = "Scene3D", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ImageTransparency = 0.28,
        Ambient = Color3.fromRGB(120, 108, 124), LightColor = Color3.fromRGB(255, 226, 214),
        LightDirection = Vector3.new(-1, -1, -0.5),
    }, Main)
    Round(vp, 10)
    local cam = New("Camera", {FieldOfView = 62}, vp)
    vp.CurrentCamera = cam
    local function neon(props, parent)
        props.Anchored, props.CanCollide, props.CastShadow, props.Material = true, false, false, Enum.Material.Neon
        return New("Part", props, parent)
    end
    local gridM = New("Model", {Name = "Grid"}, vp)
    gridM.PrimaryPart = New("Part", {
        Anchored = true, CanCollide = false, CastShadow = false, Transparency = 1, Size = Vector3.new(0.1, 0.1, 0.1),
        CFrame = CFrame.new(0, 0, 0),
    }, gridM)
    local lines = {}
    local floorY = -3
    for i = -12, 12 do
        lines[#lines + 1] = neon({
            Color = T.Accent, Transparency = 0.5 + math.abs(i) * 0.03, Size = Vector3.new(0.05, 0.05, 70),
            CFrame = CFrame.new(i * 2, floorY, -14),
        }, gridM)
    end
    for j = -2, 22 do
        lines[#lines + 1] = neon({
            Color = T.Accent, Transparency = 0.5 + math.max(0, j) * 0.018, Size = Vector3.new(60, 0.05, 0.05),
            CFrame = CFrame.new(0, floorY, 12 - j * 2),
        }, gridM)
    end
    local ringM = New("Model", {Name = "Ring"}, vp)
    local ring = {}
    for i = 1, 40 do
        local a = (i / 40) * math.pi * 2
        ring[i] = neon({
            Color = T.Accent2, Transparency = 0.25, Size = Vector3.new(0.16, 0.16, 0.16),
            CFrame = CFrame.new(math.cos(a) * 7, 0, math.sin(a) * 7),
        }, ringM)
    end
    local rng = Random.new(7)
    local shards = {}
    for i = 1, 16 do
        local sz = rng:NextNumber(0.35, 1.1)
        shards[i] = {
            p = neon({
                Color = (i % 3 == 0) and T.Accent2 or T.Accent, Transparency = 0.3 + rng:NextNumber(0, 0.4),
                Size = Vector3.new(sz, sz * rng:NextNumber(0.5, 1.6), sz),
            }, vp),
            x = rng:NextNumber(-13, 13), y = rng:NextNumber(-1.5, 6), z = rng:NextNumber(-10, 4),
            w1 = rng:NextNumber(-1, 1), w2 = rng:NextNumber(-1, 1), w3 = rng:NextNumber(-1, 1), ph = rng:NextNumber(0, 6.28),
            alt = (i % 3 == 0),
        }
    end
    local S3 = {on = true}
    local t, kick, yaw, cx, cy = 0, 0, 0, 0, 0
    function S3.kick(k, y)
        kick = math.max(kick, k or 1)
        yaw = y or ((math.random() < 0.5) and -0.09 or 0.09)
    end
    function S3.enable(v)
        S3.on = v
        vp.Visible = v
    end
    function S3.update(dt, mx, my)
        if not S3.on then return end
        t = t + dt
        kick = kick * math.exp(-dt * 3.5)
        yaw = yaw * math.exp(-dt * 3)
        cx = cx + (mx * 1.8 - cx) * math.min(1, dt * 4)
        cy = cy + (my * -0.9 - cy) * math.min(1, dt * 4)
        cam.FieldOfView = 62 + kick * 14
        cam.CFrame = CFrame.lookAt(Vector3.new(cx, 1.6 + cy, 13), Vector3.new(0, 1, 0)) * CFrame.Angles(0, yaw, 0)
        gridM:PivotTo(CFrame.new(0, 0, (t * (0.8 + kick * 3)) % 2))
        ringM:PivotTo(CFrame.new(0, 3, -2) * CFrame.Angles(0.45, t * 0.3, 0.15))
        for _, s in ipairs(shards) do
            s.p.CFrame = CFrame.new(s.x, s.y + math.sin(t * 0.7 + s.ph) * 0.45, s.z)
                * CFrame.Angles(t * s.w1, t * s.w2, t * s.w3)
        end
    end
    onTheme(function()
        for _, p in ipairs(lines) do p.Color = T.Accent end
        for _, p in ipairs(ring) do p.Color = T.Accent2 end
        for _, s in ipairs(shards) do s.p.Color = s.alt and T.Accent2 or T.Accent end
        S3.kick(1.4)
    end)
    LAY.S3 = S3
end
LAY.Sheen = New("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(-0.3, 0.5), Size = UDim2.new(0.3, 0, 2, 0),
    Rotation = 16, BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, BorderSizePixel = 0,
}, Main)
New("UIGradient", {
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.965), NumberSequenceKeypoint.new(1, 1),
    }),
}, LAY.Sheen)

-- linha de accent no topo + cantoneiras (HUD)
do
local TopLine = New("Frame", {
    Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = T.Accent, BorderSizePixel = 0, ZIndex = 6,
}, Main)
bindAcc(TopLine, "BackgroundColor3")
New("UIGradient", {
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1),
    }),
}, TopLine)
end

local bracketsAnim
do
local Brackets = {}
    local defs = {
        {Vector2.new(0, 0), UDim2.fromOffset(-4, -4)}, {Vector2.new(1, 0), UDim2.new(1, 4, 0, -4)},
        {Vector2.new(0, 1), UDim2.new(0, -4, 1, 4)}, {Vector2.new(1, 1), UDim2.new(1, 4, 1, 4)},
    }
    for _, d in ipairs(defs) do
        for _, horiz in ipairs({true, false}) do
            local b = New("Frame", {
                AnchorPoint = d[1], Position = d[2], BackgroundColor3 = T.Accent, BorderSizePixel = 0,
                Size = horiz and UDim2.fromOffset(16, 2) or UDim2.fromOffset(2, 16),
            }, Shell)
            bindAcc(b, "BackgroundColor3")
            Brackets[#Brackets + 1] = {f = b, horiz = horiz}
        end
    end
function bracketsAnim(on)
    for _, b in ipairs(Brackets) do
        local full = b.horiz and UDim2.fromOffset(16, 2) or UDim2.fromOffset(2, 16)
        local none = b.horiz and UDim2.fromOffset(0, 2) or UDim2.fromOffset(2, 0)
        if on then
            b.f.Size = none
            TweenEx(b.f, 0.5, Enum.EasingStyle.Back, {Size = full})
        else
            Tween(b.f, 0.15, {Size = none})
        end
    end
end
end

-- barra superior
local Top = New("Frame", {Size = UDim2.new(1, 0, 0, LAY.TOP), BackgroundTransparency = 1, BorderSizePixel = 0}, Main)
local logoObj = CoreLogo(Top, UDim2.fromOffset(12, 8), UDim2.fromOffset(36, 36))
local TitleGlitch = GlitchText(Top, "SILK CORE", 15, UDim2.fromOffset(58, 8), UDim2.fromOffset(200, 20))
TitleGlitch.Intro(0.9)
do
    local logoBtn = New("TextButton", {
        Text = "", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 8), Size = UDim2.fromOffset(36, 36), ZIndex = 5,
    }, Top)
    logoBtn.MouseButton1Click:Connect(Safe(function()
        logoObj.boost = 1
        TitleGlitch.Burst(0.5)
        LAY.S3.kick(1.3)
    end, "logo"))
end
Label(Top, "avatar suite  ·  v2.0", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(58, 30), UDim2.fromOffset(200, 14))
local Crumb = Label(Top, "", 11, T.Sub, F.Mono, nil, UDim2.fromOffset(300, 0), UDim2.fromOffset(240, LAY.TOP))
do
    local chip = New("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundColor3 = T.Card2, BorderSizePixel = 0,
        Size = UDim2.fromOffset(128, 26), Position = UDim2.new(1, -184, 0, 13),
    }, Top)
    Round(chip, 6)
    Stroke(chip, T.Stroke2, 1)
    Label(chip, "CTRL K", 10, T.Text, F.Mono, nil, UDim2.fromOffset(10, 0), UDim2.fromOffset(52, 26))
    Label(chip, "comandos", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.new(1, -66, 0, 0), UDim2.fromOffset(56, 26))
    chip.MouseEnter:Connect(function() Tween(chip, 0.15, {BackgroundColor3 = T.Card3}) end)
    chip.MouseLeave:Connect(function() Tween(chip, 0.2, {BackgroundColor3 = T.Card2}) end)
    chip.MouseButton1Click:Connect(Safe(function()
        if LAY.OpenPalette then LAY.OpenPalette() end
    end, "paleta"))
end
New("Frame", {
    Size = UDim2.new(1, -24, 0, 1), Position = UDim2.fromOffset(12, LAY.TOP - 1), BackgroundColor3 = T.Stroke, BorderSizePixel = 0,
}, Top)

do
local Close = New("TextButton", {
    Text = "", AutoButtonColor = false, BackgroundColor3 = T.Card2, BorderSizePixel = 0,
    Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -42, 0, 12),
}, Top)
Round(Close, 6)
Stroke(Close, T.Stroke2, 1)
local xLines = {}
for _, rot in ipairs({45, -45}) do
    local l = New("Frame", {
        Size = UDim2.fromOffset(12, 2), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Rotation = rot, BackgroundColor3 = T.Sub, BorderSizePixel = 0,
    }, Close)
    Round(l, 1)
    xLines[#xLines + 1] = l
end
Close.MouseEnter:Connect(function()
    Tween(Close, 0.15, {BackgroundColor3 = T.Bad})
    for _, l in ipairs(xLines) do TweenEx(l, 0.25, Enum.EasingStyle.Back, {BackgroundColor3 = Color3.new(1, 1, 1), Rotation = l.Rotation + 90}) end
end)
Close.MouseLeave:Connect(function()
    Tween(Close, 0.18, {BackgroundColor3 = T.Card2})
    for i, l in ipairs(xLines) do Tween(l, 0.18, {BackgroundColor3 = T.Sub, Rotation = (i == 1) and 45 or -45}) end
end)

LAY.Close = Close
end

-- arrastar pela barra superior
do
    local dragging, dragInput, dragStart, startPos
    Top.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, Shell.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if LAY.PosDirty then
                        LAY.PosDirty = false
                        Persist.Set("cfg:pos", {Shell.Position.X.Offset, Shell.Position.Y.Offset})
                    end
                end
            end)
        end
    end)
    Top.InputChanged:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then dragInput = i end
    end)
    track(UserInputService.InputChanged:Connect(function(i)
        if i == dragInput and dragging then
            local d = i.Position - dragStart
            Shell.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            LAY.PosDirty = true
        end
    end))
end

--------------------------------------------------------------------------------
-- TRILHO DE NAVEGACAO (icones desenhados com frames, sem asset nenhum)
--------------------------------------------------------------------------------
local NAVB, tabs, tabHooks = {}, {}, {}
local NavPill, curName, curFrame, ShowTab, SetBadge
do
local Rail = New("Frame", {
    Name = "Rail", Size = UDim2.fromOffset(LAY.RAIL, LAY.BODY_H), Position = UDim2.fromOffset(12, LAY.BODY_Y),
    BackgroundColor3 = T.Panel, BackgroundTransparency = 0.2, BorderSizePixel = 0, ClipsDescendants = true,
}, Main)
LAY.Rail = Rail
Round(Rail, 8)
Stroke(Rail, T.Stroke, 1)
local NavArea = New("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, -66), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 0,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ClipsDescendants = true,
}, Rail)
NavPill = New("Frame", {
    Size = UDim2.new(1, -16, 0, 28), Position = UDim2.fromOffset(8, 26), BackgroundColor3 = T.Card2,
    BorderSizePixel = 0, ZIndex = 1,
}, NavArea)
Round(NavPill, 6)
do
    local bar = New("Frame", {
        AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(3, 16),
        BackgroundColor3 = T.Accent, BorderSizePixel = 0, ZIndex = 2,
    }, NavPill)
    bindAcc(bar, "BackgroundColor3")
    Round(bar, 2)
end

local function iconBox(parent, x, y, w, h, r, filled, col)
    local f = New("Frame", {
        Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BorderSizePixel = 0,
        BackgroundColor3 = col, BackgroundTransparency = filled and 0 or 1, ZIndex = 4,
    }, parent)
    if r and r > 0 then Round(f, r) end
    local st = nil
    if not filled then st = Stroke(f, col, 1.5) end
    return {f = f, st = st}
end
local ICONS = {
    clone = function(p, c)
        return {iconBox(p, 1, 5, 11, 11, 2, false, c), iconBox(p, 6, 1, 11, 11, 2, false, c)}
    end,
    body = function(p, c)
        return {iconBox(p, 6, 1, 6, 6, 3, false, c), iconBox(p, 3, 9, 12, 8, 3, true, c)}
    end,
    shirt = function(p, c)
        return {iconBox(p, 4, 4, 10, 13, 2, true, c), iconBox(p, 0, 4, 5, 6, 1, true, c), iconBox(p, 13, 4, 5, 6, 1, true, c)}
    end,
    grid = function(p, c)
        return {iconBox(p, 1, 1, 7, 7, 1, true, c), iconBox(p, 10, 1, 7, 7, 1, true, c),
            iconBox(p, 1, 10, 7, 7, 1, true, c), iconBox(p, 10, 10, 7, 7, 1, true, c)}
    end,
    spark = function(p, c)
        return {iconBox(p, 8, 1, 2, 16, 1, true, c), iconBox(p, 1, 8, 16, 2, 1, true, c), iconBox(p, 12, 2, 4, 4, 2, true, c)}
    end,
    cross = function(p, c)
        return {iconBox(p, 3, 3, 12, 12, 6, false, c), iconBox(p, 8, 0, 2, 5, 1, true, c), iconBox(p, 8, 13, 2, 5, 1, true, c),
            iconBox(p, 0, 8, 5, 2, 1, true, c), iconBox(p, 13, 8, 5, 2, 1, true, c)}
    end,
    sliders = function(p, c)
        return {iconBox(p, 1, 3, 16, 2, 1, true, c), iconBox(p, 1, 8, 16, 2, 1, true, c), iconBox(p, 1, 13, 16, 2, 1, true, c),
            iconBox(p, 4, 1, 4, 6, 1, true, c), iconBox(p, 11, 6, 4, 6, 1, true, c), iconBox(p, 6, 11, 4, 6, 1, true, c)}
    end,
    bomb = function(p, c)
        return {iconBox(p, 1, 6, 12, 12, 6, true, c), iconBox(p, 9, 2, 6, 2, 1, true, c), iconBox(p, 14, 0, 3, 3, 1, true, c)}
    end,
    star = function(p, c)
        return {iconBox(p, 7, 0, 4, 18, 2, true, c), iconBox(p, 0, 7, 18, 4, 2, true, c), iconBox(p, 3, 3, 12, 12, 1, false, c)}
    end,
    sun = function(p, c)
        return {iconBox(p, 5, 5, 8, 8, 4, true, c), iconBox(p, 8, 0, 2, 3, 1, true, c), iconBox(p, 8, 15, 2, 3, 1, true, c),
            iconBox(p, 0, 8, 3, 2, 1, true, c), iconBox(p, 15, 8, 3, 2, 1, true, c)}
    end,
    pulse = function(p, c)
        return {iconBox(p, 0, 9, 4, 2, 1, true, c), iconBox(p, 4, 3, 2, 12, 1, true, c), iconBox(p, 7, 6, 2, 8, 1, true, c),
            iconBox(p, 10, 0, 2, 18, 1, true, c), iconBox(p, 13, 7, 5, 2, 1, true, c)}
    end,
    gear = function(p, c)
        return {iconBox(p, 4, 4, 10, 10, 5, false, c), iconBox(p, 8, 0, 2, 4, 1, true, c), iconBox(p, 8, 14, 2, 4, 1, true, c),
            iconBox(p, 0, 8, 4, 2, 1, true, c), iconBox(p, 14, 8, 4, 2, 1, true, c)}
    end,
    house = function(p, c)
        return {iconBox(p, 2, 8, 14, 9, 1, false, c), iconBox(p, 7, 0, 4, 9, 1, true, c), iconBox(p, 8, 11, 2, 6, 1, true, c)}
    end,
}

local NAV = {
    {group = "AVATAR", items = {
        {id = "Clonar", icon = "clone", title = "Clonar avatar", sub = "copie o visual de qualquer jogador"},
        {id = "Corpo", icon = "body", title = "Corpo & morphs", sub = "headless, korblox e escala"},
        {id = "Roupa", icon = "shirt", title = "Partes do corpo", sub = "troque cabeça, tronco, braços e pernas por ID"},
        {id = "Catálogo", icon = "grid", title = "Catálogo de itens", sub = "qualquer ID: acessório, roupa, tool ou parte do corpo"},
        {id = "Browse", icon = "grid", title = "Browse / Loja", sub = "explore o catálogo do Roblox e emotes diretamente"},
        {id = "Efeitos", icon = "spark", title = "Efeitos", sub = "partículas e rastro no personagem"},
        {id = "Looks", icon = "star", title = "Looks", sub = "salve, aplique, exporte e importe looks completos"},
    }},
    {group = "MUNDO", items = {
        {id = "Ambiente", icon = "sun", title = "Ambiente", sub = "filtros de câmera, hora do dia e modo foto"},
    }},
    {group = "FERRAMENTAS", items = {
        {id = "Aimlock", icon = "cross", title = "Aimlock", sub = "segure o bind pra travar no alvo"},
        {id = "Volei", icon = "pulse", title = "Vôlei", sub = "linha de mira dos adversários"},
        {id = "Hacks", icon = "spark", title = "Hacks universais", sub = "velocidade, voo, noclip, god mode e Infinite Yield"},
        {id = "Brookhaven", icon = "house", title = "Brookhaven", sub = "dump, desbloqueio de itens e teleporte"},
        {id = "HBG", icon = "cross", title = "HBG", sub = "dump de remotes, bypass de anti-cheat e auto-block"},
        {id = "Diversos", icon = "sliders", title = "Diversos", sub = "tela esticada e pulo duplo"},
        {id = "Timebomb", icon = "bomb", title = "Timebomb", sub = "ferramentas do modo"},
    }},
    {group = "SISTEMA", items = {
        {id = "Desempenho", icon = "pulse", title = "Desempenho", sub = "fps, ping e memória ao vivo, e ajustes de gráficos"},
        {id = "Config", icon = "gear", title = "Configurações", sub = "tema, atalhos e registro de eventos"},
    }},
}

do
    local navY = 10
    for _, grp in ipairs(NAV) do
        Label(NavArea, grp.group, 9, T.Faint, F.Mono, nil, UDim2.fromOffset(18, navY), UDim2.new(1, -36, 0, 16))
        navY = navY + 16
        for _, it in ipairs(grp.items) do
            local btn = New("TextButton", {
                Text = "", AutoButtonColor = false, BackgroundColor3 = T.Card2, BackgroundTransparency = 1,
                BorderSizePixel = 0, Size = UDim2.new(1, -16, 0, 28), Position = UDim2.fromOffset(8, navY), ZIndex = 3,
            }, NavArea)
            Round(btn, 6)
            local holder = New("Frame", {
                Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(12, 5), BackgroundTransparency = 1, ZIndex = 3,
            }, btn)
            local icon = ICONS[it.icon](holder, T.Sub)
            local lbl = New("TextLabel", {
                Text = it.id, Font = F.Bold, TextSize = 12, TextColor3 = T.Sub, TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1, Position = UDim2.fromOffset(40, 0), Size = UDim2.new(1, -80, 1, 0), ZIndex = 3,
            }, btn)
            local badge = New("TextLabel", {
                Text = "", Font = F.Mono, TextSize = 10, TextColor3 = T.Faint, TextXAlignment = Enum.TextXAlignment.Right,
                BackgroundTransparency = 1, Position = UDim2.new(1, -40, 0, 0), Size = UDim2.fromOffset(32, 28), ZIndex = 3,
            }, btn)
            local name = it.id
            btn.MouseEnter:Connect(function()
                if curName ~= name then Tween(btn, 0.15, {BackgroundTransparency = 0.6}) end
                TweenEx(holder, 0.25, Enum.EasingStyle.Back, {Position = UDim2.fromOffset(15, 5)})
            end)
            btn.MouseLeave:Connect(function()
                Tween(btn, 0.2, {BackgroundTransparency = 1})
                Tween(holder, 0.2, {Position = UDim2.fromOffset(12, 5)})
            end)
            btn.MouseButton1Click:Connect(Safe(function()
                if ShowTab then ShowTab(name) end
            end, "nav " .. name))
            NAVB[name] = {btn = btn, icon = icon, lbl = lbl, badge = badge, y = navY, meta = it}
            navY = navY + 29
        end
        navY = navY + 6
    end
end
function SetBadge(name, text)
    local e = NAVB[name]
    if e then e.badge.Text = text or "" end
end

-- cartao do jogador no rodape do trilho
do
    local prof = New("Frame", {
        Size = UDim2.new(1, -16, 0, 50), Position = UDim2.new(0, 8, 1, -58), BackgroundColor3 = T.Card,
        BorderSizePixel = 0,
    }, Rail)
    Round(prof, 8)
    Stroke(prof, T.Stroke, 1)
    local img = New("ImageLabel", {
        Size = UDim2.fromOffset(34, 34), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = T.Card3, BorderSizePixel = 0,
        Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(LocalPlayer.UserId) .. "&w=150&h=150",
    }, prof)
    Round(img, 17)
    Label(prof, LocalPlayer.DisplayName, 12, T.Text, F.Bold, nil, UDim2.fromOffset(50, 8), UDim2.new(1, -62, 0, 16))
    Label(prof, "@" .. LocalPlayer.Name, 10, T.Faint, F.Mono, nil, UDim2.fromOffset(50, 26), UDim2.new(1, -62, 0, 14))
    local dot = New("Frame", {
        Size = UDim2.fromOffset(8, 8), Position = UDim2.new(1, -16, 0, 8), BackgroundColor3 = T.Good, BorderSizePixel = 0,
    }, prof)
    Round(dot, 4)
    track(RunService.Heartbeat:Connect(function()
        if dot.Parent then dot.BackgroundTransparency = 0.35 + 0.35 * math.sin(os.clock() * 3) end
    end))
end

end

--------------------------------------------------------------------------------
-- PAINEL DE CONTEUDO
--------------------------------------------------------------------------------
local HeaderTitle, HeaderSub, TabHost, Scan, SetInfo
do
local Panel = New("Frame", {
    Name = "Panel", Size = UDim2.fromOffset(LAY.W - LAY.PANEL_X - 12, LAY.BODY_H), Position = UDim2.fromOffset(LAY.PANEL_X, LAY.BODY_Y),
    BackgroundColor3 = T.Panel, BackgroundTransparency = 0.2, BorderSizePixel = 0, ClipsDescendants = true,
}, Main)
LAY.Panel = Panel
Round(Panel, 8)
Stroke(Panel, T.Stroke, 1)
HeaderTitle = Label(Panel, "", 17, T.Text, F.Bold, nil, UDim2.fromOffset(18, 9), UDim2.new(1, -230, 0, 22))
HeaderSub = Label(Panel, "", 11, T.Sub, F.Body, nil, UDim2.fromOffset(18, 31), UDim2.new(1, -230, 0, 16))
local HeaderInfo = Label(Panel, "", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.new(1, -208, 0, 12), UDim2.fromOffset(190, 16))
New("Frame", {
    Size = UDim2.new(1, -36, 0, 1), Position = UDim2.fromOffset(18, 54), BackgroundColor3 = T.Stroke, BorderSizePixel = 0,
}, Panel)
TabHost = New("Frame", {
    Size = UDim2.new(1, 0, 1, -56), Position = UDim2.fromOffset(0, 56), BackgroundTransparency = 1, ClipsDescendants = true,
}, Panel)
Scan = New("Frame", {
    Size = UDim2.new(1, 0, 0, 2), Position = UDim2.fromOffset(0, 54), BackgroundColor3 = T.Accent,
    BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 20,
}, Panel)
bindAcc(Scan, "BackgroundColor3")
New("UIGradient", {
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1),
    }),
}, Scan)
function SetInfo(text)
    HeaderInfo.Text = text or ""
end

end

-- barra de status (dados reais: fps, ping, rig, itens)
do
local StatusBar = New("Frame", {
    Size = UDim2.new(1, 0, 0, 32), Position = UDim2.new(0, 0, 1, -32), BackgroundTransparency = 1, BorderSizePixel = 0,
}, Main)
New("Frame", {
    Size = UDim2.new(1, -24, 0, 1), Position = UDim2.fromOffset(12, 0), BackgroundColor3 = T.Stroke, BorderSizePixel = 0,
}, StatusBar)
LAY.StL = Label(StatusBar, "", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 2), UDim2.new(0.55, 0, 1, -2))
LAY.StR = Label(StatusBar, "", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.new(0.45, -16, 0, 2), UDim2.new(0.55, 0, 1, -2))
end
local execName = "executor"
do
    local okEx, nm = pcall(function()
        if identifyexecutor then return (identifyexecutor()) end
        return nil
    end)
    if okEx and nm then execName = tostring(nm) end
end

--------------------------------------------------------------------------------
-- ABRIR / FECHAR (so Frame + tween: sem CanvasGroup e sem UIScale)
--------------------------------------------------------------------------------
local isOpen = true
local blurFx
local cfg = {Blur = true}
local function setBlur(on)
    if on and cfg.Blur then
        if not blurFx then
            blurFx = Instance.new("BlurEffect")
            blurFx.Name = "SilkcoreBlur"
            blurFx.Size = 0
            blurFx.Parent = game:GetService("Lighting")
        end
        Tween(blurFx, 0.3, {Size = 14})
    elseif blurFx then
        local fx = blurFx
        blurFx = nil
        Tween(fx, 0.2, {Size = 0})
        task.delay(0.3, function()
            if fx.Parent then fx:Destroy() end
        end)
    end
end
local revealTab
local function SetOpen(v)
    if v == isOpen and Gui.Enabled == v then return end
    isOpen = v
    if v then
        Shell.Size = LAY.SHRUNK
        Main.BackgroundTransparency = 1
        Gui.Enabled = true
        TweenEx(Shell, 0.45, Enum.EasingStyle.Back, {Size = LAY.BASE})
        Tween(Main, 0.3, {BackgroundTransparency = 0.03})
        LAY.S3.kick(1.2)
        setBlur(true)
        bracketsAnim(true)
        TitleGlitch.Intro(0.7)
        if curFrame then revealTab(curFrame) end
    else
        Persist.Flush()
        Tween(Shell, 0.2, {Size = LAY.SHRUNK})
        Tween(Main, 0.2, {BackgroundTransparency = 1})
        setBlur(false)
        bracketsAnim(false)
        task.delay(0.24, function()
            if not isOpen then
                Gui.Enabled = false
                Shell.Size = LAY.BASE
            end
        end)
    end
end
LAY.Close.MouseButton1Click:Connect(Safe(function() SetOpen(false) end, "fechar"))

--------------------------------------------------------------------------------
-- TOASTS (ScreenGui propria: nunca cortados pela janela)
--------------------------------------------------------------------------------
local ToastGui, Toast
do
ToastGui = New("ScreenGui", {
    Name = "SilkcoreToasts", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 30,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)
local liveToasts = {}
local TOAST_W, TOAST_H, TOAST_GAP = 320, 44, 8
local function toastY(i)
    return -18 - (i - 1) * (TOAST_H + TOAST_GAP)
end
local function restackToasts()
    for i, t in ipairs(liveToasts) do
        TweenEx(t, 0.34, Enum.EasingStyle.Quint, {Position = UDim2.new(1, -18, 1, toastY(i))})
    end
end
function Toast(text, ok)
    Log.add(ok and "OK" or "FALHA", text)
    if Persist.Loading then return end
    for _, t in ipairs(liveToasts) do
        if t:GetAttribute("Msg") == text then return end
    end
    local f = New("Frame", {
        AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(TOAST_W, TOAST_H),
        Position = UDim2.new(1, TOAST_W + 40, 1, toastY(1)), BackgroundColor3 = T.Card, BorderSizePixel = 0,
        ZIndex = 30, ClipsDescendants = true,
    }, ToastGui)
    f:SetAttribute("Msg", text)
    Round(f, 8)
    Stroke(f, T.Stroke2, 1)
    local accent = ok and T.Good or T.Bad
    New("Frame", {Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = accent, BorderSizePixel = 0, ZIndex = 31}, f)
    New("TextLabel", {
        Text = text, Font = F.Body, TextSize = 12, TextColor3 = T.Text, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 0),
        Size = UDim2.new(1, -28, 1, -2), ZIndex = 31,
    }, f)
    local life = New("Frame", {
        Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2), BackgroundColor3 = accent,
        BackgroundTransparency = 0.3, BorderSizePixel = 0, ZIndex = 32,
    }, f)
    TweenService:Create(life, TweenInfo.new(2.8, Enum.EasingStyle.Linear), {Size = UDim2.new(0, 0, 0, 2)}):Play()
    table.insert(liveToasts, 1, f)
    if #liveToasts > 4 then
        local old = table.remove(liveToasts)
        if old then old:Destroy() end
    end
    restackToasts()
    task.delay(2.8, function()
        if not f.Parent then return end
        local idx = table.find(liveToasts, f)
        if idx then table.remove(liveToasts, idx) end
        TweenEx(f, 0.3, Enum.EasingStyle.Quart, {Position = UDim2.new(1, TOAST_W + 40, 1, f.Position.Y.Offset)})
        task.delay(0.32, function()
            if f.Parent then f:Destroy() end
        end)
        restackToasts()
    end)
end
Log.notify = Toast
end

--------------------------------------------------------------------------------
-- WIDGETS
--------------------------------------------------------------------------------
local CurTab

local function MakeCard(parent, size, order)
    local outer = New("Frame", {Size = size, BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = order}, parent)
    local card = New("Frame", {
        Name = "Glass", Size = UDim2.fromScale(1, 1), BackgroundColor3 = T.Card, BorderSizePixel = 0, Active = true,
    }, outer)
    Round(card, 8)
    local edge = Stroke(card, T.Stroke, 1)
    local tick = New("Frame", {
        AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(3, 0),
        BackgroundColor3 = T.Accent, BorderSizePixel = 0, ZIndex = 2,
    }, card)
    bindAcc(tick, "BackgroundColor3")
    Round(tick, 2)
    card.MouseEnter:Connect(function()
        Tween(card, 0.18, {BackgroundColor3 = T.Card2})
        Tween(edge, 0.18, {Color = T.Stroke2})
        TweenEx(tick, 0.28, Enum.EasingStyle.Back, {Size = UDim2.fromOffset(3, 18)})
    end)
    card.MouseLeave:Connect(function()
        Tween(card, 0.22, {BackgroundColor3 = T.Card})
        Tween(edge, 0.22, {Color = T.Stroke})
        Tween(tick, 0.2, {Size = UDim2.fromOffset(3, 0)})
    end)
    return card, outer
end

local function Row(h)
    local card = MakeCard(CurTab, UDim2.new(1, 0, 0, h or 40), nextOrder())
    return card
end

local function Section(text)
    local f = New("Frame", {Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = nextOrder()}, CurTab)
    local n = (CurTab:GetAttribute("sec") or 0) + 1
    CurTab:SetAttribute("sec", n)
    local num = Label(f, string.format("%02d", n), 10, T.Accent, F.Mono, nil, UDim2.fromOffset(2, 2), UDim2.fromOffset(20, 16))
    bindAcc(num, "TextColor3")
    Label(f, upperPT(text), 10, T.Sub, F.Mono, nil, UDim2.fromOffset(24, 2), UDim2.new(1, -28, 0, 16))
    New("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, 22), BackgroundColor3 = T.Stroke, BorderSizePixel = 0,
    }, f)
    local tickBar = New("Frame", {
        Size = UDim2.fromOffset(18, 2), Position = UDim2.fromOffset(0, 21), BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    }, f)
    bindAcc(tickBar, "BackgroundColor3")
    return f
end

local function Button(parent, text, pos, size, color, cb)
    local kind = "primary"
    if color == T.Bad then
        kind = "danger"
    elseif color == T.Card or color == T.Bg then
        kind = "ghost"
    elseif color == T.Good then
        kind = "good"
    end
    local b = New("TextButton", {
        Text = text, Font = F.Bold, TextSize = 12, AutoButtonColor = false, BorderSizePixel = 0,
        Position = pos, Size = size, ZIndex = 3, ClipsDescendants = true,
    }, parent)
    Round(b, 6)
    local st = Stroke(b, T.Stroke2, 1)
    local flash = New("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1,
        BorderSizePixel = 0, ZIndex = 4,
    }, b)
    local function look()
        if kind == "primary" then return T.Accent, textOn(T.Accent), T.Accent, 1 end
        if kind == "good" then return T.Good, textOn(T.Good), T.Good, 1 end
        if kind == "danger" then return T.Card, T.Bad, T.Bad, 0.55 end
        return T.Card3, T.Text, T.Stroke2, 0.2
    end
    local function paint(hover, down, animate)
        local bg, tx, sc, stT = look()
        if hover then bg = bg:Lerp(Color3.new(1, 1, 1), kind == "danger" and 0.07 or 0.14) end
        if down then bg = bg:Lerp(Color3.new(0, 0, 0), 0.2) end
        if animate then
            Tween(b, 0.14, {BackgroundColor3 = bg, TextColor3 = tx})
            Tween(st, 0.14, {Color = sc, Transparency = stT})
        else
            b.BackgroundColor3, b.TextColor3 = bg, tx
            st.Color, st.Transparency = sc, stT
        end
    end
    paint(false, false, false)
    if kind == "primary" or kind == "good" then
        onTheme(function()
            if b.Parent then paint(false, false, true) end
        end)
    end
    b.MouseEnter:Connect(function() paint(true, false, true) end)
    b.MouseLeave:Connect(function()
        paint(false, false, true)
        Tween(b, 0.12, {TextSize = 12})
    end)
    b.MouseButton1Down:Connect(function()
        paint(true, true, true)
        Tween(b, 0.08, {TextSize = 11})
    end)
    b.MouseButton1Up:Connect(function()
        paint(true, false, true)
        Tween(b, 0.14, {TextSize = 12})
    end)
    b.MouseButton1Click:Connect(Safe(function()
        flash.BackgroundTransparency = 0.8
        Tween(flash, 0.4, {BackgroundTransparency = 1})
        cb()
    end, text))
    return b
end

local function BtnRow(text, color, cb, h)
    local outer = New("Frame", {
        Size = UDim2.new(1, 0, 0, h or 42), BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = nextOrder(),
    }, CurTab)
    local b = Button(outer, text, UDim2.new(), UDim2.fromScale(1, 1), color, cb)
    b.Name = "Glass"
    return b
end

local function BtnPair(t1, c1, cb1, t2, c2, cb2, h)
    local outer = New("Frame", {
        Size = UDim2.new(1, 0, 0, h or 40), BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = nextOrder(),
    }, CurTab)
    local holder = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Name = "Glass"}, outer)
    Button(holder, t1, UDim2.new(), UDim2.new(0.5, -4, 1, 0), c1, cb1)
    Button(holder, t2, UDim2.new(0.5, 4, 0, 0), UDim2.new(0.5, -4, 1, 0), c2, cb2)
end

local function Note(text, h)
    local row = Row(h or 46)
    local l = Label(row, text, 11, T.Sub, F.Body, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -32, 1, 0))
    l.TextWrapped = true
    return l
end

local function Action(text, color, cb)
    local row = Row(50)
    Label(row, text, 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -126, 1, 0))
    return Button(row, "RUN", UDim2.new(1, -104, 0.5, -15), UDim2.fromOffset(88, 30), color, cb)
end

local Toggle
do
local OFF_TRACK = Color3.fromRGB(46, 40, 50)
local OFF_KNOB = Color3.fromRGB(150, 140, 150)
function Toggle(text, default, cb, id)
    local key = Persist.On and (Persist.Scope .. ":" .. (id or text)) or nil
    local row = Row(44)
    Label(row, text, 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -130, 1, 0))
    local on = default
    if key then
        local saved = Persist.Get(key, nil)
        if type(saved) == "boolean" then on = saved end
    end
    local state = Label(row, on and "ON" or "OFF", 10, on and T.Accent or T.Faint, F.Mono, Enum.TextXAlignment.Right,
        UDim2.new(1, -116, 0, 0), UDim2.fromOffset(48, 44))
    local sw = New("TextButton", {
        Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(44, 20), Position = UDim2.new(1, -60, 0.5, -10),
        BackgroundColor3 = OFF_TRACK, BorderSizePixel = 0,
    }, row)
    Round(sw, 4)
    Stroke(sw, T.Stroke2, 1)
    local knob = New("Frame", {
        Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = OFF_KNOB, BorderSizePixel = 0,
    }, sw)
    Round(knob, 3)
    local function paint(animate)
        if on then
            bindAcc(sw, "BackgroundColor3", "Accent", true)
            bindAcc(state, "TextColor3", "Accent", true)
        else
            unbindAcc(sw, "BackgroundColor3")
            unbindAcc(state, "TextColor3")
        end
        local tc = on and T.Accent or OFF_TRACK
        local kc = on and Color3.new(1, 1, 1) or OFF_KNOB
        local kp = on and UDim2.fromOffset(27, 3) or UDim2.fromOffset(3, 3)
        state.Text = on and "ON" or "OFF"
        if animate then
            Tween(sw, 0.2, {BackgroundColor3 = tc})
            Tween(knob, 0.2, {BackgroundColor3 = kc})
            Tween(state, 0.2, {TextColor3 = on and T.Accent or T.Faint})
            TweenEx(knob, 0.42, Enum.EasingStyle.Back, {Position = kp})
        else
            sw.BackgroundColor3, knob.BackgroundColor3, knob.Position = tc, kc, kp
            state.TextColor3 = on and T.Accent or T.Faint
        end
    end
    paint(false)
    sw.MouseButton1Click:Connect(Safe(function()
        on = not on
        paint(true)
        cb(on)
        if key then Persist.Set(key, on) end
    end, text))
    if key and on ~= default then
        Persist.Loading = true
        pcall(cb, on)
        Persist.Loading = false
    end
    return {Set = function(v, fire)
        on = v
        paint(true)
        if fire then
            cb(on)
            if key then Persist.Set(key, on) end
        end
    end}
end

end

local function Slider(text, min, max, default, fmt, cb, id)
    local key = Persist.On and (Persist.Scope .. ":" .. (id or text)) or nil
    local row = Row(62)
    Label(row, text, 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 9), UDim2.new(0.65, 0, 0, 18))
    local valLbl = Label(row, "", 12, T.Accent, F.Mono, Enum.TextXAlignment.Right, UDim2.new(0.65, 0, 0, 9), UDim2.new(0.35, -16, 0, 18))
    bindAcc(valLbl, "TextColor3")
    local bar = New("Frame", {
        Size = UDim2.new(1, -36, 0, 4), Position = UDim2.new(0, 18, 0, 40), BackgroundColor3 = Color3.fromRGB(52, 46, 56),
        BorderSizePixel = 0,
    }, row)
    Round(bar, 2)
    for i = 0, 10 do
        New("Frame", {
            Size = UDim2.fromOffset(1, (i % 5 == 0) and 5 or 3), Position = UDim2.new(i / 10, 0, 0, 8),
            BackgroundColor3 = T.Stroke2, BorderSizePixel = 0,
        }, bar)
    end
    local fill = New("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = T.Accent, BorderSizePixel = 0}, bar)
    bindAcc(fill, "BackgroundColor3")
    Round(fill, 2)
    local knob = New("Frame", {
        Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5),
        Rotation = 45, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 2,
    }, bar)
    Round(knob, 2)
    local ks = Stroke(knob, T.Accent, 2)
    bindAcc(ks, "Color")

    local function set(alpha, fire)
        alpha = math.clamp(alpha, 0, 1)
        local v = min + (max - min) * alpha
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        valLbl.Text = string.format(fmt, v)
        if fire then
            cb(v)
            if key then Persist.Set(key, v) end
        end
    end
    local saved = key and Persist.Get(key, nil) or nil
    local restored = false
    if type(saved) == "number" and math.abs(saved - default) > 1e-6 then
        Persist.Loading = true
        restored = pcall(set, (saved - min) / (max - min), true)
        Persist.Loading = false
    end
    if not restored then set((default - min) / (max - min), false) end

    local hit = New("TextButton", {
        Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 0, 28),
    }, row)
    local dragging = false
    local function fromX(x)
        set((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), true)
    end
    hit.InputBegan:Connect(Safe(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            TweenEx(knob, 0.2, Enum.EasingStyle.Back, {Size = UDim2.fromOffset(17, 17)})
            fromX(i.Position.X)
        end
    end, "slider " .. text))
    track(UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            fromX(i.Position.X)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                dragging = false
                TweenEx(knob, 0.2, Enum.EasingStyle.Back, {Size = UDim2.fromOffset(12, 12)})
            end
        end
    end))
    return {Set = function(v, fire)
        set((v - min) / (max - min), fire or false)
    end}
end

-- controle segmentado: uma fileira de botoes, um selecionado
local function Segmented(row, opts, current, onPick, x0, y0, w, h, gap)
    local btns = {}
    local cur = current
    local function paint()
        for id, b in pairs(btns) do
            local on = (id == cur)
            if on then bindAcc(b, "BackgroundColor3", "Accent", true) else unbindAcc(b, "BackgroundColor3") end
            Tween(b, 0.18, {BackgroundColor3 = on and T.Accent or T.Card3, TextColor3 = on and textOn(T.Accent) or T.Sub})
        end
    end
    for i, o in ipairs(opts) do
        local b = New("TextButton", {
            Text = upperPT(o.label), Font = F.Bold, TextSize = 11, AutoButtonColor = false, BorderSizePixel = 0,
            BackgroundColor3 = T.Card3, TextColor3 = T.Sub, Size = UDim2.fromOffset(w, h),
            Position = UDim2.fromOffset(x0 + (i - 1) * (w + gap), y0),
        }, row)
        Round(b, 6)
        btns[o.id] = b
        b.MouseButton1Click:Connect(Safe(function()
            cur = o.id
            paint()
            onPick(o.id)
        end, "segmentado"))
    end
    paint()
    onTheme(paint)
    return {Set = function(id)
        cur = id
        paint()
    end}
end

local function Field(parent, pos, size, placeholder, text)
    local box = New("Frame", {
        Position = pos, Size = size, BackgroundColor3 = T.Bg, BorderSizePixel = 0, ClipsDescendants = true,
    }, parent)
    Round(box, 6)
    local st = Stroke(box, T.Stroke2, 1)
    local tb = New("TextBox", {
        Size = UDim2.new(1, -24, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
        PlaceholderText = placeholder, PlaceholderColor3 = T.Faint, Text = text or "", ClearTextOnFocus = false,
        TextColor3 = T.Text, Font = F.Mono, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    }, box)
    local line = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.new(0, 0, 0, 2),
        BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    }, box)
    bindAcc(line, "BackgroundColor3")
    tb.Focused:Connect(function()
        Tween(st, 0.15, {Color = T.Accent})
        Tween(line, 0.28, {Size = UDim2.new(1, 0, 0, 2)})
    end)
    tb.FocusLost:Connect(function()
        Tween(st, 0.15, {Color = T.Stroke2})
        Tween(line, 0.2, {Size = UDim2.new(0, 0, 0, 2)})
    end)
    return tb
end

-- extrai o primeiro ID de qualquer texto (aceita link do catalogo/rolimons)
local function parseId(s)
    s = tostring(s or "")
    local n = s:match("%d%d%d+") or s:match("%d+")
    return n and tonumber(n) or nil
end

--------------------------------------------------------------------------------
-- ABAS
--------------------------------------------------------------------------------
do
local baseOf = setmetatable({}, {__mode = "k"})
function revealTab(tab)
    if not tab then return end
    local items = {}
    for _, o in ipairs(tab:GetChildren()) do
        if o:IsA("GuiObject") then
            if o:GetAttribute("Grid") then
                for _, cell in ipairs(o:GetChildren()) do
                    local g = cell:FindFirstChild("Glass")
                    if g then items[#items + 1] = {order = o.LayoutOrder + cell.LayoutOrder * 0.001, t = g} end
                end
            else
                items[#items + 1] = {order = o.LayoutOrder, t = o:FindFirstChild("Glass") or o}
            end
        end
    end
    table.sort(items, function(a, b) return a.order < b.order end)
    for i, it in ipairs(items) do
        local t = it.t
        if not baseOf[t] then baseOf[t] = t.Position end
        local base = baseOf[t]
        t.Position = base + UDim2.fromOffset(0, 14)
        t.Rotation = (i % 2 == 0) and 1.1 or -1.1
        task.delay(0.022 * math.min(i, 14), function()
            if t.Parent then TweenEx(t, 0.42, Enum.EasingStyle.Quint, {Position = base, Rotation = 0}) end
        end)
    end
end

end

local function Tab(name, _y, _scroll)
    local f = New("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
        ScrollBarThickness = 3, ScrollBarImageColor3 = T.Stroke2, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
    }, TabHost)
    New("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, f)
    New("UIPadding", {
        PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 16),
        PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 16),
    }, f)
    tabs[name] = f
    return f
end

do
local function PaintNav()
    for n, e in pairs(NAVB) do
        local on = (n == curName)
        Tween(e.lbl, 0.2, {TextColor3 = on and T.Text or T.Sub})
        for _, it in ipairs(e.icon) do
            local col = on and T.Accent or T.Sub
            if it.st then Tween(it.st, 0.2, {Color = col}) else Tween(it.f, 0.2, {BackgroundColor3 = col}) end
        end
    end
end
onTheme(PaintNav)

function ShowTab(name)
    local e, frame = NAVB[name], tabs[name]
    if not (e and frame) then return end
    curName, curFrame = name, frame
    for n, f in pairs(tabs) do f.Visible = (n == name) end
    PaintNav()
    LAY.S3.kick(0.55)
    TweenEx(NavPill, 0.42, Enum.EasingStyle.Quint, {Position = UDim2.fromOffset(8, e.y)})
    TypeText(HeaderTitle, e.meta.title)
    HeaderSub.Text = e.meta.sub
    SetInfo("")
    TypeText(Crumb, "// " .. string.lower(name), 0.02)
    frame.Position = UDim2.fromOffset(26, 0)
    TweenEx(frame, 0.42, Enum.EasingStyle.Quint, {Position = UDim2.fromOffset(0, 0)})
    Scan.Position = UDim2.fromOffset(0, 54)
    Scan.BackgroundTransparency = 0.4
    TweenEx(Scan, 0.55, Enum.EasingStyle.Sine, {Position = UDim2.fromOffset(0, LAY.BODY_H - 4), BackgroundTransparency = 1})
    revealTab(frame)
    if tabHooks[name] then
        local hook = tabHooks[name]
        task.defer(function() pcall(hook) end)
    end
end

end

--------------------------------------------------------------------------------
-- PREVIEW 3D do seu personagem (clone dentro de um ViewportFrame, girando)
--------------------------------------------------------------------------------
local Previews = {}
local function MakePreview(parent, pos, size, caption)
    local holder = New("Frame", {
        Position = pos, Size = size, BackgroundColor3 = T.Bg, BorderSizePixel = 0, ClipsDescendants = true,
    }, parent)
    Round(holder, 8)
    Stroke(holder, T.Stroke, 1)
    local vp = New("ViewportFrame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 2, Ambient = Color3.fromRGB(150, 140, 150),
        LightColor = Color3.fromRGB(255, 236, 226), LightDirection = Vector3.new(-1, -1, -0.7),
    }, holder)
    local cam = New("Camera", {FieldOfView = 34}, vp)
    vp.CurrentCamera = cam
    -- pedestal 3D (disco + aro neon) e particulas orbitando o personagem
    local ped = New("Model", {Name = "Pedestal"}, vp)
    local function disc(h, d, col, mat)
        return New("Part", {
            Anchored = true, CanCollide = false, CastShadow = false, Material = mat, Color = col,
            Shape = Enum.PartType.Cylinder, Size = Vector3.new(h, d, d),
        }, ped)
    end
    local base = disc(0.35, 5.2, Color3.fromRGB(30, 25, 34), Enum.Material.SmoothPlastic)
    local rim = disc(0.06, 5.35, T.Accent, Enum.Material.Neon)
    local motes = {}
    for i = 1, 14 do
        motes[i] = {
            p = New("Part", {
                Anchored = true, CanCollide = false, CastShadow = false, Material = Enum.Material.Neon,
                Color = (i % 2 == 0) and T.Accent or T.Accent2, Size = Vector3.new(0.1, 0.1, 0.1),
            }, vp),
            sp = 0.35 + (i % 5) * 0.16, ph = i * 0.9,
        }
    end
    onTheme(function()
        rim.Color = T.Accent
        for i, m in ipairs(motes) do m.p.Color = (i % 2 == 0) and T.Accent or T.Accent2 end
    end)
    local scan = New("Frame", {
        Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = T.Accent, BackgroundTransparency = 0.5, BorderSizePixel = 0, ZIndex = 4,
    }, holder)
    bindAcc(scan, "BackgroundColor3")
    New("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1),
        }),
    }, scan)
    Label(holder, caption or "PREVIEW", 9, T.Faint, F.Mono, nil, UDim2.fromOffset(10, 8), UDim2.fromOffset(120, 12)).ZIndex = 3
    Label(holder, "arraste · scroll", 9, T.Faint, F.Mono, nil, UDim2.new(0, 10, 1, -20), UDim2.fromOffset(92, 12)).ZIndex = 3
    local rot = Label(holder, "000°", 9, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.new(1, -70, 1, -20), UDim2.fromOffset(60, 12))
    rot.ZIndex = 3
    local obj = {
        holder = holder, vp = vp, cam = cam, rot = rot, scan = scan, motes = motes, base = base, rim = rim,
        tab = CurTab, clone = nil, center = Vector3.new(0, 2.5, 0), dist = 9, h = 5.5, angle = 0, zoom = 1,
        idle = 3, t = 0, drag = false,
    }
    -- arrastar gira, scroll aproxima, e a rotacao automatica volta depois de 2s parado
    local lastX = 0
    holder.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            obj.drag, lastX, obj.idle = true, i.Position.X, 0
        end
    end)
    track(UserInputService.InputChanged:Connect(function(i)
        if obj.drag and i.UserInputType == Enum.UserInputType.MouseMovement then
            obj.angle = obj.angle - (i.Position.X - lastX) * 0.012
            lastX = i.Position.X
            obj.idle = 0
        end
    end))
    track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            obj.drag = false
        end
    end))
    holder.MouseWheelForward:Connect(function()
        obj.zoom = math.max(0.55, obj.zoom - 0.08)
        obj.idle = 0
    end)
    holder.MouseWheelBackward:Connect(function()
        obj.zoom = math.min(1.5, obj.zoom + 0.08)
        obj.idle = 0
    end)
    function obj.Refresh()
        local char = LocalPlayer.Character
        if not char or not holder.Parent then return end
        if obj.clone then
            obj.clone:Destroy()
            obj.clone = nil
        end
        local was = char.Archivable
        char.Archivable = true
        local ok, c = pcall(function() return char:Clone() end)
        char.Archivable = was
        if not (ok and c) then return end
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("ForceField") then
                d:Destroy()
            elseif d:IsA("BasePart") then
                d.Anchored = true
            end
        end
        c.Parent = vp
        obj.clone = c
        local okb, cf, sz = pcall(function() return c:GetBoundingBox() end)
        if okb then
            obj.center = cf.Position
            obj.h = sz.Y
            obj.dist = math.max(sz.Y * 1.2 / (2 * math.tan(math.rad(17))), 6) + sz.Z
            local fy = obj.center.Y - sz.Y / 2 - 0.18
            base.CFrame = CFrame.new(obj.center.X, fy, obj.center.Z) * CFrame.Angles(0, 0, math.pi / 2)
            rim.CFrame = CFrame.new(obj.center.X, fy + 0.2, obj.center.Z) * CFrame.Angles(0, 0, math.pi / 2)
        end
    end
    Previews[#Previews + 1] = obj
    task.defer(function() pcall(obj.Refresh) end)
    return obj
end

do
local refreshTok = 0
local function RefreshPreviews(delay)
    refreshTok = refreshTok + 1
    local tok = refreshTok
    task.delay(delay or 0.4, function()
        if tok ~= refreshTok then return end
        for _, p in ipairs(Previews) do pcall(p.Refresh) end
    end)
end
State.Touch = function()
    RefreshPreviews(0.6)
end
end

-- atualizacao por frame: so o que esta visivel (preview girando, logo 3D, grade, status)
do
local fpsAcc, fpsFrames, fpsShown, statAcc = 0, 0, 60, 0
track(RunService.Heartbeat:Connect(function(dt)
    local menuOn = Gui.Enabled and isOpen
    for _, lg in ipairs(Logos) do
        if lg.vp.Parent and (menuOn or lg.always) then
            lg.boost = lg.boost * math.exp(-dt * 2.2)
            lg.t = lg.t + dt * (1 + lg.boost * 6)
            lg.outer:PivotTo(CFrame.Angles(lg.t * 0.7, lg.t * 1.1, lg.t * 0.3))
            lg.inner:PivotTo(CFrame.Angles(-lg.t * 1.3, lg.t * 0.9, 0))
            if lg.extra then lg.extra(lg.t) end
        end
    end
    if not menuOn then return end
    for _, p in ipairs(Previews) do
        if p.holder.Parent and p.tab and p.tab.Visible then
            p.t = p.t + dt
            if not p.drag then
                p.idle = p.idle + dt
                if p.idle > 2 then p.angle = p.angle + dt * 0.8 end
            end
            local d = p.dist * p.zoom
            local pos = p.center + Vector3.new(math.sin(p.angle) * d, 0.6 + (p.zoom - 1) * 0.5, math.cos(p.angle) * d)
            p.cam.CFrame = CFrame.lookAt(pos, p.center)
            p.rot.Text = string.format("%03d°", math.floor(math.deg(p.angle) % 360))
            p.scan.Position = UDim2.new(0, 0, (p.t * 0.28) % 1, 0)
            for i, m in ipairs(p.motes) do
                local a = p.t * m.sp + m.ph
                local r = p.dist * 0.36 + math.sin(p.t * 0.6 + m.ph) * 0.35
                m.p.CFrame = CFrame.new(p.center.X + math.cos(a) * r,
                    p.center.Y + ((i / #p.motes) - 0.5) * p.h * 1.25 + math.sin(p.t + m.ph) * 0.2,
                    p.center.Z + math.sin(a) * r)
            end
        end
    end
    local m = UserInputService:GetMouseLocation()
    local sp, ss = Shell.AbsolutePosition, Shell.AbsoluteSize
    LAY.S3.update(dt, math.clamp((m.X - sp.X) / math.max(ss.X, 1) - 0.5, -0.8, 0.8) * 2,
        math.clamp((m.Y - sp.Y) / math.max(ss.Y, 1) - 0.5, -0.8, 0.8) * 2)
    LAY.Sheen.Position = UDim2.new(-0.3 + ((os.clock() % 7) / 7) * 1.6, 0, 0.5, 0)
    fpsAcc = fpsAcc + dt
    fpsFrames = fpsFrames + 1
    statAcc = statAcc + dt
    if statAcc >= 0.5 then
        fpsShown = math.floor(fpsFrames / fpsAcc + 0.5)
        fpsAcc, fpsFrames, statAcc = 0, 0, 0
        local ping = 0
        pcall(function()
            ping = math.floor(game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue() + 0.5)
        end)
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        local rig = hum and tostring(hum.RigType):gsub("Enum.HumanoidRigType.", "") or "-"
        local P = LAY.Perf
        P.fps[#P.fps + 1] = fpsShown
        P.ping[#P.ping + 1] = ping
        if #P.fps > 60 then table.remove(P.fps, 1) end
        if #P.ping > 60 then table.remove(P.ping, 1) end
        pcall(function() P.mem = game:GetService("Stats"):GetTotalMemoryUsageMb() end)
        if LAY.PerfDraw and curName == "Desempenho" then LAY.PerfDraw() end
        local wn = 0
        for _ in pairs(State.Wardrobe) do wn = wn + 1 end
        LAY.StL.Text = string.format("%s   %s   itens %d   partes %d", execName, rig, #State.Catalog, wn)
        LAY.StR.Text = string.format("%d fps   %d ms   RCtrl", fpsShown, ping)
    end
end))
end

--------------------------------------------------------------------------------
-- CLONAR
--------------------------------------------------------------------------------
do
CurTab = Tab("Clonar", 0, true)
Persist.Scope = "cloner"
Section("Alvo")
local PreviewImg, Input
do
    local card = Row(210)
    MakePreview(card, UDim2.fromOffset(12, 12), UDim2.fromOffset(190, 186), "SEU AVATAR")
    Label(card, "ALVO", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(218, 14), UDim2.fromOffset(100, 14))
    PreviewImg = New("ImageLabel", {
        Size = UDim2.fromOffset(52, 52), Position = UDim2.fromOffset(218, 34), BackgroundColor3 = T.Bg, BorderSizePixel = 0,
        Image = "rbxasset://textures/ui/GuiImagePlaceholder.png", ScaleType = Enum.ScaleType.Crop,
    }, card)
    Round(PreviewImg, 26)
    Stroke(PreviewImg, T.Stroke2, 1)
    Input = Field(card, UDim2.fromOffset(280, 42), UDim2.new(1, -294, 0, 36), "usuário ou UserId...", Persist.Get("cloner:user", ""))
    Label(card, "digite um usuário ou UserId e clique em clonar", 10, T.Faint, F.Mono, nil,
        UDim2.fromOffset(218, 98), UDim2.new(1, -232, 0, 14))
    local busy = false
    Button(card, "CLONAR AVATAR", UDim2.fromOffset(218, 124), UDim2.new(1, -232, 0, 42), T.Accent, function()
        if busy then return end
        if #Input.Text == 0 then
            Toast("digite um usuário primeiro", false)
            return
        end
        busy = true
        task.spawn(function()
            local ok, err = pcall(function()
                local id = Morph.ResolveUserId(Input.Text)
                if id then
                    PreviewImg.Image = Morph.Thumb(id)
                    Morph.ApplyFull(id, Toast)
                else
                    Toast("usuário não encontrado", false)
                end
            end)
            if not ok then
                Log.add("ERRO", "clonar: " .. tostring(err))
                Toast("falha ao clonar (veja o registro em Config)", false)
            end
            busy = false
        end)
    end)
    Button(card, "RESTAURAR ORIGINAL", UDim2.fromOffset(218, 172), UDim2.new(1, -232, 0, 26), T.Bad, function()
        Morph.Reset(Toast)
    end)
end
local function loadThumb()
    if #Input.Text == 0 then return end
    task.spawn(function()
        local id = Morph.ResolveUserId(Input.Text)
        if id then PreviewImg.Image = Morph.Thumb(id) end
    end)
end
Input.FocusLost:Connect(function()
    Persist.Set("cloner:user", Input.Text)
    loadThumb()
end)
loadThumb()
Section("Opções")
Toggle("Reaplicar ao renascer", State.AutoReapplyOnRespawn, function(v)
    State.AutoReapplyOnRespawn = v
    Toast(v and "reaplicar ao renascer: ligado" or "reaplicar ao renascer: desligado", v)
end, "Reapply on respawn")
end

--------------------------------------------------------------------------------
-- CORPO
--------------------------------------------------------------------------------
local Colors = {State = {}}
do
CurTab = Tab("Corpo", 0, true)
Persist.Scope = "body"
    -- engine de cores do corpo (so no seu cliente): BodyColors + cor direta das partes, travada contra reset do jogo
    local COLOR_GROUPS = {
        {id = "Head", label = "Cabeça", parts = {"Head"}, r6 = {"Head"}},
        {id = "Torso", label = "Tronco", parts = {"UpperTorso", "LowerTorso"}, r6 = {"Torso"}},
        {id = "LeftArm", label = "Braço esquerdo", parts = {"LeftUpperArm", "LeftLowerArm", "LeftHand"}, r6 = {"Left Arm"}},
        {id = "RightArm", label = "Braço direito", parts = {"RightUpperArm", "RightLowerArm", "RightHand"}, r6 = {"Right Arm"}},
        {id = "LeftLeg", label = "Perna esquerda", parts = {"LeftUpperLeg", "LeftLowerLeg", "LeftFoot"}, r6 = {"Left Leg"}},
        {id = "RightLeg", label = "Perna direita", parts = {"RightUpperLeg", "RightLowerLeg", "RightFoot"}, r6 = {"Right Leg"}},
    }
    local COLOR_BY = {}
    local BC_PROP = {Head = "HeadColor3", Torso = "TorsoColor3", LeftArm = "LeftArmColor3", RightArm = "RightArmColor3",
        LeftLeg = "LeftLegColor3", RightLeg = "RightLegColor3"}
    local colorConns = {}
    local colorOrig = setmetatable({}, {__mode = "k"})
    for _, g in ipairs(COLOR_GROUPS) do
        COLOR_BY[g.id] = g
        colorConns[g.id] = {}
    end
    local function groupParts(char, g)
        local out = {}
        for _, n in ipairs(g.parts) do
            local p = char:FindFirstChild(n)
            if p and p:IsA("BasePart") then out[#out + 1] = p end
        end
        if #out == 0 then
            for _, n in ipairs(g.r6) do
                local p = char:FindFirstChild(n)
                if p and p:IsA("BasePart") then out[#out + 1] = p end
            end
        end
        return out
    end
    Colors.OnChange = function(_id, _c) end
    function Colors.Apply(id, c)
        local g = COLOR_BY[id]
        if not g then return end
        Colors.State[id] = c
        Colors.OnChange(id, c)
        local char = LocalPlayer.Character
        if not char then return end
        clearConns(colorConns[id])
        local bc = char:FindFirstChildOfClass("BodyColors")
        if bc then bc[BC_PROP[id]] = c end
        for _, p in ipairs(groupParts(char, g)) do
            if colorOrig[p] == nil then colorOrig[p] = p.Color end
            p.Color = c
            colorConns[id][#colorConns[id] + 1] = p:GetPropertyChangedSignal("Color"):Connect(function()
                if p.Color ~= c then p.Color = c end
            end)
        end
    end
    function Colors.Reset(id)
        local g = COLOR_BY[id]
        if not g then return end
        clearConns(colorConns[id])
        Colors.State[id] = nil
        Colors.OnChange(id, nil)
        local char = LocalPlayer.Character
        if not char then return end
        for _, p in ipairs(groupParts(char, g)) do
            if colorOrig[p] ~= nil then p.Color = colorOrig[p] end
        end
    end
    function Colors.ResetAll()
        for _, g in ipairs(COLOR_GROUPS) do
            if Colors.State[g.id] ~= nil then Colors.Reset(g.id) end
        end
    end
    function Colors.Reapply()
        local list = {}
        for id, c in pairs(Colors.State) do list[#list + 1] = {id, c} end
        for _, it in ipairs(list) do Colors.Apply(it[1], it[2]) end
        return #list
    end
    State.ColorsReapply = function()
        task.spawn(function()
            task.wait(0.6)
            Colors.Reapply()
        end)
    end
    for _, g in ipairs(COLOR_GROUPS) do
        local sv = Persist.Get("color:" .. g.id, nil)
        if type(sv) == "table" and type(sv[1]) == "number" and type(sv[2]) == "number" and type(sv[3]) == "number" then
            Colors.State[g.id] = Color3.fromRGB(math.clamp(sv[1], 0, 255), math.clamp(sv[2], 0, 255), math.clamp(sv[3], 0, 255))
        end
    end
    Colors.OnChange = function(id, c)
        Persist.Set("color:" .. id, c and {math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)} or nil)
    end

Section("Cabeça")
do
    local row = Row(56)
    Label(row, "Headless", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 10), UDim2.new(0.5, 0, 0, 18))
    Label(row, "esconde a cabeça e o rosto", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 30), UDim2.new(0.6, 0, 0, 14))
    local st = Label(row, State.IsHeadless and "ATIVO" or "INATIVO", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right,
        UDim2.new(1, -236, 0, 0), UDim2.fromOffset(100, 56))
    Button(row, "ALTERNAR", UDim2.new(1, -118, 0.5, -15), UDim2.fromOffset(104, 30), T.Card, function()
        local s = not State.IsHeadless
        Morph.SetHeadless(s)
        st.Text = s and "ATIVO" or "INATIVO"
        st.TextColor3 = s and T.Accent or T.Faint
        Toast(s and "headless ligado" or "headless desligado", true)
    end)
end

Section("Korblox")
local function LegRow(side, defaultId, title)
    local row = Row(80)
    Label(row, title, 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 8), UDim2.new(0.5, 0, 0, 18))
    local mode = Label(row, "desligado", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right,
        UDim2.new(0.5, 0, 0, 8), UDim2.new(0.5, -16, 0, 18))
    local saved = Persist.Get("body:leg" .. side, nil)
    local txt = (saved ~= nil) and tostring(saved) or (defaultId and tostring(defaultId) or "")
    local box = Field(row, UDim2.fromOffset(14, 36), UDim2.new(1, -148, 0, 34), "ID da perna " .. (side == "Right" and "direita" or "esquerda") .. "...", txt)
    box.FocusLost:Connect(function() Persist.Set("body:leg" .. side, box.Text) end)
    Button(row, "KORBLOX", UDim2.new(1, -126, 0, 36), UDim2.fromOffset(112, 34), T.Accent, function()
        local s = not State.Korblox[side]
        local id = parseId(box.Text)
        task.spawn(function()
            local ok, info = Morph.SetKorblox(side, s, id)
            if ok and info == "superseded" then return end
            if ok then
                mode.Text = s and tostring(info) or "desligado"
                mode.TextColor3 = s and T.Accent or T.Faint
                Toast("korblox " .. (side == "Right" and "direito" or "esquerdo") .. (s and (" ligado (" .. tostring(info) .. ")") or " desligado"), true)
            else
                Toast(tostring(info or "korblox falhou"), false)
            end
        end)
    end)
end
LegRow("Right", 139607718, "Perna direita")
LegRow("Left", nil, "Perna esquerda")

local function refitLegs()
    for _, side in ipairs({"Right", "Left"}) do
        if State.Korblox[side] then
            task.spawn(function() Morph.SetKorblox(side, true) end)
        end
    end
end
Toggle("Corrigir vão (pé flutuando)", State.GapFix, function(v)
    State.GapFix = v
    refitLegs()
    Toast("corrigir vão: " .. (v and "ligado" or "desligado"), true)
end, "Gap fix (no floating feet)")
Toggle("Pernas retas", State.Straight, function(v)
    State.Straight = v
    refitLegs()
    Toast("pernas retas: " .. (v and "ligado" or "desligado"), true)
end, "Straight legs")

Section("Cores do corpo")
do
    local ready = false
    local TARGET_SETS = {
        all = {"Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg"},
        head = {"Head"}, torso = {"Torso"}, arms = {"LeftArm", "RightArm"}, legs = {"LeftLeg", "RightLeg"},
    }
    local target = "all"
    local H, S, V = 0.07, 0.38, 0.92
    local picked = Color3.fromHSV(H, S, V)
    local swatch, hexLbl
    local function setPicked()
        picked = Color3.fromHSV(H, S, V)
        if swatch then swatch.BackgroundColor3 = picked end
        if hexLbl then
            hexLbl.Text = string.format("#%02X%02X%02X", math.floor(picked.R * 255 + 0.5), math.floor(picked.G * 255 + 0.5), math.floor(picked.B * 255 + 0.5))
        end
    end
    local function applyPicked()
        for _, id in ipairs(TARGET_SETS[target]) do Colors.Apply(id, picked) end
    end
    do
        local row = Row(58)
        Label(row, "Aplicar em", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.fromOffset(90, 58))
        Segmented(row, {
            {id = "all", label = "Tudo"}, {id = "head", label = "Cabeça"}, {id = "torso", label = "Tronco"},
            {id = "arms", label = "Braços"}, {id = "legs", label = "Pernas"},
        }, target, function(id) target = id end, 110, 13, 82, 32, 6)
    end
    local hS = Slider("Matiz", 0, 360, H * 360, "%d°", function(v)
        H = v / 360
        setPicked()
        if ready then applyPicked() end
    end, "colorH")
    local sS = Slider("Saturação", 0, 100, S * 100, "%d%%", function(v)
        S = v / 100
        setPicked()
        if ready then applyPicked() end
    end, "colorS")
    local vS = Slider("Brilho", 0, 100, V * 100, "%d%%", function(v)
        V = v / 100
        setPicked()
        if ready then applyPicked() end
    end, "colorV")
    do
        local row = Row(70)
        swatch = New("Frame", {
            Size = UDim2.fromOffset(46, 46), Position = UDim2.fromOffset(16, 12), BackgroundColor3 = picked, BorderSizePixel = 0,
        }, row)
        Round(swatch, 8)
        Stroke(swatch, T.Stroke2, 1)
        hexLbl = Label(row, "", 13, T.Text, F.Mono, nil, UDim2.fromOffset(74, 12), UDim2.fromOffset(120, 18))
        Label(row, "cor escolhida", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(74, 34), UDim2.fromOffset(120, 14))
        local pal = {
            Color3.fromRGB(255, 224, 189), Color3.fromRGB(241, 194, 125), Color3.fromRGB(224, 172, 105), Color3.fromRGB(198, 134, 66),
            Color3.fromRGB(141, 85, 36), Color3.fromRGB(92, 58, 30), Color3.fromRGB(255, 58, 96), Color3.fromRGB(255, 176, 84),
            Color3.fromRGB(86, 190, 255), Color3.fromRGB(82, 214, 140), Color3.fromRGB(190, 112, 255), Color3.fromRGB(240, 240, 240),
        }
        for i, c in ipairs(pal) do
            local b = New("TextButton", {
                Text = "", AutoButtonColor = false, BackgroundColor3 = c, BorderSizePixel = 0,
                Size = UDim2.fromOffset(24, 24), Position = UDim2.fromOffset(196 + ((i - 1) % 6) * 30, 12 + math.floor((i - 1) / 6) * 30),
            }, row)
            Round(b, 6)
            Stroke(b, T.Stroke2, 1)
            b.MouseEnter:Connect(function() TweenEx(b, 0.2, Enum.EasingStyle.Back, {Size = UDim2.fromOffset(28, 28)}) end)
            b.MouseLeave:Connect(function() Tween(b, 0.2, {Size = UDim2.fromOffset(24, 24)}) end)
            b.MouseButton1Click:Connect(Safe(function()
                local h, s, v = c:ToHSV()
                H, S, V = h, s, v
                hS.Set(h * 360)
                sS.Set(s * 100)
                vS.Set(v * 100)
                setPicked()
                applyPicked()
            end, "paleta de cores"))
        end
    end
    setPicked()
    ready = true
    BtnPair("Resetar o grupo escolhido", T.Card, function()
        for _, id in ipairs(TARGET_SETS[target]) do Colors.Reset(id) end
        Toast("cores do grupo voltaram ao original", true)
    end, "Resetar todas as cores", T.Card, function()
        Colors.ResetAll()
        Toast("todas as cores voltaram ao original", true)
    end, 40)
end

Section("Restaurar")
BtnRow("Restaurar avatar original", T.Bad, function()
    Morph.Reset(Toast)
end, 40)
BtnPair("Resetar escala", T.Card, function()
    Toast(Morph.ResetScales() and "escala resetada" or "humanoid não encontrado", true)
end, "Dump (copiar)", T.Card, function()
    local ok, copied = pcall(Morph.Dump)
    if not ok then Toast("dump falhou, veja o console", false)
    elseif copied then Toast("dump copiado pro clipboard", true)
    else Toast("dump impresso no console (F9)", true) end
end, 40)
end

--------------------------------------------------------------------------------
-- ROUPA (partes do corpo por ID)
--------------------------------------------------------------------------------
do
CurTab = Tab("Roupa", 0, true)
Persist.Scope = "roupa"
local wardUI = {}
local function wardBadge()
    local n = 0
    for _ in pairs(State.Wardrobe) do n = n + 1 end
    SetBadge("Roupa", n > 0 and tostring(n) or "")
end
local function slotRefresh(field)
    local u = wardUI[field]
    if not u then return end
    local id = State.Wardrobe[field]
    if id then
        u.thumb.Image = "rbxthumb://type=Asset&id=" .. tostring(id) .. "&w=150&h=150"
        u.glyph.Visible = false
        u.chip.Text = "ATIVO"
        bindAcc(u.chip, "TextColor3")
        u.meta.Text = "id " .. tostring(id)
        u.box.Text = tostring(id)
    else
        u.thumb.Image = ""
        u.glyph.Visible = true
        u.chip.Text = "PADRÃO"
        unbindAcc(u.chip, "TextColor3")
        u.chip.TextColor3 = T.Faint
        u.meta.Text = "id -"
    end
    wardBadge()
end
for _, w in ipairs(WARD) do
    local saved = Persist.Get("roupa:" .. w.field, nil)
    if type(saved) == "number" then State.Wardrobe[w.field] = saved end
end
State.OnWardChange = function(field, id)
    Persist.Set("roupa:" .. field, id)
    slotRefresh(field)
end
local busyField = {}
local function applySlot(field, id)
    if busyField[field] then return end
    busyField[field] = true
    local u = wardUI[field]
    u.chip.Text = "APLICANDO..."
    task.spawn(function()
        local okc, ok, info = pcall(Ward.Apply, field, id)
        busyField[field] = nil
        if not okc then
            Log.add("ERRO", "roupa " .. field .. ": " .. tostring(ok))
            Toast("falha ao aplicar (veja o registro em Config)", false)
        elseif ok then
            Toast(WARD_BY[field].label .. " aplicada · " .. tostring(info), true)
        else
            Toast(tostring(info), false)
        end
        slotRefresh(field)
    end)
end

Section("Preview e atalhos")
do
    local card = Row(196)
    MakePreview(card, UDim2.fromOffset(12, 12), UDim2.fromOffset(176, 172), "PREVIEW")
    local hint = Label(card, "Cole o ID de qualquer parte (ou o link do catálogo / rolimons). APLICAR troca na hora, LIMPAR volta ao original. Fica salvo e reaplica ao renascer.",
        11, T.Sub, F.Body, nil, UDim2.fromOffset(204, 12), UDim2.new(1, -218, 0, 66))
    hint.TextWrapped = true
    hint.TextYAlignment = Enum.TextYAlignment.Top
    Button(card, "KORBLOX DEATHWALKER · CABEÇA", UDim2.fromOffset(204, 92), UDim2.new(1, -218, 0, 36), T.Card, function()
        if wardUI.Head then wardUI.Head.box.Text = "16580493236" end
        applySlot("Head", 16580493236)
    end)
    Button(card, "LIMPAR TODAS AS PARTES", UDim2.fromOffset(204, 136), UDim2.new(1, -218, 0, 36), T.Bad, function()
        task.spawn(function()
            Ward.ClearAll()
            Toast("todas as partes voltaram ao original", true)
        end)
    end)
end

Section("Peças")
local wardGrid = New("Frame", {
    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder(),
}, CurTab)
wardGrid:SetAttribute("Grid", true)
New("UIGridLayout", {
    CellSize = UDim2.fromOffset(266, 150), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder,
}, wardGrid)
for i, w in ipairs(WARD) do
    local card = MakeCard(wardGrid, UDim2.fromOffset(266, 150), i)
    local thumb = New("ImageLabel", {
        Size = UDim2.fromOffset(56, 56), Position = UDim2.fromOffset(12, 12), BackgroundColor3 = T.Bg, BorderSizePixel = 0,
        Image = "", ScaleType = Enum.ScaleType.Fit,
    }, card)
    Round(thumb, 6)
    Stroke(thumb, T.Stroke2, 1)
    local glyph = Label(thumb, "+", 20, T.Faint, F.Mono, Enum.TextXAlignment.Center, UDim2.new(), UDim2.fromScale(1, 1))
    Label(card, w.label, 13, T.Text, F.Bold, nil, UDim2.fromOffset(80, 12), UDim2.new(1, -92, 0, 18))
    local chip = Label(card, "PADRÃO", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(80, 32), UDim2.new(1, -92, 0, 14))
    local meta = Label(card, "id -", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(80, 48), UDim2.new(1, -92, 0, 14))
    local box = Field(card, UDim2.fromOffset(12, 80), UDim2.new(1, -24, 0, 30), "id ou link...", "")
    wardUI[w.field] = {thumb = thumb, glyph = glyph, chip = chip, meta = meta, box = box}
    Button(card, "APLICAR", UDim2.fromOffset(12, 118), UDim2.new(0.5, -17, 0, 26), T.Accent, function()
        local id = parseId(box.Text)
        if not id then
            Toast("cole um ID válido", false)
            return
        end
        applySlot(w.field, id)
    end)
    Button(card, "LIMPAR", UDim2.new(0.5, 5, 0, 118), UDim2.new(0.5, -17, 0, 26), T.Card, function()
        box.Text = ""
        task.spawn(function()
            Ward.Clear(w.field)
            Toast(w.label .. " voltou ao original", true)
        end)
    end)
    slotRefresh(w.field)
end
end

--------------------------------------------------------------------------------
-- CATALOGO: qualquer ID. O tipo e detectado: acessorio/roupa/rosto/tool/efeito
-- ficam na lista, parte do corpo vai direto pra aba Roupa.
--------------------------------------------------------------------------------
local Cat = {}
do
CurTab = Tab("Catálogo", 0, true)
Persist.Scope = "cat"
local ASSET_BODY = {[17] = "Head", [27] = "Torso", [28] = "RightArm", [29] = "LeftArm", [30] = "LeftLeg", [31] = "RightLeg"}
local catCards = {}
local gridHolder, emptyCard
local refreshCatalog = function() end

local function catFind(id)
    for i, e in ipairs(State.Catalog) do
        if e.id == id then return e, i end
    end
    return nil, nil
end
local function catAnchor(char)
    return char:FindFirstChild("Head") or char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
end
local function productInfo(id)
    local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(id)
    end)
    if ok and type(info) == "table" then return info end
    return nil
end
local function assetTypeName(tid)
    for _, it in ipairs(Enum.AssetType:GetEnumItems()) do
        if it.Value == tid then return it.Name end
    end
    return "Asset"
end
local function catLoad(id)
    local ok, objs = pcall(game.GetObjects, game, "rbxassetid://" .. tostring(id))
    if not (ok and objs) or #objs == 0 then return nil, "asset não carregou" end
    for _, o in ipairs(objs) do
        if o:IsA("Accessory") or o:IsA("Tool") or o:IsA("Shirt") or o:IsA("Pants") or o:IsA("ShirtGraphic") or o:IsA("Decal") then
            return o
        end
    end
    for _, o in ipairs(objs) do
        local c = o:FindFirstChildWhichIsA("Accessory") or o:FindFirstChildWhichIsA("Tool")
        if c then return c end
    end
    for _, o in ipairs(objs) do
        if o:IsA("Model") or o:IsA("Folder") then return o end
    end
    return objs[1]
end

-- monta o item no personagem. devolve {inst, stash, stashParent} ou (nil, motivo)
local function catAttach(char, obj, id)
    obj:SetAttribute("SilkcoreCatalog", id)
    if obj:IsA("Accessory") then
        sanitize(obj)
        Morph.Mount(char, obj)
        if obj.Parent ~= char then
            obj:Destroy()
            return nil, "acessório sem handle"
        end
        return {inst = obj}
    end
    if obj:IsA("Tool") then
        sanitize(obj)
        obj.Parent = char
        return {inst = obj}
    end
    if obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("ShirtGraphic") then
        local old = char:FindFirstChildOfClass(obj.ClassName)
        local res = {inst = obj}
        if old then
            res.stash, res.stashParent = old, old.Parent
            old.Parent = nil
        end
        obj.Parent = char
        return res
    end
    if obj:IsA("Decal") then
        local head = char:FindFirstChild("Head")
        if not head then
            obj:Destroy()
            return nil, "sem cabeça"
        end
        local old = head:FindFirstChild("face")
        local res = {inst = obj}
        if old then
            res.stash, res.stashParent = old, head
            old.Parent = nil
        end
        obj.Name = "face"
        obj.Parent = head
        return res
    end
    -- model/folder: pode ter parte(s) e/ou particulas/beam/trail
    local anchor = catAnchor(char)
    if not anchor then
        obj:Destroy()
        return nil, "sem parte de ancoragem"
    end
    obj.Parent = char
    sanitize(obj)
    local parts = {}
    for _, p in ipairs(obj:GetDescendants()) do
        if p:IsA("BasePart") then parts[#parts + 1] = p end
    end
    if #parts == 0 then
        local holder = Instance.new("Part")
        holder.Name = "SilkcoreFxHolder"
        holder.Transparency, holder.Size = 1, Vector3.new(0.2, 0.2, 0.2)
        holder.CanCollide, holder.CanTouch, holder.CanQuery, holder.Massless = false, false, false, true
        holder.CFrame = anchor.CFrame
        for _, c in ipairs(obj:GetChildren()) do c.Parent = holder end
        obj:Destroy()
        obj = holder
        obj.Parent = char
        parts = {holder}
    end
    if obj:IsA("Model") then
        pcall(obj.PivotTo, obj, anchor.CFrame)
    else
        parts[1].CFrame = anchor.CFrame
    end
    for _, p in ipairs(parts) do
        local w = Instance.new("WeldConstraint")
        w.Part0, w.Part1 = p, anchor
        w.Parent = p
    end
    return {inst = obj}
end

local function catSave()
    local ids = {}
    for _, e in ipairs(State.Catalog) do
        if not e.pending then ids[#ids + 1] = e.id end
    end
    Persist.Set("catalog:ids", ids)
end
local function catDropEntry(e)
    local _, idx = catFind(e.id)
    if idx then table.remove(State.Catalog, idx) end
end
local function catKill(e)
    if e.inst and e.inst.Parent then e.inst:Destroy() end
    if e.stash and e.stashParent and e.stashParent.Parent then e.stash.Parent = e.stashParent end
    e.inst, e.stash = nil, nil
end
function Cat.Remove(id)
    local e = catFind(id)
    if not e then return end
    catKill(e)
    catDropEntry(e)
    catSave()
    refreshCatalog()
    State.Touch()
end
function Cat.ClearAll(keepSaved)
    for i = #State.Catalog, 1, -1 do
        catKill(State.Catalog[i])
        State.Catalog[i] = nil
    end
    if not keepSaved then catSave() end
    refreshCatalog()
    State.Touch()
end

-- sincrono (usa yields): devolve ok, mensagem
-- detail (opcional) vem do browse: {name, assetType}. Sem ele, cada APLICAR
-- gastava uma requisição bloqueante só pra descobrir o tipo de um item que a
-- grade já tinha na mão — era boa parte do lag no clique.
local function doAdd(id, quiet, detail)
    if catFind(id) then return false, "já adicionado: " .. tostring(id) end
    local entry = {id = id, pending = true, name = "carregando...", meta = "id " .. tostring(id)}
    State.Catalog[#State.Catalog + 1] = entry
    refreshCatalog()
    local char = Morph.Char()
    local tid, nm
    if detail and detail.assetType and detail.name then
        tid, nm = tonumber(detail.assetType), tostring(detail.name)
    else
        local info = productInfo(id)
        tid = info and tonumber(info.AssetTypeId) or nil
        nm  = info and info.Name or nil
    end
    if nm then entry.name = tostring(nm) end
    entry.meta = (tid and assetTypeName(tid) or "Asset") .. " · " .. tostring(id)
    local field = tid and ASSET_BODY[tid] or nil
    if field then
        catDropEntry(entry)
        refreshCatalog()
        local ok, msg = Ward.Apply(field, id)
        if ok then return true, WARD_BY[field].label .. " aplicada (veja a aba Roupa)" end
        return false, tostring(msg)
    end
    local obj, err = catLoad(id)
    local res
    if obj then res, err = catAttach(char, obj, id) end
    if catFind(id) ~= entry then
        if res and res.inst then res.inst:Destroy() end
        return false, "removido durante o carregamento"
    end
    if not res then
        catDropEntry(entry)
        refreshCatalog()
        return false, tostring(err or "falhou") .. " (" .. tostring(id) .. ")"
    end
    entry.inst, entry.stash, entry.stashParent = res.inst, res.stash, res.stashParent
    entry.pending = false
    if not quiet then catSave() end
    refreshCatalog()
    State.Touch()
    return true, "adicionado: " .. entry.name
end
local function catAdd(id, cb, quiet, detail)
    task.spawn(function()
        local okc, ok, msg = pcall(doAdd, id, quiet, detail)
        if not okc then
            Log.add("ERRO", "catálogo " .. tostring(id) .. ": " .. tostring(ok))
            ok, msg = false, "erro interno (veja o registro em Config)"
            local e = catFind(id)
            if e then
                catDropEntry(e)
                refreshCatalog()
            end
        end
        if cb then cb(ok, msg) end
    end)
end
Cat.Add = doAdd
function Cat.Ids()
    local ids = {}
    for _, e in ipairs(State.Catalog) do
        if not e.pending then ids[#ids + 1] = e.id end
    end
    return ids
end
function Cat.RestoreAll()
    local ids = Persist.Get("catalog:ids", {})
    local n = 0
    if type(ids) ~= "table" then return 0 end
    for _, raw in ipairs(ids) do
        local id = tonumber(raw)
        if id then
            local okc, ok = pcall(doAdd, id, true)
            if okc and ok then n = n + 1 end
            task.wait(0.1)
        end
    end
    return n
end
State.CatalogReapply = function()
    task.spawn(function()
        task.wait(0.8)
        for i = #State.Catalog, 1, -1 do State.Catalog[i] = nil end
        refreshCatalog()
        Cat.RestoreAll()
    end)
end


-- ══════════════════════════════════════════════════════════════════════════════
-- CATALOG BROWSE ENGINE — injected into Catálogo tab
-- Browse completo do catálogo Roblox: por categoria, busca, thumb grid, APLICAR.
-- Body-safety: volleyball = block-only. HBG = aceita qualquer corpo.
-- R6 / R15 compat via catAdd existente (detecta tipo, roteia Ward se body part).
-- ══════════════════════════════════════════════════════════════════════════════

-- ── game profile ──────────────────────────────────────────────────────────────
local function _buildBrowse()
local _VOLLEYBALL_IDS = {
    [9358981663]=true,[4645842232]=true,[301549746]=true,
    [3669573733]=true,[5295493007]=true,[7126492541]=true,
}
local _HBG_IDS = {
    [2788229376]=true,[5765273346]=true,[5765275050]=true,
}
local _CUR_PLACE = game.PlaceId
local function _isVolleyball() return _VOLLEYBALL_IDS[_CUR_PLACE] == true end
local function _isHBG()        return _HBG_IDS[_CUR_PLACE] == true end
local function _blockBodyGame()
    if _isHBG() then return false end
    if _isVolleyball() then return true end
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    local bts = hum:FindFirstChild("BodyTypeScale")
    local bws = hum:FindFirstChild("BodyWidthScale")
    return (bts and bts.Value < 0.05) and (bws and bws.Value > 0.95)
end

-- ── asset type info ───────────────────────────────────────────────────────────
local _AT = {
    [8]  = {label="Chapéu",    body=false},
    [41] = {label="Cabelo",    body=false},
    [18] = {label="Rosto",     body=false},
    [11] = {label="Camisa",    body=false},
    [12] = {label="Calça",     body=false},
    [2]  = {label="T-Shirt",   body=false},
    [17] = {label="Cabeça",    body=true, field="Head"},
    [27] = {label="Tronco",    body=true, field="Torso"},
    [28] = {label="Braço Dir", body=true, field="RightArm"},
    [29] = {label="Braço Esq", body=true, field="LeftArm"},
    [30] = {label="Perna Esq", body=true, field="LeftLeg"},
    [31] = {label="Perna Dir", body=true, field="RightLeg"},
    [40] = {label="Pacote",    body=true, field=nil},
    [61] = {label="Acessório", body=false},
    [64] = {label="Acessório", body=false},
    [65] = {label="Acessório", body=false},
}

-- ── body-safety ───────────────────────────────────────────────────────────────
local function _safeForGame(assetId, assetTypeId)
    if _isHBG() then return true end
    if not _blockBodyGame() then return true end
    local info = _AT[assetTypeId]
    if not info or not info.body then return true end
    local ok, safe = pcall(function()
        local d = Instance.new("HumanoidDescription")
        if info.field then d[info.field] = assetId end
        local rig = Players:CreateHumanoidModelFromDescription(d, Enum.HumanoidRigType.R15)
        if not rig then return true end
        local h2 = rig:FindFirstChildOfClass("Humanoid")
        local pass = true
        if h2 then
            local bts2 = h2:FindFirstChild("BodyTypeScale")
            local bws2 = h2:FindFirstChild("BodyWidthScale")
            if bts2 and bts2.Value > 0.1 then pass = false end
            if bws2 and bws2.Value < 0.9  then pass = false end
        end
        rig:Destroy()
        return pass
    end)
    return ok and safe or true
end

-- ── http / json ───────────────────────────────────────────────────────────────
local _httpFn = (syn and syn.request)
    or (typeof(request)      == "function" and request)
    or (typeof(http_request) == "function" and http_request)
    or (typeof(http)         == "table"    and http.request)
    or nil

-- ── http / json ───────────────────────────────────────────────────────────────
-- HttpService:RequestAsync não existe no cliente — o Roblox só permite essa API
-- no servidor. O código antigo tentava ela primeiro, gastando um erro por
-- requisição antes de cair no request() do executor. Aqui o request() vem
-- primeiro: é o único que funciona de dentro do cliente.
local _lastHttp = "nada ainda"

-- O executor anexa Roblox-Place-Id em toda requisição — herda do stack HTTP do
-- jogo — e o catálogo recusa por causa disso:
--   403 code 22 "In-experience search is denied for this place or universe."
-- Comprovado nos dois sentidos, aqui:
--   header preenchido  -> 403
--   header ausente     -> 200
--   header = "none"    -> 200
-- Isso NÃO resolve dentro do jogo: o executor escreve o valor dele depois do
-- nosso, então continua 403 (ver o bloco de hosts). Os headers ficam porque
-- quando o valor nosso vence — executor que mescla em tabela e não concatena,
-- ou execução fora do jogo — a chamada direta volta a valer e é a via mais
-- rápida. Não é a solução; é a primeira tentativa.
local _HDRS = {
    ["Accept"]          = "application/json",
    ["User-Agent"]      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36",
    ["Roblox-Place-Id"] = "none",
    ["roblox-place-id"] = "none",
    ["Roblox-Game-Id"]  = "none",
    ["roblox-game-id"]  = "none",
}

-- Devolve corpo e status. O status por host é o que alimenta o registro da tela:
-- sem ele, "403" não diz de quem é o 403 nem se é o gate do place.
local function _httpGet(url)
    if _httpFn then
        local ok, res = pcall(_httpFn, {
            Url = url, Method = "GET",
            Headers = _HDRS,
        })
        if ok and type(res) == "table" and type(res.Body) == "string" then
            local st = tonumber(res.StatusCode) or 0
            _lastHttp = "HTTP " .. tostring(st)
            if #res.Body > 10 then return res.Body, st end
        else
            _lastHttp = "request falhou: " .. tostring(res):sub(1, 70)
        end
    else
        _lastHttp = "executor sem request()"
    end

    local ok1, res1 = pcall(function()
        return HttpService:RequestAsync({
            Url = url, Method = "GET",
            Headers = { ["Accept"] = "application/json" },
        })
    end)
    if ok1 and res1 and res1.Success and res1.Body and #res1.Body > 10 then
        _lastHttp = "RequestAsync HTTP " .. tostring(res1.StatusCode)
        return res1.Body, tonumber(res1.StatusCode) or 0
    end

    local ok3, body3 = pcall(function() return game:HttpGet(url) end)
    if ok3 and body3 and #body3 > 10 then
        _lastHttp = "game:HttpGet"
        return body3, 0
    end

    return nil
end

local function _jsonDecode(s)
    if not s then return nil end
    local ok, v = pcall(HttpService.JSONDecode, HttpService, s)
    if ok and type(v) == "table" then return v end
    -- Alguns relays devolvem o JSON embrulhado em texto (o r.jina.ai prefixa
    -- "Title:/URL Source:/Markdown Content:"). Extrai o primeiro objeto de
    -- chaves balanceado e tenta decodificar de novo.
    local inner = s:match("(%b{})")
    if inner and #inner > 2 then
        local ok2, v2 = pcall(HttpService.JSONDecode, HttpService, inner)
        if ok2 and type(v2) == "table" then return v2 end
    end
    return nil
end

-- ── endpoints ─────────────────────────────────────────────────────────────────
-- O gate (403 code 22 "In-experience search is denied for this place or
-- universe") fica só no /search/items/details. Fora dele, dois endpoints
-- primeiro-party cobrem o browse inteiro, com o header do place presente:
--   catalog.roblox.com/v1/search/items?category=N&limit=28  -> {id, itemType}
--   economy.roblox.com/v2/assets/<id>/details               -> Name, AssetTypeId, PriceInRobux, Creator
-- Os dois voltam 200 com Roblox-Place-Id preenchido. O relay saiu porque o
-- header do executor não era o que quebrava o jina: da máquina, jina responde
-- 200 até com UA da Roblox e place id; dentro do jogo devolve 403, e o
-- allorigins 522 (a origem dele está fora do ar). O request() do executor sai
-- pela infra da Roblox, e Cloudflare trata tráfego de datacenter assim. Sem
-- relay, esse modo de falha não existe.
local _API  = "https://catalog.roblox.com/v1"
local _ECON = "https://economy.roblox.com/v2"

local _hostLog = ""
local _logBuf  = {}

local function _urlEnc(s)
    s = tostring(s):gsub("[^%w%-_%.~ ]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return (s:gsub(" ", "+"))
end

-- Uma chamada, sem sorteio de host. 429 é limite de rajada do catálogo e some
-- em ~20 s; três tentativas com 1,2 s de intervalo cobrem o caso normal sem
-- travar a tela.
local function _get2(url, tag)
    local data, status
    for attempt = 1, 3 do
        local body, st = _httpGet(url)
        status = tonumber(st) or 0
        _lastHttp = "HTTP " .. tostring(status)
        _logBuf[#_logBuf + 1] = tag .. ":" .. tostring(status)
        while #_logBuf > 4 do table.remove(_logBuf, 1) end
        _hostLog = table.concat(_logBuf, " ")
        data = _jsonDecode(body)
        if status ~= 429 then break end
        if attempt < 3 then task.wait(1.2) end
    end
    return data, status
end

-- ── catalog categories ────────────────────────────────────────────────────────
-- Regras medidas no /v1/search/items (o endpoint, não o /details):
--   · limit só aceita 10, 28 ou 30
--   · category e keyword PODEM ir juntos aqui — era o /details que dava 400
--   · devolve só {id, itemType}; nome e tipo vêm do economy/v2 por id
local _CATS = {
    {id="featured", label="Em Alta",    category=1,  mode="avatar"},
    {id="clothes",  label="Roupas",     category=3,  mode="avatar"},
    {id="acc",      label="Acessórios", category=11, mode="avatar"},
    {id="hats",     label="Chapéu",     category=11, kw="hat",   mode="avatar"},
    {id="hair",     label="Cabelo",     category=11, kw="hair",  mode="avatar"},
    {id="face",     label="Rosto",      category=11, kw="face",  mode="avatar"},
    {id="shirt",    label="Camisa",     category=3,  kw="shirt", mode="avatar"},
    {id="pants",    label="Calça",      category=3,  kw="pants", mode="avatar"},
    {id="emotes",   label="Emotes",     category=12, mode="emotes"},
    {id="dance",    label="Dança",      category=12, kw="dance", mode="emotes"},
    {id="wave",     label="Aceno",      category=12, kw="wave",  mode="emotes"},
    {id="laugh",    label="Rir",        category=12, kw="laugh", mode="emotes"},
    {id="search",   label="Busca",                   mode="both"},
}

-- Cache de lista de ids: voltar numa aba já vista não gasta chamada de busca. Os
-- detalhes já são cacheados por id — juntos, revisitar uma aba sai de graça.
local _idsCache = {}

local function _searchIds(cat, kw, cursor)
    local u = _API .. "/search/items?limit=28&sortOrder=Desc"
    if cat.category then u = u .. "&category=" .. tostring(cat.category) end
    if kw and #kw > 0 then u = u .. "&keyword=" .. _urlEnc(kw) end
    if cursor and #cursor > 0 then u = u .. "&cursor=" .. _urlEnc(cursor) end

    local hit = _idsCache[u]
    if hit then return hit[1], hit[2], nil end

    local data, status = _get2(u, "busca")
    if type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, "", "busca HTTP " .. tostring(status)
    end

    local ids = {}
    for _, it in ipairs(data.data) do
        local id = tonumber(it.id)
        if it.itemType == "Asset" and id then ids[#ids + 1] = id end
    end
    local nc = tostring(data.nextPageCursor or "")
    if #ids > 0 then _idsCache[u] = { ids, nc } end
    return ids, nc, nil
end

-- Nome, tipo e preço por id. 28 chamadas por página é o custo real do browse, e
-- o cache permanente faz a segunda visita à mesma aba sair de graça.
local _detCache, _detOrder = {}, {}
local function _assetDetail(id)
    local hit = _detCache[id]
    if hit then return hit end

    if #_detOrder > 700 then
        _detCache[_detOrder[1]] = nil
        table.remove(_detOrder, 1)
    end

    local data, status = _get2(_ECON .. "/assets/" .. tostring(id) .. "/details", "item")
    if type(data) ~= "table" or type(data.Name) ~= "string" then
        return nil, "item HTTP " .. tostring(status)
    end

    local d = {
        id        = id,
        name      = data.Name,
        assetType = tonumber(data.AssetTypeId) or 0,
        price     = tonumber(data.PriceInRobux) or 0,
        creator   = (type(data.Creator) == "table" and tostring(data.Creator.Name or "")) or "",
    }
    _detCache[id] = d
    _detOrder[#_detOrder + 1] = id
    return d
end

-- ── browse state ──────────────────────────────────────────────────────────────
local _bItems   = {}
local _bCursor  = ""
local _bCatIdx  = 1
local _bKeyword = ""
local _bMode    = "avatar"   -- "avatar" mostra itens, "emotes" mostra os emotes
local _bPageCap = 15         -- cards por página: cada um custa uma requisição bloqueante
local _bLoading = false
local _browseGrid    = nil
local _browseCards   = {}
local _bPrevBtn, _bNextBtn, _bInfoLbl

-- ── emote player ──────────────────────────────────────────────────────────────
local _activeEmote = nil

-- Derruba só as faixas de prioridade Action pra cima — ou seja, os emotes que
-- o jogo tocou. Idle/Walk/Run (priority Movement) ficam de pé, senão o
-- personagem emenda um T-pose no meio do gesto.
local function _stopEmotes(animator)
    pcall(function()
        for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
            local p = t.Priority
            if p == Enum.AnimationPriority.Action
                or p == Enum.AnimationPriority.Action2
                or p == Enum.AnimationPriority.Action3
                or p == Enum.AnimationPriority.Action4 then
                t:Stop()
            end
        end
    end)
    _activeEmote = nil
end

local function _playEmote(id)
    local char = Morph.Char()
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return false, "sem personagem" end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = hum
    end

    _stopEmotes(animator)

    local anim = Instance.new("Animation")
    anim.AnimationId = "rbxassetid://" .. tostring(id)

    local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not track then return false, "falha ao carregar emote" end

    -- Action4 ganha de qualquer animação que o jogo esteja rodando. Looped=false
    -- porque emote é gesto, não estado — e começar/terminar deixa o servidor
    -- replicar a faixa inteira pros outros players.
    pcall(function() track.Priority = Enum.AnimationPriority.Action4 end)
    pcall(function() track.Looped = false end)
    pcall(function() track:Play(0.1) end)
    _activeEmote = track

    pcall(function()
        track.Stopped:Connect(function()
            if _activeEmote == track then _activeEmote = nil end
        end)
    end)

    return true, "emote tocando"
end

-- ── card factory ──────────────────────────────────────────────────────────────
local function _makeBrowseCard(parent, item)
    local id     = tonumber(item.id) or 0
    local name   = tostring(item.name or "?")
    local atId   = tonumber(item.assetType) or 0
    local atInfo = _AT[atId]
    local typeLabel = atInfo and atInfo.label or "Item"
    local isSafe    = _safeForGame(id, atId)

    local outer = New("Frame", {
        Size=UDim2.fromOffset(148,186), BackgroundTransparency=1, BorderSizePixel=0,
    }, parent)
    local card = New("Frame", {
        Size=UDim2.fromScale(1,1), BackgroundColor3=T.Card, BorderSizePixel=0,
    }, outer)
    Round(card, 8)
    Stroke(card, T.Stroke, 1)

    -- Miniatura direto pelo id. A API de miniatura devolve uma URL do
    -- tr.rbxcdn.com, e Image de ImageLabel não carrega URL externa: o card ficava
    -- com o nome e sem imagem, porque essa URL sobrescrevia o rbxthumb que já
    -- estava funcionando. rbxthumb é o formato que o cliente resolve sozinho.
    local thumb = New("ImageLabel", {
        Size=UDim2.fromOffset(126,100), Position=UDim2.fromOffset(11,10),
        BackgroundColor3=T.Bg, BorderSizePixel=0, ScaleType=Enum.ScaleType.Fit,
        Image = "rbxthumb://type=Asset&id="..tostring(id).."&w=150&h=150",
    }, card)
    Round(thumb, 6)

    New("TextLabel", {
        Text=name, Font=F.Bold, TextSize=11, TextColor3=T.Text,
        TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd,
        BackgroundTransparency=1, Position=UDim2.fromOffset(11,116), Size=UDim2.fromOffset(126,16),
    }, card)
    New("TextLabel", {
        Text=typeLabel, Font=F.Mono, TextSize=9,
        TextColor3 = isSafe and T.Faint or T.Bad,
        TextXAlignment=Enum.TextXAlignment.Left,
        BackgroundTransparency=1, Position=UDim2.fromOffset(11,132), Size=UDim2.fromOffset(126,12),
    }, card)

    -- 61 = Emote, 24 = Animation, 68 = Mood. O código antigo só reconhecia o 24,
    -- então TODO emote do catálogo (tipo 61) caía no ramo de peça vestível e
    -- nem ganhava botão de tocar. Era por isso que emote não aparecia.
    local isAnim = (atId == 61) or (atId == 24) or (atId == 68)
    if isAnim then
        -- animação tocada pelo cliente no próprio personagem é replicada pelo
        -- servidor: os outros players veem o gesto.
        Button(card, "TOCAR", UDim2.fromOffset(11,148), UDim2.fromOffset(126,30),
            T.Accent, function()
                local ok, msg = _playEmote(id)
                Toast(msg, ok)
            end
        )
    else
        local applyColor = isSafe and T.Good or T.Bad
        local applyTxt   = isSafe and "APLICAR" or "BLOQUEADO"
        Button(card, applyTxt, UDim2.fromOffset(11,148), UDim2.fromOffset(126,30),
            applyColor, function()
                if not isSafe then
                    Toast("corpo slim incompatível — disponível só no HBG", false)
                    return
                end
                catAdd(id, function(a, b) Toast(b, a) end, nil, item)
            end
        )
    end

    card.MouseEnter:Connect(function() Tween(card, 0.15, {BackgroundColor3=T.Card2}) end)
    card.MouseLeave:Connect(function() Tween(card, 0.2,  {BackgroundColor3=T.Card})  end)

    return {outer=outer, card=card, thumb=thumb, _id=id}
end

local function _clearBrowseGrid()
    for _, c in ipairs(_browseCards) do
        if c.outer and c.outer.Parent then c.outer:Destroy() end
    end
    _browseCards = {}
    -- limpa TextLabels de status (carregando / sem resultados)
    if _browseGrid then
        for _, ch in ipairs(_browseGrid:GetChildren()) do
            if ch:IsA("TextLabel") then ch:Destroy() end
        end
    end
end

local _bFetchFailed = false   -- true quando a última página não trouxe nada
local _bFetchReason = nil     -- status http ou mensagem que explica
local _bGen = 0               -- a carga mais nova é a única que desenha

local function _renderEmpty()
    if not _browseGrid then return end
    local msg = _bFetchFailed
        and (tostring(_bFetchReason or "?") .. "\nTente RECARREGAR.")
        or  "Nenhum item encontrado para essa busca."
    New("TextLabel", {
        Text=msg, Font=F.Mono, TextSize=11,
        TextColor3 = _bFetchFailed and T.Bad or T.Faint,
        BackgroundTransparency=1, Size=UDim2.new(1,0,0,60),
        TextXAlignment=Enum.TextXAlignment.Left, TextWrapped=true,
    }, _browseGrid)
end

-- Duas etapas: uma chamada traz os ids, e cada card nasce assim que o nome do id
-- chega. Antes a tela prendia em "Carregando..." até o último host responder —
-- com quatro hosts em timeout, mais de um minuto — e o guarda _bLoading engolia
-- todo clique de aba nesse meio-tempo. Era isso que travava o Browse. _bGen
-- resolve: cada carga tem número, e a antiga para de desenhar quando outra começa.
local function _loadPage(cursor)
    _bGen = _bGen + 1
    local gen = _bGen
    _bLoading = true
    _bItems = {}
    _clearBrowseGrid()

    local statusLbl
    if _browseGrid then
        statusLbl = New("TextLabel", {
            Text="Carregando...", Font=F.Mono, TextSize=11, TextColor3=T.Faint,
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,32),
            TextXAlignment=Enum.TextXAlignment.Left,
        }, _browseGrid)
    end

    task.spawn(function()
        local ok, err0 = pcall(function()
            local cat = _CATS[_bCatIdx] or _CATS[1]
            local kw  = cat.kw or ""
            local q   = cat
            if cat.id == "search" then
                kw = _bKeyword or ""
                -- busca dentro do modo emotes continua sendo emote: category=12
                -- junto com a palavra. O /search/items aceita as duas juntas.
                if _bMode == "emotes" then q = { category = 12 } end
            end

            local ids, nextCur, err = _searchIds(q, kw, cursor or "")
            if gen ~= _bGen then return end
            if not ids then
                _bFetchFailed, _bFetchReason = true, err
                return
            end

            local shown, pages, pool, lastErr = 0, 0, ids, nil

            while gen == _bGen do
                for _, id in ipairs(pool) do
                    if gen ~= _bGen then return end
                    if shown >= _bPageCap then break end
                    local d, derr = _assetDetail(id)
                    if d then
                        local okc, card = pcall(_makeBrowseCard, _browseGrid, d)
                        if okc and card then
                            _browseCards[#_browseCards + 1] = card
                            _bItems[#_bItems + 1] = d
                            shown = shown + 1
                            if statusLbl and statusLbl.Parent then
                                statusLbl.Text = shown .. " itens"
                            end
                        else
                            lastErr = "card: " .. tostring(card)
                        end
                    else
                        lastErr = derr
                    end
                    task.wait()
                end

                -- Grade magra: busca outra página. Uma extra cobre as abas por palavra, que
                -- trazem coisa fora do tipo pedido (a busca lista só {id, itemType};
                -- o tipo real só aparece no economy/v2).
                if shown >= _bPageCap or pages >= 1 or #nextCur == 0 then break end
                pages = pages + 1
                local more, nc, e2 = _searchIds(q, kw, nextCur)
                if not more or #more == 0 then break end
                pool, nextCur, err = more, nc, e2 or err
            end

            _bCursor = nextCur
            _bFetchFailed = (shown == 0)
            _bFetchReason = lastErr or err
        end)

        if not ok then
            _bItems, _bFetchFailed = {}, true
            _bFetchReason = "erro no fetch: " .. tostring(err0)
        end
        if gen ~= _bGen then return end

        _bLoading = false
        if statusLbl and statusLbl.Parent then statusLbl:Destroy() end
        if _bInfoLbl then _bInfoLbl.Text = #_bItems .. " itens" end
        if _bNextBtn then _bNextBtn.Visible = (#_bItems >= _bPageCap and #_bCursor > 0) end
        if _bPrevBtn then _bPrevBtn.Visible = (cursor ~= nil and #tostring(cursor) > 0) end
        if #_bItems == 0 then pcall(_renderEmpty) end
    end)
end

-- ── NOVA ABA: Browse (separada do Catálogo, mais espaçosa) ───────────────────
CurTab = Tab("Browse", 0, true)
Persist.Scope = "browse"

-- ── UI: seção browse ──────────────────────────────────────────────────────────
do
    local row = Row(36)
    Button(row, "RECARREGAR", UDim2.fromOffset(8,3), UDim2.fromOffset(100,30), T.Accent, function()
        _bLoading = false  -- força reset caso tenha travado
        _bFetchFailed = false
        _loadPage("")
    end)
Button(row, "TESTAR HTTP", UDim2.fromOffset(116,3), UDim2.fromOffset(90,30), T.Card, function()
        task.spawn(function()
            local ids, _, e1 = _searchIds(_CATS[4], "", "")
            local n = (ids and #ids) or 0
            local d, e2 = nil, nil
            if n > 0 then d, e2 = _assetDetail(ids[1]) end
            -- leitura única: a busca respondeu, veio id, o nome saiu?
            local msg = ("busca=%d %s  nome=%s  [%s]"):format(
                n, e1 or "ok",
                d and ("'" .. d.name .. "'") or (e2 or "-"),
                _hostLog)
            Toast(msg, n > 0 and d ~= nil)
            pcall(function() print("[SilkCore Browse]", msg) end)
        end)
    end)
end

-- ── modo (itens / emotes) + categorias + busca ───────────────────────────────
do
    local catBtns = {}
    local function paintCats()
        for i, b in ipairs(catBtns) do
            local c = _CATS[i]
            -- chips de outro modo somem em vez de ficarem na fila
            b.Visible = (c ~= nil) and (c.mode == _bMode or c.mode == "both")
            local on = (i == _bCatIdx)
            if on then bindAcc(b,"BackgroundColor3","Accent",true) else unbindAcc(b,"BackgroundColor3") end
            Tween(b,0.14,{BackgroundColor3=on and T.Accent or T.Card3,
                          TextColor3=on and textOn(T.Accent) or T.Sub})
        end
    end

    local modeBtns = {}
    local function paintMode()
        for m, b in pairs(modeBtns) do
            local on = (m == _bMode)
            if on then bindAcc(b,"BackgroundColor3","Accent",true) else unbindAcc(b,"BackgroundColor3") end
            Tween(b,0.14,{BackgroundColor3=on and T.Accent or T.Card3,
                          TextColor3=on and textOn(T.Accent) or T.Sub})
        end
    end

    local function pickMode(m)
        if _bMode == m then return end
        _bMode, _bKeyword = m, ""
        for i, c in ipairs(_CATS) do
            if c.mode == m then _bCatIdx = i; break end
        end
        paintMode(); paintCats()
        _loadPage("")
    end

    local modeRow = Row(40)
    local mdefs = {{"avatar","ITENS"}, {"emotes","EMOTES"}}
    for k, def in ipairs(mdefs) do
        modeBtns[def[1]] = Button(modeRow, def[2], UDim2.fromOffset(8 + (k-1)*92, 4),
            UDim2.fromOffset(84,30), T.Card3, function() pickMode(def[1]) end)
    end

    local row = Row(84)
    local catBar = New("ScrollingFrame", {
        Size=UDim2.new(1,-16,0,34), Position=UDim2.fromOffset(8,8),
        BackgroundTransparency=1, BorderSizePixel=0,
        -- ScrollBarThickness=0 deixava a barra sem alça. No desktop o Roblox não
        -- rola horizontal no wheel sozinho, então não havia gesto nenhum: os
        -- chips passavam da borda e ficavam inalcançáveis. Com alça de 4 px dá
        -- pra arrastar, e o wheel na direção X também passa a funcionar.
        ScrollBarThickness=4, ScrollBarImageColor3=T.Faint, ScrollBarImageTransparency=0.3,
        ScrollingDirection=Enum.ScrollingDirection.X, ScrollingEnabled=true,
        ElasticBehavior=Enum.ElasticBehavior.Never,
        CanvasSize=UDim2.new(), AutomaticCanvasSize=Enum.AutomaticSize.X,
        ClipsDescendants=true,
    }, row)
    New("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,6),
        SortOrder=Enum.SortOrder.LayoutOrder, VerticalAlignment=Enum.VerticalAlignment.Top,
    }, catBar)

    -- Wheel explícito: o ScrollBarThickness resolve o arrasto, mas rolar no wheel
    -- é o gesto que a mão já tenta. Sem isso, os últimos chips continuavam
    -- dependendo de acertar uma alça de 4 px.
    catBar.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
        local span = math.max(0, catBar.AbsoluteCanvasSize.X - catBar.AbsoluteSize.X)
        local x = catBar.CanvasPosition.X - input.Position.Z * 60
        catBar.CanvasPosition = Vector2.new(math.clamp(x, 0, span), 0)
    end)

    for i, cat in ipairs(_CATS) do
        local b = New("TextButton", {
            Text=cat.label, Font=F.Bold, TextSize=10, AutoButtonColor=false,
            BackgroundColor3=T.Card3, TextColor3=T.Sub, BorderSizePixel=0,
            Size=UDim2.fromOffset(0,24), AutomaticSize=Enum.AutomaticSize.X,
            LayoutOrder=i, Visible=false,
        }, catBar)
        New("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8)}, b)
        Round(b, 5)
        catBtns[i] = b
        b.MouseButton1Click:Connect(Safe(function()
            _bCatIdx  = i
            _bKeyword = ""
            paintCats()
            _loadPage("")
        end, "bcat"..i))
    end
    paintCats()

    local searchBox = Field(row, UDim2.fromOffset(8,48), UDim2.new(1,-112,0,30), "buscar no catálogo...", "")
    local function doSearch()
        _bKeyword = searchBox.Text
        for i, c in ipairs(_CATS) do if c.id == "search" then _bCatIdx = i end end
        paintCats()
        _loadPage("")
    end
    Button(row, "BUSCAR", UDim2.new(1,-96,0,48), UDim2.fromOffset(84,30), T.Accent, doSearch)
    searchBox.FocusLost:Connect(function(enter) if enter then doSearch() end end)

    paintMode()
    onTheme(function() paintCats(); paintMode() end)
end

-- aviso de compatibilidade de corpo
do
    local msg, col
    if _VOLLEYBALL_IDS[_CUR_PLACE] then
        msg = "Volleyball detectado — corpos slim bloqueados. Apenas roupas e acessórios permitidos."
        col = T.Bad
    elseif _HBG_IDS[_CUR_PLACE] then
        msg = "HBG detectado — todos os tipos de corpo liberados."
        col = T.Good
    end
    if msg then
        local wRow = Row(44)
        local wl = Label(wRow, msg, 10, col, F.Mono, nil, UDim2.fromOffset(16,0), UDim2.new(1,-32,1,0))
        wl.TextWrapped = true
    end
end

-- grid de resultados
do
    local outer = New("Frame", {
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        BackgroundTransparency=1, LayoutOrder=nextOrder(),
    }, CurTab)
    _browseGrid = New("Frame", {
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y, BackgroundTransparency=1,
    }, outer)
    New("UIGridLayout", {
        CellSize=UDim2.fromOffset(148,186), CellPadding=UDim2.fromOffset(8,8),
        SortOrder=Enum.SortOrder.LayoutOrder,
    }, _browseGrid)
end

-- paginação
do
    local row = Row(36)
    _bPrevBtn = Button(row, "< ANTERIOR", UDim2.fromOffset(8,3), UDim2.fromOffset(96,30), T.Card, function()
        _loadPage("")  -- API Roblox não expõe cursor anterior; recomeça do início
    end)
    _bInfoLbl = Label(row, "0 itens", 10, T.Faint, F.Mono, Enum.TextXAlignment.Center,
        UDim2.new(0.3,0,0,3), UDim2.fromOffset(140,30))
    _bNextBtn = Button(row, "PROXIMO >", UDim2.new(1,-108,0,3), UDim2.fromOffset(96,30), T.Card, function()
        _loadPage(_bCursor)
    end)
    if _bPrevBtn then _bPrevBtn.Visible = false end
    if _bNextBtn then _bNextBtn.Visible = false end
end

-- botão parar emote (aparece só quando um emote está tocando)
do
    local row = Row(36)
    Button(row, "PARAR EMOTE", UDim2.fromOffset(8,3), UDim2.fromOffset(120,30), T.Bad, function()
        if _activeEmote then
            pcall(function() _activeEmote:Stop() end)
            _activeEmote = nil
            Toast("emote parado", true)
        else
            Toast("nenhum emote ativo", false)
        end
    end)
end

-- carrega automaticamente ao abrir a aba Browse
do
    tabHooks["Browse"] = function()
        if #_bItems == 0 and not _bLoading then _loadPage("") end
    end
end
end
_buildBrowse()

-- ── volta para a aba Catálogo para as seções de ID e "No personagem" ──────────
CurTab = tabs["Catálogo"]
Persist.Scope = "cat"

Section("Adicionar por ID")
do
    local row = Row(104)
    local hint = Label(row, "Cole um ID ou vários (vírgula, espaço ou links). O tipo é detectado sozinho: acessório, roupa, rosto, tool, efeito ou parte do corpo.",
        11, T.Sub, F.Body, nil, UDim2.fromOffset(16, 8), UDim2.new(1, -32, 0, 34))
    hint.TextWrapped = true
    hint.TextYAlignment = Enum.TextYAlignment.Top
    local box = Field(row, UDim2.fromOffset(14, 54), UDim2.new(1, -120, 0, 38), "ids ou links...", "")
    Button(row, "ADICIONAR", UDim2.new(1, -98, 0, 54), UDim2.fromOffset(84, 38), T.Good, function()
        local ids = {}
        for raw in string.gmatch(box.Text, "%d%d%d+") do ids[#ids + 1] = tonumber(raw) end
        if #ids == 0 then
            Toast("cole pelo menos um ID", false)
            return
        end
        box.Text = ""
        task.spawn(function()
            for _, id in ipairs(ids) do
                catAdd(id, function(ok, msg) Toast(msg, ok) end)
                task.wait(0.2)
            end
        end)
    end)
end

Section("No personagem")
gridHolder = New("Frame", {
    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder(),
}, CurTab)
gridHolder:SetAttribute("Grid", true)
New("UIGridLayout", {
    CellSize = UDim2.fromOffset(172, 196), CellPadding = UDim2.fromOffset(14, 14), SortOrder = Enum.SortOrder.LayoutOrder,
}, gridHolder)
do
    local card = Row(56)
    emptyCard = card.Parent
    Label(card, "nenhum item ainda. cole um ID acima.", 12, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -32, 1, 0))
end

local function makeCatCard(e)
    local card, outer = MakeCard(gridHolder, UDim2.fromOffset(172, 196), 0)
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromScale(0.86, 0.86)
    TweenEx(card, 0.45, Enum.EasingStyle.Back, {Size = UDim2.fromScale(1, 1)})
    local thumb = New("ImageLabel", {
        Size = UDim2.fromOffset(148, 112), Position = UDim2.fromOffset(12, 10), BackgroundColor3 = T.Bg, BorderSizePixel = 0,
        Image = "rbxthumb://type=Asset&id=" .. tostring(e.id) .. "&w=150&h=150", ScaleType = Enum.ScaleType.Fit,
    }, card)
    Round(thumb, 6)
    local name = Label(card, "", 12, T.Text, F.Bold, nil, UDim2.fromOffset(12, 128), UDim2.fromOffset(148, 16))
    name.TextTruncate = Enum.TextTruncate.AtEnd
    local meta = Label(card, "", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(12, 145), UDim2.fromOffset(148, 14))
    meta.TextTruncate = Enum.TextTruncate.AtEnd
    local rm = Button(card, "REMOVER", UDim2.fromOffset(12, 166), UDim2.fromOffset(148, 22), T.Bad, function()
        Cat.Remove(e.id)
        Toast("removido: " .. tostring(e.name), true)
    end)
    return {outer = outer, card = card, thumb = thumb, name = name, meta = meta, rm = rm}
end

refreshCatalog = function()
    local alive = {}
    for _, e in ipairs(State.Catalog) do alive[e.id] = e end
    for id, c in pairs(catCards) do
        if not alive[id] then
            catCards[id] = nil
            local outer = c.outer
            TweenEx(c.card, 0.22, Enum.EasingStyle.Quad, {Size = UDim2.fromScale(0.8, 0.8)})
            task.delay(0.24, function()
                if outer.Parent then outer:Destroy() end
            end)
        end
    end
    for i, e in ipairs(State.Catalog) do
        local c = catCards[e.id]
        if not c then
            c = makeCatCard(e)
            catCards[e.id] = c
        end
        c.outer.LayoutOrder = i
        c.name.Text = tostring(e.name)
        c.meta.Text = tostring(e.meta)
        c.name.TextColor3 = e.pending and T.Faint or T.Text
        c.thumb.ImageTransparency = e.pending and 0.6 or 0
        c.rm.Visible = not e.pending
    end
    emptyCard.Visible = #State.Catalog == 0
    SetBadge("Catálogo", #State.Catalog > 0 and tostring(#State.Catalog) or "")
    if curName == "Catálogo" then SetInfo(#State.Catalog .. " item(ns)") end
end
tabHooks["Catálogo"] = function()
    SetInfo(#State.Catalog .. " item(ns)")
end
BtnRow("REMOVER TODOS OS ITENS", T.Bad, function()
    Cat.ClearAll()
    Toast("todos os itens foram removidos", true)
end, 40)
refreshCatalog()
end

--------------------------------------------------------------------------------
-- EFEITOS (particulas e rastro, so no seu cliente)
--------------------------------------------------------------------------------
local FX
do
CurTab = Tab("Efeitos", 0, true)
Persist.Scope = "fx"
FX = {On = {}, Part = Persist.Get("fx:part", "Torso"), Mult = 1, Objs = {}, Mode = Persist.Get("fx:mode", "theme")}
local FX_TARGETS = {
    {id = "Head", label = "Cabeça", parts = {"Head"}, r6 = {"Head"}},
    {id = "Torso", label = "Tronco", parts = {"UpperTorso"}, r6 = {"Torso"}},
    {id = "Hands", label = "Mãos", parts = {"LeftHand", "RightHand"}, r6 = {"Left Arm", "Right Arm"}},
    {id = "Feet", label = "Pés", parts = {"LeftFoot", "RightFoot"}, r6 = {"Left Leg", "Right Leg"}},
    {id = "Root", label = "Corpo", parts = {"HumanoidRootPart"}, r6 = {"HumanoidRootPart"}},
}
local FX_BY = {}
for _, t in ipairs(FX_TARGETS) do FX_BY[t.id] = t end
if not FX_BY[FX.Part] then FX.Part = "Torso" end
local FX_PRESETS = {
    {id = "aura", name = "Aura", desc = "brasas subindo ao redor do corpo", rate = 22},
    {id = "spark", name = "Faíscas", desc = "fagulhas rápidas que caem", rate = 40},
    {id = "smoke", name = "Fumaça", desc = "fumaça escura e lenta", rate = 12},
    {id = "snow", name = "Neve", desc = "flocos caindo da parte escolhida", rate = 18},
    {id = "trail", name = "Rastro", desc = "faixa de luz atrás do corpo", rate = 0},
}
local function fxSeq(a, b)
    return NumberSequence.new({NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b)})
end
local function fxColors()
    if FX.Mode == "rainbow" then
        return ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 90)), ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 190, 70)),
            ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 235, 120)), ColorSequenceKeypoint.new(0.6, Color3.fromRGB(70, 200, 255)),
            ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 110, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 90, 200)),
        })
    elseif FX.Mode == "white" then
        return ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 205))
    end
    return ColorSequence.new(T.Accent, T.Accent2)
end
local function fxEmitter(kind, att, rate)
    local e = Instance.new("ParticleEmitter")
    e.Name = "SilkcoreFx_" .. kind
    e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    if kind == "aura" then
        e.Color = fxColors()
        e.Size = fxSeq(0.5, 0)
        e.Transparency = fxSeq(0.2, 1)
        e.Lifetime = NumberRange.new(1.2, 2.2)
        e.Speed = NumberRange.new(0.5, 2)
        e.SpreadAngle = Vector2.new(180, 180)
        e.Acceleration = Vector3.new(0, 1.8, 0)
        e.LightEmission = 0.8
        e.RotSpeed = NumberRange.new(-90, 90)
        e.Rotation = NumberRange.new(0, 360)
    elseif kind == "spark" then
        e.Color = (FX.Mode == "theme") and ColorSequence.new(Color3.new(1, 1, 1), T.Accent2) or fxColors()
        e.Size = fxSeq(0.3, 0)
        e.Transparency = fxSeq(0, 1)
        e.Lifetime = NumberRange.new(0.4, 0.8)
        e.Speed = NumberRange.new(8, 14)
        e.SpreadAngle = Vector2.new(180, 180)
        e.Acceleration = Vector3.new(0, -14, 0)
        e.LightEmission = 1
    elseif kind == "smoke" then
        e.Texture = "rbxasset://textures/particles/smoke_main.dds"
        e.Color = ColorSequence.new(Color3.fromRGB(70, 62, 72), Color3.fromRGB(20, 16, 22))
        e.Size = fxSeq(1, 3.2)
        e.Transparency = fxSeq(0.55, 1)
        e.Lifetime = NumberRange.new(1.5, 2.6)
        e.Speed = NumberRange.new(1, 2)
        e.SpreadAngle = Vector2.new(30, 30)
        e.Acceleration = Vector3.new(0, 1.2, 0)
        e.RotSpeed = NumberRange.new(-30, 30)
    else
        e.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 220, 255))
        e.Size = fxSeq(0.28, 0.28)
        e.Transparency = fxSeq(0.1, 1)
        e.Lifetime = NumberRange.new(2.4, 3.4)
        e.Speed = NumberRange.new(0.5, 1.5)
        e.SpreadAngle = Vector2.new(180, 180)
        e.Acceleration = Vector3.new(0, -3, 0)
        e.LightEmission = 0.4
    end
    e:SetAttribute("SilkBase", rate)
    e.Rate = rate * FX.Mult
    e.Parent = att
    return e
end
local function fxParts(char, target)
    local out = {}
    for _, n in ipairs(target.parts) do
        local p = char:FindFirstChild(n)
        if p then out[#out + 1] = p end
    end
    if #out == 0 then
        for _, n in ipairs(target.r6) do
            local p = char:FindFirstChild(n)
            if p then out[#out + 1] = p end
        end
    end
    return out
end
function FX.Clear()
    for _, o in ipairs(FX.Objs) do
        if o.Parent then o:Destroy() end
    end
    FX.Objs = {}
end
function FX.Apply()
    FX.Clear()
    local char = LocalPlayer.Character
    if not char then return 0 end
    local n = 0
    for _, pr in ipairs(FX_PRESETS) do
        if FX.On[pr.id] then
            for _, part in ipairs(fxParts(char, FX_BY[FX.Part])) do
                if pr.id == "trail" then
                    local a0 = Instance.new("Attachment")
                    a0.Name = "SilkcoreFxA0"
                    a0.Position = Vector3.new(0, 0.9, 0)
                    a0.Parent = part
                    local a1 = Instance.new("Attachment")
                    a1.Name = "SilkcoreFxA1"
                    a1.Position = Vector3.new(0, -0.9, 0)
                    a1.Parent = part
                    local tr = Instance.new("Trail")
                    tr.Name = "SilkcoreFx_trail"
                    tr.Attachment0, tr.Attachment1 = a0, a1
                    tr.Color = fxColors()
                    tr.Transparency = fxSeq(0.2, 1)
                    tr.WidthScale = fxSeq(1, 0)
                    tr.Lifetime = 0.55
                    tr.LightEmission = 0.7
                    tr.FaceCamera = true
                    tr.Parent = part
                    FX.Objs[#FX.Objs + 1] = a0
                    FX.Objs[#FX.Objs + 1] = a1
                    FX.Objs[#FX.Objs + 1] = tr
                else
                    local att = Instance.new("Attachment")
                    att.Name = "SilkcoreFxAtt"
                    att.Parent = part
                    fxEmitter(pr.id, att, pr.rate)
                    FX.Objs[#FX.Objs + 1] = att
                end
                n = n + 1
            end
        end
    end
    return n
end
function FX.RateAll()
    for _, o in ipairs(FX.Objs) do
        if o.Parent and o:IsA("Attachment") then
            for _, c in ipairs(o:GetChildren()) do
                if c:IsA("ParticleEmitter") then c.Rate = (c:GetAttribute("SilkBase") or 10) * FX.Mult end
            end
        end
    end
end
State.FxReapply = function()
    task.spawn(function()
        task.wait(0.9)
        FX.Apply()
    end)
end
local function fxBadge()
    local n = 0
    for _, p in ipairs(FX_PRESETS) do
        if FX.On[p.id] then n = n + 1 end
    end
    SetBadge("Efeitos", n > 0 and tostring(n) or "")
end

local fxHandles, fxIntens = {}, nil
FX.Presets = FX_PRESETS
function FX.SetOn(id, v)
    FX.On[id] = v
    if fxHandles[id] then fxHandles[id].Set(v) end
    Persist.Set("fx:fx " .. id, v)
    fxBadge()
end
function FX.Load(t, skipApply)
    t = t or {}
    for _, p in ipairs(FX_PRESETS) do FX.SetOn(p.id, t.on ~= nil and t.on[p.id] == true) end
    if t.part and FX_BY[t.part] then
        FX.Part = t.part
        Persist.Set("fx:part", t.part)
        if FX.PaintSeg then FX.PaintSeg() end
    end
    if t.mult then
        FX.Mult = t.mult
        if fxIntens then fxIntens.Set(t.mult) end
    end
    if t.mode then
        FX.Mode = t.mode
        Persist.Set("fx:mode", t.mode)
        if FX.ModeSeg then FX.ModeSeg.Set(t.mode) end
    end
    if not skipApply then FX.Apply() end
end
Section("Onde aplicar")
do
    local row = Row(58)
    local btns = {}
    local function paintSeg()
        for id, b in pairs(btns) do
            local on = (id == FX.Part)
            if on then bindAcc(b, "BackgroundColor3", "Accent", true) else unbindAcc(b, "BackgroundColor3") end
            Tween(b, 0.18, {BackgroundColor3 = on and T.Accent or T.Card3, TextColor3 = on and textOn(T.Accent) or T.Sub})
        end
    end
    for i, t in ipairs(FX_TARGETS) do
        local b = New("TextButton", {
            Text = upperPT(t.label), Font = F.Bold, TextSize = 11, AutoButtonColor = false, BorderSizePixel = 0,
            BackgroundColor3 = T.Card3, TextColor3 = T.Sub, Size = UDim2.fromOffset(100, 32),
            Position = UDim2.fromOffset(12 + (i - 1) * 105, 13),
        }, row)
        Round(b, 6)
        btns[t.id] = b
        b.MouseButton1Click:Connect(Safe(function()
            FX.Part = t.id
            Persist.Set("fx:part", t.id)
            paintSeg()
            FX.Apply()
        end, "efeitos alvo"))
    end
    FX.PaintSeg = paintSeg
    paintSeg()
    onTheme(paintSeg)
end
Section("Cor dos efeitos")
do
    local row = Row(58)
    FX.ModeSeg = Segmented(row, {
        {id = "theme", label = "Cor do tema"}, {id = "rainbow", label = "Arco-íris"}, {id = "white", label = "Branco"},
    }, FX.Mode, function(id)
        FX.Mode = id
        Persist.Set("fx:mode", id)
        FX.Apply()
    end, 12, 13, 168, 32, 6)
end
Section("Efeitos")
for _, p in ipairs(FX_PRESETS) do
    fxHandles[p.id] = Toggle(p.name .. "  ·  " .. p.desc, false, function(v)
        FX.On[p.id] = v
        fxBadge()
        if not Persist.Loading then FX.Apply() end
    end, "fx " .. p.id)
end
fxIntens = Slider("Intensidade", 0.2, 3, 1, "%.1fx", function(v)
    FX.Mult = v
    FX.RateAll()
end, "Intensidade")
Note("Os efeitos aparecem só no seu cliente e voltam sozinhos quando você renasce.", 40)
fxBadge()
end

--------------------------------------------------------------------------------
-- LOOKS: salva o visual completo (partes, itens, cores, efeitos, headless, korblox) em slots,
-- aplica com um clique e exporta/importa como codigo (SC1:...) pra mandar pra um amigo.
--------------------------------------------------------------------------------
local Looks = {Slots = {}}
do
CurTab = Tab("Looks", 0, true)
Persist.Scope = "looks"
local SLOTS = 8
local HttpS = game:GetService("HttpService")
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64enc(data)
    local out = {}
    local len = string.len(data)
    for i = 1, len, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end
local function b64dec(s)
    s = s:gsub("[^%w%+/=]", "")
    local out = {}
    local len = string.len(s)
    for i = 1, len, 4 do
        local n, pad = 0, 0
        for j = 0, 3 do
            local ch = s:sub(i + j, i + j)
            if ch == "=" or ch == "" then
                pad = pad + 1
                n = n * 64
            else
                local idx = B64:find(ch, 1, true)
                if not idx then return nil end
                n = n * 64 + (idx - 1)
            end
        end
        local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
        out[#out + 1] = bytes:sub(1, 3 - pad)
    end
    return table.concat(out)
end

local function capture(name)
    local slot = {
        name = name, ward = {}, cat = {}, colors = {}, kor = {}, headless = State.IsHeadless and true or false,
        fx = {on = {}, part = FX.Part, mult = FX.Mult, mode = FX.Mode},
    }
    for f, id in pairs(State.Wardrobe) do slot.ward[f] = id end
    for _, id in ipairs(Cat.Ids()) do slot.cat[#slot.cat + 1] = id end
    for id, c in pairs(Colors.State) do
        slot.colors[id] = {math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)}
    end
    for k, v in pairs(FX.On) do
        if v then slot.fx.on[k] = true end
    end
    for _, side in ipairs({"Right", "Left"}) do
        if State.Korblox[side] and tonumber(State.KorbloxIds[side]) then slot.kor[side] = tonumber(State.KorbloxIds[side]) end
    end
    return slot
end
local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
local function summary(slot)
    if not slot then return "vazio" end
    local fxn = 0
    if slot.fx and type(slot.fx.on) == "table" then fxn = count(slot.fx.on) end
    return string.format("partes %d · itens %d · cores %d · fx %d", count(slot.ward or {}), #(slot.cat or {}), count(slot.colors or {}), fxn)
end
-- valida e normaliza qualquer slot (carregado do arquivo ou importado): so numeros e nomes conhecidos
local function sanitize(t)
    if type(t) ~= "table" then return nil end
    local s = {name = tostring(t.name or "Look"):sub(1, 24), ward = {}, cat = {}, colors = {}, kor = {}, headless = t.headless == true,
        fx = {on = {}, part = "Torso", mult = 1, mode = "theme"}}
    if type(t.ward) == "table" then
        for f, id in pairs(t.ward) do
            if WARD_BY[f] and tonumber(id) and tonumber(id) > 0 then s.ward[f] = math.floor(tonumber(id)) end
        end
    end
    if type(t.cat) == "table" then
        for i, id in ipairs(t.cat) do
            if i <= 40 and tonumber(id) and tonumber(id) > 0 then s.cat[#s.cat + 1] = math.floor(tonumber(id)) end
        end
    end
    if type(t.colors) == "table" then
        for gid, rgb in pairs(t.colors) do
            if type(gid) == "string" and type(rgb) == "table" and tonumber(rgb[1]) and tonumber(rgb[2]) and tonumber(rgb[3]) then
                s.colors[gid] = {math.clamp(tonumber(rgb[1]), 0, 255), math.clamp(tonumber(rgb[2]), 0, 255), math.clamp(tonumber(rgb[3]), 0, 255)}
            end
        end
    end
    if type(t.fx) == "table" then
        if type(t.fx.on) == "table" then
            for _, p in ipairs(FX.Presets) do
                if t.fx.on[p.id] == true then s.fx.on[p.id] = true end
            end
        end
        if type(t.fx.part) == "string" then s.fx.part = t.fx.part end
        if tonumber(t.fx.mult) then s.fx.mult = math.clamp(tonumber(t.fx.mult), 0.2, 3) end
        if t.fx.mode == "rainbow" or t.fx.mode == "white" then s.fx.mode = t.fx.mode end
    end
    if type(t.kor) == "table" then
        for _, side in ipairs({"Right", "Left"}) do
            if tonumber(t.kor[side]) and tonumber(t.kor[side]) > 0 then s.kor[side] = math.floor(tonumber(t.kor[side])) end
        end
    end
    return s
end
local function encode(slot)
    return "SC1:" .. b64enc(HttpS:JSONEncode(slot))
end
local function decode(code)
    code = tostring(code or ""):gsub("%s", "")
    if code:sub(1, 4) ~= "SC1:" then return nil, "código inválido (precisa começar com SC1:)" end
    local raw = b64dec(code:sub(5))
    if not raw or #raw < 2 then return nil, "código corrompido" end
    local ok, t = pcall(function() return HttpS:JSONDecode(raw) end)
    if not ok then return nil, "código corrompido" end
    local s = sanitize(t)
    if not s then return nil, "código sem dados de look" end
    return s
end

local applying = false
local function applySlot(slot)
    if applying then return false end
    applying = true
    local nW, nC = 0, 0
    local ok, err = pcall(function()
        Ward.ClearAll()
        Cat.ClearAll()
        Colors.ResetAll()
        FX.Load({on = {}, part = FX.Part, mult = FX.Mult, mode = FX.Mode}, true)
        if State.IsHeadless then Morph.SetHeadless(false) end
        for _, side in ipairs({"Right", "Left"}) do
            if State.Korblox[side] then Morph.SetKorblox(side, false) end
        end
        for f, id in pairs(slot.ward or {}) do
            if Ward.Apply(f, id) then nW = nW + 1 end
        end
        for _, id in ipairs(slot.cat or {}) do
            if Cat.Add(id, false) then nC = nC + 1 end
        end
        for gid, rgb in pairs(slot.colors or {}) do Colors.Apply(gid, Color3.fromRGB(rgb[1], rgb[2], rgb[3])) end
        FX.Load(slot.fx)
        if slot.headless then Morph.SetHeadless(true) end
        for side, id in pairs(slot.kor or {}) do Morph.SetKorblox(side, true, id) end
    end)
    applying = false
    if not ok then
        Log.add("ERRO", "look: " .. tostring(err))
        return false
    end
    State.Touch()
    return true, nW, nC
end

local cards = {}
local function saveSlot(i)
    Persist.Set("looks:" .. i, Looks.Slots[i])
end
local function refreshCard(i)
    local c = cards[i]
    local s = Looks.Slots[i]
    c.sum.Text = summary(s)
    c.sum.TextColor3 = s and T.Sub or T.Faint
    c.name.Text = s and s.name or ("Look " .. i)
    c.apply.Visible = s ~= nil
    c.export.Visible = s ~= nil
    c.del.Visible = s ~= nil
    local n = 0
    for k = 1, SLOTS do
        if Looks.Slots[k] then n = n + 1 end
    end
    SetBadge("Looks", n > 0 and tostring(n) or "")
end
function Looks.ApplyIndex(i)
    local s = Looks.Slots[i]
    if not s then
        Toast("o slot " .. i .. " está vazio", false)
        return
    end
    task.spawn(function()
        local ok, nW, nC = applySlot(s)
        if ok then Toast(string.format("look \"%s\" aplicado (%d partes, %d itens)", s.name, nW, nC), true)
        else Toast("não consegui aplicar o look (veja o registro em Config)", false) end
    end)
end
function Looks.Next()
    local list = {}
    for i = 1, SLOTS do
        if Looks.Slots[i] then list[#list + 1] = i end
    end
    if #list == 0 then
        Toast("nenhum look salvo ainda", false)
        return
    end
    Looks.cursor = ((Looks.cursor or 0) % #list) + 1
    Looks.ApplyIndex(list[Looks.cursor])
end
function Looks.Names()
    local out = {}
    for i = 1, SLOTS do
        if Looks.Slots[i] then out[#out + 1] = {i, Looks.Slots[i].name} end
    end
    return out
end

for i = 1, SLOTS do
    Looks.Slots[i] = sanitize(Persist.Get("looks:" .. i, nil))
end

Section("Importar")
local importBox
do
    local row = Row(112)
    local hint = Label(row, "Cole um código SC1:... (do EXPORTAR de um look seu ou de um amigo). O look entra no primeiro slot livre. O código só carrega IDs e cores, nada mais.",
        11, T.Sub, F.Body, nil, UDim2.fromOffset(16, 8), UDim2.new(1, -32, 0, 34))
    hint.TextWrapped = true
    hint.TextYAlignment = Enum.TextYAlignment.Top
    importBox = Field(row, UDim2.fromOffset(14, 58), UDim2.new(1, -130, 0, 38), "SC1:...", "")
    Button(row, "IMPORTAR", UDim2.new(1, -108, 0, 58), UDim2.fromOffset(94, 38), T.Accent, function()
        local s, err = decode(importBox.Text)
        if not s then
            Toast(tostring(err), false)
            return
        end
        for i = 1, SLOTS do
            if not Looks.Slots[i] then
                Looks.Slots[i] = s
                saveSlot(i)
                refreshCard(i)
                importBox.Text = ""
                Toast("look \"" .. s.name .. "\" importado no slot " .. i, true)
                return
            end
        end
        Toast("sem slot livre: apague um look antes", false)
    end)
end

Section("Seus looks")
do
    local card = Row(48)
    Label(card, "Salve o que está no seu personagem agora em um slot, ou aplique um look salvo.", 11, T.Sub, F.Body, nil,
        UDim2.fromOffset(16, 0), UDim2.new(1, -150, 1, 0)).TextWrapped = true
    Button(card, "ALEATÓRIO", UDim2.new(1, -118, 0.5, -15), UDim2.fromOffset(104, 30), T.Card, function()
        local list = Looks.Names()
        if #list == 0 then
            Toast("nenhum look salvo ainda", false)
            return
        end
        Looks.ApplyIndex(list[math.random(1, #list)][1])
    end)
end
local grid = New("Frame", {
    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder(),
}, CurTab)
grid:SetAttribute("Grid", true)
New("UIGridLayout", {
    CellSize = UDim2.fromOffset(266, 142), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder,
}, grid)
for i = 1, SLOTS do
    local card = MakeCard(grid, UDim2.fromOffset(266, 142), i)
    Label(card, string.format("%02d", i), 10, T.Accent, F.Mono, nil, UDim2.fromOffset(14, 8), UDim2.fromOffset(24, 14))
    local nameBox = Field(card, UDim2.fromOffset(40, 6), UDim2.new(1, -52, 0, 26), "nome do look", "Look " .. i)
    local sum = Label(card, "vazio", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(14, 40), UDim2.new(1, -28, 0, 14))
    local apply = Button(card, "APLICAR", UDim2.fromOffset(12, 64), UDim2.new(0.5, -17, 0, 28), T.Accent, function()
        Looks.ApplyIndex(i)
    end)
    Button(card, "SALVAR AQUI", UDim2.new(0.5, 5, 0, 64), UDim2.new(0.5, -17, 0, 28), T.Card, function()
        local s = capture(nameBox.Text ~= "" and nameBox.Text or ("Look " .. i))
        Looks.Slots[i] = s
        saveSlot(i)
        refreshCard(i)
        Toast("look salvo no slot " .. i .. " (" .. summary(s) .. ")", true)
    end)
    local export = Button(card, "EXPORTAR", UDim2.fromOffset(12, 102), UDim2.new(0.5, -17, 0, 28), T.Card, function()
        local s = Looks.Slots[i]
        if not s then return end
        if setclipboard then
            pcall(setclipboard, encode(s))
            Toast("código do look copiado (cole no IMPORTAR de um amigo)", true)
        else
            Toast("seu executor não tem setclipboard", false)
        end
    end)
    local del = Button(card, "APAGAR", UDim2.new(0.5, 5, 0, 102), UDim2.new(0.5, -17, 0, 28), T.Bad, function()
        Looks.Slots[i] = nil
        saveSlot(i)
        refreshCard(i)
        Toast("slot " .. i .. " apagado", true)
    end)
    nameBox.FocusLost:Connect(function()
        local s = Looks.Slots[i]
        if s and nameBox.Text ~= "" then
            s.name = nameBox.Text:sub(1, 24)
            saveSlot(i)
        end
    end)
    cards[i] = {name = nameBox, sum = sum, apply = apply, export = export, del = del}
    refreshCard(i)
end
-- usado pelo teste automatizado
Looks.Encode, Looks.Decode, Looks.Capture = encode, decode, capture
end

--------------------------------------------------------------------------------
-- AMBIENTE: filtros de camera, hora do dia e modo foto. Tudo so no seu cliente.
--------------------------------------------------------------------------------
local Env = {}
do
CurTab = Tab("Ambiente", 0, true)
Persist.Scope = "env"
local Lighting = game:GetService("Lighting")
local cfgE = {on = false, useClock = false, lockClock = false, clock = 14, bright = 2, expo = 0, sat = 0, con = 0, bloom = 0,
    rays = 0, dof = false, tint = {255, 255, 255}}
Env.cfg = cfgE
local orig = nil
local handles = {}
local clockConn = nil
local function snapshot()
    if orig then return end
    orig = {ClockTime = Lighting.ClockTime, Brightness = Lighting.Brightness, ExposureCompensation = Lighting.ExposureCompensation}
end
local function ensure(class, name)
    local o = Lighting:FindFirstChild("SilkcoreEnv_" .. name)
    if not o then
        o = Instance.new(class)
        o.Name = "SilkcoreEnv_" .. name
        o.Parent = Lighting
    end
    return o
end
local function drop(name)
    local o = Lighting:FindFirstChild("SilkcoreEnv_" .. name)
    if o then o:Destroy() end
end
function Env.Restore()
    if clockConn then
        clockConn:Disconnect()
        clockConn = nil
    end
    if orig then
        Lighting.ClockTime = orig.ClockTime
        Lighting.Brightness = orig.Brightness
        Lighting.ExposureCompensation = orig.ExposureCompensation
    end
    for _, n in ipairs({"cc", "bloom", "rays", "dof"}) do drop(n) end
end
function Env.Apply()
    snapshot()
    if not cfgE.on then
        Env.Restore()
        return
    end
    Lighting.Brightness = cfgE.bright
    Lighting.ExposureCompensation = cfgE.expo
    if cfgE.useClock then
        Lighting.ClockTime = cfgE.clock
        if cfgE.lockClock and not clockConn then
            clockConn = Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
                if cfgE.on and cfgE.useClock and cfgE.lockClock and math.abs(Lighting.ClockTime - cfgE.clock) > 0.01 then
                    Lighting.ClockTime = cfgE.clock
                end
            end)
        elseif not cfgE.lockClock and clockConn then
            clockConn:Disconnect()
            clockConn = nil
        end
    elseif clockConn then
        clockConn:Disconnect()
        clockConn = nil
    end
    local cc = ensure("ColorCorrectionEffect", "cc")
    cc.Saturation = cfgE.sat
    cc.Contrast = cfgE.con
    cc.TintColor = Color3.fromRGB(cfgE.tint[1], cfgE.tint[2], cfgE.tint[3])
    if cfgE.bloom > 0.01 then
        local bl = ensure("BloomEffect", "bloom")
        bl.Intensity = cfgE.bloom
        bl.Size = 28
        bl.Threshold = 1.1
    else
        drop("bloom")
    end
    if cfgE.rays > 0.01 then
        local sr = ensure("SunRaysEffect", "rays")
        sr.Intensity = cfgE.rays
        sr.Spread = 0.6
    else
        drop("rays")
    end
    if cfgE.dof then
        local df = ensure("DepthOfFieldEffect", "dof")
        df.FarIntensity = 0.35
        df.FocusDistance = 24
        df.InFocusRadius = 40
        df.NearIntensity = 0
    else
        drop("dof")
    end
end

local PRESETS = {
    {id = "off", name = "Padrão"},
    {id = "cinema", name = "Cinema", c = {sat = 0.12, con = 0.18, bloom = 0.35, rays = 0.05, bright = 2, expo = 0, tint = {255, 238, 218}}},
    {id = "neon", name = "Neon", c = {sat = 0.45, con = 0.25, bloom = 0.9, rays = 0, bright = 2, expo = 0.1, tint = {235, 220, 255}}},
    {id = "noir", name = "Noir", c = {sat = -1, con = 0.35, bloom = 0.15, rays = 0, bright = 1.6, expo = -0.1, tint = {255, 255, 255}}},
    {id = "sonho", name = "Sonho", c = {sat = 0.2, con = -0.05, bloom = 0.85, rays = 0.2, dof = true, bright = 2.4, expo = 0.2, tint = {255, 232, 244}}},
    {id = "porsol", name = "Pôr do sol", c = {sat = 0.25, con = 0.12, bloom = 0.4, rays = 0.3, clock = 17.9, useClock = true, bright = 2, expo = 0, tint = {255, 214, 178}}},
}
local segPreset
local function loadPreset(p)
    if not p.c then
        cfgE.on = false
        if handles.on then handles.on.Set(false, true) end
        return
    end
    for k, v in pairs(p.c) do cfgE[k] = v end
    cfgE.dof = p.c.dof == true
    cfgE.on = true
    handles.sat.Set(cfgE.sat)
    handles.con.Set(cfgE.con)
    handles.bloom.Set(cfgE.bloom)
    handles.rays.Set(cfgE.rays)
    handles.bright.Set(cfgE.bright)
    handles.expo.Set(cfgE.expo)
    handles.clock.Set(cfgE.clock)
    handles.useClock.Set(cfgE.useClock)
    handles.dof.Set(cfgE.dof)
    handles.on.Set(true)
    Persist.Set("env:on", true)
    Env.Apply()
end

Section("Filtros")
do
    local row = Row(58)
    local opts = {}
    for _, p in ipairs(PRESETS) do opts[#opts + 1] = {id = p.id, label = p.name} end
    segPreset = Segmented(row, opts, "off", function(id)
        for _, p in ipairs(PRESETS) do
            if p.id == id then loadPreset(p) end
        end
        Persist.Set("env:preset", id)
    end, 12, 13, 82, 32, 4)
end
Section("Ajustes")
handles.on = Toggle("Ativar ambiente", false, function(v)
    cfgE.on = v
    Env.Apply()
end, "env on")
handles.useClock = Toggle("Controlar a hora do dia", false, function(v)
    cfgE.useClock = v
    if cfgE.on then Env.Apply() end
end, "env useClock")
handles.clock = Slider("Hora do dia", 0, 24, 14, "%.1f h", function(v)
    cfgE.clock = v
    if cfgE.on then Env.Apply() end
end, "env clock")
handles.lock = Toggle("Travar a hora (o jogo não muda)", false, function(v)
    cfgE.lockClock = v
    if cfgE.on then Env.Apply() end
end, "env lock")
handles.bright = Slider("Brilho", 0, 5, 2, "%.1f", function(v)
    cfgE.bright = v
    if cfgE.on then Env.Apply() end
end, "env bright")
handles.expo = Slider("Exposição", -2, 2, 0, "%.2f", function(v)
    cfgE.expo = v
    if cfgE.on then Env.Apply() end
end, "env expo")
handles.sat = Slider("Saturação", -1, 1, 0, "%.2f", function(v)
    cfgE.sat = v
    if cfgE.on then Env.Apply() end
end, "env sat")
handles.con = Slider("Contraste", -0.5, 0.6, 0, "%.2f", function(v)
    cfgE.con = v
    if cfgE.on then Env.Apply() end
end, "env con")
handles.bloom = Slider("Bloom (brilho nas luzes)", 0, 1.5, 0, "%.2f", function(v)
    cfgE.bloom = v
    if cfgE.on then Env.Apply() end
end, "env bloom")
handles.rays = Slider("Raios de sol", 0, 1, 0, "%.2f", function(v)
    cfgE.rays = v
    if cfgE.on then Env.Apply() end
end, "env rays")
handles.dof = Toggle("Profundidade de campo (fundo desfocado)", false, function(v)
    cfgE.dof = v
    if cfgE.on then Env.Apply() end
end, "env dof")
do
    local row = Row(64)
    Label(row, "Tinta da imagem", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 0), UDim2.fromOffset(120, 64))
    local tints = {
        {255, 255, 255}, {255, 238, 218}, {255, 214, 178}, {235, 220, 255}, {255, 232, 244}, {210, 235, 255}, {220, 255, 230},
    }
    for i, t in ipairs(tints) do
        local b = New("TextButton", {
            Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromRGB(t[1], t[2], t[3]), BorderSizePixel = 0,
            Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(150 + (i - 1) * 38, 17),
        }, row)
        Round(b, 6)
        Stroke(b, T.Stroke2, 1)
        b.MouseEnter:Connect(function() TweenEx(b, 0.2, Enum.EasingStyle.Back, {Size = UDim2.fromOffset(34, 34)}) end)
        b.MouseLeave:Connect(function() Tween(b, 0.2, {Size = UDim2.fromOffset(30, 30)}) end)
        b.MouseButton1Click:Connect(Safe(function()
            cfgE.tint = t
            Persist.Set("env:tint", t)
            if cfgE.on then Env.Apply() end
        end, "tinta"))
    end
end
do
    local st = Persist.Get("env:tint", nil)
    if type(st) == "table" and tonumber(st[1]) and tonumber(st[2]) and tonumber(st[3]) then
        cfgE.tint = {math.clamp(st[1], 0, 255), math.clamp(st[2], 0, 255), math.clamp(st[3], 0, 255)}
    end
end

local photoBusy = false
function Env.Photo()
    if photoBusy then return end
    photoBusy = true
    task.spawn(function()
        pcall(function() game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
        Gui.Enabled = false
        ToastGui.Enabled = false
        setBlur(false)
        task.wait(8)
        pcall(function() game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.All, true) end)
        Gui.Enabled = true
        ToastGui.Enabled = true
        setBlur(true)
        photoBusy = false
    end)
end
function Env.Disable()
    cfgE.on = false
    handles.on.Set(false, true)
    segPreset.Set("off")
end
Section("Modo foto")
do
    local row = Row(64)
    local hint = Label(row, "Esconde o menu e a interface do Roblox por 8 segundos pra você tirar print, e depois tudo volta sozinho.",
        11, T.Sub, F.Body, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -190, 1, 0))
    hint.TextWrapped = true
    Button(row, "ESCONDER 8s", UDim2.new(1, -150, 0.5, -17), UDim2.fromOffset(136, 34), T.Accent, function()
        Env.Photo()
    end)
end
BtnRow("Restaurar o ambiente do jogo", T.Bad, function()
    Env.Disable()
    Toast("ambiente do jogo restaurado", true)
end, 40)
Env.Loaded = function()
    return cfgE.on
end
end


--------------------------------------------------------------------------------
-- AIMLOCK
--------------------------------------------------------------------------------
do
CurTab = Tab("Aimlock", 0, true)
local function keyName(k)
    if k == Enum.UserInputType.MouseButton1 then return "Left Mouse" end
    if k == Enum.UserInputType.MouseButton2 then return "Right Mouse" end
    if k == Enum.UserInputType.MouseButton3 then return "Middle Mouse" end
    return k.Name
end

Persist.Scope = "aim"
Section("Aimlock")
do
    local row = Row(44)
    Label(row, "STATUS", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 0), UDim2.fromOffset(80, 44))
    local status = Label(row, "Idle", 12, T.Text, F.Bold, Enum.TextXAlignment.Right,
        UDim2.new(0.3, 0, 0, 0), UDim2.new(0.7, -16, 1, 0))
    Aim.OnStatus = function(text)
        status.Text = text
        status.TextColor3 = (text:sub(1, 6) == "Locked") and T.Good or T.Text
    end
end

Toggle("Ativar aimlock", false, function(v)
    Aim.Enabled = v
    if not v and Aim.Holding then releaseAim() end
    refreshFov()
    Toast(v and ("aimlock ligado · segure " .. keyName(Aim.Key)) or "aimlock desligado", v)
end, "Enable aimlock")

do
    local sk = Persist.Get("aim:key", nil)
    if type(sk) == "table" then
        local ok, k = pcall(function() return Enum[sk.t][sk.n] end)
        if ok and k then Aim.Key = k end
    end
    local row = Row(44)
    Label(row, "Segurar pra travar", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -170, 1, 0))
    local bindBtn = Button(row, keyName(Aim.Key), UDim2.new(1, -146, 0.5, -15), UDim2.fromOffset(132, 30), T.Bg, function() end)
    bindBtn.MouseButton1Click:Connect(function()
        Aim.Binding = true
        bindBtn.Text = "aperte uma tecla..."
    end)
    Aim.OnBind = function()
        bindBtn.Text = keyName(Aim.Key)
        Persist.Set("aim:key", {t = Aim.Key.EnumType.Name, n = Aim.Key.Name})
    end
end

do
    local row = Row(44)
    Label(row, "Mirar em", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -170, 1, 0))
    local order = {"Head", "UpperTorso", "HumanoidRootPart"}
    local nice = {Head = "Cabeça", UpperTorso = "Tronco", HumanoidRootPart = "Raiz"}
    local idx = 1
    local sp = Persist.Get("aim:part", nil)
    for i, n in ipairs(order) do
        if n == sp then idx = i end
    end
    Aim.PartName = order[idx]
    local btn = Button(row, nice[Aim.PartName], UDim2.new(1, -146, 0.5, -15), UDim2.fromOffset(132, 30), T.Bg, function() end)
    btn.MouseButton1Click:Connect(function()
        idx = idx % #order + 1
        Aim.PartName = order[idx]
        btn.Text = nice[Aim.PartName]
        Persist.Set("aim:part", Aim.PartName)
    end)
end

Section("Mira")
Slider("FOV do alvo (só na 1ª escolha)", 40, 600, Aim.FOV, "%d px", function(v)
    Aim.FOV = math.floor(v)
    refreshFov()
end, "Target FOV (first pick only)")
Slider("Suavização (0 = trava seca)", 0, 0.9, Aim.Smooth, "%.2f", function(v) Aim.Smooth = v end, "Smoothness (0 = snap)")
Slider("Previsão", 0, 0.3, Aim.Predict, "%.2f s", function(v) Aim.Predict = v end, "Prediction")

Section("Filtros")
Toggle("Ignorar o seu time", Aim.TeamCheck, function(v) Aim.TeamCheck = v end, "Team check")
Toggle("Só alvos visíveis (sem parede)", Aim.WallCheck, function(v) Aim.WallCheck = v end, "Wall check (pick visible only)")
Toggle("Mostrar círculo do FOV", Aim.ShowFOV, function(v)
    Aim.ShowFOV = v
    refreshFov()
end, "Show FOV ring")
Note("Segure o bind: trava no jogador mais perto do cursor e fica nele até morrer. Solte pra escolher outro.", 46)
end

--------------------------------------------------------------------------------
-- VOLEI — linha de mira dos adversarios
--------------------------------------------------------------------------------
do
CurTab = Tab("Volei", 0, true)
Persist.Scope = "volley"

local Drawing = Drawing or (getgenv and getgenv().Drawing)
local VB = {
    On = false, Len = 14, Ball = true, OnlyEnemy = true, Predict = false,
    Thick = 4, Outline = 2, Alpha = 1, Dot = 5, ShowDot = true,
    pairs = {}, ballLine = nil, ballOl = nil, ballDot = nil, cache = nil, t = 0,
    ForceFrame = true,
    Enemy = Color3.fromRGB(255, 60, 60),
    BallC = Color3.fromRGB(255, 214, 84),
    Dark  = Color3.fromRGB(0, 0, 0),
}

-- desenho antigo dessa aba, de uma execucao anterior
if env and env.SilkcoreVolley then
    for _, p in pairs(env.SilkcoreVolley) do
        for _, k in ipairs({"ol", "l", "d"}) do
            if p[k] then pcall(function() p[k]:Remove() end) end
        end
    end
    env.SilkcoreVolley = nil
end
if env then env.SilkcoreVolley = VB.pairs end

-- ── linha: Frame de GUI, não Drawing ────────────────────────────────────────
-- A versão anterior criava Drawing.new("Line") DENTRO do passo de render. Isso
-- funciona em alguns executores e falha em outros — e quando falha o passo
-- inteiro morre, sem erro na tela, e não desenha nada. Aqui a linha é um Frame
-- girado: um ScreenGui próprio e três Frames por jogador. Nenhuma API de
-- executor envolvida, então funciona onde a interface funciona.
local VBGui = nil
do
    local sg = Instance.new("ScreenGui")
    sg.Name = "SilkcoreVolleyLines"
    sg.ResetOnSpawn = false
    -- false de propósito: WorldToViewportPoint devolve coordenada de viewport, que
    -- já desconta a barra de topo. IgnoreGuiInset=true deslocaria tudo ~36 px.
    sg.IgnoreGuiInset = false
    sg.DisplayOrder = 0
    sg.Parent = guiParent
    pcall(SilkGuard.track, sg)

    local layer = Instance.new("Frame")
    layer.Name = "Layer"
    layer.Size = UDim2.fromScale(1, 1)
    layer.BackgroundTransparency = 1
    layer.BorderSizePixel = 0
    layer.ClipsDescendants = false
    layer.Parent = sg

    VBGui = sg
    VB.layer = layer
end

-- ── backend do desenho ──────────────────────────────────────────────────────
-- Drawing escreve direto no compositor do executor: mudar .From/.To não passa
-- por layout nenhum, então acompanha o frame sem engasgo. Frame girado é o
-- plano B — aparece em qualquer executor, mas cada escrita de Position/Size/
-- Rotation dispara um passo de layout da interface, e é isso que fazia a linha
-- andar aos pulos. Aqui os dois caminhos existem; o Drawing tem prioridade.
local HAS_DRAWING = false
do
    if Drawing and type(Drawing.new) == "function" then
        HAS_DRAWING = pcall(function()
            local probe = Drawing.new("Line")
            probe.Visible = false
            probe:Remove()
        end)
    end
end

local function applyStyle(p)
    local olT = VB.Thick + VB.Outline * 2
    if p.kind == "drawing" then
        p.ol.Thickness, p.ol.Transparency = olT, 0.25
        p.l.Thickness,  p.l.Transparency  = VB.Thick, 1 - VB.Alpha
        p.d.Radius, p.d.Thickness = VB.Dot, 2
        p.d.Transparency = 1 - VB.Alpha
    else
        p.ol.AnchorPoint = Vector2.new(0.5, 0.5)
        p.ol.Size        = UDim2.new(0, 0, 0, olT)
        p.ol.BackgroundTransparency = 0.25
        p.l.AnchorPoint  = Vector2.new(0.5, 0.5)
        p.l.Size         = UDim2.new(0, 0, 0, VB.Thick)
        p.l.BackgroundTransparency  = 1 - VB.Alpha
        p.d.AnchorPoint  = Vector2.new(0.5, 0.5)
        p.d.Size         = UDim2.fromOffset(VB.Dot * 2, VB.Dot * 2)
        p.d.BackgroundTransparency  = 1 - VB.Alpha
        -- altura guardada no par: ler Size.Y.Offset a cada quadro é uma travessia
        -- de reflect por jogador, por quadro, à toa.
        p.olH, p.lH = olT, VB.Thick
        p.last = nil
    end
end

local function paint(p)
    if p.kind == "drawing" then
        p.l.Color, p.d.Color = VB.Enemy, VB.Enemy
    else
        p.l.BackgroundColor3, p.d.BackgroundColor3 = VB.Enemy, VB.Enemy
    end
end

local function mkpair()
    if HAS_DRAWING and not VB.ForceFrame then
        local ol = Drawing.new("Line")
        local l  = Drawing.new("Line")
        local d  = Drawing.new("Circle")
        ol.Color, ol.Visible = VB.Dark, false
        l.Visible, d.Visible = false, false
        d.Filled, d.NumSides = true, 24
        local p = { kind = "drawing", ol = ol, l = l, d = d }
        applyStyle(p); paint(p)
        return p
    end
    local ol = New("Frame", {BackgroundColor3=VB.Dark,  BorderSizePixel=0, Visible=false}, VB.layer)
    local l  = New("Frame", {BackgroundColor3=VB.Enemy, BorderSizePixel=0, Visible=false}, VB.layer)
    local d  = New("Frame", {BackgroundColor3=VB.Enemy, BorderSizePixel=0, Visible=false}, VB.layer)
    Round(d, 999)
    local p = { kind = "frame", ol = ol, l = l, d = d }
    applyStyle(p); paint(p)
    return p
end

local function killpair(p)
    for _, k in ipairs({"ol", "l", "d"}) do
        local o = p[k]
        if o then
            if p.kind == "drawing" then pcall(function() o:Remove() end)
            else pcall(function() o:Destroy() end) end
        end
    end
end

local function restyleAll()
    for _, p in pairs(VB.pairs) do
        applyStyle(p); paint(p)
    end
end

-- câmera resolvida uma vez por quadro: Workspace.CurrentCamera é travessia de
-- serviço, e proj é chamado 2x por jogador e 2x por segmento de trajetória.
local CAM = nil

local function proj(pos)
    local cam = CAM or Workspace.CurrentCamera
    if not cam then return nil end
    local v = cam:WorldToViewportPoint(pos)
    -- O segundo retorno do Roblox (onScreen) é falso sempre que o ponto sai do
    -- viewport. Para a linha de mira isso apagava a ponta perto da borda; para
    -- a marca de queda apagava o chão INTEIRO quando a câmera subia atrás da
    -- bola — o destino saía por baixo da tela e o Drawing sumia junto.
    -- Drawing recorta sozinho: basta o ponto estar na frente da câmera.
    if v.Z <= 0 then return nil end
    return Vector2.new(v.X, v.Y)
end

-- O Neck carrega a rotacao da camera do dono, e isso replica. E daqui que sai
-- a direcao real pra onde o adversario esta olhando.
local function lookVec(char, head)
    local neck = char:FindFirstChild("Neck", true)
    if neck and neck:IsA("Motor6D") then return neck.CFrame.LookVector end
    return head.CFrame.LookVector
end

-- O jogo marca a bola com a tag "Ball" e a rede com "Net" via CollectionService.
-- Achar por tag é uma consulta ao índice, não uma varredura: o Workspace tem
-- milhares de partes e o find antigo percorria todas a cada 2 s.
local function findBall()
    local ok, cs = pcall(game.GetService, game, "CollectionService")
    if not ok or not cs then return nil end
    local ok2, list = pcall(cs.GetTagged, cs, "Ball")
    if not ok2 or not list then return nil end
    for _, t in ipairs(list) do
        if t.Parent then
            if t:IsA("BasePart") then return t end
            local pp = t.PrimaryPart
            if pp then return pp end
            local d = t:FindFirstChildWhichIsA("BasePart", true)
            if d then return d end
        end
    end
end

-- ============================================================
-- PREVER QUEDA
-- ============================================================
-- A aceleração é MEDIDA quadro a quadro — (v - v_anterior) / dt — não assumida.
-- Fórmula fechada com workspace.Gravity erraria: o dump mostra VectorForce
-- mexendo na bola durante habilidade. Medindo, eu não preciso saber que existe.
local VBX = {
    cs = game:GetService("CollectionService"),
    Prev = nil, PrevT = 0, Accel = Vector3.new(0, -workspace.Gravity, 0), Settle = 0,
    FloorY = nil, FloorT = 0, LastT = nil, Err = nil, Diag = nil,
    Arc = {}, Segs = 28, Span = 8, Ready = false,
    RingA = nil, RingB = nil, Core = nil, Orb = nil, OrbOl = nil,
    Txt = nil, Flare = nil, RingN = 3,
}

-- Alguns executores não expõem todos os campos de Drawing (Thickness em Circle,
-- NumSides, Filled...). Escrever campo inexistente lança erro e mataria o passo
-- de render inteiro — nenhuma linha, nenhuma marca, nada. set isola cada escrita.
function VBX.set(o, k, v)
    if not o then return end
    pcall(function() o[k] = v end)
end

function VBX.params()
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local f = {}
    for _, tag in ipairs({"Ball", "BallNoCollide", "BallCollideOnly", "Character"}) do
        local ok, list = pcall(VBX.cs.GetTagged, VBX.cs, tag)
        if ok and list then
            for _, v in ipairs(list) do f[#f + 1] = v end
        end
    end
    rp.FilterDescendantsInstances = f
    return rp
end

function VBX.build()
    if VBX.Ready then return end
    for i = 1, VBX.Segs do
        local L = Drawing.new("Line")
        VBX.set(L, "Thickness", 1)
        VBX.set(L, "Transparency", 0.5)
        VBX.Arc[i] = L
    end
    VBX.RingA, VBX.RingB = Drawing.new("Circle"), Drawing.new("Circle")
    VBX.Core, VBX.Flare = Drawing.new("Circle"), Drawing.new("Circle")
    for _, c in ipairs({VBX.RingA, VBX.RingB, VBX.Core, VBX.Flare}) do
        VBX.set(c, "Filled", false)
        VBX.set(c, "NumSides", 40)
        VBX.set(c, "Visible", false)
    end
    VBX.set(VBX.Core, "Filled", true)
    VBX.set(VBX.Flare, "Filled", true)
    VBX.Orb, VBX.OrbOl = Drawing.new("Circle"), Drawing.new("Circle")
    VBX.set(VBX.Orb, "Filled", true)
    VBX.set(VBX.Orb, "NumSides", 20)
    VBX.set(VBX.OrbOl, "Filled", true)
    VBX.set(VBX.OrbOl, "NumSides", 20)
    VBX.Txt = Drawing.new("Text")
    VBX.set(VBX.Txt, "Size", 15)
    VBX.set(VBX.Txt, "Center", true)
    VBX.set(VBX.Txt, "Outline", true)
    VBX.Ready = true
end

function VBX.hide()
    if not VBX.Ready then return end
    for i = 1, VBX.Segs do VBX.Arc[i].Visible = false end
    VBX.RingA.Visible, VBX.RingB.Visible = false, false
    VBX.Core.Visible, VBX.Flare.Visible = false, false
    VBX.Orb.Visible, VBX.OrbOl.Visible = false, false
    VBX.Txt.Visible = false
end

function VBX.floor(pos)
    local hit = Workspace:Raycast(pos, Vector3.new(0, -600, 0), VBX.params())
    if hit then VBX.FloorY = hit.Position.Y end
    VBX.FloorT = os.clock()
end

-- 0.5*a*t^2 + v*t + d = 0  →  menor raiz positiva
function VBX.solve(d, v, a)
    if math.abs(a) < 1e-4 then
        if math.abs(v) < 1e-4 then return nil end
        local t = -d / v
        if t > 0 then return t end
        return nil
    end
    local disc = v * v - 2 * a * d
    if disc < 0 then return nil end
    local s = math.sqrt(disc)
    local t1 = (-v + s) / a
    local t2 = (-v - s) / a
    if t1 > 0 and (t2 <= 0 or t1 < t2) then return t1 end
    if t2 > 0 then return t2 end
end

function VBX.diag()
    local ball = findBall()
    local ntags, nl = 0, 0
    local ok, list = pcall(VBX.cs.GetTagged, VBX.cs, "Ball")
    if ok and list then for _ in ipairs(list) do ntags = ntags + 1 end end
    local okL, launchers = pcall(VBX.cs.GetTagged, VBX.cs, "BallLauncher")
    if okL and launchers then for _ in ipairs(launchers) do nl = nl + 1 end end
    return string.format("bola=%s tag=%d launcher=%d chao=%s T=%s err=%s",
        ball and ball.ClassName or "NAO", ntags, nl,
        tostring(VBX.FloorY), tostring(VBX.LastT),
        VBX.Err and ("SIM:" .. tostring(VBX.Err):sub(1, 48)) or "nao")
end

function VBX.hideMark()
    if not VBX.Ready then return end
    VBX.RingA.Visible, VBX.RingB.Visible = false, false
    VBX.Core.Visible, VBX.Flare.Visible = false, false
    VBX.Txt.Visible = false
end

-- marca de impacto: três anéis + núcleo + contagem. O anel externo respira
-- enquanto falta tempo e fecha conforme o impacto chega — a animação carrega
-- informação, não só enfeite.
function VBX.drawMark(sp, col, urgent, scale, label)
    VBX.build()
    local pulse = 0.5 + 0.5 * math.sin(os.clock() * 6)
    local base = (VB.Dot + 3) * scale
    local grow = 1 + 0.45 * pulse * (1 - urgent)

    VBX.set(VBX.RingA, "Position", sp)
    VBX.set(VBX.RingA, "Radius", base + (10 + 6 * pulse) * grow)
    VBX.set(VBX.RingA, "Thickness", 2)
    VBX.set(VBX.RingA, "Color", col)
    VBX.set(VBX.RingA, "Filled", false)
    VBX.set(VBX.RingA, "Transparency", (0.42 + 0.32 * pulse) * VB.Alpha)
    VBX.set(VBX.RingA, "Visible", true)

    VBX.set(VBX.RingB, "Position", sp)
    VBX.set(VBX.RingB, "Radius", base + 3)
    VBX.set(VBX.RingB, "Thickness", 2)
    VBX.set(VBX.RingB, "Color", col)
    VBX.set(VBX.RingB, "Filled", false)
    VBX.set(VBX.RingB, "Transparency", 0.22 * VB.Alpha)
    VBX.set(VBX.RingB, "Visible", true)

    VBX.set(VBX.Core, "Position", sp)
    VBX.set(VBX.Core, "Radius", math.max(3, base * 0.55))
    VBX.set(VBX.Core, "Color", col)
    VBX.set(VBX.Core, "Filled", true)
    VBX.set(VBX.Core, "Transparency", (0.14 + 0.3 * urgent) * VB.Alpha)
    VBX.set(VBX.Core, "Visible", true)

    VBX.set(VBX.Flare, "Position", sp)
    VBX.set(VBX.Flare, "Radius", base + 26 * (1 - urgent) + 6 * pulse)
    VBX.set(VBX.Flare, "Color", col)
    VBX.set(VBX.Flare, "Filled", true)
    VBX.set(VBX.Flare, "Transparency", 0.88 * VB.Alpha)
    VBX.set(VBX.Flare, "Visible", urgent > 0.02)

    VBX.set(VBX.Txt, "Text", label)
    VBX.set(VBX.Txt, "Position", sp + Vector2.new(0, base + 20))
    VBX.set(VBX.Txt, "Color", col)
    VBX.set(VBX.Txt, "Visible", true)
end

function VBX.step(ball)
    local now = os.clock()
    VBX.build()

    -- FASE 1 — alguém está mirando o saque. O jogo calculou a queda e deixou o
    -- Beam "Trajectory" dentro do launcher; Attachment1 dele É o ponto exato
    -- (dump 37520-37539). Ler o Beam, e não o Terrain, evita pegar a mira de
    -- outro jogador quando duas pessoas miram ao mesmo tempo.
    local live = ball ~= nil and ball.Parent ~= nil
    local aimPos = nil

    if not live then
        local okL, launchers = pcall(VBX.cs.GetTagged, VBX.cs, "BallLauncher")
        if okL and launchers then
            local best = nil
            for _, L in ipairs(launchers) do
                if L.Parent and L:GetAttribute("IsActive") == true then
                    if L:GetAttribute("OwnerId") == LocalPlayer.UserId then
                        best = L
                        break
                    end
                    if not best then best = L end
                end
            end
            if best then
                local beam = best:FindFirstChild("Trajectory")
                if beam and beam:IsA("Beam") and beam.Attachment1 then
                    aimPos = beam.Attachment1.WorldPosition
                end
            end
        end
    end

    if aimPos then
        local sp = proj(aimPos)
        if not sp then VBX.hide(); return end
        for i = 1, VBX.Segs do VBX.Arc[i].Visible = false end
        VBX.Orb.Visible, VBX.OrbOl.Visible = false, false
        VBX.drawMark(sp, VB.BallC, 0.05, 1.35, "MIRA")
        return
    end

    if not live then VBX.Prev = nil; VBX.hide(); return end

    local p, v = ball.Position, ball.AssemblyLinearVelocity

    -- aceleração medida na bola viva. O dump (54553) mostra que o jogo integra
    -- pos(t) = p + v*t + accel*0.5*t² — aceleração constante por trecho. Medindo
    -- accel eu cubro gravidade-base, GravityMultiplier de habilidade e drag sem
    -- precisar saber qual habilidade foi usada.
    if VBX.Prev and VBX.PrevT > 0 then
        local dtm = now - VBX.PrevT
        if dtm > 0.004 then
            local a = (v - VBX.Prev) / dtm
            local g = workspace.Gravity
            if a.Magnitude < g * 8 then
                if VBX.Settle > 3 and (a - VBX.Accel).Magnitude > g * 1.5 then
                    VBX.Accel = a        -- impacto: obedece o estado novo na hora
                    VBX.Settle = 0
                else
                    VBX.Accel = VBX.Accel:Lerp(a, 0.45)
                    VBX.Settle = VBX.Settle + 1
                end
            end
        end
    end
    VBX.Prev, VBX.PrevT = v, now

    if not VBX.FloorY or (now - VBX.FloorT) > 1 then VBX.floor(p) end
    local floorY = VBX.FloorY
    if not floorY then VBX.hide(); return end

    local T = VBX.solve(p.Y - floorY, v.Y, VBX.Accel.Y)
    VBX.LastT = T
    if not T or T <= 0 or T > 15 then VBX.hide(); return end

    -- amostra de tempo igual. Aceleração constante ⇒ parábola exata, então a
    -- curva desenhada é a curva real, não uma aproximação por passos.
    local pts = {}
    for i = 0, VBX.Segs do
        local t = T * i / VBX.Segs
        pts[i + 1] = p + v * t + VBX.Accel * (0.5 * t * t)
    end

    -- varredura segmento a segmento: a rede é parede fina, e um raio único
    -- bola→destino tunnelaria por ela. Segmento não.
    local rp = VBX.params()
    local cut, cutPos = nil, nil
    for i = 1, VBX.Segs do
        local seg = pts[i + 1] - pts[i]
        if seg.Magnitude > 0.01 then
            local hit = Workspace:Raycast(pts[i], seg, rp)
            if hit then cut, cutPos = i, hit.Position; break end
        end
    end

    local n, land = VBX.Segs, pts[VBX.Segs + 1]
    if cut then
        n, land = cut, cutPos
        pts[n + 1] = land
    end

    local urgent = math.clamp(1 - T / 1.2, 0, 1)
    local col = VB.BallC:Lerp(Color3.fromRGB(255, 55, 55), urgent)
    if cut then col = col:Lerp(Color3.fromRGB(255, 190, 60), 0.65) end

    for i = 1, VBX.Segs do
        local L = VBX.Arc[i]
        if i <= n then
            local a, b = proj(pts[i]), proj(pts[i + 1])
            L.Color, L.Thickness = col, math.max(1, VB.Thick - 1)
            L.Transparency = (0.12 + 0.55 * (i / VBX.Segs)) * VB.Alpha
            if a and b then
                L.From, L.To, L.Visible = a, b, true
            else
                L.Visible = false
            end
        else
            L.Visible = false
        end
    end

    -- orbe fantasma percorrendo a trajetória: comunica ritmo, não só destino
    local tp = T * ((now * 0.9) % 1)
    local gs = proj(p + v * tp + VBX.Accel * (0.5 * tp * tp))
    if gs then
        VBX.OrbOl.Position, VBX.Orb.Position = gs, gs
        VBX.OrbOl.Radius, VBX.Orb.Radius = VB.Dot + 4, VB.Dot + 2
        VBX.OrbOl.Color, VBX.Orb.Color = VB.Dark, col
        VBX.OrbOl.Transparency, VBX.Orb.Transparency = 0.72 * VB.Alpha, 0.35 * VB.Alpha
        VBX.Orb.Visible, VBX.OrbOl.Visible = true, true
    else
        VBX.Orb.Visible, VBX.OrbOl.Visible = false, false
    end

    local sp = proj(land)
    if sp then
        VBX.drawMark(sp, col, urgent, 1, string.format("%.2f s", T))
    else
        VBX.hideMark()
    end
end


-- Roda fora do passo de render: criar Instance (ou Drawing) dentro do quadro é
-- o que fazia a interface engasgar. Aqui só a lista de pares é mantida, e a
-- altura da origem é medida uma vez por personagem.
local function sync()
    local seen = {}
    local now = os.clock()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            seen[plr] = true
            local p = VB.pairs[plr]
            if not p then p = mkpair(); VB.pairs[plr] = p end
            local char = plr.Character
            if char and not char.Parent then char = nil end
            if char ~= p.char or (char and now - (p.yoffAt or 0) > 4) then
                p.char, p.yoffAt, p.yoff, p.dir = char, now, 0, nil
                if char then
                    -- Origem = centro do corpo. O HumanoidRootPart deste jogo fica
                    -- no chão, e era por isso que a linha nascia no pé. A caixa do
                    -- modelo não depende de nome de parte nem do rig que ele usa.
                    local ok, box = pcall(function() return char:GetBoundingBox() end)
                    local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
                    if ok and box and root then
                        p.yoff = math.clamp(box.Position.Y - root.Position.Y, -2, 7)
                    end
                end
            end
        end
    end
    for plr, p in pairs(VB.pairs) do
        if not seen[plr] then killpair(p); VB.pairs[plr] = nil end
    end
end

local stepErr = nil

local function stepRaw(dt)
    SilkGuard.Beats = SilkGuard.Beats + 1
    CAM = Workspace.CurrentCamera

    VB.t = VB.t + dt
    if VB.Predict or VB.t > 2 then VB.t = 0; VB.cache = findBall() end

    local myTeam = LocalPlayer.Team
    for plr, p in pairs(VB.pairs) do
        local char = plr.Character
        if char and not char.Parent then char = nil end
        local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart or char:FindFirstChild("Head"))
        -- O jogo usa Team real do Roblox (Red/Purple/White/Black/Orange Team),
        -- então comparar o objeto Team é exato. Sem time (lobby), mostra todos.
        local ally = VB.OnlyEnemy and myTeam ~= nil and plr.Team == myTeam
        if VB.On and root and not ally then
            local o = root.Position + Vector3.new(0, p.yoff or 0, 0)
            -- A direção sai do Neck, que replica a ~10-20 Hz e NÃO é interpolado
            -- pelo cliente — era daí que vinha o pulo quadro a quadro. Suaviza
            -- com lerp dependente de dt: mesma velocidade em qualquer FPS.
            local want = lookVec(char, root)
            local d = p.dir
            if not d then
                p.dir = want
            else
                local nd = d:Lerp(want, math.clamp(dt * 14, 0, 1))
                p.dir = (nd.Magnitude > 0.05) and nd.Unit or want
            end
            local a = proj(o)
            local b = proj(o + p.dir * VB.Len)
            if a and b then
                if p.kind == "drawing" then
                    p.ol.From, p.ol.To, p.ol.Visible = a, b, true
                    p.l.From,  p.l.To,  p.l.Visible  = a, b, true
                    p.d.Position, p.d.Visible = b, VB.ShowDot
                else
                    -- Cada escrita em Frame dispara layout de interface: só grava
                    -- o que mudou de verdade. Abaixo de meio pixel e meio grau o
                    -- olho não vê — e era esse excesso que travava a linha.
                    local dx, dy = b.X - a.X, b.Y - a.Y
                    local len = math.sqrt(dx * dx + dy * dy)
                    local mid = (a + b) * 0.5
                    local ang = math.deg(math.atan2(dy, dx))
                    local L = p.last
                    if not L or math.abs(L.x - mid.X) > 0.5 or math.abs(L.y - mid.Y) > 0.5
                       or math.abs(L.len - len) > 0.5 or math.abs(L.ang - ang) > 0.4 then
                        p.ol.Position = UDim2.fromOffset(mid.X, mid.Y)
                        p.ol.Size     = UDim2.new(0, len, 0, p.olH)
                        p.ol.Rotation = ang
                        p.l.Position  = UDim2.fromOffset(mid.X, mid.Y)
                        p.l.Size      = UDim2.new(0, len, 0, p.lH)
                        p.l.Rotation  = ang
                        p.last = {x = mid.X, y = mid.Y, len = len, ang = ang}
                    end
                    p.d.Position = UDim2.fromOffset(b.X, b.Y)
                    if not p.ol.Visible then p.ol.Visible, p.l.Visible = true, true end
                    if p.d.Visible ~= VB.ShowDot then p.d.Visible = VB.ShowDot end
                end
            else
                if p.ol.Visible then p.ol.Visible, p.l.Visible, p.d.Visible = false, false, false end
            end
        else
            if p.ol.Visible then p.ol.Visible, p.l.Visible, p.d.Visible = false, false, false end
        end
    end

    if HAS_DRAWING and Drawing then
    if not VB.ballLine then
        VB.ballOl   = Drawing.new("Line")
        VB.ballLine = Drawing.new("Line")
        VB.ballDot  = Drawing.new("Circle")
        VB.ballOl.Color, VB.ballOl.Visible = VB.Dark, false
        VB.ballLine.Visible, VB.ballDot.Visible = false, false
        VB.ballDot.Filled, VB.ballDot.NumSides = true, 24
    end
    VB.ballOl.Thickness    = VB.Thick + VB.Outline * 2
    VB.ballOl.Transparency = 0.25
    VB.ballLine.Thickness    = VB.Thick
    VB.ballLine.Transparency = 1 - VB.Alpha
    VB.ballLine.Color, VB.ballDot.Color = VB.BallC, VB.BallC
    VB.ballDot.Radius, VB.ballDot.Thickness = VB.Dot, 2
    VB.ballDot.Transparency = 1 - VB.Alpha

    local ball = VB.cache
    if VB.On and VB.Ball and ball and ball.Parent then
        local p0 = ball.Position
        local a = proj(p0)
        local b = proj(p0 + ball.AssemblyLinearVelocity * 0.55)
        if a and b then
            VB.ballOl.From, VB.ballOl.To, VB.ballOl.Visible = a, b, true
            VB.ballLine.From, VB.ballLine.To, VB.ballLine.Visible = a, b, true
            VB.ballDot.Position = b
            VB.ballDot.Visible  = VB.ShowDot
        else
            VB.ballOl.Visible, VB.ballLine.Visible, VB.ballDot.Visible = false, false, false
        end
    else
        VB.ballOl.Visible, VB.ballLine.Visible, VB.ballDot.Visible = false, false, false
    end
    end

    if VB.Predict then
        local okP, errP = pcall(VBX.step, VB.cache)
        if not okP then VBX.Err = tostring(errP) end
    else
        VBX.hide()
    end
end

-- O passo nunca derruba o bind: erro vira texto no diagnóstico e o quadro
-- seguinte tenta de novo. Antes, um erro de Drawing matava o passo pra sempre.
local function step(dt)
    local ok, err = pcall(stepRaw, dt)
    if not ok then stepErr = tostring(err) end
end

-- exporta o passo para o SilkGuard: ele estava fora de escopo lá embaixo e o
-- vigia acabava guardando nil. Era esse nil que matava a linha de mira no
-- primeiro travamento do frame.
VOL_STEP = step

-- lista de pares mantida fora do quadro de render
pcall(sync)
pcall(function() Players.PlayerAdded:Connect(function() task.spawn(sync) end) end)
pcall(function() Players.PlayerRemoving:Connect(function() task.spawn(sync) end) end)
task.spawn(function()
    -- para sozinho quando outra execucao substitui a tabela de pares; nao
    -- depende de VBGui continuar com pai, que era um jeito silencioso de morrer
    -- no primeiro quadro e deixar pairs vazio pra sempre.
    while (not env) or (env.SilkcoreVolley == VB.pairs) do
        local ok, err = pcall(sync)
        if not ok and not stepErr then stepErr = "sync: " .. tostring(err) end
        task.wait(0.35)
    end
end)

-- troca de backend a quente: derruba os pares e remonta no outro caminho
local function rebuild()
    for plr, p in pairs(VB.pairs) do killpair(p); VB.pairs[plr] = nil end
    local ok, err = pcall(sync)
    if not ok then stepErr = "rebuild: " .. tostring(err) end
end

local COLORS = {
    {n = "vermelho", c = Color3.fromRGB(255, 60, 60)},
    {n = "ciano",    c = Color3.fromRGB(0, 240, 255)},
    {n = "verde",    c = Color3.fromRGB(70, 255, 120)},
    {n = "magenta",  c = Color3.fromRGB(255, 60, 220)},
    {n = "branco",   c = Color3.fromRGB(255, 255, 255)},
}
local colorIdx = 1

Section("Linha de mira")
Toggle("Ativar linha de mira", false, function(v)
    VB.On = v
    Toast(v and "linha de mira ligada" or "linha de mira desligada", v)
    -- autorrelato: 6 s depois de ligar, se nada estiver visivel, o motivo aparece
    -- na tela sem precisar apertar diagnostico.
    if v then
        task.delay(6, function()
            if not VB.On then return end
            local n, vis = 0, 0
            for _, p in pairs(VB.pairs) do
                n = n + 1
                if p.l and p.l.Visible then vis = vis + 1 end
            end
            if #Players:GetPlayers() > 1 and vis == 0 then
                local bk = (HAS_DRAWING and not VB.ForceFrame) and "drawing" or "frame"
                Toast(("ligada, nada visivel: bk=%s pairs=%d err=%s"):format(
                    bk, n, tostring(stepErr or "-")), false)
            end
        end)
    end
end, "Volley aim line")

Toggle("Só inimigos (ignorar meu time)", true, function(v)
    VB.OnlyEnemy = v
    Toast(v and "só adversários" or "todos os jogadores", true)
end, "Volley enemy only")

Slider("Tamanho da linha", 4, 40, 14, "%d studs", function(v)
    VB.Len = math.floor(v + 0.5)
end, "Volley line length")

Section("Aparência da linha")
Slider("Espessura", 1, 14, 4, "%d px", function(v)
    VB.Thick = math.floor(v + 0.5)
    restyleAll()
end, "Volley thickness")

Slider("Contorno (halo escuro)", 0, 6, 2, "%d px", function(v)
    VB.Outline = math.floor(v + 0.5)
    restyleAll()
end, "Volley outline")

Slider("Opacidade", 20, 100, 100, "%d%%", function(v)
    VB.Alpha = v / 100
    restyleAll()
end, "Volley opacity")

Toggle("Ponto na ponta", true, function(v) VB.ShowDot = v end, "Volley dot on")

Slider("Tamanho do ponto", 2, 16, 5, "%d px", function(v)
    VB.Dot = math.floor(v + 0.5)
    restyleAll()
end, "Volley dot size")

BtnRow("TROCAR COR DA LINHA", T.Card, function()
    colorIdx = colorIdx % #COLORS + 1
    VB.Enemy = COLORS[colorIdx].c
    restyleAll()
    Toast("cor: " .. COLORS[colorIdx].n, true)
end, 34)

Toggle("Trajetória da bola", true, function(v) VB.Ball = v end, "Volley ball trajec")

Section("Prever queda")
Toggle("Marcar onde a bola cai", false, function(v)
    VB.Predict = v
    VBX.Err = nil
    if not v then VBX.hide() end
    Toast(v and "previsao de queda ligada" or "previsao desligada", v)
    if v then
        task.delay(1.5, function()
            if VB.Predict then Toast(VBX.diag(), true) end
        end)
    end
end, "Volley predict")

-- Persist devolve o desenho do switch, mas nunca chama o callback: depois de
-- re-executar, a linha ficava com "ON" na tela e VB.On em false — nada desenhado.
-- Aqui o estado real é relido do disco uma vez, com as mesmas chaves.
VB.On        = Persist.Get("volley:Volley aim line", false) == true
VB.OnlyEnemy = Persist.Get("volley:Volley enemy only", true) ~= false
VB.Ball      = Persist.Get("volley:Volley ball trajec", true) ~= false
VB.ShowDot   = Persist.Get("volley:Volley dot on", true) ~= false
VB.Predict   = Persist.Get("volley:Volley predict", false) == true
VB.ForceFrame = Persist.Get("volley:Volley use drawing", false) ~= true

Slider("Alcance da previsao", 1, 10, 8, "%d s", function(v)
    VBX.Span = v
end, "Volley predict span")

BtnRow("TESTAR PREVISAO", T.Card, function()
    Toast(VBX.diag(), true)
end, 34)

-- cria os Drawings agora, na thread principal. Criar dentro do passo de render
-- funciona em alguns executores e falha em outros — aqui não tem risco.
if Drawing then
    local okB, errB = pcall(VBX.build)
    if not okB then VBX.Err = tostring(errB) end
end

Note("Duas fases. Mirando o saque, a marca usa o destino que o proprio jogo ja calculou (attachment TrajectoryFinish no Terrain) e escreve MIRA. Com a bola no ar, a aceleracao e medida dela quadro a quadro e a queda sai da equacao exata de parabola que o jogo usa. Rede no caminho corta o arco e pinta de ambar. A contagem e o tempo real ate o impacto. Tudo leitura: nada sai daqui.", 76)

Note("A linha sai do centro do corpo do adversário — medida pela caixa do modelo, não pelo nome da parte, porque neste jogo o HumanoidRootPart fica no chão — na direção em que ele está olhando. O Roblox replica a rotação do pescoço, então dá pra ler a intenção de ataque antes do toque. A direção é suavizada por lerp: o pescoço replica a 10-20 Hz e sem isso a linha andava aos pulos. É desenho de tela: nada é criado no jogo, nada replica pro servidor.", 58)

if HAS_DRAWING then
    Toggle("Desenho por Drawing (experimental)", false, function(v)
        VB.ForceFrame = not v
        rebuild()
        Toast(v and "desenho: Drawing" or "desenho: Frame de GUI", true)
    end, "Volley use drawing")
end

BtnRow("DIAGNOSTICO DA LINHA", T.Card, function()
    local n, vis = 0, 0
    for _, p in pairs(VB.pairs) do
        n = n + 1
        if p.l and p.l.Visible then vis = vis + 1 end
    end
    local cam = Workspace.CurrentCamera
    local msg = ("bk=%s gui=%s on=%s pairs=%d visiveis=%d beats=%d cam=%s err=%s"):format(
        HAS_DRAWING and "drawing" or "frame",
        tostring(VBGui ~= nil and VBGui.Parent ~= nil),
        tostring(VB.On), n, vis, SilkGuard.Beats,
        tostring(cam ~= nil), tostring(stepErr or VBX.Err or "-"))
    Toast(msg, VB.On and vis > 0)
    pcall(function() print("[SilkCore Volei]", msg) end)
end, 34)

-- a linha não depende mais de Drawing: o passo é sempre amarrado. Se o executor
-- não tiver Drawing, só a trajetória da bola e a previsão de queda ficam fora.
RunService:BindToRenderStep(VOL_BIND, Enum.RenderPriority.Camera.Value + 4, step)
if not Drawing then
    Note("Seu executor não expõe a Drawing API: a linha de mira funciona igual, mas a trajetória da bola e a previsão de queda não desenham.", 40)
end
end

--------------------------------------------------------------------------------
-- DIVERSOS
--------------------------------------------------------------------------------
do
CurTab = Tab("Diversos", 0, true)
Persist.Scope = "misc"
Section("Tela")
Toggle("Tela esticada", false, function(v)
    Mods.SetStretch(v)
    Toast(v and "tela esticada ligada" or "tela esticada desligada", v)
end, "Stretch screen")
Slider("Quanto esticar (menor = mais largo)", 0.35, 1, Mods.Stretch.Y, "%.2f", function(v) Mods.Stretch.Y = v end, "Stretch amount (lower = wider)")
Note("Achata a imagem na vertical e os jogadores parecem mais largos. É só visual; o aimlock continua usando a câmera real.", 46)
Section("Movimento")
Toggle("Pulo duplo", false, function(v)
    Mods.DJ.Enabled, Mods.DJ.Used = v, 0
    Toast(v and "pulo duplo ligado" or "pulo duplo desligado", v)
end, "Double jump")
Slider("Pulos no ar", 1, 5, Mods.DJ.Max, "%.0f", function(v) Mods.DJ.Max = math.max(1, math.floor(v + 0.5)) end, "Air jumps")
Note("Aperte pular de novo no ar. Zera quando você toca o chão. Se o jogo bloqueia pulo ou zera a velocidade, esse recurso não funciona nele.", 46)
end

--------------------------------------------------------------------------------
-- DESEMPENHO: graficos ao vivo (fps, ping, memoria) e ajustes de grafico
--------------------------------------------------------------------------------
CurTab = Tab("Desempenho", 0, true)
Persist.Scope = "perf"
do
local P = LAY.Perf
local function Chart(title, color)
    local row = Row(138)
    Label(row, title, 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 10), UDim2.fromOffset(120, 14))
    local val = Label(row, "-", 13, T.Text, F.Mono, Enum.TextXAlignment.Right, UDim2.new(1, -236, 0, 8), UDim2.fromOffset(220, 18))
    local area = New("Frame", {
        Size = UDim2.new(1, -32, 0, 82), Position = UDim2.fromOffset(16, 38), BackgroundColor3 = T.Bg, BorderSizePixel = 0,
        ClipsDescendants = true,
    }, row)
    Round(area, 6)
    local bars = {}
    for i = 1, 60 do
        local b = New("Frame", {
            AnchorPoint = Vector2.new(0, 1), Size = UDim2.new(1 / 60, -1, 0, 2), Position = UDim2.new((i - 1) / 60, 1, 1, 0),
            BackgroundColor3 = color, BackgroundTransparency = 0.7 - 0.55 * (i / 60), BorderSizePixel = 0,
        }, area)
        if color == T.Accent then bindAcc(b, "BackgroundColor3") end
        bars[i] = b
    end
    local foot = Label(row, "", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 122), UDim2.new(1, -32, 0, 12))
    return {bars = bars, val = val, foot = foot}
end
Section("Ao vivo")
local cFps = Chart("FPS (últimos 30 s)", T.Accent)
local cPing = Chart("PING (últimos 30 s)", T.Accent2)
local function stats(list)
    local mn, mx, sum = math.huge, 0, 0
    for _, v in ipairs(list) do
        mn, mx, sum = math.min(mn, v), math.max(mx, v), sum + v
    end
    if #list == 0 then return 0, 0, 0 end
    return mn, mx, sum / #list
end
local function draw(chart, list, floorMax, unit)
    local _, mx, avg = stats(list)
    local top = math.max(floorMax, mx)
    local n = #list
    for i = 1, 60 do
        local v = list[n - 60 + i]
        local h = v and math.max(2, (v / top) * 82) or 2
        chart.bars[i].Size = UDim2.new(1 / 60, -1, 0, h)
    end
    local mn = stats(list)
    chart.val.Text = string.format("%d %s", list[n] or 0, unit)
    chart.foot.Text = string.format("mín %d   média %d   máx %d", mn == math.huge and 0 or mn, avg, mx)
end
LAY.PerfDraw = function()
    draw(cFps, P.fps, 60, "fps")
    draw(cPing, P.ping, 100, "ms")
end
tabHooks["Desempenho"] = function()
    LAY.PerfDraw()
end
do
    local row = Row(54)
    local lbl = Label(row, "MEMÓRIA DO CLIENTE", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 0), UDim2.fromOffset(160, 54))
    local memLbl = Label(row, "-", 15, T.Text, F.Mono, Enum.TextXAlignment.Right, UDim2.new(1, -216, 0, 0), UDim2.fromOffset(200, 54))
    task.spawn(function()
        while row.Parent do
            memLbl.Text = string.format("%d MB", math.floor(P.mem + 0.5))
            task.wait(1)
        end
    end)
    lbl.ZIndex = 2
end

Section("Ajustes de gráfico")
local pendingCap = 144
Slider("Limite de FPS", 30, 360, 144, "%d", function(v)
    pendingCap = math.floor(v + 0.5)
end, "fpscap")
BtnRow("Aplicar o limite de FPS", T.Accent, function()
    if setfpscap then
        setfpscap(pendingCap)
        Toast("limite de fps: " .. pendingCap, true)
    else
        Toast("seu executor não tem setfpscap", false)
    end
end, 40)
Toggle("Sombras do jogo", true, function(v)
    game:GetService("Lighting").GlobalShadows = v
end, "shadows")
Slider("Qualidade gráfica", 1, 10, 10, "%d", function(v)
    local n = math.clamp(math.floor(v + 0.5), 1, 10)
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel["Level" .. string.format("%02d", n)]
    end)
end, "quality")
BtnRow("Liberar memória (coletar lixo)", T.Card, function()
    local before = P.mem
    pcall(collectgarbage, "collect")
    Toast("coleta de lixo executada (era " .. math.floor(before) .. " MB)", true)
end, 40)
end

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local MenuKeys = {Extra = nil, Look = nil, Binding = false, OnBind = function() end, OnBindLook = function() end}
do
CurTab = Tab("Config", 0, true)
Persist.Scope = "cfg"
Section("Aparência")
do
    local row = Row(114)
    Label(row, "Tema", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 10), UDim2.fromOffset(200, 18))
    local rings = {}
    local function paintRings()
        local cur = Persist.Get("cfg:theme", "carmim")
        for id, r in pairs(rings) do Tween(r, 0.2, {Transparency = (id == cur) and 0 or 1}) end
    end
    for i, th in ipairs(THEMES) do
        local b = New("TextButton", {
            Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(46, 46), Position = UDim2.fromOffset(16 + (i - 1) * 58, 36),
            BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
        }, row)
        Round(b, 8)
        local sg = New("UIGradient", {
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, th.a), ColorSequenceKeypoint.new(0.5, th.a),
                ColorSequenceKeypoint.new(0.51, th.b), ColorSequenceKeypoint.new(1, th.b),
            }), Rotation = 45,
        }, b)
        if th.id == "custom" then LAY.CustomGrad = sg end
        local ring = Stroke(b, Color3.new(1, 1, 1), 2)
        ring.Transparency = 1
        rings[th.id] = ring
        b.MouseEnter:Connect(function() TweenEx(b, 0.2, Enum.EasingStyle.Back, {Size = UDim2.fromOffset(50, 50)}) end)
        b.MouseLeave:Connect(function() Tween(b, 0.2, {Size = UDim2.fromOffset(46, 46)}) end)
        b.MouseButton1Click:Connect(Safe(function()
            SetTheme(th.id)
            Persist.Set("cfg:theme", th.id)
            paintRings()
            Toast("tema " .. th.name, true)
        end, "tema"))
    end
    Label(row, "o tema muda o menu inteiro na hora e fica salvo", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 92), UDim2.new(1, -32, 0, 14))
    paintRings()
    LAY.PaintRings = paintRings
end
Toggle("Desfoque do fundo", true, function(v)
    cfg.Blur = v
    setBlur(isOpen)
end, "Blur")
local scene3dOn = true
Toggle("Cenário 3D no fundo", true, function(v)
    scene3dOn = v
    LAY.S3.enable(v and not ANIM.reduce)
end, "Scene3D")
Toggle("Animações reduzidas", false, function(v)
    ANIM.reduce = v
    ANIM.speed = v and 0.3 or 1
    LAY.S3.enable(scene3dOn and not v)
end, "Reduce")
Slider("Transparência dos painéis", 0, 0.6, 0.2, "%.2f", function(v)
    LAY.Rail.BackgroundTransparency = v
    LAY.Panel.BackgroundTransparency = v
end, "PanelT")

Section("Cor própria")
do
    local ch, cs, cv = 0.97, 0.78, 1
    local swFrame, hexLbl
    local function pickedColor()
        return Color3.fromHSV(ch, cs, cv)
    end
    local function refreshPick()
        local c = pickedColor()
        if swFrame then swFrame.BackgroundColor3 = c end
        if hexLbl then
            hexLbl.Text = string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
        end
    end
    Slider("Matiz", 0, 360, ch * 360, "%d°", function(v)
        ch = v / 360
        refreshPick()
    end, "cuH")
    Slider("Saturação", 0, 100, cs * 100, "%d%%", function(v)
        cs = v / 100
        refreshPick()
    end, "cuS")
    Slider("Brilho", 20, 100, cv * 100, "%d%%", function(v)
        cv = v / 100
        refreshPick()
    end, "cuV")
    local row = Row(62)
    swFrame = New("Frame", {
        Size = UDim2.fromOffset(44, 36), Position = UDim2.fromOffset(16, 13), BackgroundColor3 = pickedColor(), BorderSizePixel = 0,
    }, row)
    Round(swFrame, 6)
    Stroke(swFrame, T.Stroke2, 1)
    hexLbl = Label(row, "", 12, T.Text, F.Mono, nil, UDim2.fromOffset(72, 0), UDim2.fromOffset(90, 62))
    Button(row, "USAR COMO TEMA", UDim2.new(1, -170, 0.5, -16), UDim2.fromOffset(154, 32), T.Accent, function()
        local c = pickedColor()
        SetCustomAccent(c)
        Persist.Set("cfg:custom", {math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)})
        Persist.Set("cfg:theme", "custom")
        local th = THEMES[#THEMES]
        if LAY.CustomGrad then
            LAY.CustomGrad.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, th.a), ColorSequenceKeypoint.new(0.5, th.a),
                ColorSequenceKeypoint.new(0.51, th.b), ColorSequenceKeypoint.new(1, th.b),
            })
        end
        SetTheme("custom")
        if LAY.PaintRings then LAY.PaintRings() end
        Toast("tema personalizado aplicado", true)
    end)
    refreshPick()
end

Section("Atalhos")
do
    local row = Row(48)
    Label(row, "Tecla extra pra abrir/fechar", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 6), UDim2.new(1, -190, 0, 18))
    Label(row, "RightControl e RightShift sempre funcionam", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 26), UDim2.new(1, -190, 0, 14))
    local saved = Persist.Get("cfg:menukey", nil)
    if type(saved) == "string" then
        local ok, k = pcall(function() return Enum.KeyCode[saved] end)
        if ok and k then MenuKeys.Extra = k end
    end
    local btn = Button(row, MenuKeys.Extra and MenuKeys.Extra.Name or "nenhuma", UDim2.new(1, -162, 0.5, -15),
        UDim2.fromOffset(148, 30), T.Card, function()
            MenuKeys.Binding = "extra"
            Toast("aperte uma tecla (Esc limpa)", true)
        end)
    MenuKeys.OnBind = function()
        btn.Text = MenuKeys.Extra and MenuKeys.Extra.Name or "nenhuma"
        Persist.Set("cfg:menukey", MenuKeys.Extra and MenuKeys.Extra.Name or nil)
    end
end

do
    local row = Row(48)
    Label(row, "Tecla pra ciclar os looks", 13, T.Text, F.Body, nil, UDim2.fromOffset(16, 6), UDim2.new(1, -190, 0, 18))
    Label(row, "aplica o próximo look salvo", 10, T.Faint, F.Mono, nil, UDim2.fromOffset(16, 26), UDim2.new(1, -190, 0, 14))
    local saved = Persist.Get("cfg:lookkey", nil)
    if type(saved) == "string" then
        local ok, k = pcall(function() return Enum.KeyCode[saved] end)
        if ok and k then MenuKeys.Look = k end
    end
    local btn = Button(row, MenuKeys.Look and MenuKeys.Look.Name or "nenhuma", UDim2.new(1, -162, 0.5, -15),
        UDim2.fromOffset(148, 30), T.Card, function()
            MenuKeys.Binding = "look"
            Toast("aperte uma tecla (Esc limpa)", true)
        end)
    MenuKeys.OnBindLook = function()
        btn.Text = MenuKeys.Look and MenuKeys.Look.Name or "nenhuma"
        Persist.Set("cfg:lookkey", MenuKeys.Look and MenuKeys.Look.Name or nil)
    end
end
Note("Ctrl esquerdo + K (ou /) abre a paleta de comandos: digite o que quer fazer (aba, tema, look, efeito).", 44)

Section("Registro")
local logLbl, logScroll
do
    local row = Row(210)
    logScroll = New("ScrollingFrame", {
        Size = UDim2.new(1, -24, 1, -60), Position = UDim2.fromOffset(12, 10), BackgroundColor3 = T.Bg, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = T.Stroke2, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
    }, row)
    Round(logScroll, 6)
    New("UIPadding", {
        PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6),
    }, logScroll)
    logLbl = New("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Text = "",
        Font = F.Mono, TextSize = 10, TextColor3 = T.Sub, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
    }, logScroll)
    Button(row, "COPIAR REGISTRO", UDim2.new(0, 12, 1, -40), UDim2.new(0.5, -17, 0, 30), T.Accent, function()
        local text = table.concat(Log.lines, "\n")
        if setclipboard then
            pcall(setclipboard, text)
            Toast("registro copiado (" .. #Log.lines .. " linhas)", true)
        else
            Toast("seu executor não tem setclipboard", false)
        end
    end)
    Button(row, "LIMPAR", UDim2.new(0.5, 5, 1, -40), UDim2.new(0.5, -17, 0, 30), T.Card, function()
        Log.lines = {}
        Log.onChange()
    end)
end
local logPending = false
Log.onChange = function()
    if curName ~= "Config" or logPending then return end
    logPending = true
    task.delay(0.15, function()
        logPending = false
        local from = math.max(1, #Log.lines - 80)
        logLbl.Text = table.concat(Log.lines, "\n", from, #Log.lines)
        logScroll.CanvasPosition = Vector2.new(0, 100000)
    end)
end
tabHooks["Config"] = function()
    SetInfo(#Log.lines .. " linhas no registro")
    logLbl.Text = table.concat(Log.lines, "\n", math.max(1, #Log.lines - 80), #Log.lines)
    logScroll.CanvasPosition = Vector2.new(0, 100000)
end

Section("Dados")
BtnRow("Centralizar a janela", T.Card, function()
    Shell.Position = UDim2.fromScale(0.5, 0.5)
    Persist.Set("cfg:pos", nil)
    Toast("janela centralizada", true)
end, 40)
BtnRow("Apagar configurações salvas", T.Bad, function()
    Persist.Data = {}
    Persist.Dirty = true
    Persist.Flush()
    Toast("configurações apagadas (rode o script de novo)", true)
end, 40)
Section("Sobre")
do
    local row = Row(72)
    local about = Label(row, "Silk Core v2.0  ·  avatar, partes do corpo, catálogo e efeitos\nexecutor: " .. execName .. "   ·   place " .. tostring(game.PlaceId),
        11, T.Sub, F.Mono, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -32, 1, 0))
    about.TextWrapped = true
end
end

Persist.On = false -- a partir daqui (aba Timebomb) nada e salvo/restaurado

-- TIMEBOMB TAB
CurTab = Tab("Timebomb", 278, true)

local function Header(text)
    local f = New("Frame", {Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = nextOrder()}, CurTab)
    local dot = New("Frame", {
        Size = UDim2.fromOffset(4, 12), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 2, 0.5, 0),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, f)
    Round(dot, 2)
    Grad(dot, 90)
    local l = Label(f, string.upper(text), 10, T.Sub, Enum.Font.BuilderSansExtraBold, nil, UDim2.fromOffset(14, 0), UDim2.new(1, -18, 1, 0))
    New("UIGradient", {Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(132, 140, 160)), Rotation = 0}, l)
end

do
    local row = Row(40)
    Label(row, "BOMB HOLDER", 11, T.Sub, Enum.Font.BuilderSansBold)
    local st = Label(row, "enable an ESP to track", 12, T.Text, Enum.Font.BuilderSansBold, Enum.TextXAlignment.Right,
        UDim2.new(0.35, 0, 0, 0), UDim2.new(0.65, -14, 1, 0))
    TB.OnStatus = function(text, hot)
        st.Text = text
        st.TextColor3 = hot and T.Bad or T.Text
    end
end

Header("MOVEMENT")
Toggle("Stealth speed boost", false, function(v)
    TB.Speed.Enabled = v
    TB.RefreshMove()
    Toast(v and "Stealth speed on" or "Stealth speed off", v)
end)
Slider("Boost over current speed", 0, 35, TB.Speed.Boost * 100, "+%.0f%%", function(v) TB.Speed.Boost = v / 100 end)
Note("Adds a small drifting extra on top of whatever speed the game gives you (it follows the bomb's faster speed too). Start at 8-12%. I can't see the server checks, so keep it low until we read the replication code.", 62)
Toggle("Instant turn (no turn delay)", false, function(v)
    TB.Turn = v
    TB.RefreshMove()
    Toast(v and "Instant turn on" or "Instant turn off", v)
end)
Toggle("Face camera always", false, function(v)
    TB.FaceCam = v
    TB.RefreshMove()
    Toast(v and "Face camera on" or "Face camera off", v)
end)
Toggle("Instant stop (no slide)", false, function(v)
    TB.Stop = v
    TB.RefreshMove()
    Toast(v and "Instant stop on" or "Instant stop off", v)
end)

Header("CAMERA")
Toggle("Faster camera turn", false, function(v)
    TB.Sens.Enabled = v
    TB.ApplySens()
    Toast(v and "Camera sensitivity up" or "Camera sensitivity restored", v)
end)
Slider("Sensitivity multiplier", 0.5, 3, TB.Sens.Mult, "%.1fx", function(v)
    TB.Sens.Mult = v
    TB.ApplySens()
end)
Toggle("FOV changer", false, function(v)
    TB.SetFov(v)
    Toast(v and "FOV override on" or "FOV restored", v)
end)
Slider("Field of view", 60, 120, TB.Fov.Value, "%.0f", function(v) TB.Fov.Value = math.floor(v + 0.5) end)

Header("VISUALS + AIM")
Toggle("Bomb holder ESP", false, function(v)
    TB.ESP.Holder = v
    TB.RefreshESP()
end)
Toggle("Player ESP (all)", false, function(v)
    TB.ESP.All = v
    TB.RefreshESP()
end)
Toggle("Aimlock: bomb holder only", false, function(v)
    TB.HolderOnly = v
    Toast(v and "Aimlock picks only the bomb holder" or "Aimlock picks anyone", v)
end)
Note("Set the aimlock itself up in the Aimlock tab (R6 targets are handled: 'Torso' = Torso part).", 40)

Header("DUMPS")
local function runDump(fn, label)
    task.spawn(function()
        local ok, copied, n, file, err = pcall(fn)
        if not ok then Toast(label .. " failed - see console", false)
        return end
        if err then Toast(tostring(err), false)
        return end
        Toast(string.format("%s %s (%s)", label, copied and "copied" or "printed (F9)", tostring(n or 0)), true)
        if file then print("[Silkcore] saved to workspace/" .. file) end
    end)
end
Action("DUMP GAME (FULL)", T.Accent, function() runDump(function() return Morph.DumpGame("full") end, "Dump") end)
Action("DUMP REMOTES + SCRIPTS (SHORT)", T.Card, function() runDump(function() return Morph.DumpGame("net") end, "Net dump") end)
Action("DUMP SOURCE (DECOMPILE GAME LOGIC)", T.Card, function() runDump(Morph.DumpSource, "Source") end)
Action("DUMP KILL EFFECTS (OWNED + ITEM DATA)", T.Card, function() runDump(Morph.DumpEffects, "Effects dump") end)
Note("SOURCE decompiles the client scripts that handle the bomb, explosions, arenas and character replication into SilkcoreTimebombSource.txt (also copied). Run it during a round, upload the file here, and I tune speed limits and build hit/bomb features against the real code.", 74)


--------------------------------------------------------------------------------
-- LOADER: cada etapa faz trabalho de verdade (rede, engine, arquivos). A barra so anda
-- quando a etapa termina, o tempo de cada uma e medido e erro nao some em silencio.
--------------------------------------------------------------------------------
local runLoader
do
local function runStep(fn, timeout)
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(fn)
        done = true
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < timeout do
        task.wait(0.05)
    end
    if not done then return false, "tempo esgotado" end
    return ok, res
end

function runLoader(onDone)
    local LG = New("ScreenGui", {
        Name = "SilkcoreLoader", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 50,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, guiParent)
    local shade = Color3.fromRGB(8, 6, 9)
    local topHalf = New("Frame", {Size = UDim2.fromScale(1, 0.5), BackgroundColor3 = shade, BorderSizePixel = 0, ZIndex = 1}, LG)
    local botHalf = New("Frame", {
        Size = UDim2.fromScale(1, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = shade, BorderSizePixel = 0, ZIndex = 1,
    }, LG)
    local content = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2}, LG)

    local motes = {}
    for i = 1, 36 do
        local d = New("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(math.random(2, 3), math.random(2, 3)),
            Position = UDim2.fromScale(math.random(), math.random()), BorderSizePixel = 0, ZIndex = 2,
            BackgroundColor3 = (i % 3 == 0) and T.Accent2 or T.Accent, BackgroundTransparency = 0.6 + math.random() * 0.3,
        }, content)
        motes[i] = {f = d, sp = 0.015 + math.random() * 0.04}
    end

    local col = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(460, 500),
        BackgroundTransparency = 1, ZIndex = 3,
    }, content)
    local logo = CoreLogo(col, UDim2.new(0.5, -95, 0, 0), UDim2.fromOffset(190, 190), true)
    logo.always = true
    local word = GlitchText(col, "SILK CORE", 28, UDim2.fromOffset(0, 188), UDim2.new(1, 0, 0, 36), Enum.TextXAlignment.Center)
    word.Intro(1.1)
    local tag = Label(col, "inicializando módulos", 10, T.Faint, F.Mono, Enum.TextXAlignment.Center,
        UDim2.fromOffset(0, 230), UDim2.new(1, 0, 0, 14))
    local bar = New("Frame", {
        Size = UDim2.fromOffset(440, 4), Position = UDim2.fromOffset(10, 258), BackgroundColor3 = T.Card3, BorderSizePixel = 0,
    }, col)
    Round(bar, 2)
    local fill = New("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = T.Accent, BorderSizePixel = 0}, bar)
    Round(fill, 2)
    New("UIGradient", {Color = ColorSequence.new(T.Accent, T.Accent2)}, fill)
    local pct = Label(col, "0%", 11, T.Text, F.Mono, Enum.TextXAlignment.Right, UDim2.fromOffset(10, 266), UDim2.fromOffset(440, 16))

    local function addId(ids, seen, v)
        local n = tonumber(v)
        if n and n > 0 and not seen[n] then
            seen[n] = true
            ids[#ids + 1] = "rbxassetid://" .. tostring(n)
        end
    end
    local steps = {
        {name = "ambiente", timeout = 8, fn = function()
            local want = {"writefile", "readfile", "isfile", "setclipboard", "gethui", "getgenv", "decompile"}
            local have = 0
            local genv = (getgenv and getgenv()) or {}
            for _, n in ipairs(want) do
                local ok, v = pcall(function() return getfenv()[n] or genv[n] end)
                if ok and v then have = have + 1 end
            end
            return string.format("%s · %d/%d funções", execName, have, #want)
        end},
        {name = "perfil", timeout = 12, fn = function()
            local url = Morph.Thumb(LocalPlayer.UserId)
            if type(url) ~= "string" or url == "" then error("thumbnail vazia") end
            return "thumbnail ok"
        end},
        {name = "avatar", timeout = 12, fn = function()
            Morph.SaveOriginal()
            local hum = Morph.Hum()
            if not hum then error("humanoid ausente") end
            return (tostring(hum.RigType):gsub("Enum.HumanoidRigType.", ""))
        end},
        {name = "rig base", timeout = 20, fn = function()
            DefaultRig = DefaultRig or makeRig(Instance.new("HumanoidDescription"))
            if not DefaultRig then return "indisponível (usa o asset direto)" end
            return "ok"
        end},
        {name = "assets", timeout = 25, fn = function()
            local ids, seen = {}, {}
            for _, id in ipairs(Persist.Get("catalog:ids", {}) or {}) do addId(ids, seen, id) end
            for _, w in ipairs(WARD) do addId(ids, seen, State.Wardrobe[w.field]) end
            addId(ids, seen, State.KorbloxIds.Right)
            addId(ids, seen, State.KorbloxIds.Left)
            if #ids == 0 then return "nada salvo" end
            game:GetService("ContentProvider"):PreloadAsync(ids)
            return #ids .. " assets"
        end},
        {name = "partes", timeout = 40, fn = function()
            return Ward.RestoreAll() .. " peça(s)"
        end},
        {name = "itens", timeout = 40, fn = function()
            return Cat.RestoreAll() .. " item(ns)"
        end},
        {name = "cores", timeout = 10, fn = function()
            return Colors.Reapply() .. " grupo(s)"
        end},
        {name = "visual", timeout = 10, fn = function()
            Env.Apply()
            return Env.Loaded() and "filtros ligados" or "padrão do jogo"
        end},
        {name = "efeitos", timeout = 10, fn = function()
            return FX.Apply() .. " emissor(es)"
        end},
        {name = "preview", timeout = 10, fn = function()
            for _, p in ipairs(Previews) do p.Refresh() end
            return #Previews .. " preview(s)"
        end},
    }
    local total = #steps
    local rows = {}
    for i, st in ipairs(steps) do
        New("Frame", {
            Size = UDim2.fromOffset(1, 8), Position = UDim2.new(i / total, 0, 0, -2), BackgroundColor3 = T.Stroke2,
            BorderSizePixel = 0, ZIndex = 4,
        }, bar)
        rows[i] = {
            l = Label(col, "·  " .. st.name, 11, T.Faint, F.Mono, nil, UDim2.fromOffset(10, 292 + (i - 1) * 16), UDim2.fromOffset(340, 16)),
            r = Label(col, "", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.fromOffset(350, 292 + (i - 1) * 16), UDim2.fromOffset(100, 16)),
        }
    end
    local corners = {
        {"SILK CORE // BOOT", UDim2.fromOffset(20, 16), Enum.TextXAlignment.Left},
        {"v2.0", UDim2.new(1, -220, 0, 16), Enum.TextXAlignment.Right},
        {"executor: " .. execName, UDim2.new(0, 20, 1, -30), Enum.TextXAlignment.Left},
        {"place " .. tostring(game.PlaceId), UDim2.new(1, -220, 1, -30), Enum.TextXAlignment.Right},
    }
    for _, c in ipairs(corners) do
        Label(content, c[1], 10, T.Faint, F.Mono, c[3], c[2], UDim2.fromOffset(200, 14))
    end
    local scan = New("Frame", {
        Size = UDim2.new(1, 0, 0, 2), Position = UDim2.fromScale(0, 0), BackgroundColor3 = T.Accent,
        BackgroundTransparency = 0.82, BorderSizePixel = 0, ZIndex = 5,
    }, content)

    local hb
    hb = RunService.Heartbeat:Connect(function(dt)
        if not LG.Parent then
            hb:Disconnect()
            return
        end
        for _, m in ipairs(motes) do
            local p = m.f.Position
            local y = p.Y.Scale - dt * m.sp
            if y < -0.03 then y = 1.03 end
            m.f.Position = UDim2.new(p.X.Scale, 0, y, 0)
        end
        scan.Position = UDim2.fromScale(0, (os.clock() * 0.35) % 1)
        pct.Text = math.floor(fill.Size.X.Scale * 100 + 0.5) .. "%"
    end)

    task.spawn(function()
        local failed = {}
        for i, st in ipairs(steps) do
            rows[i].l.Text = "›  " .. st.name
            rows[i].l.TextColor3 = T.Text
            local s0 = os.clock()
            local ok, res = runStep(st.fn, st.timeout)
            local ms = math.floor((os.clock() - s0) * 1000)
            if ok then
                rows[i].l.Text = string.format("✓  %-9s %s", st.name, tostring(res))
                rows[i].l.TextColor3 = T.Good
            else
                failed[#failed + 1] = st.name .. ": " .. tostring(res)
                rows[i].l.Text = string.format("✕  %-9s %s", st.name, tostring(res))
                rows[i].l.TextColor3 = T.Bad
                Log.add("ERRO", "loader " .. st.name .. ": " .. tostring(res))
            end
            rows[i].r.Text = ms .. " ms"
            TweenEx(fill, 0.35, Enum.EasingStyle.Quint, {Size = UDim2.fromScale(i / total, 1)})
        end
        tag.Text = (#failed == 0) and "pronto" or ("pronto com " .. #failed .. " falha(s)")
        task.wait(0.45)
        word.Burst(0.35)
        task.wait(0.4)
        logo.vp.Visible = false
        for _, d in ipairs(content:GetDescendants()) do
            if d:IsA("TextLabel") then
                Tween(d, 0.3, {TextTransparency = 1})
            elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
                Tween(d, 0.3, {BackgroundTransparency = 1})
            end
        end
        task.wait(0.3)
        if onDone then onDone(failed) end
        TweenEx(topHalf, 0.65, Enum.EasingStyle.Quint, {Position = UDim2.fromScale(0, -0.5)})
        TweenEx(botHalf, 0.65, Enum.EasingStyle.Quint, {Position = UDim2.fromScale(0, 1)})
        task.wait(0.75)
        LG:Destroy()
    end)
end

end

--------------------------------------------------------------------------------
-- PALETA DE COMANDOS (Ctrl esquerdo + K, ou /): digite o que quer fazer
--------------------------------------------------------------------------------
local Palette = {}
do
    local isOpenP, sel, shown = false, 1, {}
    local MAXR = 8
    local overlay = New("Frame", {
        Name = "Palette", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1,
        BorderSizePixel = 0, ZIndex = 40, Visible = false, Active = true,
    }, Main)
    local box = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 70), Size = UDim2.fromOffset(540, 64),
        BackgroundColor3 = T.Card, BorderSizePixel = 0, ZIndex = 41, ClipsDescendants = true,
    }, overlay)
    Round(box, 10)
    bindAcc(Stroke(box, T.Accent, 1), "Color")
    local tb = New("TextBox", {
        Size = UDim2.new(1, -96, 0, 44), Position = UDim2.fromOffset(20, 6), BackgroundTransparency = 1,
        PlaceholderText = "digite um comando...  (aba, tema, look, efeito)", PlaceholderColor3 = T.Faint, Text = "",
        ClearTextOnFocus = false, TextColor3 = T.Text, Font = F.Mono, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 42,
    }, box)
    local escChip = Label(box, "ESC", 10, T.Faint, F.Mono, Enum.TextXAlignment.Center, UDim2.new(1, -62, 0, 17), UDim2.fromOffset(46, 22))
    escChip.ZIndex = 42
    escChip.BackgroundTransparency = 0
    escChip.BackgroundColor3 = T.Card3
    Round(escChip, 5)
    New("Frame", {
        Size = UDim2.new(1, -24, 0, 1), Position = UDim2.fromOffset(12, 55), BackgroundColor3 = T.Stroke, BorderSizePixel = 0, ZIndex = 42,
    }, box)
    local rows = {}
    for i = 1, MAXR do
        local r = New("TextButton", {
            Text = "", AutoButtonColor = false, Size = UDim2.new(1, -16, 0, 32), Position = UDim2.fromOffset(8, 62 + (i - 1) * 34),
            BackgroundColor3 = T.Card3, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 43, Visible = false,
        }, box)
        Round(r, 6)
        local l1 = Label(r, "", 13, T.Text, F.Body, nil, UDim2.fromOffset(12, 0), UDim2.new(1, -130, 1, 0))
        l1.ZIndex = 44
        local l2 = Label(r, "", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.new(1, -110, 0, 0), UDim2.fromOffset(98, 32))
        l2.ZIndex = 44
        rows[i] = {btn = r, l1 = l1, l2 = l2}
    end

    local function commands()
        local list = {}
        local function add(label, hint, fn)
            list[#list + 1] = {label = label, hint = hint, fn = fn}
        end
        local tabsList = {}
        for id, e in pairs(NAVB) do tabsList[#tabsList + 1] = {id = id, y = e.y} end
        table.sort(tabsList, function(a, b) return a.y < b.y end)
        for _, t in ipairs(tabsList) do
            add("Ir para " .. t.id, "aba", function() ShowTab(t.id) end)
        end
        for _, th in ipairs(THEMES) do
            if th.id ~= "custom" then
                add("Tema " .. th.name, "tema", function()
                    SetTheme(th.id)
                    Persist.Set("cfg:theme", th.id)
                    Toast("tema " .. th.name, true)
                end)
            end
        end
        for _, it in ipairs(Looks.Names()) do
            add("Aplicar look " .. it[1] .. " · " .. it[2], "look", function() Looks.ApplyIndex(it[1]) end)
        end
        add("Próximo look salvo", "look", function() Looks.Next() end)
        add("Korblox Deathwalker na cabeça", "partes", function()
            local ok, info = Ward.Apply("Head", 16580493236)
            Toast(ok and ("cabeça aplicada · " .. tostring(info)) or tostring(info), ok)
        end)
        add("Limpar todas as partes do corpo", "partes", function() Ward.ClearAll()
        Toast("partes do corpo restauradas", true) end)
        add("Remover todos os itens do catálogo", "catálogo", function() Cat.ClearAll()
        Toast("itens removidos", true) end)
        add("Resetar todas as cores do corpo", "cores", function() Colors.ResetAll()
        Toast("cores restauradas", true) end)
        add("Desligar todos os efeitos", "efeitos", function()
            FX.Load({on = {}, part = FX.Part, mult = FX.Mult, mode = FX.Mode})
            Toast("efeitos desligados", true)
        end)
        add("Alternar headless", "corpo", function()
            local s = not State.IsHeadless
            Morph.SetHeadless(s)
            Toast(s and "headless ligado" or "headless desligado", true)
        end)
        add("Restaurar avatar original", "avatar", function() Morph.Reset(Toast) end)
        add("Restaurar o ambiente do jogo", "ambiente", function() Env.Disable()
        Toast("ambiente do jogo restaurado", true) end)
        add("Modo foto (esconder tudo por 8s)", "ambiente", function() Env.Photo() end)
        add("Copiar o registro de eventos", "sistema", function()
            if setclipboard then
                pcall(setclipboard, table.concat(Log.lines, "\n"))
                Toast("registro copiado", true)
            else
                Toast("seu executor não tem setclipboard", false)
            end
        end)
        add("Fechar o menu", "sistema", function() SetOpen(false) end)
        return list
    end
    local all = {}
    local function score(q, text)
        if q == "" then return 1 end
        local t, qi, sc, last = text:lower(), 1, 0, 0
        local tl = string.len(t)
        for ti = 1, tl do
            if t:sub(ti, ti) == q:sub(qi, qi) then
                sc = sc + ((ti == last + 1) and 3 or 1) + ((ti == 1) and 2 or 0)
                last = ti
                qi = qi + 1
                if qi > #q then return sc end
            end
        end
        return nil
    end
    local function paint()
        for i, r in ipairs(rows) do
            local item = shown[i]
            r.btn.Visible = item ~= nil
            if item then
                r.l1.Text = item.label
                r.l2.Text = item.hint
                r.l1.TextColor3 = (i == sel) and T.Text or T.Sub
                Tween(r.btn, 0.12, {BackgroundTransparency = (i == sel) and 0 or 1})
            end
        end
    end
    local function refresh()
        local q = tb.Text:lower()
        local scored = {}
        for _, c in ipairs(all) do
            local sc = score(q, c.label)
            if sc then scored[#scored + 1] = {c = c, sc = sc} end
        end
        table.sort(scored, function(a, b)
            if a.sc ~= b.sc then return a.sc > b.sc end
            return a.c.label < b.c.label
        end)
        shown = {}
        for i = 1, math.min(MAXR, #scored) do shown[i] = scored[i].c end
        sel = 1
        paint()
        Tween(box, 0.18, {Size = UDim2.fromOffset(540, 62 + math.max(1, #shown) * 34 + 10)})
    end
    local function run(i)
        local item = shown[i]
        Palette.Close()
        if item then task.spawn(Safe(item.fn, "comando " .. item.label)) end
    end
    function Palette.IsOpen() return isOpenP end
    function Palette.Open()
        if isOpenP then return end
        isOpenP = true
        all = commands()
        overlay.Visible = true
        overlay.BackgroundTransparency = 1
        Tween(overlay, 0.2, {BackgroundTransparency = 0.45})
        box.Position = UDim2.new(0.5, 0, 0, 40)
        TweenEx(box, 0.38, Enum.EasingStyle.Back, {Position = UDim2.new(0.5, 0, 0, 70)})
        tb.Text = ""
        refresh()
        task.defer(function() tb:CaptureFocus() end)
    end
    function Palette.Close()
        if not isOpenP then return end
        isOpenP = false
        pcall(function() tb:ReleaseFocus() end)
        Tween(overlay, 0.15, {BackgroundTransparency = 1})
        task.delay(0.17, function()
            if not isOpenP then overlay.Visible = false end
        end)
    end
    function Palette.Move(d)
        if #shown == 0 then return end
        sel = ((sel - 1 + d) % #shown) + 1
        paint()
    end
    tb:GetPropertyChangedSignal("Text"):Connect(function()
        if isOpenP then refresh() end
    end)
    tb.FocusLost:Connect(function(enter)
        if not isOpenP then return end
        if enter then run(sel) else Palette.Close() end
    end)
    for i, r in ipairs(rows) do
        r.btn.MouseEnter:Connect(function()
            sel = i
            paint()
        end)
        r.btn.MouseButton1Click:Connect(Safe(function() run(i) end, "paleta"))
    end
    LAY.OpenPalette = Palette.Open
end


--------------------------------------------------------------------------------
-- HACKS (universal)
--------------------------------------------------------------------------------
local HackState = {
    speed     = false,
    jump      = false,
    fly       = false,
    noclip    = false,
    iJump     = false,
    godMode   = false,
    antiVoid  = false,
    antiAfk   = false,
    fullBright= false,
    noFog     = false,
    remSpy    = false,
    spyConns  = {},
    flyConn   = nil,
    speedVal  = 40,
    jumpVal   = 80,
    flySpeed  = 50,
    spawnCF   = nil,
}
local hackConns = {}
local function trackHK(c) hackConns[#hackConns+1]=c; return c end

local function hkChar() return LocalPlayer.Character end
local function hkHum()  local c=hkChar(); return c and c:FindFirstChildOfClass("Humanoid") end
local function hkRoot() local c=hkChar(); return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart) end

local function applySpeed(v)
    local h=hkHum()
    if h then h.WalkSpeed = HackState.speed and (v or HackState.speedVal) or 16 end
end
local function applyJump(v)
    local h=hkHum()
    if not h then return end
    if h.RigType == Enum.HumanoidRigType.R15 then
        h.JumpHeight = HackState.jump and (v or HackState.jumpVal) or 7.2
    else
        h.JumpPower  = HackState.jump and (v or HackState.jumpVal) or 50
    end
end

-- fly engine
local function startFly()
    local bg, bv
    local function setup()
        local r = hkRoot()
        if not r then return end
        r.Velocity = Vector3.zero
        bg = Instance.new("BodyGyro");  bg.MaxTorque=Vector3.new(4e5,4e5,4e5); bg.P=2e4; bg.Parent=r
        bv = Instance.new("BodyVelocity"); bv.MaxForce=Vector3.new(4e5,4e5,4e5); bv.Velocity=Vector3.zero; bv.Parent=r
        local h=hkHum(); if h then h.PlatformStand=true end
    end
    setup()
    HackState.flyConn = RunService.Heartbeat:Connect(function()
        if not HackState.fly then
            if bg and bg.Parent then bg:Destroy() end
            if bv and bv.Parent then bv:Destroy() end
            local h=hkHum(); if h then h.PlatformStand=false end
            HackState.flyConn:Disconnect(); HackState.flyConn=nil
            return
        end
        local r=hkRoot(); if not r or not bg or not bg.Parent then return end
        local cam=workspace.CurrentCamera
        local dir=Vector3.zero
        local uis=UserInputService
        local spd=HackState.flySpeed
        if uis:IsKeyDown(Enum.KeyCode.W) then dir=dir+cam.CFrame.LookVector end
        if uis:IsKeyDown(Enum.KeyCode.S) then dir=dir-cam.CFrame.LookVector end
        if uis:IsKeyDown(Enum.KeyCode.A) then dir=dir-cam.CFrame.RightVector end
        if uis:IsKeyDown(Enum.KeyCode.D) then dir=dir+cam.CFrame.RightVector end
        if uis:IsKeyDown(Enum.KeyCode.Space) then dir=dir+Vector3.new(0,1,0) end
        if uis:IsKeyDown(Enum.KeyCode.LeftShift) then dir=dir-Vector3.new(0,1,0) end
        if dir.Magnitude>0 then dir=dir.Unit end
        bg.CFrame=cam.CFrame
        bv.Velocity=dir*spd
    end)
end
local function stopFly()
    if HackState.flyConn then HackState.flyConn:Disconnect(); HackState.flyConn=nil end
    local r=hkRoot()
    if r then
        for _, c in ipairs(r:GetChildren()) do
            if c:IsA("BodyGyro") or c:IsA("BodyVelocity") then c:Destroy() end
        end
    end
    local h=hkHum(); if h then h.PlatformStand=false end
end

-- noclip engine
local noclipConn
local function startNoclip()
    noclipConn = RunService.Stepped:Connect(function()
        if not HackState.noclip then noclipConn:Disconnect(); noclipConn=nil; return end
        local c=hkChar(); if not c then return end
        for _,p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide=false end
        end
    end)
end

-- anti-void
trackHK(RunService.Heartbeat:Connect(function()
    if not HackState.antiVoid then return end
    local r=hkRoot()
    if r and r.Position.Y < -150 then
        if HackState.spawnCF then
            r.CFrame=HackState.spawnCF
        else
            r.CFrame=CFrame.new(0,10,0)
        end
    end
end))

-- god mode
trackHK(RunService.Heartbeat:Connect(function()
    if not HackState.godMode then return end
    local h=hkHum()
    if h and h.Health < h.MaxHealth then h.Health=h.MaxHealth end
end))

-- infinite jump
local ijConn
local function startIJ()
    local h=hkHum(); if not h then return end
    ijConn = h.StateChanged:Connect(function(_, new)
        if not HackState.iJump then if ijConn then ijConn:Disconnect(); ijConn=nil end; return end
        if new==Enum.HumanoidStateType.Jumping or new==Enum.HumanoidStateType.Freefall then
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
                h:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end
    end)
end

-- anti-afk
local afkConn
local function startAfk()
    afkConn = RunService.Heartbeat:Connect(function()
        if not HackState.antiAfk then afkConn:Disconnect(); afkConn=nil; return end
    end)
    pcall(function()
        local veh = game:GetService("VirtualUser")
        veh:CaptureController()
        veh:ClickButton2(Vector2.new())
    end)
    task.spawn(function()
        while HackState.antiAfk do
            pcall(function()
                local veh=game:GetService("VirtualUser")
                veh:Button2Down(Vector2.new(0,0),workspace.CurrentCamera.CFrame)
                task.wait(0.1)
                veh:Button2Up(Vector2.new(0,0),workspace.CurrentCamera.CFrame)
            end)
            task.wait(20)
        end
    end)
end

-- fullbright
local function applyFB(v)
    local L=game:GetService("Lighting")
    if v then
        L.Brightness=10; L.ClockTime=14; L.FogEnd=1e6
        L.GlobalShadows=false; L.Ambient=Color3.new(1,1,1); L.OutdoorAmbient=Color3.new(1,1,1)
    else
        L.Brightness=1; L.GlobalShadows=true
    end
end

-- no fog
local function applyNoFog(v)
    local L=game:GetService("Lighting")
    L.FogEnd = v and 1e6 or 100000
    L.FogStart= v and 0 or 0
end

-- remote spy
local function startRemoteSpy()
    for _,c in ipairs(HackState.spyConns) do c:Disconnect() end
    HackState.spyConns={}
    local function hookRemote(r)
        if r:IsA("RemoteEvent") then
            local c=r.OnClientEvent:Connect(function(...)
                if not HackState.remSpy then return end
                local args={}
                for _,v in ipairs({...}) do args[#args+1]=tostring(v) end
                print("[SC-SPY] "..r:GetFullName().."  "..table.concat(args," | "))
            end)
            HackState.spyConns[#HackState.spyConns+1]=c
        end
    end
    for _,d in ipairs(game:GetDescendants()) do hookRemote(d) end
    HackState.spyConns[#HackState.spyConns+1]=game.DescendantAdded:Connect(function(d) hookRemote(d) end)
end

-- respawn event: re-apply hacks
trackHK(LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    local h=char:FindFirstChildOfClass("Humanoid")
    if HackState.spawnCF==nil and char.PrimaryPart then
        HackState.spawnCF=char.PrimaryPart.CFrame
    end
    if HackState.speed then applySpeed() end
    if HackState.jump  then applyJump()  end
    if HackState.fly   then task.spawn(startFly) end
    if HackState.noclip then task.spawn(startNoclip) end
    if HackState.iJump then task.spawn(startIJ) end
    if HackState.godMode then end -- heartbeat handles it
end))

do
CurTab = Tab("Hacks", 0, true)
Persist.Scope = "hacks"

Section("Movimento")
Slider("Velocidade (WalkSpeed)", 16, 500, 40, "%d", function(v)
    HackState.speedVal=v
    if HackState.speed then applySpeed(v) end
end, "hk_spd")
Toggle("Speed Hack", false, function(v)
    HackState.speed=v
    applySpeed(HackState.speedVal)
    Toast("speed hack "..(v and "ligado ("..HackState.speedVal..")" or "desligado"), v)
end, "hk_speed_on")
Slider("Jump Power", 7, 300, 80, "%d", function(v)
    HackState.jumpVal=v
    if HackState.jump then applyJump(v) end
end, "hk_jmp")
Toggle("Jump Hack", false, function(v)
    HackState.jump=v
    applyJump(HackState.jumpVal)
    Toast("jump hack "..(v and "ligado" or "desligado"), v)
end, "hk_jump_on")
Toggle("Infinite Jump", false, function(v)
    HackState.iJump=v
    if v then task.spawn(startIJ) end
    Toast("infinite jump "..(v and "ligado" or "desligado"), v)
end, "hk_ijump")

Section("Fly / Noclip")
Slider("Fly Speed", 10, 300, 50, "%d", function(v)
    HackState.flySpeed=v
end, "hk_flyspd")
Toggle("Voar (WASD + Space/Shift)", false, function(v)
    HackState.fly=v
    if v then task.spawn(startFly) else stopFly() end
    Toast("fly "..(v and "ligado" or "desligado"), v)
end, "hk_fly")
Toggle("Noclip (sem colisão)", false, function(v)
    HackState.noclip=v
    if v then task.spawn(startNoclip) end
    Toast("noclip "..(v and "ligado" or "desligado"), v)
end, "hk_noclip")

Section("Sobrevivência")
Toggle("God Mode (HP sempre cheio)", false, function(v)
    HackState.godMode=v
    Toast("god mode "..(v and "ligado" or "desligado"), v)
end, "hk_god")
Toggle("Anti-Void (TP ao cair)", false, function(v)
    HackState.antiVoid=v
    if v then
        local r=hkRoot()
        if r then HackState.spawnCF=r.CFrame end
    end
    Toast("anti-void "..(v and "ligado" or "desligado"), v)
end, "hk_avoid")
do
    local row=Row(50)
    Label(row,"Salvar ponto de retorno (anti-void)",12,T.Text,F.Bold,nil,UDim2.fromOffset(16,0),UDim2.new(1,-126,1,0))
    Button(row,"SALVAR",UDim2.new(1,-104,0.5,-15),UDim2.fromOffset(88,30),T.Card,function()
        local r=hkRoot()
        if r then HackState.spawnCF=r.CFrame; Toast("ponto salvo", true)
        else Toast("sem personagem", false) end
    end)
end

Section("Visual")
Toggle("Full Bright", false, function(v)
    HackState.fullBright=v
    applyFB(v)
    Toast("full bright "..(v and "ligado" or "desligado"), v)
end, "hk_fb")
Toggle("Sem Névoa", false, function(v)
    HackState.noFog=v
    applyNoFog(v)
    Toast("sem névoa "..(v and "ligado" or "desligado"), v)
end, "hk_nofog")

Section("Utilitários")
Toggle("Anti-AFK", false, function(v)
    HackState.antiAfk=v
    if v then task.spawn(startAfk) end
    Toast("anti-afk "..(v and "ligado" or "desligado"), v)
end, "hk_afk")
Toggle("Remote Spy (output)", false, function(v)
    HackState.remSpy=v
    if v then task.spawn(startRemoteSpy) end
    Toast("remote spy "..(v and "ligado e printando no output" or "desligado"), v)
end, "hk_rspy")

do
    -- TP to player
    local row=Row(50)
    Label(row,"Teleportar até jogador",12,T.Text,F.Bold,nil,UDim2.fromOffset(16,0),UDim2.new(0.55,0,1,0))
    local pField=Field(row,UDim2.new(0.56,0,0.5,-15),UDim2.new(0.26,0,0,30),"nome...")
    Button(row,"IR",UDim2.new(0.84,0,0.5,-15),UDim2.fromOffset(52,30),T.Accent,function()
        local target=Players:FindFirstChild(pField.Text)
        if not target or not target.Character then Toast("jogador não encontrado",false); return end
        local r=hkRoot(); local tr=target.Character:FindFirstChild("HumanoidRootPart")
        if r and tr then r.CFrame=tr.CFrame+Vector3.new(0,3,0); Toast("tp → "..target.Name,true)
        else Toast("sem root part",false) end
    end)
end
do
    -- chat send
    local row=Row(50)
    Label(row,"Enviar mensagem no chat",12,T.Text,F.Bold,nil,UDim2.fromOffset(16,0),UDim2.new(0.44,0,1,0))
    local cField=Field(row,UDim2.new(0.45,0,0.5,-15),UDim2.new(0.38,0,0,30),"mensagem...")
    Button(row,"ENVIAR",UDim2.new(0.85,0,0.5,-15),UDim2.fromOffset(56,30),T.Card,function()
        local msg=cField.Text
        if #msg==0 then return end
        local ok=pcall(function()
            game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
                :FindFirstChild("SayMessageRequest"):FireServer(msg,"All")
        end)
        if not ok then
            pcall(function() game:GetService("Chat"):Chat(hkRoot(),msg) end)
        end
        Toast("mensagem enviada",true)
    end)
end

Section("SilkCore Commands")
Note("Carrega o motor de comandos completo (base Infinite Yield) rebatizado com a marca SilkCore — título da janela, créditos e textos trocados no momento do carregamento. O chat de comandos aparece no chat do jogo.", 52)

-- troca literal e segura: escapa os caracteres especiais de pattern na busca,
-- escapa '%' na troca. Só mexe em texto visível (título/créditos/hint), nunca
-- em nomes de variável, pastas de asset ou lógica interna.
local function bhPlainGsub(src, find, repl)
    local escFind = find:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    local escRepl = repl:gsub("%%", "%%%%")
    return (src:gsub(escFind, escRepl))
end

BtnRow("CARREGAR SILKCORE COMMANDS", T.Accent, function()
    Toast("carregando SilkCore Commands...", true)
    task.spawn(function()
        local ok, err = pcall(function()
            local src = game:HttpGet("https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source")
            local rebrand = {
                {"Infinite Yield is already running!", "SilkCore Commands is already running!"},
                {"Infinite Yield FE v", "SilkCore Commands v"},
                {"Edge // Zwolf // Moon // Toon // Peyton // ATP", "SilkCore"},
                {"Download plugins from the IY Discord (discord.gg/78ZuWSq)", "Plugins via arquivos .iy"},
            }
            for _, pair in ipairs(rebrand) do
                src = bhPlainGsub(src, pair[1], pair[2])
            end
            local fn, lerr = loadstring(src)
            if not fn then error(lerr) end
            fn()
        end)
        if ok then
            Toast("✓ SilkCore Commands carregado · use ; no chat", true)
        else
            Toast("falhou: "..(tostring(err):sub(1,60)), false)
            print("[SilkCore] Commands error:", err)
        end
    end)
end)
Note("Após carregar: ';cmds' lista todos os comandos. Ex: ';speed 100' ';fly' ';tp [player]'. Janela abre com título e créditos SilkCore.", 52)

end -- Hacks tab

--------------------------------------------------------------------------------
-- BROOKHAVEN
--------------------------------------------------------------------------------
-- Mesmo motivo do HBG: corpo em função própria pra não consumir os 200
-- registradores do chunk principal.
local function buildBrookhaven()
CurTab = Tab("Brookhaven", 0, true)
Persist.Scope = "bh"

-- helpers para Brookhaven
local BH = {}
local BH_RS  = game:GetService("ReplicatedStorage")
local BH_MPS = game:GetService("MarketplaceService")

local function bhFind(path)
    local cur=game
    for part in path:gmatch("[^%.]+") do
        if not cur then return nil end
        cur=cur:FindFirstChild(part) or (cur.FindFirstChild and cur:FindFirstChild(part,true)) or nil
        if not cur then return nil end
    end
    return cur
end

local function bhFireRemote(path, ...)
    local r=bhFind(path)
    if r and r:IsA("RemoteEvent") then
        local ok,e=pcall(r.FireServer,r,...)
        return ok, e
    elseif r and r:IsA("RemoteFunction") then
        local ok,e=pcall(r.InvokeServer,r,...)
        return ok, e
    end
    return false,"remote não encontrado: "..path
end

-- nomes reais tirados do dump (obfuscação: 1s injetados nos nomes, ex. "1Pas1s" = "Pass")
local BH_RE = {
    Pass   = "RE.1Pas1s",
    Flying = "RE.1Flyin1g",
    Faster = "RE.1Faste1r",
}

-- frames/gates de gamepass confirmados no dump (NoResetGUIHandler.*)
local BH_GATE_NAMES = { GamepassNeeded=true, GamepassUnlock=true, ProductUnlock=true }

-- dump
function BH.Dump()
    local out={}
    local function add(s,...) out[#out+1]=(select("#",...)>0) and string.format(s,...) or s end
    add("== BROOKHAVEN DUMP — SilkCore ==")
    add("Jogo: %s  PlaceId: %s", game.Name, tostring(game.PlaceId))
    add("")

    add("== GAMEPASSES (MarketplaceService) ==")
    local gpFolder = BH_RS:FindFirstChild("GamepassData") or BH_RS:FindFirstChild("Gamepasses") or BH_RS:FindFirstChild("Items")
    if gpFolder then
        for _,v in ipairs(gpFolder:GetDescendants()) do
            if v:IsA("ValueBase") or v:IsA("IntValue") or v:IsA("StringValue") then
                add("  %s = %s [%s]", v:GetFullName(), tostring(v.Value), v.ClassName)
            end
        end
    else
        add("  pasta de gamepasses não encontrada — tentando via player data")
    end
    add("")

    add("== PLAYER DATA (LocalPlayer) ==")
    local ld=LocalPlayer:FindFirstChild("Data") or LocalPlayer:FindFirstChild("PlayerData")
    if ld then
        for _,v in ipairs(ld:GetDescendants()) do
            add("  %s = %s [%s]", v.Name, v:IsA("ValueBase") and tostring(v.Value) or "", v.ClassName)
        end
    else add("  sem objeto Data no player") end
    add("")

    add("== LEADERSTATS ==")
    local ls=LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        for _,v in ipairs(ls:GetChildren()) do
            add("  %s = %s", v.Name, tostring(v:IsA("ValueBase") and v.Value or "?"))
        end
    else add("  sem leaderstats") end
    add("")

    add("== REMOTES (ReplicatedStorage) ==")
    local counted=0
    for _,d in ipairs(BH_RS:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            counted=counted+1
            if counted<=900 then add("  [%s] %s", d.ClassName, d:GetFullName()) end
        end
    end
    if counted>900 then add("  ... +%d mais", counted-900) end
    add("  total de remotas: %d", counted)
    add("")

    add("== GUI DE COMPRA / LOJA ==")
    local pg=LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        local shown=0
        for _,d in ipairs(pg:GetDescendants()) do
            local n=d.Name:lower()
            if n:find("shop") or n:find("store") or n:find("gamepass") or n:find("buy") or n:find("locked") then
                shown=shown+1
                if shown<=80 then add("  %s [%s]", d:GetFullName(), d.ClassName) end
            end
        end
    end

    local txt=table.concat(out,"\n")
    local copied=false
    if setclipboard then copied=pcall(setclipboard,txt) end
    if writefile then pcall(writefile,"SilkcoreBrookhavenDump.txt",txt) end
    print("[SilkCore] BH dump: "..#txt.." chars")
    return txt, copied
end

-- esconde UM gate/lock se o nó bater no padrão confirmado pelo dump
local function bhHideIfGate(inst)
    if (inst:IsA("Frame") or inst:IsA("ImageButton")) and BH_GATE_NAMES[inst.Name] then
        if inst.Visible then inst.Visible=false; return true end
    end
    -- selo de cadeado "Gamepass" dentro de template de item de catálogo (pets etc.) — NÃO mexe
    -- no filtro de catálogo (esse é TextButton, aqui só ImageLabel dentro de *Template.*)
    if inst:IsA("ImageLabel") and inst.Name=="Gamepass" and inst.Parent and inst.Parent.Name:find("Template") then
        if inst.Visible then inst.Visible=false; return true end
    end
    -- banner "precisa de gamepass" no card de detalhe do item
    if inst:IsA("Frame") and inst.Name=="GamepassBanner" then
        if inst.Visible then inst.Visible=false; return true end
    end
    return false
end

-- unlock client-side: alvo é a árvore real do dump (NoResetGUIHandler.GamepassNeeded /
-- GamepassUnlock / ProductUnlock + selos de cadeado nos templates), não heurística genérica.
-- Fica permanente: além de varrer uma vez, prende um watcher em DescendantAdded (preso em
-- conns, limpo no Destroy) pra pegar GUI que o jogo recria depois (troca de menu, respawn).
local bhWatcherOn = false
function BH.ClientUnlock()
    local count=0
    local pg=LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _,d in ipairs(pg:GetDescendants()) do
            if bhHideIfGate(d) then count=count+1 end
        end
    end
    if not bhWatcherOn and pg then
        bhWatcherOn = true
        track(pg.DescendantAdded:Connect(function(inst)
            task.defer(function() pcall(bhHideIfGate, inst) end)
        end))
    end
    return count
end

-- hook permanente: UserOwnsGamePassAsync volta true pro LocalPlayer em qualquer checagem
-- feita do lado do cliente (padrão comum pra liberar UI/cosmético). Não existe sem
-- hookfunction no executor, e não muda nada que o servidor valide por conta própria.
local bhHookInstalled = false
function BH.HookMPS()
    if bhHookInstalled then return true, "já instalado" end
    if not hookfunction then return false, "executor sem hookfunction" end
    local ok, err = pcall(function()
        local old
        old = hookfunction(BH_MPS.UserOwnsGamePassAsync, function(self, plr, passId)
            if plr == LocalPlayer then return true end
            return old(self, plr, passId)
        end)
    end)
    if ok then bhHookInstalled = true end
    return ok, err
end

-- espiona (log-only, sem sobrescrever nada) toda chamada real de UserOwnsGamePassAsync
-- e PromptGamePassPurchase feita pelos SCRIPTS DO JOGO durante a janela. Isso é o jeito
-- de saber de verdade, não chutar: se um passId aparece aqui, a checagem roda no cliente
-- e o hook em BH.HookMPS cobre ela 100%. Se nunca aparece enquanto você abre a loja/item
-- travado, a checagem é só no servidor — e nenhum script de cliente, deste ou de qualquer
-- outro, consegue forjar isso. Não é limite deste build, é o modelo de segurança do Roblox.
function BH.SpyGamepasses(seconds)
    if not hookfunction then return nil, "executor sem hookfunction" end
    local hits = {}
    local function log(name, plr, passId)
        hits[#hits+1] = string.format("[%s] %s(player=%s, passId=%s)",
            os.date("%H:%M:%S"), name, tostring(plr), tostring(passId))
    end
    local oldOwns, oldPrompt
    pcall(function()
        oldOwns = hookfunction(BH_MPS.UserOwnsGamePassAsync, function(self, plr, passId)
            log("UserOwnsGamePassAsync", plr, passId)
            return oldOwns(self, plr, passId)
        end)
    end)
    pcall(function()
        oldPrompt = hookfunction(BH_MPS.PromptGamePassPurchase, function(self, plr, passId)
            log("PromptGamePassPurchase", plr, passId)
            return oldPrompt(self, plr, passId)
        end)
    end)
    task.wait(seconds)
    if oldOwns then pcall(hookfunction, BH_MPS.UserOwnsGamePassAsync, oldOwns) end
    if oldPrompt then pcall(hookfunction, BH_MPS.PromptGamePassPurchase, oldPrompt) end

    local txt
    if #hits > 0 then
        txt = "== SPY GAMEPASS — chamadas reais capturadas ==\n" .. table.concat(hits, "\n")
            .. "\n\nesses passId's rodam checagem no cliente — BH.HookMPS() cobre 100%."
    else
        txt = "== SPY GAMEPASS — nada capturado em " .. seconds .. "s ==\n"
            .. "ou a tela do item/loja travado não foi aberta durante a janela,\n"
            .. "ou esse gate é validado só no servidor — nesse caso não existe\n"
            .. "forma client-side de contornar, de nenhum script."
    end
    if writefile then pcall(writefile, "SilkcoreGamepassSpy.txt", txt) end
    if setclipboard then pcall(setclipboard, txt) end
    return hits, txt
end

-- dispara a remota real de Pass (RE.1Pas1s) com algumas assinaturas plausíveis.
-- experimental: o servidor valida a posse de verdade, então isso só ajuda se o jogo
-- confiar no client pra alguma parte do fluxo (ex. sync de UI pós-compra).
function BH.ProbePass(gpId)
    local attempts = {
        function() return bhFireRemote(BH_RE.Pass, gpId, true) end,
        function() return bhFireRemote(BH_RE.Pass, gpId) end,
        function() return bhFireRemote(BH_RE.Pass, "Buy", gpId) end,
    }
    local worked=0
    for _,try in ipairs(attempts) do
        local ok = pcall(try)
        if ok then worked=worked+1 end
    end
    return worked
end

Section("Dump")
Note("Escaneia remotes, gamepasses, PlayerData e loja do Brookhaven. Salva em SilkcoreBrookhavenDump.txt e copia para a área de transferência.", 68)
do
    local busy=false
    BtnRow("DUMP BROOKHAVEN", T.Accent, function()
        if busy then return end
        busy=true
        Toast("fazendo dump...", true)
        task.spawn(function()
            local txt,copied=BH.Dump()
            Toast(string.format("dump pronto · %d chars · %s", #txt, copied and "copiado!" or "salvo em arquivo"), true)
            busy=false
        end)
    end)
end

Section("Desbloqueio")
Note("Alvo é a árvore real do dump: NoResetGUIHandler.GamepassNeeded/GamepassUnlock/ProductUnlock + selos de cadeado nos templates de catálogo. Fica permanente — um watcher pega GUI nova depois do primeiro clique. Não altera dados no servidor.", 68)
BtnRow("DESBLOQUEAR GATES (cliente, permanente)", T.Good, function()
    local n=BH.ClientUnlock()
    Toast(string.format("unlock: %d gates fechados · watcher ativo", n), true)
end)

BtnRow("HOOK MarketplaceService (permanente)", T.Accent, function()
    local ok, err = BH.HookMPS()
    if ok then
        Toast("UserOwnsGamePassAsync agora retorna true pro seu player", true)
    else
        Toast("hook falhou: "..tostring(err), false)
    end
end)
Note("O hook intercepta toda checagem de posse de gamepass feita no cliente. Precisa de hookfunction no executor. Não afeta checagem feita só no servidor.", 68)

BtnRow("ESPIONAR GAMEPASS (10s)", T.Card, function()
    Toast("abra agora a loja/item travado — espionando 10s...", true)
    task.spawn(function()
        local hits, txt = BH.SpyGamepasses(10)
        if hits == nil then
            Toast("falhou: "..tostring(txt), false)
            return
        end
        Toast(string.format("spy: %d chamada(s) capturada(s) · salvo em SilkcoreGamepassSpy.txt", #hits), #hits>0)
    end)
end)
Note("Isso é o jeito de saber garantido, não chutado: abre a loja ou o item travado enquanto o spy roda. Se o passId aparecer no log, o hook acima cobre 100%. Se nunca aparecer, a checagem é só do servidor e nenhum script de cliente contorna isso — não dá pra fingir que dá.", 68)

do
    local row=Row(50)
    Label(row,"ID do Gamepass (remota 1Pas1s)",12,T.Text,F.Bold,nil,UDim2.fromOffset(16,0),UDim2.new(0.5,0,1,0))
    local gpField=Field(row,UDim2.new(0.5,4,0.5,-15),UDim2.new(0.28,0,0,30),"gamepassId...")
    Button(row,"FIRE",UDim2.new(0.8,4,0.5,-15),UDim2.fromOffset(60,30),T.Card,function()
        local id=tonumber(gpField.Text)
        if not id then Toast("ID inválido",false); return end
        local worked=BH.ProbePass(id)
        Toast(string.format("RE.1Pas1s disparada: %d tentativas", worked), worked>0)
    end)
end

Note("Experimental: dispara a remota real de Pass encontrada no dump. O servidor valida posse de verdade — isso só ajuda se o jogo confiar no client pra sincronizar UI pós-compra.", 68)

Section("Teleporte Brookhaven")
do
    local BH_LOCS={
        {n="Spawn",      p=Vector3.new(0,5,0)},
        {n="Casa (1)",   p=Vector3.new(120,5,80)},
        {n="Hospital",   p=Vector3.new(-180,5,60)},
        {n="Escola",     p=Vector3.new(200,5,-100)},
        {n="Policia",    p=Vector3.new(-100,5,-150)},
        {n="Praia",      p=Vector3.new(300,5,300)},
        {n="Montanha",   p=Vector3.new(-300,80,-300)},
    }
    for _, loc in ipairs(BH_LOCS) do
        local row=Row(40)
        Label(row,loc.n,12,T.Text,F.Bold,nil,UDim2.fromOffset(16,0),UDim2.new(0.7,0,1,0))
        Button(row,"TP",UDim2.new(0.76,0,0.5,-13),UDim2.fromOffset(60,26),T.Card,function()
            local r=hkRoot()
            if r then
                r.CFrame=CFrame.new(loc.p)
                Toast("tp → "..loc.n, true)
            else
                Toast("sem personagem",false)
            end
        end)
    end
end

Section("Hacks Brookhaven")
Toggle("Voar no Brookhaven", false, function(v)
    HackState.fly=v
    if v then task.spawn(startFly) else stopFly() end
    Toast("fly "..(v and "ligado" or "desligado"), v)
end, "bh_fly")
Toggle("Speed (carro / personagem)", false, function(v)
    HackState.speed=v; HackState.speedVal=v and 100 or 16
    applySpeed(HackState.speedVal)
    Toast("speed hack "..(v and "ligado" or "desligado"), v)
end, "bh_speed")
Toggle("Invisível (transparência 1)", false, function(v)
    local char=hkChar()
    if not char then Toast("sem personagem",false); return end
    for _,p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") or p:IsA("Decal") then
            p.Transparency = v and 1 or 0
        end
    end
    Toast("invisível "..(v and "ligado" or "desligado"), v)
end, "bh_invis")
Toggle("Congelar NPCs (Anchored)", false, function(v)
    for _,p in ipairs(workspace:GetDescendants()) do
        if p:IsA("BasePart") and not p:IsDescendantOf(LocalPlayer.Character or game) then
            local isNpc=p.Parent and p.Parent:FindFirstChildOfClass("Humanoid")
            if isNpc then p.Anchored=v end
        end
    end
    Toast("npcs "..(v and "congelados" or "descongelados"), v)
end, "bh_npc")

BtnRow("DAR DINHEIRO (local)", T.Good, function()
    local n=0
    local function trySet(inst)
        if not inst then return end
        for _,d in ipairs(inst:GetDescendants()) do
            local nm=d.Name:lower()
            if d:IsA("NumberValue") or d:IsA("IntValue") then
                if nm:find("money") or nm:find("cash") or nm:find("coin") or nm:find("buck") then
                    d.Value=999999; n=n+1
                end
            end
        end
    end
    trySet(LocalPlayer); trySet(LocalPlayer:FindFirstChild("Data"))
    trySet(LocalPlayer:FindFirstChild("leaderstats"))
    Toast(n>0 and ("dinheiro: "..n.." valores → 999999") or "sem valores de dinheiro encontrados", n>0)
end)

BtnRow("FORÇAR PERSONAGEM PADRÃO", T.Card, function()
    task.spawn(function()
        local h=hkHum()
        if h then
            local d=Instance.new("HumanoidDescription")
            pcall(h.ApplyDescription,h,d)
            Toast("personagem resetado", true)
        else Toast("sem humanoid",false) end
    end)
end)

end -- Brookhaven tab
buildBrookhaven()

--------------------------------------------------------------------------------
-- HBG
--------------------------------------------------------------------------------
-- Corpo da aba em função própria: os locals daqui ficam no orçamento de
-- registradores desta função, não no do chunk principal (limite de 200).
local function buildHBG()
CurTab = Tab("HBG", 0, true)
Persist.Scope = "hbg"

local HG      = {}
local HG_RS   = game:GetService("ReplicatedStorage")
local HG_MPS  = game:GetService("MarketplaceService")

-- ============================================================
-- ESTADO
-- ============================================================
local HGState = {
    -- auto-block
    autoBlock     = false,
    blockRange    = 22,         -- studs até ameaça ativar o block
    blockHold     = 0.18,       -- segundos de hold após ativar
    blockDebounce = false,
    blockConn     = nil,
    comboActive   = false,
    lastAttack    = 0,
    comboWindow   = 0.55,       -- janela que conta como "em combo" (não bloqueia)
    -- anti-cheat bypass
    acBypass      = false,
    acHooks       = {},
    acConns       = {},
    acLastPing    = 0,
    acFakeSpeed   = false,
}

-- ============================================================
-- HELPERS INTERNOS
-- ============================================================
local function hgChar()  return LocalPlayer.Character end
local function hgRoot()
    local c = hgChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function hgHum()
    local c = hgChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- Varredura de remotes no jogo inteiro (usa cache por sessão)
local hgRemoteCache = nil
local function hgScanRemotes(force)
    if hgRemoteCache and not force then return hgRemoteCache end
    local found = {}
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            found[#found + 1] = {
                class = d.ClassName,
                path  = d:GetFullName(),
                name  = d.Name:lower(),
                ref   = d,
            }
        end
    end
    hgRemoteCache = found
    return found
end

-- Tenta encontrar remote por palavras-chave no nome
local function hgFindRemote(keywords)
    local remotes = hgScanRemotes()
    for _, r in ipairs(remotes) do
        for _, kw in ipairs(keywords) do
            if r.name:find(kw, 1, true) then return r.ref, r.path end
        end
    end
    return nil, nil
end

-- ============================================================
-- DUMP HBG
-- ============================================================
function HG.Dump()
    local out = {}
    local function add(s, ...) out[#out+1] = (select("#",...) > 0) and string.format(s,...) or s end

    add("== HBG DUMP — SilkCore ==")
    add("Jogo: %s  PlaceId: %s", game.Name, tostring(game.PlaceId))
    add("")

    -- remotes categorizadas por intenção
    add("== REMOTES (jogo inteiro) ==")
    local remotes = hgScanRemotes(true)
    local cats = {
        ataque   = {"attack","atk","hit","damage","dmg","combat","punch","slash","skill","ability","cast"},
        block    = {"block","guard","parry","defend","shield"},
        status   = {"hp","health","stamina","energy","mana","ki","chakra","stat"},
        player   = {"player","char","respawn","spawn","load","join","leave"},
        anti     = {"check","verify","validate","anticheat","anti","cheat","flag","ban","kick","detect"},
        equip    = {"equip","weapon","item","inv","pickup","use"},
    }
    local tagged = {}
    for _, r in ipairs(remotes) do
        local labels = {}
        for cat, kws in pairs(cats) do
            for _, kw in ipairs(kws) do
                if r.name:find(kw, 1, true) then labels[cat] = true; break end
            end
        end
        local tag = next(labels) and "[" .. table.concat((function()
            local t={} for k in pairs(labels) do t[#t+1]=k end return t end)(), ",") .. "]" or ""
        tagged[#tagged+1] = string.format("  [%s] %s %s", r.class, r.path, tag)
    end
    table.sort(tagged)
    for _, l in ipairs(tagged) do add(l) end
    add("  total: %d remotes", #remotes)
    add("")

    -- pastas de combate em workspace / RS
    add("== FOLDERS DE COMBATE (workspace + RS) ==")
    local combatKws = {"hitbox","hurt","damage","projectile","bullet","combat","attack","skill","effect","vfx"}
    local folderCount = 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Folder") or d:IsA("Model") then
            local n = d.Name:lower()
            for _, kw in ipairs(combatKws) do
                if n:find(kw,1,true) then
                    add("  ws > %s [%s]", d:GetFullName(), d.ClassName)
                    folderCount = folderCount + 1
                    break
                end
            end
        end
    end
    for _, d in ipairs(HG_RS:GetDescendants()) do
        if d:IsA("Folder") or d:IsA("ModuleScript") or d:IsA("Model") then
            local n = d.Name:lower()
            for _, kw in ipairs(combatKws) do
                if n:find(kw,1,true) then
                    add("  rs > %s [%s]", d:GetFullName(), d.ClassName)
                    folderCount = folderCount + 1
                    break
                end
            end
        end
    end
    if folderCount == 0 then add("  nenhuma pasta de combate detectada") end
    add("")

    -- scripts de anti-cheat detectados
    add("== SCRIPTS DE ANTI-CHEAT DETECTADOS ==")
    local acKws = {"anticheat","anti_cheat","anti-cheat","cheatdetect","validate","integrity","security","sanity","ban","kick"}
    local acFound = 0
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("LocalScript") or d:IsA("ModuleScript") or d:IsA("Script") then
            local n = d.Name:lower()
            for _, kw in ipairs(acKws) do
                if n:find(kw,1,true) then
                    add("  [%s] %s", d.ClassName, d:GetFullName())
                    acFound = acFound + 1
                    break
                end
            end
        end
    end
    if acFound == 0 then add("  nenhum script AC com nome óbvio — pode ser ofuscado") end
    add("")

    -- player data
    add("== PLAYER DATA ==")
    local function scanValues(root, prefix)
        if not root then return end
        for _, v in ipairs(root:GetDescendants()) do
            if v:IsA("ValueBase") then
                add("  %s%s = %s [%s]", prefix, v:GetFullName():sub(#root:GetFullName()+2), tostring(v.Value), v.ClassName)
            end
        end
    end
    scanValues(LocalPlayer:FindFirstChild("Data"),        "Data.")
    scanValues(LocalPlayer:FindFirstChild("PlayerData"),  "PlayerData.")
    scanValues(LocalPlayer:FindFirstChild("leaderstats"), "leaderstats.")
    scanValues(LocalPlayer:FindFirstChild("Stats"),       "Stats.")
    add("")

    -- hitboxes ativas agora
    add("== HITBOXES ATIVAS (BasePart sem CanCollide, dono ≠ local) ==")
    local hbCount = 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") and not d.CanCollide then
            local owner = d:FindFirstChildOfClass("ObjectValue") -- alguns jogos marcam owner
            local n = d.Name:lower()
            if n:find("hit") or n:find("hurt") or n:find("dmg") or n:find("box") then
                add("  %s  size=%s", d:GetFullName(), tostring(d.Size))
                hbCount = hbCount + 1
            end
        end
    end
    if hbCount == 0 then add("  nenhuma hitbox detectada agora (execute durante combate)") end
    add("")

    local txt = table.concat(out, "\n")
    if writefile then pcall(writefile, "SilkcoreHBGDump.txt", txt) end
    local copied = false
    if setclipboard then copied = pcall(setclipboard, txt) end
    print("[SilkCore] HBG dump: " .. #txt .. " chars")
    return txt, copied
end

-- ============================================================
-- BYPASS DE ANTI-CHEAT
-- ============================================================

-- 1. Fake-speed: em vez de alterar WalkSpeed diretamente (o que ACs lêem),
--    usa um CFrame loop pra mover o character enquanto mantém WalkSpeed original.
--    Só ativa se Speed Hack do tab Hacks estiver desligado (não duplica).
local hgFakespeedConn = nil
local hgFakespeedTarget = 60

local function hgStartFakeSpeed(spd)
    hgFakespeedTarget = spd or 60
    if hgFakespeedConn then hgFakespeedConn:Disconnect(); hgFakespeedConn = nil end
    hgFakespeedConn = RunService.Heartbeat:Connect(function(dt)
        if not HGState.acFakeSpeed then
            hgFakespeedConn:Disconnect(); hgFakespeedConn = nil; return
        end
        local root = hgRoot()
        if not root then return end
        local mv = Vector3.new(0,0,0)
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then mv = mv + workspace.CurrentCamera.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then mv = mv - workspace.CurrentCamera.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then mv = mv - workspace.CurrentCamera.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then mv = mv + workspace.CurrentCamera.CFrame.RightVector end
        mv = Vector3.new(mv.X, 0, mv.Z)
        if mv.Magnitude > 0.01 then
            mv = mv.Unit * hgFakespeedTarget * dt
            root.CFrame = root.CFrame + mv
        end
    end)
end

-- 2. Hook remotes de verificação: intercepta chamadas de anti-cheat conhecidas
--    (speed check, position check) e responde com valores dentro do range normal.
local hgHookActive = false
function HG.InstallACHooks()
    if hgHookActive then return true, "já instalado" end
    if SilkGuard.Ghost then
        return false, "modo fantasma ligado — o hook deixa rastro de C-closure trocada, mais visível que o truque"
    end
    if not hookfunction then return false, "executor sem hookfunction" end

    local hooked = 0

    -- Targets confirmados pelo dump do HBG:
    -- ReplicateStep  → sync de estado de movimento/posição por frame (principal candidato de speed-check)
    -- ClientBodyVelocityEvent → replica velocidade do corpo pro servidor
    -- RemoteEvent / RemoteEvent1 → remotes genéricas que podem carregar qualquer payload de combate
    local HBG_AC_PATHS = {
        "ReplicatedStorage.Remotes.ReplicateStep",
        "ReplicatedStorage.Remotes.ClientBodyVelocityEvent",
        "ReplicatedStorage.Remotes.RemoteEvent",
        "ReplicatedStorage.Remotes.RemoteEvent1",
    }

    local function hookRemoteByPath(path)
        local cur = game
        for seg in path:gmatch("[^%.]+") do
            if not cur then return false end
            cur = cur:FindFirstChild(seg)
        end
        if not (cur and cur:IsA("RemoteEvent")) then return false end
        local ok = pcall(function()
            local old
            old = hookfunction(cur.FireServer, function(self, ...)
                local args = {...}
                for i, v in ipairs(args) do
                    -- normaliza qualquer número que pareça velocidade fora do range legítimo
                    if type(v) == "number" and math.abs(v) > 24 and math.abs(v) < 5000 then
                        -- preserva sinal, substitui por valor com ruído natural
                        args[i] = (v > 0 and 1 or -1) * (16 + math.random() * 3)
                    end
                    -- Vector3 com magnitude de velocidade suspeita
                    if type(v) == "userdata" then
                        local ok2, mag = pcall(function() return v.Magnitude end)
                        if ok2 and mag and mag > 24 and mag < 500 then
                            local ok3, unit = pcall(function() return v.Unit end)
                            if ok3 then
                                args[i] = unit * (16 + math.random() * 3)
                            end
                        end
                    end
                end
                return old(self, table.unpack(args))
            end)
        end)
        if ok then
            hooked = hooked + 1
            HGState.acHooks[#HGState.acHooks+1] = path
        end
        return ok
    end

    for _, path in ipairs(HBG_AC_PATHS) do
        hookRemoteByPath(path)
    end

    -- também tenta por nome genérico pra cobrir possíveis renomeações
    local remotes = hgScanRemotes()
    for _, r in ipairs(remotes) do
        local n = r.name
        if (n:find("replicate") or n:find("velocity") or n:find("step")) and r.ref:IsA("RemoteEvent") then
            local alreadyHooked = false
            for _, p in ipairs(HGState.acHooks) do if p == r.path then alreadyHooked = true; break end end
            if not alreadyHooked then
                local ok = pcall(function()
                    local old
                    old = hookfunction(r.ref.FireServer, function(self, ...)
                        return old(self, ...)
                    end)
                end)
                if ok then hooked = hooked + 1; HGState.acHooks[#HGState.acHooks+1] = r.path end
            end
        end
    end

    -- Hook UserOwnsGamePassAsync como fallback (alguns ACs verificam via gamepass)
    pcall(function()
        local old
        old = hookfunction(HG_MPS.UserOwnsGamePassAsync, function(self, plr, passId)
            if plr == LocalPlayer then return true end
            return old(self, plr, passId)
        end)
    end)

    -- Neutraliza checagem de Humanoid.WalkSpeed via __newindex se houver getrawmetatable
    if getrawmetatable then
        pcall(function()
            local mt = getrawmetatable(game)
            local oldNI = mt.__newindex
            setreadonly(mt, false)
            mt.__newindex = function(self, key, value)
                -- se algum script tentar setar WalkSpeed pra 0 ou valor suspeito no LocalPlayer
                if key == "WalkSpeed" and typeof(self) == "Instance" and self:IsA("Humanoid") then
                    local char = hgChar()
                    if char and self == char:FindFirstChildOfClass("Humanoid") then
                        if HGState.acFakeSpeed then return end -- ignora reset externo
                    end
                end
                return oldNI(self, key, value)
            end
            setreadonly(mt, true)
        end)
    end

    hgHookActive = true
    return true, string.format("%d remote(s) hookada(s)", hooked)
end

-- 3. Randomização de timing: adiciona jitter às ações pra não parecer bot
function HG.Jitter(base, variance)
    variance = variance or 0.05
    return base + (math.random() * variance * 2 - variance)
end

-- ============================================================
-- 4. DUMP PROFUNDO (GC + SCRIPTS) E NEUTRALIZAÇÃO DE DETECÇÃO
-- ============================================================
-- Superfície real de um anti-cheat de Roblox. Do lado do servidor ele vê:
--   (a) tudo que replica — posição, velocity, WalkSpeed, atributos de Humanoid
--   (b) instâncias que VOCÊ criou dentro do DataModel
--   (c) o ritmo e o formato dos argumentos que você manda nas remotes
-- Ele não chama getgc, getgenv ou hookfunction: isso só existe no executor.
-- Um anti-cheat client-side é um LocalScript comum, e o que ele consegue
-- checar é instância, nome, propriedade e callback. É isso que o dump
-- abaixo mapeia e que o report killer corta.

local HG_AC_WORDS = {
    "anti", "guard", "detect", "integrity", "heartbeat", "suspect",
    "exploit", "verify", "violation", "speed", "teleport", "fly", "noclip",
}

local HG_REPORT_WORDS = {
    "report", "flag", "anticheat", "anti_cheat", "antichat", "detect",
    "kick", "ban", "punish", "suspicious", "violation",
}

local function hgWordHit(name, list)
    if not name then return false end
    local n = name:lower()
    for _, w in ipairs(list) do
        if n:find(w, 1, true) then return true end
    end
    return false
end

local function hgFmtValue(v, depth)
    depth = depth or 0
    local t = typeof(v)
    if t == "Instance" then return v.ClassName .. ":" .. v:GetFullName() end
    if t == "string" then return string.format("%q", v:sub(1, 120)) end
    if t == "table" then
        if depth > 0 then return "{...}" end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 8 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. hgFmtValue(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

function HG.DumpScripts()
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

    add("== GC: funcoes com cara de anti-cheat ==")
    if type(getgc) ~= "function" then
        add("  executor sem getgc — sem dump de funcoes")
    else
        local seen, hits = {}, 0
        for _, v in ipairs(getgc(true)) do
            if type(v) == "function" then
                local okS, src = pcall(debug.info, v, "s")
                if okS and hgWordHit(tostring(src), HG_AC_WORDS) then
                    local okN, nm = pcall(debug.info, v, "n")
                    local okL, ln = pcall(debug.info, v, "l")
                    local key = tostring(src) .. ":" .. tostring(ln) .. ":" .. tostring(nm)
                    if not seen[key] then
                        seen[key] = true
                        hits = hits + 1
                        if hits <= 250 then
                            add("  [%s:%s] %s", tostring(src), tostring(ln), tostring(nm))
                        end
                    end
                end
            end
        end
        add("  total: %d", hits)
    end

    add("")
    add("== Instancias LuaSourceContainer ==")
    local inst, total = nil, 0
    if type(getinstances) == "function" then
        local oki, res = pcall(getinstances)
        if oki then inst = res end
    end
    if not inst then
        add("  executor sem getinstances")
    else
        for _, v in ipairs(inst) do
            local ok, isS = pcall(function() return v:IsA("LuaSourceContainer") end)
            if ok and isS then
                total = total + 1
                add("  %s [%s]%s", v:GetFullName(), v.ClassName, hgWordHit(v.Name, HG_AC_WORDS) and "  <== suspeito" or "")
            end
        end
        add("  total: %d", total)
    end

    add("")
    add("== Fonte dos scripts suspeitos ==")
    if type(decompile) ~= "function" and type(getscriptbytecode) ~= "function" then
        add("  executor sem decompile/getscriptbytecode")
    else
        local dumped = 0
        for _, v in ipairs(inst or {}) do
            local ok, isS = pcall(function() return v:IsA("LocalScript") or v:IsA("ModuleScript") end)
            if ok and isS and hgWordHit(v.Name, HG_AC_WORDS) then
                local src
                if type(decompile) == "function" then
                    local okd, d = pcall(decompile, v)
                    if okd and type(d) == "string" then src = d end
                end
                if not src and type(getscriptbytecode) == "function" then
                    local okb, b = pcall(getscriptbytecode, v)
                    if okb and type(b) == "string" then
                        src = "-- bytecode, " .. #b .. " bytes (usa um descompilador externo)"
                    end
                end
                if src then
                    dumped = dumped + 1
                    add("")
                    add("---- %s [%s] ----", v:GetFullName(), v.ClassName)
                    add("%s", src:sub(1, 24000))
                end
            end
        end
        add("")
        add("  scripts com fonte extraida: %d", dumped)
    end

    add("")
    add("== Remotes com nome de report/flag ==")
    for _, r in ipairs(hgScanRemotes(true)) do
        if hgWordHit(r.name, HG_REPORT_WORDS) then
            add("  %s [%s]", r.path, r.class)
        end
    end

    local txt = table.concat(out, "\n")
    if writefile then pcall(writefile, "SilkcoreACDump.txt", txt) end
    local copied = false
    if setclipboard then copied = pcall(setclipboard, txt) end
    print("[SilkCore] AC dump: " .. #txt .. " chars")
    return txt, copied
end

-- ============================================================
-- DUMP TOTAL
-- ============================================================
-- Puxa tudo que o cliente consegue ler: remotes, fonte de todos os scripts,
-- instâncias suspeitas, dados do player, atributos e o trace.
-- Não usa hook nenhum, não escreve nada no DataModel, não cria instância.
-- Só leitura + arquivo no executor. O jogo não tem como ver isso.
-- Roda em fatias (task.wait a cada N itens) pra não travar o frame — travada
-- de 2s é o único rastro comportamental que um dump deixa.
function HG.DumpAll()
    local t0 = os.clock()
    local out, n = {}, 0
    local function add(fmt, ...)
        n = n + 1
        out[n] = string.format(fmt, ...)
    end

    add("== SILK CORE · DUMP TOTAL ==")
    add("place=%s  job=%s", tostring(game.PlaceId), tostring(game.JobId))
    add("executor=%s", tostring(execName))
    add("api: getgc=%s getinstances=%s decompile=%s getconnections=%s",
        tostring(type(getgc) == "function"), tostring(type(getinstances) == "function"),
        tostring(type(decompile) == "function"), tostring(type(getconnections) == "function"))
    add("")

    -- remotes
    local remotes = hgScanRemotes(true)
    add("== REMOTES (%d) ==", #remotes)
    for i, r in ipairs(remotes) do
        add("  [%s] %s", r.class, r.path)
        if i % 40 == 0 then task.wait() end
    end

    -- instâncias com nome suspeito
    add("")
    add("== INSTANCIAS SUSPEITAS ==")
    local hits = 0
    for i, v in ipairs(game:GetDescendants()) do
        if hgWordHit(v.Name, HG_AC_WORDS) and hits < 500 then
            hits = hits + 1
            add("  %s [%s]", v:GetFullName(), v.ClassName)
        end
        if i % 500 == 0 then task.wait() end
    end
    add("  total: %d", hits)

    -- dados do player
    add("")
    add("== DADOS DO PLAYER ==")
    for _, folder in ipairs({"Data", "PlayerData", "leaderstats", "Stats", "Inventory", "Backpack"}) do
        local f = LocalPlayer:FindFirstChild(folder)
        if f then
            for _, v in ipairs(f:GetDescendants()) do
                if v:IsA("ValueBase") then
                    add("  %s = %s [%s]", v:GetFullName(), tostring(v.Value), v.ClassName)
                end
            end
            if f:IsA("ValueBase") then
                add("  %s = %s [%s]", f:GetFullName(), tostring(f.Value), f.ClassName)
            end
        end
    end

    -- atributos
    add("")
    add("== ATRIBUTOS ==")
    local function dumpAttrs(obj, label)
        if not obj then return end
        local ok, attrs = pcall(function() return obj:GetAttributes() end)
        if ok and attrs then
            for k, v in pairs(attrs) do
                add("  %s.%s = %s", label, tostring(k), tostring(v))
            end
        end
    end
    dumpAttrs(LocalPlayer, "Player")
    dumpAttrs(LocalPlayer.Character, "Character")
    dumpAttrs(workspace, "Workspace")

    -- fonte dos scripts: anti-cheat primeiro, resto depois, com teto de tamanho
    add("")
    add("== FONTE DOS SCRIPTS ==")
    local inst
    if type(getinstances) == "function" then
        local ok, res = pcall(getinstances)
        if ok then inst = res end
    end
    local dumped, budget = 0, 0
    local LIM_BYTES, LIM_SCRIPTS = 2000000, 90

    local function try_dump(v)
        if dumped >= LIM_SCRIPTS or budget > LIM_BYTES then return end
        local okS, isS = pcall(function() return v:IsA("LuaSourceContainer") end)
        if not okS or not isS then return end
        local src
        if type(decompile) == "function" then
            local okd, d = pcall(decompile, v)
            if okd and type(d) == "string" then src = d end
        end
        if not src then return end
        dumped = dumped + 1
        budget = budget + #src
        add("")
        add("---- %s [%s] %d chars ----", v:GetFullName(), v.ClassName, #src)
        add("%s", src:sub(1, 30000))
    end

    if inst then
        for i, v in ipairs(inst) do
            if hgWordHit(v.Name, HG_AC_WORDS) then try_dump(v) end
            if i % 20 == 0 then task.wait() end
        end
        add("")
        add("-- passe 2: restante dos scripts --")
        for i, v in ipairs(inst) do
            if not hgWordHit(v.Name, HG_AC_WORDS) then try_dump(v) end
            if i % 20 == 0 then task.wait() end
        end
    end
    add("")
    add("  scripts com fonte: %d · %d bytes", dumped, budget)

    -- gc: só o índice das funções
    add("")
    add("== GC: FUNCOES DE AC ==")
    if type(getgc) == "function" then
        local seen, gcHits = {}, 0
        for i, v in ipairs(getgc(true)) do
            if type(v) == "function" then
                local okS, src = pcall(debug.info, v, "s")
                if okS and hgWordHit(tostring(src), HG_AC_WORDS) then
                    local okN, nm = pcall(debug.info, v, "n")
                    local okL, ln = pcall(debug.info, v, "l")
                    local key = tostring(src) .. ":" .. tostring(ln)
                    if not seen[key] then
                        seen[key] = true
                        gcHits = gcHits + 1
                        if gcHits <= 300 then add("  [%s:%s] %s", tostring(src), tostring(ln), tostring(nm)) end
                    end
                end
            end
            if i % 2000 == 0 then task.wait() end
        end
        add("  total: %d", gcHits)
    else
        add("  executor sem getgc")
    end

    -- trace, se estiver ligado
    if #hgTrace.log > 0 then
        add("")
        add("== TRACE DE REMOTES (%d) ==", #hgTrace.log)
        for i = 1, #hgTrace.log do add("  %s", hgTrace.log[i]) end
    end

    local txt = table.concat(out, "\n")
    if writefile then pcall(writefile, "SilkcoreFullDump.txt", txt) end
    local copied = false
    if setclipboard then copied = pcall(setclipboard, txt) end
    HG.LastDump = txt
    return txt, copied, os.clock() - t0
end

-- ============================================================
-- DUMP DO JOGO (sem o lixo da engine)
-- ============================================================
-- O filtro por palavra-chave pega 40 mil linhas de CorePackages e quase nada
-- do jogo. O filtro certo é por caminho: joga fora a engine, fica com o que
-- o dev do jogo escreveu.
local HG_SKIP_PATH = {"CorePackages", "CoreGui", "RobloxGui", "RobloxReplicatedStorage", "CoreScripts"}

local function hgIsGamePath(obj)
    local ok, path = pcall(function() return obj:GetFullName() end)
    if not ok or not path then return false end
    for i = 1, #HG_SKIP_PATH do
        if path:find(HG_SKIP_PATH[i], 1, true) then return false end
    end
    return true
end

function HG.DumpGame()
    local t0 = os.clock()
    local out, n = {}, 0
    local function add(fmt, ...) n = n + 1; out[n] = string.format(fmt, ...) end

    add("== SILK CORE · DUMP DO JOGO ==")
    add("place=%s  job=%s  executor=%s",
        tostring(game.PlaceId), tostring(game.JobId), tostring(execName))
    add("")

    -- todos os remotes, agrupados pelo pai
    add("== REMOTES COMPLETAS ==")
    local groups, order = {}, {}
    for i, r in ipairs(hgScanRemotes(true)) do
        local parent = r.path:match("^(.*)%.[^.]+$") or "?"
        if not groups[parent] then groups[parent] = {}; order[#order + 1] = parent end
        table.insert(groups[parent], r)
        if i % 40 == 0 then task.wait() end
    end
    for _, parent in ipairs(order) do
        add("")
        add("[%s]", parent)
        for _, r in ipairs(groups[parent]) do
            add("  %-18s %s", r.class, tostring(r.ref and r.ref.Name or r.name))
        end
    end

    -- fonte de tudo que é do jogo
    add("")
    add("== FONTE DOS SCRIPTS DO JOGO ==")
    local inst
    if type(getinstances) == "function" then
        local ok, r = pcall(getinstances); if ok then inst = r end
    end
    local dumped, bytes = 0, 0
    if inst then
        for i, v in ipairs(inst) do
            local okS, isS = pcall(function() return v:IsA("LuaSourceContainer") end)
            if okS and isS and hgIsGamePath(v) then
                local src
                if type(decompile) == "function" then
                    local okd, d = pcall(decompile, v)
                    if okd and type(d) == "string" then src = d end
                end
                if src then
                    dumped = dumped + 1
                    bytes = bytes + #src
                    add("")
                    add("---- %s [%s] %d chars ----", v:GetFullName(), v.ClassName, #src)
                    add("%s", src:sub(1, 80000))
                    if bytes > 3000000 then
                        add("-- corte: 3 MB atingido")
                        break
                    end
                end
            end
            if i % 10 == 0 then task.wait() end
        end
    end
    add("")
    add("  scripts do jogo com fonte: %d · %d bytes", dumped, bytes)

    local txt = table.concat(out, "\n")
    if writefile then pcall(writefile, "SilkcoreGameDump.txt", txt) end
    local copied = false
    if setclipboard then copied = pcall(setclipboard, txt) end
    HG.LastDump = txt
    return txt, copied, os.clock() - t0
end

-- Trace de __namecall: mostra toda remote que o JOGO dispara e toda que NÓS
-- disparamos, com o payload. É esse log que revela qual remote o anti-cheat
-- usa pra avisar o servidor.
local hgTrace = { active = false, old = nil, log = {}, max = 400, dropped = {} }

function HG.TraceRemotes(on)
    if not (getrawmetatable and getnamecallmethod and newcclosure) then
        return false, "executor sem getrawmetatable/newcclosure"
    end
    local mt = getrawmetatable(game)

    if not on then
        if hgTrace.old then
            setreadonly(mt, false)
            mt.__namecall = hgTrace.old
            setreadonly(mt, true)
            hgTrace.old, hgTrace.active = nil, false
        end
        return true, string.format("%d eventos no log", #hgTrace.log)
    end
    if hgTrace.active then return true, "trace já ativo" end

    hgTrace.old = mt.__namecall
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        -- todo o log dentro de pcall: se der erro aqui, ele morre aqui.
        -- erro vazando pro namecall do jogo é a única forma de um hook ser notado.
        local m
        pcall(function() m = getnamecallmethod() end)
        if m == "FireServer" or m == "InvokeServer" then
            local args = table.pack(...)
            pcall(function()
                local ours = false
                if checkcaller then pcall(function() ours = checkcaller() end) end
                if #hgTrace.log < hgTrace.max then
                    local parts = {}
                    for i = 1, args.n do parts[i] = hgFmtValue(args[i]) end
                    hgTrace.log[#hgTrace.log + 1] = string.format("[%s] %s(%s)",
                        ours and "EU" or "JOGO", tostring(self.Name), table.concat(parts, ", "))
                end
            end)
        end
        return hgTrace.old(self, ...)
    end)
    setreadonly(mt, true)
    hgTrace.active = true
    return true, "trace ligado"
end

function HG.TraceText()
    return table.concat(hgTrace.log, "\n")
end

function HG.TraceClear()
    hgTrace.log = {}
end

-- Report killer: dropa o FireServer da remote que o anti-cheat usa pra avisar
-- o servidor. Não destrói o script deles — se ele sumir, o próprio heartbeat
-- de integridade acusa. Só corta a saída.
function HG.KillReport(on)
    if not (getrawmetatable and getnamecallmethod and newcclosure) then
        return false, "executor sem getrawmetatable/newcclosure"
    end
    local mt = getrawmetatable(game)

    if not on then
        if hgTrace.reportOld then
            setreadonly(mt, false)
            mt.__namecall = hgTrace.reportOld
            setreadonly(mt, true)
            hgTrace.reportOld = nil
        end
        return true, "report killer desligado"
    end
    if hgTrace.reportOld then return true, "já instalado" end

    hgTrace.reportOld = mt.__namecall
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        local drop = false
        pcall(function()
            local m = getnamecallmethod()
            if m ~= "FireServer" and m ~= "InvokeServer" then return end
            local ours = false
            if checkcaller then pcall(function() ours = checkcaller() end) end
            if ours then return end
            local ok, nm = pcall(function() return self.Name end)
            if ok and hgWordHit(nm, HG_REPORT_WORDS) then
                drop = true
                if not hgTrace.dropped[nm] then
                    hgTrace.dropped[nm] = 0
                    print("[SilkCore] report bloqueado: " .. tostring(nm))
                end
                hgTrace.dropped[nm] = hgTrace.dropped[nm] + 1
            end
        end)
        if drop then return nil end
        return hgTrace.reportOld(self, ...)
    end)
    setreadonly(mt, true)
    return true, "report killer instalado"
end

-- Tira a GUI do PlayerGui (se ainda estiver lá) e protege contra enumeração.
function HG.Evade()
    local done = {}
    local gui = (guiParent and guiParent:FindFirstChild(GUI_NAME)) or PlayerGui:FindFirstChild(GUI_NAME)
    if gui and gethui then
        local ok, dest = pcall(gethui)
        if ok and dest and gui.Parent ~= dest then
            gui.Parent = dest
            done[#done + 1] = "gui fora do PlayerGui"
        end
    end
    if gui then
        if syn and syn.protect_gui then
            if pcall(syn.protect_gui, gui) then done[#done + 1] = "syn.protect_gui" end
        elseif protectgui then
            if pcall(protectgui, gui) then done[#done + 1] = "protectgui" end
        end
    end
    if #done == 0 then return false, "nenhum método de proteção disponível" end
    return true, table.concat(done, " · ")
end

-- ============================================================
-- AUTO-BLOCK
-- ============================================================

-- Remote de ação do player: Workspace.Live.[nome].Main.RemoteEvent
-- (confirmado no dump — é o canal por onde todas as ações do combate passam)
local hgBlockRemote = nil
local function hgFindBlockRemote()
    if hgBlockRemote and hgBlockRemote.Parent then return hgBlockRemote end
    -- path real do dump
    local live = workspace:FindFirstChild("Live")
    if live then
        local playerFolder = live:FindFirstChild(LocalPlayer.Name)
        if playerFolder then
            local main = playerFolder:FindFirstChild("Main")
            if main then
                local re = main:FindFirstChild("RemoteEvent")
                if re and re:IsA("RemoteEvent") then
                    hgBlockRemote = re
                    return re
                end
            end
        end
    end
    -- fallback: varredura genérica por "block"/"guard" no RS
    local r = hgFindRemote({"block","guard","parry","defend","shield"})
    hgBlockRemote = r
    return r
end

-- ============================================================
-- PAYLOAD SPY via __namecall
-- Intercepta TODOS os FireServer do jogo via metamethod.
-- Captura o payload de qualquer ação do player (incluindo block).
-- Funciona em qualquer executor que tenha getrawmetatable + setreadonly.
-- ============================================================
local hgCapturedPayload = nil  -- {remote=ref, args={...}} capturado
local hgSpyActive       = false
local hgSpyOldNC        = nil  -- old __namecall

local function hgSerializeArgs(args)
    local parts = {}
    for i, v in ipairs(args) do
        if type(v) == "table" then
            local sub = {}
            for k2, v2 in pairs(v) do sub[#sub+1] = tostring(k2).."="..tostring(v2) end
            parts[i] = "{" .. table.concat(sub, ",") .. "}"
        elseif type(v) == "userdata" then
            parts[i] = "<"..tostring(v)..">"
        else
            parts[i] = tostring(v)
        end
    end
    return table.concat(parts, " | ")
end

-- remotes de interesse pra filtrar o spy (evita spam do jogo inteiro)
local hgSpyWhitelist = nil
local function hgBuildSpyWhitelist()
    hgSpyWhitelist = {}
    -- remote do player no workspace
    local live = workspace:FindFirstChild("Live")
    if live then
        local pf = live:FindFirstChild(LocalPlayer.Name)
        if pf then
            local main = pf:FindFirstChild("Main")
            if main then
                local re = main:FindFirstChild("RemoteEvent")
                if re then hgSpyWhitelist[re] = "ws.Live."..LocalPlayer.Name..".Main.RE" end
            end
        end
    end
    -- remotes RS relevantes do dump
    local rs = game:GetService("ReplicatedStorage")
    local rems = rs:FindFirstChild("Remotes")
    if rems then
        for _, name in ipairs({"RemoteEvent","RemoteEvent1","ReplicateStep","ClientBodyVelocityEvent"}) do
            local r = rems:FindFirstChild(name)
            if r then hgSpyWhitelist[r] = "RS.Remotes."..name end
        end
    end
end

local function hgStartSpy()
    if not getrawmetatable then return false, "executor sem getrawmetatable" end
    if hgSpyActive then return false, "spy já ativo" end
    hgBuildSpyWhitelist()
    local ok, err = pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure and newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" then
                local label = hgSpyWhitelist and hgSpyWhitelist[self]
                if label then
                    local args = {...}
                    local str = hgSerializeArgs(args)
                    print("[HBG SPY] " .. label .. " → " .. str)
                    if #args > 0 then
                        hgCapturedPayload = {remote = self, args = args}
                        Toast(label .. ": " .. str:sub(1,60), true)
                    end
                end
            end
            return old(self, ...)
        end) or function(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" then
                local label = hgSpyWhitelist and hgSpyWhitelist[self]
                if label then
                    local args = {...}
                    local str = hgSerializeArgs(args)
                    print("[HBG SPY] " .. label .. " → " .. str)
                    if #args > 0 then
                        hgCapturedPayload = {remote = self, args = args}
                        Toast(label .. ": " .. str:sub(1,60), true)
                    end
                end
            end
            return old(self, ...)
        end
        setreadonly(mt, true)
        hgSpyOldNC = old
        hgSpyActive = true
    end)
    if ok then return true, "spy ativo — aperta block uma vez no jogo"
    else return false, tostring(err) end
end

local function hgStopSpy()
    -- restaura __namecall original se tiver referência
    if hgSpyOldNC and getrawmetatable then
        pcall(function()
            local mt = getrawmetatable(game)
            setreadonly(mt, false)
            mt.__namecall = hgSpyOldNC
            setreadonly(mt, true)
        end)
    end
    hgSpyActive = false
    hgSpyOldNC  = nil
end

-- ============================================================
-- HOLD BLOCK
-- Usa o payload capturado pelo spy e fica disparando via :FireServer()
-- Intervalo base configurável + jitter humano.
-- ============================================================
local hgHoldConn = nil

local function hgFireBlock(remote, args)
    -- sintaxe correta: remote:FireServer(...) via pcall anônimo
    pcall(function() remote:FireServer(table.unpack(args)) end)
end

local function hgStartHoldBlock()
    if hgHoldConn then hgHoldConn:Disconnect(); hgHoldConn = nil end
    local interval = HGState.holdInterval or 0.08
    local lastFire  = 0

    -- remotes e payloads genéricos de fallback (usados quando spy não capturou nada)
    local function fireFallback()
        -- tenta na remote do workspace do player
        local remote = hgFindBlockRemote()
        if not remote then return end
        pcall(function() remote:FireServer("Block",  true)  end)
        pcall(function() remote:FireServer("Guard",  true)  end)
        pcall(function() remote:FireServer("block")         end)
        pcall(function() remote:FireServer(true)            end)
        pcall(function() remote:FireServer("block", true)   end)
    end

    hgHoldConn = RunService.Heartbeat:Connect(function()
        if not HGState.autoBlock then
            hgHoldConn:Disconnect(); hgHoldConn = nil; return
        end
        local now = tick()
        local jitter = interval * (0.7 + math.random() * 0.6)
        if now - lastFire < jitter then return end
        lastFire = now

        if hgCapturedPayload then
            hgFireBlock(hgCapturedPayload.remote, hgCapturedPayload.args)
        else
            fireFallback()
        end
    end)
end

local function hgStopHoldBlock()
    if hgHoldConn then hgHoldConn:Disconnect(); hgHoldConn = nil end
    -- tenta soltar o block
    if hgCapturedPayload then
        local rel = {}
        for i, v in ipairs(hgCapturedPayload.args) do
            rel[i] = (v == true) and false or v
        end
        pcall(function() hgCapturedPayload.remote:FireServer(table.unpack(rel)) end)
    else
        local remote = hgFindBlockRemote()
        if remote then
            pcall(function() remote:FireServer("Block", false) end)
            pcall(function() remote:FireServer("Guard", false) end)
            pcall(function() remote:FireServer(false)          end)
        end
    end
end

-- ============================================================
-- UI — DUMP
-- ============================================================
Section("Dump HBG")
Note("Escaneia todas as remotes do jogo, categoriza por intenção (ataque, block, status, anti-cheat), mapeia hitboxes e pasta de combate. Salva em SilkcoreHBGDump.txt.", 68)
do
    local busy = false
    BtnRow("DUMP HBG", T.Accent, function()
        if busy then return end
        busy = true
        Toast("fazendo dump HBG...", true)
        task.spawn(function()
            local txt, copied = HG.Dump()
            Toast(string.format("dump pronto · %d chars · %s", #txt, copied and "copiado!" or "salvo em arquivo"), true)
            busy = false
        end)
    end)
end
BtnRow("RESETAR CACHE DE REMOTES", T.Card, function()
    hgRemoteCache = nil
    hgBlockRemote = nil
    Toast("cache limpo — próximo dump re-escaneia tudo", true)
end)

-- ============================================================
-- UI — ANTI-CHEAT BYPASS
-- ============================================================
Section("Anti-Cheat Bypass")
Note("Hook de remotes de verificação: intercepta chamadas de speed/position check e normaliza os valores antes de enviarem ao servidor. Requer executor com hookfunction (ex: Synapse X, KRNL, AWP).", 68)

Section("Silk Guard")
Toggle("Silk Guard (proteção do script)", true, function(v)
    SilkGuard.On = v
    Toast(v and "guarda armada" or "guarda desarmada — nada é reposto se cair", v)
end, "hg_silkguard")

Toggle("Modo fantasma (GUI em gethui)", false, function(v)
    local on = SilkGuard.ghost(v)
    Toast(on and "GUI movida pro container oculto do executor" or "GUI de volta à árvore normal", true)
end, "hg_ghost")

BtnRow("AUDITORIA DE PEGADA", T.Card, function()
    Toast(SilkGuard.audit(), true)
end, 34)
Note("A guarda conta os frames do loop de render: se o bind cair, ela re-arma. Não é mágica contra servidor — é contra script de terceiro mexendo na tua mesa.", 52)

BtnRow("INSTALAR HOOKS DE AC", T.Good, function()
    task.spawn(function()
        local ok, msg = HG.InstallACHooks()
        Toast((ok and "✓ " or "✗ ") .. tostring(msg), ok)
        if ok and #HGState.acHooks > 0 then
            Toast("remotes hookadas: " .. table.concat(HGState.acHooks, ", "):sub(1, 80), true)
        end
    end)
end)
Note("Execute DUMP primeiro para mapear as remotes — o hook fica mais preciso com o cache populado.", 52)

Toggle("Fake Speed (bypassa speed-check)", false, function(v)
    HGState.acFakeSpeed = v
    if v then
        local spd = HGState.fakeSpeedVal or 60
        hgStartFakeSpeed(spd)
        Toast("fake speed ligado · WalkSpeed real mantido em 16", true)
    else
        Toast("fake speed desligado", false)
    end
end, "hg_fakespeed")
do
    local row = Row(50)
    Label(row, "Velocidade alvo (fake speed)", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16,0), UDim2.new(0.55,0,1,0))
    local sField = Field(row, UDim2.new(0.56,0,0.5,-15), UDim2.new(0.22,0,0,30), "60")
    Button(row, "SET", UDim2.new(0.8,0,0.5,-15), UDim2.fromOffset(52,30), T.Card, function()
        local v = tonumber(sField.Text)
        if not v or v < 1 or v > 500 then Toast("valor inválido (1-500)", false); return end
        HGState.fakeSpeedVal = v
        if HGState.acFakeSpeed then hgStartFakeSpeed(v) end
        Toast("fake speed → " .. v, true)
    end)
end

-- ============================================================
-- UI — DUMP PROFUNDO / NEUTRALIZACAO
-- ============================================================
Section("Dump profundo")
Note("Lê o GC atrás das funções de anti-cheat, lista os scripts do jogo e tenta descompilar os suspeitos. Salva em SilkcoreACDump.txt e copia pra área de transferência.", 60)

BtnRow("DUMP DE SCRIPTS / AC", T.Accent, function()
    task.spawn(function()
        local txt, copied = HG.DumpScripts()
        Toast(string.format("dump AC · %d chars · %s", #txt, copied and "copiado!" or "salvo em arquivo"), true)
    end)
end)

BtnRow("DUMP DO JOGO (sem CorePackages)", T.Accent, function()
    task.spawn(function()
        Toast("dump do jogo rodando — só o que é do dev", true)
        local txt, copied, secs = HG.DumpGame()
        Toast(string.format("dump do jogo · %d chars · %.1fs · %s", #txt, secs, copied and "copiado!" or "salvo em arquivo"), true)
    end)
end)

BtnRow("DUMP TOTAL (tudo)", T.Good, function()
    task.spawn(function()
        Toast("dump total rodando em segundo plano — pode jogar", true)
        local txt, copied, secs = HG.DumpAll()
        Toast(string.format("dump total · %d chars · %.1fs · %s", #txt, secs, copied and "copiado!" or "salvo em arquivo"), true)
    end)
end)

BtnRow("COPIAR ÚLTIMO DUMP", T.Card, function()
    if not HG.LastDump then Toast("nenhum dump ainda — roda o DUMP TOTAL primeiro", false); return end
    if setclipboard then pcall(setclipboard, HG.LastDump) end
    Toast(string.format("%d chars copiados pro clipboard", #HG.LastDump), true)
end, 34)

Toggle("Trace de remotes", false, function(v)
    local ok, msg = HG.TraceRemotes(v)
    Toast((ok and "" or "✗ ") .. msg, ok)
end, "hg_trace")

BtnRow("VER TRACE CAPTURADO", T.Card, function()
    local txt = HG.TraceText()
    if txt == "" then Toast("trace vazio — liga o trace e joga um round", false); return end
    if setclipboard then pcall(setclipboard, txt) end
    print("[SilkCore] trace:\n" .. txt)
    Toast(string.format("%d linhas copiadas", select(2, txt:gsub("\n", "")) + 1), true)
end, 34)

BtnRow("LIMPAR TRACE", T.Card, function()
    HG.TraceClear()
    Toast("trace limpo", true)
end, 34)

Section("Neutralizar detecção")
Note("O servidor não vê o teu executor — vê o que replica e o que você manda pra ele. O report killer corta a remote que o anti-cheat usa pra avisar. Não apague o script deles: se ele sumir, o heartbeat de integridade acusa na hora.", 60)

Toggle("Report killer (dropa flag/ban)", false, function(v)
    local ok, msg = HG.KillReport(v)
    Toast((ok and "" or "✗ ") .. msg, ok)
end, "hg_reportkill")

BtnRow("PROTEGER A GUI", T.Good, function()
    local ok, msg = HG.Evade()
    Toast((ok and "" or "✗ ") .. msg, ok)
end, 34)

-- ============================================================
-- UI — AUTO-BLOCK (HOLD BLOCK)
-- ============================================================
Section("Auto-Block")
Note("Segura o block ativo em loop via FireServer direto. Passo 1: ativa o Spy e aperta block uma vez no jogo pra capturar o payload real. Passo 2: liga o Hold Block.", 68)

-- Spy
BtnRow("ATIVAR SPY (captura payload de block)", T.Accent, function()
    task.spawn(function()
        local ok, msg = hgStartSpy()
        Toast((ok and "✓ " or "✗ ") .. msg, ok)
    end)
end)
Note("Com o spy ativo: aperta o botão de block do jogo UMA VEZ. O payload aparece no output e na notificação. Depois pode ligar o Hold Block.", 52)

BtnRow("VER PAYLOAD CAPTURADO", T.Card, function()
    if not hgCapturedPayload then
        Toast("nenhum payload capturado ainda — use o spy primeiro", false); return
    end
    local parts = {}
    for i, v in ipairs(hgCapturedPayload) do
        parts[i] = type(v) == "table" and "{table}" or tostring(v)
    end
    Toast("payload: " .. table.concat(parts, " | "), true)
    print("[HBG] payload capturado: " .. table.concat(parts, " | "))
end)

BtnRow("LIMPAR PAYLOAD (volta pra fallback)", T.Card, function()
    hgCapturedPayload = nil
    Toast("payload limpo — hold block vai usar argumentos genéricos", true)
end)

-- Hold block
Toggle("Hold Block", false, function(v)
    HGState.autoBlock = v
    if v then
        hgStartHoldBlock()
        local modo = hgCapturedPayload and "payload capturado" or "argumentos genéricos"
        Toast("hold block ligado · " .. modo, true)
    else
        hgStopHoldBlock()
        Toast("hold block desligado", false)
    end
end, "hg_holdblock")

do
    local row = Row(50)
    Label(row, "Intervalo de fire (s) — menor = mais agressivo", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16,0), UDim2.new(0.6,0,1,0))
end
do
    local row = Row(50)
    local iField = Field(row, UDim2.new(0.04,0,0.5,-15), UDim2.new(0.22,0,0,30), "0.08")
    Button(row, "SET", UDim2.new(0.28,0,0.5,-15), UDim2.fromOffset(52,30), T.Card, function()
        local v = tonumber(iField.Text)
        if not v or v < 0.02 or v > 2 then Toast("valor inválido (0.02-2)", false); return end
        HGState.holdInterval = v
        Toast("intervalo → " .. v .. "s", true)
        -- reinicia o loop se estiver ativo
        if HGState.autoBlock then hgStartHoldBlock() end
    end)
    Button(row, "REMOTE ATIVA", UDim2.new(0.36,0,0.5,-15), UDim2.fromOffset(106,30), T.Good, function()
        hgBlockRemote = nil
        local r = hgFindBlockRemote()
        if r then Toast("remote: " .. r:GetFullName(), true)
        else Toast("remote não encontrada — entre no jogo primeiro", false) end
    end)
end
Note("Se o hold block não funcionar com payload genérico: ativa o spy → aperta block manual uma vez → o payload é capturado → o hold block passa a usar ele.", 68)

end -- HBG tab
buildHBG()

--------------------------------------------------------------------------------
-- ATALHOS + LIMPEZA + BOOT
--------------------------------------------------------------------------------
do
    local origSetOpen = SetOpen
    SetOpen = function(v)
        if not v then Palette.Close() end
        origSetOpen(v)
    end
end
track(UserInputService.InputBegan:Connect(function(i, processed)
    if MenuKeys.Binding then
        if i.UserInputType == Enum.UserInputType.Keyboard then
            local target = MenuKeys.Binding
            MenuKeys.Binding = false
            local key = nil
            if i.KeyCode ~= Enum.KeyCode.Escape then key = i.KeyCode end
            if key == Enum.KeyCode.RightControl or key == Enum.KeyCode.RightShift or key == Enum.KeyCode.LeftControl then
                Toast("essa tecla é reservada do menu, escolha outra", false)
                return
            end
            if target == "look" then
                MenuKeys.Look = key
                MenuKeys.OnBindLook()
            else
                MenuKeys.Extra = key
                MenuKeys.OnBind()
            end
        end
        return
    end
    if Palette.IsOpen() then
        if i.KeyCode == Enum.KeyCode.Down then
            Palette.Move(1)
        elseif i.KeyCode == Enum.KeyCode.Up then
            Palette.Move(-1)
        elseif i.KeyCode == Enum.KeyCode.Escape then
            Palette.Close()
        elseif i.KeyCode == Enum.KeyCode.RightControl or i.KeyCode == Enum.KeyCode.RightShift then
            SetOpen(false)
        end
        return
    end
    if processed then return end
    local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
    if isOpen and ((i.KeyCode == Enum.KeyCode.K and ctrl) or i.KeyCode == Enum.KeyCode.Slash) then
        Palette.Open()
        return
    end
    if i.KeyCode == Enum.KeyCode.RightControl or i.KeyCode == Enum.KeyCode.RightShift
        or (MenuKeys.Extra ~= nil and i.KeyCode == MenuKeys.Extra) then
        SetOpen(not isOpen)
    elseif MenuKeys.Look ~= nil and i.KeyCode == MenuKeys.Look then
        Looks.Next()
    end
end))

Gui.Destroying:Connect(function()
    pcall(Persist.Flush)
    Persist.Loading = true -- nada daqui pra baixo pode sobrescrever o que esta salvo
    pcall(TB.Cleanup)
    pcall(Ward.ClearAll)
    pcall(Cat.ClearAll, true)
    pcall(FX.Clear)
    pcall(Env.Restore)
    pcall(Colors.ResetAll)
    pcall(RunService.UnbindFromRenderStep, RunService, STRETCH_BIND)
    unbindAim()
    clearConns(conns)
    clearAllBody()
    if FovGui then FovGui:Destroy() end
    if blurFx and blurFx.Parent then blurFx:Destroy() end
    if ToastGui then ToastGui:Destroy() end
    local lg = guiParent:FindFirstChild("SilkcoreLoader")
    if lg then lg:Destroy() end
end)
if env then
    env.SilkcoreCleanup = function()
        if Gui then Gui:Destroy() end
    end
end

-- Silk Guard: registra o que tem que continuar de pé, e liga a vigilância
if SilkGuard then
    pcall(SilkGuard.track, Gui)
    if FovGui then pcall(SilkGuard.track, FovGui) end
    if Drawing and VOL_STEP then pcall(SilkGuard.hold, VOL_BIND, Enum.RenderPriority.Camera.Value + 4, VOL_STEP) end
end

ShowTab("Clonar")
Gui.Enabled = false
runLoader(function(failed)
    SetOpen(true)
    if #failed > 0 then
        Toast("loader: " .. failed[1], false)
    else
        Toast("Silk Core pronto · RControl abre e fecha", true)
    end
end)