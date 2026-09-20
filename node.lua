--[[ ===========================================================================
  node.lua -- ROLE 3: node controller
  ---------------------------------------------------------------------------
  Sits next to one or more junctions and does two jobs, independently
  configurable per controller:

    MODE = "control"  switch junctions on request from the master
    MODE = "sensor"   only report this junction's scanner
    MODE = "both"     do both

  HARDWARE (confirmed in world, Create: Hypertubes 0.6.0):
    * A junction follows the redstone LEVEL on its line, but what that level
      DOES depends on which port the pod arrives at:

          entry          line LOW         line HIGH
          straight run   carry straight   divert to the branch
          the branch     leave right      leave left

      so it is a routing function of (entry, level), not a switch between two
      connections. That is why the master sends a DIRECTED move: the same two
      ports can need different levels depending on which way they travelled.
    * Setting one is idempotent -- re-asserting the same level is free -- and
      boot can put every junction into a known state by dropping its line.
    * A Tube Scanner fits on a JUNCTION or an accelerator, not on a plain
      length of tube, and reports the junction as a whole: a one second pulse
      saying something went through, with no way to tell which branch it took
      or which one it came from. All the master gets is "a pod reached J_hub".
      That is still enough to follow a route, because the path already says
      which junctions a pod should reach and in what order.
      (Access points have the opposite problem -- see panel.lua. A scanner on
      an ENTRANCE only fires for entities going in.)
    * One second is long enough that the rising edge is never missed, but two
      travellers less than a second apart merge into a single report.

  The redstone wiring lives HERE, not on the master. The master only ever says
  "a pod arrives at this port and must leave by that one"; working out which
  level that needs is local knowledge, so re-wiring a junction or re-aiming it
  with the wrench never touches the master's config.

  A computer only has six sides. If one controller ends up driving more
  junctions than that, put the extra lines on redstone_relay peripherals over
  a wired modem and replace the redstone.setOutput call in applyMove.
=========================================================================== ]]

local common = require("common")

local Controller = {}


-- ===========================================================================
-- 1. CONFIG  (per controller)
-- ===========================================================================

---@type HypertubeConfig
local CFG = nil

---@type "control"|"sensor"|"both"
local MODE = "both"

---Ports are named for the node they lead to, so `a`, `b` and `branch` are node
---ids. The master therefore asks for a move in the same terms: a pod arriving
---from AP_base, leaving towards J_two.
---@class ManagedNode
---@field side      string  redstone output driving this junction
---@field a         PortId  one end of the straight run
---@field b         PortId  the other end of the straight run
---@field branch    PortId  the side branch
---@field right     PortId  a or b: the exit taken from the branch on a LOW line
---@field scanner   string|nil  redstone input side of this junction's Tube
---                             Scanner, if one is fitted. A scanner belongs to
---                             the junction as a whole: it says something went
---                             through, never which way.

---Filled from /hypertube.cfg by the setup wizard. One entry per junction this
---computer is wired to, each looking like:
---
---  ["J_hub"] = { side = "top", a = "AP_base", b = "J_two", branch = "AP_mine",
---                right = "AP_base", scanner = "left" }
---@type table<NodeId, ManagedNode>
local MANAGED = {}

local link = common.masterLink()


-- ===========================================================================
-- 2. CONFIG CHECKS  (a wiring mistake should fail at boot, not mid-route)
-- ===========================================================================

