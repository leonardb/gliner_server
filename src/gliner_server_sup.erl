-module(gliner_server_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    % Supervisor strategy: start gliner_manager first, then gliner_worker_sup
    % If either crashes, restart it independently (one_for_one)
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    ChildSpecs = [
        % Manager starts first, ensures model/tokenizer files exist
        #{id => gliner_manager,
          start => {gliner_manager, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [gliner_manager]},
        
        % Worker supervisor manages poolboy pool of gliner_worker processes
        #{id => gliner_worker_sup,
          start => {gliner_worker_sup, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [gliner_worker_sup]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
