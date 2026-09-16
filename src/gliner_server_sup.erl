-module(gliner_server_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    % Supervisor strategy: start services in order
    % 1. gliner_manager: ensures model/tokenizer files exist
    % 2. gliner_pattern_cache: manages shared pattern cache (accessed by all workers)
    % 3. gliner_worker_sup: manages poolboy pool of gliner_worker processes
    % If any crash, restart independently (one_for_one)
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    ChildSpecs = [
        % Manager starts first, ensures model/tokenizer files exist
        #{id => gliner_manager,
          start => {gliner_manager, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [gliner_manager]},
        
        % Pattern cache server - manages shared cache in persistent_term
        % All workers read from this cache
        #{id => gliner_pattern_cache,
          start => {gliner_pattern_cache, start_link, [1000]},  % Max 1000 patterns
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [gliner_pattern_cache]},
        
        % Worker supervisor manages poolboy pool of gliner_worker processes
        #{id => gliner_worker_sup,
          start => {gliner_worker_sup, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [gliner_worker_sup]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
