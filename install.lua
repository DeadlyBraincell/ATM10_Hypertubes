--[[ ===========================================================================
  install.lua -- fetch the right programs for one computer
  ---------------------------------------------------------------------------
  Put this on a fresh computer and tell it what the computer is:

      install master
      install panel
      install node

  With no argument it re-installs whatever this computer already is, which is
  how you update after a change.

  A second argument overrides where the files come from, useful while testing a
  branch. It is remembered afterwards:

      install panel https://raw.githubusercontent.com/me/repo/dev/

  Standalone on purpose: it uses no part of the hypertube code, because on a
  fresh computer none of it exists yet.
=========================================================================== ]]

local DEFAULT_REPO = "https://raw.githubusercontent.com/DeadlyBraincell/Hypertube_Router/main/"

-- Every computer gets these.
local SHARED = { "common.lua", "config.lua", "startup.lua" }

-- ... plus exactly one of these.
local ROLE_FILES = {
  master = { "master.lua" },
  panel  = { "panel.lua" },
  node   = { "node.lua" },
}

local CONFIG_FILE = "/hypertube.cfg"
local STAGE_DIR   = "/.hypertube_install"


-- ===========================================================================
-- 1. HELPERS
-- ===========================================================================

local function usage()
  print("usage: install <master|panel|node> [repo-url]")
  print("")
  print("  master   routing, locks and the topology")
  print("  panel    one access point: monitor, doors, scanner")
  print("  node     one or more junctions and their scanners")
  print("")
  print("with no role, re-installs what this computer already is")
end

---@return table|nil
local function readConfig()
  if not fs.exists(CONFIG_FILE) then return nil end

  local file = fs.open(CONFIG_FILE, "r")
  if file == nil then return nil end
  local text = file.readAll()
  file.close()

  local cfg = textutils.unserialise(text or "")
  if type(cfg) ~= "table" then return nil end
  return cfg
end

---Remember the role so a later bare `install` knows what to fetch, and so the
---setup wizard does not have to ask something the installer already knows.
---@param role string
local function writeRole(role)
  local cfg = readConfig() or {}
  if cfg.role == role then return end

  cfg.role = role
  local file = fs.open(CONFIG_FILE, "w")
  if file == nil then
    print("warning: could not write " .. CONFIG_FILE)
    return
  end
  file.write(textutils.serialise(cfg))
  file.close()
end

---@param repo string
---@param name string
---@return string|nil body
---@return string|nil err
local function download(repo, name)
  -- The raw host sits behind a CDN that caches for a few minutes, which is
  -- long enough to hand back the file you just fixed. A throwaway query
  -- parameter is ignored by the server but changes the cache key.
  local url = repo .. name .. "?t=" .. tostring(os.epoch("utc"))

  local response, err = http.get(url)
  if response == nil then
    return nil, tostring(err or "no response")
  end

  local body = response.readAll()
  response.close()

  if body == nil or #body == 0 then
    return nil, "empty file"
  end
  -- A 404 page from a bad path is a perfectly valid HTTP response, so check
  -- that what came back actually looks like one of our programs.
  if not body:find("--", 1, true) then
    return nil, "that does not look like Lua -- check the repo url"
  end
  return body, nil
end


-- ===========================================================================
-- 2. INSTALL
-- ===========================================================================

local args = { ... }
local role = args[1]
local repo = args[2] or settings.get("hypertube.repo") or DEFAULT_REPO

-- no role given: re-install whatever is already here
if role == nil then
  local cfg = readConfig()
  role = cfg and cfg.role
  if role == nil then
    usage()
    return
  end
  print("re-installing as " .. role)
end

if ROLE_FILES[role] == nil then
  print("unknown role: " .. tostring(role))
  print("")
  usage()
  return
end

if repo:sub(-1) ~= "/" then repo = repo .. "/" end

if repo:find("USER/REPO/BRANCH", 1, true) then
  printError("install.lua still has the placeholder repository url in it.")
  print("Edit DEFAULT_REPO at the top, or pass the url as a second argument:")
  print("  install " .. role .. " https://raw.githubusercontent.com/you/repo/main/")
  return
end

if not http then
  printError("HTTP is disabled on this server.")
  print("Enable the http api in the ComputerCraft config, or copy the files")
  print("across with a disk drive instead.")
  return
end

-- what this computer needs
local wanted = { }
for _, name in ipairs(SHARED) do wanted[#wanted + 1] = name end
for _, name in ipairs(ROLE_FILES[role]) do wanted[#wanted + 1] = name end

print("Installing " .. role .. " from:")
print("  " .. repo)
print("")

-- Download everything into a staging directory first. A half-finished install
-- is worse than none at all: the computer would boot into a broken program
-- with no obvious sign of why.
if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
fs.makeDir(STAGE_DIR)

local fetched = {}
for _, name in ipairs(wanted) do
  write("  " .. name .. " ... ")
  local body, err = download(repo, name)
  if body == nil then
    print("failed")
    printError("  " .. tostring(err))
    fs.delete(STAGE_DIR)
    print("Nothing was changed.")
    return
  end

  local file = fs.open(fs.combine(STAGE_DIR, name), "w")
  if file == nil then
    print("failed")
    printError("  cannot write to disk -- is it full?")
    fs.delete(STAGE_DIR)
    return
  end
  file.write(body)
  file.close()

  fetched[#fetched + 1] = name
  print(#body .. " bytes")
end

-- Everything arrived: move it into place.
for _, name in ipairs(fetched) do
  local target = "/" .. name
  if fs.exists(target) then fs.delete(target) end
  fs.move(fs.combine(STAGE_DIR, name), target)
end
fs.delete(STAGE_DIR)

-- Drop the other roles' programs, so a computer that used to be a panel does
-- not keep a stale panel.lua around to confuse the next person reading it.
for otherRole, files in pairs(ROLE_FILES) do
  if otherRole ~= role then
    for _, name in ipairs(files) do
      if fs.exists("/" .. name) then fs.delete("/" .. name) end
    end
  end
end

writeRole(role)
settings.set("hypertube.repo", repo)
settings.save()

print("")
print("Installed " .. #fetched .. " files as " .. role .. ".")

if role == "master" then
  print("Edit NODES in master.lua to describe the network, then reboot.")
else
  print("Reboot to run the setup wizard.")
end

write("Reboot now? (Y/n): ")
local answer = read()
if answer == nil or answer == "" or answer:sub(1, 1):lower() == "y" then
  os.reboot()
end
