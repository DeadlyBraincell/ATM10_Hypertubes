--[[ ===========================================================================
  panel.lua -- ROLE 2: endpoint panel
  ---------------------------------------------------------------------------
  One per access point. Two responsibilities:

    * the interface: a monitor listing every other access point, paged so the
      list survives growing past one screen, with busy destinations greyed out
    * the access point itself: doors, status light, and the Tube Scanner
      detector placed just inside the tube

  The panel decides nothing about routing. It sends "route A -> B" and then
  renders whatever state the master pushes back.

  Needs an ADVANCED monitor: a basic one throws on setTextColour and never
  fires monitor_touch at all.

  Monitor sizing: a 2x1 advanced monitor at textScale 0.5 is roughly 29x9
  characters, a 2x2 roughly 29x18. Nothing below hard-codes that -- the layout
  is derived from getSize(), so any monitor works and the page size adapts.
=========================================================================== ]]

local common = require("common")

local Panel = {}


-- ===========================================================================
-- 1. CONFIG  (per access point, from /hypertube.cfg via the setup wizard)
-- ===========================================================================

local TEXT_SCALE = 0.5

---@type HypertubeConfig
local CFG = nil

---@type NodeId
local MY_NODE = nil

---@type PanelWiring
local WIRING = nil

local COLORS = {
  bg       = colors.black,
  text     = colors.white,
  header   = colors.blue,
  button   = colors.gray,
  busy     = colors.lightGray,
  busyText = colors.gray,
  accent   = colors.lime,
  warn     = colors.red,
}


-- ===========================================================================
-- 2. STATE
-- ===========================================================================

---@type Destination[]
local destinations = {}

---@type PanelState
local status = {
  state = "idle", text = "Connecting...", doors = false, light = "off", ticket = nil,
}

local page = 1
local known = false       -- has the master ever sent us a destination list?

---Why the master is refusing new routes, or nil while it is running. A route
---already under way is unaffected, so this never hides a live ticket.
---@type string|nil
local lockedReason = nil

---@class Button
---@field x1     integer
---@field y1     integer
---@field x2     integer
---@field y2     integer
---@field action "select"|"page"|"cancel"
---@field value  any

---@type Button[]  rebuilt on every draw, so hit testing can never go stale
local buttons = {}

---@type any  the Advanced Monitor peripheral, wrapped at boot
local monitor = nil
local link = common.masterLink()

---The header line for a panel with no route of its own running. A live ticket
---arrives with its own wording, and so do one-off notices like "No route", so
---this is only ever used when there is nothing more specific to say.
---@return string
local function idleText()
  if lockedReason ~= nil then return "Network locked" end
  if not known then return "Waiting for master..." end
  return "Select a destination"
end


-- ===========================================================================
-- 3. LAYOUT
-- ===========================================================================
--  row 1          header: status text
--  rows 2..h-1    destination buttons, one per row, 2 columns on wide screens
--  row h          pager: < Prev   1/3   Next >

---@return integer width
---@return integer height
---@return integer columns
---@return integer perPage
local function geometry()
  local w, h = monitor.getSize()
  local columns = (w >= 30) and 2 or 1
  local rows = math.max(1, h - 2)   -- minus header and pager
  return w, h, columns, columns * rows
end

