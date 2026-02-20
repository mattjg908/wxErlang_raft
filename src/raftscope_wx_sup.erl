-module(raftscope_wx_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% GUI as a permanent worker
    SupFlags =
        #{strategy => one_for_one,
          intensity => 1,
          period => 5},
    Child =
        #{id => raftscope_wx_gui,
          start => {raftscope_wx_gui, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [raftscope_wx_gui]},
    {ok, {SupFlags, [Child]}}.
