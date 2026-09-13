-- GTNH 2.9.0-beta-3
-- Monitor de conteudo de uma subnetwork ME pela ME Controller.
-- Nao calcula capacidade, teto ou porcentagem de preenchimento.

local component = require("component")
local unicode = require("unicode")
local os = require("os")

local REFRESH_SECONDS = 30
local LIST_SIZE = 30

local COLOR = {
  background = 0x071217,
  foreground = 0xD8F6EE,
  muted = 0x79A99E,
  rule = 0x24524D,
  item = 0x43E0B2,
  fluid = 0x55B8E8,
  essentia = 0xC18CFF,
  danger = 0xFF6B6B
}

local gpu = assert(component.gpu, "GPU nao encontrada")
local screenAddress = component.list("screen")()
assert(screenAddress, "Screen nao encontrada")

gpu.bind(screenAddress, true)
pcall(gpu.setDepth, gpu.maxDepth())

local maxWidth, maxHeight = gpu.maxResolution()
assert(maxWidth >= 120 and maxHeight >= 35,
  "Use uma GPU T3 e uma Screen T3")
gpu.setResolution(maxWidth, maxHeight)

local width, height = gpu.getResolution()
local columnWidth = math.floor((width - 8) / 3)

local function setColors(foreground, background)
  gpu.setForeground(foreground or COLOR.foreground)
  gpu.setBackground(background or COLOR.background)
end

local function write(x, y, value, foreground)
  if x < 1 or x > width or y < 1 or y > height then return end
  value = tostring(value or "")
  local available = width - x + 1
  if unicode.len(value) > available then
    value = unicode.sub(value, 1, available)
  end
  setColors(foreground, COLOR.background)
  gpu.set(x, y, value)
end

local function writeRight(x, y, value, foreground)
  value = tostring(value or "")
  write(x - unicode.len(value) + 1, y, value, foreground)
end

local function truncate(value, maximum)
  value = tostring(value or "?")
  if unicode.len(value) <= maximum then return value end
  return unicode.sub(value, 1, math.max(1, maximum - 1)) .. "~"
end

local function rule(y)
  setColors(COLOR.rule, COLOR.background)
  gpu.fill(2, y, width - 2, 1, "-")
end

local function formatNumber(value)
  local suffixes = {"", "k", "M", "G", "T", "P", "E"}
  local index = 1
  value = tonumber(value) or 0

  while math.abs(value) >= 1000 and index < #suffixes do
    value = value / 1000
    index = index + 1
  end

  local digits = math.abs(value) >= 100 and 0 or
                 math.abs(value) >= 10 and 1 or 2
  return string.format("%." .. digits .. "f", value):gsub("%.", ",") .. suffixes[index]
end

local function normalize(stack, fallback)
  local amount = tonumber(stack.size or stack.amount or 0) or 0
  local label = stack.label or stack.name or fallback or "?"
  return {label = tostring(label), amount = amount}
end