---@return string[] sides
---@return table<string, NodeId> owner  side -> the junction it belongs to
local function detectorSides()
  local sides, owner = {}, {}
  for nodeId, node in pairs(MANAGED) do
    local side = node.scanner
    if side ~= nil then
      if owner[side] ~= nil then
        error("side " .. side .. " is the scanner for both "
          .. owner[side] .. " and " .. nodeId, 0)
      end
      sides[#sides + 1] = side
      owner[side] = nodeId
    end
  end
  return sides, owner
end

local function checkConfig()
  if next(MANAGED) == nil then
    error("MANAGED is empty: this controller has nothing to do", 0)
  end

  local usedSides = {}
  for nodeId, node in pairs(MANAGED) do
    if MODE ~= "sensor" then
      if node.side == nil then error(nodeId .. " has no output side", 0) end

      -- A port may lead nowhere: a junction with an arm that is not built yet
      -- still routes perfectly well between the two that are.
      local connected = {}
      for _, port in pairs({ node.a, node.b, node.branch }) do
        if type(port) ~= "string" or port == "" then
          error(nodeId .. " has a port that is neither a node id nor blank", 0)
        end
        if connected[port] then
          error(nodeId .. " has two tubes leading to " .. port
            .. "; it could not route between them", 0)
        end
        connected[port] = true
      end

      local count = 0
      for _ in pairs(connected) do count = count + 1 end
      if count < 2 then
        error(nodeId .. " has fewer than two tubes connected", 0)
      end

      if node.right ~= nil and node.right ~= node.a and node.right ~= node.b then
        error(nodeId .. " right must be one of its straight ends", 0)
      end

      if usedSides[node.side] ~= nil then
        error("side " .. node.side .. " drives both "
          .. usedSides[node.side] .. " and " .. nodeId, 0)
      end
      usedSides[node.side] = nodeId

      if node.scanner == node.side then
        error(nodeId .. " uses side " .. node.side .. " as both output and scanner", 0)
      end
    end
  end
end


-- ===========================================================================
-- 3. SWITCHING
-- ===========================================================================

---The level that carries a pod from `entry` to `exit`:
---
---     entry     line LOW     line HIGH
---     a         b            branch
---     b         a            branch
---     branch    right        left
---
---Note what that means for the two ports {a, branch}: travelling a -> branch
---needs the line HIGH, but branch -> a needs it LOW whenever a is the
---right-hand exit. The move is directed, and an unordered pair of ports
---cannot say which level is wanted.
---@param node  ManagedNode
---@param entry PortId
---@param exit  PortId
---@return boolean|nil level  nil when the junction cannot make that move at all
local function levelFor(node, entry, exit)
  -- nil never matches: a port that leads nowhere can be neither end of a move
  if entry == nil or exit == nil then return nil end

  if entry == node.branch then
    if node.right == nil then return nil end
    if exit == node.right then return false end
    if exit == node.a or exit == node.b then return true end   -- the other one: left
    return nil
  end

  if entry == node.a or entry == node.b then
    if exit == node.branch then return true end
    if exit ~= entry and (exit == node.a or exit == node.b) then return false end
  end

  return nil
end

---Route a pod arriving at `entry` out through `exit`. Idempotent: the junction
---follows the level, so asking for the level it already carries costs one
---redstone write and nothing else. No state is tracked and nothing has to
---survive a reboot -- boot just drops every line.
---@param nodeId NodeId
---@param entry  PortId
---@param exit   PortId
---@return boolean ok
---@return string|nil err
function Controller.applyMove(nodeId, entry, exit)
  local node = MANAGED[nodeId]
  if node == nil then return false, "not my junction" end

  local level = levelFor(node, entry, exit)
  if level == nil then
    -- Say what this junction actually believes, because the usual cause is
    -- that it and the master disagree about what its tubes are called.
    common.say(nodeId .. ": cannot route " .. tostring(entry)
      .. " -> " .. tostring(exit))
    common.say("  this junction has a=" .. tostring(node.a)
      .. " b=" .. tostring(node.b) .. " branch=" .. tostring(node.branch)
      .. " right=" .. tostring(node.right))
    return false, "cannot route " .. tostring(entry) .. " -> " .. tostring(exit)
  end

  common.debug(nodeId .. ": " .. entry .. " -> " .. exit .. " means "
    .. node.side .. " " .. (level and "HIGH (turn)" or "LOW (straight)"))

  redstone.setOutput(node.side, level)
  return true, nil
end

---@param nodeId NodeId
---@return boolean ok
function Controller.applyIdle(nodeId)
  local node = MANAGED[nodeId]
  if node == nil then return false end

  redstone.setOutput(node.side, false)
  return true
end

---Drop every line: all junctions straight. Safe to do at boot precisely
---because these are levels -- there is no hidden state to get wrong.
function Controller.resetAll()
  for nodeId in pairs(MANAGED) do
    Controller.applyIdle(nodeId)
  end
end


-- ===========================================================================
-- 4. MESSAGES
-- ===========================================================================

---Announce and register every node this controller owns. A computer can only
---host ONE rednet hostname per protocol, so a controller with several
---junctions is discovered through this message rather than a hostname lookup.
---The config rides along so the master can keep a copy in its own persistent
---registry: one place to look when a junction misbehaves, and a record of what
---a controller used to be if it ever has to be rebuilt.
local function sayHello()
  local ids = {}
  for nodeId in pairs(MANAGED) do ids[#ids + 1] = nodeId end
  link:send({ cmd = "hello", role = "node", nodes = ids, mode = MODE, config = CFG })
end

---Print what this controller thinks it is looking after, and what its lines
---are doing right now.
function Controller.dump()
  common.say("-- this controller --")
  common.say("  mode " .. MODE .. ", master "
    .. (link.id and tostring(link.id) or "not found yet"))

  local ids = {}
  for nodeId in pairs(MANAGED) do ids[#ids + 1] = nodeId end
  table.sort(ids)

  for _, nodeId in ipairs(ids) do
    local node = MANAGED[nodeId]
    local live = redstone.getOutput(node.side)

    common.say("  " .. nodeId .. " on " .. node.side .. " = "
      .. (live and "HIGH" or "LOW"))
    common.say("    a=" .. tostring(node.a) .. " b=" .. tostring(node.b)
      .. " branch=" .. tostring(node.branch) .. " right=" .. tostring(node.right))
    common.say("    so right now: " .. (live
      and ("straight run -> " .. tostring(node.branch))
      or  (tostring(node.a) .. " <-> " .. tostring(node.b))))
    common.say("    scanner " .. (node.scanner or "none")
      .. (node.scanner and (" reads " .. tostring(redstone.getInput(node.scanner))) or ""))
  end
end

---@param senderId number
---@param msg      table
local function onMessage(senderId, msg)
  common.trace("<-", senderId, msg)

  if msg.cmd == "set" then
    if MODE == "sensor" then return end
    link:learn(senderId)

    local ok, err = Controller.applyMove(msg.node, msg.entry, msg.exit)
    rednet.send(senderId, {
      cmd = "ack", node = msg.node, seq = msg.seq, ok = ok, err = err,
    }, common.PROTOCOL)

  elseif msg.cmd == "idle" then
    if MODE == "sensor" then return end
    link:learn(senderId)
    Controller.applyIdle(msg.node)

  elseif msg.cmd == "discover" then
    link:learn(senderId)
    sayHello()

  elseif msg.cmd == "welcome" then
    link:learn(senderId)

  elseif msg.cmd == "ping" then
    -- the master is auditing: answer for every junction this computer runs
    link:learn(senderId)
    local ids = {}
    for nodeId in pairs(MANAGED) do ids[#ids + 1] = nodeId end
    rednet.send(senderId, { cmd = "pong", round = msg.round, nodes = ids },
      common.PROTOCOL)
  end
end


-- ===========================================================================
-- 5. MAIN LOOP
-- ===========================================================================

---@param cfg HypertubeConfig
function Controller.main(cfg)
  CFG = cfg
  MODE = cfg.mode or "both"
  MANAGED = cfg.junctions or {}

  checkConfig()
  common.openModem("any")

  -- One hostname only, for findability from the shell; routing does not use it.
  local first = next(MANAGED)
  rednet.host(common.PROTOCOL, common.hostname("node", first))

  if MODE ~= "sensor" then Controller.resetAll() end
  sayHello()

  common.say("controller online: " .. MODE .. ". press h for keys")

  local sides, owner = detectorSides()
  local risingEdges = common.edgeDetector(sides)
  local retry = os.startTimer(common.HELLO_INTERVAL)

  while true do
    local event, a, b = os.pullEvent()

    if event == "rednet_message" then
      if type(b) == "table" and type(b.cmd) == "string" then
        onMessage(a, b)
      end

    elseif event == "redstone" and MODE ~= "control" then
      -- A control detector fired: the pod passed this point. The master uses
      -- it to advance the ticket one leg, to release the tubes behind the pod,
      -- and to notice a player who left the tube early -- a missed detection
      -- fails the ticket one leg later instead of after the whole route's ETA.
      for _, side in ipairs(risingEdges()) do
        common.debug("scanner " .. side .. " fired for " .. owner[side])
        link:send({ cmd = "detect", node = owner[side] })
      end

    elseif event == "key" then
      if a == keys.s then
        Controller.dump()
      elseif a == keys.d then
        common.setDebug(not common.isDebug())
        settings.set("hypertube.debug", common.isDebug())
        settings.save()
        common.say("tracing " .. (common.isDebug() and "ON" or "off"))
      elseif a == keys.h then
        common.say("s state | d tracing")
      end

    elseif event == "timer" and a == retry then
      -- Keep announcing until the master has answered once.
      if link.id == nil then sayHello() end
      retry = os.startTimer(common.HELLO_INTERVAL)
    end
  end
end

return Controller
