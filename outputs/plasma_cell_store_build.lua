-- plasma_cell_store_build.lua
local component = require("component")

-----------------------------------------------------
-- ME CONTROLLER WITH PLASMA CELL PATTERNS
-----------------------------------------------------
local craftingAddr = "7bb51d70-97a8-4805-a19d-5c4a31d82ca5"   -- plasma cell patterns ME
local craftingME   = assert(component.proxy(craftingAddr), "Crafting ME controller not found")

local outPath = "/home/plasma_cell_store.lua"

-----------------------------------------------------
-- UTIL: normalize "Gallium Plasma Cell" -> "Gallium"
-----------------------------------------------------
local function normalizeBaseFromPlasmaCellLabel(label)
  local s = label
  s = s:gsub(" Plasma Cell$", "")
  return s
end

-----------------------------------------------------
-- SCAN CRAFTABLES FOR *PLASMA CELLS*
-----------------------------------------------------
print("Scanning craftables for Plasma Cells...")

local ok, craftables = pcall(craftingME.getCraftables)
if not ok or not craftables then
  error("getCraftables failed: " .. tostring(craftables))
end

local store = {}

for _, recipe in ipairs(craftables) do
  local ok2, stack = pcall(recipe.getItemStack, recipe)
  if ok2 and stack and stack.label and stack.label:find("Plasma Cell") then
    local base = normalizeBaseFromPlasmaCellLabel(stack.label)

    -- 🔴 IMPORTANT: keep this minimal, like your old plasma_store
    store[base] = {
      name   = stack.name,
      damage = stack.damage or 0,
      label  = stack.label
    }

    print(string.format(
      "  Found plasma cell pattern: base=%s, label=%s",
      base, stack.label
    ))
  end
end

local count = 0
for _ in pairs(store) do count = count + 1 end
print("Found " .. count .. " plasma cell patterns. Writing file...")

-----------------------------------------------------
-- WRITE /home/plasma_cell_store.lua
-----------------------------------------------------
local f, err = io.open(outPath, "w")
if not f then
  error("Failed to open " .. outPath .. " for writing: " .. tostring(err))
end

f:write("return {\n")
for base, stack in pairs(store) do
  f:write(string.format(
    "  [%q] = { name = %q, damage = %d, label = %q },\n",
    base,
    stack.name or "",
    tonumber(stack.damage) or 0,
    stack.label or ""
  ))
end
f:write("}\n")
f:close()

print("Done. Plasma cell store written to " .. outPath .. ".")
