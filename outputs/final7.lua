local component = require("component")

------------------------------------------------
-- CONFIG
------------------------------------------------
local PULSE_SIDE   = 0

local IDLE_POLL_SECONDS = 1
local INPUT_STABLE_SECONDS = 5
local FLUSH_PULSE_SECONDS = 5

local PLASMA_RETRY_SECONDS          = 30
local RETRIES_BEFORE_CRAFT_CANCEL  = 30
local CRAFT_CANCEL_SETTLE_SECONDS  = 2
local PLASMA_WATCH_POLL_SECONDS     = 1
local PLASMA_CLEAR_STABLE_POLLS     = 3

------------------------------------------------
-- ME
------------------------------------------------
local storageAddr  = "54bc4eb1-f01f-493a-a0e7-caea2cca9996"
local craftingAddr = "64272e40-2a06-491c-84b1-e7c7c9cac969"

local storageME  = assert(component.proxy(storageAddr),  "Storage ME controller not found")
local craftingME = assert(component.proxy(craftingAddr), "Crafting ME controller not found")

------------------------------------------------
-- CONSTANTS
------------------------------------------------
local DUST_PLASMA_PER_DUST  = 1296
local FLUID_PLASMA_PER_UNIT = 1000

local DUST_PLASMA_PER_CELL  = 144
local FLUID_PLASMA_PER_CELL = 1000

------------------------------------------------
-- REDSTONE
------------------------------------------------
local redstone = assert(component.redstone, "No redstone card found")

------------------------------------------------
-- LOAD STORE
------------------------------------------------
local plasmaCellStore = assert(
  dofile("/home/plasma_cell_store.lua"),
  "Failed to load plasma_cell_store.lua"
)

------------------------------------------------
-- HELPERS
------------------------------------------------
local function normalizeDustLabel(label)
  return label
    :gsub("^[Tt]iny Pile of ", "")
    :gsub("^[Ss]mall Pile of ", "")
    :gsub("^[Pp]ile of ", "")
    :gsub(" Dust$", "")
end

local function isEmptyCellLabel(label)
  local normalized = tostring(label or "")
    :lower()
    :gsub("^%s+", "")
    :gsub("%s+$", "")

  return normalized == "cell"
      or normalized == "empty cell"
      or normalized == "empty fluid cell"
end

local function ceilDiv(a, b)
  return math.floor((a + b - 1) / b)
end

local function getRecipe(base)
  local stack = plasmaCellStore[base]
  if not stack then
    return nil
  end

  local ok, recipes = pcall(craftingME.getCraftables, {
    name   = stack.name,
    damage = stack.damage,
    label  = stack.label
  })

  if not ok or not recipes or #recipes == 0 then
    return nil
  end

  return recipes[1]
end

local function getCraftingState(status)
  if not status then
    return "missing", "no crafting status returned"
  end

  local canceledOk, canceled, canceledReason = pcall(function()
    return status.isCanceled()
  end)
  if canceledOk and canceled then
    return "canceled", canceledReason
  end

  local doneOk, done, doneReason = pcall(function()
    return status.isDone()
  end)
  if doneOk and done then
    return "done", doneReason
  end

  if not canceledOk or not doneOk then
    return "unknown", "unable to read crafting status"
  end

  return "active"
end

local function stacksMatch(left, right)
  if not left or not right then
    return false
  end

  if left.name and right.name and left.name ~= right.name then
    return false
  end
  if left.damage ~= nil and right.damage ~= nil and left.damage ~= right.damage then
    return false
  end
  if left.label and right.label and left.label ~= right.label then
    return false
  end

  return (left.name ~= nil and right.name ~= nil)
      or (left.label ~= nil and right.label ~= nil)
end

local function cpuContainsTarget(cpuHandle, target)
  local outputOk, output = pcall(function()
    return cpuHandle.finalOutput()
  end)
  if outputOk and stacksMatch(output, target) then
    return true
  end

  local activeOk, activeItems = pcall(function()
    return cpuHandle.activeItems()
  end)
  if activeOk and activeItems then
    for _, stack in ipairs(activeItems) do
      if stacksMatch(stack, target) then
        return true
      end
    end
  end

  local pendingOk, pendingItems = pcall(function()
    return cpuHandle.pendingItems()
  end)
  if pendingOk and pendingItems then
    for _, stack in ipairs(pendingItems) do
      if stacksMatch(stack, target) then
        return true
      end
    end
  end

  return false
end

