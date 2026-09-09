-module(gliner_server_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    ChildSpecs = [
        #{id => gliner_server,
          start => {gliner_server, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [gliner_server]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