---@param x integer
---@param y integer
---@return Button|nil
local function hitTest(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
  end
  return nil
end

---@param x integer
---@param y integer
---@param width integer
---@param label string
---@param bg integer
---@param fg integer
local function drawButton(x, y, width, label, bg, fg)
  if width < 1 then return end

  monitor.setBackgroundColor(bg)
  monitor.setTextColor(fg)
  monitor.setCursorPos(x, y)
  monitor.write(string.rep(" ", width))

  -- centre the label, truncating when it does not fit
  if #label > width then label = label:sub(1, math.max(0, width - 1)) .. "." end
  if #label > width then label = label:sub(1, width) end
  monitor.setCursorPos(x + math.floor((width - #label) / 2), y)
  monitor.write(label)
end

function Panel.draw()
  buttons = {}
  local w, h, columns, perPage = geometry()

  monitor.setBackgroundColor(COLORS.bg)
  monitor.clear()

  -- header ----------------------------------------------------------------
  monitor.setBackgroundColor(COLORS.header)
  monitor.setTextColor(COLORS.text)
  monitor.setCursorPos(1, 1)
  monitor.write(string.rep(" ", w))
  monitor.setCursorPos(2, 1)
  monitor.write(status.text:sub(1, math.max(0, w - 2)))

  -- a ticket is running: show it instead of the list ----------------------
  if status.state ~= "idle" then
    monitor.setBackgroundColor(COLORS.bg)
    monitor.setTextColor(status.state == "boarding" and COLORS.accent or COLORS.text)
    monitor.setCursorPos(2, math.floor(h / 2))
    monitor.write(status.state == "boarding" and "BOARD NOW" or "IN TRANSIT")

    if status.ticket ~= nil then
      drawButton(2, h - 1, w - 2, "Cancel", COLORS.warn, COLORS.text)
      buttons[#buttons + 1] =
        { x1 = 2, y1 = h - 1, x2 = w - 1, y2 = h - 1, action = "cancel" }
    end
    return
  end

  -- the master is refusing new routes ------------------------------------
  if lockedReason ~= nil then
    monitor.setBackgroundColor(COLORS.bg)
    monitor.setTextColor(COLORS.warn)
    monitor.setCursorPos(2, math.max(2, math.floor(h / 2) - 1))
    monitor.write("NETWORK LOCKED")

    monitor.setTextColor(COLORS.busyText)
    monitor.setCursorPos(2, math.max(3, math.floor(h / 2) + 1))
    monitor.write(lockedReason:sub(1, math.max(0, w - 2)))
    return
  end

  -- destination grid ------------------------------------------------------
  local pages = math.max(1, math.ceil(#destinations / perPage))
  if page > pages then page = pages end
  if page < 1 then page = 1 end

  local cellWidth = math.floor((w - 2) / columns)
  local first = (page - 1) * perPage + 1

  for index = first, math.min(first + perPage - 1, #destinations) do
    local slot = index - first
    local col = slot % columns
    local row = math.floor(slot / columns)
    local dest = destinations[index]

    local x = 2 + col * cellWidth
    local y = 2 + row
    local bg = dest.busy and COLORS.busy or COLORS.button
    local fg = dest.busy and COLORS.busyText or COLORS.text

    drawButton(x, y, cellWidth - 1, dest.label, bg, fg)
    if not dest.busy then
      buttons[#buttons + 1] = {
        x1 = x, y1 = y, x2 = x + cellWidth - 2, y2 = y,
        action = "select", value = dest.id,
      }
    end
  end

  -- pager -----------------------------------------------------------------
  if pages > 1 then
    if page > 1 then
      drawButton(2, h, 8, "< Prev", COLORS.button, COLORS.text)
      buttons[#buttons + 1] =
        { x1 = 2, y1 = h, x2 = 9, y2 = h, action = "page", value = page - 1 }
    end

    local label = page .. "/" .. pages
    monitor.setBackgroundColor(COLORS.bg)
    monitor.setTextColor(COLORS.text)
    monitor.setCursorPos(math.max(1, math.floor((w - #label) / 2)), h)
    monitor.write(label)

    if page < pages then
      drawButton(w - 9, h, 8, "Next >", COLORS.button, COLORS.text)
      buttons[#buttons + 1] =
        { x1 = w - 9, y1 = h, x2 = w - 2, y2 = h, action = "page", value = page + 1 }
    end
  end
end


-- ===========================================================================
-- 4. ACCESS POINT HARDWARE
-- ===========================================================================

---@param open boolean
local function setDoors(open)
  redstone.setOutput(WIRING.doors, open)
end

---@param light "green"|"red"|"off"
local function setLights(light)
  for color, side in pairs(WIRING.lights) do
    redstone.setOutput(side, light == color)
  end
end


-- ===========================================================================
-- 5. MAIN LOOP
-- ===========================================================================

---@param destinationId NodeId
function Panel.request(destinationId)
  status.text = "Requesting route..."
  Panel.draw()
  link:send({ cmd = "route", from = MY_NODE, to = destinationId })
end

---Registration. The master keeps the config in its own persistent registry,
---so a panel that is destroyed and rebuilt can be told what it used to be,
---and so there is one place to look when a station stops answering.
local function announce()
  link:send({
    cmd    = "hello",
    role   = "panel",
    node   = MY_NODE,
    label  = CFG.label,
    config = CFG,
  })
end

---@param cfg HypertubeConfig
function Panel.main(cfg)
  CFG = cfg
  MY_NODE = cfg.node
  WIRING = cfg.wiring

  if type(MY_NODE) ~= "string" or type(WIRING) ~= "table" then
    error("this panel is not configured -- run: startup config", 0)
  end

  -- Check the sides before touching any of them. redstone.getInput on a bad
  -- side throws, and the throw would land AFTER the first draw, leaving the
  -- monitor frozen on a half-drawn screen with the real error on the
  -- computer behind it.
  local VALID_SIDES = {
    top = true, bottom = true, left = true, right = true, front = true, back = true,
  }
  local wired = { doors = WIRING.doors, detector = WIRING.detector }
  for name, side in pairs(WIRING.lights or {}) do wired[name .. " lamp"] = side end

  for what, side in pairs(wired) do
    if not VALID_SIDES[side] then
      error(what .. " is set to '" .. tostring(side)
        .. "', which is not a side -- run: startup config", 0)
    end
  end

  common.openModem("any")
  -- rednet.host also refuses a duplicate, which catches two panels wired to
  -- the same access point before they start fighting over its doors.
  rednet.host(common.PROTOCOL, common.hostname("panel", MY_NODE))

  monitor = peripheral.find("monitor")
  if monitor == nil then error("no monitor attached", 0) end
  if not monitor.isColor() then
    error("this panel needs an ADVANCED monitor (colour + touch)", 0)
  end
  monitor.setTextScale(TEXT_SCALE)

  setDoors(false)
  setLights("off")
  announce()
  Panel.draw()

  local entered = common.edgeDetector({ WIRING.detector })
  local retry = os.startTimer(common.HELLO_INTERVAL)
  local doorTimer = nil

  while true do
    local event, a, b, c = os.pullEvent()

    if event == "monitor_touch" then
      local hit = hitTest(b, c)
      if hit ~= nil then
        if hit.action == "select" then
          Panel.request(hit.value)
        elseif hit.action == "page" then
          page = hit.value
          Panel.draw()
        elseif hit.action == "cancel" then
          link:send({ cmd = "cancel", ticket = status.ticket })
        end
      end

    elseif event == "redstone" then
      -- The scanner sits just inside the entrance. At the origin a rising edge
      -- means the player is in the tube; at the destination the same detector
      -- reports the arrival. The master knows which end this is.
      if #entered() > 0 then
        link:send({ cmd = "enter", node = MY_NODE })
      end

    elseif event == "rednet_message" then
      local msg = b
      if type(msg) == "table" and type(msg.cmd) == "string" then
        if msg.cmd == "destinations" then
          link:learn(a)

          local firstList = not known
          local lockChanged = lockedReason ~= msg.locked

          known = true
          destinations = msg.nodes or {}
          lockedReason = msg.locked

          -- The header holds whatever this panel was last TOLD, and a panel
          -- that has never asked for a route is never told anything: without
          -- this it sits on the "Connecting..." it booted with, for ever,
          -- above a perfectly working list of destinations.
          if status.state == "idle" and (firstList or lockChanged) then
            status.text = idleText()
          end

          Panel.draw()

        elseif msg.cmd == "ping" then
          -- the master is auditing: say we are here
          link:learn(a)
          rednet.send(a, { cmd = "pong", round = msg.round, node = MY_NODE },
            common.PROTOCOL)

        elseif msg.cmd == "state" then
          link:learn(a)
          status = msg
          setDoors(msg.doors == true)
          setLights(msg.light or "off")
          Panel.draw()

          -- Arrival opens these doors; nothing else would ever close them,
          -- because the ticket stops existing the moment we are told.
          if msg.autoClose then
            doorTimer = os.startTimer(common.DOOR_HOLD)
          end

        elseif msg.cmd == "discover" then
          link:learn(a)
          announce()
        end
      end

    elseif event == "timer" then
      if a == doorTimer then
        doorTimer = nil
        setDoors(false)
        setLights("off")
        status.doors = false
        status.text = idleText()
        Panel.draw()

      elseif a == retry then
        -- Keep announcing until the master has sent us a list. Until then
        -- MasterLink broadcasts, so a button press is not lost either.
        if not known then
          status.text = idleText()
          announce()
          Panel.draw()
        end
        retry = os.startTimer(common.HELLO_INTERVAL)
      end

    elseif event == "monitor_resize" then
      Panel.draw()
    end
  end
end

return Panel
