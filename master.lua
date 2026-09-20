--[[ ===========================================================================
  master.lua -- ROLE 1: master server
  ---------------------------------------------------------------------------
  Owns the topology, the pathfinding and the locks. Never touches redstone
  itself: it asks node controllers to switch junctions and panels to open
  doors, and it tracks where every player currently is.

  Assumes a loop-free network, so between two access points there is exactly
  one path. The search counts nodes anyway, ready for loops later.

  Nothing in this file blocks. Peers are learned from "hello" and cached; an
  unknown peer fails the send and re-triggers discovery, because a lookup here
  would eat the watchdog timer and stop the whole server from ever timing a
  ticket out again.
=========================================================================== ]]

local common = require("common")

local Master = {}


-- ===========================================================================
-- 1. TOPOLOGY  (the only thing this computer has to be told)
-- ===========================================================================
--  Nothing is typed in here or anywhere else. The map is assembled from what
--  the panels and controllers say about themselves when they register, and
--  lives in memory, rebuilt from the registry on every boot.
--
--  It holds no redstone and no computer ids. How a junction is wired is the
--  node controller's business, and which computer runs it is learned at boot.

---@type table<NodeId, Node>
NODES = {}

---Set while the map is incomplete or contradictory: something has not
---registered yet, or two computers disagree about a tube. Unlike an
---unreachable node this does not resolve itself by waiting -- it resolves
---when the missing computer is set up -- so it holds the lockdown down.
---@type string|nil
local topologyError = nil

-- Release nodes and links behind the pod as its scanners confirm it has passed.
-- Roughly doubles throughput, but needs a scanner on every junction: a stretch
-- with none reports nothing, and freeing it would be a guess. Leave it off
-- until the scanners are actually in the ground.
local TRAILING_RELEASE = false

-- How often to make every access point and junction prove it is still there,
-- and how long they get to answer. Set the interval to 0 while building the
-- network out, or a half-finished topology locks itself down every minute.
local AUDIT_INTERVAL = 60
local AUDIT_TIMEOUT  = 5

-- Send every junction on a finished route back to straight. Costs one message
-- per junction and buys a predictable resting network: anyone who walks into a
-- tube by hand, with no ticket at all, runs straight through instead of being
-- thrown down whichever branch the last route happened to leave set.
local IDLE_ON_RELEASE = true


-- ===========================================================================
-- 2. STATE
-- ===========================================================================

-- The lock table is the single source of truth. Everything else derives from it.
---@type Locks
local locks = { nodes = {}, links = {} }

---@type table<TicketId, Ticket>
local tickets = {}

---@type Request[]  FIFO of requests that could not be served yet
local queue = {}

---@type table<NodeId, number>  rednet ids, filled by "hello"
local peers = {}

---@type table<NodeId, boolean>  nodes we wanted to reach but do not know yet
local missing = {}

---What every panel and controller told us about itself, kept on disk so the
---master comes back up already knowing the network instead of waiting for
---everyone to say hello again.
---@class Registration
---@field computer number            rednet id
---@field kind     "panel"|"node"
---@field label    string|nil        panels: the name to show
---@field config   table|nil         the computer's own /hypertube.cfg

---@type table<NodeId, Registration>
local registry = {}

local REGISTRY_FILE = "/hypertube_registry"

---When each node last proved it was alive. Deliberately NOT persisted: after a
---reboot nothing has proved anything yet, and the first audit says so.
---@type table<NodeId, number>
local lastSeen = {}

---An audit in progress: everyone still owing us an answer this round.
---@class Audit
---@field round   integer
---@field pending table<NodeId, boolean>

---@type Audit|nil
local audit = nil
local auditRound = 0

---Why the network is shut to new traffic, or nil while it is running.
---@type string|nil
local lockdown = nil

---@type table<string, number|nil>  the timers the main loop is waiting on
local timers = {}

local nextTicketId = 0
local nextSeq = 0
local pumping = false      -- re-entrancy guard for pumpQueue


-- ===========================================================================
-- 3. PEERS
-- ===========================================================================

---@param message string
function Master.log(message)
  -- TODO: mirror to a monitor and/or a log file
  print(message)
end

---Cache only. A miss is recorded so the next discover round asks for it again;
---it never falls back to rednet.lookup, which would block for two seconds and
---swallow every event that arrived meanwhile.
---@param nodeId NodeId
---@return number|nil computerId
function Master.peerFor(nodeId)
  return peers[nodeId]
end

---@param nodeId  NodeId
---@param message table
---@return boolean sent
function Master.sendTo(nodeId, message)
  local id = Master.peerFor(nodeId)
  if id == nil then
    -- only chase peers that are actually in the topology, or a typo'd request
    -- would keep the discovery broadcast running forever
    if NODES[nodeId] ~= nil and not missing[nodeId] then
      missing[nodeId] = true
      Master.log("no computer registered for " .. nodeId)
      -- Something we need is not there. Do not wait up to a minute for the
      -- next scheduled round to notice.
      Master.beginAudit()
    end
    return false
  end
  rednet.send(id, message, common.PROTOCOL)
  return true
