--[[
    SILK CORE - loader com diagnostico
    Busca o script em varios espelhos, recusa resposta curta, vazia ou de
    build antigo, e mostra o erro na tela em vez de falhar em silencio.
]]

local MIN_BYTES = 300000
local MARKER    = "buildBrookhaven()"   -- presente so na build atual

local URLS = {
    "https://raw.githubusercontent.com/silkcoree-png/silk/main/silk.lua",
    "https://cdn.jsdelivr.net/gh/silkcoree-png/silk@main/silk.lua?v=4",
    "https://raw.githack.com/silkcoree-png/silk/main/silk.lua",
    "https://rawcdn.githack.com/silkcoree-png/silk/main/silk.lua",
}

local function notify(title, text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title, Text = tostring(text):sub(1, 200), Duration = 12,
        })
    end)
    warn("[silk] " .. tostring(title) .. " :: " .. tostring(text))
end

local function get_body(url)
    if syn and syn.request then
        local ok, res = pcall(syn.request, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and type(res.Body) == "string" then return res.Body end
    end
    if request then
        local ok, res = pcall(request, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and type(res.Body) == "string" then return res.Body end
    end
    if http_request then
        local ok, res = pcall(http_request, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and type(res.Body) == "string" then return res.Body end
    end
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" then return body end
    return nil
end

local src, source_url
for i, u in ipairs(URLS) do
    local body = get_body(u)
    if body and #body >= MIN_BYTES and body:find(MARKER, 1, true) then
        src, source_url = body, u
        warn(string.format("[silk] fonte %d ok: %d bytes", i, #body))
        break
    end
    if body and #body >= MIN_BYTES then
        warn(string.format("[silk] fonte %d: build antiga em cache (%d bytes)", i, #body))
    else
        warn(string.format("[silk] fonte %d falhou: %s", i,
            body and ("bytes=" .. #body) or "sem resposta"))
    end
end

if not src then
    return notify("Silk Core", "nenhum espelho serviu a build atual — cache do CDN, tente de novo em 1 min")
end

local fn, parse_err = loadstring(src, "silk")
if not fn then
    return notify("Silk Core", "erro de sintaxe: " .. tostring(parse_err))
end

local ok, run_err = pcall(fn)
if not ok then
    return notify("Silk Core", "erro em execucao: " .. tostring(run_err))
end

warn("[silk] carregado de " .. source_url)