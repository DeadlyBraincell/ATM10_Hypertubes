--[[ ===========================================================================
  common.lua -- shared types, protocol and helpers
  ---------------------------------------------------------------------------
  Loaded by master.lua, node.lua and panel.lua. Holds everything the three
  roles must agree on: the wire protocol, the key formats, and the type
  definitions the LSP uses across all files.

  RULE, learned the hard way: nothing in here may call rednet.lookup, or any
  other function that waits on os.pullEvent, from inside an event loop. Those
  helpers consume every event they pull -- including the caller's own timers --
  and CC has no way to put an event back. See MasterLink below.
=========================================================================== ]]

local M = {}


-- ===========================================================================
-- 1. PROTOCOL CONSTANTS
-- ===========================================================================

-- Every message is scoped to one network by the rednet protocol itself, so two
-- hypertube systems on the same server can reuse access point names without
-- ever hearing each other. useFrequency is called once at boot, before any
-- modem is opened; everything else just reads M.PROTOCOL when it sends.
M.BASE_PROTOCOL = "hypertube"
M.PROTOCOL = M.BASE_PROTOCOL

---@param frequency number|nil
---@return string protocol
function M.useFrequency(frequency)
  M.PROTOCOL = M.BASE_PROTOCOL .. "-" .. math.floor(tonumber(frequency) or 0)
  return M.PROTOCOL
end

M.ACK_TIMEOUT      = 2     -- seconds a junction has to confirm a switch
M.BOARDING_TIMEOUT = 30    -- seconds the player has to enter the tube
M.SAFETY_FACTOR    = 2.0   -- per-leg deadline = cost * SAFETY_FACTOR + GRACE
M.GRACE            = 5     -- seconds
M.TICK             = 1     -- watchdog interval

M.DISCOVER_INTERVAL = 15   -- master re-asks who is out there while peers are missing
M.HELLO_INTERVAL    = 10   -- panels and controllers re-announce until answered
M.DOOR_HOLD         = 8    -- seconds the destination doors stay open after arrival

-- Rednet hostnames. Nothing routes by hostname any more -- every peer is
-- learned from "hello" -- but hosting one is still worth it: it makes a
-- computer findable from the shell, and rednet.host refuses a duplicate, which
-- catches two panels configured for the same access point.
---@param role "master"|"node"|"panel"
---@param id   string|nil
---@return string
function M.hostname(role, id)
  if role == "master" then return "master" end
  return role .. ":" .. tostring(id)
end


-- ===========================================================================
-- 2. TYPES
-- ===========================================================================

---@alias NodeId   string   -- both junctions and access points
---@alias PortId   string   -- physical direction a tube leaves a node
---@alias TicketId string
---@alias LinkKey  string   -- canonical edge id, "A~B"

---@alias NodeKind
---| "junction"  # up to 3 links, switchable
---| "access"    # endpoint with a panel, exactly 1 link

---@alias TicketState
---| "switching"  # junctions are being set, nobody may board yet
---| "boarding"   # origin doors open, waiting for the entrance detector
---| "transit"    # player is in the tube, tracked leg by leg

---@class Link
---@field to   NodeId  neighbour node
---@field port PortId  the port on `to` that this link arrives at
---@field cost number  travel time in seconds

---@class Node
---@field kind      NodeKind
---@field links     table<PortId, Link>  at most 3 entries
---@field label     string|nil           shown on panels; defaults to the id
---@field entryPort PortId|nil           access points only: port a pod launches into

---@class Hop
---@field from    NodeId
---@field to      NodeId
---@field outPort PortId  port we LEAVE `from` by
---@field inPort  PortId  port we ENTER `to` by

---@alias Path Hop[]  ordered list of hops, origin -> destination

---@class PrevStep
---@field from    NodeId
---@field outPort PortId
---@field inPort  PortId

---@class Locks
---@field nodes table<NodeId, TicketId>
---@field links table<LinkKey, TicketId>

---@class Ticket
---@field id       TicketId
---@field from     NodeId
---@field to       NodeId
---@field path     Path
---@field panel    number         rednet id of the requesting panel
---@field state    TicketState
---@field deadline number         os.clock() value; missing it fails the ticket
---@field leg      integer        hops confirmed so far, 0 = still at origin
---@field pending  table<NodeId, integer>  junctions that have not acked yet
---@field eta      number         total cost in seconds

---@class Destination
---@field id    NodeId
---@field label string
---@field busy  boolean  currently held by some ticket

---Everything a panel needs to render itself. Sent by the master on every
---change, so the panel never has to work anything out on its own.
---@class PanelState
---@field cmd       string|nil   filled in by the master on the way out
---@field ticket    TicketId|nil
---@field state     TicketState|"idle"
---@field text      string
---@field doors     boolean
---@field light     "green"|"red"|"off"
---@field autoClose boolean|nil  panel closes the doors again after DOOR_HOLD

---@class Request
---@field panel number
---@field from  NodeId
---@field to    NodeId

---@class ExpiredTicket
---@field id     TicketId
---@field reason string