end

---@param nodeId NodeId
---@param id     number
function Master.registerPeer(nodeId, id)
  peers[nodeId] = id
  missing[nodeId] = nil
end

---True while some node we tried to reach is still unaccounted for.
---@return boolean
function Master.hasMissingPeers()
  return next(missing) ~= nil
end


-- ===========================================================================
-- 3b. REGISTRY  (who is out there, remembered across reboots)
-- ===========================================================================

local function saveRegistry()
  local file = fs.open(REGISTRY_FILE, "w")
  if file == nil then
    Master.log("WARNING: cannot write " .. REGISTRY_FILE)
    return
  end
  file.write(textutils.serialise(registry))
  file.close()
end

local function loadRegistry()
  if not fs.exists(REGISTRY_FILE) then return end

  local file = fs.open(REGISTRY_FILE, "r")
  if file == nil then return end
  local loaded = textutils.unserialise(file.readAll() or "")
  file.close()

  if type(loaded) ~= "table" then return end
  registry = loaded

  -- warm the peer cache, so the first route after a reboot does not have to
  -- wait for everybody to announce themselves again
  for nodeId, entry in pairs(registry) do
    if type(entry) == "table" and type(entry.computer) == "number" then
      peers[nodeId] = entry.computer
    end
  end
end

---Record what a computer says it is, and write it down.
---
---A registration is a fact about the network, so it goes to disk as soon as it
---arrives rather than at some later checkpoint: whatever happens next, the file
---already describes what is out there. Re-announcements from a computer we
---already have on file are liveness, not registration, and only touch lastSeen.
---Deep equality, enough to tell one registration from another.
---@param a any
---@param b any
---@return boolean
local function same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end

  for key, value in pairs(a) do
    if not same(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

---@param nodeId NodeId
---@param entry  Registration
function Master.register(nodeId, entry)
  local before = registry[nodeId]

  -- The CONFIG has to be part of this. It is the whole reason a registration
  -- is interesting: it carries which tubes lead where. Comparing only the
  -- computer id meant re-running setup on a panel changed nothing here --
  -- the new answers were dropped, never saved, and the master kept routing
  -- from a map that no longer matched the world.
  local changed = before == nil
    or before.computer ~= entry.computer
    or before.label ~= entry.label
    or before.kind ~= entry.kind
    or not same(before.config, entry.config)

  registry[nodeId] = entry
  Master.registerPeer(nodeId, entry.computer)
  Master.sawNode(nodeId)

  -- Both of these only fire on a real change. A panel re-announces itself
  -- every few seconds until it is answered, and logging that each time buries
  -- everything else.
  if changed then
    Master.log(nodeId .. " registered as computer " .. entry.computer)
    saveRegistry()

    -- A new computer is a new piece of the map, and may be the piece that
    -- completes it.
    Master.refreshTopology()
  end
end


-- ===========================================================================
-- 3bb. TOPOLOGY  (assembled from what registered, never typed in)
-- ===========================================================================
--  Nobody writes a map of the network. Each computer knows one local fact --
--  which node each of its tubes reaches -- and the master matches up the two
--  ends that name each other.
--
--  A junction's ports are NAMED for where they lead, so "which port" and
--  "leading where" are the same answer. It falls out of that that the master
--  talks to a controller in terms a person would use: a pod arriving from
--  AP_base and leaving towards J_two, rather than arriving north and leaving
--  east.
--
--  That is the only arrangement that cannot go stale: the answer comes from
--  the computer standing next to the tube, so it is corrected by whoever
--  rebuilds that junction, at the moment they rebuild it.
--
--  An access point has exactly one tube, so its port needs no name of its
--  own and is always called this.
local ACCESS_PORT = "tube"

---Rebuild NODES from the registry.
---@return string[] problems  everything still missing or contradictory
function Master.buildTopology()
  ---@type table<NodeId, Node>
  local nodes = {}

  ---What each node says its ports lead to: nodeId -> port -> neighbour id.
  ---@type table<NodeId, table<PortId, NodeId>>
  local claims = {}

  local problems = {}
  local function complain(text) problems[#problems + 1] = text end

  -- 1. every registration contributes a node and its claims
  for nodeId, entry in pairs(registry) do
    if type(entry) ~= "table" or type(entry.config) ~= "table" then
      complain(nodeId .. " registered without a usable config")

    elseif entry.kind == "panel" then
      nodes[nodeId] = {
        kind      = "access",
        label     = entry.label or nodeId,
        entryPort = ACCESS_PORT,
        links     = {},
      }
      claims[nodeId] = { [ACCESS_PORT] = entry.config.neighbour }

    elseif entry.kind == "node" then
      local junctions = entry.config.junctions
      local junction = type(junctions) == "table" and junctions[nodeId] or nil
      if junction == nil then
        complain(nodeId .. " registered as a junction but its config has no such junction")
      else
        nodes[nodeId] = { kind = "junction", links = {} }

        -- A junction's ports are named for where they lead, so each port name
        -- IS the claim. Two tubes to the same place would be the same key,
        -- which is exactly the pair a junction could never route between.
        --
        -- Built by assignment rather than as a literal: a port that leads
        -- nowhere is nil, and `{ [nil] = nil }` is an error, not an empty
        -- entry.
        local claim = {}
        for _, port in pairs({ junction.a, junction.b, junction.branch }) do
          if type(port) == "string" and port ~= "" then claim[port] = port end
        end
        claims[nodeId] = claim
      end
    end
  end

  -- 2. pair the halves
  for nodeId, ports in pairs(claims) do
    for port, neighbourId in pairs(ports) do
      if type(neighbourId) ~= "string" or neighbourId == "" then
        complain(nodeId .. "." .. port .. ": nothing named at the far end")

      elseif neighbourId == nodeId then
        complain(nodeId .. "." .. port .. " points at itself")

      elseif nodes[neighbourId] == nil then
        complain(nodeId .. "." .. port .. " leads to " .. neighbourId
          .. ", which has not registered")

      else
        -- Which of the neighbour's ports names us back? Only one may, or
        -- there is no way to tell the two tubes apart.
        local facing = {}
        for otherPort, otherNeighbour in pairs(claims[neighbourId] or {}) do
          if otherNeighbour == nodeId then facing[#facing + 1] = otherPort end
        end

        if #facing == 0 then
          complain(neighbourId .. " does not point back at " .. nodeId
            .. " (check its setup)")
        elseif #facing > 1 then
          complain(neighbourId .. " claims " .. #facing .. " tubes to " .. nodeId
            .. "; they cannot be told apart")
        else
          nodes[nodeId].links[port] = { to = neighbourId, port = facing[1] }
        end
      end
    end
  end

  -- 3. shapes that would break routing
  for nodeId, node in pairs(nodes) do
    local count = 0
    for _ in pairs(node.links) do count = count + 1 end

    if node.kind == "junction" and count > 3 then
      complain(nodeId .. " has " .. count .. " tubes; a junction has at most 3")
    end
  end

  NODES = nodes
  table.sort(problems)
  return problems
end

---Rebuild the map and decide whether the network can run on it.
---Called at boot and whenever a registration changes something.
function Master.refreshTopology()
  local problems = Master.buildTopology()

  local accessPoints, junctions = 0, 0
  for _, node in pairs(NODES) do
    if node.kind == "access" then accessPoints = accessPoints + 1 end
    if node.kind == "junction" then junctions = junctions + 1 end
  end

  if next(NODES) == nil then
    topologyError = "waiting for the first computer to register"
    Master.setLockdown(topologyError)
    return
  end

  if #problems > 0 then
    Master.log("topology: " .. accessPoints .. " access points, " .. junctions
      .. " junctions, " .. #problems .. " problem(s):")
    for _, problem in ipairs(problems) do Master.log("  " .. problem) end

    topologyError = "incomplete map: " .. problems[1]
    Master.setLockdown(topologyError)
    return
  end

  Master.log("topology: " .. accessPoints .. " access points, "
    .. junctions .. " junctions, all linked")

  -- The map is sound. Whether the network is actually THERE is the audit's
  -- question, so ask it now rather than sitting locked until the next round.
  if topologyError ~= nil then
    topologyError = nil
    Master.beginAudit()
  end
end


-- ===========================================================================
-- 3c. AUDIT AND LOCKDOWN
-- ===========================================================================
--  Every AUDIT_INTERVAL seconds the master asks every access point and every
--  junction to prove it is still there. Anything that does not answer within
--  AUDIT_TIMEOUT locks the network: no new routes are handed out until it
--  comes back.
--
--  The reasoning is that a silent junction is worse than a busy one. The
--  master cannot read a junction, so it cannot tell a controller that died
--  from one that is about to mis-route somebody into a wall. Refusing to
--  dispatch is the only honest answer.
--
--  Routes already in flight are deliberately left alone. Their locks still
--  hold, their junctions were already set, and a player in a tube is better
--  off arriving than having the route torn up underneath them. They end the
--  way they always do, on arrival or on their watchdog.

---@param nodeId NodeId
function Master.sawNode(nodeId)
  lastSeen[nodeId] = os.clock()
  if audit ~= nil then audit.pending[nodeId] = nil end
end

---@param reason string
function Master.setLockdown(reason)
  if lockdown == reason then return end

  lockdown = reason
  Master.log("LOCKDOWN: " .. reason)

  -- Queued requests cannot be honoured, and holding them would hand somebody a
  -- route minutes later out of nowhere.
  local dropped = #queue
  for i = #queue, 1, -1 do queue[i] = nil end
  if dropped > 0 then Master.log("dropped " .. dropped .. " queued requests") end

  Master.broadcastDestinations()
end

function Master.clearLockdown()
  if lockdown == nil then return end

  -- A missing node can come back on its own. A missing topology cannot, and an
  -- empty one would otherwise pass every audit trivially -- nothing to check --
  -- and open a network that cannot route anywhere.
  if topologyError ~= nil then
    lockdown = topologyError
    return
  end

  Master.log("lockdown lifted: the whole network answered")
  lockdown = nil
  Master.broadcastDestinations()
  Master.pumpQueue()
end

---Ask everything to prove it is alive. Non-blocking: the answers arrive as
---ordinary messages and finishAudit passes judgement when the timer fires.
function Master.beginAudit()
  -- The discover goes out either way: it is also how a panel that booted
  -- before this master finds us at all.
  if AUDIT_INTERVAL <= 0 then
    rednet.broadcast({ cmd = "discover" }, common.PROTOCOL)
    return
  end
  if audit ~= nil then return end   -- one round at a time

  auditRound = auditRound + 1

  ---@type table<NodeId, boolean>
  local pending = {}
  for nodeId in pairs(NODES) do pending[nodeId] = true end

  audit = { round = auditRound, pending = pending }

  -- One ping per computer, not per node: a controller running three junctions
  -- answers for all three at once.
  local asked = {}
  for nodeId in pairs(pending) do
    local id = peers[nodeId]
    if id ~= nil and not asked[id] then
      asked[id] = true
      rednet.send(id, { cmd = "ping", round = auditRound }, common.PROTOCOL)
    end
  end

  -- Anything we have no id for is either new or was lost with the registry;
  -- this gives it a chance to announce itself before the round is judged.
  rednet.broadcast({ cmd = "discover" }, common.PROTOCOL)

  timers.auditDeadline = os.startTimer(AUDIT_TIMEOUT)
end

---The round is over: whoever did not answer is missing.
function Master.finishAudit()
  if audit == nil then return end

  local absent = {}
  for nodeId in pairs(audit.pending) do absent[#absent + 1] = nodeId end
  audit = nil
  timers.auditDeadline = nil

  if #absent == 0 then
    Master.clearLockdown()
    return
  end

  table.sort(absent)

  -- Say how long each one has been quiet. "never seen" means it has not
  -- checked in since this master booted, which usually means a computer that
  -- was never installed or a node id that does not match the topology --
  -- a different problem from one that answered a minute ago and then stopped.
  local now = os.clock()
  local detail = {}
  for _, nodeId in ipairs(absent) do
    local seen = lastSeen[nodeId]
    if seen == nil then
      detail[#detail + 1] = nodeId .. " (never seen)"
    else
      detail[#detail + 1] = nodeId .. " (quiet " .. math.floor(now - seen) .. "s)"
    end
  end

  Master.log("audit: " .. table.concat(detail, ", "))
  Master.setLockdown("unreachable: " .. table.concat(absent, ", "))
end

---@return boolean
function Master.isLocked()
  return lockdown ~= nil
end


-- ===========================================================================
-- 4. PATHFINDING
-- ===========================================================================

---Breadth-first search: the route through the fewest nodes wins.
---
---Tubes carry no travel time, so there is nothing to weigh one against
---another. Counting nodes is both the honest measure and the useful one --
---every junction is a thing that has to be switched, acked and waited on, so
---the shortest route is also the one with the least that can go wrong.
---
---BFS visits in hop order, so the first time a node is reached is by a
---shortest route and it never has to be reconsidered.
---@param startNode NodeId
---@param goalNode  NodeId
---@param avoid     Locks|nil  nodes/links to route around (no effect on a tree)
---@return Path|nil path  nil when there is no route
---@return integer|string count  hops, or an error message
function Master.findPath(startNode, goalNode, avoid)
  if NODES[startNode] == nil or NODES[goalNode] == nil then
    return nil, "unknown node"
  end

  ---@type table<NodeId, integer>
  local hops = { [startNode] = 0 }
  ---@type table<NodeId, PrevStep>
  local prev = {}

  local queue = { startNode }
  local head = 1

  while head <= #queue do
    local current = queue[head]
    head = head + 1
    if current == goalNode then break end

    for port, link in pairs(NODES[current].links) do
      local neighbour = link.to
      -- a link pointing at a node that is not in NODES would break the search
      if NODES[neighbour] == nil then
        Master.log("config error: " .. current .. " links to unknown " .. neighbour)

      elseif hops[neighbour] == nil then
        local blocked = avoid ~= nil
          and (avoid.nodes[neighbour] ~= nil
            or avoid.links[common.linkKey(current, neighbour)] ~= nil)

        if not blocked then
          hops[neighbour] = hops[current] + 1
          prev[neighbour] = { from = current, outPort = port, inPort = link.port }
          queue[#queue + 1] = neighbour
        end
      end
    end
  end

  if hops[goalNode] == nil then return nil, "no route" end

  -- Rebuild as a list of HOPS: setting a junction needs both the port the pod
  -- arrives on and the port it leaves by.
  ---@type Path
  local path = {}
  local node = goalNode
  while prev[node] do
    local step = prev[node]
    table.insert(path, 1, {
      from    = step.from,
      to      = node,
      outPort = step.outPort,
      inPort  = step.inPort,
    })
    node = step.from
  end

  return path, hops[goalNode]
end


-- ===========================================================================
-- 5. LOCKING  (all or nothing, never partially claimed)
-- ===========================================================================

---@param path Path
---@return table<NodeId, boolean> nodes
---@return table<LinkKey, boolean> links
function Master.pathResources(path)
  local nodes, links = {}, {}
  nodes[path[1].from] = true
  for _, hop in ipairs(path) do
    nodes[hop.to] = true
    links[common.linkKey(hop.from, hop.to)] = true
  end
  return nodes, links
end

---@param path Path
---@return boolean free
---@return NodeId|LinkKey|nil blocker
function Master.isPathFree(path)
  local nodes, links = Master.pathResources(path)
  for n in pairs(nodes) do
    if locks.nodes[n] then return false, n end
  end
  for l in pairs(links) do
    if locks.links[l] then return false, l end
  end
  return true, nil
end

---Check FIRST, write SECOND: no half-locked state, and no deadlock between two
---simultaneous requests, because the event loop is single threaded and this
---function therefore runs atomically.
---@param path     Path
---@param ticketId TicketId
---@return boolean claimed
function Master.claimPath(path, ticketId)
  if not Master.isPathFree(path) then return false end

  local nodes, links = Master.pathResources(path)
  for n in pairs(nodes) do locks.nodes[n] = ticketId end
  for l in pairs(links) do locks.links[l] = ticketId end
  return true
end

---Drop every lock held by a ticket and retire it.
---@param ticketId TicketId
---@param reason   string
function Master.releasePath(ticketId, reason)
  local ticket = tickets[ticketId]
  if ticket == nil then return end

  -- Which junctions are still ours? Worked out BEFORE the locks go, so a
  -- trailing release that already handed a junction to somebody else cannot
  -- make us reset a junction that is now carrying another player.
  local ours = {}
  if IDLE_ON_RELEASE then
    for _, hop in ipairs(ticket.path) do
      if NODES[hop.from].kind == "junction" and locks.nodes[hop.from] == ticketId then
        ours[#ours + 1] = hop.from
      end
    end
  end

  for n, owner in pairs(locks.nodes) do
    if owner == ticketId then locks.nodes[n] = nil end
  end
  for l, owner in pairs(locks.links) do
    if owner == ticketId then locks.links[l] = nil end
  end
  tickets[ticketId] = nil

  for _, nodeId in ipairs(ours) do
    Master.sendTo(nodeId, { cmd = "idle", node = nodeId })
  end

  Master.log("ticket " .. ticketId .. " released: " .. reason)
  Master.tellPanel(ticket.from, {
    state = "idle", text = reason, doors = false, light = "off",
  })
  Master.broadcastDestinations()
  Master.pumpQueue()
end

---Release everything the pod has already passed. Only called when control
---detectors are trustworthy, otherwise a missed detector frees a tube that
---still has somebody in it.
---@param ticket Ticket
function Master.releaseBehind(ticket)
  if not TRAILING_RELEASE or ticket.leg < 2 then return end

  for i = 1, ticket.leg - 1 do
    local hop = ticket.path[i]
    locks.links[common.linkKey(hop.from, hop.to)] = nil
    locks.nodes[hop.from] = nil
  end
  Master.pumpQueue()
end


-- ===========================================================================
-- 6. SWITCHING  (asynchronous, never blocks the event loop)
-- ===========================================================================
--  Every "set" carries a sequence number and the ticket waits in the
--  "switching" state until each junction has acked its own seq. Nothing here
--  waits on an event, so an unrelated message can never be taken for an ack.

---@param ticket Ticket
---@return boolean ok
---@return string|nil err
function Master.applyRoute(ticket)
  for i, hop in ipairs(ticket.path) do
    local node = NODES[hop.from]
    if node.kind == "junction" then
      -- the port the pod arrives on is the previous hop's inPort; for the
      -- first node it is the access point's own launch port
      local entryPort = (i == 1) and node.entryPort or ticket.path[i - 1].inPort
      if entryPort == nil then
        return false, "no entryPort configured for " .. hop.from
      end

      nextSeq = nextSeq + 1
      local sent = Master.sendTo(hop.from, {
        cmd   = "set",
        node  = hop.from,
        entry = entryPort,      -- the port the pod arrives on ...
        exit  = hop.outPort,    -- ... and the one it must leave by
        seq   = nextSeq,
      })
      if not sent then return false, "junction " .. hop.from .. " offline" end
      ticket.pending[hop.from] = nextSeq
    end
  end
  return true, nil
end

---@param nodeId NodeId
---@param seq    integer
---@param ok     boolean
function Master.onAck(nodeId, seq, ok)
  local ticketId = locks.nodes[nodeId]
  if ticketId == nil then return end

  local ticket = tickets[ticketId]
  if ticket == nil or ticket.pending[nodeId] ~= seq then return end

  if not ok then
    Master.releasePath(ticketId, "junction " .. nodeId .. " failed to switch")
    return
  end

  ticket.pending[nodeId] = nil
  if next(ticket.pending) == nil and ticket.state == "switching" then
    Master.beginBoarding(ticket)
  end
end


-- ===========================================================================
-- 7. TICKET LIFECYCLE
-- ===========================================================================
--  switching -> boarding -> transit -> released
--
--  Each state has its own deadline, so a player who never boards is noticed in
--  BOARDING_TIMEOUT and one who leaves the tube mid-route (disconnect, /home,
--  /spawn) is noticed one leg later instead of after the whole route's ETA.

---@param apNode NodeId
---@param patch  PanelState
function Master.tellPanel(apNode, patch)
  patch.cmd = "state"
  Master.sendTo(apNode, patch)
end

---@param ticket Ticket
function Master.beginBoarding(ticket)
  ticket.state = "boarding"
  ticket.deadline = os.clock() + common.BOARDING_TIMEOUT
  Master.tellPanel(ticket.from, {
    ticket = ticket.id,
    state  = "boarding",
    -- No ETA: nothing in the topology says how long a tube takes, and a
    -- number made up from a hop count would be worse than no number.
    text   = "Route open, " .. ticket.hops .. " stop"
      .. (ticket.hops == 1 and "" or "s"),
    doors  = true,
    light  = "green",
  })
end

---An access point detector fired. The same detector serves both ends of a
---route, so which end it is depends on the ticket that holds this node:
---at the origin it means "boarded", at the destination "arrived".
---@param apNode NodeId
function Master.onEnter(apNode)
  local ticketId = locks.nodes[apNode]
  if ticketId == nil then return end

  local ticket = tickets[ticketId]
  if ticket == nil then return end

  if ticket.from == apNode and ticket.state == "boarding" then
    ticket.state = "transit"
    ticket.leg = 0
    ticket.deadline = Master.legDeadline(ticket)

    Master.tellPanel(ticket.from, {
      ticket = ticket.id,
      state  = "transit",
      text   = "In transit",
      doors  = false,   -- close behind the player
      light  = "red",
    })

  elseif ticket.to == apNode and ticket.state == "transit" then
    Master.onArrival(ticket)
  end
end

---Can this node tell us a pod reached it? An access point always can, through
---its panel's entrance scanner. A junction only can if one was actually fitted,
---which the controller told us when it registered.
---@param nodeId NodeId
---@return boolean
function Master.canReport(nodeId)
  local node = NODES[nodeId]
  if node == nil then return false end
  if node.kind == "access" then return true end

  local entry = registry[nodeId]
  local junctions = entry and entry.config and entry.config.junctions
  local junction = junctions and junctions[nodeId]
  return junction ~= nil and junction.scanner ~= nil
end

---Deadline for the next report we can actually expect.
---
---Scanners only exist at junctions, and only where one was built, so the
---reports coming back are a SUBSEQUENCE of the path. Timing to the next hop
---would kill any route whose next junction has no scanner, so this counts on
---past the silent ones to the next node that can speak up -- the next fitted
---junction, or the destination panel.
---
---With no travel times in the topology the budget is simply HOP_SECONDS per
---hop crossed. That is a blunt instrument, and deliberately so: its only job
---is to notice a player who has left the system, and being late about that
---costs a little throughput, while being early strands somebody who was
---merely on a long tube.
---
---An unregistered controller reports nothing, which lands on the lenient side:
---the deadline simply reaches further ahead.
---@param ticket Ticket
---@return number
function Master.legDeadline(ticket)
  local crossed = 0

  for i = ticket.leg + 1, #ticket.path do
    crossed = crossed + 1
    if Master.canReport(ticket.path[i].to) then break end
  end

  if crossed == 0 then return os.clock() + common.GRACE end
  return os.clock() + crossed * common.HOP_SECONDS + common.GRACE
end

---A control detector along the tubes saw the pod pass.
---@param nodeId NodeId
function Master.onDetect(nodeId)
  local ticketId = locks.nodes[nodeId]
  if ticketId == nil then
    Master.log("stray detection at " .. nodeId .. " (no ticket holds it)")
    return
  end

  local ticket = tickets[ticketId]
  if ticket == nil or ticket.state ~= "transit" then return end

  -- Which leg is this? A scanner says a pod passed through its junction and
  -- nothing else -- not which way it went, not who it was -- so the path is
  -- what turns that into progress. Legs may be skipped, because a junction
  -- without a scanner never reports, but they must never go backwards: a pod
  -- that escaped a mis-set junction elsewhere can trip a scanner out of turn,
  -- and rewinding this ticket would hand it a deadline it has already spent.
  for i, hop in ipairs(ticket.path) do
    if hop.to == nodeId then
      if i <= ticket.leg then return end
      ticket.leg = i
      break
    end
  end

  if nodeId == ticket.to then
    Master.onArrival(ticket)
  else
    ticket.deadline = Master.legDeadline(ticket)
    Master.releaseBehind(ticket)
  end
end

---@param ticket Ticket
function Master.onArrival(ticket)
  -- autoClose: the panel shuts its own doors again after DOOR_HOLD seconds.
  -- Without it the destination would stay open and green forever, since the
  -- ticket is about to stop existing.
  Master.tellPanel(ticket.to, {
    ticket    = ticket.id,
    state     = "idle",
    text      = "Arrived",
    doors     = true,
    light     = "green",
    autoClose = true,
  })
  Master.releasePath(ticket.id, "arrived")
end

---Called once per TICK. One missed deadline == one lost player.
function Master.tickWatchdog()
  local now = os.clock()

  -- Collect first, release second. releasePath pumps the queue, which can
  -- create new tickets, and adding a key to a table that pairs() is walking
  -- is undefined behaviour in Lua 5.1.
  ---@type ExpiredTicket[]
  local expired = {}
  for id, ticket in pairs(tickets) do
    if now > ticket.deadline then
      local reason = "player left the tube"
      if ticket.state == "switching" then
        reason = "junctions did not respond"
      elseif ticket.state == "boarding" then
        reason = "nobody boarded"
      end
      expired[#expired + 1] = { id = id, reason = reason }
    end
  end

  for _, dead in ipairs(expired) do
    Master.releasePath(dead.id, dead.reason)
  end
end


-- ===========================================================================
-- 8. REQUESTS
-- ===========================================================================

---One pending request per access point. A player mashing four destinations
---should end up going to the last one they picked, not to all four in turn.
---@param request Request
---@return integer position
function Master.enqueue(request)
  for i, queued in ipairs(queue) do
    if queued.from == request.from then
      queue[i] = request
      return i
    end
  end
  queue[#queue + 1] = request
  return #queue
end

---Answer the computer that asked, rather than routing by access point: the
---request may name a station that does not exist, and that must not register
---as a missing peer.
---@param panelId number
---@param text    string
function Master.replyTo(panelId, text)
  rednet.send(panelId,
    { cmd = "state", state = "idle", text = text, doors = false, light = "red" },
    common.PROTOCOL)
end

---@param panelId number
---@param fromAP  NodeId
---@param toAP    NodeId
---@return TicketId|nil
function Master.handleRequest(panelId, fromAP, toAP)
  if type(fromAP) ~= "string" or type(toAP) ~= "string" then return nil end

  if lockdown ~= nil then
    Master.replyTo(panelId, "Locked: " .. lockdown)
    return nil
  end

  local origin = NODES[fromAP]
  local target = NODES[toAP]
  if origin == nil or target == nil
    or origin.kind ~= "access" or target.kind ~= "access" then
    Master.replyTo(panelId, "Unknown station")
    return nil
  end
  if fromAP == toAP then return nil end

  local path, hops = Master.findPath(fromAP, toAP)
  if path == nil then
    Master.replyTo(panelId, "No route")
    return nil
  end
  ---@cast hops integer

  nextTicketId = nextTicketId + 1
  local ticketId = "T" .. nextTicketId

  if not Master.claimPath(path, ticketId) then
    -- busy; on a tree there is no second path to try, so queue it
    local position = Master.enqueue({ panel = panelId, from = fromAP, to = toAP })
    Master.tellPanel(fromAP, {
      state = "idle",
      text  = "Busy, queued (#" .. position .. ")",
      doors = false,
      light = "red",
    })
    return nil
  end

  ---@type Ticket
  local ticket = {
    id       = ticketId,
    from     = fromAP,
    to       = toAP,
    path     = path,
    panel    = panelId,
    state    = "switching",
    deadline = os.clock() + common.ACK_TIMEOUT,
    leg      = 0,
    pending  = {},
    hops     = hops,
  }
  tickets[ticketId] = ticket

  local ok, err = Master.applyRoute(ticket)
  if not ok then
    Master.releasePath(ticketId, tostring(err))
    return nil
  end

  -- a path with no junctions at all is ready immediately
  if next(ticket.pending) == nil then Master.beginBoarding(ticket) end

  Master.broadcastDestinations()
  return ticketId
end

---Strict FIFO: stop at the first request that still cannot run, so long
---routes do not starve. Scan the whole queue instead to maximise throughput.
---
---Guarded, because releasePath calls this and handleRequest can call
---releasePath: without the flag the queue would be drained from two stack
---frames at once.
function Master.pumpQueue()
  if pumping then return end
  pumping = true

  while #queue > 0 do
    local req = queue[1]
    local path = Master.findPath(req.from, req.to)
    if path == nil or not Master.isPathFree(path) then break end
    table.remove(queue, 1)
    Master.handleRequest(req.panel, req.from, req.to)
  end

  pumping = false
end


-- ===========================================================================
-- 9. DESTINATION LIST  (what panels draw)
-- ===========================================================================

---@param exclude NodeId|nil  the asking panel's own access point
---@return Destination[]
function Master.destinations(exclude)
  local list = {}
  for id, node in pairs(NODES) do
    if node.kind == "access" and id ~= exclude then
      local registered = registry[id]
      list[#list + 1] = {
        id    = id,
        label = (registered and registered.label) or node.label or id,
        busy  = locks.nodes[id] ~= nil,
      }
    end
  end
  table.sort(list, function(a, b) return a.label < b.label end)
  return list
end

---Push a fresh list to every KNOWN panel, so busy destinations grey out the
---moment somebody else claims them. Panels we have not met yet are skipped
---rather than looked up; they will get a list when they say hello.
function Master.broadcastDestinations()
  for id, node in pairs(NODES) do
    if node.kind == "access" and peers[id] ~= nil then
      rednet.send(peers[id], {
        cmd    = "destinations",
        nodes  = Master.destinations(id),
        locked = lockdown,   -- nil while running; the reason while shut
      }, common.PROTOCOL)
    end
  end
end


-- ===========================================================================
-- 10. MESSAGE HANDLING
-- ===========================================================================

---@param senderId number
---@param msg      table
function Master.onMessage(senderId, msg)
  if msg.cmd == "hello" then
    if msg.role == "panel" and type(msg.node) == "string" then
      Master.register(msg.node, {
        computer = senderId,
        kind     = "panel",
        label    = msg.label,
        config   = msg.config,
      })
      rednet.send(senderId, {
        cmd    = "destinations",
        nodes  = Master.destinations(msg.node),
        locked = lockdown,
      }, common.PROTOCOL)
    elseif msg.role == "node" and type(msg.nodes) == "table" then
      for _, nodeId in ipairs(msg.nodes) do
        Master.register(nodeId, {
          computer = senderId,
          kind     = "node",
          config   = msg.config,
        })
      end
      -- a controller has nothing else to receive until a route needs it, so
      -- without this it would re-announce itself forever
      rednet.send(senderId, { cmd = "welcome" }, common.PROTOCOL)
    end

  elseif msg.cmd == "route" then
    -- only the panel that owns an access point may launch from it
    if peers[msg.from] == senderId then
      Master.handleRequest(senderId, msg.from, msg.to)
    else
      Master.log("ignored route from " .. tostring(msg.from) .. ": not its panel")
    end

  elseif msg.cmd == "enter" then
    if peers[msg.node] == senderId then Master.onEnter(msg.node) end

  elseif msg.cmd == "detect" then
    if peers[msg.node] == senderId then Master.onDetect(msg.node) end

  elseif msg.cmd == "pong" then
    -- an audit answer: a panel speaks for itself, a controller for every
    -- junction it runs
    if type(msg.node) == "string" and peers[msg.node] == senderId then
      Master.sawNode(msg.node)
    end
    if type(msg.nodes) == "table" then
      for _, nodeId in ipairs(msg.nodes) do
        if peers[nodeId] == senderId then Master.sawNode(nodeId) end
      end
    end

  elseif msg.cmd == "ack" then
    Master.onAck(msg.node, msg.seq, msg.ok == true)

  elseif msg.cmd == "cancel" then
    local ticket = tickets[msg.ticket]
    -- only the panel that asked for a route may cancel it
    if ticket ~= nil and ticket.panel == senderId then
      Master.releasePath(msg.ticket, "cancelled")
    end
  end
end


-- ===========================================================================
-- 11. MAIN LOOP  (event driven; single threaded, which is what makes the
--                 locking above atomic)
-- ===========================================================================

---@param cfg HypertubeConfig
function Master.main(cfg)
  loadRegistry()
  common.openModem("any")
  rednet.host(common.PROTOCOL, common.hostname("master"))

  Master.log("master online, frequency " .. tostring(cfg and cfg.frequency))

  -- No discover broadcast here: the first audit sends one a second from now,
  -- and doing both made every panel and controller announce itself twice.

  Master.refreshTopology()

  -- Junctions are levels, so every controller has already put its own
  -- junctions straight on ITS boot: there is no stale switch state to undo.
  -- Tickets and locks are still lost on a master reboot, which is safe (every
  -- route simply has to be asked for again) but not yet graceful.
  -- TODO: persist locks and tickets alongside the registry.

  timers.watchdog = os.startTimer(common.TICK)
  timers.discover = os.startTimer(common.DISCOVER_INTERVAL)

  -- Start locked. Nothing has proved it is there yet, and the first audit is
  -- what opens the network -- assuming everything is fine until told otherwise
  -- would dispatch routes into junctions nobody has heard from since the
  -- reboot.
  if topologyError ~= nil then
    lockdown = topologyError
  elseif AUDIT_INTERVAL > 0 then
    lockdown = "starting up"
  end

  -- The audit runs even with AUDIT_INTERVAL at 0 if there is no topology,
  -- because its discover broadcast is also how panels find us at all.
  timers.audit = os.startTimer(1)

  while true do
    local event, a, b = os.pullEvent()

    if event == "rednet_message" then
      if type(b) == "table" and type(b.cmd) == "string" then
        Master.onMessage(a, b)
      end

    elseif event == "timer" then
      if a == timers.watchdog then
        Master.tickWatchdog()
        timers.watchdog = os.startTimer(common.TICK)

      elseif a == timers.discover then
        if Master.hasMissingPeers() then
          rednet.broadcast({ cmd = "discover" }, common.PROTOCOL)
        end
        timers.discover = os.startTimer(common.DISCOVER_INTERVAL)

      elseif a == timers.audit then
        Master.beginAudit()
        -- never rearm with 0: that is a busy loop, not a disabled audit
        timers.audit = os.startTimer(
          AUDIT_INTERVAL > 0 and AUDIT_INTERVAL or common.DISCOVER_INTERVAL)

      elseif a == timers.auditDeadline then
        Master.finishAudit()
      end
    end
  end
end

return Master