local function readItems(me)
  local result = {}
  local iterator = me.allItems()
  while true do
    local stack = iterator()
    if not stack then break end
    local entry = normalize(stack, "item")
    if entry.amount > 0 then result[#result + 1] = entry end
  end
  return result
end

local function readFluids(me)
  local result = {}
  if type(me.getFluidsInNetwork) ~= "function" then
    return result, "API indisponivel"
  end
  local stacks = me.getFluidsInNetwork() or {}
  for _, stack in pairs(stacks) do
    local entry = normalize(stack, "fluido")
    if entry.amount > 0 then result[#result + 1] = entry end
  end
  return result
end

local function readEssentia(me)
  local result = {}
  if type(me.getEssentiaInNetwork) ~= "function" then
    return result, "API indisponivel"
  end
  local stacks = me.getEssentiaInNetwork() or {}
  for _, stack in pairs(stacks) do
    local entry = normalize(stack, "aspecto")
    if entry.amount > 0 then result[#result + 1] = entry end
  end
  return result
end

local function summarize(reader, me)
  local ok, entries, note = pcall(reader, me)
  if not ok then
    return {entries = {}, total = 0, types = 0, error = tostring(entries)}
  end

  table.sort(entries, function(a, b)
    if a.amount == b.amount then return a.label < b.label end
    return a.amount > b.amount
  end)

  local total = 0
  for _, entry in ipairs(entries) do total = total + entry.amount end
  return {entries = entries, total = total, types = #entries, note = note}
end

local function drawColumn(x, title, summary, color, unit)
  local right = x + columnWidth - 1
  write(x, 5, title, color)
  write(x, 7, "TOTAL", COLOR.muted)
  writeRight(right, 7, formatNumber(summary.total) .. unit, COLOR.foreground)
  write(x, 8, "TIPOS", COLOR.muted)
  writeRight(right, 8, summary.types, COLOR.foreground)

  if summary.error then
    write(x, 11, "ERRO DE LEITURA", COLOR.danger)
    write(x, 12, truncate(summary.error, columnWidth), COLOR.danger)
    return
  elseif summary.note then
    write(x, 11, summary.note, COLOR.muted)
    return
  elseif #summary.entries == 0 then
    write(x, 11, "VAZIO", COLOR.muted)
    return
  end

  write(x, 10, "MAIORES CONTEUDOS", COLOR.muted)
  for index = 1, math.min(LIST_SIZE, #summary.entries) do
    local entry = summary.entries[index]
    local y = 11 + index
    local prefix = string.format("%2d ", index)
    local amount = formatNumber(entry.amount) .. unit
    local labelWidth = columnWidth - unicode.len(prefix) - unicode.len(amount) - 1
    write(x, y, prefix .. truncate(entry.label, labelWidth), COLOR.foreground)
    writeRight(right, y, amount, color)
  end
end


local function draw(items, fluids, essentia)
  setColors(COLOR.foreground, COLOR.background)
  gpu.fill(1, 1, width, height, " ")

  write(3, 2, "ME STORAGE CONTENTS // ZPM", COLOR.foreground)
  writeRight(width - 2, 2, "ONLINE", COLOR.item)
  rule(4)

  local x1 = 3
  local x2 = x1 + columnWidth + 2
  local x3 = x2 + columnWidth + 2

  drawColumn(x1, "ITENS", items, COLOR.item, "")
  drawColumn(x2, "FLUIDOS", fluids, COLOR.fluid, "L")
  drawColumn(x3, "ESSENTIA", essentia, COLOR.essentia, "")

  setColors(COLOR.rule, COLOR.background)
  gpu.fill(x2 - 1, 5, 1, height - 9, "|")
  gpu.fill(x3 - 1, 5, 1, height - 9, "|")

  rule(height - 3)
  write(3, height - 1, "SOMENTE CONTEUDO ATUAL", COLOR.muted)
  writeRight(width - 2, height - 1,
    "ATUALIZA A CADA " .. REFRESH_SECONDS .. "s", COLOR.muted)
end

local function drawFatal(message)
  setColors(COLOR.foreground, COLOR.background)
  gpu.fill(1, 1, width, height, " ")
  write(3, 2, "ME STORAGE CONTENTS // ERRO", COLOR.danger)
  rule(4)
  write(3, 7, truncate(message, width - 6), COLOR.danger)
  write(3, 9, "Nova tentativa em " .. REFRESH_SECONDS .. " segundos.", COLOR.muted)
end

while true do
  local ok, message = pcall(function()
    local me = component.me_controller or component.me_interface
    assert(me, "ME Controller ou ME Interface nao encontrado")

    local items = summarize(readItems, me)
    local fluids = summarize(readFluids, me)
    local essentia = summarize(readEssentia, me)
    draw(items, fluids, essentia)
  end)

  if not ok then drawFatal(tostring(message)) end
  os.sleep(REFRESH_SECONDS)
end
