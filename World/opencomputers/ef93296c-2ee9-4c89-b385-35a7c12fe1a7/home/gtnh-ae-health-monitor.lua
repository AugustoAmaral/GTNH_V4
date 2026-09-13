-- GTNH 2.9.0-beta-3
-- Monitor central de saude para uma rede ME de crafting e transporte P2P.
-- P2P/canais nao sao expostos pela API do OpenComputers nesta versao.

local component = require("component")
local computer = require("computer")
local unicode = require("unicode")
local os = require("os")

local REFRESH_SECONDS = 10
local QUIET_WARNING_SECONDS = 600
local MAX_CPU_ROWS = 16

local COLOR = {
  background = 0x071217,
  foreground = 0xD8F6EE,
  muted = 0x79A99E,
  rule = 0x24524D,
  good = 0x43E0B2,
  info = 0x55B8E8,
  warning = 0xF1C75B,
  danger = 0xFF6B6B,
  track = 0x17312F
}

local gpu = assert(component.gpu, "GPU nao encontrada")
local screenAddress = component.list("screen")()
assert(screenAddress, "Screen nao encontrada")
local screen = component.proxy(screenAddress)

gpu.bind(screenAddress, true)
pcall(gpu.setDepth, gpu.maxDepth())

local maxWidth, maxHeight = gpu.maxResolution()
local blocksWide, blocksHigh = screen.getAspectRatio()
local screenRatio = (blocksWide * 2 - 0.5) / (blocksHigh - 0.25)
if screenRatio > maxWidth / maxHeight then
  maxHeight = math.floor(maxWidth / screenRatio)
else
  maxWidth = math.floor(maxHeight * screenRatio)
end
assert(maxWidth >= 100 and maxHeight >= 40,
  "Use uma GPU T3 e uma Screen T3 grande")
gpu.setResolution(maxWidth, maxHeight)

local width, height = gpu.getResolution()
local cpuHistory = {}

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

local function percent(value, maximum)
  if not maximum or maximum <= 0 then return 0 end
  return math.max(0, math.min(100, value / maximum * 100))
end

local function decimal(value, digits)
  return string.format("%." .. digits .. "f", value):gsub("%.", ",")
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
  return decimal(value, digits) .. suffixes[index]
end

local function formatDuration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  return decimal(seconds / 3600, 1) .. "h"
end

local function invoke(address, method, fallback, ...)
  local ok, result, reason = pcall(component.invoke, address, method, ...)
  if not ok then return fallback, tostring(result) end
  return result, reason
end

local function safeCall(method, fallback)
  if not method then return fallback, "metodo indisponivel" end
  local ok, result, reason = pcall(method)
  if not ok then return fallback, tostring(result) end
  return result or fallback, reason
end

local function sumStacks(stacks)
  local total = 0
  local types = 0
  for _, stack in pairs(stacks or {}) do
    local amount = tonumber(stack.size or stack.amount or 0) or 0
    if amount > 0 then
      total = total + amount
      types = types + 1
    end
  end
  return total, types
end

local function bar(y, label, value, color)
  local x = 3
  local barWidth = width - 4
  local filled = math.floor(barWidth * math.max(0, math.min(100, value)) / 100 + 0.5)
  write(x, y, label, COLOR.muted)
  writeRight(width - 2, y, decimal(value, 1) .. "%", COLOR.foreground)
  setColors(COLOR.foreground, COLOR.track)
  gpu.fill(x, y + 1, barWidth, 1, " ")
  if filled > 0 then
    setColors(COLOR.foreground, color)
    gpu.fill(x, y + 1, filled, 1, " ")
  end
end

local function scanPower(meAddress)
  local stored, e1 = invoke(meAddress, "getStoredPower", 0)
  local maximum, e2 = invoke(meAddress, "getMaxStoredPower", 0)
  local input, e3 = invoke(meAddress, "getAvgPowerInjection", 0)
  local usage, e4 = invoke(meAddress, "getAvgPowerUsage", 0)
  local idle, e5 = invoke(meAddress, "getIdlePowerUsage", 0)
  return {
    stored = tonumber(stored) or 0,
    maximum = tonumber(maximum) or 0,
    input = tonumber(input) or 0,
    usage = tonumber(usage) or 0,
    idle = tonumber(idle) or 0,
    error = e1 or e2 or e3 or e4 or e5
  }
