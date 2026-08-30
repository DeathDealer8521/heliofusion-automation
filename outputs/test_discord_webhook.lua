local component = require("component")

local WEBHOOK_CONFIG = "/home/discord_webhook.lua"
local TEST_MESSAGE = "Heliofusion webhook test successful from OpenComputers."

local function loadWebhookUrl()
  local ok, urlOrError = pcall(dofile, WEBHOOK_CONFIG)
  if not ok then
    return nil, "could not load " .. WEBHOOK_CONFIG .. ": " .. tostring(urlOrError)
  end

  if type(urlOrError) ~= "string"
      or not urlOrError:match("^https://discord%.com/api/webhooks/") then
    return nil, WEBHOOK_CONFIG .. " did not return a valid Discord webhook URL"
  end

  return urlOrError
end

local function jsonEscape(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")
    :gsub("\t", "\\t")
end

if not component.isAvailable("internet") then
  error("No Internet Card is available.", 0)
end

local internet = require("internet")
local webhookUrl, configError = loadWebhookUrl()
if not webhookUrl then
  error(configError, 0)
end

local separator = webhookUrl:find("?", 1, true) and "&" or "?"
local requestUrl = webhookUrl .. separator .. "wait=true"
local payload = string.format(
  '{"content":"%s"}',
  jsonEscape(TEST_MESSAGE)
)

print("Sending Discord webhook test...")

local requestOk, responseOrError = pcall(
  internet.request,
  requestUrl,
  payload,
  {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "OpenComputers-Webhook-Test"
  },
  "POST"
)

if not requestOk then
  error("Discord request failed: " .. tostring(responseOrError), 0)
end

local responseOk, responseError = pcall(function()
  for _ in responseOrError do
    -- Consume the response so OpenComputers finishes the HTTP request.
  end
end)

if not responseOk then
  error("Discord response failed: " .. tostring(responseError), 0)
end

print("Discord webhook test sent successfully.")
