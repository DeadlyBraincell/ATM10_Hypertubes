--[[ ===========================================================================
  config.lua -- per-computer settings and the first-run wizard
  ---------------------------------------------------------------------------
  Every computer keeps its own settings in /hypertube.cfg. If that file is
  missing, startup.lua runs the wizard below and writes it; passing "config" to
  startup re-runs the wizard with the current values as the defaults.

  The wizard runs on the COMPUTER's screen, not on the monitor a panel drives.
  Stand at the computer to set one up.
=========================================================================== ]]

local config = {}

config.FILE = "/hypertube.cfg"

local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local ROLES = { "master", "panel", "node" }
local MODES = { "control", "sensor", "both" }


-- ===========================================================================
-- 1. TYPES
-- ===========================================================================

---@class PanelWiring
---@field doors    string
---@field detector string
---@field lights   table<string, string|nil>  "green"/"red" -> side, absent if not built

---A junction's ports are NAMED for where they lead, so each of a/b/branch is
---both a port name and the node id at the far end of that tube.
---@class JunctionConfig
---@field side       string   redstone output driving this junction
---@field a          PortId   one end of the straight run
---@field b          PortId   the other end of the straight run
---@field branch     PortId   the side branch
---@field right      PortId   a or b: where a pod from the branch goes on a LOW line
---@field scanner    string|nil  redstone input side of this junction's scanner

---@class HypertubeConfig
---@field role      "master"|"panel"|"node"
---@field frequency number
---@field node      NodeId|nil                      panels
---@field label     string|nil                      panels
---@field neighbour NodeId|nil                      panels: what its tube leads to
---@field wiring    PanelWiring|nil                 panels
---@field mode      "control"|"sensor"|"both"|nil   controllers
---@field junctions table<NodeId, JunctionConfig>|nil  controllers


-- ===========================================================================
-- 2. FILE
-- ===========================================================================

---@return boolean
function config.exists()
  return fs.exists(config.FILE)
end

---@return HypertubeConfig|nil
function config.load()
  if not fs.exists(config.FILE) then return nil end

  local file = fs.open(config.FILE, "r")
  if file == nil then return nil end

  local text = file.readAll()
  file.close()

  local loaded = textutils.unserialise(text or "")
  if type(loaded) ~= "table" or type(loaded.role) ~= "string" then return nil end

  -- Coerce only what is there. A missing frequency must stay missing, or the
  -- role-only stub the installer writes would look like a finished config.
  if loaded.frequency ~= nil then loaded.frequency = tonumber(loaded.frequency) end
  return loaded
end

---Is this a config a computer can actually run on, or only half of one? The
---installer seeds the file with nothing but a role, and a file truncated by a
---full disk is possible too. Cheap existence checks only -- whether the sides
---are wired the way they claim is for each role to find out.
---@param cfg HypertubeConfig|nil
---@return boolean complete
---@return string|nil missing  what is not filled in yet
function config.isComplete(cfg)
  if type(cfg) ~= "table" then return false, "anything at all" end
  if type(cfg.role) ~= "string" then return false, "role" end
  if type(cfg.frequency) ~= "number" then return false, "frequency" end

  if cfg.role == "panel" then
    if type(cfg.node) ~= "string" or cfg.node == "" then
      return false, "access point id"
    end
    if type(cfg.neighbour) ~= "string" or cfg.neighbour == "" then
      return false, "what this station's tube leads to"
    end
    local wiring = cfg.wiring
    if type(wiring) ~= "table"
      or type(wiring.doors) ~= "string"
      or type(wiring.detector) ~= "string" then
      return false, "wiring"
    end

  elseif cfg.role == "node" then
    if type(cfg.mode) ~= "string" then return false, "mode" end
    if type(cfg.junctions) ~= "table" or next(cfg.junctions) == nil then
      return false, "junctions"
    end
    for nodeId, junction in pairs(cfg.junctions) do
      if type(junction.side) ~= "string" then
        return false, nodeId .. " output side"
      end

      -- a/b/branch/right may each be absent: a port can lead nowhere
      local connected = 0
      for _, port in pairs({ junction.a, junction.b, junction.branch }) do
        if type(port) == "string" and port ~= "" then connected = connected + 1 end
      end
      if connected < 2 then
        return false, nodeId .. ": what its tubes lead to"
      end
    end
  end

  return true, nil
end

---@param cfg HypertubeConfig
---@return boolean ok
function config.save(cfg)
  local file = fs.open(config.FILE, "w")
  if file == nil then return false end

  file.write(textutils.serialise(cfg))
  file.close()
  return true
end


-- ===========================================================================
-- 3. PROMPTS
-- ===========================================================================

---@param label   string
---@param default string|nil
---@return string
local function ask(label, default)
  while true do
    if default ~= nil and default ~= "" then
      write(label .. " [" .. default .. "]: ")
    else
      write(label .. ": ")
    end

    local answer = read()
    if answer ~= nil then answer = answer:gsub("^%s+", ""):gsub("%s+$", "") end

    if answer ~= nil and answer ~= "" then return answer end
    if default ~= nil then return default end
    print("This one is required.")
  end
