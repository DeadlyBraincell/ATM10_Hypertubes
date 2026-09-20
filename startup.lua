--[[ ===========================================================================
  startup.lua -- launcher, identical on every computer
  ---------------------------------------------------------------------------
  Copy the whole folder to a computer and reboot. On the first run there is no
  /hypertube.cfg, so it asks what this computer is and how it is wired, saves
  the answers, and starts the right program. After that it just starts.

  To change the answers later:

      startup config

  which re-runs the wizard with the current values as the defaults.
=========================================================================== ]]

-- require() resolves package.path against the CURRENT DIRECTORY, not against
-- the directory this script lives in. Without this line, "startup" works from
-- the root but /hypertube/startup.lua does not find common.lua.
local here = fs.getDir(shell.getRunningProgram())
if here ~= "" and here ~= "." then
  package.path = "/" .. here .. "/?.lua;/" .. here .. "/?;" .. package.path
end

local common = require("common")
local config = require("config")

local ROLES = {
  master = "master",
  panel  = "panel",
  node   = "node",
}

local args = { ... }
local forced = false
for _, arg in ipairs(args) do
  if arg == "config" or arg == "-c" or arg == "--config" then forced = true end
end

local cfg = config.load()
local complete, missing = config.isComplete(cfg)

-- The installer leaves a stub holding only the role, so a fresh computer
-- arrives here incomplete rather than unconfigured, and the wizard starts with
-- the one question already answered.
if forced or not complete then
  if not forced then
    if cfg == nil then
      print("No configuration found on this computer.")
    else
      print("Setup is not finished: missing " .. tostring(missing) .. ".")
    end
  end

  cfg = config.wizard(cfg)
  if not config.save(cfg) then
    printError("Could not write " .. config.FILE .. " -- is the disk full?")
    return
  end
  print("Saved to " .. config.FILE)
end

if cfg == nil then
  printError("No configuration to run. Try: startup config")
  return
end

local moduleName = ROLES[cfg.role]
if moduleName == nil then
  printError("Unknown role '" .. tostring(cfg.role) .. "'. Run: startup config")
  return
end

-- Scope every message to this network before anything opens a modem.
common.useFrequency(cfg.frequency)

-- Tracing is per computer and survives a reboot, so a machine can be left
-- logging overnight:  set hypertube.debug true
settings.define("hypertube.debug", {
  description = "Log every hypertube message to " .. common.LOG_FILE,
  type = "boolean",
  default = false,
})
common.setDebug(settings.get("hypertube.debug"))

print("Hypertube " .. cfg.role .. " on frequency " .. cfg.frequency)
if common.isDebug() then
  print("tracing ON -> " .. common.LOG_FILE)
end

-- pcall so a config mistake prints a readable line on the computer's own
-- screen instead of dumping a stack trace nobody is standing next to.
local ok, err = pcall(function()
  require(moduleName).main(cfg)
end)

if not ok then
  printError("Hypertube " .. cfg.role .. " stopped: " .. tostring(err))
  print("Run 'startup config' to change this computer's settings.")
end
