-module(gliner_worker_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    % Get pool size from application config, default to 3
    PoolSize = case application:get_env(gliner_server, gliner_pool_size) of
        {ok, Size} -> Size;
        undefined -> 3
    end,
    
    ?LOG_INFO("Starting GLiNER worker pool with ~w workers", [PoolSize]),
    
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    ChildSpecs = [
        #{id => gliner_pool,
          start => {poolboy, start_link, [[
              {name, {local, gliner_pool}},
              {worker_module, gliner_worker},
              {size, PoolSize},
              {max_overflow, 0}
          ]]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [poolboy]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
