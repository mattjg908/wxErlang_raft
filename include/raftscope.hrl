%% Shared records for the RaftScope Erlang engine + GUI.

-define(RPC_TIMEOUT, 50000).          %% microseconds
-define(MIN_RPC_LATENCY, 10000).
-define(MAX_RPC_LATENCY, 15000).
-define(ELECTION_TIMEOUT, 100000).
-define(NUM_SERVERS, 5).
-define(BATCH_SIZE, 1).
-define(INF, 1000000000000000000000000000000000000).

-record(entry, {term, value}).
-record(server,
        {id,
         peers = [],
         state = follower,              %% follower | candidate | leader | stopped
         term = 1,
         voted_for = undefined,
         log = [],                      %% [#entry{}]
         commit_index = 0,              %% 1-based
         election_start = 0,
         election_timeout = ?ELECTION_TIMEOUT,
         election_alarm = 0,
         vote_granted = #{},            %% PeerId => boolean()
         match_index = #{},             %% PeerId => integer()
         next_index = #{},             %% PeerId => integer()
         rpc_due = #{},                 %% PeerId => time()
         heartbeat_due = #{}}).            %% PeerId => time()
-record(model,
        {time = 0,                      %% microseconds
         servers = [],                  %% [#server{}]
         messages = []}).                  %% [map()]
