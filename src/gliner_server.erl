-module(gliner_server).

%% API
-export([analyze/1, analyze/2, wait_ready/1, wait_ready_all/1]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

-doc """
Analyze text and extract entities
Uses poolboy transaction to checkout a worker, call it, and return it
Args: Text (binary)
Returns: {ok, map()} with entities or {error, term()}
""".
-spec analyze(binary()) -> {ok, map()} | {error, term()}.
analyze(Text) when is_binary(Text) ->
    % Use poolboy transaction for automatic checkout/checkin
    try
        poolboy:transaction(gliner_pool, fun(Worker) ->
            gen_server:call(Worker, {analyze, Text, map})
        end)
    catch
        _:Reason ->
            {error, Reason}
    end.

-doc """
Analyze text and extract entities with specified return type
Args: Text (binary), ReturnType :: map | pattern | tokens
  - map: Return standard GLiNER response with all entities
  - pattern: Return matched pattern if cached, otherwise standard response
  - tokens: Return template with token replacements for entity matches
Returns: {ok, map()} or {error, term()}
""".
-spec analyze(binary(), map | pattern | tokens) -> {ok, map()} | {error, term()}.
analyze(Text, ReturnType) when is_binary(Text), (ReturnType =:= map orelse ReturnType =:= pattern orelse ReturnType =:= tokens) ->
    % Use poolboy transaction for automatic checkout/checkin
    try
        poolboy:transaction(gliner_pool, fun(Worker) ->
            gen_server:call(Worker, {analyze, Text, ReturnType})
        end)
    catch
        _:Reason ->
            {error, Reason}
    end.

-doc """
Wait for a single worker to be ready
Args: TimeoutMs - timeout in milliseconds
Returns: ok or {error, not_ready}
""".
-spec wait_ready(non_neg_integer()) -> ok | {error, not_ready}.
wait_ready(TimeoutMs) ->
    % Use poolboy transaction to check readiness
    try
        poolboy:transaction(gliner_pool, fun(Worker) ->
            gen_server:call(Worker, {wait_ready}, TimeoutMs)
        end, TimeoutMs + 1000)  % Give extra time for transaction overhead
    catch
        _:_ ->
            {error, not_ready}
    end.

-doc """
Wait for all workers in the pool to be ready
Useful during initialization to ensure the entire pool is available
Args: TimeoutMs - timeout in milliseconds for the entire wait
Returns: ok or {error, Reason}
""".
-spec wait_ready_all(non_neg_integer()) -> ok | {error, term()}.
wait_ready_all(TimeoutMs) ->
    StartTime = erlang:system_time(millisecond),
    wait_all_ready_loop(TimeoutMs, StartTime).

%%====================================================================
%% Internal functions
%%====================================================================

%% Poll until all workers are ready or timeout
-spec wait_all_ready_loop(non_neg_integer(), integer()) -> ok | {error, term()}.
wait_all_ready_loop(TimeoutMs, StartTime) ->
    ElapsedTime = erlang:system_time(millisecond) - StartTime,
    case ElapsedTime >= TimeoutMs of
        true ->
            {error, timeout};
        false ->
            case check_pool_ready() of
                true ->
                    ok;
                false ->
                    timer:sleep(100),
                    wait_all_ready_loop(TimeoutMs, StartTime)
            end
    end.

%% Check if all workers in the pool are ready
-spec check_pool_ready() -> boolean().
check_pool_ready() ->
    % Try to check out all workers (non-blocking)
    Workers = checkout_all_workers([], 0),
    % Release them all
    release_all_workers(Workers),
    % If we got at least one worker, consider ready
    % (If pool is exhausted, we need to wait longer)
    length(Workers) > 0 andalso all_ready(Workers).

%% Check out all available workers without blocking
-spec checkout_all_workers(list(), pos_integer()) -> list().
checkout_all_workers(Acc, Attempts) when Attempts > 20 ->
    Acc;  % Stop after reasonable attempts
checkout_all_workers(Acc, Attempts) ->
    case poolboy:checkout(gliner_pool, false) of
        full ->
            Acc;  % No more workers available
        Worker ->
            checkout_all_workers([Worker | Acc], Attempts + 1)
    end.

%% Release all checked-out workers back to the pool
-spec release_all_workers(list()) -> ok.
release_all_workers([]) ->
    ok;
release_all_workers([Worker | Rest]) ->
    poolboy:checkin(gliner_pool, Worker),
    release_all_workers(Rest).

%% Check if all workers are ready
-spec all_ready(list()) -> boolean().
all_ready([]) ->
    true;
all_ready([Worker | Rest]) ->
    case catch gen_server:call(Worker, {wait_ready}, 100) of
        ok ->
            all_ready(Rest);
        _ ->
            false
    end.