local function cancelStuckCrafts(job)
  local target = plasmaCellStore[job.base]
  if not target then
    print("    cannot cancel: no stored Plasma Cell identity for " .. tostring(job.base))
    return 0
  end

  local ok, cpus = pcall(craftingME.getCpus)
  if not ok or not cpus then
    print("    cannot inspect crafting CPUs: " .. tostring(cpus))
    return 0
  end

  local busyCpus = {}
  local matchingCpus = {}

  for _, info in ipairs(cpus) do
    if info.busy and info.cpu then
      busyCpus[#busyCpus + 1] = info
      if cpuContainsTarget(info.cpu, target) then
        matchingCpus[#matchingCpus + 1] = info
      end
    end
  end

  -- If output inspection is unavailable but exactly one CPU is busy,
  -- that CPU is the only possible owner of this stuck plasma craft.
  if #matchingCpus == 0 and #busyCpus == 1 then
    matchingCpus[1] = busyCpus[1]
    print("    target output was unavailable; using the only busy crafting CPU.")
  end

  if #matchingCpus == 0 then
    print(string.format(
      "    no uniquely matching busy CPU found; %d busy CPU(s) left untouched.",
      #busyCpus
    ))
    return 0
  end

  local canceled = 0
  for _, info in ipairs(matchingCpus) do
    local cancelOk, didCancel = pcall(function()
      return info.cpu.cancel()
    end)

    if cancelOk and didCancel then
      canceled = canceled + 1
      print("    canceled crafting CPU: " .. tostring(info.name or "unnamed"))
    else
      print(string.format(
        "    failed to cancel crafting CPU %s: %s",
        tostring(info.name or "unnamed"),
        tostring(didCancel)
      ))
    end
  end

  return canceled
end

local function submitPlasmaRequest(job, isRetry)
  if isRetry then
    job.retries = job.retries + 1
    job.retriesSinceCancel = job.retriesSinceCancel + 1
  end

  local recipe = getRecipe(job.base)
  if not recipe then
    job.status = nil
    print(string.format(
      "  %s: no %s Plasma Cell pattern on crafting ME %s",
      isRetry and "RETRY FAILED" or "SKIP",
      tostring(job.base),
      craftingAddr
    ))
    return false
  end

  local ok, status, reason = pcall(function()
    return recipe.request(job.cells)
  end)

  if not ok then
    job.status = nil
    print("  request() error: " .. tostring(status))
    return false
  end

  if not status then
    job.status = nil
    print("  request() rejected: " .. tostring(reason or "no crafting status returned"))
    return false
  end

  job.status = status
  job.quietSeconds = 0
  print(string.format(
    "  %s sent to crafting ME %s%s",
    isRetry and "retry" or "cell request()",
    craftingAddr,
    isRetry and string.format(" (retry #%d)", job.retries) or ""
  ))
  return true
end

------------------------------------------------
-- CLEAN CHECK (cells only before new cycle)
------------------------------------------------
local function meHasPlasmaCells()
  local items = storageME.getItemsInNetwork()
  for _, stack in ipairs(items) do
    local label = stack.label or ""
    if label:find("Plasma Cell") then
      return true, label, stack.size or 0
    end
  end
  return false
end

local function waitForClean()
  print("Waiting for leftover plasma cells...")
  while true do
    local hasCells, label, amount = meHasPlasmaCells()
    if not hasCells then
      print("ME is clear of leftover plasma cells.")
      return
    end
    print(string.format("  Leftover plasma cell: %s (%s)", label, tostring(amount)))
    os.sleep(1)
  end
end

------------------------------------------------
-- AUTOMATIC INPUT DETECTION
-- A batch is ready after its dust/non-plasma fluid contents
-- remain unchanged for INPUT_STABLE_SECONDS.
------------------------------------------------
local function getInputSignature(items, fluids)
  local amounts = {}

  for _, stack in ipairs(items) do
    local label = stack.label or ""
    local amount = stack.size or 0
    if amount > 0 and not isEmptyCellLabel(label) and label:find("Dust") then
      local key = "item:" .. label
      amounts[key] = (amounts[key] or 0) + amount
    end
  end

  for _, stack in ipairs(fluids) do
    local label = stack.label or ""
    local amount = stack.amount or 0
    if amount > 0 and not label:find("Plasma") then
      local key = "fluid:" .. label
      amounts[key] = (amounts[key] or 0) + amount
    end
  end

  local keys = {}
  for key in pairs(amounts) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(amounts[key])
  end

  return table.concat(parts, "|"), #keys > 0
end

local function flushInputs()
  print(string.format("\n=== Flush pulse (%ds) ===", FLUSH_PULSE_SECONDS))
  redstone.setOutput(PULSE_SIDE, 15)

  local ok, sleepError = pcall(os.sleep, FLUSH_PULSE_SECONDS)
  redstone.setOutput(PULSE_SIDE, 0)

  if not ok then
    error("Flush pulse failed: " .. tostring(sleepError))
  end

  print("  Flush pulse complete; output turned off.")
end

local function waitForStableInputSnapshot()
  print("Watching storage ME for a new Exoticizer input batch...")

  local previousSignature = nil
  local stableSeconds = 0

  while true do
    local items = storageME.getItemsInNetwork()
    local fluids = storageME.getFluidsInNetwork()
    local signature, hasInputs = getInputSignature(items, fluids)

    if not hasInputs then
      previousSignature = nil
      stableSeconds = 0
    elseif signature ~= previousSignature then
      if previousSignature then
        print(string.format(
          "  Input batch changed; restarting the %d-second settle timer.",
          INPUT_STABLE_SECONDS
        ))
      else
        print("  Input batch detected; waiting for deposits to finish.")
      end
      previousSignature = signature
      stableSeconds = 0
    else
      stableSeconds = stableSeconds + IDLE_POLL_SECONDS
      if stableSeconds >= INPUT_STABLE_SECONDS then
        print(string.format(
          "  Input batch unchanged for %d seconds; snapshot accepted.",
          INPUT_STABLE_SECONDS
        ))
        return items, fluids
      end
    end

    os.sleep(IDLE_POLL_SECONDS)
  end
end

------------------------------------------------
-- PLASMA FLUID CHECK
------------------------------------------------
local function getPlasmaFluids()
  local plasmaFluids = {}
  local fluids = storageME.getFluidsInNetwork()
  for _, stack in ipairs(fluids) do
    local label = stack.label or ""
    if label:find("Plasma") then
      plasmaFluids[#plasmaFluids + 1] = {
        label = label,
        amount = stack.amount or 0
      }
    end
  end
  return plasmaFluids
end

local function plasmaMatchesJob(label, job)
  local plasmaLabel = label:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local baseLabel = tostring(job.base):lower():gsub("^%s+", ""):gsub("%s+$", "")
  return plasmaLabel == (baseLabel .. " plasma")
      or plasmaLabel == ("plasma " .. baseLabel)
end

------------------------------------------------
-- WAIT FOR REQUESTED WORK
-- Retry every unseen plasma job on a fixed interval.
-- AE's reported job state is logged but does not block a retry.
------------------------------------------------
local function waitForRequestedWork(jobs)
  if #jobs == 0 then
    print("\nNo plasma crafting jobs were created.")
    return false
  end

  print("\nWatching requested plasma jobs...")
  local stableClear = 0

  while true do
    local plasmaFluids = getPlasmaFluids()
    local hasPlasma = #plasmaFluids > 0

    for _, job in ipairs(jobs) do
      local matched = false
      for _, plasma in ipairs(plasmaFluids) do
        if plasmaMatchesJob(plasma.label, job) then
          matched = true
          if not job.seen then
            job.seen = true
            print(string.format(
              "  detected %s for %s job (%s)",
              plasma.label,
              job.kind,
              tostring(plasma.amount)
            ))
          end
        end
      end

      if matched then
        job.quietSeconds = 0
      else
        job.quietSeconds = job.quietSeconds + PLASMA_WATCH_POLL_SECONDS
      end
    end

    local allResolved = true
    for _, job in ipairs(jobs) do
      local state = getCraftingState(job.status)
      job.state = state

      if not job.seen then
        allResolved = false

        if job.quietSeconds >= PLASMA_RETRY_SECONDS then
          print(string.format(
            "  WATCHDOG: no %s plasma detected for %d seconds (craft: %s)",
            tostring(job.base),
            PLASMA_RETRY_SECONDS,
            state
          ))

          if job.retriesSinceCancel >= RETRIES_BEFORE_CRAFT_CANCEL then
            print(string.format(
              "    %s reached %d retries; canceling its stuck craft before retrying.",
              tostring(job.base),
              job.retriesSinceCancel
            ))

            local canceled = cancelStuckCrafts(job)
            if canceled > 0 then
              job.retriesSinceCancel = 0
              os.sleep(CRAFT_CANCEL_SETTLE_SECONDS)
            end
          end

          submitPlasmaRequest(job, true)

          job.quietSeconds = 0
        end
      end
    end

    if allResolved then
      if hasPlasma then
        stableClear = 0
      else
        stableClear = stableClear + 1
        print(string.format(
          "  all jobs resolved; no plasma fluids seen (%d/%d)",
          stableClear,
          PLASMA_CLEAR_STABLE_POLLS
        ))

        if stableClear >= PLASMA_CLEAR_STABLE_POLLS then
          print("Plasma fluid activity appears finished.")
          return true
        end
      end
    else
      stableClear = 0
    end

    os.sleep(PLASMA_WATCH_POLL_SECONDS)
  end
end

------------------------------------------------
-- ONE CYCLE
------------------------------------------------
local function runCycle(items, fluids)
  print("\nReading ME snapshot...")

  print(string.format("  item stacks: %d", #items))
  print(string.format("  fluid stacks: %d", #fluids))

  local ignoredEmptyCells = 0
  for _, stack in ipairs(items) do
    if isEmptyCellLabel(stack.label) then
      ignoredEmptyCells = ignoredEmptyCells + (stack.size or 0)
    end
  end
  if ignoredEmptyCells > 0 then
    print(string.format("  ignored empty cells: %d", ignoredEmptyCells))
  end

  ------------------------------------------------
  -- FLUSH AFTER READING SNAPSHOT
  ------------------------------------------------
  flushInputs()

  ------------------------------------------------
  -- BUILD COUNTS FROM SNAPSHOT
  ------------------------------------------------
  local dustByBase  = {}
  local fluidByBase = {}

  for _, stack in ipairs(items) do
    local label = stack.label
    if label and not isEmptyCellLabel(label) and label:find("Dust") then
      local base = normalizeDustLabel(label)
      dustByBase[base] = (dustByBase[base] or 0) + (stack.size or 0)
    end
  end

  for _, stack in ipairs(fluids) do
    local label = stack.label
    if label and not label:find("Plasma") then
      fluidByBase[label] = (fluidByBase[label] or 0) + (stack.amount or 0)
    end
  end

  ------------------------------------------------
  -- DEBUG
  ------------------------------------------------
  print("\n=== Dust bases ===")
  for base, count in pairs(dustByBase) do
    local hasPattern = plasmaCellStore[base] and "YES" or "NO"
    print(string.format("  %s: %d dusts (pattern: %s)", tostring(base), count or 0, hasPattern))
  end

  print("\n=== Fluid bases ===")
  for base, amount in pairs(fluidByBase) do
    local hasPattern = plasmaCellStore[base] and "YES" or "NO"
    print(string.format("  %s: %d units (pattern: %s)", tostring(base), amount or 0, hasPattern))
  end

  ------------------------------------------------
  -- SEND DUST REQUESTS
  ------------------------------------------------
  local jobs = {}

  print("\n=== Dust -> Plasma Cell Requests ===")
  for base, count in pairs(dustByBase) do
    count = count or 0

    if count > 0 then
      local neededFluid = count * DUST_PLASMA_PER_DUST
      local neededCells = ceilDiv(neededFluid or 0, DUST_PLASMA_PER_CELL)

      print(string.format(
        "REQUEST: %s Dust x%d -> %d mB @ %d mB/cell -> %d Plasma Cells",
        tostring(base),
        count,
        neededFluid or 0,
        DUST_PLASMA_PER_CELL,
        neededCells or 0
      ))

      local job = {
        base = base,
        kind = "dust",
        cells = neededCells,
        retries = 0,
        retriesSinceCancel = 0,
        quietSeconds = 0,
        seen = false
      }
      jobs[#jobs + 1] = job
      submitPlasmaRequest(job, false)
    else
      print("SKIP: " .. tostring(base))
    end
  end

  ------------------------------------------------
  -- SEND FLUID REQUESTS
  ------------------------------------------------
  print("\n=== Fluid -> Plasma Cell Requests ===")
  for base, amount in pairs(fluidByBase) do
    amount = amount or 0

    if amount > 0 then
      local neededFluid = amount * FLUID_PLASMA_PER_UNIT
      local neededCells = ceilDiv(neededFluid or 0, FLUID_PLASMA_PER_CELL)

      print(string.format(
        "REQUEST: %s Fluid x%d -> %d mB @ %d mB/cell -> %d Plasma Cells",
        tostring(base),
        amount,
        neededFluid or 0,
        FLUID_PLASMA_PER_CELL,
        neededCells or 0
      ))

      local job = {
        base = base,
        kind = "fluid",
        cells = neededCells,
        retries = 0,
        retriesSinceCancel = 0,
        quietSeconds = 0,
        seen = false
      }
      jobs[#jobs + 1] = job
      submitPlasmaRequest(job, false)
    else
      print("SKIP: " .. tostring(base))
    end
  end

  ------------------------------------------------
  -- WAIT FOR PLASMA TO APPEAR, THEN FINISH
  ------------------------------------------------
  waitForRequestedWork(jobs)

  print("\nCycle complete.")
end

------------------------------------------------
-- DAEMON
------------------------------------------------
print("Storage ME controller:  " .. storageAddr)
print("Crafting ME controller: " .. craftingAddr)
print("Automatic mode enabled; no input trigger is required.")

while true do
  waitForClean()
  local items, fluids = waitForStableInputSnapshot()

  local ok, err = pcall(runCycle, items, fluids)
  if not ok then
    print("ERROR: " .. tostring(err))
  end
end
