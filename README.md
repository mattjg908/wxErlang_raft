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