end

local function scanCpus(meAddress)
  local raw, errorMessage = invoke(meAddress, "getCpus", {})
  local rows = {}
  local now = computer.uptime()

  for index, entry in ipairs(raw or {}) do
    local cpu = entry.cpu
    local active = {}
    local pending = {}
    local staged = {}
    local output = nil

    if entry.busy and cpu then
      active = safeCall(cpu.activeItems, {})
      pending = safeCall(cpu.pendingItems, {})
      staged = safeCall(cpu.storedItems, {})
      output = safeCall(cpu.finalOutput, nil)
    end

    local activeAmount = sumStacks(active)
    local pendingAmount = sumStacks(pending)
    local stagedAmount = sumStacks(staged)
    local outputLabel = output and (output.label or output.name) or
      (entry.busy and "sem crafting monitor" or "-")
    local outputAmount = output and tonumber(output.size or output.amount or 0) or 0
    local name = tostring(entry.name or ("CPU " .. index))
    local key = name .. "#" .. index
    local signature = table.concat({
      tostring(entry.busy), tostring(outputLabel), tostring(outputAmount),
      tostring(activeAmount), tostring(pendingAmount), tostring(stagedAmount)
    }, "|")

    local history = cpuHistory[key]
    if not history or history.signature ~= signature or not entry.busy then
      history = {signature = signature, changedAt = now}
      cpuHistory[key] = history
    end

    rows[#rows + 1] = {
      name = name,
      busy = not not entry.busy,
      storage = tonumber(entry.storage) or 0,
      coprocessors = tonumber(entry.coprocessors) or 0,
      output = tostring(outputLabel),
      active = activeAmount,
      pending = pendingAmount,
      staged = stagedAmount,
      quiet = entry.busy and (now - history.changedAt) or 0
    }
  end

  table.sort(rows, function(a, b)
    if a.busy ~= b.busy then return a.busy end
    return a.name < b.name
  end)
  return rows, errorMessage
end