end

---Same, but an empty answer is a real answer: "none".
---@param label   string
---@param default string|nil
---@return string|nil
local function askOptional(label, default)
  write(label .. (default and default ~= "" and " [" .. default .. "]" or " [none]") .. ": ")
  local answer = read()
  if answer ~= nil then answer = answer:gsub("^%s+", ""):gsub("%s+$", "") end

  if answer == "" or answer == nil then
    return default   -- nil when there was no default either
  end
  if answer == "-" or answer == "none" then return nil end
  return answer
end

---@param label   string
---@param choices string[]
---@param default string|nil
---@return string
local function askFrom(label, choices, default)
  local allowed = {}
  for _, choice in ipairs(choices) do allowed[choice] = true end

  while true do
    local answer = ask(label .. " (" .. table.concat(choices, "/") .. ")", default)
    if allowed[answer] then return answer end
    print("Pick one of: " .. table.concat(choices, ", "))
  end
end

---@param label   string
---@param default string|nil
---@return string
local function askSide(label, default)
  return askFrom(label, SIDES, default)
end

---@param label   string
---@param default string|nil
---@return string|nil
local function askOptionalSide(label, default)
  while true do
    local answer = askOptional(label, default)
    if answer == nil then return nil end
    for _, side in ipairs(SIDES) do
      if answer == side then return answer end
    end
    print("Pick one of: " .. table.concat(SIDES, ", ") .. ". Blank for none.")
  end
end

---@param label   string
---@param default number|nil
---@return number
local function askNumber(label, default)
  while true do
    local answer = tonumber(ask(label, default and tostring(default) or nil))
    if answer ~= nil then return answer end
    print("Numbers only.")
  end
end

---@param label   string
---@param default boolean
---@return boolean
local function askYesNo(label, default)
  local answer = ask(label .. (default and " (Y/n)" or " (y/N)"), default and "y" or "n")
  return answer:sub(1, 1):lower() == "y"
end

---@param label    string
---@param taken    string[]  nodes already named on this junction
---@param default  string|nil
---@param optional boolean|nil  blank means "this tube is not built"
---@return string|nil
local function askPort(label, taken, default, optional)
  while true do
    local answer
    if optional then
      answer = askOptional(label, default)
      if answer == nil then return nil end
    else
      answer = ask(label, default)
    end

    local clash = false
    for _, used in ipairs(taken) do
      if used == answer then clash = true end
    end
    if not clash then return answer end

    -- Two tubes to the same node would be the same port name, and a junction
    -- cannot route between two ports it cannot tell apart.
    print("A tube to " .. answer .. " is already on this junction.")
  end
end


-- ===========================================================================
-- 4. WIZARDS
-- ===========================================================================

---@param cfg      HypertubeConfig
---@param existing HypertubeConfig|nil
local function panelWizard(cfg, existing)
  print("")
  print("-- access point --")
  cfg.node = ask("Access point id (as it appears in the master's topology)",
    existing and existing.node)
  cfg.label = ask("Name to show on panels", (existing and existing.label) or cfg.node)

  -- The master builds the map of the network out of these answers, so this is
  -- the one question that describes the world rather than this computer.
  print("")
  print("Follow this station's tube: the first junction or station it reaches is its neighbour. Give that computer's node id, not the far end of the line.")
  cfg.neighbour = ask("Node at the other end of the tube",
    existing and existing.neighbour)

  local wiring = (existing and existing.wiring) or {}
  local lights = wiring.lights or {}

  print("")
  print("-- wiring (sides of THIS computer) --")
  print("The entrance output is powered only while somebody may board.")
  print("")
  print("The Tube Scanner must sit on an ACCELERATOR just inside the tube, never on the entrance. An entrance only reports entities going IN, so a station wired that way never notices anyone arriving.")
  print("")
  cfg.wiring = {
    -- Still called `doors` on the wire and in the saved config, so that
    -- existing stations keep working. What it drives is the entrance itself:
    -- powered while somebody may board, off the rest of the time.
    doors    = askSide("Entrance power output side", wiring.doors or "right"),
    detector = askSide("Tube Scanner input side", wiring.detector or "back"),
    lights   = {
      green = askOptionalSide("Green lamp side", lights.green),
      red   = askOptionalSide("Red lamp side", lights.red),
    },
  }
end

