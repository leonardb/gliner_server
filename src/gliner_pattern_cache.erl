-module(gliner_pattern_cache).
-behaviour(gen_server).

%% API
-export([
    start_link/1,
    get_cache_list/0,
    put_pattern/1,
    clear_cache/0,
    cache_stats/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(CACHE_TERM_KEY, gliner_pattern_cache).

-record(state, {
    max_size :: pos_integer(),
    current_size = 0 :: non_neg_integer(),
    cache_list = [] :: list({re:mp(), binary()})
}).

%%====================================================================
%% API
%%====================================================================

-doc """
Start the pattern cache server
Args: MaxSize - maximum number of cached patterns (default: 1000)
""".
start_link(MaxSize) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [MaxSize], []).

-doc """
Get the entire cached pattern list
Returns: list() of {CompiledPattern, PatternString} tuples
Fast zero-overhead read - all workers read directly from persistent_term
Iterates locally to find matching patterns
""".
-spec get_cache_list() -> list().
get_cache_list() ->
    try
        persistent_term:get(?CACHE_TERM_KEY)
    catch
        error:badarg ->
            []
    end.

-doc """
Put a pattern in the cache
Args: PatternEntry - {CompiledPattern, PatternString}
Updates persistent_term with the new cache list
""".
-spec put_pattern({re:mp(), binary()}) -> ok.
put_pattern({_, _} = PatternEntry) ->
    gen_server:call(?MODULE, {put_pattern, PatternEntry}).

-doc """
Clear all cached patterns
""".
-spec clear_cache() -> ok.
clear_cache() ->
    gen_server:call(?MODULE, clear_cache).

-doc """
Get cache statistics
Returns: {ok, #{size => N, max_size => M}}
""".
-spec cache_stats() -> {ok, map()}.
cache_stats() ->
    gen_server:call(?MODULE, cache_stats).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([MaxSize]) ->
    ?LOG_INFO("GLiNER Pattern Cache starting (max size: ~w)", [MaxSize]),
    % Initialize persistent_term with empty cache
    CacheList = case persistent_term:get(?CACHE_TERM_KEY, undefined) of
        undefined ->
            persistent_term:put(?CACHE_TERM_KEY, []),
            [];
        List ->
            List
    end,
    {ok, #state{max_size = MaxSize, cache_list = CacheList, current_size = length(CacheList)}}.

handle_call({put_pattern, PatternEntry}, _From, State) ->
    {reply, ok, add_to_cache(PatternEntry, State)};

handle_call(clear_cache, _From, State) ->
    persistent_term:put(?CACHE_TERM_KEY, []),
    {reply, ok, State#state{cache_list = [], current_size = 0}};

handle_call(cache_stats, _From, State) ->
    Stats = #{
        size => State#state.current_size,
        max_size => State#state.max_size
    },
    {reply, {ok, Stats}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% Add a pattern to the cache with LRU eviction
%% Simple: if cache not full, add to front; if full, evict last and add to front
-spec add_to_cache({re:mp(), binary()}, #state{}) -> #state{}.
add_to_cache(PatternEntry, #state{current_size = CurrentSize, max_size = MaxSize, cache_list = CacheList} = State) when CurrentSize < MaxSize ->
    NewCacheList = [PatternEntry | CacheList],
    persistent_term:put(?CACHE_TERM_KEY, NewCacheList),
    State#state{
        cache_list = NewCacheList,
        current_size = CurrentSize + 1
    };
add_to_cache(PatternEntry, #state{cache_list = CacheList} = State) ->
    % Cache full - evict last (LRU) and add new to front
    NewCacheList = [PatternEntry | lists:droplast(CacheList)],
    persistent_term:put(?CACHE_TERM_KEY, NewCacheList),
    State#state{cache_list = NewCacheList}.
