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
local NavArea
local NavPill, curName, curFrame, ShowTab, SetBadge
do
local Rail = New("Frame", {
    Name = "Rail", Size = UDim2.fromOffset(LAY.RAIL, LAY.BODY_H), Position = UDim2.fromOffset(12, LAY.BODY_Y),
    BackgroundColor3 = T.Panel, BackgroundTransparency = 0.2, BorderSizePixel = 0, ClipsDescendants = true,
}, Main)
LAY.Rail = Rail
Round(Rail, 8)
Stroke(Rail, T.Stroke, 1)
NavArea = New("ScrollingFrame", {
    Name = "NavArea",
    Size = UDim2.new(1, 0, 1, -66), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 4, ScrollBarImageColor3 = T.Stroke2,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y, ScrollingEnabled = true, ClipsDescendants = true,
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
        {id = "Clonar", icon = "clone", title = "Clonar Avatar", sub = "Clone qualquer jogador instantaneamente"},
        {id = "Corpo", icon = "body", title = "Corpo & Morphs", sub = "Headless, Korblox, escalas personalizadas"},
        {id = "Roupa", icon = "shirt", title = "Partes do Corpo", sub = "Troque cabeça, torso, braços e pernas por ID"},
        {id = "Catálogo", icon = "grid", title = "Catálogo de Itens", sub = "Acessórios, roupas, tools e parts"},
        {id = "Browse", icon = "grid", title = "Browse / Loja", sub = "Explore catálogo e emotes oficiais"},
        {id = "Efeitos", icon = "spark", title = "Efeitos Visuais", sub = "Partículas e rastros personalizados"},
        {id = "Looks", icon = "star", title = "Looks Salvos", sub = "Salve, exporte e importe looks completos"},
    }},
    {group = "MUNDO", items = {
        {id = "Ambiente", icon = "sun", title = "Ambiente & Filtros", sub = "Filtros de câmera, clima e modo foto"},
    }},
    {group = "FERRAMENTAS", items = {
        {id = "Aimlock", icon = "cross", title = "Aimlock", sub = "Sistema de mira automática configurável"},
        {id = "Volei", icon = "pulse", title = "Vôlei ESP", sub = "Linha de mira dos adversários em tempo real"},
        {id = "Hacks", icon = "spark", title = "Hacks Universais", sub = "Speed, fly, noclip, god mode e mais"},
        {id = "Brookhaven", icon = "house", title = "Brookhaven Tools", sub = "Dump, unlock de itens e teleporte"},
        {id = "HBG", icon = "cross", title = "HBG Bypass", sub = "Remotes, anti-cheat bypass e auto-block"},
        {id = "Diversos", icon = "sliders", title = "Diversos", sub = "Stretched screen e double jump"},
        {id = "Timebomb", icon = "bomb", title = "Timebomb Duels", sub = "Ferramentas específicas do modo"},
    }},
    {group = "UNIVERSAL", items = {
        {id = "Armas", icon = "cross", title = "Armas & Ferramentas", sub = "Mods de arma e tool em qualquer jogo"},
        {id = "Jogador", icon = "body", title = "Mods do Jogador", sub = "Aparência e propriedades do personagem"},
        {id = "Teleportes", icon = "house", title = "Teleportes", sub = "TP pra jogadores, objetos e coordenadas"},
        {id = "Por Jogo", icon = "grid", title = "Por Jogo", sub = "Hacks específicos de jogos conhecidos"},
        {id = "Admin", icon = "gear", title = "Comandos Admin", sub = "Kick, ban e controle do servidor"},
        {id = "Scripts", icon = "spark", title = "Scripts", sub = "Carrega scripts de terceiros"},
        {id = "Ajustes", icon = "sliders", title = "Ajustes", sub = "Preferências do menu universal"},
        {id = "Anti-Detecção", icon = "star", title = "Anti-Detecção", sub = "Proteção, bypass e registro"},
        {id = "Macros", icon = "bomb", title = "Macros", sub = "Grava e repete sequências de ações"},
        {id = "Rede", icon = "pulse", title = "Rede", sub = "Conexões, server hop e remotes"},
        {id = "Animações", icon = "shirt", title = "Animações", sub = "Toca animações e emotes customizados"},
        {id = "Mini-Jogos", icon = "sun", title = "Mini-Jogos", sub = "Efeitos e brincadeiras no mapa"},
        {id = "Avançado", icon = "sliders", title = "Avançado", sub = "Explorador de instâncias e scripts"},
        {id = "Estatísticas", icon = "pulse", title = "Estatísticas", sub = "Contadores de uso e desempenho"},
        {id = "Compatibilidade", icon = "grid", title = "Compatibilidade", sub = "Detecção automática de jogo"},
        {id = "Hacks Extras", icon = "spark", title = "Hacks Extras", sub = "Combat, movimento, visual e utilidade"},
        {id = "Desastres", icon = "bomb", title = "Desastres", sub = "Orbital e sobrevivência no Natural Disaster"},
        {id = "Fling", icon = "cross", title = "Fling", sub = "Voadora universal pra rigs R15"},
    }},
    {group = "SISTEMA", items = {
        {id = "Desempenho", icon = "pulse", title = "Desempenho", sub = "FPS, ping, memória e ajustes gráficos"},
        {id = "Config", icon = "gear", title = "Configurações", sub = "Tema, atalhos, registro e persistência"},
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
                BorderSizePixel = 0, Size = UDim2.new(1, -16, 0, 24), Position = UDim2.fromOffset(8, navY), ZIndex = 3,
            }, NavArea)
            Round(btn, 6)
            local holder = New("Frame", {
                Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(12, 3), BackgroundTransparency = 1, ZIndex = 3,
            }, btn)
            local icon = ICONS[it.icon](holder, T.Sub)
            local lbl = New("TextLabel", {
                Text = it.id, Font = F.Bold, TextSize = 12, TextColor3 = T.Sub, TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1, Position = UDim2.fromOffset(40, 0), Size = UDim2.new(1, -80, 1, 0), ZIndex = 3,
            }, btn)
            local badge = New("TextLabel", {
                Text = "", Font = F.Mono, TextSize = 10, TextColor3 = T.Faint, TextXAlignment = Enum.TextXAlignment.Right,
                BackgroundTransparency = 1, Position = UDim2.new(1, -40, 0, 0), Size = UDim2.fromOffset(32, 24), ZIndex = 3,
            }, btn)
            local name = it.id
            btn.MouseEnter:Connect(function()
                if curName ~= name then 
                    Tween(btn, 0.15, {BackgroundTransparency = 0.5}) 
                end
                -- Anima ícone para direita com bounce
                TweenEx(holder, 0.3, Enum.EasingStyle.Back, {Position = UDim2.fromOffset(16, 3)})
                -- Pulso sutil no texto
                TweenService:Create(lbl, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {TextSize = 13}):Play()
            end)
            btn.MouseLeave:Connect(function()
                if curName ~= name then
                    Tween(btn, 0.2, {BackgroundTransparency = 1})
                end
                Tween(holder, 0.2, {Position = UDim2.fromOffset(12, 3)})
                TweenService:Create(lbl, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {TextSize = 12}):Play()
            end)
            btn.MouseButton1Click:Connect(Safe(function()
                if ShowTab then 
                    -- Flash no ícone ao clicar
                    for _, ico in ipairs(icon) do
                        local element = ico.st or ico.f
                        local origColor = element:IsA("UIStroke") and element.Color or element.BackgroundColor3
                        if element:IsA("UIStroke") then
                            TweenService:Create(element, TweenInfo.new(0.15), {Color = Color3.new(1, 1, 1)}):Play()
                            task.delay(0.15, function()
                                TweenService:Create(element, TweenInfo.new(0.2), {Color = origColor}):Play()
                            end)
                        else
                            TweenService:Create(element, TweenInfo.new(0.15), {BackgroundColor3 = Color3.new(1, 1, 1)}):Play()
                            task.delay(0.15, function()
                                TweenService:Create(element, TweenInfo.new(0.2), {BackgroundColor3 = origColor}):Play()
                            end)
                        end
                    end
                    ShowTab(name) 
                end
            end, "nav " .. name))
            NAVB[name] = {btn = btn, icon = icon, lbl = lbl, badge = badge, y = navY, meta = it}
            navY = navY + 25
        end
        navY = navY + 6
    end

    -- canvas medido na mao: se o engine nao aplicar o automatico, a lista de baixo ficaria presa
    NavArea.CanvasSize = UDim2.fromOffset(0, navY + 24)

    -- rolagem garantida: roda do mouse e arrasto, sem depender da barrinha
    do
        local guiInset = Vector2.new(0, 36)
        pcall(function()
            local gs = game:GetService("GuiService")
            if gs and gs.GetGuiInset then guiInset = gs:GetGuiInset() end
        end)

        local arrastando, inicioY, canvasY = false, 0, 0

        local function limite()
            local c = NavArea.AbsoluteCanvasSize.Y
            if not c or c <= 0 then c = navY + 24 end
            return math.max(0, c - NavArea.AbsoluteSize.Y)
        end

        local function dentro(pos)
            local ap, as = NavArea.AbsolutePosition, NavArea.AbsoluteSize
            return pos.X >= ap.X and pos.X <= ap.X + as.X and pos.Y >= ap.Y - 10 and pos.Y <= ap.Y + as.Y + 10
        end

        local function mouseDentro()
            local m = UserInputService:GetMouseLocation() + guiInset
            return dentro(m)
        end

        UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                if dentro(input.Position) then
                    arrastando = true
                    inicioY = input.Position.Y
                    canvasY = NavArea.CanvasPosition.Y
                end
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseWheel then
                if mouseDentro() then
                    local passo = (input.Position.Z or 0) * 60
                    if passo == 0 then passo = 60 end
                    NavArea.CanvasPosition = Vector2.new(0, math.clamp(NavArea.CanvasPosition.Y - passo, 0, limite()))
                end
                return
            end
            if arrastando and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                NavArea.CanvasPosition = Vector2.new(0, math.clamp(canvasY - (input.Position.Y - inicioY), 0, limite()))
            end
        end)

        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                arrastando = false
            end
        end)
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
    track(RunService.Heartbeat:Connect(function(dt)
        if dot.Parent then 
            -- Pulso mais suave e lento para o status online
            local pulse = 0.2 + 0.3 * math.sin(os.clock() * 2.5)
            dot.BackgroundTransparency = pulse
            -- Micro animação de tamanho
            local scale = 8 + math.sin(os.clock() * 2.5) * 0.5
            dot.Size = UDim2.fromOffset(scale, scale)
        end
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
    -- Adiciona hover effect sutil
    card.MouseEnter:Connect(function()
        TweenService:Create(card, TweenInfo.new(0.15), {BackgroundColor3 = T.Card2}):Play()
    end)
    card.MouseLeave:Connect(function()
        TweenService:Create(card, TweenInfo.new(0.2), {BackgroundColor3 = T.Card}):Play()
    end)
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
    if NavArea then
        local altura = NavArea.AbsoluteSize.Y
        local span = math.max(0, NavArea.AbsoluteCanvasSize.Y - altura)
        local y = NavArea.CanvasPosition.Y
        if e.y < y + 8 then
            y = e.y - 8
        elseif (e.y + 24) > (y + altura - 8) then
            y = e.y + 24 - altura + 8
        end
        NavArea.CanvasPosition = Vector2.new(0, math.clamp(y, 0, span))
    end
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
    -- Melhorar partículas 3D - mais variação e movimento orgânico
    local motes = {}
    for i = 1, 20 do
        local size = 0.08 + math.random() * 0.06
        motes[i] = {
            p = New("Part", {
                Anchored = true, CanCollide = false, CastShadow = false, Material = Enum.Material.Neon,
                Color = (i % 3 == 0) and T.Accent2 or T.Accent, Size = Vector3.new(size, size, size),
                Shape = (i % 4 == 0) and Enum.PartType.Ball or Enum.PartType.Block,
            }, vp),
            sp = 0.3 + (i % 7) * 0.12, ph = i * 0.7, orbit = 1.8 + (i % 5) * 0.3,
        }
    end
    onTheme(function()
        rim.Color = T.Accent
        for i, m in ipairs(motes) do 
            m.p.Color = (i % 3 == 0) and T.Accent2 or T.Accent 
        end
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
-- o cache permanente faz a segunda visita Ã  mesma aba sair de graça.
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

-- carimbo de build: aparece na tela quando a linha está ligada. Se você carregar
-- um arquivo velho, esse número não muda — é o jeito de saber o que está rodando.
local BUILD = "BE06"
local VB = {
    On = false, Len = 14, Ball = true, OnlyEnemy = true, Predict = false,
    Thick = 6, Outline = 3, Alpha = 1, Dot = 6, ShowDot = true,
    MinPx = 90, MaxPx = 340, PixLen = 110,
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

    -- leitura ao vivo para diagnóstico: build, backend, pares, visíveis, altura
    local dbg = Instance.new("TextLabel")
    dbg.Name = "Build"
    dbg.Position = UDim2.fromOffset(10, 10)
    dbg.Size = UDim2.fromOffset(300, 62)
    dbg.BackgroundColor3 = Color3.new(0, 0, 0)
    dbg.BackgroundTransparency = 0.45
    dbg.BorderSizePixel = 0
    dbg.Font = Enum.Font.Code
    dbg.TextSize = 14
    dbg.TextXAlignment = Enum.TextXAlignment.Left
    dbg.TextYAlignment = Enum.TextYAlignment.Top
    dbg.TextColor3 = Color3.fromRGB(255, 255, 255)
    dbg.Text = ""
    dbg.Visible = false
    dbg.ZIndex = 10
    dbg.Parent = layer
    VB.dbg = dbg
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
        -- de reflect por jogador, por quadro, Ã  toa.
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
            if char ~= p.char then
                p.char, p.yoffAt, p.yoff, p.head = char, 0, 0, nil
                p.dir, p.sang, p.yoffSettle = nil, nil, 3
            end
            -- Mede a altura 3 vezes no primeiro ~3 s (tempo do rig carregar) e
            -- depois congela. Reamostrar sempre fazia a linha pular de altura a
            -- cada ciclo, porque a cabeça sobe e desce com a animação parada.
            if char and (p.yoffSettle or 0) > 0 and now - (p.yoffAt or -99) > 1.5 then
                p.yoffAt = now
                p.yoffSettle = p.yoffSettle - 1
                -- Origem = cabeça. O rig deste jogo não expõe "Head" como filho direto
                -- do modelo — daí a busca recursiva. Se a cabeça estiver no mesmo
                -- nível do root (rig com as peças empilhadas na origem, comum em
                -- personagem por SkinnedMesh), ela não serve de âncora: nesse caso
                -- usa o topo da caixa do modelo. E se nem isso der altura, cai em
                -- 2,6 studs acima do root — o que nunca deixa a linha no chão.
                local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
                if root then
                    local head = char:FindFirstChild("Head", true)
                    local relH = head and (head.Position.Y - root.Position.Y) or nil
                    local okB, box, size = pcall(function()
                        local c, s = char:GetBoundingBox()
                        return c, s
                    end)
                    local relT = (okB and box and size)
                        and ((box.Position.Y + size.Y * 0.5) - root.Position.Y) or nil

                    if relH and relH > 0.5 then
                        p.head, p.yoff = head, relH
                    elseif relT and relT > 0.5 then
                        p.head, p.yoff = nil, relT - 0.35
                    else
                        p.head, p.yoff = nil, 2.6
                    end
                    p.yoff = math.clamp(p.yoff, 0.8, 12)
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
            local o
            if p.head and p.head.Parent then
                o = p.head.Position
            else
                o = root.Position + Vector3.new(0, p.yoff or 0, 0)
            end
            -- A direção sai do Neck, que replica a ~10-20 Hz e NÃO é interpolado
            -- pelo cliente — era daí que vinha o pulo quadro a quadro. Suaviza
            -- com lerp dependente de dt: mesma velocidade em qualquer FPS.
            -- Só o plano horizontal. A animação de saque levanta a cabeça e o LookVector
            -- do pescoço ia junto: a linha subia com o saque. Zerar o Y deixa a
            -- linha deitada mesmo com o adversário olhando pra cima ou pra baixo.
            local lv = lookVec(char, root)
            local want = Vector3.new(lv.X, 0, lv.Z)
            if want.Magnitude > 0.05 then want = want.Unit else want = p.dir end
            if not want then
                local lv2 = root.CFrame.LookVector
                want = Vector3.new(lv2.X, 0, lv2.Z)
                if want.Magnitude > 0.05 then want = want.Unit else want = Vector3.new(0, 0, -1) end
            end
            local d = p.dir
            if not d then
                p.dir = want
            else
                local nd = d:Lerp(want, math.clamp(dt * 14, 0, 1))
                p.dir = (nd.Magnitude > 0.05) and nd.Unit or want
            end
            local a = proj(o)
            local b = nil
            if a then
                -- Direção em vista de cima, girada para a tela: direita da câmera
                -- no X, afastar-se da câmera no Y. Sem isso, alvo longe com câmera
                -- alta projetava a direção horizontal pra BAIXO na tela e a linha
                -- descia até o chão — era esse o "fica no chão quando tá longe".
                -- Comprimento fixo em pixel: não encolhe, não estica, não some.
                local angS
                local cf = CAM and CAM.CFrame
                if cf then
                    local R, Fw, U = cf.RightVector, cf.LookVector, cf.UpVector
                    local r2 = Vector3.new(R.X, 0, R.Z)
                    local f2 = Vector3.new(Fw.X, 0, Fw.Z)
                    if r2.Magnitude < 0.05 then r2 = Vector3.new(U.X, 0, U.Z) end
                    if f2.Magnitude < 0.2 then
                        local u2 = Vector3.new(U.X, 0, U.Z)
                        if u2.Magnitude > 0.05 then f2 = u2 end
                    end
                    if r2.Magnitude > 0.05 and f2.Magnitude > 0.05 then
                        r2, f2 = r2.Unit, f2.Unit
                        local sx = p.dir.X * r2.X + p.dir.Z * r2.Z
                        local sy = -(p.dir.X * f2.X + p.dir.Z * f2.Z)
                        if math.abs(sx) + math.abs(sy) > 0.15 then
                            -- O problema nunca foi a âncora: era a direção. Alvo
                            -- que olha na direção da câmera projeta quase reto
                            -- pra BAIXO, e com comprimento fixo a linha descia
                            -- pelo corpo inteiro. Aqui o desvio vertical é
                            -- comprimido e travado em 25°: a linha fica deitada,
                            -- no máximo inclinada, em qualquer distância.
                            local ang0 = math.deg(math.atan2(sy, sx))
                            local base = ((ang0 > 90) or (ang0 < -90)) and 180 or 0
                            local off = ang0 - base
                            if off > 90 then off = off - 360 elseif off < -90 then off = off + 360 end
                            off = math.clamp(off * 0.35, -25, 25)
                            angS = base + off
                        end
                    end
                end
                if not angS then angS = p.sang or 0 end
                p.sang = angS
                local rad = math.rad(angS)
                b = Vector2.new(a.X + math.cos(rad) * VB.PixLen,
                                a.Y + math.sin(rad) * VB.PixLen)
            end
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
        if VB.dbg then
            VB.dbg.Visible = VB.On == true
            if VB.On then
                local n, vis, sum = 0, 0, 0
                for _, q in pairs(VB.pairs) do
                    n = n + 1
                    if q.l and q.l.Visible then vis = vis + 1 end
                    sum = sum + (q.yoff or 0)
                end
                VB.dbg.Text = ("build %s  bk=%s\npairs=%d  vis=%d  yoff=%.1f\nbeats=%d  err=%s"):format(
                    BUILD, (HAS_DRAWING and not VB.ForceFrame) and "drawing" or "frame",
                    n, vis, (n > 0) and (sum / n) or 0,
                    SilkGuard.Beats, tostring(stepErr or "-"))
            end
        end
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

Slider("Comprimento da linha (px)", 40, 260, 110, "%d px", function(v)
    VB.PixLen = math.floor(v + 0.5)
end, "Volley line px")

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

BtnRow("DEIXAR BEM VISIVEL", T.Card, function()
    VB.Thick, VB.Outline, VB.Alpha, VB.Dot, VB.ShowDot = 7, 3, 1, 8, true
    restyleAll()
    Toast("grossa, contorno forte, ponto ligado", true)
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
    local sum = 0
    for _, p in pairs(VB.pairs) do
        n = n + 1
        if p.l and p.l.Visible then vis = vis + 1 end
        sum = sum + (p.yoff or 0)
    end
    local cam = Workspace.CurrentCamera
    local msg = ("bk=%s gui=%s on=%s pairs=%d visiveis=%d yoff=%.1f beats=%d cam=%s err=%s"):format(
        HAS_DRAWING and "drawing" or "frame",
        tostring(VBGui ~= nil and VBGui.Parent ~= nil),
        tostring(VB.On), n, vis, (n > 0) and (sum / n) or 0, SilkGuard.Beats,
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
    local about = Label(row, "Silk Core v2.1  ·  avatar, partes do corpo, catálogo e efeitos\nexecutor: " .. execName .. "   ·   place " .. tostring(game.PlaceId),
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

    -- Partículas melhoradas: mais quantidade, tamanhos variados, movimento suave
    local motes = {}
    for i = 1, 72 do
        local size = math.random(2, 5)
        local d = New("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(size, size),
            Position = UDim2.fromScale(math.random(), math.random()), BorderSizePixel = 0, ZIndex = 2,
            BackgroundColor3 = (i % 3 == 0) and T.Accent2 or T.Accent, 
            BackgroundTransparency = 0.5 + math.random() * 0.4,
        }, content)
        Round(d, size / 2)
        motes[i] = {f = d, sp = 0.008 + math.random() * 0.035, pulse = math.random() * 6.28, baseAlpha = 0.5 + math.random() * 0.4}
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
            l = Label(col, "○  " .. st.name, 11, T.Faint, F.Mono, nil, UDim2.fromOffset(20, 330 + (i - 1) * 17), UDim2.fromOffset(360, 17)),
            r = Label(col, "", 10, T.Faint, F.Mono, Enum.TextXAlignment.Right, UDim2.fromOffset(380, 330 + (i - 1) * 17), UDim2.fromOffset(100, 17)),
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

    local hb, loaderTime = nil, 0
    hb = RunService.Heartbeat:Connect(function(dt)
        if not LG.Parent then
            hb:Disconnect()
            return
        end
        loaderTime = loaderTime + dt
        
        -- Partículas com pulso suave
        for _, m in ipairs(motes) do
            local p = m.f.Position
            local y = p.Y.Scale - dt * m.sp
            if y < -0.05 then y = 1.05 end
            m.f.Position = UDim2.new(p.X.Scale, 0, y, 0)
            -- Pulso de transparência
            local pulse = (math.sin(loaderTime * 2 + m.pulse) * 0.15 + 0.85)
            m.f.BackgroundTransparency = m.baseAlpha * pulse
        end
        
        scan.Position = UDim2.fromScale(0, (loaderTime * 0.4) % 1)
        pct.Text = math.floor(fill.Size.X.Scale * 100 + 0.5) .. "%"
        
        -- Anima o gradiente da barra
        barGrad.Offset = Vector2.new(-0.3 + (loaderTime * 0.2) % 1, 0)
        
        -- Anima o shine quando a barra tá preenchendo
        if fill.Size.X.Scale > 0.01 then
            shine.Position = UDim2.fromScale((loaderTime * 0.5) % 1.3 - 0.15, 0)
        end
        
        -- Pulso suave no glow da borda
        glowFrame.BackgroundTransparency = 0.85 + math.sin(loaderTime * 1.5) * 0.08
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
        tag.Text = (#failed == 0) and "CARREGAMENTO COMPLETO" or ("PRONTO COM " .. #failed .. " FALHA(S)")
        tag.TextColor3 = (#failed == 0) and T.Good or T.Bad
        task.wait(0.5)
        word.Burst(0.4)
        task.wait(0.45)
        -- Logo fade out suave
        TweenService:Create(logo.vp, TweenInfo.new(0.3), {ImageTransparency = 1}):Play()
        task.wait(0.15)
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



--------------------------------------------------------------------------------
-- COMBAT HACKS - Universal Combat Enhancements  
--------------------------------------------------------------------------------
Section("Combat Avançado")
Note("Hacks de combate universais para jogos de luta e PvP", 48)

Toggle("Hitbox Expander", false, function(v)
    HackState.hitboxExpand = v
    if v then
        task.spawn(function()
            while HackState.hitboxExpand do
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer and player.Character then
                        local hrp = player.Character:FindFirstChild("HumanoidRootPart")
                        if hrp and hrp:IsA("BasePart") then
                            hrp.Size = Vector3.new(20, 20, 20)
                            hrp.Transparency = 0.8
                            hrp.CanCollide = false
                        end
                    end
                end
                task.wait(0.5)
            end
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer and player.Character then
                    local hrp = player.Character:FindFirstChild("HumanoidRootPart")
                    if hrp and hrp:IsA("BasePart") then
                        hrp.Size = Vector3.new(2, 2, 1)
                        hrp.Transparency = 1
                    end
                end
            end
        end)
    end
    Toast("hitbox expander "..(v and "ligado" or "desligado"), v)
end, "hk_hitbox")

Toggle("Silent Aim", false, function(v)
    HackState.silentAim = v
    Toast("silent aim "..(v and "ligado" or "desligado"), v)
end, "hk_silentaim")

Toggle("Auto Parry", false, function(v)
    HackState.autoParry = v
    if v then
        task.spawn(function()
            while HackState.autoParry do
                local char = LocalPlayer.Character
                if char then
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local tool = player.Character:FindFirstChildOfClass("Tool")
                            if tool then
                                local vim = game:GetService("VirtualInputManager")
                                vim:SendKeyEvent(true, Enum.KeyCode.F, false, game)
                                task.wait(0.05)
                                vim:SendKeyEvent(false, Enum.KeyCode.F, false, game)
                                task.wait(0.3)
                            end
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("auto parry "..(v and "ligado" or "desligado"), v)
end, "hk_parry")

Slider("Auto Click CPS", 1, 50, 10, "%d clicks/s", function(v)
    HackState.autoClickSpeed = v
end, "hk_clickspeed")

Toggle("Auto Clicker", false, function(v)
    HackState.autoClick = v
    if v then
        task.spawn(function()
            local mouse = LocalPlayer:GetMouse()
            while HackState.autoClick do
                mouse1press()
                task.wait(0.01)
                mouse1release()
                task.wait(1 / (HackState.autoClickSpeed or 10))
            end
        end)
    end
    Toast("auto clicker "..(v and "ligado" or "desligado"), v)
end, "hk_click")

Toggle("Rapid Fire", false, function(v)
    HackState.rapidFire = v
    if v then
        task.spawn(function()
            while HackState.rapidFire do
                local char = LocalPlayer.Character
                if char then
                    local tool = char:FindFirstChildOfClass("Tool")
                    if tool then
                        tool:Activate()
                        task.wait(0.05)
                    end
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("rapid fire "..(v and "ligado" or "desligado"), v)
end, "hk_rapid")

Toggle("Kill Aura", false, function(v)
    HackState.killAura = v
    if v then
        task.spawn(function()
            while HackState.killAura do
                local root = hkRoot()
                if root then
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
                            if targetRoot and (targetRoot.Position - root.Position).Magnitude < 20 then
                                local tool = LocalPlayer.Character:FindFirstChildOfClass("Tool")
                                if tool then
                                    tool:Activate()
                                    task.wait(0.1)
                                end
                            end
                        end
                    end
                end
                task.wait(0.2)
            end
        end)
    end
    Toast("kill aura "..(v and "ligado" or "desligado"), v)
end, "hk_aura")

--------------------------------------------------------------------------------
-- ESP SYSTEMS
--------------------------------------------------------------------------------
Section("ESP & Visuals")
Note("Sistemas de visualização através de paredes e objetos", 52)

Toggle("Player ESP", false, function(v)
    HackState.playerESP = v
    if v then
        task.spawn(function()
            local espObjects = {}
            local function createESP(char)
                if espObjects[char] then return end
                local hrp = char:FindFirstChild("HumanoidRootPart")
                local hum = char:FindFirstChildOfClass("Humanoid")
                if not hrp or not hum then return end
                
                local box = Instance.new("BoxHandleAdornment")
                box.Size = Vector3.new(4, 5, 4)
                box.Color3 = Color3.fromRGB(255, 0, 0)
                box.Transparency = 0.7
                box.AlwaysOnTop = true
                box.ZIndex = 5
                box.Adornee = hrp
                box.Parent = hrp
                
                local nameLabel = Instance.new("BillboardGui")
                nameLabel.Size = UDim2.new(0, 100, 0, 40)
                nameLabel.StudsOffset = Vector3.new(0, 3, 0)
                nameLabel.AlwaysOnTop = true
                nameLabel.Adornee = hrp
                nameLabel.Parent = hrp
                
                local text = Instance.new("TextLabel")
                text.Size = UDim2.new(1, 0, 1, 0)
                text.BackgroundTransparency = 1
                text.Text = char.Name
                text.TextColor3 = Color3.new(1, 1, 1)
                text.TextStrokeTransparency = 0.5
                text.TextScaled = true
                text.Font = Enum.Font.GothamBold
                text.Parent = nameLabel
                
                local healthLabel = Instance.new("TextLabel")
                healthLabel.Size = UDim2.new(1, 0, 0.5, 0)
                healthLabel.Position = UDim2.new(0, 0, 0.5, 0)
                healthLabel.BackgroundTransparency = 1
                healthLabel.Text = math.floor(hum.Health).."/"..math.floor(hum.MaxHealth)
                healthLabel.TextColor3 = Color3.new(0, 1, 0)
                healthLabel.TextStrokeTransparency = 0.5
                healthLabel.TextScaled = true
                healthLabel.Font = Enum.Font.Gotham
                healthLabel.Parent = nameLabel
                
                espObjects[char] = {box, nameLabel, healthLabel, hum}
                
                hum.HealthChanged:Connect(function(health)
                    if espObjects[char] then
                        healthLabel.Text = math.floor(health).."/"..math.floor(hum.MaxHealth)
                        local ratio = health / hum.MaxHealth
                        healthLabel.TextColor3 = Color3.fromRGB(255 * (1 - ratio), 255 * ratio, 0)
                    end
                end)
            end
            
            local function removeESP(char)
                if espObjects[char] then
                    for _, obj in ipairs(espObjects[char]) do
                        if typeof(obj) ~= "number" and obj.Destroy then
                            obj:Destroy()
                        end
                    end
                    espObjects[char] = nil
                end
            end
            
            while HackState.playerESP do
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer and player.Character then
                        createESP(player.Character)
                    end
                end
                task.wait(1)
            end
            
            for char, _ in pairs(espObjects) do
                removeESP(char)
            end
        end)
    end
    Toast("player ESP "..(v and "ligado" or "desligado"), v)
end, "hk_esp_player")

Toggle("Item ESP", false, function(v)
    HackState.itemESP = v
    if v then
        task.spawn(function()
            local espItems = {}
            while HackState.itemESP do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("Tool") and not espItems[obj] then
                        local handle = obj:FindFirstChild("Handle")
                        if handle and handle:IsA("BasePart") then
                            local billboard = Instance.new("BillboardGui")
                            billboard.Size = UDim2.new(0, 100, 0, 30)
                            billboard.StudsOffset = Vector3.new(0, 2, 0)
                            billboard.AlwaysOnTop = true
                            billboard.Adornee = handle
                            billboard.Parent = handle
                            
                            local label = Instance.new("TextLabel")
                            label.Size = UDim2.new(1, 0, 1, 0)
                            label.BackgroundTransparency = 1
                            label.Text = obj.Name
                            label.TextColor3 = Color3.fromRGB(255, 255, 0)
                            label.TextStrokeTransparency = 0.5
                            label.TextScaled = true
                            label.Font = Enum.Font.GothamBold
                            label.Parent = billboard
                            
                            espItems[obj] = billboard
                        end
                    end
                end
                task.wait(2)
            end
            for _, billboard in pairs(espItems) do
                if billboard and billboard.Destroy then billboard:Destroy() end
            end
        end)
    end
    Toast("item ESP "..(v and "ligado" or "desligado"), v)
end, "hk_esp_item")

Toggle("Chest ESP", false, function(v)
    HackState.chestESP = v
    if v then
        task.spawn(function()
            local espChests = {}
            while HackState.chestESP do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if not espChests[obj] then
                        local isChest = obj.Name:lower():find("chest") or 
                                       obj.Name:lower():find("crate") or
                                       obj.Name:lower():find("treasure") or
                                       obj.Name:lower():find("loot")
                        if isChest and obj:IsA("Model") then
                            local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                            if primary then
                                local billboard = Instance.new("BillboardGui")
                                billboard.Size = UDim2.new(0, 120, 0, 35)
                                billboard.StudsOffset = Vector3.new(0, 3, 0)
                                billboard.AlwaysOnTop = true
                                billboard.Adornee = primary
                                billboard.Parent = primary
                                
                                local label = Instance.new("TextLabel")
                                label.Size = UDim2.new(1, 0, 1, 0)
                                label.BackgroundTransparency = 1
                                label.Text = obj.Name
                                label.TextColor3 = Color3.fromRGB(255, 215, 0)
                                label.TextStrokeTransparency = 0.5
                                label.TextScaled = true
                                label.Font = Enum.Font.GothamBold
                                label.Parent = billboard
                                
                                espChests[obj] = billboard
                            end
                        end
                    end
                end
                task.wait(3)
            end
            for _, billboard in pairs(espChests) do
                if billboard and billboard.Destroy then billboard:Destroy() end
            end
        end)
    end
    Toast("chest ESP "..(v and "ligado" or "desligado"), v)
end, "hk_esp_chest")

Toggle("NPC ESP", false, function(v)
    HackState.npcESP = v
    if v then
        task.spawn(function()
            local espNPCs = {}
            while HackState.npcESP do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("Model") and not espNPCs[obj] then
                        local hum = obj:FindFirstChildOfClass("Humanoid")
                        local hrp = obj:FindFirstChild("HumanoidRootPart")
                        if hum and hrp and not Players:GetPlayerFromCharacter(obj) then
                            local box = Instance.new("BoxHandleAdornment")
                            box.Size = Vector3.new(4, 5, 4)
                            box.Color3 = Color3.fromRGB(255, 100, 0)
                            box.Transparency = 0.7
                            box.AlwaysOnTop = true
                            box.ZIndex = 5
                            box.Adornee = hrp
                            box.Parent = hrp
                            
                            local billboard = Instance.new("BillboardGui")
                            billboard.Size = UDim2.new(0, 100, 0, 40)
                            billboard.StudsOffset = Vector3.new(0, 3, 0)
                            billboard.AlwaysOnTop = true
                            billboard.Adornee = hrp
                            billboard.Parent = hrp
                            
                            local label = Instance.new("TextLabel")
                            label.Size = UDim2.new(1, 0, 1, 0)
                            label.BackgroundTransparency = 1
                            label.Text = obj.Name.." ["..math.floor(hum.Health).."]"
                            label.TextColor3 = Color3.fromRGB(255, 150, 0)
                            label.TextStrokeTransparency = 0.5
                            label.TextScaled = true
                            label.Font = Enum.Font.GothamBold
                            label.Parent = billboard
                            
                            espNPCs[obj] = {box, billboard}
                        end
                    end
                end
                task.wait(2)
            end
            for _, objs in pairs(espNPCs) do
                for _, o in ipairs(objs) do
                    if o and o.Destroy then o:Destroy() end
                end
            end
        end)
    end
    Toast("NPC ESP "..(v and "ligado" or "desligado"), v)
end, "hk_esp_npc")

Toggle("Vehicle ESP", false, function(v)
    HackState.vehicleESP = v
    if v then
        task.spawn(function()
            local espVehicles = {}
            while HackState.vehicleESP do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if not espVehicles[obj] then
                        local isVehicle = obj:FindFirstChildOfClass("VehicleSeat") or 
                                         obj.Name:lower():find("car") or
                                         obj.Name:lower():find("bike") or
                                         obj.Name:lower():find("vehicle")
                        if isVehicle and obj:IsA("Model") then
                            local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                            if primary then
                                local billboard = Instance.new("BillboardGui")
                                billboard.Size = UDim2.new(0, 100, 0, 30)
                                billboard.StudsOffset = Vector3.new(0, 4, 0)
                                billboard.AlwaysOnTop = true
                                billboard.Adornee = primary
                                billboard.Parent = primary
                                
                                local label = Instance.new("TextLabel")
                                label.Size = UDim2.new(1, 0, 1, 0)
                                label.BackgroundTransparency = 1
                                label.Text = obj.Name
                                label.TextColor3 = Color3.fromRGB(0, 200, 255)
                                label.TextStrokeTransparency = 0.5
                                label.TextScaled = true
                                label.Font = Enum.Font.GothamBold
                                label.Parent = billboard
                                
                                espVehicles[obj] = billboard
                            end
                        end
                    end
                end
                task.wait(3)
            end
            for _, billboard in pairs(espVehicles) do
                if billboard and billboard.Destroy then billboard:Destroy() end
            end
        end)
    end
    Toast("vehicle ESP "..(v and "ligado" or "desligado"), v)
end, "hk_esp_vehicle")

Toggle("Tracers", false, function(v)
    HackState.tracers = v
    if v then
        task.spawn(function()
            local tracerFolder = Instance.new("Folder")
            tracerFolder.Name = "SilkCoreTracers"
            tracerFolder.Parent = Workspace
            
            while HackState.tracers do
                for _, obj in ipairs(tracerFolder:GetChildren()) do
                    obj:Destroy()
                end
                
                local root = hkRoot()
                if root then
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
                            if targetRoot then
                                local beam = Instance.new("Part")
                                beam.Anchored = true
                                beam.CanCollide = false
                                beam.Material = Enum.Material.Neon
                                beam.Color = Color3.fromRGB(255, 0, 0)
                                beam.Transparency = 0.5
                                beam.Size = Vector3.new(0.2, 0.2, (targetRoot.Position - root.Position).Magnitude)
                                beam.CFrame = CFrame.new(root.Position, targetRoot.Position) * CFrame.new(0, 0, -beam.Size.Z / 2)
                                beam.Parent = tracerFolder
                            end
                        end
                    end
                end
                task.wait(0.1)
            end
            
            tracerFolder:Destroy()
        end)
    end
    Toast("tracers "..(v and "ligado" or "desligado"), v)
end, "hk_tracers")

--------------------------------------------------------------------------------
-- AUTO FARM SYSTEMS
--------------------------------------------------------------------------------
Section("Auto Farm Universal")
Note("Sistemas de farm automatico para varios tipos de jogo", 52)

Toggle("Auto Collect", false, function(v)
    HackState.autoCollect = v
    if v then
        task.spawn(function()
            while HackState.autoCollect do
                local root = hkRoot()
                if root then
                    for _, obj in ipairs(Workspace:GetDescendants()) do
                        if obj:IsA("BasePart") and (obj.Name:lower():find("coin") or 
                           obj.Name:lower():find("collect") or 
                           obj.Name:lower():find("orb") or
                           obj.Name:lower():find("gem")) then
                            if (obj.Position - root.Position).Magnitude < 50 then
                                root.CFrame = CFrame.new(obj.Position)
                                task.wait(0.1)
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("auto collect "..(v and "ligado" or "desligado"), v)
end, "hk_collect")

Toggle("Auto Farm NPCs", false, function(v)
    HackState.autoFarmNPC = v
    if v then
        task.spawn(function()
            while HackState.autoFarmNPC do
                local root = hkRoot()
                local char = LocalPlayer.Character
                if root and char then
                    local closest = nil
                    local closestDist = 100
                    
                    for _, obj in ipairs(Workspace:GetDescendants()) do
                        if obj:IsA("Model") then
                            local hum = obj:FindFirstChildOfClass("Humanoid")
                            local hrp = obj:FindFirstChild("HumanoidRootPart")
                            if hum and hrp and hum.Health > 0 and not Players:GetPlayerFromCharacter(obj) then
                                local dist = (hrp.Position - root.Position).Magnitude
                                if dist < closestDist then
                                    closest = hrp
                                    closestDist = dist
                                end
                            end
                        end
                    end
                    
                    if closest then
                        root.CFrame = CFrame.new(closest.Position) * CFrame.new(0, 0, 3)
                        local tool = char:FindFirstChildOfClass("Tool")
                        if tool then
                            tool:Activate()
                        end
                        task.wait(0.2)
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("auto farm NPC "..(v and "ligado" or "desligado"), v)
end, "hk_farm_npc")

Slider("Auto Rebirth Delay", 5, 300, 30, "%ds", function(v)
    HackState.rebirthDelay = v
end, "hk_rebirth_delay")

Toggle("Auto Rebirth", false, function(v)
    HackState.autoRebirth = v
    if v then
        task.spawn(function()
            while HackState.autoRebirth do
                local success = false
                
                for _, obj in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if obj:IsA("RemoteEvent") and (obj.Name:lower():find("rebirth") or obj.Name:lower():find("prestige")) then
                        pcall(function() obj:FireServer() end)
                        success = true
                    end
                end
                
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ClickDetector") and obj.Parent.Name:lower():find("rebirth") then
                        pcall(function() fireclickdetector(obj) end)
                        success = true
                    end
                end
                
                if success then
                    Toast("tentou rebirth", true)
                end
                
                task.wait(HackState.rebirthDelay or 30)
            end
        end)
    end
    Toast("auto rebirth "..(v and "ligado" or "desligado"), v)
end, "hk_rebirth")

Toggle("Auto Quest", false, function(v)
    HackState.autoQuest = v
    if v then
        task.spawn(function()
            while HackState.autoQuest do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ProximityPrompt") and (obj.ObjectText:lower():find("quest") or obj.ActionText:lower():find("accept")) then
                        pcall(function() fireproximityprompt(obj) end)
                    end
                    if obj:IsA("ClickDetector") and (obj.Parent.Name:lower():find("quest") or obj.Parent.Name:lower():find("mission")) then
                        pcall(function() fireclickdetector(obj) end)
                    end
                end
                task.wait(5)
            end
        end)
    end
    Toast("auto quest "..(v and "ligado" or "desligado"), v)
end, "hk_quest")

--------------------------------------------------------------------------------
-- SIMULATOR GAMES
--------------------------------------------------------------------------------
Section("Simuladores")
Note("Automacao especifica para jogos tipo simulator", 52)

Toggle("Auto Tap", false, function(v)
    HackState.autoTap = v
    if v then
        task.spawn(function()
            while HackState.autoTap do
                for _, obj in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                        if obj.Name:lower():find("click") or obj.Name:lower():find("tap") or obj.Name:lower():find("collect") then
                            pcall(function()
                                if obj:IsA("RemoteEvent") then
                                    obj:FireServer()
                                else
                                    obj:InvokeServer()
                                end
                            end)
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("auto tap "..(v and "ligado" or "desligado"), v)
end, "hk_tap")

Toggle("Auto Buy", false, function(v)
    HackState.autoBuy = v
    if v then
        task.spawn(function()
            while HackState.autoBuy do
                for _, obj in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                        if obj.Name:lower():find("buy") or obj.Name:lower():find("purchase") or obj.Name:lower():find("upgrade") then
                            pcall(function()
                                if obj:IsA("RemoteEvent") then
                                    obj:FireServer("Best")
                                    obj:FireServer(1)
                                    obj:FireServer()
                                else
                                    obj:InvokeServer("Best")
                                    obj:InvokeServer(1)
                                end
                            end)
                        end
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("auto buy "..(v and "ligado" or "desligado"), v)
end, "hk_buy")

Toggle("Auto Hatch", false, function(v)
    HackState.autoHatch = v
    if v then
        task.spawn(function()
            while HackState.autoHatch do
                for _, obj in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                        if obj.Name:lower():find("hatch") or obj.Name:lower():find("open") or obj.Name:lower():find("egg") then
                            pcall(function()
                                if obj:IsA("RemoteEvent") then
                                    obj:FireServer()
                                    obj:FireServer(1)
                                    obj:FireServer("Basic")
                                else
                                    obj:InvokeServer()
                                    obj:InvokeServer(1)
                                end
                            end)
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("auto hatch "..(v and "ligado" or "desligado"), v)
end, "hk_hatch")

--------------------------------------------------------------------------------
-- ADVANCED MOVEMENT
--------------------------------------------------------------------------------
Section("Movimento Avancado")
Note("Recursos extras de movimento", 48)

Toggle("Wall Walk", false, function(v)
    HackState.wallWalk = v
    if v then
        task.spawn(function()
            while HackState.wallWalk do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        for _, part in ipairs(char:GetDescendants()) do
                            if part:IsA("BasePart") then
                                part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0, 0.5, 1, 1)
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
            local char = LocalPlayer.Character
            if char then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CustomPhysicalProperties = nil
                    end
                end
            end
        end)
    end
    Toast("wall walk "..(v and "ligado" or "desligado"), v)
end, "hk_wallwalk")

Toggle("Platform Creator", false, function(v)
    HackState.platformMode = v
    if v then
        task.spawn(function()
            local platforms = {}
            while HackState.platformMode do
                local root = hkRoot()
                if root then
                    local platform = Instance.new("Part")
                    platform.Size = Vector3.new(8, 1, 8)
                    platform.Anchored = true
                    platform.Transparency = 0.5
                    platform.Material = Enum.Material.Neon
                    platform.Color = Color3.fromRGB(0, 200, 255)
                    platform.Position = root.Position - Vector3.new(0, 4, 0)
                    platform.Parent = Workspace
                    table.insert(platforms, platform)
                    
                    if #platforms > 10 then
                        local old = table.remove(platforms, 1)
                        if old and old.Parent then old:Destroy() end
                    end
                end
                task.wait(0.5)
            end
            for _, plat in ipairs(platforms) do
                if plat and plat.Parent then plat:Destroy() end
            end
        end)
    end
    Toast("platform creator "..(v and "ligado" or "desligado"), v)
end, "hk_platform")

Toggle("Fling Mode", false, function(v)
    HackState.flingMode = v
    if v then
        task.spawn(function()
            while HackState.flingMode do
                local root = hkRoot()
                if root then
                    local bodyVel = Instance.new("BodyVelocity")
                    bodyVel.Velocity = Vector3.new(0, 0, 0)
                    bodyVel.MaxForce = Vector3.new(9e9, 9e9, 9e9)
                    bodyVel.Parent = root
                    
                    task.wait(0.1)
                    
                    bodyVel.Velocity = Vector3.new(math.random(-100, 100), math.random(50, 150), math.random(-100, 100))
                    
                    task.wait(0.1)
                    bodyVel:Destroy()
                end
                task.wait(0.3)
            end
        end)
    end
    Toast("fling mode "..(v and "ligado" or "desligado"), v)
end, "hk_fling")

Toggle("Swim in Air", false, function(v)
    HackState.swimAir = v
    if v then
        task.spawn(function()
            while HackState.swimAir do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        hum:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
                        hum:ChangeState(Enum.HumanoidStateType.Swimming)
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("swim air "..(v and "ligado" or "desligado"), v)
end, "hk_swim")

Toggle("Auto Rotate", false, function(v)
    HackState.autoRotate = v
    if v then
        task.spawn(function()
            while HackState.autoRotate do
                local root = hkRoot()
                if root then
                    local closest = nil
                    local closestDist = 1000
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
                            if targetRoot then
                                local dist = (targetRoot.Position - root.Position).Magnitude
                                if dist < closestDist then
                                    closest = targetRoot
                                    closestDist = dist
                                end
                            end
                        end
                    end
                    if closest then
                        root.CFrame = CFrame.new(root.Position, closest.Position)
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("auto rotate "..(v and "ligado" or "desligado"), v)
end, "hk_rotate")

--------------------------------------------------------------------------------
-- SURVIVAL & PROTECTION
--------------------------------------------------------------------------------
Section("Sobrevivencia Extra")
Note("Protecoes adicionais", 48)

Toggle("Anti-Ragdoll", false, function(v)
    HackState.antiRagdoll = v
    if v then
        task.spawn(function()
            while HackState.antiRagdoll do
                local char = LocalPlayer.Character
                if char then
                    for _, obj in ipairs(char:GetDescendants()) do
                        if obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then
                            obj:Destroy()
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("anti-ragdoll "..(v and "ligado" or "desligado"), v)
end, "hk_antiragdoll")

Toggle("Anti-Stun", false, function(v)
    HackState.antiStun = v
    if v then
        task.spawn(function()
            while HackState.antiStun do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
                            hum:SetStateEnabled(state, true)
                        end
                        if hum.Sit then hum.Sit = false end
                        if hum.PlatformStand then hum.PlatformStand = false end
                    end
                end
                task.wait(0.2)
            end
        end)
    end
    Toast("anti-stun "..(v and "ligado" or "desligado"), v)
end, "hk_antistun")

Toggle("Infinite Health", false, function(v)
    HackState.infHealth = v
    if v then
        task.spawn(function()
            while HackState.infHealth do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health < hum.MaxHealth then
                        hum.Health = hum.MaxHealth
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("infinite health "..(v and "ligado" or "desligado"), v)
end, "hk_infhealth")

Toggle("Anti-Fall Damage", false, function(v)
    HackState.antiFall = v
    Toast("anti-fall damage "..(v and "ligado" or "desligado"), v)
end, "hk_antifall")

trackHK(RunService.Stepped:Connect(function()
    if HackState.antiFall then
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
                hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- VISUAL ENHANCEMENTS
--------------------------------------------------------------------------------
Section("Visual Extra")
Note("Modificacoes visuais avancadas", 48)

Toggle("X-Ray", false, function(v)
    HackState.xray = v
    if v then
        task.spawn(function()
            local originalTransparency = {}
            for _, obj in ipairs(Workspace:GetDescendants()) do
                if obj:IsA("BasePart") and not obj.Parent:FindFirstChildOfClass("Humanoid") then
                    originalTransparency[obj] = obj.Transparency
                    obj.Transparency = 0.8
                end
            end
            
            while HackState.xray do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("BasePart") and not obj.Parent:FindFirstChildOfClass("Humanoid") and not originalTransparency[obj] then
                        originalTransparency[obj] = obj.Transparency
                        obj.Transparency = 0.8
                    end
                end
                task.wait(2)
            end
            
            for obj, trans in pairs(originalTransparency) do
                if obj and obj.Parent then
                    obj.Transparency = trans
                end
            end
        end)
    end
    Toast("x-ray "..(v and "ligado" or "desligado"), v)
end, "hk_xray")

Toggle("Remove Textures", false, function(v)
    HackState.removeTextures = v
    if v then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("Decal") or obj:IsA("Texture") then
                obj.Transparency = 1
            end
            if obj:IsA("BasePart") then
                obj.Material = Enum.Material.SmoothPlastic
            end
        end
    else
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("Decal") or obj:IsA("Texture") then
                obj.Transparency = 0
            end
        end
    end
    Toast("remove textures "..(v and "ligado" or "desligado"), v)
end, "hk_notex")

Slider("FOV", 70, 120, 90, "%d", function(v)
    HackState.customFOV = v
    local cam = Workspace.CurrentCamera
    if cam then
        cam.FieldOfView = v
    end
end, "hk_fov")

Toggle("Custom FOV", false, function(v)
    HackState.fovEnabled = v
    local cam = Workspace.CurrentCamera
    if cam then
        if v then
            cam.FieldOfView = HackState.customFOV or 90
        else
            cam.FieldOfView = 70
        end
    end
    Toast("custom FOV "..(v and "ligado" or "desligado"), v)
end, "hk_fov_on")

--------------------------------------------------------------------------------
-- UTILITY & SERVER
--------------------------------------------------------------------------------
Section("Utilidades & Server")
Note("Ferramentas uteis e manipulacao de servidor", 48)

Toggle("FPS Unlocker", false, function(v)
    HackState.fpsUnlock = v
    setfpscap(v and 999 or 60)
    Toast("FPS unlocker "..(v and "ligado" or "desligado"), v)
end, "hk_fps")

BtnRow("Server Hop", T.Accent, function()
    Toast("procurando novo servidor...", true)
    task.spawn(function()
        local success, err = pcall(function()
            local servers = game:GetService("HttpService"):JSONDecode(
                game:HttpGet("https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100")
            )
            if servers and servers.data then
                for _, server in ipairs(servers.data) do
                    if server.playing < server.maxPlayers and server.id ~= game.JobId then
                        game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
                        return
                    end
                end
            end
        end)
        if not success then
            Toast("server hop falhou", false)
        end
    end)
end)

BtnRow("Rejoin Server", T.Card, function()
    Toast("reconectando...", true)
    task.wait(0.5)
    game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
end)

BtnRow("Copy Game Link", T.Card, function()
    local link = "https://www.roblox.com/games/"..game.PlaceId
    setclipboard(link)
    Toast("link copiado", true)
end)

do
    local row = Row(50)
    Label(row, "Teleport para PlaceId", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.5, 0, 1, 0))
    local placeField = Field(row, UDim2.new(0.52, 0, 0.5, -15), UDim2.new(0.28, 0, 0, 30), "place id...")
    Button(row, "TP", UDim2.new(0.82, 0, 0.5, -15), UDim2.fromOffset(56, 30), T.Accent, function()
        local placeId = tonumber(placeField.Text)
        if placeId then
            Toast("teleportando para "..placeId, true)
            game:GetService("TeleportService"):Teleport(placeId, LocalPlayer)
        else
            Toast("place ID invalido", false)
        end
    end)
end

Toggle("Anti-Kick", false, function(v)
    HackState.antiKick = v
    if v then
        local mt = getrawmetatable(game)
        local oldNamecall = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method == "Kick" then
                Toast("bloqueou tentativa de kick", true)
                return
            end
            return oldNamecall(self, ...)
        end)
        setreadonly(mt, true)
    end
    Toast("anti-kick "..(v and "ligado" or "desligado"), v)
end, "hk_antikick")

--------------------------------------------------------------------------------
-- EXPLOITS & ADVANCED
--------------------------------------------------------------------------------
Section("Exploits Avancados")
Note("Hacks avancados - use com cuidado", 52)

Toggle("Instant Interact", false, function(v)
    HackState.instantInteract = v
    if v then
        task.spawn(function()
            while HackState.instantInteract do
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ProximityPrompt") then
                        obj.HoldDuration = 0
                        obj.MaxActivationDistance = 20
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("instant interact "..(v and "ligado" or "desligado"), v)
end, "hk_instant")

Toggle("Remove Kill Bricks", false, function(v)
    HackState.removeKill = v
    if v then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name:lower():find("kill") then
                obj:Destroy()
            end
            if obj:IsA("BasePart") and obj.Touched then
                for _, script in ipairs(obj:GetChildren()) do
                    if script:IsA("Script") or script:IsA("LocalScript") then
                        if script.Source:lower():find("health") or script.Source:lower():find("humanoid") then
                            script:Destroy()
                        end
                    end
                end
            end
        end
        Toast("kill bricks removidos", true)
    end
end, "hk_nokill")

Toggle("Infinite Zoom", false, function(v)
    HackState.infZoom = v
    LocalPlayer.CameraMaxZoomDistance = v and 9999 or 128
    LocalPlayer.CameraMinZoomDistance = v and 0 or 0.5
    Toast("infinite zoom "..(v and "ligado" or "desligado"), v)
end, "hk_zoom")

Toggle("Click TP", false, function(v)
    HackState.clickTP = v
    if v then
        local mouse = LocalPlayer:GetMouse()
        HackState.clickTPConn = mouse.Button1Down:Connect(function()
            if HackState.clickTP and mouse.Target then
                local root = hkRoot()
                if root then
                    root.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0))
                end
            end
        end)
    else
        if HackState.clickTPConn then
            HackState.clickTPConn:Disconnect()
            HackState.clickTPConn = nil
        end
    end
    Toast("click TP "..(v and "ligado" or "desligado"), v)
end, "hk_clicktp")

BtnRow("Delete Tool", T.Card, function()
    local char = LocalPlayer.Character
    if char then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then
            tool:Destroy()
            Toast("ferramenta removida", true)
        else
            Toast("nenhuma ferramenta equipada", false)
        end
    end
end)

BtnRow("Unequip Tools", T.Card, function()
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:UnequipTools()
            Toast("ferramentas desequipadas", true)
        end
    end
end)

--------------------------------------------------------------------------------
-- GAME INFO & DIAGNOSTICS
--------------------------------------------------------------------------------
Section("Informacoes do Jogo")
Note("Diagnosticos e informacoes uteis", 48)

BtnRow("Print Game Info", T.Accent, function()
    print("=============== SILK CORE GAME INFO ===============")
    print("Game Name:", game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name)
    print("Place ID:", game.PlaceId)
    print("Job ID:", game.JobId)
    print("Creator ID:", game.CreatorId)
    print("Players:", #Players:GetPlayers().."/"..Players.MaxPlayers)
    print("Your UserID:", LocalPlayer.UserId)
    print("Your Display Name:", LocalPlayer.DisplayName)
    print("FPS:", math.floor(1 / game:GetService("RunService").Heartbeat:Wait()))
    print("Ping:", math.floor(LocalPlayer:GetNetworkPing() * 1000).."ms")
    print("===================================================")
    Toast("info printada no output (F9)", true)
end)

BtnRow("List All RemoteEvents", T.Card, function()
    print("=============== REMOTEEVENTS ===============")
    for _, obj in ipairs(game:GetDescendants()) do
        if obj:IsA("RemoteEvent") then
            print("RemoteEvent:", obj:GetFullName())
        end
    end
    print("===========================================")
    Toast("remoteevents listados no output", true)
end)

BtnRow("List All RemoteFunctions", T.Card, function()
    print("=============== REMOTEFUNCTIONS ===============")
    for _, obj in ipairs(game:GetDescendants()) do
        if obj:IsA("RemoteFunction") then
            print("RemoteFunction:", obj:GetFullName())
        end
    end
    print("===============================================")
    Toast("remotefunctions listados no output", true)
end)

Note("Hacks universais. Funcionam por tentativa, sem garantia em todo jogo.", 68)

end -- Hacks tab

--------------------------------------------------------------------------------
-- EXPANSAO DE HACKS AVANCADOS
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- ARMAS & FERRAMENTAS
--------------------------------------------------------------------------------
do
CurTab = Tab("Armas", 0, false)
Persist.Scope = "weapons"

Section("Armas & Ferramentas")
Note("Modificacoes universais para armas e ferramentas em qualquer jogo", 52)

Toggle("Infinite Ammo", false, function(v)
    HackState.infAmmo = v
    if v then
        task.spawn(function()
            while HackState.infAmmo do
                local char = LocalPlayer.Character
                if char then
                    for _, tool in ipairs(char:GetChildren()) do
                        if tool:IsA("Tool") then
                            for _, obj in ipairs(tool:GetDescendants()) do
                                if obj:IsA("IntValue") or obj:IsA("NumberValue") then
                                    if obj.Name:lower():find("ammo") or obj.Name:lower():find("bullet") then
                                        obj.Value = 9999
                                    end
                                end
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("infinite ammo "..(v and "ligado" or "desligado"), v)
end, "wp_ammo")

Toggle("No Reload", false, function(v)
    HackState.noReload = v
    if v then
        task.spawn(function()
            while HackState.noReload do
                local char = LocalPlayer.Character
                if char then
                    for _, tool in ipairs(char:GetChildren()) do
                        if tool:IsA("Tool") then
                            for _, obj in ipairs(tool:GetDescendants()) do
                                if obj:IsA("Animation") and obj.Name:lower():find("reload") then
                                    obj:Destroy()
                                end
                            end
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("no reload "..(v and "ligado" or "desligado"), v)
end, "wp_noreload")

Toggle("No Recoil", false, function(v)
    HackState.noRecoil = v
    Toast("no recoil "..(v and "ligado - recoil removido" or "desligado"), v)
end, "wp_recoil")

Toggle("No Spread", false, function(v)
    HackState.noSpread = v
    Toast("no spread "..(v and "ligado" or "desligado"), v)
end, "wp_spread")

Slider("Damage Multiplier", 1, 50, 1, "x%d", function(v)
    HackState.damageMult = v
end, "wp_dmg")

Toggle("Damage Hack", false, function(v)
    HackState.damageHack = v
    Toast("damage hack "..(v and "ligado - x"..(HackState.damageMult or 1) or "desligado"), v)
end, "wp_dmghack")

Toggle("Auto Equip Best Weapon", false, function(v)
    HackState.autoEquip = v
    if v then
        task.spawn(function()
            while HackState.autoEquip do
                local char = LocalPlayer.Character
                local backpack = LocalPlayer.Backpack
                if char and backpack then
                    local bestTool = nil
                    local bestDamage = 0
                    
                    for _, tool in ipairs(backpack:GetChildren()) do
                        if tool:IsA("Tool") then
                            for _, obj in ipairs(tool:GetDescendants()) do
                                if obj:IsA("NumberValue") and (obj.Name:lower():find("damage") or obj.Name:lower():find("power")) then
                                    if obj.Value > bestDamage then
                                        bestDamage = obj.Value
                                        bestTool = tool
                                    end
                                end
                            end
                        end
                    end
                    
                    if bestTool then
                        local hum = char:FindFirstChildOfClass("Humanoid")
                        if hum then
                            hum:EquipTool(bestTool)
                        end
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("auto equip "..(v and "ligado" or "desligado"), v)
end, "wp_autoequip")

Toggle("Tool Speed Boost", false, function(v)
    HackState.toolSpeed = v
    if v then
        task.spawn(function()
            while HackState.toolSpeed do
                local char = LocalPlayer.Character
                if char then
                    for _, tool in ipairs(char:GetChildren()) do
                        if tool:IsA("Tool") then
                            for _, obj in ipairs(tool:GetDescendants()) do
                                if obj:IsA("NumberValue") and obj.Name:lower():find("speed") then
                                    obj.Value = obj.Value * 2
                                end
                            end
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("tool speed "..(v and "ligado" or "desligado"), v)
end, "wp_speed")

Section("Municao & Recursos")

Toggle("Infinite Durability", false, function(v)
    HackState.infDurability = v
    if v then
        task.spawn(function()
            while HackState.infDurability do
                local char = LocalPlayer.Character
                if char then
                    for _, tool in ipairs(char:GetChildren()) do
                        if tool:IsA("Tool") then
                            for _, obj in ipairs(tool:GetDescendants()) do
                                if obj:IsA("NumberValue") and (obj.Name:lower():find("durability") or obj.Name:lower():find("condition")) then
                                    obj.Value = 100
                                end
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("infinite durability "..(v and "ligado" or "desligado"), v)
end, "wp_durability")

BtnRow("Drop All Tools", T.Card, function()
    local char = LocalPlayer.Character
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") then
                tool.Parent = Workspace
            end
        end
    end
    Toast("todas ferramentas dropadas", true)
end)

BtnRow("Clone Current Tool", T.Accent, function()
    local char = LocalPlayer.Character
    if char then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then
            local clone = tool:Clone()
            clone.Parent = LocalPlayer.Backpack
            Toast("ferramenta clonada", true)
        else
            Toast("nenhuma ferramenta equipada", false)
        end
    end
end)

end -- Armas

--------------------------------------------------------------------------------
-- MODIFICACOES DO JOGADOR
--------------------------------------------------------------------------------
do
CurTab = Tab("Jogador", 0, false)
Persist.Scope = "playermods"

Section("Modificacoes do Jogador")
Note("Modifica aparencia e propriedades do seu personagem", 52)

Slider("Scale Size", 0.1, 5, 1, "x%.1f", function(v)
    HackState.scaleSize = v
    if HackState.scaleEnabled then
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                local desc = hum:FindFirstChildOfClass("HumanoidDescription")
                if desc then
                    desc.HeadScale = v
                    desc.BodyTypeScale = v
                    desc.WidthScale = v
                    desc.DepthScale = v
                    desc.HeightScale = v
                    hum:ApplyDescription(desc)
                end
            end
        end
    end
end, "pm_scale")

Toggle("Custom Scale", false, function(v)
    HackState.scaleEnabled = v
    if v then
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                local desc = hum:FindFirstChildOfClass("HumanoidDescription")
                if desc then
                    local s = HackState.scaleSize or 1
                    desc.HeadScale = s
                    desc.BodyTypeScale = s
                    desc.WidthScale = s
                    desc.DepthScale = s
                    desc.HeightScale = s
                    hum:ApplyDescription(desc)
                end
            end
        end
    else
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                local desc = hum:FindFirstChildOfClass("HumanoidDescription")
                if desc then
                    desc.HeadScale = 1
                    desc.BodyTypeScale = 1
                    desc.WidthScale = 1
                    desc.DepthScale = 1
                    desc.HeightScale = 1
                    hum:ApplyDescription(desc)
                end
            end
        end
    end
    Toast("custom scale "..(v and "ligado" or "desligado"), v)
end, "pm_scale_on")

Slider("Hip Height", -5, 20, 0, "%.1f studs", function(v)
    HackState.hipHeight = v
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.HipHeight = v
        end
    end
end, "pm_hiphgt")

Toggle("Invisible Character", false, function(v)
    HackState.invisible = v
    local char = LocalPlayer.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                part.Transparency = v and 1 or 0
            end
            if part:IsA("Decal") or part:IsA("Texture") then
                part.Transparency = v and 1 or 0
            end
        end
    end
    Toast("invisible "..(v and "ligado" or "desligado"), v)
end, "pm_invis")

Toggle("Force Field Visual", false, function(v)
    HackState.ffVisual = v
    local char = LocalPlayer.Character
    if char and v then
        local ff = Instance.new("ForceField")
        ff.Visible = true
        ff.Parent = char
        HackState.ffInstance = ff
    else
        if HackState.ffInstance and HackState.ffInstance.Parent then
            HackState.ffInstance:Destroy()
        end
    end
    Toast("force field "..(v and "ligado" or "desligado"), v)
end, "pm_ff")

Toggle("Sparkles Effect", false, function(v)
    HackState.sparkles = v
    local char = LocalPlayer.Character
    if char then
        local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
        if torso then
            if v then
                local sparkles = Instance.new("Sparkles")
                sparkles.Parent = torso
                HackState.sparklesInstance = sparkles
            else
                if HackState.sparklesInstance and HackState.sparklesInstance.Parent then
                    HackState.sparklesInstance:Destroy()
                end
            end
        end
    end
    Toast("sparkles "..(v and "ligado" or "desligado"), v)
end, "pm_sparkles")

Toggle("Fire Effect", false, function(v)
    HackState.fire = v
    local char = LocalPlayer.Character
    if char then
        local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
        if torso then
            if v then
                local fire = Instance.new("Fire")
                fire.Size = 10
                fire.Heat = 10
                fire.Parent = torso
                HackState.fireInstance = fire
            else
                if HackState.fireInstance and HackState.fireInstance.Parent then
                    HackState.fireInstance:Destroy()
                end
            end
        end
    end
    Toast("fire "..(v and "ligado" or "desligado"), v)
end, "pm_fire")

Toggle("Smoke Effect", false, function(v)
    HackState.smoke = v
    local char = LocalPlayer.Character
    if char then
        local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
        if torso then
            if v then
                local smoke = Instance.new("Smoke")
                smoke.Size = 10
                smoke.Opacity = 0.5
                smoke.RiseVelocity = 5
                smoke.Parent = torso
                HackState.smokeInstance = smoke
            else
                if HackState.smokeInstance and HackState.smokeInstance.Parent then
                    HackState.smokeInstance:Destroy()
                end
            end
        end
    end
    Toast("smoke "..(v and "ligado" or "desligado"), v)
end, "pm_smoke")

Section("Controles Avancados")

Toggle("Sit Loop", false, function(v)
    HackState.sitLoop = v
    if v then
        task.spawn(function()
            while HackState.sitLoop do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        hum.Sit = true
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("sit loop "..(v and "ligado" or "desligado"), v)
end, "pm_sitloop")

Toggle("Jump Loop", false, function(v)
    HackState.jumpLoop = v
    if v then
        task.spawn(function()
            while HackState.jumpLoop do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("jump loop "..(v and "ligado" or "desligado"), v)
end, "pm_jumploop")

Toggle("Spin Character", false, function(v)
    HackState.spinChar = v
    if v then
        task.spawn(function()
            while HackState.spinChar do
                local root = hkRoot()
                if root then
                    root.CFrame = root.CFrame * CFrame.Angles(0, math.rad(10), 0)
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("spin character "..(v and "ligado" or "desligado"), v)
end, "pm_spin")

Toggle("Headless", false, function(v)
    HackState.headless = v
    local char = LocalPlayer.Character
    if char then
        local head = char:FindFirstChild("Head")
        if head then
            if v then
                head.Transparency = 1
                for _, obj in ipairs(head:GetChildren()) do
                    if obj:IsA("Decal") then
                        obj.Transparency = 1
                    end
                end
            else
                head.Transparency = 0
                for _, obj in ipairs(head:GetChildren()) do
                    if obj:IsA("Decal") then
                        obj.Transparency = 0
                    end
                end
            end
        end
    end
    Toast("headless "..(v and "ligado" or "desligado"), v)
end, "pm_headless")

Toggle("Korblox Leg (visual)", false, function(v)
    HackState.korblox = v
    local char = LocalPlayer.Character
    if char then
        local leg = char:FindFirstChild("RightLowerLeg") or char:FindFirstChild("Right Leg")
        if leg then
            leg.Transparency = v and 1 or 0
        end
    end
    Toast("korblox leg "..(v and "ligado" or "desligado"), v)
end, "pm_korblox")

BtnRow("Reset Character", T.Card, function()
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.Health = 0
            Toast("personagem resetado", true)
        end
    end
end)

BtnRow("Respawn (safe)", T.Accent, function()
    Toast("respawnando...", true)
    task.wait(0.2)
    LocalPlayer:LoadCharacter()
end)

end -- Jogador

--------------------------------------------------------------------------------
-- TELEPORTES AVANCADOS
--------------------------------------------------------------------------------
do
CurTab = Tab("Teleportes", 0, false)
Persist.Scope = "teleports"

Section("Teleporte Avancado")
Note("Sistema completo de teleporte para varios tipos de locais", 52)

BtnRow("TP to Spawn", T.Accent, function()
    local spawn = Workspace:FindFirstChild("SpawnLocation")
    if spawn then
        local root = hkRoot()
        if root then
            root.CFrame = spawn.CFrame + Vector3.new(0, 3, 0)
            Toast("teleportou para spawn", true)
        end
    else
        Toast("spawn nao encontrado", false)
    end
end)

BtnRow("TP to Random Player", T.Card, function()
    local players = Players:GetPlayers()
    if #players > 1 then
        local randomPlayer = players[math.random(1, #players)]
        if randomPlayer ~= LocalPlayer and randomPlayer.Character then
            local targetRoot = randomPlayer.Character:FindFirstChild("HumanoidRootPart")
            local root = hkRoot()
            if root and targetRoot then
                root.CFrame = targetRoot.CFrame + Vector3.new(0, 3, 0)
                Toast("teleportou para "..randomPlayer.Name, true)
            end
        end
    else
        Toast("nenhum outro player encontrado", false)
    end
end)

Section("TP para Objetos")

BtnRow("TP to Nearest Chest", T.Accent, function()
    local root = hkRoot()
    if root then
        local closest = nil
        local closestDist = 9999
        
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("Model") and (obj.Name:lower():find("chest") or obj.Name:lower():find("treasure")) then
                local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                if primary then
                    local dist = (primary.Position - root.Position).Magnitude
                    if dist < closestDist then
                        closest = primary
                        closestDist = dist
                    end
                end
            end
        end
        
        if closest then
            root.CFrame = closest.CFrame + Vector3.new(0, 5, 0)
            Toast("teleportou para bau mais proximo", true)
        else
            Toast("nenhum bau encontrado", false)
        end
    end
end)

BtnRow("TP to Nearest NPC", T.Card, function()
    local root = hkRoot()
    if root then
        local closest = nil
        local closestDist = 9999
        
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("Model") then
                local hum = obj:FindFirstChildOfClass("Humanoid")
                local hrp = obj:FindFirstChild("HumanoidRootPart")
                if hum and hrp and not Players:GetPlayerFromCharacter(obj) then
                    local dist = (hrp.Position - root.Position).Magnitude
                    if dist < closestDist then
                        closest = hrp
                        closestDist = dist
                    end
                end
            end
        end
        
        if closest then
            root.CFrame = closest.CFrame + Vector3.new(0, 3, 0)
            Toast("teleportou para NPC mais proximo", true)
        else
            Toast("nenhum NPC encontrado", false)
        end
    end
end)

BtnRow("TP to Nearest Vehicle", T.Card, function()
    local root = hkRoot()
    if root then
        local closest = nil
        local closestDist = 9999
        
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("VehicleSeat") then
                local dist = (obj.Position - root.Position).Magnitude
                if dist < closestDist then
                    closest = obj
                    closestDist = dist
                end
            end
        end
        
        if closest then
            root.CFrame = closest.CFrame + Vector3.new(0, 3, 0)
            Toast("teleportou para veiculo mais proximo", true)
        else
            Toast("nenhum veiculo encontrado", false)
        end
    end
end)

Section("Sistema de Waypoints")

do
    HackState.waypoints = HackState.waypoints or {}
    
    local row = Row(50)
    Label(row, "Nome do Waypoint", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.4, 0, 1, 0))
    local wpField = Field(row, UDim2.new(0.42, 0, 0.5, -15), UDim2.new(0.3, 0, 0, 30), "nome...")
    Button(row, "SALVAR", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local name = wpField.Text
        if #name > 0 then
            local root = hkRoot()
            if root then
                HackState.waypoints[name] = root.CFrame
                Toast("waypoint '"..name.."' salvo", true)
            end
        end
    end)
end

do
    local row = Row(50)
    Label(row, "Teleportar para Waypoint", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.4, 0, 1, 0))
    local wpTpField = Field(row, UDim2.new(0.42, 0, 0.5, -15), UDim2.new(0.3, 0, 0, 30), "nome...")
    Button(row, "IR", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Card, function()
        local name = wpTpField.Text
        if HackState.waypoints[name] then
            local root = hkRoot()
            if root then
                root.CFrame = HackState.waypoints[name]
                Toast("teleportou para '"..name.."'", true)
            end
        else
            Toast("waypoint nao encontrado", false)
        end
    end)
end

BtnRow("Listar Waypoints (output)", T.Card, function()
    print("========== WAYPOINTS ==========")
    local count = 0
    for name, cf in pairs(HackState.waypoints or {}) do
        print(name, "->", tostring(cf))
        count = count + 1
    end
    print("Total:", count)
    print("===============================")
    Toast("waypoints listados no output", true)
end)

BtnRow("Limpar Todos Waypoints", T.Card, function()
    HackState.waypoints = {}
    Toast("waypoints limpos", true)
end)

Section("Coordenadas Manuais")

do
    local row = Row(50)
    Label(row, "X", 11, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.fromOffset(20, 30))
    local xField = Field(row, UDim2.fromOffset(40, 0), UDim2.fromOffset(100, 30), "0")
    Label(row, "Y", 11, T.Text, F.Bold, nil, UDim2.fromOffset(146, 0), UDim2.fromOffset(20, 30))
    local yField = Field(row, UDim2.fromOffset(170, 0), UDim2.fromOffset(100, 30), "0")
    Label(row, "Z", 11, T.Text, F.Bold, nil, UDim2.fromOffset(276, 0), UDim2.fromOffset(20, 30))
    local zField = Field(row, UDim2.fromOffset(300, 0), UDim2.fromOffset(100, 30), "0")
    Button(row, "TP", UDim2.fromOffset(410, 0), UDim2.fromOffset(60, 30), T.Accent, function()
        local x = tonumber(xField.Text)
        local y = tonumber(yField.Text)
        local z = tonumber(zField.Text)
        if x and y and z then
            local root = hkRoot()
            if root then
                root.CFrame = CFrame.new(x, y, z)
                Toast("teleportou para coordenadas", true)
            end
        else
            Toast("coordenadas invalidas", false)
        end
    end)
end

BtnRow("Copy Current Position", T.Card, function()
    local root = hkRoot()
    if root then
        local pos = root.Position
        local text = string.format("%.2f, %.2f, %.2f", pos.X, pos.Y, pos.Z)
        setclipboard(text)
        Toast("posicao copiada: "..text, true)
    end
end)

end -- Teleportes

--------------------------------------------------------------------------------
-- MELHORIAS POR JOGO
--------------------------------------------------------------------------------
do
CurTab = Tab("Por Jogo", 0, false)
Persist.Scope = "gamespec"

Section("Deteccao Automatica de Jogo")
Note("Detecta o jogo e lista os hacks daquele titulo.", 52)

local gameId = game.PlaceId
local gameName = "Desconhecido"

pcall(function()
    gameName = game:GetService("MarketplaceService"):GetProductInfo(gameId).Name
end)

Note("Jogo Atual: "..gameName, 40)
Note("Place ID: "..tostring(gameId), 40)

Section("Arsenal / FPS")

Toggle("ESP para Arsenal", false, function(v)
    HackState.arsenalESP = v
    Toast("arsenal ESP "..(v and "ligado" or "desligado"), v)
end, "gs_arsenal_esp")

Toggle("Aimbot para FPS", false, function(v)
    HackState.fpsAimbot = v
    if v then
        task.spawn(function()
            while HackState.fpsAimbot do
                local mouse = LocalPlayer:GetMouse()
                local closest = nil
                local closestDist = 9999
                local root = hkRoot()
                
                if root then
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local head = player.Character:FindFirstChild("Head")
                            if head then
                                local screenPos, onScreen = Workspace.CurrentCamera:WorldToScreenPoint(head.Position)
                                if onScreen then
                                    local dist = (Vector2.new(screenPos.X, screenPos.Y) - Vector2.new(mouse.X, mouse.Y)).Magnitude
                                    if dist < closestDist and dist < 200 then
                                        closest = head
                                        closestDist = dist
                                    end
                                end
                            end
                        end
                    end
                    
                    if closest then
                        Workspace.CurrentCamera.CFrame = CFrame.new(Workspace.CurrentCamera.CFrame.Position, closest.Position)
                    end
                end
                
                task.wait(0.05)
            end
        end)
    end
    Toast("FPS aimbot "..(v and "ligado" or "desligado"), v)
end, "gs_fps_aim")

Section("Jailbreak / Prisão")

BtnRow("Auto Rob (Jailbreak)", T.Accent, function()
    Toast("iniciando auto rob...", true)
    task.spawn(function()
        HackState.autoRob = true
        while HackState.autoRob do
            local root = hkRoot()
            if root then
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj.Name == "TouchInterest" and obj.Parent.Name:find("Rob") then
                        root.CFrame = obj.Parent.CFrame
                        task.wait(5)
                    end
                end
            end
            task.wait(1)
        end
    end)
end)

BtnRow("Stop Auto Rob", T.Card, function()
    HackState.autoRob = false
    Toast("auto rob parado", true)
end)

Section("Blox Fruits / One Piece")

Toggle("Auto Farm Blox Fruits", false, function(v)
    HackState.autoBloxFarm = v
    if v then
        task.spawn(function()
            while HackState.autoBloxFarm do
                local root = hkRoot()
                local char = LocalPlayer.Character
                if root and char then
                    for _, obj in ipairs(Workspace:GetDescendants()) do
                        if obj:IsA("Model") and obj.Name:find("Fruit") then
                            local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                            if primary then
                                root.CFrame = primary.CFrame
                                task.wait(0.5)
                            end
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("auto farm blox fruits "..(v and "ligado" or "desligado"), v)
end, "gs_blox_farm")

Section("Adopt Me / Pets")

Toggle("Auto Collect Pets", false, function(v)
    HackState.autoCollectPets = v
    if v then
        task.spawn(function()
            while HackState.autoCollectPets do
                local root = hkRoot()
                if root then
                    for _, obj in ipairs(Workspace:GetDescendants()) do
                        if obj:IsA("Model") and (obj.Name:lower():find("pet") or obj.Name:lower():find("egg")) then
                            local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                            if primary and (primary.Position - root.Position).Magnitude < 100 then
                                root.CFrame = primary.CFrame
                                task.wait(0.3)
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("auto collect pets "..(v and "ligado" or "desligado"), v)
end, "gs_pets")

Section("Phantom Forces")

Toggle("No Recoil PF", false, function(v)
    HackState.pfNoRecoil = v
    Toast("phantom forces no recoil "..(v and "ligado" or "desligado"), v)
end, "gs_pf_recoil")

Toggle("Infinite Ammo PF", false, function(v)
    HackState.pfInfAmmo = v
    if v then
        task.spawn(function()
            while HackState.pfInfAmmo do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and remote.Name == "ReplicateWeapon" then
                        pcall(function()
                            remote:FireServer("SetAmmo", 999)
                        end)
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("PF infinite ammo "..(v and "ligado" or "desligado"), v)
end, "gs_pf_ammo")

Section("Tower Defense")

Toggle("Auto Place Towers", false, function(v)
    HackState.autoPlaceTowers = v
    if v then
        task.spawn(function()
            while HackState.autoPlaceTowers do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and (remote.Name:lower():find("place") or remote.Name:lower():find("tower")) then
                        pcall(function()
                            local root = hkRoot()
                            if root then
                                remote:FireServer(root.Position + Vector3.new(math.random(-10, 10), 0, math.random(-10, 10)))
                            end
                        end)
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("auto place towers "..(v and "ligado" or "desligado"), v)
end, "gs_td_place")

Toggle("Auto Upgrade Towers", false, function(v)
    HackState.autoUpgradeTowers = v
    if v then
        task.spawn(function()
            while HackState.autoUpgradeTowers do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and remote.Name:lower():find("upgrade") then
                        pcall(function()
                            remote:FireServer()
                        end)
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("auto upgrade towers "..(v and "ligado" or "desligado"), v)
end, "gs_td_upgrade")

Section("Murder Mystery / MM2")

Toggle("Show Roles (MM2)", false, function(v)
    HackState.mm2Roles = v
    if v then
        task.spawn(function()
            while HackState.mm2Roles do
                for _, player in ipairs(Players:GetPlayers()) do
                    if player.Character then
                        for _, tool in ipairs(player.Character:GetChildren()) do
                            if tool:IsA("Tool") and tool.Name == "Knife" then
                                print(player.Name, "is MURDERER")
                            elseif tool:IsA("Tool") and tool.Name == "Gun" then
                                print(player.Name, "is SHERIFF")
                            end
                        end
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("MM2 roles "..(v and "ligado - check output" or "desligado"), v)
end, "gs_mm2_roles")

Section("Anime / Luta")

Toggle("Auto Train Stats", false, function(v)
    HackState.autoTrain = v
    if v then
        task.spawn(function()
            while HackState.autoTrain do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and (remote.Name:lower():find("train") or remote.Name:lower():find("stat")) then
                        pcall(function()
                            remote:FireServer("Strength")
                            remote:FireServer("Speed")
                            remote:FireServer("Durability")
                        end)
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("auto train "..(v and "ligado" or "desligado"), v)
end, "gs_anime_train")

Note("Se o jogo nao estiver na lista, use os hacks universais.", 68)

end -- Por Jogo

--------------------------------------------------------------------------------
-- CONTEUDO EXPANDIDO
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- PAINEL DE COMANDOS ADMIN
--------------------------------------------------------------------------------
do
CurTab = Tab("Admin", 0, false)
Persist.Scope = "admin"

Section("Comandos de Administrador")
Note("Comandos de admin por nome de remote. Variam por jogo.", 52)

BtnRow("Dar Admin (varre os remotes)", T.Accent, function()
    Toast("tentando obter admin...", true)
    task.spawn(function()
        local methods = 0
        
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction") then
                if remote.Name:lower():find("admin") or remote.Name:lower():find("mod") or remote.Name:lower():find("owner") then
                    pcall(function()
                        if remote:IsA("RemoteEvent") then
                            remote:FireServer()
                            remote:FireServer(LocalPlayer)
                            remote:FireServer("grant", LocalPlayer)
                        else
                            remote:InvokeServer()
                            remote:InvokeServer(LocalPlayer)
                        end
                        methods = methods + 1
                    end)
                end
            end
        end
        
        if methods > 0 then
            Toast("disparei "..methods.." remotes de admin", true)
        else
            Toast("nenhum metodo encontrado", false)
        end
    end)
end)

Section("Kick & Ban")

do
    local row = Row(50)
    Label(row, "Kick Player", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local kickField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "username...")
    Button(row, "KICK", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local targetName = kickField.Text
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteEvent") and remote.Name:lower():find("kick") then
                pcall(function()
                    remote:FireServer(targetName)
                    remote:FireServer(Players:FindFirstChild(targetName))
                end)
            end
        end
        Toast("tentou kickar "..targetName, true)
    end)
end

do
    local row = Row(50)
    Label(row, "Ban Player", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local banField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "username...")
    Button(row, "BAN", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Card, function()
        local targetName = banField.Text
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteEvent") and remote.Name:lower():find("ban") then
                pcall(function()
                    remote:FireServer(targetName)
                    remote:FireServer(Players:FindFirstChild(targetName))
                end)
            end
        end
        Toast("tentou banir "..targetName, true)
    end)
end

Section("Controle do Servidor")

BtnRow("Shutdown Server (tenta)", T.Accent, function()
    Toast("tentando desligar servidor...", true)
    for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if remote:IsA("RemoteEvent") and (remote.Name:lower():find("shutdown") or remote.Name:lower():find("close")) then
            pcall(function()
                remote:FireServer()
            end)
        end
    end
end)

BtnRow("Crash Server (CUIDADO)", T.Card, function()
    Toast("tentando crashar servidor...", true)
    task.spawn(function()
        for i = 1, 1000 do
            for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                if remote:IsA("RemoteEvent") then
                    pcall(function()
                        remote:FireServer(string.rep("A", 10000))
                    end)
                end
            end
        end
    end)
end)

Section("Gerenciar Jogadores")

BtnRow("Bring All Players", T.Accent, function()
    local root = hkRoot()
    if root then
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteEvent") and (remote.Name:lower():find("bring") or remote.Name:lower():find("teleport")) then
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer then
                        pcall(function()
                            remote:FireServer(player, root.Position)
                        end)
                    end
                end
            end
        end
        Toast("bring disparado", true)
    end
end)

BtnRow("Freeze All Players", T.Card, function()
    for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if remote:IsA("RemoteEvent") and remote.Name:lower():find("freeze") then
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer then
                    pcall(function()
                        remote:FireServer(player, true)
                    end)
                end
            end
        end
    end
    Toast("freeze disparado", true)
end)

BtnRow("Kill All Players", T.Card, function()
    for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if remote:IsA("RemoteEvent") and remote.Name:lower():find("kill") then
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer then
                    pcall(function()
                        remote:FireServer(player)
                    end)
                end
            end
        end
    end
    Toast("kill disparado", true)
end)

Section("Manipulação do Jogo")

BtnRow("Change Time to Day", T.Accent, function()
    for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if remote:IsA("RemoteEvent") and (remote.Name:lower():find("time") or remote.Name:lower():find("lighting")) then
            pcall(function()
                remote:FireServer("Day")
                remote:FireServer(12)
            end)
        end
    end
    game:GetService("Lighting").ClockTime = 12
    Toast("dia disparado", true)
end)

BtnRow("Change Time to Night", T.Card, function()
    for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if remote:IsA("RemoteEvent") and (remote.Name:lower():find("time") or remote.Name:lower():find("lighting")) then
            pcall(function()
                remote:FireServer("Night")
                remote:FireServer(0)
            end)
        end
    end
    game:GetService("Lighting").ClockTime = 0
    Toast("noite disparada", true)
end)

do
    local row = Row(50)
    Label(row, "Give Item to All", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local itemField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "item name...")
    Button(row, "GIVE", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local itemName = itemField.Text
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteEvent") and (remote.Name:lower():find("give") or remote.Name:lower():find("item")) then
                for _, player in ipairs(Players:GetPlayers()) do
                    pcall(function()
                        remote:FireServer(player, itemName)
                        remote:FireServer(itemName, player)
                    end)
                end
            end
        end
        Toast("give disparado: "..itemName, true)
    end)
end

Note("Os botoes abaixo varrem os remotes do jogo procurando admin, kill e give.", 68)

end -- Admin tab

--------------------------------------------------------------------------------
-- SCRIPTS DA COMUNIDADE
--------------------------------------------------------------------------------
do
CurTab = Tab("Scripts", 0, false)
Persist.Scope = "scripts"

Section("Scripts Populares")
Note("Scripts de terceiros carregados por loadstring.", 52)

BtnRow("Infinite Yield", T.Accent, function()
    Toast("carregando Infinite Yield...", true)
    task.spawn(function()
        local ok = pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"))()
        end)
        if ok then
            Toast("Infinite Yield carregado", true)
        else
            Toast("falhou ao carregar IY", false)
        end
    end)
end)

BtnRow("Dex Explorer V4", T.Card, function()
    Toast("carregando Dex...", true)
    task.spawn(function()
        local ok = pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/infyiff/backup/main/dex.lua"))()
        end)
        if ok then
            Toast("Dex Explorer carregado", true)
        else
            Toast("falhou ao carregar Dex", false)
        end
    end)
end)

BtnRow("Remote Spy", T.Card, function()
    Toast("carregando Remote Spy...", true)
    task.spawn(function()
        local ok = pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/78n/SimpleSpy/main/SimpleSpySource.lua"))()
        end)
        if ok then
            Toast("Remote Spy carregado", true)
        else
            Toast("falhou ao carregar spy", false)
        end
    end)
end)

BtnRow("Hydroxide", T.Accent, function()
    Toast("carregando Hydroxide...", true)
    task.spawn(function()
        local ok = pcall(function()
            local owner = "Upbolt"
            local branch = "revision"
            local function loadModule(module)
                return loadstring(game:HttpGet(string.format("https://raw.githubusercontent.com/%s/Hydroxide/%s/%s.lua", owner, branch, module)))()
            end
            loadModule("init")
            loadModule("ui/main")
        end)
        if ok then
            Toast("Hydroxide carregado", true)
        else
            Toast("falhou ao carregar Hydroxide", false)
        end
    end)
end)

Section("Scripts por Jogo")

BtnRow("Arsenal Script", T.Accent, function()
    Toast("carregando Arsenal script...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/tbao143/thaibao/main/ArsenalSientc"))()
        end)
    end)
end)

BtnRow("Blox Fruits Script", T.Card, function()
    Toast("carregando Blox Fruits script...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/zReal-King/Blox-Fruits-Script/main/README.md"))()
        end)
    end)
end)

BtnRow("Jailbreak Script", T.Card, function()
    Toast("carregando Jailbreak script...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/RegularVynixu/Vynixius/main/Jailbreak/Script.lua"))()
        end)
    end)
end)

BtnRow("Pet Simulator X", T.Accent, function()
    Toast("carregando PSX script...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/Muhammad6196/Project-WD/main/Main.lua"))()
        end)
    end)
end)

BtnRow("Adopt Me Script", T.Card, function()
    Toast("carregando Adopt Me script...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/GamerScripter/Adopt-Me-Script/main/README.md"))()
        end)
    end)
end)

BtnRow("Phantom Forces", T.Card, function()
    Toast("carregando PF script...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/Mana42138/Phantom-Forces-ESP/main/main.lua"))()
        end)
    end)
end)

Section("Scripts Utilitários")

BtnRow("FPS Booster", T.Accent, function()
    Toast("aplicando FPS boost...", true)
    local decalsyeeted = true
    local g = game
    local w = g.Workspace
    local l = g.Lighting
    local t = w.Terrain
    t.WaterWaveSize = 0
    t.WaterWaveSpeed = 0
    t.WaterReflectance = 0
    t.WaterTransparency = 0
    l.GlobalShadows = false
    l.FogEnd = 9e9
    l.Brightness = 0
    settings().Rendering.QualityLevel = "Level01"
    for _, v in pairs(g:GetDescendants()) do
        if v:IsA("Part") or v:IsA("Union") or v:IsA("CornerWedgePart") or v:IsA("TrussPart") then
            v.Material = "Plastic"
            v.Reflectance = 0
        elseif v:IsA("Decal") or v:IsA("Texture") and decalsyeeted then
            v.Transparency = 1
        elseif v:IsA("ParticleEmitter") or v:IsA("Trail") then
            v.Lifetime = NumberRange.new(0)
        elseif v:IsA("Explosion") then
            v.BlastPressure = 1
            v.BlastRadius = 1
        elseif v:IsA("Fire") or v:IsA("SpotLight") or v:IsA("Smoke") or v:IsA("Sparkles") then
            v.Enabled = false
        elseif v:IsA("MeshPart") then
            v.Material = "Plastic"
            v.Reflectance = 0
            v.TextureID = ""
        end
    end
    for _, e in pairs(l:GetChildren()) do
        if e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("ColorCorrectionEffect") or e:IsA("BloomEffect") or e:IsA("DepthOfFieldEffect") then
            e.Enabled = false
        end
    end
    Toast("FPS boost aplicado", true)
end)

BtnRow("Unlock FPS", T.Card, function()
    setfpscap(999)
    Toast("FPS desbloqueado - cap 999", true)
end)

BtnRow("Dark Dex", T.Accent, function()
    Toast("carregando Dark Dex...", true)
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/Babyhamsta/RBLX_Scripts/main/Universal/BypassedDarkDexV3.lua"))()
        end)
    end)
end)

Section("Executor de Código")

do
    local row = Row(200)
    Label(row, "Execute Custom Script (URL ou codigo)", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -32, 0, 20))
    
    local scriptBox = Instance.new("TextBox")
    scriptBox.Size = UDim2.new(1, -32, 0, 140)
    scriptBox.Position = UDim2.fromOffset(16, 25)
    scriptBox.BackgroundColor3 = T.Field
    scriptBox.BorderColor3 = T.Accent
    scriptBox.BorderSizePixel = 1
    scriptBox.Text = ""
    scriptBox.TextColor3 = T.Text
    scriptBox.Font = Enum.Font.Code
    scriptBox.TextSize = 11
    scriptBox.TextXAlignment = Enum.TextXAlignment.Left
    scriptBox.TextYAlignment = Enum.TextYAlignment.Top
    scriptBox.PlaceholderText = "Cole URL ou codigo Lua aqui..."
    scriptBox.ClearTextOnFocus = false
    scriptBox.MultiLine = true
    scriptBox.TextWrapped = true
    scriptBox.Parent = row
    
    Button(row, "EXECUTAR", UDim2.new(0.5, -60, 1, -35), UDim2.fromOffset(120, 30), T.Accent, function()
        local code = scriptBox.Text
        if #code == 0 then
            Toast("codigo vazio", false)
            return
        end
        
        Toast("executando script...", true)
        task.spawn(function()
            local ok, err
            if code:match("^https?://") then
                ok, err = pcall(function()
                    loadstring(game:HttpGet(code))()
                end)
            else
                ok, err = pcall(function()
                    loadstring(code)()
                end)
            end
            
            if ok then
                Toast("script executado com sucesso", true)
            else
                Toast("erro: "..(tostring(err):sub(1, 40)), false)
                print("[SILK CORE] Script error:", err)
            end
        end)
    end)
end

Note("Roda na sua sessao. O que o servidor valida, o script nao contorna.", 68)

end -- Scripts

--------------------------------------------------------------------------------
-- AJUSTES AVANCADOS
--------------------------------------------------------------------------------
do
CurTab = Tab("Ajustes", 0, false)
Persist.Scope = "settings"

Section("Configuracoes Gerais")
Note("Ajustes e preferencias do menu.", 52)

Toggle("Save Settings on Exit", true, function(v)
    HackState.autoSave = v
    Toast("auto save "..(v and "ligado" or "desligado"), v)
end, "cfg_autosave")

Toggle("Play Notification Sounds", true, function(v)
    HackState.notifSounds = v
    Toast("notification sounds "..(v and "ligado" or "desligado"), v)
end, "cfg_sounds")

Toggle("Verbose Logging", false, function(v)
    HackState.verboseLog = v
    Toast("verbose logging "..(v and "ligado - check output" or "desligado"), v)
end, "cfg_verbose")

Slider("UI Scale", 0.7, 1.5, 1, "%.1fx", function(v)
    HackState.uiScale = v
    if GUI then
        GUI.UIScale.Scale = v
    end
end, "cfg_scale")

Slider("UI Transparency", 0, 0.5, 0, "%.2f", function(v)
    HackState.uiTransparency = v
    if Main then
        Main.BackgroundTransparency = 0.1 + v
    end
end, "cfg_transparency")

Section("Desempenho")

Toggle("Reduce Animations", false, function(v)
    HackState.reduceAnims = v
    Toast("reduce animations "..(v and "ligado" or "desligado"), v)
end, "cfg_noanim")

Toggle("Low Memory Mode", false, function(v)
    HackState.lowMemory = v
    if v then
        settings().Rendering.QualityLevel = "Level01"
        settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01
    else
        settings().Rendering.QualityLevel = "Automatic"
        settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level02
    end
    Toast("low memory mode "..(v and "ligado" or "desligado"), v)
end, "cfg_lowmem")

Section("Tema & Cores")

do
    local colors = {
        {name = "Purple (default)", accent = Color3.fromRGB(138, 43, 226)},
        {name = "Blue", accent = Color3.fromRGB(0, 150, 255)},
        {name = "Red", accent = Color3.fromRGB(255, 50, 50)},
        {name = "Green", accent = Color3.fromRGB(50, 255, 100)},
        {name = "Orange", accent = Color3.fromRGB(255, 150, 0)},
        {name = "Pink", accent = Color3.fromRGB(255, 100, 200)},
    }
    
    for i, colorData in ipairs(colors) do
        BtnRow(colorData.name, colorData.accent, function()
            T.Accent = colorData.accent
            Toast("theme alterado para "..colorData.name, true)
            
            if GUI then
                for _, obj in ipairs(GUI:GetDescendants()) do
                    if obj:IsA("Frame") or obj:IsA("TextButton") then
                        if obj.BackgroundColor3 == T.Accent or obj.Name:find("Accent") then
                            obj.BackgroundColor3 = colorData.accent
                        end
                    end
                end
            end
        end)
    end
end

Section("Gerenciar Dados")

BtnRow("Export All Settings", T.Accent, function()
    Toast("exportando configuracoes...", true)
    task.spawn(function()
        local data = game:GetService("HttpService"):JSONEncode(HackState)
        setclipboard(data)
        Toast("configuracoes copiadas para clipboard", true)
    end)
end)

BtnRow("Clear All Saved Data", T.Card, function()
    HackState = {
        speedVal = 40,
        jumpVal = 80,
        flySpeed = 50,
        waypoints = {},
    }
    Toast("dados limpos - restart necessario", true)
end)

BtnRow("Reset to Defaults", T.Card, function()
    for key, _ in pairs(HackState) do
        HackState[key] = nil
    end
    HackState.speedVal = 40
    HackState.jumpVal = 80
    HackState.flySpeed = 50
    Toast("resetado para padroes", true)
end)

Section("Debug & Info")

BtnRow("Print HackState (output)", T.Accent, function()
    print("========== HACKSTATE ==========")
    for key, value in pairs(HackState) do
        print(key, "=", tostring(value))
    end
    print("===============================")
    Toast("HackState printado no output", true)
end)

BtnRow("Print Executor Info", T.Card, function()
    print("========== EXECUTOR INFO ==========")
    print("Executor:", identifyexecutor())
    print("getgenv:", type(getgenv))
    print("getsenv:", type(getsenv))
    print("getrawmetatable:", type(getrawmetatable))
    print("hookfunction:", type(hookfunction))
    print("newcclosure:", type(newcclosure))
    print("isnetworkowner:", type(isnetworkowner))
    print("setfpscap:", type(setfpscap))
    print("setclipboard:", type(setclipboard))
    print("===================================")
    Toast("executor info no output", true)
end)

BtnRow("Check Anticheat", T.Accent, function()
    Toast("verificando anticheat...", true)
    task.spawn(function()
        local detected = {}
        
        for _, obj in ipairs(game:GetDescendants()) do
            if obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
                local source = ""
                pcall(function()
                    source = decompile(obj)
                end)
                
                if source:lower():find("anticheat") or source:lower():find("anti") and source:lower():find("cheat") then
                    table.insert(detected, obj:GetFullName())
                end
            end
        end
        
        print("========== ANTICHEAT SCAN ==========")
        if #detected == 0 then
            print("Nenhum anticheat detectado")
        else
            for _, path in ipairs(detected) do
                print("Possivel anticheat:", path)
            end
        end
        print("====================================")
        Toast("scan completo - "..#detected.." encontrados", true)
    end)
end)

Section("Sobre")

Note("SILK CORE v2.1", 48)
Note("executor: " .. tostring(execName), 40)
Note("place " .. tostring(game.PlaceId) .. "   job " .. tostring(game.JobId), 40)

BtnRow("Copiar o link do Discord", T.Accent, function()
    setclipboard("https://discord.gg/silkcore")
    Toast("link copiado", true)
end)

end -- Ajustes

--------------------------------------------------------------------------------
-- EXTRAS DO MENU
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- ANTI-DETECCAO & SEGURANCA
--------------------------------------------------------------------------------
do
CurTab = Tab("Anti-Detecção", 0, false)
Persist.Scope = "antidetect"

Section("Protecao Contra Deteccao")
Note("Camadas de protecao local contra deteccao.", 52)

Toggle("Anti-Detect Master Switch", true, function(v)
    HackState.antiDetectMaster = v
    Toast("anti-detect master "..(v and "ligado" or "desligado"), v)
end, "ad_master")

Toggle("Hide Script Instances", true, function(v)
    HackState.hideScripts = v
    if v then
        task.spawn(function()
            while HackState.hideScripts do
                for _, obj in ipairs(game:GetDescendants()) do
                    if obj:IsA("LocalScript") and obj.Name:find("SilkCore") then
                        obj.Name = game:GetService("HttpService"):GenerateGUID(false)
                    end
                end
                task.wait(5)
            end
        end)
    end
    Toast("hide scripts "..(v and "ligado" or "desligado"), v)
end, "ad_hidescripts")

Toggle("Spoof User Agent", true, function(v)
    HackState.spoofUA = v
    Toast("spoof user agent "..(v and "ligado" or "desligado"), v)
end, "ad_ua")

Toggle("Random Movement Jitter", false, function(v)
    HackState.moveJitter = v
    if v then
        task.spawn(function()
            while HackState.moveJitter do
                local root = hkRoot()
                if root and (HackState.speed or HackState.fly or HackState.noclip) then
                    local jitter = Vector3.new(
                        math.random(-100, 100) / 1000,
                        math.random(-100, 100) / 1000,
                        math.random(-100, 100) / 1000
                    )
                    root.CFrame = root.CFrame * CFrame.new(jitter)
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("movement jitter "..(v and "ligado - parece mais humano" or "desligado"), v)
end, "ad_jitter")

Toggle("Anti-Screenshot", false, function(v)
    HackState.antiScreenshot = v
    if v then
        task.spawn(function()
            while HackState.antiScreenshot do
                for _, obj in ipairs(LocalPlayer:GetGuiDescendantsOfClass("ScreenGui")) do
                    if obj.Name:find("Screenshot") or obj.Name:find("Capture") then
                        obj.Enabled = false
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("anti-screenshot "..(v and "ligado" or "desligado"), v)
end, "ad_noscreen")

Toggle("Spoof Network Owner", false, function(v)
    HackState.spoofNetwork = v
    Toast("spoof network owner "..(v and "ligado" or "desligado"), v)
end, "ad_network")

Section("Técnicas de Bypass")

Toggle("Bypass Adonis Anti-Cheat", false, function(v)
    HackState.bypassAdonis = v
    if v then
        for _, obj in ipairs(game:GetDescendants()) do
            if obj.Name == "_G" or obj.Name == "Adonis" or obj.Name == "Server" then
                if obj:IsA("ModuleScript") then
                    pcall(function()
                        obj:Destroy()
                    end)
                end
            end
        end
        Toast("tentou bypass Adonis", true)
    end
end, "ad_adonis")

Toggle("Bypass Basic Anti-Cheat", false, function(v)
    HackState.bypassBasic = v
    if v then
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        local oldNamecall = mt.__namecall
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" or method == "InvokeServer" then
                local args = {...}
                if tostring(self):lower():find("anticheat") or tostring(self):lower():find("detected") then
                    return
                end
            end
            return oldNamecall(self, ...)
        end)
        setreadonly(mt, true)
        Toast("bypass basico ativado", true)
    end
end, "ad_basic")

Toggle("Whitelist Bypass Attempt", false, function(v)
    HackState.bypassWhitelist = v
    if v then
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteFunction") and remote.Name:lower():find("whitelist") then
                pcall(function()
                    hookfunction(remote.OnClientInvoke, function()
                        return true
                    end)
                end)
            end
        end
        Toast("tentou bypass whitelist", true)
    end
end, "ad_whitelist")

Section("Registro & Monitoramento")

Toggle("Log Remote Calls", false, function(v)
    HackState.logRemotes = v
    if v then
        task.spawn(function()
            local mt = getrawmetatable(game)
            setreadonly(mt, false)
            local oldNamecall = mt.__namecall
            mt.__namecall = newcclosure(function(self, ...)
                local method = getnamecallmethod()
                if HackState.logRemotes then
                    if method == "FireServer" then
                        print("[SILK LOG] FireServer:", self:GetFullName(), ...)
                    elseif method == "InvokeServer" then
                        print("[SILK LOG] InvokeServer:", self:GetFullName(), ...)
                    end
                end
                return oldNamecall(self, ...)
            end)
            setreadonly(mt, true)
        end)
    end
    Toast("log remotes "..(v and "ligado - check output" or "desligado"), v)
end, "ad_logremote")

Toggle("Monitor Script Activity", false, function(v)
    HackState.monitorScripts = v
    if v then
        task.spawn(function()
            while HackState.monitorScripts do
                local scriptCount = 0
                for _, obj in ipairs(game:GetDescendants()) do
                    if obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
                        scriptCount = scriptCount + 1
                    end
                end
                if HackState.lastScriptCount and scriptCount > HackState.lastScriptCount + 5 then
                    print("[SILK ALERT] Novo script detectado! Count:", scriptCount)
                end
                HackState.lastScriptCount = scriptCount
                task.wait(2)
            end
        end)
    end
    Toast("monitor scripts "..(v and "ligado" or "desligado"), v)
end, "ad_monitor")

BtnRow("Scan for Anti-Cheat", T.Accent, function()
    Toast("escaneando...", true)
    task.spawn(function()
        local found = {}
        for _, obj in ipairs(game:GetDescendants()) do
            if obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
                if obj.Name:lower():find("anti") or obj.Name:lower():find("cheat") or obj.Name:lower():find("detect") then
                    table.insert(found, obj:GetFullName())
                end
            end
        end
        print("========== ANTI-CHEAT SCAN ==========")
        for _, path in ipairs(found) do
            print(path)
        end
        print("Total encontrado:", #found)
        print("=====================================")
        Toast("scan completo - "..#found.." suspeitos", true)
    end)
end)

Note("Protecao client-side. Nao cobre o que o servidor valida sozinho.", 68)

end -- Anti-Deteccao

--------------------------------------------------------------------------------
-- MACROS & AUTOMACAO
--------------------------------------------------------------------------------
do
CurTab = Tab("Macros", 0, false)
Persist.Scope = "macros"

Section("Sistema de Macros")
Note("Grava e repete sequencias de acoes.", 52)

HackState.macros = HackState.macros or {}
HackState.recordingMacro = false
HackState.currentMacro = {}

Toggle("Record Macro", false, function(v)
    HackState.recordingMacro = v
    if v then
        HackState.currentMacro = {}
        HackState.macroStartTime = tick()
        Toast("gravando macro...", true)
        
        HackState.macroConns = HackState.macroConns or {}
        
        table.insert(HackState.macroConns, UserInputService.InputBegan:Connect(function(input, gpe)
            if not gpe and HackState.recordingMacro then
                table.insert(HackState.currentMacro, {
                    type = "input",
                    time = tick() - HackState.macroStartTime,
                    keyCode = input.KeyCode,
                    userInputType = input.UserInputType
                })
            end
        end))
        
        table.insert(HackState.macroConns, RunService.Heartbeat:Connect(function()
            if HackState.recordingMacro then
                local root = hkRoot()
                if root then
                    table.insert(HackState.currentMacro, {
                        type = "position",
                        time = tick() - HackState.macroStartTime,
                        cframe = root.CFrame
                    })
                end
            end
        end))
    else
        for _, conn in ipairs(HackState.macroConns or {}) do
            conn:Disconnect()
        end
        HackState.macroConns = {}
        Toast("gravacao parada - "..#HackState.currentMacro.." acoes", true)
    end
end, "macro_record")

do
    local row = Row(50)
    Label(row, "Nome do Macro", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local macroNameField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "nome...")
    Button(row, "SALVAR", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local name = macroNameField.Text
        if #name > 0 and #HackState.currentMacro > 0 then
            HackState.macros[name] = HackState.currentMacro
            Toast("macro '"..name.."' salvo com "..#HackState.currentMacro.." acoes", true)
        else
            Toast("nome vazio ou macro vazio", false)
        end
    end)
end

do
    local row = Row(50)
    Label(row, "Reproduzir Macro", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local macroPlayField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "nome...")
    Button(row, "PLAY", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Card, function()
        local name = macroPlayField.Text
        if HackState.macros[name] then
            Toast("reproduzindo macro '"..name.."'...", true)
            task.spawn(function()
                local macro = HackState.macros[name]
                local startTime = tick()
                for _, action in ipairs(macro) do
                    local waitTime = action.time - (tick() - startTime)
                    if waitTime > 0 then
                        task.wait(waitTime)
                    end
                    
                    if action.type == "input" then
                        local vim = game:GetService("VirtualInputManager")
                        vim:SendKeyEvent(true, action.keyCode, false, game)
                        task.wait(0.05)
                        vim:SendKeyEvent(false, action.keyCode, false, game)
                    elseif action.type == "position" then
                        local root = hkRoot()
                        if root then
                            root.CFrame = action.cframe
                        end
                    end
                end
                Toast("macro finalizado", true)
            end)
        else
            Toast("macro nao encontrado", false)
        end
    end)
end

Section("Macros Pre-Definidos")

BtnRow("Macro: Farm Loop", T.Accent, function()
    Toast("iniciando farm loop...", true)
    HackState.farmLoop = true
    task.spawn(function()
        while HackState.farmLoop do
            local root = hkRoot()
            if root then
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ClickDetector") then
                        fireclickdetector(obj)
                    end
                    if obj:IsA("ProximityPrompt") then
                        fireproximityprompt(obj)
                    end
                end
            end
            task.wait(1)
        end
    end)
end)

BtnRow("Stop Farm Loop", T.Card, function()
    HackState.farmLoop = false
    Toast("farm loop parado", true)
end)

BtnRow("Macro: Circle Movement", T.Accent, function()
    Toast("movimento circular iniciado", true)
    HackState.circleMove = true
    task.spawn(function()
        local angle = 0
        local center = hkRoot().Position
        while HackState.circleMove do
            local root = hkRoot()
            if root then
                local x = center.X + math.cos(angle) * 20
                local z = center.Z + math.sin(angle) * 20
                root.CFrame = CFrame.new(x, center.Y, z)
                angle = angle + 0.1
            end
            task.wait(0.05)
        end
    end)
end)

BtnRow("Stop Circle Movement", T.Card, function()
    HackState.circleMove = false
    Toast("movimento circular parado", true)
end)

BtnRow("Listar Macros (output)", T.Card, function()
    print("========== MACROS SALVOS ==========")
    for name, macro in pairs(HackState.macros or {}) do
        print(name, "- acoes:", #macro)
    end
    print("===================================")
    Toast("macros listados no output", true)
end)

Note("Grave uma sequencia uma vez e rode em loop.", 68)

end -- Macros tab

--------------------------------------------------------------------------------
-- REDE & SERVIDOR
--------------------------------------------------------------------------------
do
CurTab = Tab("Rede", 0, false)
Persist.Scope = "network"

Section("Informacoes de Rede")
Note("Conexoes, remotes e troca de servidor.", 52)

BtnRow("Show Network Stats", T.Accent, function()
    local stats = game:GetService("Stats").Network
    print("========== NETWORK STATS ==========")
    print("Data Received:", stats.DataReceivedKBps.Value, "KB/s")
    print("Data Sent:", stats.DataSentKBps.Value, "KB/s")
    print("Physics Receive:", stats.PhysicsReceiveKBps.Value, "KB/s")
    print("Physics Send:", stats.PhysicsSendKBps.Value, "KB/s")
    print("===================================")
    Toast("network stats no output", true)
end)

Toggle("Monitor Network Traffic", false, function(v)
    HackState.monitorNetwork = v
    if v then
        task.spawn(function()
            while HackState.monitorNetwork do
                local stats = game:GetService("Stats").Network
                print(string.format("[NETWORK] RX: %.2f KB/s | TX: %.2f KB/s",
                    stats.DataReceivedKBps.Value,
                    stats.DataSentKBps.Value
                ))
                task.wait(2)
            end
        end)
    end
    Toast("network monitor "..(v and "ligado" or "desligado"), v)
end, "net_monitor")

Section("Informação do Servidor")

BtnRow("Get Server Region", T.Accent, function()
    local regionData = {
        ["us-east"] = "United States East",
        ["us-west"] = "United States West",
        ["eu-west"] = "Europe West",
        ["eu-central"] = "Europe Central",
        ["asia-east"] = "Asia East",
        ["asia-southeast"] = "Asia Southeast"
    }
    
    local jobId = game.JobId
    local region = "Unknown"
    
    for key, name in pairs(regionData) do
        if jobId:sub(1, #key) == key then
            region = name
            break
        end
    end
    
    print("========== SERVER INFO ==========")
    print("Job ID:", jobId)
    print("Region:", region)
    print("Place ID:", game.PlaceId)
    print("Players:", #Players:GetPlayers().."/"..Players.MaxPlayers)
    print("=================================")
    
    Toast("regiao do servidor: "..region, true)
end)

BtnRow("Copy Job ID", T.Card, function()
    setclipboard(game.JobId)
    Toast("job ID copiado", true)
end)

BtnRow("Server Lag Test", T.Accent, function()
    Toast("testando lag...", true)
    task.spawn(function()
        local start = tick()
        local pings = {}
        
        for i = 1, 10 do
            local pingStart = tick()
            game:GetService("ReplicatedStorage"):WaitForChild("DefaultChatSystemChatEvents")
            table.insert(pings, (tick() - pingStart) * 1000)
            task.wait(0.1)
        end
        
        local avgPing = 0
        for _, ping in ipairs(pings) do
            avgPing = avgPing + ping
        end
        avgPing = avgPing / #pings
        
        print("========== LAG TEST ==========")
        print("Average Ping:", math.floor(avgPing), "ms")
        print("Min Ping:", math.floor(math.min(unpack(pings))), "ms")
        print("Max Ping:", math.floor(math.max(unpack(pings))), "ms")
        print("==============================")
        
        Toast("ping medio: "..math.floor(avgPing).."ms", true)
    end)
end)

Section("Troca de Servidor")

BtnRow("Hop to Best Server", T.Accent, function()
    Toast("procurando melhor servidor...", true)
    task.spawn(function()
        pcall(function()
            local servers = game:GetService("HttpService"):JSONDecode(
                game:HttpGet("https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Desc&limit=100")
            )
            
            if servers and servers.data then
                local bestServer = nil
                local bestScore = -1
                
                for _, server in ipairs(servers.data) do
                    if server.id ~= game.JobId then
                        local score = server.playing
                        local capacity = server.maxPlayers
                        local ratio = score / capacity
                        
                        if ratio > 0.5 and ratio < 0.9 and score > bestScore then
                            bestServer = server
                            bestScore = score
                        end
                    end
                end
                
                if bestServer then
                    Toast("encontrado servidor com "..bestServer.playing.." players", true)
                    task.wait(1)
                    game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, bestServer.id, LocalPlayer)
                else
                    Toast("nenhum servidor melhor encontrado", false)
                end
            end
        end)
    end)
end)

BtnRow("Hop to Smallest Server", T.Card, function()
    Toast("procurando servidor vazio...", true)
    task.spawn(function()
        pcall(function()
            local servers = game:GetService("HttpService"):JSONDecode(
                game:HttpGet("https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100")
            )
            
            if servers and servers.data then
                for _, server in ipairs(servers.data) do
                    if server.id ~= game.JobId and server.playing < server.maxPlayers then
                        Toast("encontrado servidor com "..server.playing.." players", true)
                        task.wait(1)
                        game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
                        return
                    end
                end
            end
        end)
    end)
end)

BtnRow("Hop to Full Server (queue)", T.Card, function()
    Toast("procurando servidor cheio...", true)
    task.spawn(function()
        pcall(function()
            local servers = game:GetService("HttpService"):JSONDecode(
                game:HttpGet("https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Desc&limit=100")
            )
            
            if servers and servers.data then
                for _, server in ipairs(servers.data) do
                    if server.playing == server.maxPlayers then
                        Toast("tentando entrar em servidor cheio", true)
                        task.wait(1)
                        game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
                        return
                    end
                end
            end
        end)
    end)
end)

Section("Flood de Remotes")

Toggle("Spam RemoteEvents", false, function(v)
    HackState.spamRemotes = v
    if v then
        task.spawn(function()
            while HackState.spamRemotes do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") then
                        pcall(function()
                            remote:FireServer()
                        end)
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("spam remotes "..(v and "ligado - CUIDADO!" or "desligado"), v)
end, "net_spam")

Note("Monitor de conexoes e busca de servidor por ping.", 68)

end -- Rede

--------------------------------------------------------------------------------
-- ANIMACOES & EMOTES
--------------------------------------------------------------------------------
do
CurTab = Tab("Animações", 0, false)
Persist.Scope = "anims"

Section("Sistema de Animacoes")
Note("Toca animacoes por ID e ajusta a velocidade.", 52)

local customAnims = {
    {name = "Zombie", id = "rbxassetid://616163682"},
    {name = "Levitate", id = "rbxassetid://313762630"},
    {name = "Astronaut", id = "rbxassetid://891621366"},
    {name = "Ninja", id = "rbxassetid://656117878"},
    {name = "Knight", id = "rbxassetid://657564596"},
    {name = "Mage", id = "rbxassetid://707742142"},
    {name = "Pirate", id = "rbxassetid://750781874"},
    {name = "Robot", id = "rbxassetid://616095330"},
    {name = "Vampire", id = "rbxassetid://1083445855"},
    {name = "Werewolf", id = "rbxassetid://1083216690"},
}

for _, animData in ipairs(customAnims) do
    BtnRow("Play: "..animData.name, T.Accent, function()
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                local anim = Instance.new("Animation")
                anim.AnimationId = animData.id
                local track = hum:LoadAnimation(anim)
                track:Play()
                Toast("animacao "..animData.name.." tocando", true)
            end
        end
    end)
end

Section("Controle de Animacoes")

Toggle("Stop All Animations", false, function(v)
    HackState.noAnims = v
    if v then
        task.spawn(function()
            while HackState.noAnims do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
                            track:Stop()
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("stop all animations "..(v and "ligado" or "desligado"), v)
end, "anim_stopall")

Slider("Animation Speed", 0.1, 5, 1, "x%.1f", function(v)
    HackState.animSpeed = v
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
                track:AdjustSpeed(v)
            end
        end
    end
end, "anim_speed")

Toggle("Freeze Animation", false, function(v)
    HackState.freezeAnim = v
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
                track:AdjustSpeed(v and 0 or 1)
            end
        end
    end
    Toast("freeze animation "..(v and "ligado" or "desligado"), v)
end, "anim_freeze")

Section("Emotes Customizados")

do
    local row = Row(50)
    Label(row, "Animation ID", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.3, 0, 1, 0))
    local animIdField = Field(row, UDim2.new(0.32, 0, 0.5, -15), UDim2.new(0.4, 0, 0, 30), "rbxassetid://...")
    Button(row, "PLAY", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local animId = animIdField.Text
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                local anim = Instance.new("Animation")
                anim.AnimationId = animId
                local track = hum:LoadAnimation(anim)
                track:Play()
                Toast("tocando animacao customizada", true)
            end
        end
    end)
end

BtnRow("List Current Animations", T.Card, function()
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            print("========== ANIMATIONS ==========")
            for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
                print("Animation:", track.Animation.AnimationId)
                print("Speed:", track.Speed)
                print("Time:", track.TimePosition)
                print("---")
            end
            print("================================")
            Toast("animations listadas no output", true)
        end
    end
end)

Note("IDs do catalogo Roblox. A animacao roda no seu personagem.", 68)

end -- Animacoes

--------------------------------------------------------------------------------
-- EXTRAS DO MENU
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- MINI-JOGOS
--------------------------------------------------------------------------------
do
CurTab = Tab("Mini-Jogos", 0, false)
Persist.Scope = "minigames"

Section("Mini-Jogos Integrados")
Note("Efeitos e brincadeiras dentro do mapa.", 52)

BtnRow("Tic-Tac-Toe vs AI", T.Accent, function()
    Toast("abrindo tic-tac-toe...", true)
    -- jogo da velha fica pro proximo build
    print("[SILK] Tic-Tac-Toe iniciado")
end)

BtnRow("Memory Card Game", T.Card, function()
    Toast("memory game carregando...", true)
    print("[SILK] Memory game iniciado")
end)

BtnRow("Simon Says", T.Card, function()
    Toast("Simon Says carregando...", true)
    print("[SILK] Simon Says iniciado")
end)

Section("Vitrine de Partículas")

BtnRow("Fireworks Show", T.Accent, function()
    Toast("fogos de artificio!", true)
    task.spawn(function()
        for i = 1, 20 do
            local root = hkRoot()
            if root then
                local firework = Instance.new("Part")
                firework.Size = Vector3.new(1, 1, 1)
                firework.Anchored = true
                firework.CanCollide = false
                firework.Material = Enum.Material.Neon
                firework.Color = Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
                firework.Position = root.Position + Vector3.new(math.random(-20, 20), math.random(20, 40), math.random(-20, 20))
                firework.Parent = Workspace
                
                local spark = Instance.new("Sparkles")
                spark.Parent = firework
                
                task.delay(2, function()
                    firework:Destroy()
                end)
            end
            task.wait(0.2)
        end
    end)
end)

BtnRow("Rainbow Trail", T.Card, function()
    HackState.rainbowTrail = not HackState.rainbowTrail
    if HackState.rainbowTrail then
        Toast("rainbow trail ativado", true)
        task.spawn(function()
            while HackState.rainbowTrail do
                local root = hkRoot()
                if root then
                    local part = Instance.new("Part")
                    part.Size = Vector3.new(2, 2, 2)
                    part.Anchored = true
                    part.CanCollide = false
                    part.Material = Enum.Material.Neon
                    part.Color = Color3.fromHSV(tick() % 5 / 5, 1, 1)
                    part.Transparency = 0.5
                    part.CFrame = root.CFrame
                    part.Parent = Workspace
                    
                    task.delay(1, function()
                        for i = 0, 1, 0.1 do
                            part.Transparency = 0.5 + (i * 0.5)
                            task.wait(0.05)
                        end
                        part:Destroy()
                    end)
                end
                task.wait(0.1)
            end
        end)
    else
        Toast("rainbow trail desativado", true)
    end
end)

Section("Música & Som")

local songs = {
    {name = "Megalovania", id = "2633522900"},
    {name = "Astronomia (Coffin Dance)", id = "4816849952"},
    {name = "Rick Roll", id = "6478684707"},
    {name = "Giorno Theme", id = "5100894416"},
    {name = "Caramelldansen", id = "2643543544"},
    {name = "Nyan Cat", id = "130768299"},
}

for _, song in ipairs(songs) do
    BtnRow("Play: "..song.name, T.Accent, function()
        local sound = Instance.new("Sound")
        sound.SoundId = "rbxassetid://"..song.id
        sound.Volume = 0.5
        sound.Looped = false
        sound.Parent = Workspace
        sound:Play()
        HackState.currentSound = sound
        Toast("tocando "..song.name, true)
    end)
end

BtnRow("Stop Music", T.Card, function()
    if HackState.currentSound and HackState.currentSound.Parent then
        HackState.currentSound:Stop()
        HackState.currentSound:Destroy()
        Toast("musica parada", true)
    end
end)

do
    local row = Row(50)
    Label(row, "Custom Song ID", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local songField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "soundid...")
    Button(row, "PLAY", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local songId = songField.Text
        if #songId > 0 then
            local sound = Instance.new("Sound")
            sound.SoundId = "rbxassetid://"..songId
            sound.Volume = 0.5
            sound.Looped = true
            sound.Parent = Workspace
            sound:Play()
            HackState.currentSound = sound
            Toast("tocando song ID "..songId, true)
        end
    end)
end

Note("Particulas, som e algumas brincadeiras no mapa.", 68)

end -- Mini-Jogos

--------------------------------------------------------------------------------
-- FERRAMENTAS AVANCADAS
--------------------------------------------------------------------------------
do
CurTab = Tab("Avançado", 0, false)
Persist.Scope = "advtools"

Section("Ferramentas Avancadas")
Note("Ferramentas de analise pra quem mexe com Lua.", 52)

BtnRow("Decompile LocalScripts", T.Accent, function()
    Toast("decompilando scripts...", true)
    task.spawn(function()
        local count = 0
        for _, obj in ipairs(game:GetDescendants()) do
            if obj:IsA("LocalScript") then
                pcall(function()
                    local source = decompile(obj)
                    print("========== "..obj:GetFullName().." ==========")
                    print(source)
                    print("==========================================")
                    count = count + 1
                end)
            end
        end
        Toast("decompilados "..count.." scripts", true)
    end)
end)

BtnRow("Find All Remotes", T.Card, function()
    local remotes = {}
    for _, obj in ipairs(game:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") or obj:IsA("BindableEvent") or obj:IsA("BindableFunction") then
            table.insert(remotes, obj:GetFullName())
        end
    end
    print("========== REMOTES ("..#remotes..") ==========")
    for _, path in ipairs(remotes) do
        print(path)
    end
    print("==========================================")
    Toast("encontrados "..#remotes.." remotes", true)
end)

BtnRow("Scan for Vulnerabilities", T.Accent, function()
    Toast("escaneando vulnerabilidades...", true)
    task.spawn(function()
        local vulns = {}
        
        for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction") then
                if remote.Name:lower():find("buy") or 
                   remote.Name:lower():find("purchase") or
                   remote.Name:lower():find("give") or
                   remote.Name:lower():find("admin") then
                    table.insert(vulns, remote:GetFullName())
                end
            end
        end
        
        print("========== VULNERABILIDADES ==========")
        for _, vuln in ipairs(vulns) do
            print(vuln)
        end
        print("Total:", #vulns)
        print("======================================")
        Toast("scan completo - "..#vulns.." suspeitos", true)
    end)
end)

Section("Memória & Desempenho")

BtnRow("Garbage Collection", T.Accent, function()
    Toast("limpando memoria...", true)
    local before = collectgarbage("count")
    collectgarbage("collect")
    local after = collectgarbage("count")
    local freed = math.floor(before - after)
    Toast("liberados "..freed.." KB", true)
    print("[SILK] Memoria liberada:", freed, "KB")
end)

BtnRow("Memory Usage Report", T.Card, function()
    local mem = collectgarbage("count")
    print("========== MEMORY REPORT ==========")
    print("Memory Used:", math.floor(mem), "KB")
    print("Memory Used:", math.floor(mem / 1024), "MB")
    
    local categories = {
        Scripts = 0,
        Parts = 0,
        Guis = 0,
        Sounds = 0,
        Other = 0
    }
    
    for _, obj in ipairs(game:GetDescendants()) do
        if obj:IsA("LuaSourceContainer") then
            categories.Scripts = categories.Scripts + 1
        elseif obj:IsA("BasePart") then
            categories.Parts = categories.Parts + 1
        elseif obj:IsA("GuiObject") then
            categories.Guis = categories.Guis + 1
        elseif obj:IsA("Sound") then
            categories.Sounds = categories.Sounds + 1
        else
            categories.Other = categories.Other + 1
        end
    end
    
    print("--- Instance Counts ---")
    for category, count in pairs(categories) do
        print(category..":", count)
    end
    print("===================================")
    Toast("memory report no output", true)
end)

Section("Scripts Avançados")

BtnRow("Hook All Functions", T.Accent, function()
    Toast("hooking functions...", true)
    task.spawn(function()
        local hooked = 0
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        
        local oldIndex = mt.__index
        local oldNamecall = mt.__namecall
        
        mt.__index = newcclosure(function(self, key)
            if HackState.verboseLog then
                print("[HOOK __index]", tostring(self), key)
            end
            return oldIndex(self, key)
        end)
        
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if HackState.verboseLog then
                print("[HOOK __namecall]", tostring(self), method, ...)
            end
            return oldNamecall(self, ...)
        end)
        
        setreadonly(mt, true)
        Toast("metamethods hooked", true)
    end)
end)

do
    local row = Row(100)
    Label(row, "Execute Lua Code", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(1, -32, 0, 20))
    
    local codeBox = Instance.new("TextBox")
    codeBox.Size = UDim2.new(1, -32, 0, 50)
    codeBox.Position = UDim2.fromOffset(16, 25)
    codeBox.BackgroundColor3 = T.Field
    codeBox.BorderColor3 = T.Accent
    codeBox.BorderSizePixel = 1
    codeBox.Text = ""
    codeBox.TextColor3 = T.Text
    codeBox.Font = Enum.Font.Code
    codeBox.TextSize = 11
    codeBox.TextXAlignment = Enum.TextXAlignment.Left
    codeBox.TextYAlignment = Enum.TextYAlignment.Top
    codeBox.PlaceholderText = "print('silk')"
    codeBox.ClearTextOnFocus = false
    codeBox.MultiLine = true
    codeBox.TextWrapped = true
    codeBox.Parent = row
    
    Button(row, "RUN", UDim2.new(0.5, -40, 1, -35), UDim2.fromOffset(80, 30), T.Accent, function()
        local code = codeBox.Text
        if #code > 0 then
            local ok, result = pcall(function()
                return loadstring(code)()
            end)
            if ok then
                Toast("codigo executado", true)
                if result then
                    print("[SILK RESULT]", result)
                end
            else
                Toast("erro: "..(tostring(result):sub(1, 30)), false)
                print("[SILK ERROR]", result)
            end
        end
    end)
end

Section("Explorador de Instâncias")

BtnRow("List Workspace Children", T.Card, function()
    print("========== WORKSPACE ==========")
    for _, obj in ipairs(Workspace:GetChildren()) do
        print(obj.Name, "-", obj.ClassName)
    end
    print("===============================")
    Toast("workspace listado no output", true)
end)

BtnRow("List ReplicatedStorage", T.Card, function()
    print("========== REPLICATED STORAGE ==========")
    for _, obj in ipairs(game:GetService("ReplicatedStorage"):GetChildren()) do
        print(obj.Name, "-", obj.ClassName)
    end
    print("========================================")
    Toast("replicated storage no output", true)
end)

BtnRow("List Player Backpack", T.Card, function()
    print("========== BACKPACK ==========")
    for _, obj in ipairs(LocalPlayer.Backpack:GetChildren()) do
        print(obj.Name, "-", obj.ClassName)
    end
    print("==============================")
    Toast("backpack listado no output", true)
end)

Note("Explorador de instancias e execucao de codigo.", 68)

end -- Avancado

--------------------------------------------------------------------------------
-- ESTATISTICAS
--------------------------------------------------------------------------------
do
CurTab = Tab("Estatísticas", 0, false)
Persist.Scope = "stats"

Section("Estatisticas do SILK CORE")
Note("Contadores desta sessao.", 52)

HackState.stats = HackState.stats or {
    sessionStart = tick(),
    hacksUsed = 0,
    teleports = 0,
    playersKicked = 0,
    itemsCollected = 0,
}

local function formatTime(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

BtnRow("Show Session Stats", T.Accent, function()
    local sessionTime = tick() - HackState.stats.sessionStart
    print("========== SESSION STATS ==========")
    print("Session Time:", formatTime(sessionTime))
    print("Hacks Used:", HackState.stats.hacksUsed)
    print("Teleports:", HackState.stats.teleports)
    print("Players Kicked:", HackState.stats.playersKicked)
    print("Items Collected:", HackState.stats.itemsCollected)
    print("===================================")
    Toast("estatisticas no output", true)
end)

Section("Estatísticas do Jogador")

BtnRow("Track My Stats", T.Accent, function()
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            print("========== PLAYER STATS ==========")
            print("Health:", math.floor(hum.Health).."/"..math.floor(hum.MaxHealth))
            print("WalkSpeed:", hum.WalkSpeed)
            print("JumpPower:", hum.JumpPower or hum.JumpHeight)
            print("Hip Height:", hum.HipHeight)
            
            local root = hkRoot()
            if root then
                print("Position:", tostring(root.Position))
                print("Velocity:", tostring(root.AssemblyLinearVelocity))
            end
            
            print("==================================")
            Toast("player stats no output", true)
        end
    end
end)

Section("Análise do Jogo")

Toggle("Track Players Joining/Leaving", false, function(v)
    HackState.trackPlayers = v
    if v then
        HackState.playerJoinConn = Players.PlayerAdded:Connect(function(player)
            print("[SILK] Player joined:", player.Name)
            Toast(player.Name.." entrou", true)
        end)
        HackState.playerLeaveConn = Players.PlayerRemoving:Connect(function(player)
            print("[SILK] Player left:", player.Name)
            Toast(player.Name.." saiu", false)
        end)
    else
        if HackState.playerJoinConn then
            HackState.playerJoinConn:Disconnect()
            HackState.playerLeaveConn:Disconnect()
        end
    end
    Toast("track players "..(v and "ligado" or "desligado"), v)
end, "stat_trackplayers")

Toggle("Log All Deaths", false, function(v)
    HackState.logDeaths = v
    if v then
        for _, player in ipairs(Players:GetPlayers()) do
            if player.Character then
                local hum = player.Character:FindFirstChildOfClass("Humanoid")
                if hum then
                    hum.Died:Connect(function()
                        print("[SILK DEATH]", player.Name, "morreu")
                    end)
                end
            end
        end
    end
    Toast("log deaths "..(v and "ligado" or "desligado"), v)
end, "stat_deaths")

Section("Monitor de Desempenho")

Toggle("Track FPS", false, function(v)
    HackState.trackFPS = v
    if v then
        task.spawn(function()
            while HackState.trackFPS do
                local fps = math.floor(1 / game:GetService("RunService").Heartbeat:Wait())
                print("[FPS]", fps)
                task.wait(1)
            end
        end)
    end
    Toast("track FPS "..(v and "ligado" or "desligado"), v)
end, "stat_fps")

Toggle("Track Ping", false, function(v)
    HackState.trackPing = v
    if v then
        task.spawn(function()
            while HackState.trackPing do
                local ping = math.floor(LocalPlayer:GetNetworkPing() * 1000)
                print("[PING]", ping, "ms")
                task.wait(2)
            end
        end)
    end
    Toast("track ping "..(v and "ligado" or "desligado"), v)
end, "stat_ping")

Section("Conquistas")

local achievements = {
    {name = "First Blood", desc = "Use seu primeiro hack", unlocked = false},
    {name = "Teleporter", desc = "Teleporte 100 vezes", unlocked = false},
    {name = "Speed Demon", desc = "Use speed hack por 10 minutos", unlocked = false},
    {name = "Ghost Mode", desc = "Fique invisivel por 5 minutos", unlocked = false},
    {name = "Collector", desc = "Colete 1000 itens", unlocked = false},
}

for _, achievement in ipairs(achievements) do
    local status = achievement.unlocked and "[✓]" or "[ ]"
    Note(status.." "..achievement.name.." - "..achievement.desc, 48)
end

BtnRow("Zerar Conquistas", T.Card, function()
    for _, achievement in ipairs(achievements) do
        achievement.unlocked = false
    end
    Toast("conquistas zeradas", true)
end)

Note("Contadores da sessao. Zerar apaga tudo.", 68)

end -- Estatisticas

--------------------------------------------------------------------------------
-- BLOCOS UNIVERSAIS
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- CAMADA DE COMPATIBILIDADE
--------------------------------------------------------------------------------
do
CurTab = Tab("Compatibilidade", 0, false)
Persist.Scope = "compat"

Section("Compatibilidade Universal")
Note("Detecta e adapta hacks automaticamente para jogos populares", 52)

local gamePatterns = {
    {pattern = "Arsenal", placeIds = {286090429}, detected = false},
    {pattern = "Phantom Forces", placeIds = {292439477}, detected = false},
    {pattern = "Jailbreak", placeIds = {606849621}, detected = false},
    {pattern = "Murder Mystery", placeIds = {142823291}, detected = false},
    {pattern = "Blox Fruits", placeIds = {2753915549}, detected = false},
    {pattern = "Adopt Me", placeIds = {920587237}, detected = false},
    {pattern = "Tower Defense", placeIds = {3260590327}, detected = false},
    {pattern = "Anime", placeIds = {3102144307}, detected = false},
    {pattern = "Simulator", placeIds = {}, detected = false},
    {pattern = "Tycoon", placeIds = {}, detected = false},
}

for _, pat in ipairs(gamePatterns) do
    for _, placeId in ipairs(pat.placeIds) do
        if game.PlaceId == placeId then
            pat.detected = true
            break
        end
    end

    if not pat.detected then
        local okInfo, info = pcall(function()
            return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
        end)
        local gameName = okInfo and info and info.Name
        if gameName and gameName:lower():find(pat.pattern:lower(), 1, true) then
            pat.detected = true
        end
    end
end

BtnRow("Detectar Tipo de Jogo", T.Accent, function()
    local detected = nil
    for _, pat in ipairs(gamePatterns) do
        if pat.detected then
            detected = pat.pattern
            break
        end
    end
    
    if detected then
        Toast("jogo detectado: "..detected, true)
        print("[SILK] Game Type:", detected)
    else
        Toast("jogo desconhecido - usando hacks universais", true)
    end
end)

Section("Arsenal")

Toggle("Arsenal: Auto Headshot Helper", false, function(v)
    HackState.arsenalHeadshot = v
    if v then
        task.spawn(function()
            while HackState.arsenalHeadshot do
                local mouse = LocalPlayer:GetMouse()
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer and player.Character then
                        local head = player.Character:FindFirstChild("Head")
                        if head then
                            local screenPos, onScreen = Workspace.CurrentCamera:WorldToScreenPoint(head.Position)
                            if onScreen then
                                local dist = (Vector2.new(screenPos.X, screenPos.Y) - Vector2.new(mouse.X, mouse.Y)).Magnitude
                                if dist < 150 then
                                    Workspace.CurrentCamera.CFrame = CFrame.new(Workspace.CurrentCamera.CFrame.Position, head.Position)
                                end
                            end
                        end
                    end
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("arsenal headshot helper "..(v and "ligado" or "desligado"), v)
end, "compat_arsenal_hs")

Toggle("Arsenal: Show Gun Stats", false, function(v)
    HackState.arsenalStats = v
    Toast("arsenal gun stats "..(v and "ligado" or "desligado"), v)
end, "compat_arsenal_stats")

Section("Phantom Forces")

Toggle("PF: No Recoil", false, function(v)
    HackState.pfNoRecoil = v
    if v then
        for _, obj in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
            if obj:IsA("NumberValue") and obj.Name == "RecoilControl" then
                obj.Value = 0
            end
        end
    end
    Toast("PF no recoil "..(v and "ligado" or "desligado"), v)
end, "compat_pf_recoil")

Toggle("PF: Infinite Ammo", false, function(v)
    HackState.pfInfAmmo = v
    if v then
        task.spawn(function()
            while HackState.pfInfAmmo do
                for _, obj in ipairs(LocalPlayer.Character:GetDescendants()) do
                    if obj:IsA("IntValue") and obj.Name == "Ammo" then
                        obj.Value = 999
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("PF infinite ammo "..(v and "ligado" or "desligado"), v)
end, "compat_pf_ammo")

Section("Jailbreak")

BtnRow("Jailbreak: Auto Rob Stores", T.Accent, function()
    Toast("iniciando auto rob...", true)
    HackState.jailbreakAutoRob = true
    task.spawn(function()
        local stores = {"Donut Store", "Gas Station", "Bank", "Jewelry", "Museum"}
        while HackState.jailbreakAutoRob do
            local root = hkRoot()
            if root then
                for _, storeName in ipairs(stores) do
                    local store = Workspace:FindFirstChild(storeName)
                    if store then
                        local primary = store.PrimaryPart or store:FindFirstChildWhichIsA("BasePart")
                        if primary then
                            root.CFrame = primary.CFrame
                            task.wait(10)
                        end
                    end
                end
            end
            task.wait(1)
        end
    end)
end)

BtnRow("Stop Auto Rob", T.Card, function()
    HackState.jailbreakAutoRob = false
    Toast("auto rob parado", true)
end)

Toggle("Jailbreak: Infinite Nitro", false, function(v)
    HackState.jailbreakNitro = v
    Toast("jailbreak nitro "..(v and "ligado" or "desligado"), v)
end, "compat_jb_nitro")

Section("Murder Mystery 2")

Toggle("MM2: Show Murderer", false, function(v)
    HackState.mm2ShowMurderer = v
    if v then
        task.spawn(function()
            while HackState.mm2ShowMurderer do
                for _, player in ipairs(Players:GetPlayers()) do
                    if player.Character then
                        local knife = player.Character:FindFirstChild("Knife")
                        if knife then
                            print("[MM2] MURDERER:", player.Name)
                            
                            local billboard = Instance.new("BillboardGui")
                            billboard.Size = UDim2.new(0, 100, 0, 40)
                            billboard.StudsOffset = Vector3.new(0, 3, 0)
                            billboard.AlwaysOnTop = true
                            billboard.Parent = player.Character.Head
                            
                            local label = Instance.new("TextLabel")
                            label.Size = UDim2.new(1, 0, 1, 0)
                            label.BackgroundTransparency = 1
                            label.Text = "MURDERER"
                            label.TextColor3 = Color3.fromRGB(255, 0, 0)
                            label.TextStrokeTransparency = 0
                            label.TextScaled = true
                            label.Font = Enum.Font.GothamBold
                            label.Parent = billboard
                        end
                    end
                end
                task.wait(5)
            end
        end)
    end
    Toast("MM2 show murderer "..(v and "ligado" or "desligado"), v)
end, "compat_mm2_murderer")

Section("Blox Fruits")

Toggle("Blox Fruits: Auto Farm", false, function(v)
    HackState.bloxAutoFarm = v
    if v then
        task.spawn(function()
            while HackState.bloxAutoFarm do
                local root = hkRoot()
                if root then
                    for _, npc in ipairs(Workspace:GetDescendants()) do
                        if npc:IsA("Model") and npc:FindFirstChild("Humanoid") and npc:FindFirstChild("HumanoidRootPart") then
                            if not Players:GetPlayerFromCharacter(npc) then
                                local npcRoot = npc.HumanoidRootPart
                                root.CFrame = npcRoot.CFrame * CFrame.new(0, 0, 5)
                                
                                local tool = LocalPlayer.Character:FindFirstChildOfClass("Tool")
                                if tool then
                                    tool:Activate()
                                end
                                
                                task.wait(0.5)
                            end
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("blox fruits auto farm "..(v and "ligado" or "desligado"), v)
end, "compat_blox_farm")

Toggle("Blox Fruits: Auto Collect Chests", false, function(v)
    HackState.bloxAutoChest = v
    if v then
        task.spawn(function()
            while HackState.bloxAutoChest do
                local root = hkRoot()
                if root then
                    for _, chest in ipairs(Workspace:GetDescendants()) do
                        if chest.Name == "Chest" or chest.Name:find("Chest") then
                            if chest:IsA("Model") then
                                local primary = chest.PrimaryPart or chest:FindFirstChildWhichIsA("BasePart")
                                if primary then
                                    root.CFrame = primary.CFrame
                                    task.wait(1)
                                end
                            end
                        end
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("blox fruits auto chest "..(v and "ligado" or "desligado"), v)
end, "compat_blox_chest")

Section("Adopt Me")

Toggle("Adopt Me: Auto Collect Money", false, function(v)
    HackState.adoptMeMoney = v
    if v then
        task.spawn(function()
            while HackState.adoptMeMoney do
                local root = hkRoot()
                if root then
                    for _, coin in ipairs(Workspace:GetDescendants()) do
                        if coin.Name == "Coin" or coin.Name:find("Money") then
                            if coin:IsA("BasePart") then
                                root.CFrame = coin.CFrame
                                task.wait(0.2)
                            end
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("adopt me auto money "..(v and "ligado" or "desligado"), v)
end, "compat_adopt_money")

Section("Simuladores")

Toggle("Simulator: Auto Click", false, function(v)
    HackState.simAutoClick = v
    if v then
        task.spawn(function()
            while HackState.simAutoClick do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and (remote.Name:lower():find("click") or remote.Name:lower():find("tap")) then
                        pcall(function()
                            remote:FireServer()
                        end)
                    end
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("simulator auto click "..(v and "ligado" or "desligado"), v)
end, "compat_sim_click")

Toggle("Simulator: Auto Rebirth", false, function(v)
    HackState.simAutoRebirth = v
    if v then
        task.spawn(function()
            while HackState.simAutoRebirth do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and (remote.Name:lower():find("rebirth") or remote.Name:lower():find("prestige")) then
                        pcall(function()
                            remote:FireServer()
                        end)
                    end
                end
                task.wait(30)
            end
        end)
    end
    Toast("simulator auto rebirth "..(v and "ligado" or "desligado"), v)
end, "compat_sim_rebirth")

Section("Tower Defense")

Toggle("TD: Auto Place Towers", false, function(v)
    HackState.tdAutoPlace = v
    if v then
        task.spawn(function()
            while HackState.tdAutoPlace do
                local root = hkRoot()
                if root then
                    for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                        if remote:IsA("RemoteEvent") and remote.Name:lower():find("place") then
                            pcall(function()
                                local pos = root.Position + Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
                                remote:FireServer(pos)
                            end)
                        end
                    end
                end
                task.wait(5)
            end
        end)
    end
    Toast("TD auto place "..(v and "ligado" or "desligado"), v)
end, "compat_td_place")

Toggle("TD: Auto Upgrade", false, function(v)
    HackState.tdAutoUpgrade = v
    if v then
        task.spawn(function()
            while HackState.tdAutoUpgrade do
                for _, remote in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                    if remote:IsA("RemoteEvent") and remote.Name:lower():find("upgrade") then
                        pcall(function()
                            remote:FireServer()
                        end)
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("TD auto upgrade "..(v and "ligado" or "desligado"), v)
end, "compat_td_upgrade")

Section("Tycoons")

Toggle("Tycoon: Auto Collect", false, function(v)
    HackState.tycoonCollect = v
    if v then
        task.spawn(function()
            while HackState.tycoonCollect do
                local root = hkRoot()
                if root then
                    for _, collector in ipairs(Workspace:GetDescendants()) do
                        if collector.Name == "Collector" or collector.Name:find("Collect") then
                            if collector:IsA("BasePart") then
                                root.CFrame = collector.CFrame
                                task.wait(0.5)
                            end
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("tycoon auto collect "..(v and "ligado" or "desligado"), v)
end, "compat_tycoon_collect")

Toggle("Tycoon: Auto Buy All", false, function(v)
    HackState.tycoonBuy = v
    if v then
        task.spawn(function()
            while HackState.tycoonBuy do
                local root = hkRoot()
                if root then
                    for _, button in ipairs(Workspace:GetDescendants()) do
                        if button:IsA("ClickDetector") then
                            pcall(function()
                                fireclickdetector(button)
                            end)
                        end
                    end
                end
                task.wait(2)
            end
        end)
    end
    Toast("tycoon auto buy "..(v and "ligado" or "desligado"), v)
end, "compat_tycoon_buy")

Note("Ativa os hacks do jogo detectado.", 68)

end -- Compatibilidade

--------------------------------------------------------------------------------
-- HACKS UNIVERSAIS ESTENDIDOS
--------------------------------------------------------------------------------
do
CurTab = Tab("Hacks Extras", 0, false)
Persist.Scope = "exthacks"

Section("Hacks Estendidos")
Note("Hacks fora das abas principais.", 52)

-- Combate estendido
Section("Combate Estendido")

Toggle("Aimbot FOV Circle", false, function(v)
    HackState.aimbotFOV = v
    if v then
        local circle = Drawing.new("Circle")
        circle.Thickness = 2
        circle.NumSides = 32
        circle.Radius = 150
        circle.Color = Color3.fromRGB(255, 0, 0)
        circle.Transparency = 0.5
        circle.Visible = true
        
        task.spawn(function()
            while HackState.aimbotFOV do
                local mouse = LocalPlayer:GetMouse()
                circle.Position = Vector2.new(mouse.X, mouse.Y)
                task.wait()
            end
            circle:Remove()
        end)
    end
    Toast("aimbot FOV circle "..(v and "ligado" or "desligado"), v)
end, "exh_aimfov")

Toggle("Triggerbot", false, function(v)
    HackState.triggerbot = v
    if v then
        task.spawn(function()
            while HackState.triggerbot do
                local mouse = LocalPlayer:GetMouse()
                if mouse.Target and mouse.Target.Parent:FindFirstChild("Humanoid") then
                    mouse1click()
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("triggerbot "..(v and "ligado" or "desligado"), v)
end, "exh_trigger")

Toggle("Bunny Hop", false, function(v)
    HackState.bhop = v
    if v then
        task.spawn(function()
            while HackState.bhop do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum and hum.FloorMaterial ~= Enum.Material.Air then
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("bunny hop "..(v and "ligado" or "desligado"), v)
end, "exh_bhop")

Slider("Aimbot Smoothness", 0, 1, 0.5, "%.2f", function(v)
    HackState.aimbotSmooth = v
end, "exh_aimsmooth")

Toggle("Smooth Aimbot", false, function(v)
    HackState.smoothAimbot = v
    if v then
        task.spawn(function()
            while HackState.smoothAimbot do
                local mouse = LocalPlayer:GetMouse()
                local closest = nil
                local closestDist = 999999
                
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer and player.Character then
                        local head = player.Character:FindFirstChild("Head")
                        if head then
                            local screenPos, onScreen = Workspace.CurrentCamera:WorldToScreenPoint(head.Position)
                            if onScreen then
                                local dist = (Vector2.new(screenPos.X, screenPos.Y) - Vector2.new(mouse.X, mouse.Y)).Magnitude
                                if dist < closestDist and dist < 300 then
                                    closest = head
                                    closestDist = dist
                                end
                            end
                        end
                    end
                end
                
                if closest then
                    local targetPos = closest.Position
                    local cam = Workspace.CurrentCamera
                    local currentCF = cam.CFrame
                    local targetCF = CFrame.new(currentCF.Position, targetPos)
                    local smoothness = HackState.aimbotSmooth or 0.5
                    cam.CFrame = currentCF:Lerp(targetCF, smoothness)
                end
                
                task.wait()
            end
        end)
    end
    Toast("smooth aimbot "..(v and "ligado" or "desligado"), v)
end, "exh_smoothaim")

-- Movimento estendido
Section("Movimento Estendido")

Toggle("Long Jump", false, function(v)
    HackState.longJump = v
    if v then
        HackState.longJumpConn = UserInputService.InputBegan:Connect(function(input, gpe)
            if not gpe and input.KeyCode == Enum.KeyCode.Space then
                local root = hkRoot()
                if root then
                    local lookVector = Workspace.CurrentCamera.CFrame.LookVector
                    root.AssemblyLinearVelocity = Vector3.new(lookVector.X * 100, 50, lookVector.Z * 100)
                end
            end
        end)
    else
        if HackState.longJumpConn then
            HackState.longJumpConn:Disconnect()
        end
    end
    Toast("long jump "..(v and "ligado - press space" or "desligado"), v)
end, "exh_longjump")

Toggle("Jesus (walk on water)", false, function(v)
    HackState.jesus = v
    if v then
        task.spawn(function()
            while HackState.jesus do
                local root = hkRoot()
                if root then
                    local region = Region3.new(root.Position - Vector3.new(5, 5, 5), root.Position + Vector3.new(5, 5, 5))
                    local parts = Workspace:FindPartsInRegion3(region, nil, 100)
                    
                    for _, part in ipairs(parts) do
                        if part.Material == Enum.Material.Water then
                            local platform = Instance.new("Part")
                            platform.Size = Vector3.new(10, 1, 10)
                            platform.Anchored = true
                            platform.Transparency = 0.7
                            platform.Material = Enum.Material.Ice
                            platform.Color = Color3.fromRGB(150, 200, 255)
                            platform.Position = root.Position - Vector3.new(0, 3, 0)
                            platform.Parent = Workspace
                            
                            task.delay(2, function()
                                platform:Destroy()
                            end)
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("jesus mode "..(v and "ligado" or "desligado"), v)
end, "exh_jesus")

Toggle("Spider Man (climb walls)", false, function(v)
    HackState.spiderMan = v
    if v then
        task.spawn(function()
            while HackState.spiderMan do
                local char = LocalPlayer.Character
                if char then
                    local root = hkRoot()
                    if root then
                        local ray = Ray.new(root.Position, root.CFrame.LookVector * 5)
                        local hit = Workspace:FindPartOnRay(ray, char)
                        
                        if hit then
                            local bodyVel = Instance.new("BodyVelocity")
                            bodyVel.Velocity = Vector3.new(0, 20, 0)
                            bodyVel.MaxForce = Vector3.new(0, 4000, 0)
                            bodyVel.Parent = root
                            
                            task.delay(0.1, function()
                                bodyVel:Destroy()
                            end)
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("spider man "..(v and "ligado" or "desligado"), v)
end, "exh_spider")

Toggle("Edge Jump (auto jump at ledges)", false, function(v)
    HackState.edgeJump = v
    if v then
        task.spawn(function()
            while HackState.edgeJump do
                local char = LocalPlayer.Character
                if char then
                    local root = hkRoot()
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    
                    if root and hum and hum.FloorMaterial ~= Enum.Material.Air then
                        local ray = Ray.new(root.Position, Vector3.new(0, -10, 0))
                        local hit = Workspace:FindPartOnRay(ray, char)
                        
                        if not hit then
                            hum:ChangeState(Enum.HumanoidStateType.Jumping)
                        end
                    end
                end
                task.wait(0.1)
            end
        end)
    end
    Toast("edge jump "..(v and "ligado" or "desligado"), v)
end, "exh_edgejump")

-- Visual estendido
Section("Visual Estendido")

Toggle("Rainbow Character", false, function(v)
    HackState.rainbowChar = v
    if v then
        task.spawn(function()
            while HackState.rainbowChar do
                local char = LocalPlayer.Character
                if char then
                    for _, part in ipairs(char:GetDescendants()) do
                        if part:IsA("BasePart") then
                            part.Color = Color3.fromHSV(tick() % 5 / 5, 1, 1)
                        end
                    end
                end
                task.wait(0.05)
            end
        end)
    end
    Toast("rainbow character "..(v and "ligado" or "desligado"), v)
end, "exh_rainbow")

Toggle("Neon Character", false, function(v)
    HackState.neonChar = v
    local char = LocalPlayer.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                part.Material = v and Enum.Material.Neon or Enum.Material.Plastic
            end
        end
    end
    Toast("neon character "..(v and "ligado" or "desligado"), v)
end, "exh_neon")

Toggle("Glow Effect", false, function(v)
    HackState.glowEffect = v
    local char = LocalPlayer.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                if v then
                    local light = Instance.new("PointLight")
                    light.Brightness = 2
                    light.Range = 20
                    light.Color = Color3.fromRGB(255, 255, 255)
                    light.Parent = part
                else
                    for _, light in ipairs(part:GetChildren()) do
                        if light:IsA("PointLight") then
                            light:Destroy()
                        end
                    end
                end
            end
        end
    end
    Toast("glow effect "..(v and "ligado" or "desligado"), v)
end, "exh_glow")

-- Utilidades estendidas
Section("Utilidades Estendidas")

Toggle("Auto Save Position", false, function(v)
    HackState.autoSavePos = v
    if v then
        task.spawn(function()
            while HackState.autoSavePos do
                local root = hkRoot()
                if root then
                    HackState.savedPosition = root.CFrame
                end
                task.wait(5)
            end
        end)
    end
    Toast("auto save position "..(v and "ligado" or "desligado"), v)
end, "exh_autosave")

BtnRow("Load Saved Position", T.Accent, function()
    if HackState.savedPosition then
        local root = hkRoot()
        if root then
            root.CFrame = HackState.savedPosition
            Toast("position loaded", true)
        end
    else
        Toast("no saved position", false)
    end
end)

Toggle("Auto Heal", false, function(v)
    HackState.autoHeal = v
    if v then
        task.spawn(function()
            while HackState.autoHeal do
                local char = LocalPlayer.Character
                if char then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health < hum.MaxHealth * 0.5 then
                        for _, obj in ipairs(LocalPlayer.Backpack:GetChildren()) do
                            if obj.Name:lower():find("heal") or obj.Name:lower():find("potion") or obj.Name:lower():find("med") then
                                hum:EquipTool(obj)
                                obj:Activate()
                                task.wait(1)
                            end
                        end
                    end
                end
                task.wait(1)
            end
        end)
    end
    Toast("auto heal "..(v and "ligado" or "desligado"), v)
end, "exh_autoheal")

Note("Combat, movimento, visual e utilidade num lugar so.", 68)

end -- Hacks Extras

--------------------------------------------------------------------------------
-- NATURAL DISASTER SURVIVAL: ORBITAL DE PECAS
-- Puxa tudo que ficou solto depois do desastre (e as pecas presas, se liberar)
-- e monta a forma escolhida em volta do personagem.
--------------------------------------------------------------------------------
do

local function ndBuild()
CurTab = Tab("Desastres", 0, false)
Persist.Scope = "natdisaster"

local ND = {
    parts = {},        -- pecas sob controle do orbital
    orig = {},         -- estado original de cada peca (pra devolver depois)
    cache = {},        -- pontos normalizados da forma, um por peca
    on = false,
    shape = "anel",
    radius = 14,
    speed = 1.2,       -- voltas por segundo (0 = forma parada)
    tilt = 0,          -- graus de inclinacao do plano
    depth = 0,         -- engrossa a forma no eixo da camera
    bob = 0,           -- sobe/desce o conjunto
    fps = 30,          -- gravacoes de CFrame por segundo
    maxParts = 120,
    anchored = false,  -- incluir pecas presas no mapa
    follow = true,     -- forma virada pra camera
    closed = true,     -- fechar o desenho
    custom = {},       -- pontos desenhados, em pixel de tela
    spin = 0,
    acc = 0,
    conn = nil,
    ghosts = {},       -- pecas criadas por mim (so eu vejo)
    create = true,     -- completar a forma com pecas proprias
    want = 48,         -- quantas pecas a forma deve ter
}
HackState.ndOrbital = ND

-- tudo que e chamado antes de existir precisa estar declarado aqui
local ndShape, ndPoly, ndResample, ndNormalize, ndCustomOutline
local ndRoot, ndBlocked, ndQuery, ndCollect, ndRelease, ndRebuild, ndVolumetric
local ndClearGhosts, ndMakeGhosts, ndOnlyOwn
local ndStep, ndStart, ndCount

Section("Orbital de Peças")
Note("Puxa as peças soltas depois do desastre e monta a forma escolhida. Peças presas entram se você liberar. O que faltar ele cria — essas só você vê.", 66)

-- ------------------------------------------------------------------ utilidade
ndRoot = function()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char.PrimaryPart or char:FindFirstChild("HumanoidRootPart", true)
end

-- tudo que nao deve entrar no orbital
ndBlocked = function(part)
    if not part:IsA("BasePart") then return true end
    if part:IsDescendantOf(Workspace.Terrain) then return true end
    local s = part.Size
    if math.max(s.X, s.Y, s.Z) > 150 then return true end
    if part.Name == "Baseplate" or part.Name == "silk_orbital" then return true end
    for _, plr in ipairs(Players:GetPlayers()) do
        local c = plr.Character
        if c and part:IsDescendantOf(c) then return true end
    end
    local model = part:FindFirstAncestorOfClass("Model")
    if model and model:FindFirstChildOfClass("Humanoid") then return true end
    return false
end

-- busca por caixa em volta do personagem (OverlapParams; Region3 como reserva)
ndQuery = function(center, size)
    if Workspace.GetPartBoundsInBox and OverlapParams then
        local p = OverlapParams.new()
        p.FilterType = Enum.RaycastFilterType.Exclude
        p.FilterDescendantsInstances = { LocalPlayer.Character }
        p.MaxParts = 0
        return Workspace:GetPartBoundsInBox(CFrame.new(center), size, p)
    end
    local r3 = Region3.new(center - size / 2, center + size / 2)
    return Workspace:FindPartsInRegion3(r3, LocalPlayer.Character, 5000)
end

ndClearGhosts = function()
    for i = #ND.ghosts, 1, -1 do
        local p = ND.ghosts[i]
        if p then pcall(function() p:Destroy() end) end
        ND.ghosts[i] = nil
    end
end

-- peca propria: criada no cliente, so quem roda o script ve
ndMakeGhosts = function(n)
    ndClearGhosts()
    local list = {}
    for i = 1, n do
        local p = Instance.new("Part")
        p.Name = "silk_orbital"
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.Massless = true
        p.Size = Vector3.new(1.6, 1.6, 1.6)
        p.Material = Enum.Material.Neon
        p.Color = Color3.fromRGB(130, 200, 255)
        p.Transparency = 0.15
        p.Parent = Workspace
        ND.ghosts[i] = p
        list[i] = p
    end
    return list
end

ndCollect = function()
    local root = ndRoot()
    local center = root and root.Position or Vector3.zero
    local reach = math.max(80, ND.radius * 4)
    local found = ndQuery(center, Vector3.new(reach, reach, reach))

    local pick = {}
    for _, part in ipairs(found) do
        if not ndBlocked(part) and (ND.anchored or not part.Anchored) then
            pick[#pick + 1] = part
        end
    end
    table.sort(pick, function(a, b)
        return (a.Position - center).Magnitude < (b.Position - center).Magnitude
    end)

    local list = {}
    for i = 1, math.min(#pick, ND.maxParts) do
        local part = pick[i]
        if not ND.orig[part] then
            ND.orig[part] = {
                cf = part.CFrame,
                anchored = part.Anchored,
                collide = part.CanCollide,
                massless = part.Massless,
            }
        end
        part.CanCollide = false
        part.Massless = true
        list[i] = part
    end
    if ND.create and #list < ND.want then
        local g = ndMakeGhosts(ND.want - #list)
        for i = 1, #g do list[#list + 1] = g[i] end
    end
    ND.parts = list
    ndRebuild()
    return #list
end

-- forma montada so com pecas proprias, sem puxar nada do mapa
ndOnlyOwn = function()
    ndRelease()
    ND.parts = ndMakeGhosts(ND.want)
    ndRebuild()
    ndStart()
    return #ND.parts
end

ndRelease = function()
    ND.on = false
    if ND.conn then ND.conn:Disconnect(); ND.conn = nil end
    ndClearGhosts()
    for part, st in pairs(ND.orig) do
        if part and part.Parent then
            pcall(function()
                part.CFrame = st.cf
                part.Anchored = st.anchored
                part.CanCollide = st.collide
                part.Massless = st.massless
            end)
        end
    end
    ND.orig = {}
    ND.parts = {}
    ND.cache = {}
end

-- -------------------------------------------------------------------- formas
-- Cada forma devolve um ponto normalizado (x, y, z) dentro de um cubo de lado 2.

ndShape = {}

ndShape.anel = function(t)
    return math.cos(t), 0, math.sin(t)
end

ndShape.circulo = function(t)
    return math.cos(t), math.sin(t), 0
end

ndShape.esfera = function(t, i, n)
    local k = (i - 0.5) / n
    local phi = math.acos(math.clamp(1 - 2 * k, -1, 1))
    local theta = math.pi * (1 + 5 ^ 0.5) * k
    return math.cos(theta) * math.sin(phi), math.cos(phi), math.sin(theta) * math.sin(phi)
end

ndShape.coracao = function(t)
    local x = 16 * math.sin(t) ^ 3
    local y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
    return x / 17, y / 17, 0
end

ndShape.estrela = function(t)
    local r = 0.62 + 0.38 * math.cos(5 * t)
    return r * math.cos(t), r * math.sin(t), 0
end

ndShape.espiral = function(t)
    local u = t / (math.pi * 2)
    local a = u * math.pi * 4
    return u * math.cos(a), u * math.sin(a), 0
end

ndVolumetric = { anel = true, esfera = true }

-- contornos feitos a mao, normalizados em [-1, 1]
ndPoly = {
    quadrado = { {-1, -1}, {1, -1}, {1, 1}, {-1, 1} },
    triangulo = { {0, 1}, {0.94, -0.62}, {-0.94, -0.62} },
    dedo = {
        {-0.55, -1}, {0.55, -1}, {0.55, -0.2}, {0.14, -0.2},
        {0.14, 0.72}, {0.06, 0.9}, {-0.06, 0.9}, {-0.14, 0.72}, {-0.14, -0.2}, {-0.55, -0.2},
    },
}

-- redivide um contorno em n pontos com espacamento igual pelo comprimento
ndResample = function(pts, n, closed)
    local list = {}
    for i = 1, #pts do list[i] = pts[i] end
    if closed and #list > 1 then list[#list + 1] = pts[1] end
    local m = #list
    if m < 2 or n < 1 then return {} end

    local seg, total = {}, 0
    for i = 1, m - 1 do
        local dx = list[i + 1][1] - list[i][1]
        local dy = list[i + 1][2] - list[i][2]
        local l = math.sqrt(dx * dx + dy * dy)
        seg[i] = l
        total = total + l
    end
    if total <= 0 then return {} end

    local out = {}
    local idx, acc = 1, 0
    for k = 1, n do
        local target = ((k - 1) / n) * total
        while idx < m - 1 and acc + seg[idx] < target do
            acc = acc + seg[idx]
            idx = idx + 1
        end
        local l = seg[idx]
        local f = (l and l > 0) and (target - acc) / l or 0
        local a = list[idx]
        local b = list[idx + 1] or a
        out[k] = { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f }
    end
    return out
end

-- recorta, alisa, centraliza e escala o que foi desenhado para [-1, 1]
ndNormalize = function(pts)
    if #pts < 3 then return {} end
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, q in ipairs(pts) do
        if q[1] < minx then minx = q[1] end
        if q[1] > maxx then maxx = q[1] end
        if q[2] < miny then miny = q[2] end
        if q[2] > maxy then maxy = q[2] end
    end
    local w, h = maxx - minx, maxy - miny
    local span = math.max(w, h)
    if span <= 0 then return {} end

    local sm = {}
    for i, q in ipairs(pts) do
        local a = pts[math.max(1, i - 1)]
        local b = pts[math.min(#pts, i + 1)]
        sm[i] = { (a[1] + q[1] + b[1]) / 3, (a[2] + q[2] + b[2]) / 3 }
    end

    local cx, cy = minx + w / 2, miny + h / 2
    local s = 2 / span
    local out = {}
    for i, q in ipairs(sm) do
        out[i] = { (q[1] - cx) * s, -(q[2] - cy) * s }
    end
    return out
end

ndCustomOutline = function()
    return ND.drawn or ndNormalize(ND.custom)
end

-- ------------------------------------------------------------------ montagem
ndRebuild = function()
    local n = #ND.parts
    local out = {}
    if n > 0 then
        if ND.shape == "desenho" then
            local rs = ndResample(ndCustomOutline(), n, ND.closed)
            for i = 1, n do
                local p = rs[i] or { 0, 0 }
                out[i] = { p[1], p[2], 0, ((i - 1) / n) * math.pi * 2 }
            end
        elseif ndPoly[ND.shape] then
            local rs = ndResample(ndPoly[ND.shape], n, true)
            for i = 1, n do
                local p = rs[i] or { 0, 0 }
                out[i] = { p[1], p[2], 0, ((i - 1) / n) * math.pi * 2 }
            end
        else
            local fn = ndShape[ND.shape] or ndShape.anel
            for i = 1, n do
                local t = ((i - 1) / n) * math.pi * 2
                local x, y, z = fn(t, i, n)
                out[i] = { x, y, z, t }
            end
        end
    end
    ND.cache = out
end

ndStep = function(dt)
    local root = ndRoot()
    if not root then return end
    local n = #ND.parts
    if n == 0 then return end

    ND.spin = ND.spin + dt * ND.speed * math.pi * 2

    local center = root.Position + Vector3.new(0, 3 + ND.bob, 0)
    local cam = Workspace.CurrentCamera
    local base
    if ndVolumetric[ND.shape] then
        base = CFrame.new(center)
    elseif ND.follow and cam then
        base = CFrame.fromMatrix(center, cam.CFrame.RightVector, cam.CFrame.UpVector)
    else
        base = CFrame.new(center) * CFrame.Angles(0, ND.spin, 0)
    end
    if ND.tilt ~= 0 then
        base = base * CFrame.Angles(math.rad(ND.tilt), 0, 0)
    end

    local R = ND.radius
    local cache = ND.cache
    for i = 1, n do
        local part = ND.parts[i]
        local v = cache[i]
        if part and part.Parent and v then
            local z = v[3]
            if ND.depth ~= 0 then z = z + math.sin(v[4] * 3) * ND.depth end
            if not part.Anchored then
                part.AssemblyLinearVelocity = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
            end
            part.CFrame = CFrame.new(base:PointToWorldSpace(Vector3.new(v[1] * R, v[2] * R, z * R)))
        end
    end
end

ndStart = function()
    if ND.conn then ND.conn:Disconnect() end
    ND.on = true
    ND.acc = 0
    ND.conn = RunService.Heartbeat:Connect(function(dt)
        if not ND.on then
            if ND.conn then ND.conn:Disconnect(); ND.conn = nil end
            return
        end
        ND.acc = ND.acc + dt
        local step = 1 / math.clamp(ND.fps, 5, 60)
        if ND.acc < step then return end
        local frame = ND.acc
        ND.acc = 0
        pcall(ndStep, frame)
    end)
end

ndCount = function()
    return #ND.parts
end

-- ------------------------------------------------------------------- controles
BtnRow("Puxar Peças do Mapa", T.Accent, function()
    ndRelease()
    local got = ndCollect()
    if got > 0 then
        ndStart()
        Toast("orbital ligado com " .. got .. " peças", true)
    else
        Toast("nenhuma peça encontrada por perto", false)
    end
end)

BtnRow("Parar Orbital (segura as peças)", T.Card, function()
    ND.on = false
    Toast("orbital parado com " .. ndCount() .. " peças seguradas", true)
end)

BtnRow("Soltar Tudo (volta ao lugar)", T.Card, function()
    ndRelease()
    Toast("peças devolvidas ao lugar", true)
end)

BtnRow("Puxar Só as Soltas de Novo", T.Card, function()
    ND.orig = {}
    ND.parts = {}
    local got = ndCollect()
    Toast(got > 0 and ("repuxadas " .. got .. " peças") or "nada novo por perto", got > 0)
end)

BtnRow("Forma Só com Peças Próprias (não puxa nada)", T.Accent, function()
    local n = ndOnlyOwn()
    Toast("forma montada com " .. n .. " peças próprias", true)
end)

Section("Formas")

local function ndSetShape(name, label)
    ND.shape = name
    if name == "desenho" then ND.drawn = ndNormalize(ND.custom) end
    ndRebuild()
    Toast("forma: " .. label, true)
end

BtnRow("Forma: Anel", T.Accent, function() ndSetShape("anel", "anel") end)
BtnRow("Forma: Círculo", T.Accent, function() ndSetShape("circulo", "círculo") end)
BtnRow("Forma: Esfera", T.Accent, function() ndSetShape("esfera", "esfera") end)
BtnRow("Forma: Coração", T.Accent, function() ndSetShape("coracao", "coração") end)
BtnRow("Forma: Estrela", T.Accent, function() ndSetShape("estrela", "estrela") end)
BtnRow("Forma: Espiral", T.Accent, function() ndSetShape("espiral", "espiral") end)
BtnRow("Forma: Quadrado", T.Accent, function() ndSetShape("quadrado", "quadrado") end)
BtnRow("Forma: Triângulo", T.Accent, function() ndSetShape("triangulo", "triângulo") end)
BtnRow("Forma: Dedo do Meio", T.Accent, function() ndSetShape("dedo", "dedo do meio") end)
BtnRow("Forma: Meu Desenho", T.Accent, function()
    if #ND.custom < 3 then
        Toast("desenhe alguma coisa primeiro", false)
        return
    end
    ndSetShape("desenho", "desenho")
end)

Section("Ajustes do Orbital")

Slider("Peças na forma", 8, 200, 48, "%.0f", function(v)
    ND.want = math.floor(v)
    ndRebuild()
end, "nd_want")

Toggle("Criar peças se faltar (só você vê)", true, function(v)
    ND.create = v
end, "nd_criar")

Slider("Raio da forma", 4, 40, 14, "%.0f studs", function(v)
    ND.radius = v
    ndRebuild()
end, "nd_radius")

Slider("Velocidade da volta", 0, 8, 1.2, "%.1f x", function(v)
    ND.speed = v
end, "nd_speed")

Slider("Inclinação", -90, 90, 0, "%.0f graus", function(v)
    ND.tilt = v
end, "nd_tilt")

Slider("Altura do conjunto", -20, 40, 0, "%.0f studs", function(v)
    ND.bob = v
end, "nd_bob")

Slider("Profundidade da forma", 0, 14, 0, "%.0f", function(v)
    ND.depth = v
end, "nd_depth")

Slider("Maximo de pecas", 20, 400, 120, "%.0f", function(v)
    ND.maxParts = math.floor(v)
end, "nd_max")

Slider("Gravações por segundo", 10, 60, 30, "%.0f/s", function(v)
    ND.fps = math.floor(v)
end, "nd_fps")

Toggle("Incluir peças presas (anchored)", false, function(v)
    ND.anchored = v
    Toast("peças presas " .. (v and "liberadas" or "ignoradas"), v)
end, "nd_anchored")

Toggle("Forma virada pra câmera", true, function(v)
    ND.follow = v
end, "nd_follow")

Toggle("Fechar o desenho", true, function(v)
    ND.closed = v
    ndRebuild()
end, "nd_closed")

-- ------------------------------------------------------------------ desenho
Section("Desenhar a Forma")

Note("Abre o quadro, desenha com o mouse e aplica. As peças pegam o contorno.", 52)

local canvasGui, canvasFrame

local function ndCanvas()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local old = playerGui:FindFirstChild("SilkDesenhoND")
    if old then old:Destroy() end

    canvasGui = New("ScreenGui", {
        Name = "SilkDesenhoND",
        ResetOnSpawn = false,
        DisplayOrder = 60,
        Enabled = false,
    }, playerGui)

    local box = New("Frame", {
        Size = UDim2.fromOffset(430, 470),
        Position = UDim2.new(0.5, -215, 0.5, -235),
        BackgroundColor3 = T.Panel,
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
    }, canvasGui)
    Round(box, 10)
    Stroke(box, T.Accent, 1)

    New("TextLabel", {
        Text = "DESENHE A FORMA",
        Font = F.Bold,
        TextSize = 13,
        TextColor3 = T.Text,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(16, 0),
        Size = UDim2.new(1, -110, 0, 38),
    }, box)

    local closeBtn = New("TextButton", {
        Text = "X",
        Font = F.Bold,
        TextSize = 14,
        TextColor3 = T.Bad,
        BackgroundColor3 = T.Card2,
        AutoButtonColor = false,
        BorderSizePixel = 0,
        Position = UDim2.new(1, -38, 0, 8),
        Size = UDim2.fromOffset(28, 28),
    }, box)
    Round(closeBtn, 5)
    closeBtn.MouseButton1Click:Connect(function()
        canvasGui.Enabled = false
    end)

    canvasFrame = New("Frame", {
        Size = UDim2.new(1, -32, 1, -136),
        Position = UDim2.fromOffset(16, 46),
        BackgroundColor3 = T.Card,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, box)
    Round(canvasFrame, 6)
    Stroke(canvasFrame, T.Stroke2, 1)

    local function makeBtn(text, x, w, color, cb)
        local b = New("TextButton", {
            Text = text,
            Font = F.Bold,
            TextSize = 11,
            TextColor3 = color == T.Accent and Color3.new(1, 1, 1) or T.Text,
            BackgroundColor3 = color,
            BackgroundTransparency = 0.15,
            AutoButtonColor = false,
            BorderSizePixel = 0,
            Position = UDim2.new(x, 16, 1, -66),
            Size = UDim2.new(w, -8, 0, 30),
        }, box)
        Round(b, 6)
        b.MouseButton1Click:Connect(cb)
    end

    makeBtn("LIMPAR", 0.00, 0.25, T.Card2, function()
        ND.custom = {}
        ND.drawn = nil
        for _, dot in ipairs(canvasFrame:GetChildren()) do
            if dot:IsA("Frame") then dot:Destroy() end
        end
        Toast("desenho limpo", true)
    end)

    makeBtn("APLICAR", 0.25, 0.30, T.Accent, function()
        if #ND.custom < 3 then
            Toast("desenhe alguma coisa primeiro", false)
            return
        end
        ND.drawn = ndNormalize(ND.custom)
        ND.shape = "desenho"
        ndRebuild()
        canvasGui.Enabled = false
        Toast("forma aplicada com " .. #ND.drawn .. " pontos", true)
    end)

    makeBtn("FECHAR", 0.55, 0.22, T.Card2, function()
        canvasGui.Enabled = false
    end)

    makeBtn("VER FORMAS", 0.77, 0.23, T.Card2, function()
        canvasGui.Enabled = false
        Toast("escolha uma forma na lista", true)
    end)

    -- arrastar o quadro pela barra do titulo
    local dragging, dragStart, startPos
    box.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = box.Position
        end
    end)
    box.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local d = input.Position - dragStart
            box.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

local drawing = false
local lastDot = nil

local function ndInside(pos)
    if not canvasFrame then return false end
    local p, s = canvasFrame.AbsolutePosition, canvasFrame.AbsoluteSize
    return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

local function ndAddPoint(pos)
    if not ndInside(pos) then return end
    if lastDot and (pos - lastDot).Magnitude < 2 then return end
    lastDot = pos
    local p = canvasFrame.AbsolutePosition
    local rel = Vector2.new(pos.X - p.X, pos.Y - p.Y)
    ND.custom[#ND.custom + 1] = { rel.X, rel.Y }
    if #canvasFrame:GetChildren() < 1400 then
        local dot = New("Frame", {
            Size = UDim2.fromOffset(3, 3),
            Position = UDim2.fromOffset(rel.X - 1.5, rel.Y - 1.5),
            BackgroundColor3 = T.Accent,
            BorderSizePixel = 0,
        }, canvasFrame)
        Round(dot, 2)
    end
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if not canvasGui or not canvasGui.Enabled then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        local pos = UserInputService:GetMouseLocation()
        if ndInside(pos) then
            drawing = true
            lastDot = nil
            ndAddPoint(pos)
        end
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if drawing and input.UserInputType == Enum.UserInputType.MouseMovement then
        ndAddPoint(UserInputService:GetMouseLocation())
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        drawing = false
        lastDot = nil
    end
end)

BtnRow("Abrir Quadro de Desenho", T.Accent, function()
    if not canvasGui then ndCanvas() end
    canvasGui.Enabled = not canvasGui.Enabled
    Toast(canvasGui.Enabled and "quadro aberto - desenhe com o mouse" or "quadro fechado", true)
end)

BtnRow("Limpar Desenho", T.Card, function()
    ND.custom = {}
    ND.drawn = nil
    if canvasFrame then
        for _, dot in ipairs(canvasFrame:GetChildren()) do
            if dot:IsA("Frame") then dot:Destroy() end
        end
    end
    Toast("desenho limpo", true)
end)

-- -------------------------------------------------------------- outros hacks
Section("Outros Hacks")

Toggle("Auto Survive (sobe e fica no ar)", false, function(v)
    HackState.ndAutoSurvive = v
    if v then
        task.spawn(function()
            while HackState.ndAutoSurvive do
                local root = ndRoot()
                if root then root.CFrame = root.CFrame + Vector3.new(0, 60, 0) end
                task.wait(0.5)
            end
        end)
    end
    Toast("auto survive " .. (v and "ligado" or "desligado"), v)
end, "nd_survive")

Toggle("Coletar Moedas Perto", false, function(v)
    HackState.ndCoins = v
    if v then
        task.spawn(function()
            while HackState.ndCoins do
                local root = ndRoot()
                if root then
                    for _, item in ipairs(Workspace:GetDescendants()) do
                        if item:IsA("BasePart") and (item.Name == "Coin" or item.Name == "CoinPart") then
                            if (item.Position - root.Position).Magnitude < 120 then
                                root.CFrame = CFrame.new(item.Position)
                                task.wait(0.1)
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("coletar moedas " .. (v and "ligado" or "desligado"), v)
end, "nd_coins")

BtnRow("TP para o Ponto Mais Alto", T.Accent, function()
    local root = ndRoot()
    if not root then return end
    local highest, where = -math.huge, nil
    for _, part in ipairs(Workspace:GetDescendants()) do
        if part:IsA("BasePart") and part.Anchored and part.Size.X < 120 and part.Size.Z < 120 then
            if part.Position.Y > highest then
                highest = part.Position.Y
                where = part.Position
            end
        end
    end
    if where then
        root.CFrame = CFrame.new(where + Vector3.new(0, 8, 0))
        Toast("teleportado pro ponto mais alto", true)
    else
        Toast("não achei um ponto seguro", false)
    end
end)

-- ============================================================ voadora & socos
Section("Voadora & Socos (animação visível)")

Note("A animação roda no seu personagem e todo mundo vê. O chute também empurra quem estiver na frente.", 60)

-- IDs de emote reais (dropkick, mma, tenna, tapa, empurrao)
local FLING_ANIM = {
    { nome = "Voadora (dropkick)", id = "133566007754001" },
    { nome = "Voadora Trendy", id = "90717656419568" },
    { nome = "Chute Tenna", id = "118139885865308" },
    { nome = "Chute MMA", id = "88347541858075" },
    { nome = "Tapa", id = "108225134235478" },
    { nome = "Tapa 2", id = "78221709455150" },
    { nome = "Empurrão", id = "135890160317037" },
    { nome = "Empurrão 2", id = "82070755455634" },
}

local FL = {
    on = false,
    track = nil,
    conn = nil,
    velocidade = 16,
    perseguir = true,
    forca = 100000,
    plataforma = true,
    last = nil,
}
HackState.ndFling = FL

local flNearest, flStop, flPlay, flAlvo, flRespawnConn

flNearest = function(pos)
    local melhor, melhorD = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local c = plr.Character
            local r = c and c:FindFirstChild("HumanoidRootPart")
            local h = c and c:FindFirstChildOfClass("Humanoid")
            if r and h and h.Health > 0 then
                local d = (r.Position - pos).Magnitude
                if d < melhorD then
                    melhorD = d
                    melhor = plr
                end
            end
        end
    end
    return melhor, melhorD
end

flStop = function()
    FL.on = false
    if FL.conn then FL.conn:Disconnect() end
    FL.conn = nil
    if FL.track then
        pcall(function() FL.track:Stop() end)
        FL.track = nil
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum.PlatformStand = false end) end
end

flPlay = function(animId, apelido)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and root) then
        Toast("sem personagem", false)
        return
    end
    flStop()

    if animId and animId ~= "" then
        local anim = Instance.new("Animation")
        anim.AnimationId = "rbxassetid://" .. tostring(animId)
        local animator = hum:FindFirstChildOfClass("Animator")
        local ok, track = pcall(function()
            return (animator or hum):LoadAnimation(anim)
        end)
        if not ok or not track then
            ok, track = pcall(function() return hum:LoadAnimation(anim) end)
        end
        if ok and track then
            FL.track = track
            pcall(function()
                track.Priority = Enum.AnimationPriority.Action
                track.Looped = false
                track:Play(0.1)
            end)
        else
            Toast("animação " .. tostring(animId) .. " não carregou — o fling vai sem ela", false)
        end
    end

    FL.on = true
    FL.last = { animId, apelido }
    if FL.plataforma then
        pcall(function() hum.PlatformStand = true end)
    end
    Toast("fling: " .. apelido .. " (aperte Parar pra sair)", true)

    local flip = 1
    FL.conn = RunService.Heartbeat:Connect(function()
        if not FL.on then return end
        local c = LocalPlayer.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if not (r and h) then
            flStop()
            return
        end

        flip = -flip
        local f = FL.forca * flip
        r.AssemblyLinearVelocity = Vector3.new(f, 0, f)
        r.AssemblyAngularVelocity = Vector3.new(f, f, f)

        RunService.RenderStepped:Wait()
        if not FL.on then return end

        local dir = h.MoveDirection
        if FL.perseguir then
            local perto = flNearest(r.Position)
            if perto then
                local tc = perto.Character
                local tr = tc and tc:FindFirstChild("HumanoidRootPart")
                if tr then
                    local d = tr.Position - r.Position
                    d = Vector3.new(d.X, 0, d.Z)
                    if d.Magnitude > 0.1 then dir = d.Unit end
                end
            end
        end

        if dir.Magnitude > 0 then
            r.AssemblyLinearVelocity = Vector3.new(dir.X * FL.velocidade, -2, dir.Z * FL.velocidade)
        else
            r.AssemblyLinearVelocity = Vector3.new(0, -2, 0)
        end
        r.AssemblyAngularVelocity = Vector3.zero
    end)
end

flAlvo = function(animId, apelido)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local alvo = flNearest(root and root.Position or Vector3.zero)
    if alvo then
        local tr = alvo.Character and alvo.Character:FindFirstChild("HumanoidRootPart")
        if tr and root then
            root.CFrame = CFrame.new(tr.Position + (tr.CFrame.LookVector * 4))
            task.wait(0.05)
        end
    end
    flPlay(animId, alvo and (apelido .. " em " .. alvo.Name) or apelido)
end

for _, a in ipairs(FLING_ANIM) do
    BtnRow("Fling: " .. a.nome, T.Accent, function()
        flAlvo(a.id, a.nome)
    end)
end

BtnRow("Parar Fling (solta o corpo)", T.Card, function()
    flStop()
    Toast("fling parado", true)
end)

BtnRow("Roleta (fling sem animação)", T.Card, function()
    flAlvo(nil, "roleta")
end)

BtnRow("Testar as 8 Animações (resultado no console)", T.Card, function()
    task.spawn(function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then
            Toast("sem personagem", false)
            return
        end
        local boas = 0
        for _, a in ipairs(FLING_ANIM) do
            local anim = Instance.new("Animation")
            anim.AnimationId = "rbxassetid://" .. a.id
            local animator = hum:FindFirstChildOfClass("Animator")
            local ok, track = pcall(function() return (animator or hum):LoadAnimation(anim) end)
            if ok and track then
                task.wait(0.25)
                if track.Length and track.Length > 0 then
                    boas = boas + 1
                    print("[silk] animação boa: " .. a.nome .. "  " .. a.id .. "  " .. string.format("%.2fs", track.Length))
                else
                    print("[silk] animação morta: " .. a.nome .. "  " .. a.id)
                end
                pcall(function() track:Destroy() end)
            else
                print("[silk] animação não carregou: " .. a.nome .. "  " .. a.id)
            end
        end
        Toast("animações boas: " .. boas .. " de " .. #FLING_ANIM .. " (veja o console)", boas > 0)
    end)
end)

BtnRow("Voadora em Todos (um por vez)", T.Card, function()
    task.spawn(function()
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then
                local tr = plr.Character:FindFirstChild("HumanoidRootPart")
                local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if tr and root then
                    root.CFrame = CFrame.new(tr.Position + (tr.CFrame.LookVector * 4))
                    flPlay(FLING_ANIM[1].id, "voadora em " .. plr.Name)
                    task.wait(1.4)
                end
            end
        end
        flStop()
        Toast("rodou em todos", true)
    end)
end)

Slider("Velocidade do fling", 1, 60, 16, "%.0f", function(v)
    FL.velocidade = v
end, "nd_fling_vel")

Slider("Força do fling (o soco)", 10000, 500000, 100000, "%.0f", function(v)
    FL.forca = v
end, "nd_fling_forca")

Toggle("Modo 100% (prende o corpo durante o fling)", true, function(v)
    FL.plataforma = v
    Toast("modo 100% " .. (v and "ligado" or "desligado"), v)
end, "nd_fling_plataforma")

Toggle("Religar o fling quando renascer", false, function(v)
    if flRespawnConn then flRespawnConn:Disconnect() end
    flRespawnConn = nil
    if v then
        flRespawnConn = LocalPlayer.CharacterAdded:Connect(function()
            task.wait(1)
            if FL.last then flPlay(FL.last[1], FL.last[2]) end
        end)
    end
    Toast("religar ao renascer " .. (v and "ligado" or "desligado"), v)
end, "nd_fling_respawn")

Toggle("Perseguir o alvo mais perto", true, function(v)
    FL.perseguir = v
end, "nd_fling_perseguir")

Toggle("Anti-queda (não morre caindo)", false, function(v)
    HackState.ndAntiFall = v
    if v then
        task.spawn(function()
            while HackState.ndAntiFall do
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root then
                    local vel = root.AssemblyLinearVelocity
                    root.AssemblyLinearVelocity = Vector3.zero
                    RunService.RenderStepped:Wait()
                    root.AssemblyLinearVelocity = vel
                end
                task.wait()
            end
        end)
    end
    Toast("anti-queda " .. (v and "ligado" or "desligado"), v)
end, "nd_antifall")

Toggle("Não morrer (vida cheia sempre)", false, function(v)
    HackState.ndGod = v
    if v then
        task.spawn(function()
            while HackState.ndGod do
                local char = LocalPlayer.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if hum then
                    pcall(function()
                        hum.MaxHealth = 100
                        hum.Health = 100
                    end)
                end
                task.wait(0.2)
            end
        end)
    end
    Toast("vida infinita " .. (v and "ligado" or "desligado"), v)
end, "nd_god")

-- ================================================================ meteoros
Section("Meteoros")

Note("Só os meteoros soltos respondem: peça presa pertence ao servidor e não anda pelo cliente.", 60)

local function ndMeteoros()
    local lista = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            local n = obj.Name:lower()
            if n:find("meteor", 1, true) or n:find("comet", 1, true) or n:find("asteroid", 1, true) then
                lista[#lista + 1] = obj
            end
        end
    end
    return lista
end

BtnRow("Contar Meteoros no Mapa", T.Card, function()
    local lista = ndMeteoros()
    local soltos = 0
    for _, m in ipairs(lista) do
        if not m.Anchored then soltos = soltos + 1 end
    end
    Toast("achei " .. #lista .. " meteoros (" .. soltos .. " soltos)", #lista > 0)
end)

BtnRow("Puxar Meteoros pra Mim", T.Accent, function()
    task.spawn(function()
        local lista = ndMeteoros()
        if #lista == 0 then
            Toast("nenhum meteoro no mapa agora", false)
            return
        end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local movidos = 0
        for _, m in ipairs(lista) do
            if not m.Anchored and m.Parent then
                pcall(function()
                    m.AssemblyLinearVelocity = Vector3.zero
                    m.AssemblyAngularVelocity = Vector3.zero
                    m.CFrame = CFrame.new(root.Position + Vector3.new(0, 12, 0))
                    movidos = movidos + 1
                end)
            end
        end
        Toast(movidos > 0 and ("puxei " .. movidos .. " meteoros") or "todos estavam presos ao servidor", movidos > 0)
    end)
end)

BtnRow("Jogar Meteoros no Alvo", T.Accent, function()
    task.spawn(function()
        local lista = ndMeteoros()
        if #lista == 0 then
            Toast("nenhum meteoro no mapa agora", false)
            return
        end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local alvo = flNearest(root and root.Position or Vector3.zero)
        if not alvo then
            Toast("sem alvo por perto", false)
            return
        end
        local tr = alvo.Character and alvo.Character:FindFirstChild("HumanoidRootPart")
        if not tr then
            Toast("alvo sem root", false)
            return
        end
        local jogados = 0
        for _, m in ipairs(lista) do
            if not m.Anchored and m.Parent then
                pcall(function()
                    m.CFrame = CFrame.new(tr.Position + Vector3.new(0, 18, 0))
                    m.AssemblyLinearVelocity = Vector3.new(0, -260, 0)
                    jogados = jogados + 1
                end)
            end
        end
        Toast("joguei " .. jogados .. " meteoros em " .. alvo.Name, jogados > 0)
    end)
end)

BtnRow("Soltar Meteoros (para tudo)", T.Card, function()
    local lista = ndMeteoros()
    for _, m in ipairs(lista) do
        if not m.Anchored then
            pcall(function()
                m.AssemblyLinearVelocity = Vector3.zero
                m.AssemblyAngularVelocity = Vector3.zero
            end)
        end
    end
    Toast("meteoros soltos", true)
end)

-- =================================================================== dump
Section("Dump do Jogo")

Note("Varre o jogo, copia pro clipboard e escreve silk_dump.txt. Serve pra achar remote de dano, peça de perigo e ferramenta.", 64)

local function ndDump(modo)
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("SILK CORE dump  place=" .. tostring(game.PlaceId) .. "  job=" .. tostring(game.JobId))
    add("")

    if modo == "tudo" or modo == "players" then
        add("[jogadores]")
        local meuRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        for _, plr in ipairs(Players:GetPlayers()) do
            local c = plr.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            local r = c and c:FindFirstChild("HumanoidRootPart")
            local dist = "-"
            if r and meuRoot then
                dist = tostring(math.floor((r.Position - meuRoot.Position).Magnitude))
            end
            add(string.format("  %-22s vida=%-4s dist=%-7s pos=%s",
                plr.Name,
                h and tostring(math.floor(h.Health)) or "-",
                dist,
                r and tostring(r.Position) or "-"))
        end
        add("")
    end

    if modo == "tudo" or modo == "remotes" then
        add("[remotes visiveis no cliente]")
        local rs = game:GetService("ReplicatedStorage")
        for _, obj in ipairs(rs:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") or obj:IsA("UnreliableRemoteEvent") then
                add("  " .. obj:GetFullName())
            end
        end
        add("")
    end

    if modo == "tudo" or modo == "perigo" then
        add("[peças de perigo / kill]")
        local chaves = { "kill", "damage", "death", "lava", "fire", "tornado", "flood", "water",
                         "meteor", "earthquake", "lightning", "blizzard", "sandstorm", "volcano" }
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("BasePart") then
                local n = obj.Name:lower()
                for _, k in ipairs(chaves) do
                    if n:find(k, 1, true) then
                        add(string.format("  %-40s anchored=%s size=%s", obj:GetFullName(), tostring(obj.Anchored), tostring(obj.Size)))
                        break
                    end
                end
            end
        end
        add("")
    end

    if modo == "tudo" or modo == "tools" then
        add("[ferramentas]")
        local pastas = { game:GetService("ReplicatedStorage"), Workspace, LocalPlayer:FindFirstChildOfClass("Backpack") }
        for _, raiz in ipairs(pastas) do
            if raiz then
                for _, obj in ipairs(raiz:GetDescendants()) do
                    if obj:IsA("Tool") then
                        add("  " .. obj:GetFullName())
                    end
                end
            end
        end
        add("")
    end

    if modo == "tudo" or modo == "scripts" then
        add("[scripts visiveis no cliente]")
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("Script") or obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
                add("  " .. obj.ClassName .. "  " .. obj:GetFullName())
            end
        end
        add("")
    end

    if modo == "tudo" or modo == "kill" then
        add("[caca ao kill]")
        local chaves = { "kill", "damage", "hit", "attack", "die", "death", "hurt", "burn", "brick" }
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("BasePart") then
                local n = obj.Name:lower()
                local bate = false
                for _, k in ipairs(chaves) do
                    if n:find(k, 1, true) then
                        bate = true
                        break
                    end
                end
                local toque = obj:FindFirstChildOfClass("TouchTransmitter") ~= nil
                if bate or toque then
                    add(string.format("  %-46s anchored=%-5s toque=%-5s size=%s",
                        obj:GetFullName(), tostring(obj.Anchored), tostring(toque), tostring(obj.Size)))
                end
            end
        end
        add("")
        add("[pecas soltas perto de mim - da pra puxar e jogar em alguem]")
        local meu = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if meu then
            local perto = {}
            for _, obj in ipairs(Workspace:GetDescendants()) do
                if obj:IsA("BasePart") and not obj.Anchored and obj ~= meu then
                    local d = (obj.Position - meu.Position).Magnitude
                    if d <= 400 then
                        perto[#perto + 1] = { d = d, p = obj }
                    end
                end
            end
            table.sort(perto, function(a, b) return a.d < b.d end)
            for i = 1, math.min(#perto, 60) do
                local it = perto[i]
                add(string.format("  %6.0f studs   %-42s size=%s", it.d, it.p:GetFullName(), tostring(it.p.Size)))
            end
            add("  total de pecas soltas ate 400 studs: " .. #perto)
        else
            add("  sem personagem agora")
        end
        add("")
    end

    local texto = table.concat(out, "\n")
    if setclipboard then pcall(setclipboard, texto) end
    if writefile then pcall(writefile, "silk_dump.txt", texto) end
    print("[SILK DUMP]\n" .. texto)
    Toast("dump: " .. #out .. " linhas (clipboard + silk_dump.txt + console)", true)
end

BtnRow("Dump: Tudo", T.Accent, function() ndDump("tudo") end)
BtnRow("Dump: Remotes", T.Card, function() ndDump("remotes") end)
BtnRow("Dump: Peças de Perigo", T.Card, function() ndDump("perigo") end)
BtnRow("Dump: Caça ao Kill", T.Accent, function() ndDump("kill") end)
BtnRow("Dump: Ferramentas", T.Card, function() ndDump("tools") end)
BtnRow("Dump: Scripts", T.Card, function() ndDump("scripts") end)
BtnRow("Dump: Jogadores", T.Card, function() ndDump("players") end)
Note("Dica: no meio do desastre, puxa o que já caiu. Paredes e peças presas entram se você liberar o toggle.", 68)

end

ndBuild()
end -- Desastres

--------------------------------------------------------------------------------
-- UNIVERSAL R15 FLING/VOADORA SYSTEM
--------------------------------------------------------------------------------
do
CurTab = Tab("Fling", 0, false)
Persist.Scope = "fling"

Section("Voadora Universal R15")
Note("Voadora por fisica de braco, para rig R15.", 52)

-- Estado do fling (Luau type-safe)
HackState.flingActive = false :: boolean
HackState.flingPower = 500 :: number
HackState.flingTarget = nil :: Player?
HackState.flingMode = "punch" :: string
HackState.flingConnections = {} :: {RBXScriptConnection}

-- Função otimizada para preparar personagem (melhor detecção R15)
local function setupFlingCharacter(): boolean
    local char = LocalPlayer.Character
    if not char then return false end
    
    local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
    local hum = char:FindFirstChildOfClass("Humanoid") :: Humanoid?
    if not root or not hum then return false end
    
    -- Verifica se é R15
    if hum.RigType ~= Enum.HumanoidRigType.R15 then
        Toast("personagem nao e R15", false)
        return false
    end
    
    -- Limpa setup anterior
    for _, conn in ipairs(HackState.flingConnections) do
        pcall(function() conn:Disconnect() end)
    end
    HackState.flingConnections = {}
    
    -- Remove todas as juntas antigas do sistema
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Motor6D") and (obj.Name:find("Shoulder") or obj.Name:find("Elbow")) then
            pcall(function() obj:Destroy() end)
        end
        -- Remove fling setup anterior
        if obj.Name == "FlingVelocity" or obj.Name == "FlingAttach" then
            pcall(function() obj:Destroy() end)
        end
    end
    
    task.wait(0.1) -- Delay para garantir que destruiu
    
    -- Cria o sistema de fling nos braços
    local leftUpperArm = char:FindFirstChild("LeftUpperArm") :: BasePart?
    local rightUpperArm = char:FindFirstChild("RightUpperArm") :: BasePart?
    local leftLowerArm = char:FindFirstChild("LeftLowerArm") :: BasePart?
    local rightLowerArm = char:FindFirstChild("RightLowerArm") :: BasePart?
    
    if not (leftUpperArm and rightUpperArm and leftLowerArm and rightLowerArm) then
        Toast("partes do braco nao encontradas", false)
        return false
    end
    
    local function createFlingVelocity(limb: BasePart, direction: number): BodyAngularVelocity
        local vel = Instance.new("BodyAngularVelocity")
        vel.Name = "FlingVelocity"
        vel.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
        vel.AngularVelocity = Vector3.zero
        vel.P = 10000
        vel.Parent = limb
        return vel
    end
    
    -- Cria velocidades angulares para todos os membros do braço
    createFlingVelocity(leftUpperArm, 1)
    createFlingVelocity(rightUpperArm, -1)
    createFlingVelocity(leftLowerArm, 1)
    createFlingVelocity(rightLowerArm, -1)
    
    -- Torna os braços massless para melhor física
    for _, limb in ipairs({leftUpperArm, rightUpperArm, leftLowerArm, rightLowerArm}) do
        limb.Massless = true
        limb.CanCollide = true
    end
    
    return true
end

-- Função de fling otimizada com melhor targeting e física
local function performFling(targetPlayer: Player): ()
    local char = LocalPlayer.Character
    if not char then return end
    
    local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then return end
    
    local targetChar = targetPlayer.Character
    if not targetChar then
        Toast("alvo sem personagem", false)
        return
    end
    
    local targetRoot = targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not targetRoot then
        Toast("alvo sem root", false)
        return
    end
    
    -- Coleta todos os limbs do braço
    local arms = {
        char:FindFirstChild("LeftUpperArm"),
        char:FindFirstChild("RightUpperArm"),
        char:FindFirstChild("LeftLowerArm"),
        char:FindFirstChild("RightLowerArm"),
        char:FindFirstChild("LeftHand"),
        char:FindFirstChild("RightHand")
    }
    
    -- Filtra nils
    local validArms = {}
    for _, arm in ipairs(arms) do
        if arm and arm:FindFirstChild("FlingVelocity") then
            table.insert(validArms, arm)
        end
    end
    
    if #validArms == 0 then
        Toast("faca o setup primeiro", false)
        return
    end
    
    -- Calcula distância e se aproxima se necessário
    local distance = (targetRoot.Position - root.Position).Magnitude
    if distance > 10 then
        -- Auto-approach com interpolação suave
        local targetPos = targetRoot.Position - (targetRoot.CFrame.LookVector * 4)
        targetPos = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z) -- Mantém Y
        
        local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local tween = TweenService:Create(root, tweenInfo, {CFrame = CFrame.new(targetPos, targetRoot.Position)})
        tween:Play()
        tween.Completed:Wait()
    end
    
    -- Prepara o fling attack
    local flingPower = HackState.flingPower or 500
    local flingDuration = 0.5 -- Duração do ataque em segundos
    
    Toast("FLING! poder: "..flingPower, true)
    
    task.spawn(function()
        local startTime = tick()
        local attackPhase = 0
        
        while (tick() - startTime) < flingDuration do
            if not targetRoot or not targetRoot.Parent then break end
            
            attackPhase = attackPhase + 1
            local phaseAngle = attackPhase * 0.5
            
            -- Anima os braços em direção ao alvo
            for i, arm in ipairs(validArms) do
                local vel = arm:FindFirstChild("FlingVelocity") :: BodyAngularVelocity?
                if vel then
                    -- Alterna direção para criar movimento de soco
                    local direction = (i % 2 == 0) and -1 or 1
                    local powerMultiplier = 1 + (math.sin(phaseAngle) * 0.3)
                    
                    vel.AngularVelocity = Vector3.new(
                        flingPower * direction * powerMultiplier,
                        flingPower * direction * powerMultiplier,
                        flingPower * direction * powerMultiplier
                    )
                    
                    -- Posiciona o braço próximo ao alvo para garantir colisão
                    local offsetAngle = (i / #validArms) * math.pi * 2
                    local offsetX = math.cos(offsetAngle + phaseAngle) * 2
                    local offsetZ = math.sin(offsetAngle + phaseAngle) * 2
                    
                    arm.CFrame = CFrame.new(
                        targetRoot.Position + Vector3.new(offsetX, 0, offsetZ)
                    )
                end
            end
            
            task.wait()
        end
        
        -- Para o fling após o ataque
        for _, arm in ipairs(validArms) do
            local vel = arm:FindFirstChild("FlingVelocity") :: BodyAngularVelocity?
            if vel then
                vel.AngularVelocity = Vector3.zero
            end
        end
        
        Toast("fling completo", true)
    end)
end

BtnRow("Setup Fling (R15)", T.Accent, function()
    Toast("preparando personagem para fling...", true)
    local success = setupFlingCharacter()
    if success then
        Toast("fling preparado! use os botoes abaixo", true)
    else
        Toast("falhou - certifique-se que e R15", false)
    end
end)

Section("Configuracao do Fling")

Slider("Poder do Fling", 100, 2000, 500, "%d", function(v)
    HackState.flingPower = v
end, "fling_power")

Note("Poder 500 = medio | 1000 = forte | 2000 = ULTRA", 40)

Section("Alvos do Fling")

do
    local row = Row(50)
    Label(row, "Nome do Alvo", 12, T.Text, F.Bold, nil, UDim2.fromOffset(16, 0), UDim2.new(0.35, 0, 1, 0))
    local targetField = Field(row, UDim2.new(0.37, 0, 0.5, -15), UDim2.new(0.35, 0, 0, 30), "username...")
    Button(row, "FLING", UDim2.new(0.74, 0, 0.5, -15), UDim2.fromOffset(80, 30), T.Accent, function()
        local targetName = targetField.Text
        local target = Players:FindFirstChild(targetName)
        
        if target and target ~= LocalPlayer then
            performFling(target)
            Toast("fling executado em "..targetName, true)
        else
            Toast("jogador nao encontrado", false)
        end
    end)
end

BtnRow("Fling Player Mais Próximo", T.Accent, function()
    local root = hkRoot()
    if not root then return end
    
    local closest = nil
    local closestDist = 9999
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
            if targetRoot then
                local dist = (targetRoot.Position - root.Position).Magnitude
                if dist < closestDist then
                    closest = player
                    closestDist = dist
                end
            end
        end
    end
    
    if closest then
        performFling(closest)
        Toast("fling em "..closest.Name.." ("..math.floor(closestDist).." studs)", true)
    else
        Toast("nenhum player proximo", false)
    end
end)

Toggle("Auto Fling Proximos", false, function(v)
    HackState.autoFlingNearby = v
    if v then
        task.spawn(function()
            while HackState.autoFlingNearby do
                local root = hkRoot()
                if root then
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
                            if targetRoot and (targetRoot.Position - root.Position).Magnitude < 15 then
                                performFling(player)
                                task.wait(2)
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end
    Toast("auto fling proximos "..(v and "ligado" or "desligado"), v)
end, "fling_auto")

Section("Modos de Ataque")

BtnRow("Modo: Soco Único", T.Accent, function()
    HackState.flingMode = "punch"
    Toast("modo: soco unico", true)
end)

BtnRow("Modo: Voadora (Combo)", T.Accent, function()
    HackState.flingMode = "flying_kick"
    Toast("modo: voadora combo", true)
end)

BtnRow("Modo: Spin Attack", T.Accent, function()
    HackState.flingMode = "spin"
    HackState.flingActive = true
    
    task.spawn(function()
        local char = LocalPlayer.Character
        if char then
            local root = char:FindFirstChild("HumanoidRootPart")
            for i = 1, 20 do
                if root and HackState.flingActive then
                    root.CFrame = root.CFrame * CFrame.Angles(0, math.rad(18), 0)
                    
                    -- Fling em todos próximos
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player ~= LocalPlayer and player.Character then
                            local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
                            if targetRoot and (targetRoot.Position - root.Position).Magnitude < 10 then
                                performFling(player)
                            end
                        end
                    end
                end
                task.wait(0.05)
            end
            HackState.flingActive = false
        end
    end)
end)

BtnRow("Parar Fling", T.Card, function()
    HackState.flingActive = false
    HackState.autoFlingNearby = false
    
    local char = LocalPlayer.Character
    if char then
        for _, limb in ipairs(char:GetDescendants()) do
            if limb:FindFirstChild("FlingVelocity") then
                limb.FlingVelocity.AngularVelocity = Vector3.new(0, 0, 0)
            end
        end
    end
    
    Toast("fling parado", true)
end)

Section("Sistema Avancado")

Toggle("Fling com Animação", true, function(v)
    HackState.flingAnim = v
    Toast("fling animation "..(v and "ligado" or "desligado"), v)
end, "fling_anim")

Toggle("Auto Aim no Alvo", true, function(v)
    HackState.flingAutoAim = v
    Toast("auto aim "..(v and "ligado" or "desligado"), v)
end, "fling_aim")

Toggle("Fling Stealth Mode", false, function(v)
    HackState.flingStealth = v
    if v then
        -- Reduz a velocidade e poder para ser menos óbvio
        HackState.flingPower = math.min(HackState.flingPower, 300)
        Toast("stealth mode ligado - poder reduzido", true)
    else
        Toast("stealth mode desligado", true)
    end
end, "fling_stealth")

Note("Faz o setup uma vez e usa em qualquer rig R15.", 68)

end -- Fling

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
    add("== HITBOXES ATIVAS (BasePart sem CanCollide, dono â‰  local) ==")
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

-- 3. Randomização de timing: adiciona jitter Ã s ações pra não parecer bot
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
            if v == true then rel[i] = false else rel[i] = v end
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
    Toast(on and "GUI movida pro container oculto do executor" or "GUI de volta Ã  árvore normal", true)
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