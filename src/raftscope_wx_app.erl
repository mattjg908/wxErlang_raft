-module(raftscope_wx_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    raftscope_wx_sup:start_link().

stop(_State) ->
    ok.
