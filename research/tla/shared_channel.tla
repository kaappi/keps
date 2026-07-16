--------------------------- MODULE shared_channel ---------------------------
(***************************************************************************)
(* Bounded model of KEP-0002's SharedChannel protocol (P2 in               *)
(* research/open-problems.md).                                             *)
(*                                                                         *)
(* One channel, three OS threads (t0 owns it pre-promotion and runs two    *)
(* fibers), modeling:                                                      *)
(*   - promotion with local-queue drain and local-waiter migration (§2)    *)
(*   - send with slot reservation and the copy-failure path (§4)           *)
(*   - receive with drain-then-EOF (§4, §6)                                *)
(*   - close with both-lists snapshot-and-clear (§6)                       *)
(*   - the ThreadNotifier flag+fd notify and the swap-loop/poll consume    *)
(*     protocol (§5)                                                       *)
(*   - the §1 refcount state machine incl. envelope stubs (self-sends)     *)
(*     and destroy-at-zero                                                 *)
(*                                                                         *)
(* Atomicity: every mutex-held region of the §4/§6 pseudocode is one       *)
(* atomic action (the mutex serializes them); every lock-free window is    *)
(* its own step: registered-but-not-yet-parked, the envelope build, each   *)
(* per-target flag-then-fd ring, the wake_pending swap, the poll, and the  *)
(* refcount transitions.  Fibers of one thread are serialized by cur[t]    *)
(* (cooperative scheduling: primitives have no fiber switch points).       *)
(*                                                                         *)
(* Rendezvous (capacity 0, the kaappi#1600/#1601 amendment): Cap = 0 is   *)
(* a rendezvous channel — send admission is bounded by rvDemand, the      *)
(* count of receivers currently committed to the channel (each holds one  *)
(* demand token, acquired idempotently at its park decision and released  *)
(* on every terminal exit).  A receiver whose registration grows the      *)
(* demand also snapshot-and-rings send_waiters: new demand is a send-side *)
(* event.  RvRing = "noring" keeps the rejected no-ring variant as a      *)
(* regression witness (Finding 4: both senders park before any receiver   *)
(* commits; without the ring nothing ever wakes them).                    *)
(*                                                                         *)
(* Scoped out (see README.md): notifier refcounts/alive flag (no thread    *)
(* exits mid-model), §6 timeouts (incl. the rendezvous delivery-wins and   *)
(* reservation-drain timeout rules), local-channel capacity pre-promotion, *)
(* the §5 deadlock heuristic (P4), equality/identity (UQ 4).               *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Cap,          \* channel capacity; >= total sends models "unbounded";
                \* 0 = rendezvous (admission bounded by receiver demand)
  SweepPolicy,  \* "selective" (§5 as written: flip only if ready-for-it)
                \* | "flip_all" (candidate repair: flip every parked shared waiter)
  FailCopy,     \* TRUE: the §4 step-9 copy-failure branch is reachable
  Scenario,     \* "core" | "strand" | "rv"  (fiber scripts; see README)
  EofPolicy,    \* "asis"               (pre-amendment §4 step 6: EOF when
                \*     drained ∧ closed — REJECTED, Finding 2)
                \* | "wait_reserved_naive" (EOF additionally waits for
                \*     reserved = 0, no other change — REJECTED, Finding 3)
                \* | "wait_reserved"    (same, plus the §4 failure path also
                \*     rings recv_waiters when closed — the AMENDED normative
                \*     text)
  RecvFail,     \* TRUE: the receive-side copy-out can fail; the amended §4
                \* re-queues the envelope at the head and rings recv_waiters
                \* ("receive fails => nothing received")
  RvRing,       \* "ring"   (normative: a registration that grows rvDemand
                \*     snapshot-and-rings send_waiters)
                \* | "noring" (REJECTED, Finding 4: demand grows silently —
                \*     parked senders are never woken)
  RvPopWithdraw,\* "at_pop"    (normative, Finding 5 repair: a pop by a
                \*     token-holding receiver withdraws its demand in the
                \*     same mutex section as the pop)
                \* | "at_deinit" (REJECTED, Finding 5: the token stays
                \*     counted through the unlocked copy-out, admitting a
                \*     second send against an already-satisfied receiver)
  RvAbandon     \* "none" | "atomic" | "naive" — receiver abandonment (the
                \* §6 timeout withdraw, modeled as a spontaneous decision
                \* since timers are scoped out). "atomic" (normative,
                \* Finding 6 repair): queue-check, reservation-check, and
                \* withdrawal are one mutex section — enabled only when
                \* queue = <<>> ∧ reserved = 0, which structurally encodes
                \* both delivery-wins and the reservation-drain rule.
                \* "naive" (REJECTED, Finding 6): withdraws without the
                \* reservation check, stranding an admitted send.

ASSUME Cap \in Nat
ASSUME SweepPolicy \in {"selective", "flip_all"}
ASSUME FailCopy \in BOOLEAN
ASSUME Scenario \in {"core", "strand", "rv", "rv2", "rva"}
ASSUME EofPolicy \in {"asis", "wait_reserved_naive", "wait_reserved"}
ASSUME RecvFail \in BOOLEAN
ASSUME RvRing \in {"ring", "noring"}
ASSUME RvPopWithdraw \in {"at_pop", "at_deinit"}
ASSUME RvAbandon \in {"none", "atomic", "naive"}

Threads == {"t0", "t1", "t2"}
Fibers  == {"f0a", "f0b", "f1", "f2"}
Th(f)   == CASE f = "f0a" -> "t0" [] f = "f0b" -> "t0"
             [] f = "f1"  -> "t1" [] f = "f2"  -> "t2"
FibersOf(t) == {f \in Fibers : Th(f) = t}
Idle    == "idle"

(* Scripts.                                                                *)
(* core:   f0a: local self-send preload -> promote -> hand-offs -> 1 plain *)
(*              shared send -> close;                                      *)
(*         f0b: 1 receive (may park locally pre-promotion -> migration);   *)
(*         f1:  1 self send;   f2: 2 receives.                             *)
(* strand: the §8 shutdown race — f1: 1 plain send; f0b, f2: receive       *)
(*         until EOF; f0a: promote -> hand-offs -> close (racing f1).      *)
(* rv:     rendezvous (Cap = 0) — no preload (nothing can be queued        *)
(*         without demand); f0a: promote -> hand-offs -> 1 plain send ->   *)
(*         close; f1: 1 self send; f0b, f2: 1 receive each (f0b may park   *)
(*         locally pre-promotion, exercising token-carrying migration).    *)
(*         Sends = receive budgets, so NoAbandonedTask must hold.          *)
(* rv2:    Finding 5 geometry — f1: 2 self sends against f0b's single      *)
(*         receive, no other receiver (f2 idle; f0a only promotes and      *)
(*         closes). Under "at_deinit" the pop window admits f1's second    *)
(*         send against f0b's already-satisfied token and no receiver      *)
(*         remains: the handoff is destroyed at teardown (NoAbandonedTask  *)
(*         fails). Under "at_pop" the second send parks and close raises   *)
(*         it out.                                                         *)
(* rva:    Finding 6 geometry — f1: 1 self send against f0b's single       *)
(*         receive, and f0b may ABANDON its wait once (the modeled §6      *)
(*         timeout withdraw); f2 idle; f0a promotes and closes. Under      *)
(*         "naive" the withdraw can interleave with f1's in-flight         *)
(*         reservation: f1 pushes into withdrawn demand, nobody is left,   *)
(*         NoAbandonedTask fails. Under "atomic" the abandon is disabled   *)
(*         while reserved > 0 (drain) or the queue is non-empty            *)
(*         (delivery-wins), so nothing strands.                            *)
(* rv2/rva use PLAIN sends deliberately: a stranded SELF envelope would    *)
(* hold a stub of the channel, pinning rc above zero — the strand would    *)
(* then surface as the documented §1 cycle leak instead of a              *)
(* destroy-at-zero deinit, and NoAbandonedTask (destroyDeinit = 0) would   *)
(* hold vacuously. Plain envelopes keep the property able to see the      *)
(* abandoned handoff.                                                      *)
PreloadSelf   == Scenario = "core"
PlainSends(f) == CASE Scenario = "core"   -> (IF f = "f0a" THEN 1 ELSE 0)
                   [] Scenario = "strand" -> (IF f = "f1"  THEN 1 ELSE 0)
                   [] Scenario = "rv"     -> (IF f = "f0a" THEN 1 ELSE 0)
                   [] Scenario = "rv2"    -> (IF f = "f1"  THEN 2 ELSE 0)
                   [] Scenario = "rva"    -> (IF f = "f1"  THEN 1 ELSE 0)
SelfSends(f)  == CASE Scenario = "core"   -> (IF f = "f1"  THEN 1 ELSE 0)
                   [] Scenario = "strand" -> 0
                   [] Scenario = "rv"     -> (IF f = "f1"  THEN 1 ELSE 0)
                   [] Scenario \in {"rv2", "rva"} -> 0
RecvBudget(f) == CASE Scenario = "core"   -> (CASE f = "f0b" -> 1 [] f = "f2" -> 2
                                                [] OTHER -> 0)
                   [] Scenario = "strand" -> (IF f \in {"f0b", "f2"} THEN 2 ELSE 0)
                   [] Scenario = "rv"     -> (IF f \in {"f0b", "f2"} THEN 1 ELSE 0)
                   [] Scenario \in {"rv2", "rva"} -> (IF f = "f0b" THEN 1 ELSE 0)
UntilEOF(f)   == Scenario = "strand" /\ f \in {"f0b", "f2"}
Closer(f)     == f = "f0a"
(* One bounded abandonment, rva's f0b only: enough to reach the Finding-6  *)
(* interleavings without letting weak fairness "escape" every wait through *)
(* abandonment (which would hollow out the lost-wakeup meaning of          *)
(* Termination for the other fibers).                                      *)
AbandonBudget(f) == IF Scenario = "rva" /\ f = "f0b" THEN 1 ELSE 0

VARIABLES
  \* channel, local representation (pre-promotion, t0 only)
  promoted, lq,
  \* channel, shared representation — all guarded by the SharedChannel mutex
  queue,        \* Seq of envelopes: "plain" | "self" ("self" carries a stub of ch)
  reservedV,    \* §4 slots claimed by in-flight sends
  closed,
  recvW, sendW, \* notifier lists: SUBSET Threads (set = §7 dedup, one entry/thread)
  rvDemand,     \* rendezvous demand (Cap = 0 only): committed receivers'
                \* outstanding tokens; the send-admission bound. Lives with
                \* the channel (ch.rv_demand locally, SharedChannel.rv_demand
                \* once promoted — promotion carries it, which one shared
                \* variable models directly)
  \* shared-object protocol (§1)
  rc,           \* SharedChannel.refcount
  held,         \* [Threads -> Nat]: counted stubs on each thread's heap
  destroyed,
  \* per-thread notifier + scheduler (§5)
  wakeP, fdR,   \* [Threads -> BOOLEAN]: wake_pending; pending fd event
  cur,          \* [Threads -> Fibers ∪ {Idle}]: fiber currently on the thread
  started,      \* [Threads -> BOOLEAN]: got its stub via the thunk hand-off
  tornDown,     \* [Threads -> BOOLEAN]: heap freed after all fibers finished
  \* fiber state (record per fiber; fields described in README)
  fst,
  \* envelope-fate counters (P-3/P-4/P-5 invariants)
  built, pushed, receivedCnt, destroyDeinit, failDeinit

chanVars  == << promoted, lq, queue, reservedV, closed, recvW, sendW, rvDemand >>
rcVars    == << rc, held, destroyed >>
notifVars == << wakeP, fdR >>
schedVars == << cur, started, tornDown >>
cntVars   == << built, pushed, receivedCnt, destroyDeinit, failDeinit >>
vars == << promoted, lq, queue, reservedV, closed, recvW, sendW, rvDemand,
           rc, held, destroyed, wakeP, fdR, cur, started, tornDown, fst,
           built, pushed, receivedCnt, destroyDeinit, failDeinit >>

Msg == {"plain", "self"}
EnvVals == {"none", "plain", "self", "failplain", "failself"}
PCs == {"ready", "h1", "h2",
        "send_preparked", "send_parked", "send_wake",
        "send_building", "send_push", "send_ring", "send_done",
        "send_fail_locked", "send_fail_ring", "send_fail_deinit",
        "recv_preparked", "recv_parked", "recv_wake",
        "recv_ring", "recv_copyout", "recv_deinit",
        "recv_fail_ring", "recv_fail_done", "recv_demand_ring",
        "lrecv_preparked", "lrecv_parked",
        "close_ring", "close_done"}

Init ==
  /\ promoted = FALSE /\ lq = << >>
  /\ queue = << >> /\ reservedV = 0 /\ closed = FALSE
  /\ recvW = {} /\ sendW = {} /\ rvDemand = 0
  /\ rc = 0 /\ held = [t \in Threads |-> 0] /\ destroyed = FALSE
  /\ wakeP = [t \in Threads |-> FALSE] /\ fdR = [t \in Threads |-> FALSE]
  /\ cur = [t \in Threads |-> Idle]
  /\ started = [t \in Threads |-> t = "t0"]
  /\ tornDown = [t \in Threads |-> FALSE]
  \* The pre-promotion local self-send is optional (\E p): with it, the
  \* promotion drain and re-entrant alias are exercised; without it, f0b
  \* can be parked on the *empty* local channel at promotion time, which
  \* is the §2 step 4 waiter-migration case.
  /\ \E p \in (IF PreloadSelf THEN {0, 1} ELSE {0}) :
       fst = [f \in Fibers |->
         [pc |-> "ready", kind |-> "none", env |-> "none", snap |-> {},
          rt |-> "none", contPc |-> "ready",
          plainLeft |-> PlainSends(f), selfLeft |-> SelfSends(f),
          recvLeft |-> RecvBudget(f),
          failLeft |-> IF RecvBudget(f) > 0 THEN 1 ELSE 0,
          preloadLeft |-> IF f = "f0a" THEN p ELSE 0,
          closeLeft |-> IF Closer(f) THEN 1 ELSE 0,
          eof |-> FALSE, hasTok |-> FALSE,
          abandonLeft |-> AbandonBudget(f)]]
  /\ built = 0 /\ pushed = 0 /\ receivedCnt = 0
  /\ destroyDeinit = 0 /\ failDeinit = 0

-----------------------------------------------------------------------------
(* Derived state *)

SelfCount(s) == Cardinality({i \in DOMAIN s : s[i] = "self"})
SelfInQueue == SelfCount(queue)
SelfInFlight == Cardinality({f \in Fibers : fst[f].env \in {"self", "failself"}})
InFlightEnvCnt == Cardinality({f \in Fibers : fst[f].env # "none"})
SumHeld == held["t0"] + held["t1"] + held["t2"]
Parked(f) == fst[f].pc \in {"send_parked", "recv_parked"}
SendsDone(f) == fst[f].plainLeft = 0 /\ fst[f].selfLeft = 0
                /\ fst[f].preloadLeft = 0
FiberDone(f) ==
  /\ fst[f].pc = "ready" /\ SendsDone(f) /\ fst[f].closeLeft = 0
  /\ IF UntilEOF(f) THEN fst[f].eof ELSE (fst[f].recvLeft = 0 \/ fst[f].eof)
AllDone == \A f \in Fibers : FiberDone(f)
AllTorn == \A t \in Threads : tornDown[t]

(* Send-admission bound: static capacity, or — rendezvous (Cap = 0) — the  *)
(* current receiver demand.  Everything downstream (SendFull/SendReserve/  *)
(* ReadySend) is the unchanged §4 protocol against this bound.             *)
Bound == IF Cap = 0 THEN rvDemand ELSE Cap

ReadyRecv == Len(queue) > 0 \/ closed
ReadySend == Len(queue) + reservedV < Bound \/ closed
ReadyFor(f) == CASE fst[f].pc = "recv_parked" -> ReadyRecv
                 [] fst[f].pc = "send_parked" -> ReadySend
                 [] OTHER -> FALSE

-----------------------------------------------------------------------------
(* §5: ringing a waiter snapshot, one notifier at a time, flag THEN fd.    *)
(* A fiber in a *_ring pc with a non-empty snap performs two steps per     *)
(* target; when snap is empty it proceeds to contPc.  Rings run with      *)
(* cur[t] held — they execute inside the primitive on the ringer's thread. *)

RingPcs == {"send_ring", "send_fail_ring", "recv_ring", "recv_fail_ring",
            "close_ring", "recv_demand_ring"}

RingFlag(f) ==
  /\ fst[f].pc \in RingPcs /\ fst[f].rt = "none" /\ fst[f].snap # {}
  /\ \E u \in fst[f].snap :
       /\ wakeP' = [wakeP EXCEPT ![u] = TRUE]
       /\ fst' = [fst EXCEPT ![f].rt = u]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, sendW,
                  rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED fdR /\ UNCHANGED schedVars
  /\ UNCHANGED cntVars

RingFd(f) ==
  /\ fst[f].pc \in RingPcs /\ fst[f].rt # "none"
  /\ fdR' = [fdR EXCEPT ![fst[f].rt] = TRUE]
  /\ fst' = [fst EXCEPT ![f].snap = fst[f].snap \ {fst[f].rt},
                        ![f].rt = "none"]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED wakeP
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

RingDone(f) ==
  /\ fst[f].pc \in RingPcs /\ fst[f].snap = {} /\ fst[f].rt = "none"
  /\ fst' = [fst EXCEPT ![f].pc = fst[f].contPc]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

-----------------------------------------------------------------------------
(* Pre-promotion local operations (t0 only; today's lock-free path).       *)

LocalPreloadSend(f) ==   \* f0a's local (channel-send ch ch) before any thread exists;
                         \* a local send wakes local waiters (wakeChannelWaiters).
                         \* Only the core scenario preloads, never with Cap = 0
                         \* (a rendezvous local send would need local demand).
  /\ f = "f0a" /\ fst[f].pc = "ready" /\ fst[f].preloadLeft = 1 /\ ~promoted
  /\ cur["t0"] = Idle
  /\ lq' = Append(lq, "self")
  /\ fst' = [fst EXCEPT ![f].preloadLeft = 0,
               !["f0b"].pc = IF fst["f0b"].pc = "lrecv_parked"
                               THEN "ready" ELSE fst["f0b"].pc]
  /\ UNCHANGED << promoted, queue, reservedV, closed, recvW, sendW, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED cntVars

LocalRecvPop(f) ==       \* f0b receives on the local representation; a value in
                         \* hand releases any demand token this wait acquired
  /\ f = "f0b" /\ fst[f].pc = "ready" /\ fst[f].recvLeft > 0 /\ ~fst[f].eof
  /\ ~promoted /\ cur["t0"] = Idle /\ lq # << >>
  /\ lq' = Tail(lq)
  /\ rvDemand' = rvDemand - (IF fst[f].hasTok THEN 1 ELSE 0)
  /\ fst' = [fst EXCEPT ![f].recvLeft = fst[f].recvLeft - 1,
                        ![f].hasTok = FALSE]
  /\ UNCHANGED << promoted, queue, reservedV, closed, recvW, sendW >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED cntVars

LocalRecvParkA(f) ==     \* empty local queue: enter the primitive, decide to park
  /\ f = "f0b" /\ fst[f].pc = "ready" /\ fst[f].recvLeft > 0 /\ ~fst[f].eof
  /\ ~promoted /\ cur["t0"] = Idle /\ lq = << >>
  /\ cur' = [cur EXCEPT !["t0"] = f]
  /\ fst' = [fst EXCEPT ![f].pc = "lrecv_preparked"]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

LocalRecvParkB(f) ==     \* park under the local waiting_on protocol; on a
                         \* rendezvous channel the park is the commitment
                         \* point: acquire the demand token (idempotent —
                         \* a woken-and-reparked fiber already holds one)
  /\ fst[f].pc = "lrecv_preparked"
  /\ rvDemand' = rvDemand + (IF Cap = 0 /\ ~fst[f].hasTok THEN 1 ELSE 0)
  /\ fst' = [fst EXCEPT ![f].pc = "lrecv_parked",
                        ![f].hasTok = (Cap = 0) \/ fst[f].hasTok]
  /\ cur' = [cur EXCEPT !["t0"] = Idle]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, sendW >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

(* Exits from lrecv_parked: a local send wakes the waiter (it retries and  *)
(* may run before or after f0a's next step — cooperative nondeterminism),  *)
(* or promotion migrates it (§2 step 4, the "park locally -> promote ->    *)
(* remote send wakes" Phase 3 regression case, reachable when the preload  *)
(* is skipped).  A woken-but-not-yet-retried fiber is NOT migrated — its   *)
(* waiting_on was cleared by the wake — matching the runtime scan.         *)

-----------------------------------------------------------------------------
(* §2 promotion + §3 thunk hand-offs (f0a, inside thread-start!).          *)
(* Promotion is one atomic action: it runs on the owning thread inside a   *)
(* primitive with no fiber switch points, and no other thread can reach    *)
(* the channel until the hand-off (invariant 4).  The re-entrant drain     *)
(* (a queued message containing ch itself) is modeled by its specified     *)
(* outcome (§2 step 2): the envelope gets an aliased stub, rc += 1.        *)

Promote(f) ==
  /\ f = "f0a" /\ fst[f].pc = "ready" /\ fst[f].preloadLeft = 0 /\ ~promoted
  /\ cur["t0"] = Idle
  /\ promoted' = TRUE
  /\ rc' = 1 + SelfCount(lq)                 \* owner stub + drained-envelope stubs
  /\ held' = [held EXCEPT !["t0"] = 1]
  /\ queue' = lq /\ lq' = << >>              \* drain in FIFO order
  /\ built' = built + Len(lq) /\ pushed' = pushed + Len(lq)
  /\ IF fst["f0b"].pc = "lrecv_parked"       \* §2 step 4: migrate the local waiter
       THEN /\ recvW' = recvW \union {"t0"}
            /\ fst' = [fst EXCEPT ![f].pc = "h1", !["f0b"].pc = "recv_parked"]
       ELSE /\ recvW' = recvW
            /\ fst' = [fst EXCEPT ![f].pc = "h1"]
  /\ cur' = [cur EXCEPT !["t0"] = f]
  \* rvDemand carries over unchanged: promoteChannel copies ch.rv_demand
  \* into the SharedChannel (one shared variable models the copy), so a
  \* token acquired at a pre-promotion local park stays counted.
  /\ UNCHANGED << reservedV, closed, sendW, rvDemand >> /\ UNCHANGED destroyed
  /\ UNCHANGED notifVars /\ UNCHANGED << started, tornDown >>
  /\ UNCHANGED << receivedCnt, destroyDeinit, failDeinit >>

Handoff1(f) ==   \* thunk envelope in + child copy-out + envelope deinit: net rc+1
  /\ f = "f0a" /\ fst[f].pc = "h1"
  /\ rc' = rc + 1 /\ held' = [held EXCEPT !["t1"] = 1]
  /\ started' = [started EXCEPT !["t1"] = TRUE]
  /\ fst' = [fst EXCEPT ![f].pc = "h2"]
  /\ UNCHANGED chanVars /\ UNCHANGED destroyed /\ UNCHANGED notifVars
  /\ UNCHANGED << cur, tornDown >> /\ UNCHANGED cntVars

Handoff2(f) ==
  /\ f = "f0a" /\ fst[f].pc = "h2"
  /\ rc' = rc + 1 /\ held' = [held EXCEPT !["t2"] = 1]
  /\ started' = [started EXCEPT !["t2"] = TRUE]
  /\ fst' = [fst EXCEPT ![f].pc = "ready"]
  /\ cur' = [cur EXCEPT !["t0"] = Idle]
  /\ UNCHANGED chanVars /\ UNCHANGED destroyed /\ UNCHANGED notifVars
  /\ UNCHANGED tornDown /\ UNCHANGED cntVars

-----------------------------------------------------------------------------
(* §4 send, shared path.  Steps 1–8 are one atomic action (the mutex is    *)
(* held continuously); the build, the failure path, the push, and each     *)
(* ring are separate steps.  A send that parked retries from step 1 with   *)
(* nothing copied yet (pc "send_wake" re-enters the same entry actions).   *)

SendEntryOk(f) ==
  \/ /\ fst[f].pc = "ready" /\ ~SendsDone(f) /\ fst[f].preloadLeft = 0
     /\ promoted /\ started[Th(f)] /\ held[Th(f)] >= 1 /\ cur[Th(f)] = Idle
  \/ /\ fst[f].pc = "send_wake" /\ cur[Th(f)] = Idle

EntryKind(f) == IF fst[f].pc = "send_wake" THEN fst[f].kind
                ELSE IF fst[f].plainLeft > 0 THEN "plain" ELSE "self"

SendClosed(f) ==         \* §4 step 2: raise "send on closed channel"
  /\ SendEntryOk(f) /\ closed
  /\ LET k == EntryKind(f) IN
     fst' = [fst EXCEPT ![f].pc = "ready", ![f].kind = "none",
               ![f].plainLeft = @ - (IF k = "plain" THEN 1 ELSE 0),
               ![f].selfLeft  = @ - (IF k = "self"  THEN 1 ELSE 0)]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

SendFull(f) ==           \* §4 steps 3–4: register own notifier (dedup);
                         \* rendezvous: "full" = no unmatched receiver demand
  /\ SendEntryOk(f) /\ ~closed /\ Len(queue) + reservedV >= Bound
  /\ sendW' = sendW \union {Th(f)}
  /\ fst' = [fst EXCEPT ![f].pc = "send_preparked", ![f].kind = EntryKind(f)]
  /\ cur' = [cur EXCEPT ![Th(f)] = f]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

ParkSend(f) ==           \* §4 step 5: unlock -> park (the residual window)
  /\ fst[f].pc = "send_preparked"
  /\ fst' = [fst EXCEPT ![f].pc = "send_parked"]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

SendReserve(f) ==        \* §4 step 7: slot reservation (rendezvous: admission
                         \* against committed receiver demand)
  /\ SendEntryOk(f) /\ ~closed /\ Len(queue) + reservedV < Bound
  /\ reservedV' = reservedV + 1
  /\ fst' = [fst EXCEPT ![f].pc = "send_building", ![f].kind = EntryKind(f)]
  /\ cur' = [cur EXCEPT ![Th(f)] = f]
  /\ UNCHANGED << promoted, lq, queue, closed, recvW, sendW, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

BuildOk(f) ==            \* §4 step 9: deepCopy the payload into the envelope
  /\ fst[f].pc = "send_building"
  /\ rc' = rc + (IF fst[f].kind = "self" THEN 1 ELSE 0)   \* envelope stub (§1 rule 2)
  /\ built' = built + 1
  /\ fst' = [fst EXCEPT ![f].pc = "send_push", ![f].env = fst[f].kind]
  /\ UNCHANGED chanVars /\ UNCHANGED << held, destroyed >>
  /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED << pushed, receivedCnt, destroyDeinit, failDeinit >>

BuildFail(f) ==          \* §4 step 9 failure: partial copy took its stubs already
  /\ FailCopy /\ fst[f].pc = "send_building"
  /\ rc' = rc + (IF fst[f].kind = "self" THEN 1 ELSE 0)
  /\ built' = built + 1
  /\ fst' = [fst EXCEPT ![f].pc = "send_fail_locked",
               ![f].env = IF fst[f].kind = "self" THEN "failself" ELSE "failplain"]
  /\ UNCHANGED chanVars /\ UNCHANGED << held, destroyed >>
  /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED << pushed, receivedCnt, destroyDeinit, failDeinit >>

SendFailLocked(f) ==     \* failure path: reopen the slot, wake senders — and
                         \* receivers too when closed (they may be parked
                         \* waiting out this reservation, the full Finding-3
                         \* repair) or on a rendezvous channel (always: a
                         \* timed-out receiver draining this reservation per
                         \* §6 must be rung by the abort as well as the push
                         \* — timeouts themselves stay out of the model, but
                         \* the ring is unconditional protocol behavior)
  /\ fst[f].pc = "send_fail_locked"
  /\ reservedV' = reservedV - 1
  /\ LET alsoRecv == (EofPolicy = "wait_reserved" /\ closed) \/ Cap = 0 IN
       /\ fst' = [fst EXCEPT ![f].pc = "send_fail_ring",
                    ![f].snap = sendW \union (IF alsoRecv THEN recvW ELSE {}),
                    ![f].contPc = "send_fail_deinit"]
       /\ recvW' = IF alsoRecv THEN {} ELSE recvW
  /\ sendW' = {}
  /\ UNCHANGED << promoted, lq, queue, closed, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED cntVars

SendFailDeinit(f) ==     \* envelope.deinit() releases the partial copy's stubs
  /\ fst[f].pc = "send_fail_deinit"
  /\ rc' = rc - (IF fst[f].env = "failself" THEN 1 ELSE 0)
  /\ failDeinit' = failDeinit + 1
  /\ LET k == fst[f].kind IN
     fst' = [fst EXCEPT ![f].pc = "ready", ![f].env = "none", ![f].kind = "none",
               ![f].plainLeft = @ - (IF k = "plain" THEN 1 ELSE 0),
               ![f].selfLeft  = @ - (IF k = "self"  THEN 1 ELSE 0)]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED chanVars /\ UNCHANGED << held, destroyed >>
  /\ UNCHANGED notifVars /\ UNCHANGED << started, tornDown >>
  /\ UNCHANGED << built, pushed, receivedCnt, destroyDeinit >>

SendPush(f) ==           \* §4 steps 10–12: infallible push, snapshot receivers
  /\ fst[f].pc = "send_push"
  /\ reservedV' = reservedV - 1
  /\ queue' = Append(queue, fst[f].env)
  /\ pushed' = pushed + 1
  /\ fst' = [fst EXCEPT ![f].pc = "send_ring", ![f].env = "none",
                        ![f].snap = recvW, ![f].contPc = "send_done"]
  /\ recvW' = {}
  /\ UNCHANGED << promoted, lq, closed, sendW, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED << built, receivedCnt, destroyDeinit, failDeinit >>

SendDone(f) ==           \* primitive returns
  /\ fst[f].pc = "send_done"
  /\ LET k == fst[f].kind IN
     fst' = [fst EXCEPT ![f].pc = "ready", ![f].kind = "none",
               ![f].plainLeft = @ - (IF k = "plain" THEN 1 ELSE 0),
               ![f].selfLeft  = @ - (IF k = "self"  THEN 1 ELSE 0)]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

-----------------------------------------------------------------------------
(* §4 receive, shared path.                                                *)

RecvEntryOk(f) ==
  \/ /\ fst[f].pc = "ready" /\ fst[f].recvLeft > 0 /\ ~fst[f].eof
     /\ promoted /\ started[Th(f)] /\ held[Th(f)] >= 1 /\ cur[Th(f)] = Idle
  \/ /\ fst[f].pc = "recv_wake" /\ cur[Th(f)] = Idle

RecvPop(f) ==            \* steps 2–4: pop, snapshot senders (a slot opened).
                         \* Normative ("at_pop", Finding 5 repair): a pop by
                         \* a token-holding receiver withdraws its demand in
                         \* this same mutex section — the receiver is
                         \* satisfied the instant it owns an envelope, so its
                         \* token must stop admitting sends before the ring
                         \* below can wake one. The rejected "at_deinit"
                         \* keeps the token counted through the unlocked
                         \* copy-out (rv2_popwindow is its witness). On the
                         \* copy-failure path the token stays withdrawn
                         \* either way: the raise is a terminal exit, and the
                         \* re-queued envelope falls under §6's abnormal-exit
                         \* rule (collectable by whichever receiver comes).
  /\ RecvEntryOk(f) /\ queue # << >>
  /\ LET withdraw == RvPopWithdraw = "at_pop" /\ fst[f].hasTok IN
       /\ rvDemand' = rvDemand - (IF withdraw THEN 1 ELSE 0)
       /\ fst' = [fst EXCEPT ![f].pc = "recv_ring", ![f].env = Head(queue),
                             ![f].snap = sendW, ![f].contPc = "recv_copyout",
                             ![f].hasTok = IF withdraw THEN FALSE ELSE fst[f].hasTok]
  /\ queue' = Tail(queue)
  /\ sendW' = {}
  /\ cur' = [cur EXCEPT ![Th(f)] = f]
  /\ UNCHANGED << promoted, lq, reservedV, closed, recvW >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

RecvEOF(f) ==            \* step 6: drained and closed -> (eof-object); a
                         \* terminal exit releases the demand token
  /\ RecvEntryOk(f) /\ queue = << >> /\ closed
  /\ EofPolicy = "asis" \/ reservedV = 0     \* repair: EOF outwaits reservations
  /\ rvDemand' = rvDemand - (IF fst[f].hasTok THEN 1 ELSE 0)
  /\ fst' = [fst EXCEPT ![f].pc = "ready", ![f].eof = TRUE,
                        ![f].hasTok = FALSE]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, sendW >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

RecvRegister(f) ==       \* step 7: register own notifier (dedup). Rendezvous
                         \* (Cap = 0): the park decision is the commitment
                         \* point — acquire the demand token exactly once per
                         \* logical wait (idempotent across wake-and-repark,
                         \* which models the runtime's yield_retry
                         \* re-execution), and, under the normative RvRing =
                         \* "ring", snapshot-and-ring send_waiters: new
                         \* demand is a send-side event, exactly like a freed
                         \* slot. The rejected "noring" variant (Finding 4)
                         \* grows demand silently.
  /\ RecvEntryOk(f) /\ queue = << >>
  /\ ~closed \/ (EofPolicy # "asis" /\ reservedV > 0)
  /\ recvW' = recvW \union {Th(f)}
  /\ IF Cap = 0 /\ ~fst[f].hasTok
       THEN /\ rvDemand' = rvDemand + 1
            /\ IF RvRing = "ring"
                 THEN /\ fst' = [fst EXCEPT ![f].pc = "recv_demand_ring",
                                   ![f].hasTok = TRUE, ![f].snap = sendW,
                                   ![f].contPc = "recv_preparked"]
                      /\ sendW' = {}
                 ELSE /\ fst' = [fst EXCEPT ![f].pc = "recv_preparked",
                                   ![f].hasTok = TRUE]
                      /\ sendW' = sendW
       ELSE /\ rvDemand' = rvDemand
            /\ fst' = [fst EXCEPT ![f].pc = "recv_preparked"]
            /\ sendW' = sendW
  /\ cur' = [cur EXCEPT ![Th(f)] = f]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

ParkRecv(f) ==           \* step 8: unlock -> park
  /\ fst[f].pc = "recv_preparked"
  /\ fst' = [fst EXCEPT ![f].pc = "recv_parked"]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

RecvCopyOut(f) ==        \* deepCopy into own heap: a self message adds a stub
  /\ fst[f].pc = "recv_copyout"
  /\ rc' = rc + (IF fst[f].env = "self" THEN 1 ELSE 0)
  /\ held' = [held EXCEPT ![Th(f)] = @ + (IF fst[f].env = "self" THEN 1 ELSE 0)]
  /\ fst' = [fst EXCEPT ![f].pc = "recv_deinit"]
  /\ UNCHANGED chanVars /\ UNCHANGED destroyed /\ UNCHANGED notifVars
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

RecvCopyFail(f) ==       \* amended §4: receive-side copy failure re-queues the
                         \* envelope at the head (FIFO preserved, stubs intact)
                         \* and rings recv_waiters — receivers may have parked
                         \* while the queue was empty during this pop window
  /\ RecvFail /\ fst[f].pc = "recv_copyout" /\ fst[f].failLeft > 0
  /\ queue' = << fst[f].env >> \o queue
  /\ fst' = [fst EXCEPT ![f].pc = "recv_fail_ring", ![f].env = "none",
                        ![f].snap = recvW, ![f].contPc = "recv_fail_done"]
  /\ recvW' = {}
  /\ UNCHANGED << promoted, lq, reservedV, closed, sendW, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars /\ UNCHANGED schedVars
  /\ UNCHANGED cntVars

RecvFailDone(f) ==       \* the receive raises; the worker catches and retries.
                         \* Failures are bounded (failLeft): a *persistently*
                         \* failing receiver is an effectively-dead consumer,
                         \* and parked senders behind it are the KEP's
                         \* documented weakened-deadlock hang, not a bug the
                         \* re-queue rule can or should repair.
  /\ fst[f].pc = "recv_fail_done"
  \* The raise is a terminal exit of this wait: the token releases; the
  \* worker's retry re-acquires one. A handoff already committed against
  \* the released token stays queued for whichever receiver comes next
  \* (receivers are interchangeable; §6 rendezvous, abnormal-exit rule).
  /\ rvDemand' = rvDemand - (IF fst[f].hasTok THEN 1 ELSE 0)
  /\ fst' = [fst EXCEPT ![f].pc = "ready", ![f].failLeft = @ - 1,
                        ![f].hasTok = FALSE]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, sendW >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

RecvDeinit(f) ==         \* envelope.deinit(): the envelope's stub is released;
                         \* value in hand = terminal exit, token released
  /\ fst[f].pc = "recv_deinit"
  /\ rc' = rc - (IF fst[f].env = "self" THEN 1 ELSE 0)
  /\ receivedCnt' = receivedCnt + 1
  /\ rvDemand' = rvDemand - (IF fst[f].hasTok THEN 1 ELSE 0)
  /\ fst' = [fst EXCEPT ![f].pc = "ready", ![f].env = "none",
                        ![f].recvLeft = @ - 1, ![f].hasTok = FALSE]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, sendW >>
  /\ UNCHANGED << held, destroyed >>
  /\ UNCHANGED notifVars /\ UNCHANGED << started, tornDown >>
  /\ UNCHANGED << built, pushed, destroyDeinit, failDeinit >>

-----------------------------------------------------------------------------
(* §6 receiver abandonment — the timeout withdraw, modeled as a bounded    *)
(* spontaneous decision (timers are scoped out; the timer pop that         *)
(* triggers it in the runtime is irrelevant to the protocol content).      *)
(* The enabling condition IS the amended protocol: the withdraw happens    *)
(* only with the queue empty (a committed handoff outranks the timer —     *)
(* delivery-wins; with a value present the fiber's RecvPop is the enabled  *)
(* action instead) and, under the normative "atomic" variant, with no      *)
(* reservation in flight (the drain rule: an admitted send must land or    *)
(* abort first — its push re-enables RecvPop, its abort re-enables this).  *)
(* All three checks and the decrement are one mutex section, which is      *)
(* exactly what Finding 6 requires: the rejected "naive" variant skips     *)
(* the reservation check, letting a sender reserve against the token       *)
(* after the receiver's empty-queue observation and push into demand       *)
(* that no longer exists. The abandoning fiber's recv_waiters              *)
(* registration goes stale — a later ring is one harmless spurious sweep   *)
(* (§7), faithful to the runtime.                                          *)

Abandon(f) ==
  /\ RvAbandon # "none" /\ fst[f].abandonLeft > 0
  /\ fst[f].pc = "recv_parked" /\ fst[f].hasTok
  /\ cur[Th(f)] = Idle
  /\ queue = << >>
  /\ RvAbandon = "naive" \/ reservedV = 0
  /\ rvDemand' = rvDemand - 1
  /\ fst' = [fst EXCEPT ![f].pc = "ready", ![f].hasTok = FALSE,
               ![f].recvLeft = @ - 1, ![f].abandonLeft = @ - 1]
  /\ UNCHANGED << promoted, lq, queue, reservedV, closed, recvW, sendW >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

-----------------------------------------------------------------------------
(* §6 close.                                                               *)

CloseLock(f) ==          \* steps 1–5: set closed, snapshot BOTH lists
  /\ Closer(f) /\ fst[f].closeLeft = 1 /\ fst[f].pc = "ready" /\ SendsDone(f)
  /\ promoted /\ held[Th(f)] >= 1 /\ cur[Th(f)] = Idle /\ ~closed
  /\ closed' = TRUE
  /\ fst' = [fst EXCEPT ![f].pc = "close_ring", ![f].snap = recvW \union sendW,
                        ![f].contPc = "close_done", ![f].closeLeft = 0]
  /\ recvW' = {} /\ sendW' = {}
  /\ cur' = [cur EXCEPT ![Th(f)] = f]
  /\ UNCHANGED << promoted, lq, queue, reservedV, rvDemand >>
  /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

CloseDone(f) ==
  /\ fst[f].pc = "close_done"
  /\ fst' = [fst EXCEPT ![f].pc = "ready"]
  /\ cur' = [cur EXCEPT ![Th(f)] = Idle]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED notifVars
  /\ UNCHANGED << started, tornDown >> /\ UNCHANGED cntVars

-----------------------------------------------------------------------------
(* §5 scheduler: the normative consume protocol.                           *)
(*   while (wake_pending.swap(false)) sweep;  then block in poll — a       *)
(*   notify after the last swap still rang the fd, which poll observes.    *)
(* PollWake is enabled whenever the fd is pending: the kqueue trigger /    *)
(* eventfd counter stays armed until retrieved.                            *)

SweepFlip(g, t) ==
  IF /\ Th(g) = t /\ Parked(g)
     /\ (SweepPolicy = "flip_all" \/ ReadyFor(g))
    THEN [fst[g] EXCEPT !.pc = IF fst[g].pc = "recv_parked"
                                 THEN "recv_wake" ELSE "send_wake"]
    ELSE fst[g]

SwapSweep(t) ==
  /\ cur[t] = Idle /\ wakeP[t]
  /\ wakeP' = [wakeP EXCEPT ![t] = FALSE]
  /\ fst' = [g \in Fibers |-> SweepFlip(g, t)]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED fdR
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

PollWake(t) ==
  /\ cur[t] = Idle /\ fdR[t]
  /\ fdR' = [fdR EXCEPT ![t] = FALSE]
  /\ fst' = [g \in Fibers |-> SweepFlip(g, t)]
  /\ UNCHANGED chanVars /\ UNCHANGED rcVars /\ UNCHANGED wakeP
  /\ UNCHANGED schedVars /\ UNCHANGED cntVars

-----------------------------------------------------------------------------
(* §7 thread teardown: when a thread's fibers are all done, its heap is    *)
(* collected — every stub it holds releases its refcount; zero destroys    *)
(* (drain + deinit queued envelopes, clear waiter lists).                  *)

Teardown(t) ==
  /\ promoted /\ started[t] /\ ~tornDown[t] /\ cur[t] = Idle
  /\ \A f \in FibersOf(t) : FiberDone(f)
  /\ tornDown' = [tornDown EXCEPT ![t] = TRUE]
  /\ rc' = rc - held[t]
  /\ held' = [held EXCEPT ![t] = 0]
  /\ IF rc - held[t] = 0 /\ ~destroyed
       THEN /\ destroyed' = TRUE
            /\ destroyDeinit' = destroyDeinit + Len(queue)
            /\ queue' = << >> /\ recvW' = {} /\ sendW' = {}
       ELSE /\ UNCHANGED << destroyed, destroyDeinit, queue, recvW, sendW >>
  /\ UNCHANGED << promoted, lq, reservedV, closed, rvDemand >>
  /\ UNCHANGED notifVars /\ UNCHANGED << cur, started >> /\ UNCHANGED fst
  /\ UNCHANGED << built, pushed, receivedCnt, failDeinit >>

-----------------------------------------------------------------------------

FiberNext(f) ==
  \/ LocalPreloadSend(f) \/ LocalRecvPop(f)
  \/ LocalRecvParkA(f) \/ LocalRecvParkB(f)
  \/ Promote(f) \/ Handoff1(f) \/ Handoff2(f)
  \/ SendClosed(f) \/ SendFull(f) \/ ParkSend(f) \/ SendReserve(f)
  \/ BuildOk(f) \/ BuildFail(f)
  \/ SendFailLocked(f) \/ SendFailDeinit(f)
  \/ SendPush(f) \/ SendDone(f)
  \/ RecvPop(f) \/ RecvEOF(f) \/ RecvRegister(f) \/ ParkRecv(f)
  \/ RecvCopyOut(f) \/ RecvCopyFail(f) \/ RecvFailDone(f) \/ RecvDeinit(f)
  \/ Abandon(f)
  \/ CloseLock(f) \/ CloseDone(f)
  \/ RingFlag(f) \/ RingFd(f) \/ RingDone(f)

ThreadNext(t) == SwapSweep(t) \/ PollWake(t) \/ Teardown(t)

DoneStutter == AllDone /\ AllTorn /\ UNCHANGED vars

Next ==
  \/ \E f \in Fibers : FiberNext(f)
  \/ \E t \in Threads : ThreadNext(t)
  \/ DoneStutter

Spec == /\ Init /\ [][Next]_vars
        /\ \A f \in Fibers : WF_vars(FiberNext(f))
        /\ \A t \in Threads : WF_vars(ThreadNext(t))

-----------------------------------------------------------------------------
(* Properties — the six pre-registered checks from                         *)
(* research/open-problems.md P2, plus bookkeeping invariants.              *)

TypeOK ==
  /\ promoted \in BOOLEAN /\ closed \in BOOLEAN /\ destroyed \in BOOLEAN
  /\ lq \in Seq(Msg) /\ queue \in Seq(Msg)
  /\ reservedV \in Nat /\ rc \in Nat /\ rvDemand \in Nat
  /\ held \in [Threads -> Nat]
  /\ recvW \subseteq Threads /\ sendW \subseteq Threads
  /\ wakeP \in [Threads -> BOOLEAN] /\ fdR \in [Threads -> BOOLEAN]
  /\ cur \in [Threads -> Fibers \union {Idle}]
  /\ started \in [Threads -> BOOLEAN] /\ tornDown \in [Threads -> BOOLEAN]
  /\ \A f \in Fibers :
       /\ fst[f].pc \in PCs /\ fst[f].env \in EnvVals
       /\ fst[f].kind \in Msg \union {"none"}
       /\ fst[f].snap \subseteq Threads
       /\ fst[f].rt \in Threads \union {"none"}
       /\ fst[f].plainLeft \in Nat /\ fst[f].selfLeft \in Nat
       /\ fst[f].recvLeft \in Nat /\ fst[f].failLeft \in Nat
       /\ fst[f].hasTok \in BOOLEAN /\ fst[f].abandonLeft \in Nat
  /\ built \in Nat /\ pushed \in Nat /\ receivedCnt \in Nat
  /\ destroyDeinit \in Nat /\ failDeinit \in Nat

(* P-1: refcount >= 0 — strengthened to exact accounting: every counted    *)
(* reference is a thread-heap stub, an envelope stub in the queue, or an   *)
(* envelope stub in a sender's/receiver's hands.                           *)
RcAccounting ==
  /\ ~promoted => rc = 0
  /\ promoted /\ ~destroyed => rc = SumHeld + SelfInQueue + SelfInFlight
  /\ destroyed => rc = 0

(* P-2: destroy exactly once, and only when nothing references the         *)
(* channel; after destroy no stub, envelope, or waiter entry survives.     *)
DestroyedClean ==
  destroyed => /\ rc = 0 /\ SumHeld = 0 /\ SelfInFlight = 0
               /\ queue = << >> /\ recvW = {} /\ sendW = {}

(* P-3: every built envelope is in exactly one place: a sender's or        *)
(* receiver's hands, the queue, or one of the three deinit fates.          *)
EnvelopeAccounting ==
  built = InFlightEnvCnt + Len(queue) + receivedCnt + destroyDeinit + failDeinit

(* P-4 support: a reservation is held exactly while a send is between      *)
(* step 7 and step 11 (or the failure path's release).                     *)
ReservedAccounting ==
  reservedV = Cardinality({f \in Fibers :
                 fst[f].pc \in {"send_building", "send_push", "send_fail_locked"}})

(* Rendezvous token accounting (kaappi#1601): the demand counter is        *)
(* exactly the number of fibers holding a token — acquire is idempotent    *)
(* per logical wait, and every terminal exit (value, EOF, raise) releases. *)
(* On a Cap > 0 channel no token is ever acquired.                         *)
RvTokenAccounting ==
  /\ rvDemand = Cardinality({f \in Fibers : fst[f].hasTok})
  /\ Cap > 0 => rvDemand = 0

(* Parked or mid-operation fibers sit on a rooted stub (§2: only locally   *)
(* owned stubs may be used; the waiting fiber roots it).                   *)
ParkedImpliesHeld ==
  \A f \in Fibers :
    fst[f].pc \in (PCs \ {"ready", "lrecv_preparked", "lrecv_parked"})
      => held[Th(f)] >= 1 \/ fst[f].pc \in {"h1", "h2"}

(* The only way the channel outlives full teardown is the documented       *)
(* refcount cycle: a self-stub still queued (§1 known limitation).         *)
CycleLeakOnly ==
  (AllTorn /\ ~destroyed) => SelfInQueue > 0

(* strand scenario only (checked via cfg): with receive-until-EOF workers  *)
(* and a close, no pushed task may be thrown away at destroy — §8's        *)
(* "tasks submitted before shutdown all run".                              *)
NoAbandonedTask == destroyDeinit = 0

(* P-6: no lost wakeup — the run always ends with every fiber done and     *)
(* every heap torn down (close ends the streams; a stranded parked fiber   *)
(* would make this false and also shows up as a TLC deadlock).             *)
Termination == <>[](AllDone /\ AllTorn)

=============================================================================