local function draw(power, cpus, cpuError)
  setColors(COLOR.foreground, COLOR.background)
  gpu.fill(1, 1, width, height, " ")

  local bufferPercent = percent(power.stored, power.maximum)
  local balance = power.input - power.usage
  local busy = 0
  local storage = 0
  local coprocessors = 0
  local quietWarnings = 0
  for _, cpu in ipairs(cpus) do
    if cpu.busy then busy = busy + 1 end
    storage = storage + cpu.storage
    coprocessors = coprocessors + cpu.coprocessors
    if cpu.quiet >= QUIET_WARNING_SECONDS then quietWarnings = quietWarnings + 1 end
  end

  local healthy = not power.error and not cpuError and
    bufferPercent >= 20 and balance >= 0 and quietWarnings == 0
  write(3, 2, "AE CORE HEALTH // CRAFT + P2P", COLOR.foreground)
  writeRight(width - 2, 2, healthy and "● SAUDAVEL" or "● ATENCAO",
    healthy and COLOR.good or COLOR.warning)
  rule(4)

  bar(6, "RESERVA DE ENERGIA", bufferPercent,
    bufferPercent < 20 and COLOR.danger or COLOR.good)
  write(3, 9, "ARMAZENADA", COLOR.muted)
  write(18, 9, formatNumber(power.stored) .. " AE", COLOR.foreground)
  write(44, 9, "ENTRADA", COLOR.muted)
  write(55, 9, formatNumber(power.input) .. " AE/t", COLOR.info)
  write(81, 9, "CONSUMO", COLOR.muted)
  write(93, 9, formatNumber(power.usage) .. " AE/t", COLOR.foreground)
  write(3, 11, "SALDO", COLOR.muted)
  write(18, 11, (balance >= 0 and "+" or "") .. formatNumber(balance) .. " AE/t",
    balance >= 0 and COLOR.good or COLOR.danger)
  write(44, 11, "IDLE", COLOR.muted)
  write(55, 11, formatNumber(power.idle) .. " AE/t", COLOR.foreground)
  if power.error then write(81, 11, "ERRO DE ENERGIA", COLOR.danger) end

  rule(13)
  write(3, 15, "CRAFTING CPUS", COLOR.info)
  write(22, 15, "OCUPADAS " .. busy .. "/" .. #cpus, COLOR.foreground)
  write(44, 15, "MEM TOTAL " .. formatNumber(storage) .. "B", COLOR.foreground)
  write(76, 15, "COPROCS " .. coprocessors, COLOR.foreground)
  write(100, 15, "SEM MUDANCA " .. quietWarnings, quietWarnings > 0 and COLOR.warning or COLOR.good)

  write(3, 17, "CPU", COLOR.muted)
  write(20, 17, "ESTADO", COLOR.muted)
  write(29, 17, "SAIDA FINAL", COLOR.muted)
  writeRight(77, 17, "ATIVO", COLOR.muted)
  writeRight(87, 17, "PENDENTE", COLOR.muted)
  writeRight(97, 17, "INTERNO", COLOR.muted)
  writeRight(108, 17, "MEM", COLOR.muted)
  writeRight(114, 17, "CO", COLOR.muted)
  writeRight(width - 2, 17, "SEM ALTERAR", COLOR.muted)

  local rowY = 18
  if cpuError then
    write(3, rowY, "ERRO AO LER CPUS: " .. truncate(cpuError, width - 20), COLOR.danger)
  elseif #cpus == 0 then
    write(3, rowY, "NENHUM CRAFTING CPU ENCONTRADO", COLOR.warning)
  else
    for index = 1, math.min(MAX_CPU_ROWS, #cpus) do
      local cpu = cpus[index]
      local y = rowY + index - 1
      local state = cpu.busy and "OCUPADO" or "LIVRE"
      local stateColor = cpu.quiet >= QUIET_WARNING_SECONDS and COLOR.warning or
        (cpu.busy and COLOR.info or COLOR.good)
      write(3, y, truncate(cpu.name, 15), COLOR.foreground)
      write(20, y, state, stateColor)
      write(29, y, truncate(cpu.output, 31), COLOR.foreground)
      writeRight(77, y, formatNumber(cpu.active), COLOR.foreground)
      writeRight(87, y, formatNumber(cpu.pending), COLOR.foreground)
      writeRight(97, y, formatNumber(cpu.staged), COLOR.foreground)
      writeRight(108, y, formatNumber(cpu.storage), COLOR.foreground)
      writeRight(114, y, cpu.coprocessors, COLOR.foreground)
      writeRight(width - 2, y, cpu.busy and formatDuration(cpu.quiet) or "-", stateColor)
    end
  end

  local p2pY = height - 7
  rule(p2pY - 1)
  write(3, p2pY, "P2P", COLOR.warning)
  write(9, p2pY, "SEM TELEMETRIA DIRETA NA API DO OC", COLOR.muted)
  write(3, p2pY + 2,
    "AUDITORIA DE TUNEIS E CANAIS: BETTERP2P MEMORY CARD", COLOR.foreground)

  rule(height - 3)
  write(3, height - 1, "ALERTA: RESERVA <20% | SALDO NEGATIVO | CPU SEM MUDANCA >10m", COLOR.muted)
  writeRight(width - 2, height - 1, "SCAN " .. REFRESH_SECONDS .. "s", COLOR.muted)
end

local function drawFatal(message)
  setColors(COLOR.foreground, COLOR.background)
  gpu.fill(1, 1, width, height, " ")
  write(3, 2, "AE CORE HEALTH // OFFLINE", COLOR.danger)
  rule(4)
  write(3, 7, truncate(message, width - 6), COLOR.danger)
  write(3, 9, "Nova tentativa em " .. REFRESH_SECONDS .. " segundos.", COLOR.muted)
end

while true do
  local ok, message = pcall(function()
    local meAddress = component.list("me_controller", true)()
    assert(meAddress, "ME Controller nao encontrada")
    local power = scanPower(meAddress)
    local cpus, cpuError = scanCpus(meAddress)
    draw(power, cpus, cpuError)
  end)
  if not ok then drawFatal(tostring(message)) end
  os.sleep(REFRESH_SECONDS)
end
