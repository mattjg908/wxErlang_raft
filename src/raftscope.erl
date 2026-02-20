%% raftscope.erl
%% Erlang port of RaftScope's raft.js "model" (simulation, not the UI).

-module(raftscope).

-include_lib("raftscope_wx/include/raftscope.hrl").

-export([
    new/0,
    tick/2,
    tick_n/3,
    update/1,
    leader/1,

    stop/2, resume/2, restart/2, resume_all/1,
    timeout/2,
    client_request/2,

    spread_timers/1,
    align_timers/1
]).

%% --- Public API -------------------------------------------------------------

new() ->
    seed_rand(),
    Servers =
        [server(I, peers(I)) || I <- lists:seq(1, ?NUM_SERVERS)],
    #model{time = 0, servers = Servers, messages = []}.

tick(Model0, DeltaMicros) when is_integer(DeltaMicros), DeltaMicros >= 0 ->
    Model1 = Model0#model{time = Model0#model.time + DeltaMicros},
    update(Model1).

tick_n(Model0, DeltaMicros, N) when N >= 0 ->
    lists:foldl(fun(_, M) -> tick(M, DeltaMicros) end, Model0, lists:seq(1, N)).

leader(#model{servers = Servers}) ->
    %% Return {LeaderId, Term} of highest-term leader, or none.
    lists:foldl(
      fun(S, Acc) ->
          case S#server.state of
              leader ->
                  case Acc of
                      none -> {S#server.id, S#server.term};
                      {_Id, Term0} when S#server.term > Term0 ->
                          {S#server.id, S#server.term};
                      _ ->
                          Acc
                  end;
              _ ->
                  Acc
          end
      end,
      none,
      Servers).

stop(Model, ServerId) ->
    map_server(Model, ServerId, fun(M, S) ->
        {S#server{state = stopped, election_alarm = 0}, M}
    end).

resume(Model, ServerId) ->
    map_server(Model, ServerId, fun(M, S) ->
        {S#server{state = follower, election_alarm = make_election_alarm(M#model.time)}, M}
    end).

restart(Model0, ServerId) ->
    Model1 = stop(Model0, ServerId),
    resume(Model1, ServerId).

resume_all(Model0) ->
    lists:foldl(fun(S, M) -> resume(M, S#server.id) end, Model0, Model0#model.servers).

timeout(Model0, ServerId) ->
    %% Like raft.js: set election_alarm=0 and immediately start an election.
    map_server(Model0, ServerId, fun(M, S0) ->
        S1 = S0#server{state = follower, election_alarm = 0},
        start_new_election(M, S1)
    end).

client_request(Model, ServerId) ->
    map_server(Model, ServerId, fun(M, S) ->
        case S#server.state of
            leader ->
                Entry = #entry{term = S#server.term, value = v},
                {S#server{log = S#server.log ++ [Entry]}, M};
            _ ->
                {S, M}
        end
    end).

spread_timers(Model0) ->
    Time = Model0#model.time,
    Timers = lists:sort([S#server.election_alarm ||
                         S <- Model0#model.servers,
                         S#server.election_alarm > Time,
                         S#server.election_alarm < ?INF]),
    case Timers of
        [T0, T1 | _] when (T1 - T0) < ?MAX_RPC_LATENCY ->
            if
                T0 > Time + ?MAX_RPC_LATENCY ->
                    %% Move the earliest timer forward by MAX_RPC_LATENCY
                    adjust_alarm(Model0, fun(Alarm) -> Alarm =:= T0 end, fun(A) -> A - ?MAX_RPC_LATENCY end);
                true ->
                    %% Push any timers within (T0, T0 + MAX_RPC_LATENCY) backward
                    adjust_alarm(Model0,
                                 fun(Alarm) -> Alarm > T0 andalso Alarm < T0 + ?MAX_RPC_LATENCY end,
                                 fun(A) -> A + ?MAX_RPC_LATENCY end)
            end;
        _ ->
            Model0
    end.

align_timers(Model0) ->
    Model1 = spread_timers(Model0),
    Time = Model1#model.time,
    Timers = lists:sort([S#server.election_alarm ||
                         S <- Model1#model.servers,
                         S#server.election_alarm > Time,
                         S#server.election_alarm < ?INF]),
    case Timers of
        [T0, T1 | _] ->
            %% Set the 2nd timer equal to the 1st (encourage split vote)
            adjust_alarm(Model1, fun(Alarm) -> Alarm =:= T1 end, fun(_A) -> T0 end);
        _ ->
            Model1
    end.

%% --- Core simulation update -------------------------------------------------

update(Model0 = #model{time = Time, servers = Servers0}) ->
    %% 1) Apply "rules" per server (may enqueue outbound messages)
    {Servers1, Model1} =
        lists:mapfoldl(
          fun(S, MAcc) ->
              {S2, MAcc2} = apply_rules(MAcc, S),
              {S2, MAcc2}
          end,
          Model0,
          Servers0),

    Model2 = Model1#model{servers = Servers1},

    %% 2) Deliver messages whose recv_time <= now
    %%
    %% IMPORTANT: we must deliver from the *current* message queue after
    %% apply_rules/2 has had a chance to enqueue outbound RPCs. This matches
    %% the original raftscope sequencing (rules first, then message delivery).
    Msgs1 = Model2#model.messages,
    {DeliverRev, KeepRev} =
        lists:foldl(
          fun(Msg, {Del, Keep}) ->
              Recv = maps:get(recv_time, Msg),
              if
                  Recv =< Time -> {[Msg | Del], Keep};
                  Recv < ?INF  -> {Del, [Msg | Keep]};
                  true         -> {Del, Keep}
              end
          end,
          {[], []},
          Msgs1),

    Deliver = lists:reverse(DeliverRev),
    Keep = lists:reverse(KeepRev),

    Model3 = Model2#model{messages = Keep},

    %% 3) Deliver each message to its target server (may enqueue replies)
    lists:foldl(fun deliver_one/2, Model3, Deliver).

%% lists:foldl/3 calls Fun(Elem, Acc) -> Acc.
%% Here Elem is a message map, Acc is the model.
deliver_one(Msg, M) ->
    To = maps:get(to, Msg),
    map_server(M, To, fun(MAcc, S) -> handle_message(MAcc, S, Msg) end).

apply_rules(M0, S0) ->
    {S1, M1} = start_new_election(M0, S0),
    {S2, M2} = become_leader(M1, S1),
    {S3, M3} = advance_commit_index(M2, S2),
    lists:foldl(
      fun(Peer, {SAcc, MAcc}) ->
          {SAcc1, MAcc1} = send_request_vote(MAcc, SAcc, Peer),
          {SAcc2, MAcc2} = send_append_entries(MAcc1, SAcc1, Peer),
          {SAcc2, MAcc2}
      end,
      {S3, M3},
      S3#server.peers).

%% --- Rules ------------------------------------------------------------------

start_new_election(M = #model{time = Time}, S) ->
    case (S#server.state =:= follower orelse S#server.state =:= candidate)
         andalso (S#server.election_alarm =< Time) of
        true ->
            Peers = S#server.peers,
            S1 = S#server{
                election_alarm = make_election_alarm(Time),
                term = S#server.term + 1,
                voted_for = S#server.id,
                state = candidate,
                vote_granted = make_map(Peers, false),
                match_index = make_map(Peers, 0),
                next_index = make_map(Peers, 1),
                rpc_due = make_map(Peers, 0),
                heartbeat_due = make_map(Peers, 0)
            },
            {S1, M};
        false ->
            {S, M}
    end.

become_leader(M, S) ->
    Votes = count_true(maps:values(S#server.vote_granted)) + 1,
    case S#server.state =:= candidate andalso Votes > (?NUM_SERVERS div 2) of
        true ->
            LogLen = length(S#server.log),
            Peers = S#server.peers,
            S1 = S#server{
                state = leader,
                next_index = make_map(Peers, LogLen + 1),
                rpc_due = make_map(Peers, ?INF),
                heartbeat_due = make_map(Peers, 0),
                election_alarm = ?INF
            },
            {S1, M};
        false ->
            {S, M}
    end.

advance_commit_index(M, S = #server{state = leader}) ->
    LogLen = length(S#server.log),
    Match = maps:values(S#server.match_index) ++ [LogLen],
    Sorted = lists:sort(Match),
    NthIndex = (?NUM_SERVERS div 2) + 1,
    N = case length(Sorted) >= NthIndex of
            true  -> lists:nth(NthIndex, Sorted);
            false -> 0
        end,
    case log_term(S#server.log, N) =:= S#server.term of
        true ->
            {S#server{commit_index = erlang:max(S#server.commit_index, N)}, M};
        false ->
            {S, M}
    end;
advance_commit_index(M, S) ->
    {S, M}.

send_request_vote(M = #model{time = Time}, S, Peer) ->
    case S#server.state =:= candidate andalso maps:get(Peer, S#server.rpc_due) =< Time of
        true ->
            RpcDue2 = maps:put(Peer, Time + ?RPC_TIMEOUT, S#server.rpc_due),
            LogLen = length(S#server.log),
            Req = #{
                from => S#server.id,
                to => Peer,
                type => request_vote,
                direction => request,
                term => S#server.term,
                last_log_term => log_term(S#server.log, LogLen),
                last_log_index => LogLen
            },
            M1 = send_message(M, Req),
            {S#server{rpc_due = RpcDue2}, M1};
        false ->
            {S, M}
    end.

send_append_entries(M = #model{time = Time}, S, Peer) ->
    case S#server.state =:= leader of
        false ->
            {S, M};
        true ->
            HeartbeatDue = maps:get(Peer, S#server.heartbeat_due),
            NextIndex = maps:get(Peer, S#server.next_index),
            RpcDue = maps:get(Peer, S#server.rpc_due),
            LogLen = length(S#server.log),

            ShouldSend =
                (HeartbeatDue =< Time) orelse
                ((NextIndex =< LogLen) andalso (RpcDue =< Time)),

            case ShouldSend of
                false ->
                    {S, M};
                true ->
                    PrevIndex = NextIndex - 1,
                    LastIndex0 = erlang:min(PrevIndex + ?BATCH_SIZE, LogLen),
                    MatchIndex = maps:get(Peer, S#server.match_index),
                    LastIndex =
                        case (MatchIndex + 1) < NextIndex of
                            true  -> PrevIndex;   %% heartbeat only
                            false -> LastIndex0
                        end,
                    Entries = log_slice(S#server.log, PrevIndex, LastIndex),
                    CommitForPeer = erlang:min(S#server.commit_index, LastIndex),

                    Req = #{
                        from => S#server.id,
                        to => Peer,
                        type => append_entries,
                        direction => request,
                        term => S#server.term,
                        prev_index => PrevIndex,
                        prev_term => log_term(S#server.log, PrevIndex),
                        entries => Entries,
                        commit_index => CommitForPeer
                    },

                    M1 = send_message(M, Req),
                    RpcDue2 = maps:put(Peer, Time + ?RPC_TIMEOUT, S#server.rpc_due),
                    HbDue2 = maps:put(Peer, Time + (?ELECTION_TIMEOUT div 2), S#server.heartbeat_due),
                    {S#server{rpc_due = RpcDue2, heartbeat_due = HbDue2}, M1}
            end
    end.

%% --- Message handlers -------------------------------------------------------

handle_message(M0, S0, Msg) ->
    case S0#server.state of
        stopped ->
            {S0, M0};
        _ ->
            Type = maps:get(type, Msg),
            Dir  = maps:get(direction, Msg),
            case {Type, Dir} of
                {request_vote, request} ->
                    handle_request_vote_request(M0, S0, Msg);
                {request_vote, reply} ->
                    handle_request_vote_reply(M0, S0, Msg);
                {append_entries, request} ->
                    handle_append_entries_request(M0, S0, Msg);
                {append_entries, reply} ->
                    handle_append_entries_reply(M0, S0, Msg);
                _ ->
                    {S0, M0}
            end
    end.

handle_request_vote_request(M0, S0, Req) ->
    {S1, M1} = maybe_step_down(M0, S0, maps:get(term, Req)),
    Granted =
        case S1#server.term =:= maps:get(term, Req) of
            false -> false;
            true ->
                From = maps:get(from, Req),
                VotedOk = (S1#server.voted_for =:= undefined) orelse (S1#server.voted_for =:= From),
                LogLen = length(S1#server.log),
                MyLastTerm = log_term(S1#server.log, LogLen),
                MyLastIdx = LogLen,
                ReqLastTerm = maps:get(last_log_term, Req),
                ReqLastIdx  = maps:get(last_log_index, Req),
                UpToDate = (ReqLastTerm > MyLastTerm) orelse
                           (ReqLastTerm =:= MyLastTerm andalso ReqLastIdx >= MyLastIdx),
                VotedOk andalso UpToDate
        end,

    S2 =
        case Granted of
            true ->
                S1#server{
                    voted_for = maps:get(from, Req),
                    election_alarm = make_election_alarm(M1#model.time)
                };
            false ->
                S1
        end,

    Reply = #{
        from => maps:get(to, Req),
        to => maps:get(from, Req),
        type => request_vote,
        direction => reply,
        term => S2#server.term,
        granted => Granted
    },
    M2 = send_message(M1, Reply),
    {S2, M2}.

handle_request_vote_reply(M0, S0, Reply) ->
    {S1, M1} = maybe_step_down(M0, S0, maps:get(term, Reply)),
    case (S1#server.state =:= candidate) andalso (S1#server.term =:= maps:get(term, Reply)) of
        false ->
            {S1, M1};
        true ->
            From = maps:get(from, Reply),
            RpcDue2 = maps:put(From, ?INF, S1#server.rpc_due),
            Vote2   = maps:put(From, maps:get(granted, Reply), S1#server.vote_granted),
            {S1#server{rpc_due = RpcDue2, vote_granted = Vote2}, M1}
    end.

handle_append_entries_request(M0, S0, Req) ->
    {S1, M1} = maybe_step_down(M0, S0, maps:get(term, Req)),
    TermOk = (S1#server.term =:= maps:get(term, Req)),
    {Success, MatchIndex, S2} =
        case TermOk of
            false ->
                {false, 0, S1};
            true ->
                %% Become follower, reset election alarm
                Sx = S1#server{state = follower, election_alarm = make_election_alarm(M1#model.time)},
                PrevIndex = maps:get(prev_index, Req),
                PrevTerm  = maps:get(prev_term, Req),
                LogOk =
                    (PrevIndex =:= 0) orelse
                    (PrevIndex =< length(Sx#server.log) andalso log_term(Sx#server.log, PrevIndex) =:= PrevTerm),
                case LogOk of
                    false ->
                        {false, 0, Sx};
                    true ->
                        Entries = maps:get(entries, Req),
                        {Log2, LastIdx} = append_entries(Sx#server.log, PrevIndex, Entries),
                        Commit2 = erlang:max(Sx#server.commit_index, maps:get(commit_index, Req)),
                        {true, LastIdx, Sx#server{log = Log2, commit_index = Commit2}}
                end
        end,

    Reply = #{
        from => maps:get(to, Req),
        to => maps:get(from, Req),
        type => append_entries,
        direction => reply,
        term => S2#server.term,
        success => Success,
        match_index => MatchIndex
    },
    M2 = send_message(M1, Reply),
    {S2, M2}.

handle_append_entries_reply(M0, S0, Reply) ->
    {S1, M1} = maybe_step_down(M0, S0, maps:get(term, Reply)),
    case (S1#server.state =:= leader) andalso (S1#server.term =:= maps:get(term, Reply)) of
        false ->
            {S1, M1};
        true ->
            From = maps:get(from, Reply),
            RpcDue2 = maps:put(From, 0, S1#server.rpc_due),
            case maps:get(success, Reply) of
                true ->
                    MI = maps:get(match_index, Reply),
                    Match2 = maps:put(From, erlang:max(maps:get(From, S1#server.match_index), MI), S1#server.match_index),
                    Next2  = maps:put(From, MI + 1, S1#server.next_index),
                    {S1#server{match_index = Match2, next_index = Next2, rpc_due = RpcDue2}, M1};
                false ->
                    NextOld = maps:get(From, S1#server.next_index),
                    NextNew = erlang:max(1, NextOld - 1),
                    Next2   = maps:put(From, NextNew, S1#server.next_index),
                    {S1#server{next_index = Next2, rpc_due = RpcDue2}, M1}
            end
    end.

%% --- Helpers ----------------------------------------------------------------

server(Id, Peers) ->
    #server{
        id = Id,
        peers = Peers,
        state = follower,
        term = 1,
        voted_for = undefined,
        log = [],
        commit_index = 0,
        election_alarm = make_election_alarm(0),
        vote_granted = make_map(Peers, false),
        match_index = make_map(Peers, 0),
        next_index  = make_map(Peers, 1),
        rpc_due = make_map(Peers, 0),
        heartbeat_due = make_map(Peers, 0)
    }.

peers(Id) ->
    [J || J <- lists:seq(1, ?NUM_SERVERS), J =/= Id].

make_election_alarm(Now) ->
    %% Between 1x and 2x election timeout
    Now + trunc((rand:uniform() + 1.0) * ?ELECTION_TIMEOUT).

seed_rand() ->
    _ = rand:seed(exsplus, {
        erlang:monotonic_time(),
        erlang:unique_integer([positive]),
        erlang:phash2(self())
    }),
    ok.

make_map(Keys, Value) ->
    maps:from_list([{K, Value} || K <- Keys]).

count_true(Bools) ->
    lists:foldl(fun(B, Acc) -> if B -> Acc + 1; true -> Acc end end, 0, Bools).

log_term(_Log, Index) when Index < 1 ->
    0;
log_term(Log, Index) ->
    case length(Log) >= Index of
        true ->
            (lists:nth(Index, Log))#entry.term;
        false ->
            0
    end.

log_slice(_Log, _PrevIndex, LastIndex) when LastIndex =< 0 ->
    [];
log_slice(Log, PrevIndex, LastIndex) ->
    Len = LastIndex - PrevIndex,
    case Len =< 0 of
        true -> [];
        false ->
            Start = PrevIndex + 1,
            lists:sublist(Log, Start, Len)
    end.

append_entries(Log0, PrevIndex, Entries) ->
    %% Apply entries starting at PrevIndex+1; truncate on term mismatch.
    %% Returns {NewLog, LastIndexWritten}.
    {Log1, LastIdx} =
        lists:foldl(
          fun(Entry, {LogAcc, IdxAcc}) ->
              Idx = IdxAcc + 1,
              case log_term(LogAcc, Idx) =:= Entry#entry.term of
                  true ->
                      {LogAcc, Idx};
                  false ->
                      Prefix = lists:sublist(LogAcc, Idx - 1),
                      {Prefix ++ [Entry], Idx}
              end
          end,
          {Log0, PrevIndex},
          Entries),
    {Log1, LastIdx}.

maybe_step_down(M, S, IncomingTerm) ->
    case S#server.term < IncomingTerm of
        true -> {step_down(M, S, IncomingTerm), M};
        false -> {S, M}
    end.

step_down(#model{time = Time}, S, NewTerm) ->
    Alarm0 = S#server.election_alarm,
    Alarm1 =
        case (Alarm0 =< Time) orelse (Alarm0 =:= ?INF) of
            true  -> make_election_alarm(Time);
            false -> Alarm0
        end,
    S#server{
        term = NewTerm,
        state = follower,
        voted_for = undefined,
        election_alarm = Alarm1
    }.

send_message(M = #model{time = Now, messages = Msgs}, Msg0) ->
    Lat = ?MIN_RPC_LATENCY + trunc(rand:uniform() * (?MAX_RPC_LATENCY - ?MIN_RPC_LATENCY)),
    Msg = Msg0#{send_time => Now, recv_time => Now + Lat},
    M#model{messages = [Msg | Msgs]}.

map_server(Model0 = #model{servers = Servers0}, ServerId, Fun) ->
    {Servers1, Model1} =
        lists:mapfoldl(
          fun(S, MAcc) ->
              case S#server.id =:= ServerId of
                  true ->
                      {S2, MAcc2} = Fun(MAcc, S),
                      {S2, MAcc2};
                  false ->
                      {S, MAcc}
              end
          end,
          Model0,
          Servers0),
    Model1#model{servers = Servers1}.

adjust_alarm(Model0 = #model{servers = Servers0}, Pred, F) ->
    Servers1 =
        [case Pred(S#server.election_alarm) of
             true  -> S#server{election_alarm = F(S#server.election_alarm)};
             false -> S
         end || S <- Servers0],
    Model0#model{servers = Servers1}.