-- ===========================================================================
-- 3. WIRE MESSAGES
-- ===========================================================================
--  Every message is a table with a `cmd` field, sent on M.PROTOCOL.
--
--  panel  -> master  { cmd = "route",  from = NodeId, to = NodeId }
--  panel  -> master  { cmd = "cancel", ticket = TicketId }
--  panel  -> master  { cmd = "enter",  node = NodeId }   detector fired; means
--                                                        "boarded" at the origin
--                                                        and "arrived" at the
--                                                        destination
--  panel  -> master  { cmd = "hello",  role = "panel", node = NodeId }
--
--  master -> panel   { cmd = "destinations", nodes = Destination[],
--                      locked = string|nil }
--                    `locked` is why the master is refusing new routes, and
--                    nil while it is running.
--  master -> panel   PanelState with cmd = "state"
--  master -> all     { cmd = "discover" }
--  master -> node    { cmd = "welcome" }   stops the hello retries
--
--  master -> all     { cmd = "ping",  round = integer }
--  panel  -> master  { cmd = "pong",  round = integer, node  = NodeId }
--  node   -> master  { cmd = "pong",  round = integer, nodes = NodeId[] }
--                    The audit: anything that does not answer in time locks
--                    the network until it does.
--
--  master -> node    { cmd = "set",  node = NodeId, entry = PortId, exit = PortId,
--                      seq = integer }
--                    DIRECTED on purpose: which way a pod is travelling through
--                    a junction changes which redstone level it needs.
--  master -> node    { cmd = "idle", node = NodeId }   drop the line: straight
--  node   -> master  { cmd = "ack", node = NodeId, seq = integer, ok = boolean }
--  node   -> master  { cmd = "detect", node = NodeId }
--                    A scanner belongs to a junction, not to a port: all it
--                    can say is that something passed through that junction.
--  node   -> master  { cmd = "hello", role = "node", nodes = NodeId[] }


-- ===========================================================================
-- 4. MODEMS
-- ===========================================================================

---Open rednet on EVERY attached modem that matches `kind`.
---A controller often has a wired modem for peripherals and a wireless one for
---rednet; opening only the first one found is a coin flip. The filter callback
---returns false throughout so peripheral.find keeps scanning -- the work is
---done in the side effect, which is the idiom the CC docs use themselves.
---@param kind "wireless"|"wired"|"any"|nil  defaults to "any"
---@return string[] names  every modem rednet was opened on
function M.openModem(kind)
  kind = kind or "any"
  local names = {}

  peripheral.find("modem", function(name, wrapped)
    if kind ~= "any" and wrapped.isWireless() ~= (kind == "wireless") then
      return false
    end
    if not rednet.isOpen(name) then rednet.open(name) end
    names[#names + 1] = name
    return false
  end)

  if #names == 0 then
    error("no " .. kind .. " modem attached", 0)
  end
  return names
end


-- ===========================================================================
-- 5. TALKING TO THE MASTER  (without ever blocking)
-- ===========================================================================

---@class MasterLink
---@field id number|nil  learned from the first message the master sends us
local MasterLink = {}
MasterLink.__index = MasterLink

---@return MasterLink
function M.masterLink()
  return setmetatable({ id = nil }, MasterLink)
end

---Send to the master. Never blocks and never calls lookup: until we know the
---master's id the message goes out as a broadcast, which reaches it just the
---same. Other roles ignore commands they have no handler for.
---@param message table
function MasterLink:send(message)
  if self.id ~= nil then
    rednet.send(self.id, message, M.PROTOCOL)
  else
    rednet.broadcast(message, M.PROTOCOL)
  end
end

---Call this with the sender of any message only the master sends, so the next
---send goes out directed instead of broadcast.
---@param senderId number
function MasterLink:learn(senderId)
  self.id = senderId
end


-- ===========================================================================
-- 6. REDSTONE
-- ===========================================================================

---Rising-edge tracker for redstone inputs, so a detector reports once per
---pulse instead of once per redstone event.
---
---The Tube Scanner emits a one second pulse, which is far longer than the
---time it takes this computer to wake up and read the side, so no edge is
---ever missed. The flip side is that two travellers passing the same scanner
---less than a second apart arrive as a single report: the line never goes low
---between them, so there is only one rising edge to see.
---@param sides string[]
---@return fun(): string[]  sides that went low -> high since the last call
function M.edgeDetector(sides)
  local previous = {}
  for _, side in ipairs(sides) do previous[side] = redstone.getInput(side) end

  return function()
    local fired = {}
    for _, side in ipairs(sides) do
      local now = redstone.getInput(side)
      if now and not previous[side] then fired[#fired + 1] = side end
      previous[side] = now
    end
    return fired
  end
end


-- ===========================================================================
-- 7. KEYS
-- ===========================================================================

---Canonical, order independent key for one edge of the graph.
---@param nodeA NodeId
---@param nodeB NodeId
---@return LinkKey
function M.linkKey(nodeA, nodeB)
  if nodeA < nodeB then return nodeA .. "~" .. nodeB end
  return nodeB .. "~" .. nodeA
end

return M