---@param existing JunctionConfig|nil
---@param nodeId   NodeId
---@return JunctionConfig
local function junctionWizard(nodeId, existing)
  existing = existing or {}
  print("")
  print("-- junction " .. nodeId .. " --")

  -- A port is named for where it leads, so naming the three tubes and saying
  -- where they go is one question, not two. It also means a junction cannot
  -- describe two tubes to the same place, which is a thing it could not route
  -- between anyway.
  print("Name the node each of the three tubes leads to: the next junction or station along it, not the final destination. Leave one blank if that tube is not built yet.")
  print("")

  local side = askSide("Redstone output side", existing.side or "top")

  -- Which of the three is unconnected matters: a/b are the straight run and
  -- branch is the side, and that is fixed by the block, not by which tubes
  -- happen to be built. Answer for the junction as it sits in the world and
  -- leave the unbuilt one blank.
  local a = askPort("Straight run: one end leads to", {}, existing.a, true)
  local b = askPort("Straight run: other end leads to", { a }, existing.b, true)
  local branch = askPort("The side branch leads to", { a, b }, existing.branch, true)

  local connected = 0
  for _, port in pairs({ a, b, branch }) do
    if port ~= nil then connected = connected + 1 end
  end
  if connected < 2 then
    print("")
    print("A junction needs at least two tubes connected to be worth anything. Starting again.")
    return junctionWizard(nodeId, existing)
  end

  -- The behaviour a pod meets depends on where it came in:
  --   from a or b, line low  -> carries straight on
  --   from a or b, line high -> diverted into the branch
  --   from the branch        -> right on a low line, left on a high one
  -- Only that last row needs asking about, and only once: "right" is fixed by
  -- how the junction sits in the world. Send somebody through from the branch
  -- with the line off and write down where they come out.
  print("")
  -- Only worth asking when there is a branch to arrive from and somewhere for
  -- it to go.
  local right = nil
  local straightEnds = {}
  for _, port in pairs({ a, b }) do straightEnds[#straightEnds + 1] = port end

  if branch ~= nil and #straightEnds > 0 then
    print("A pod entering from " .. branch .. " with the line OFF leaves to its RIGHT. Which way is that?")
    right = askFrom("Right-hand exit from " .. branch,
      straightEnds, existing.right or straightEnds[1])
  end

  -- A scanner sits at the junction and reports the junction: something went
  -- through, with no way to tell which branch. So there is nothing to ask
  -- beyond which side it is wired to.
  print("")
  print("A Tube Scanner here lets the master follow a pod past this junction. Without one the route is still tracked, just from the next junction that has one.")
  local scanner = askOptionalSide("Tube Scanner input side", existing.scanner)

  return {
    side    = side,
    a       = a,
    b       = b,
    branch  = branch,
    right   = right,
    scanner = scanner,
  }
end

---@param cfg      HypertubeConfig
---@param existing HypertubeConfig|nil
local function nodeWizard(cfg, existing)
  print("")
  cfg.mode = askFrom("Mode", MODES, (existing and existing.mode) or "both")
  cfg.junctions = {}

  local previous = (existing and existing.junctions) or {}

  -- offer the ones it already had first, then let them add more
  for nodeId, junction in pairs(previous) do
    if askYesNo("Keep junction " .. nodeId .. "?", true) then
      cfg.junctions[nodeId] = junctionWizard(nodeId, junction)
    end
  end

  while true do
    local more = (next(cfg.junctions) == nil)
      or askYesNo("Add another junction?", false)
    if not more then break end

    local nodeId = ask("Junction id (as it appears in the master's topology)")
    cfg.junctions[nodeId] = junctionWizard(nodeId, nil)
  end
end

---@param cfg HypertubeConfig
local function summarise(cfg)
  print("")
  print("=== this computer ===")
  print("  role      " .. cfg.role)
  print("  frequency " .. cfg.frequency)

  if cfg.role == "panel" then
    print("  node      " .. tostring(cfg.node) .. "  (" .. tostring(cfg.label) .. ")")
    print("  tube to   " .. tostring(cfg.neighbour))
    print("  doors     " .. cfg.wiring.doors)
    print("  scanner   " .. cfg.wiring.detector)
    for colour, side in pairs(cfg.wiring.lights) do
      print("  " .. colour .. string.rep(" ", 10 - #colour) .. side)
    end

  elseif cfg.role == "node" then
    print("  mode      " .. tostring(cfg.mode))
    for nodeId, junction in pairs(cfg.junctions) do
      local left = (junction.right == junction.a) and junction.b or junction.a
      print("  " .. nodeId .. " on " .. junction.side)
      local none = "(not built)"
      print("      straight  " .. (junction.a or none)
        .. " <-> " .. (junction.b or none))
      print("      branch    to " .. (junction.branch or none))
      if junction.right ~= nil then
        print("      from " .. junction.branch .. ": right " .. junction.right
          .. ", left " .. (left or none))
      end
      print("      scanner   " .. (junction.scanner or "none fitted"))
    end
  end
  print("")
end

---Ask the player everything this computer needs. Loops until they are happy.
---@param existing HypertubeConfig|nil  current values, used as the defaults
---@return HypertubeConfig
function config.wizard(existing)
  while true do
    print("")
    print("=== Hypertube setup ===")
    print("Enter keeps the [default]. Type - to clear an optional value.")
    print("")

    local role = askFrom("Role of this computer", ROLES, existing and existing.role)
    local frequency = askNumber(
      "Network frequency (same number on every computer of this network)",
      (existing and existing.frequency) or 1)

    ---@type HypertubeConfig
    local cfg = { role = role, frequency = frequency }

    if cfg.role == "panel" then
      panelWizard(cfg, existing)
    elseif cfg.role == "node" then
      nodeWizard(cfg, existing)
    end

    summarise(cfg)
    if askYesNo("Save this?", true) then return cfg end

    existing = cfg   -- start the next pass from what they just typed
  end
end

return config
