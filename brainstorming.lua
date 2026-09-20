--[[ ===========================================================================
  HYPERTUBE NETWORK -- ARCHITECTURE OVERVIEW
  ---------------------------------------------------------------------------
  Design notes only. The code lives in:

      common.lua   shared types, protocol constants, helpers
      master.lua   ROLE 1: routing, locks, tickets
      panel.lua    ROLE 2: endpoint interface + access point hardware
      node.lua     ROLE 3: junction control and/or tube sensors

  Assumptions
    * The network is a TREE: no cycles, so between two access points there is
      exactly one path. The search counts nodes anyway, ready for loops.
    * Every node has AT MOST 3 links (hypertube T-junction).
    * A route locks every node and link it uses until the player arrives.


  ---------------------------------------------------------------------------
  ROLE 1 -- MASTER SERVER                                         master.lua
  ---------------------------------------------------------------------------
  The only computer that knows the topology. Holds NODES (links), the
  lock table, the ticket table and the queue. Never touches redstone: it asks
  panels to open doors and controllers to switch junctions.

    * findPath      breadth-first: fewest nodes wins. Tubes carry no travel
                    time, so there is nothing to weigh one against another,
                    and every junction on a route is one more thing to switch,
                    ack and wait on. On a tree it just walks the tree
    * claimPath     all-or-nothing lock over every node AND link on the path
    * applyRoute    fires one "set" per junction, each with a sequence number
    * watchdog      one deadline per ticket state, checked once a second

  Locking is safe without any mutex because the event loop is single threaded:
  claimPath checks the whole path and then writes every claim without yielding,
  so two simultaneous requests can never interleave.


  ---------------------------------------------------------------------------
  ROLE 2 -- ENDPOINT PANEL                                         panel.lua
  ---------------------------------------------------------------------------
  One per access point. Owns the interface and the local hardware, and decides
  nothing about routing: it sends "route A -> B" and renders what comes back.

    * monitor       2x1 (~29x9 at textScale 0.5) or 2x2 (~29x18); the layout is
                    derived from getSize() so the page size adapts by itself
    * pages         destinations are paged with a < Prev  n/m  Next > footer,
                    2 columns on wide monitors, busy entries greyed and dead
    * doors         redstone output, driven purely by the master's state push
    * lights        green = boardable, red = occupied, off = idle
    * detector      just inside the entrance; a rising edge means the player is
                    in the tube -> "enter" to the master -> doors close behind
                    them and the ticket moves from boarding to transit

  Hit testing uses a `buttons` list rebuilt on every draw, so a touch can never
  land on a button from a previous page.


  ---------------------------------------------------------------------------
  ROLE 3 -- NODE CONTROLLER                                         node.lua
  ---------------------------------------------------------------------------
  Sits next to one or more junctions. MODE picks what it does:

    "control"   switch junctions when the master asks
    "sensor"    only report its junctions' scanners
    "both"      both

  The redstone wiring lives here, not on the master. The master says "a pod
  arrives at this port and must leave by that one" and the controller works out
  which level that needs, so re-wiring or re-aiming a junction never touches
  the master's config.

  Junction scanners are what make an early exit cheap to detect: a player who
  disconnects, /homes or /spawns out mid-route simply never reaches the next
  scanner, and the ticket fails there instead of after the whole route's ETA.
  The same reports drive TRAILING_RELEASE.

  Scanners are optional and only exist at junctions, so what comes back is a
  SUBSEQUENCE of the path, not every hop. The master therefore times each wait
  to the next node that can actually report -- the next fitted junction, or the
  destination panel -- rather than to the next hop, which would kill any route
  whose next junction has no scanner. Fitting more scanners buys tighter
  detection, and fitting none still works: the route is then only checked on
  arrival.


  ---------------------------------------------------------------------------
  HARDWARE  (Create: Hypertubes 0.6.0, confirmed in world)
  ---------------------------------------------------------------------------
  There is no ComputerCraft peripheral for hypertubes. Redstone is the whole
  interface, in both directions, through two tube attachments:

    Tube Scanner            only fits on a JUNCTION, never part way along a
                            tube, and reports the junction as a whole: a ONE
                            SECOND pulse saying something went through, with
                            no way to tell which branch it took.

                            One second is comfortably long, so the rising edge
                            is never missed. But two travellers less than a
                            second apart merge into one report, because the
                            line never drops between them.

    Redstone Detector       the junction follows the LEVEL on its line, but
                            what that level does depends on where the pod
                            came in:

                              entry          LOW              HIGH
                              straight run   carry straight   into the branch
                              the branch     leave right      leave left

  A junction is therefore a routing function of (entry, level), not a switch
  between two connections, and the move the master asks for has to be DIRECTED.
  The unordered pair {a, branch} needs the line HIGH travelling a -> branch and
  LOW travelling branch -> a, whenever a is the right-hand exit -- so a pair of
  port names alone cannot say which level is wanted.

  Which of the two straight ports counts as "right" is fixed by how the
  junction sits in the world, so it is asked once during setup and stored.
  Everything else follows from it.

  A level, rather than a pulse, is what keeps the controller stateless:

    * Setting a junction is idempotent. Re-asserting the mode it is already in
      costs one redstone write and changes nothing, so no code has to ask
      "is it already there?" before acting.
    * Boot can drop every line and have the whole network in a known state.
      Nothing has to be remembered across a reboot, and there is no way for
      the controller's idea of a junction to drift away from the world.
    * One output side drives a junction, and the config is the shape of the
      junction rather than a list of states: the two ends of the straight run,
      the branch, and which end is the right-hand exit from that branch.
    * IDLE_ON_RELEASE is therefore on. A finished route drops its junctions
      back to straight, so anyone who walks into a tube by hand with no ticket
      runs straight through rather than down whichever branch was last used.


  ---------------------------------------------------------------------------
  TICKET STATE MACHINE
  ---------------------------------------------------------------------------
    switching --> boarding --> transit --> released
        |             |            |
        |             |            +-- missed a control detector
        |             +-- nobody boarded within BOARDING_TIMEOUT
        +-- a junction never acked within ACK_TIMEOUT

  Every path out of the machine ends in releasePath, which drops the locks,
  tells the origin panel to go idle and pumps the queue.

  Nothing in the master blocks on rednet.receive. Acks arrive as ordinary
  events and are matched by (node, seq), so an unrelated message can never be
  mistaken for an ack -- the bug an inline "wait for ack" would have had.


  ---------------------------------------------------------------------------
  WHAT LIVES WHERE
  ---------------------------------------------------------------------------
  The installer overwrites every program it manages, so nothing a person types
  in may live inside one. Three files belong to the computer instead, and are
  never fetched or deleted:

    /hypertube.cfg       this computer's role, frequency and wiring, from the
                         setup wizard
    /hypertube_registry  MASTER ONLY: who registered as what, written the
                         moment a registration arrives. The map of the network
                         is rebuilt from this, never typed in.

  There is no topology file. Each computer is asked one question about the
  world -- what is at the other end of each of its tubes -- and the master
  pairs up the two ends that name each other. The answer comes from the
  computer standing next to the tube, so it is corrected by whoever rebuilds
  that junction, at the moment they rebuild it, and there is no second copy to
  fall out of date. Until every named neighbour has registered and agreed, the
  map is incomplete and the network stays locked, naming what is missing.


  ---------------------------------------------------------------------------
  AUDIT AND LOCKDOWN
  ---------------------------------------------------------------------------
  Every registration is written to /hypertube_registry the moment it arrives,
  so the file always describes what is out there, and the master reboots
  already knowing the network instead of waiting for everyone to say hello.

  Every AUDIT_INTERVAL seconds the master pings every access point and every
  junction and gives them AUDIT_TIMEOUT to answer. Anything that does not
  locks the network: no new routes until it comes back. The master starts
  locked and the first audit is what opens it, because assuming everything is
  fine until told otherwise would dispatch routes into junctions nobody has
  heard from since the reboot.

  The reasoning: a silent junction is worse than a busy one. The master cannot
  read a junction, so it cannot tell a controller that died from one that is
  about to put somebody into a wall. Refusing to dispatch is the only honest
  answer, and the log names each missing node with how long it has been quiet.

  Routes already in flight are left alone. Their locks still hold, their
  junctions are already set, and a player in a tube is better off arriving
  than having the route torn up underneath them.

  A failed send starts an audit immediately rather than waiting for the next
  scheduled round, so noticing takes seconds rather than up to a minute.


  ---------------------------------------------------------------------------
  DISCOVERY
  ---------------------------------------------------------------------------
  No computer ids in any config file. Each role hosts a rednet hostname
  ("master", "panel:<id>", "node:<id>") and announces itself with "hello" on
  boot; the master also broadcasts "discover" on ITS boot, so either startup
  order works. A controller managing several junctions can only host one
  hostname per protocol, which is exactly why "hello" carries the full list.

  Modems are opened with peripheral.find's filter rather than a configured
  side, so wired, wireless and ender modems all work with no config.


  ---------------------------------------------------------------------------
  OPEN QUESTIONS / NEXT STEPS
  ---------------------------------------------------------------------------
  * HOP_SECONDS is the one timing number left, and it is a blunt one: the
    watchdog allows that long per hop crossed. It only has to be longer than
    the longest tube in the network. If a genuine ETA is ever wanted, that is
    when travel times would have to come back -- measured by a mapping run
    rather than typed in by hand.
  * Persistence: write locks and tickets to disk on every change, so a server
    restart or chunk unload cannot strand a locked route.
  * An Advanced Peripherals player detector alongside the scanner would tell
    us WHO is in the tube, which would let a panel show "occupied by <name>"
    and turn "player left the tube" from an inference into a fact.
  * Junction verification: a scanner on each branch would let the master
    confirm which way a pod actually went, rather than inferring it from the
    next detector that fires. Worth it on a junction that carries a lot.
  * TRAILING_RELEASE stays off until every junction has a detector. A missed
    detection would otherwise free a tube that still has somebody in it.
  * Queue fairness: currently strict FIFO, so a blocked long route holds up
    shorter ones behind it. Scan the whole queue if throughput matters more.
  * Once LOOPS exist:
      - findPath's `avoid` argument starts doing real work, routing around a
        busy branch instead of queueing,
      - claimPath must also lock the DIRECTION of travel, or two pods can be
        granted the same corridor head-on.
=========================================================================== ]]
