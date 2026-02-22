# wxErlang_raft

wxErlang re-implementation of raftscope as seen on raft.github.io

# raftscope_wx (wxErlang RaftScope-style simulator)

This is a self-contained Erlang/OTP + wxErlang desktop app that simulates Raft and visualizes:
- server roles (follower/candidate/leader/stopped)
- elections and heartbeats
- in-flight RPC messages as moving dots
- per-server logs (term-colored blocks) and commit index

It is **inspired by** the RaftScope visualization, but implemented as a native wxErlang app.

## Requirements
- Erlang/OTP with wxErlang enabled (most official builds include it)
- rebar3

## Build
```bash
rebar3 compile
```

## Run
```bash
rebar3 shell
```

Close the window to stop the GUI process; the shell will remain open.

## Controls
- **Run/Pause**: start/stop the simulation timer
- **Step**: advance one tick when paused
- **Client req → leader**: append a dummy entry to current leader's log (if any)
- **Timeout**: force a selected server to start an election immediately
- **Stop / Resume / Restart**: change selected server's liveness
- **Align timers / Spread timers**: mimic RaftScope's "encourage split vote" tools
- **Heal all links**: restore communication on every link (clears all net cuts)
- **Speed** slider: simulation speed multiplier

Click a server node to select it.

## Network splits
- **Click a link (line) between two servers** to toggle communication on that link (cut/heal).
  Cut links are drawn in red with an "X".

## What this simulator implements
The goal is to be faithful to the **core Raft protocol** (election, replication, commitment) while keeping
the GUI/behavior easy to understand.

Implemented (high level):
- Leader election with randomized timeouts (`RequestVote`)
- Heartbeats + log replication (`AppendEntries`)
- Log conflict resolution (truncate/delete conflicting suffix, then append)
- Leader commit index advancement by majority, with the Raft safety rule:
  only advance `commit_index` to `N` if `log[N].term == currentTerm`
- A no-op entry is appended when a server becomes leader (helps a new leader commit an entry in its own term)

Network model:
- Cutting/healing a link only affects message delivery on that edge.
- Cutting links **does not change cluster membership**; quorum is still computed over the configured cluster size.

## What is simplified or missing vs the full Raft spec
This is a teaching/simulation tool, not a production Raft library. Notably:

- **Persistence & crash semantics**: the Raft paper assumes `currentTerm`, `votedFor`, and the log are persisted.
  In this simulator, **Stop/Resume are liveness toggles** and do not model disk persistence or true
  crash/reboot behavior.
- **State machine application & client semantics**: the simulator tracks `commit_index`, but it does not model a
  real state machine (`lastApplied`), client command IDs/deduplication, or linearizable read-only queries.
- **Snapshots / log compaction**: no `InstallSnapshot` RPC and no compaction.
- **Membership changes**: no joint-consensus configuration changes (cluster size is fixed).
- **Timing / delivery realism**: the simulation is tick-based; link cuts drop messages on that edge.
  It does not aim to reproduce real-world latency distributions or arbitrary reordering.
- **Performance optimizations / extensions**: no conflict-term/index “hints” on AppendEntries failure,
  no batching/pipelining, and no extras like pre-vote or leadership transfer.
