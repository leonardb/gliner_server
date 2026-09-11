-module(gliner_worker).
-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    worker_id :: pos_integer(),
    model_dir :: string(),
    port :: port() | undefined,
    buffer = <<>> :: binary(),
    ready = false :: boolean(),
    reconnect_attempt = 0 :: non_neg_integer(),
    reconnect_timer = undefined :: reference() | undefined,
    pattern_cache = [] :: list(),  % In-memory list of {CompiledPattern, EntityMap}
    cache_size = 0 :: non_neg_integer(),  % Current cache size (O(1) lookup vs length/1)
    max_cache_size = 1000 :: pos_integer()
}).

%%====================================================================
%% API
%%====================================================================

-doc """
Start a GLiNER worker process
Args: WorkerId - unique worker identifier (for logging)
Returns: {ok, Pid} or {error, Reason}
""".
start_link(WorkerId) ->
    gen_server:start_link(?MODULE, [WorkerId], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([WorkerId]) ->
    % Trap EXIT messages so we can handle port crashes
    process_flag(trap_exit, true),
    
    % Get model directory from manager
    ModelDir = gliner_manager:get_model_dir(),
    
    % Defer port opening to handle_continue
    ?LOG_INFO("GLiNER worker ~w initializing (model dir: ~s)...", [WorkerId, ModelDir]),
    {ok, #state{worker_id = WorkerId, model_dir = ModelDir, ready = false}, {continue, start_port}}.

handle_continue(start_port, State) ->
    % Open port to Rust binary
    BinaryPath = get_binary_path(),
    
    case open_port({spawn, BinaryPath}, [binary, exit_status]) of
        Port when is_port(Port) ->
            % Link to the port so we get EXIT messages when it dies
            link(Port),
            ?LOG_INFO("Worker ~w: Port opened, waiting for READY signal from Rust binary...", [State#state.worker_id]),
            % Return state with port but ready=false until we get READY message
            {noreply, State#state{port = Port, reconnect_attempt = 0}};
        Error ->
            ?LOG_ERROR("Worker ~w: Failed to open port: ~w", [State#state.worker_id, Error]),
            {stop, Error}
    end;
handle_continue(_Msg, State) ->
    {noreply, State}.

handle_call({analyze, _Text}, _From, State = #state{ready = false}) ->
    {reply, {error, not_ready}, State};
handle_call({analyze, Text}, _From, State = #state{port = Port, buffer = Buffer}) ->
    % Check if port is alive
    case Port of
        undefined ->
            {reply, {error, port_not_available}, State};
        _ ->
            % Generate a unique request ID
            IdBinary = generate_id(),
            
            % Send request to port using binary protocol
            % Protocol: <<IdSize:u8, Id:binary, TextSize:u16, Text:binary>>
            IdSize = byte_size(IdBinary),
            TextSize = byte_size(Text),
            
            Request = <<IdSize:8, IdBinary/binary, TextSize:16, Text/binary>>,
            port_command(Port, Request),
            
            % Read response
            {Response, NewBuffer} = read_response(Port, Buffer),
            
            {reply, {ok, Response}, State#state{buffer = NewBuffer}}
    end;

%% Analyze with explicit return type
handle_call({analyze, _Text, _ReturnType}, _From, State = #state{ready = false}) ->
    {reply, {error, not_ready}, State};
handle_call({analyze, Text, ReturnType}, _From, State = #state{port = Port, buffer = Buffer, pattern_cache = Cache}) ->
    % Check if port is alive
    case Port of
        undefined ->
            {reply, {error, port_not_available}, State};
        _ ->
            case ReturnType of
                map ->
                    % Always call GLiNER for map return type
                    {Response, NewBuffer} = call_gliner(Text, Port, Buffer),
                    {reply, {ok, Response}, State#state{buffer = NewBuffer}};
                pattern ->
                    % Try pattern cache first
                    case try_match_cache(Text, Cache) of
                        {ok, MatchedPattern} ->
                            % Return matched pattern
                            Response = #{<<"pattern">> => MatchedPattern, <<"cached">> => true},
                            {reply, {ok, Response}, State};
                        no_match ->
                            % Call GLiNER and potentially cache the pattern
                            {Response, NewBuffer, NewCache, NewCacheSize} = call_gliner_and_cache(Text, Port, Buffer, Cache, State#state.cache_size, State#state.max_cache_size),
                            {reply, {ok, Response}, State#state{buffer = NewBuffer, pattern_cache = NewCache, cache_size = NewCacheSize}}
                    end;
                tokens ->
                    % Try pattern cache first, then extract matches if found
                    case try_match_cache_with_matches(Text, Cache) of
                        {ok, TemplateAndMatches} ->
                            % Return template with matches (cached)
                            Response = maps:merge(TemplateAndMatches, #{<<"cached">> => true}),
                            {reply, {ok, Response}, State};
                        no_match ->
                            % Call GLiNER and extract matches from generated pattern
                            {Response, NewBuffer, NewCache, NewCacheSize} = call_gliner_and_cache_matches(Text, Port, Buffer, Cache, State#state.cache_size, State#state.max_cache_size),
                            {reply, {ok, Response}, State#state{buffer = NewBuffer, pattern_cache = NewCache, cache_size = NewCacheSize}}
                    end
            end
    end;

handle_call({wait_ready}, _From, State = #state{ready = Ready}) ->
    % If already ready, return immediately
    case Ready of
        true ->
            {reply, ok, State};
        false ->
            % If not ready yet, return error and caller must retry
            {reply, {error, not_ready}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    ?LOG_ERROR("Worker ~w: Port ~w exited with reason: ~w", [State#state.worker_id, Port, Reason]),
    % Schedule reconnection with exponential backoff
    DelayMs = calculate_backoff(State#state.reconnect_attempt),
    {noreply, schedule_reconnect(State#state{port = undefined, ready = false}, DelayMs)};

handle_info({Port, {data, Data}}, State = #state{port = Port, buffer = Buffer}) ->
    % Check if this is a READY signal from startup (ID="S")
    NewBuffer = <<Buffer/binary, Data/binary>>,
    case try_parse_ready_signal(NewBuffer) of
        {ready, Rest} ->
            ?LOG_INFO("Worker ~w: ✓ Received READY signal from Rust binary - worker is now ready", [State#state.worker_id]),
            {noreply, State#state{buffer = Rest, ready = true}};
        {not_ready, _Rest} ->
            % Not a READY signal, keep in buffer for regular message handling
            {noreply, State#state{buffer = NewBuffer}}
    end;

handle_info({reconnect}, State) ->
    ?LOG_INFO("Worker ~w: Attempting to reconnect (attempt ~w)...", [State#state.worker_id, State#state.reconnect_attempt + 1]),
    BinaryPath = get_binary_path(),
    case erlang:open_port({spawn, BinaryPath}, [binary, exit_status]) of
        Port when is_port(Port) ->
            link(Port),
            ?LOG_INFO("Worker ~w: Successfully reconnected to port: ~w", [State#state.worker_id, Port]),
            {noreply, State#state{
                port = Port,
                reconnect_attempt = 0,
                reconnect_timer = undefined,
                ready = false
            }};
        Error ->
            ?LOG_ERROR("Worker ~w: Reconnect failed: ~w", [State#state.worker_id, Error]),
            DelayMs = calculate_backoff(State#state.reconnect_attempt + 1),
            {noreply, schedule_reconnect(State#state{reconnect_attempt = State#state.reconnect_attempt + 1}, DelayMs)}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, #state{worker_id = WorkerId, port = Port, reconnect_timer = Timer}) ->
    ?LOG_INFO("Worker ~w terminating with reason: ~w", [WorkerId, Reason]),
    % Cancel any pending reconnect timer
    case Timer of
        undefined -> ok;
        TimerRef -> erlang:cancel_timer(TimerRef)
    end,
    % Close the port if it exists
    case Port of
        undefined -> ok;
        _ -> try port_close(Port) catch _:_ -> ok end
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% Get the path to the native GLiNER binary
-spec get_binary_path() -> string().
get_binary_path() ->
    % Try to find binary in priv/bin (when running via rebar3/OTP release)
    case code:priv_dir(gliner_server) of
        {error, _} ->
            % Fallback: assume we're running from source tree
            "target/release/native_gliner_worker";
        PrivDir ->
            % Use the binary from priv/bin directory
            filename:join([PrivDir, "bin", "native_gliner_worker"])
    end.

%% Attempt to parse a READY signal from the buffer
%% READY message format: [IdSize:u8][Id:binary][ResponseSize:u16][Response:binary]
%% Where: IdSize=1, Id="S", ResponseSize=5, Response="READY"
%% Returns: {ready, RestOfBuffer} | {not_ready, BufferUnchanged}
try_parse_ready_signal(Buffer) ->
    case Buffer of
        <<1:8, $S:8, 5:16/big, Rest/binary>> ->
            % Check if the next 5 bytes are "READY"
            case Rest of
                <<"READY", Remainder/binary>> ->
                    {ready, Remainder};
                _ ->
                    {not_ready, Buffer}
            end;
        _ ->
            {not_ready, Buffer}
    end.

%% Schedule a reconnection attempt
%% Returns: Updated state with timer reference
schedule_reconnect(State, DelayMs) ->
    % Cancel any existing timer
    case State#state.reconnect_timer of
        undefined -> ok;
        OldTimer -> erlang:cancel_timer(OldTimer)
    end,
    % Schedule new timer
    Timer = erlang:send_after(DelayMs, self(), {reconnect}),
    State#state{reconnect_timer = Timer}.

%% Calculate exponential backoff with jitter
%% Starts at 1s, doubles up to max 60s
-spec calculate_backoff(non_neg_integer()) -> pos_integer().
calculate_backoff(Attempt) ->
    MaxDelay = 60000, % 60 seconds in ms
    BaseDelay = 1000, % 1 second in ms
    % Calculate exponential backoff: min(2^attempt * base, max)
    Delay = min(BaseDelay * (1 bsl Attempt), MaxDelay),
    % Add jitter: ±10%
    Jitter = Delay div 10,
    Delay - Jitter + rand:uniform(Jitter * 2).

%% Generate a unique request ID
generate_id() ->
    Timestamp = erlang:system_time(microsecond),
    Node = node(),
    list_to_binary(
        erlang:integer_to_list(Timestamp) ++ "_" ++ erlang:atom_to_list(Node)
    ).

%% Read response from port
%% Protocol: <<IdSize:u8, Id:binary, ResponseSize:u16, Response:binary>>
%% Returns: {Response, NewBuffer}
read_response(Port, Buffer) ->
    % 1. Read IdSize (1 byte)
    {IdSizeBin, Buffer1} = read_exact(Port, 1, Buffer),
    <<IdSize:8>> = IdSizeBin,
    
    % 2. Read Id (IdSize bytes)
    {_Id, Buffer2} = read_exact(Port, IdSize, Buffer1),
    
    % 3. Read ResponseSize (2 bytes, big-endian)
    {ResponseSizeBin, Buffer3} = read_exact(Port, 2, Buffer2),
    <<ResponseSize:16/big>> = ResponseSizeBin,
    
    % 4. Read Response (ResponseSize bytes)
    {ResponseBin, Buffer4} = read_exact(Port, ResponseSize, Buffer3),
    
    % Parse JSON response
    Response = json:decode(ResponseBin),
    
    {Response, Buffer4}.

%% Read exactly N bytes from port
%% Returns: {Data, RemainingBuffer}
read_exact(_Port, N, Buffer) when byte_size(Buffer) >= N ->
    <<Data:N/binary, Rest/binary>> = Buffer,
    {Data, Rest};
read_exact(Port, N, Buffer) ->
    % Need more data
    receive
        {Port, {data, Data}} ->
            read_exact(Port, N, <<Buffer/binary, Data/binary>>);
        {Port, {exit_status, Status}} ->
            error({port_exit, Status})
    after 120000 ->  % 120 seconds timeout to allow for model download on first run
        error(port_read_timeout)
    end.

%% Call GLiNER and return response with new buffer
-spec call_gliner(binary(), port(), binary()) -> {map(), binary()}.
call_gliner(Text, Port, Buffer) ->
    IdBinary = generate_id(),
    IdSize = byte_size(IdBinary),
    TextSize = byte_size(Text),
    Request = <<IdSize:8, IdBinary/binary, TextSize:16, Text/binary>>,
    port_command(Port, Request),
    {Response, NewBuffer} = read_response(Port, Buffer),
    {Response, NewBuffer}.

%% Try to match text against cached patterns
%% Returns {ok, PatternString} or no_match
-spec try_match_cache(binary(), list()) -> {ok, binary()} | no_match.
try_match_cache(_Text, []) ->
    no_match;
try_match_cache(Text, [PatternEntry | Rest]) ->
    case gliner_cache:try_match_pattern(Text, PatternEntry) of
        {ok, PatternString} ->
            {ok, PatternString};
        no_match ->
            try_match_cache(Text, Rest)
    end.

%% Call GLiNER and generate/cache pattern if response contains entities
-spec call_gliner_and_cache(binary(), port(), binary(), list(), non_neg_integer(), pos_integer()) -> {map(), binary(), list(), non_neg_integer()}.
call_gliner_and_cache(Text, Port, Buffer, Cache, CacheSize, MaxCacheSize) ->
    {Response, NewBuffer} = call_gliner(Text, Port, Buffer),
    
    % Try to generate and cache pattern
    case maps:get(<<"entities">>, Response, []) of
        [] ->
            % No entities, no pattern to cache - return original response
            {Response, NewBuffer, Cache, CacheSize};
        Entities ->
            case gliner_cache:generate_pattern(Text, Entities) of
                {ok, {_CompiledPattern, PatternString}} ->
                    % Add to cache (returns both cache and new size)
                    PatternEntry = {_CompiledPattern, PatternString},
                    {NewCache, NewSize} = gliner_cache:add_to_cache(PatternEntry, Cache, CacheSize, MaxCacheSize),
                    % Return pattern response (not the original entity response)
                    PatternResponse = #{<<"pattern">> => PatternString, <<"cached">> => false},
                    {PatternResponse, NewBuffer, NewCache, NewSize};
                {error, Reason} ->
                    ?LOG_DEBUG("Failed to generate pattern: ~w", [Reason]),
                    % On error, return original response
                    {Response, NewBuffer, Cache, CacheSize}
            end
    end.

%% Try to match text against cached patterns and extract matches
%% Returns {ok, {template, tokens, matches}} if match found, or no_match
-spec try_match_cache_with_matches(binary(), list()) -> {ok, map()} | no_match.
try_match_cache_with_matches(_Text, []) ->
    no_match;
try_match_cache_with_matches(Text, [{CompiledPattern, PatternString} | Rest]) ->
    case gliner_cache:try_match_pattern(Text, {CompiledPattern, PatternString}) of
        {ok, _} ->
            % Pattern matched, now extract matches
            case extract_matches_and_build_template(Text, CompiledPattern, PatternString) of
                {ok, TemplateMap} ->
                    {ok, TemplateMap};
                {error, _} ->
                    % Extraction failed, try next pattern
                    try_match_cache_with_matches(Text, Rest)
            end;
        no_match ->
            try_match_cache_with_matches(Text, Rest)
    end.

%% Call GLiNER, generate pattern, and extract matches
-spec call_gliner_and_cache_matches(binary(), port(), binary(), list(), non_neg_integer(), pos_integer()) -> {map(), binary(), list(), non_neg_integer()}.
call_gliner_and_cache_matches(Text, Port, Buffer, Cache, CacheSize, MaxCacheSize) ->
    {Response, NewBuffer} = call_gliner(Text, Port, Buffer),
    
    % Try to generate and cache pattern
    case maps:get(<<"entities">>, Response, []) of
        [] ->
            % No entities, no pattern to cache - return original response
            {Response, NewBuffer, Cache, CacheSize};
        Entities ->
            case gliner_cache:generate_pattern(Text, Entities) of
                {ok, {CompiledPattern, PatternString}} ->
                    % Extract matches from the generated pattern
                    case extract_matches_and_build_template(Text, CompiledPattern, PatternString) of
                        {ok, TemplateMap} ->
                            % Add to cache
                            PatternEntry = {CompiledPattern, PatternString},
                            {NewCache, NewSize} = gliner_cache:add_to_cache(PatternEntry, Cache, CacheSize, MaxCacheSize),
                            % Return template with matches (not cached, just generated)
                            TemplateMapWithCached = maps:merge(TemplateMap, #{<<"cached">> => false}),
                            {TemplateMapWithCached, NewBuffer, NewCache, NewSize};
                        {error, _ExtractReason} ->
                            ?LOG_DEBUG("Failed to extract matches from pattern", []),
                            % On extraction error, return original response
                            {Response, NewBuffer, Cache, CacheSize}
                    end;
                {error, Reason} ->
                    ?LOG_DEBUG("Failed to generate pattern: ~w", [Reason]),
                    % On error, return original response
                    {Response, NewBuffer, Cache, CacheSize}
            end
    end.

%% Extract matches from compiled pattern and build response template with tokens
%% Returns {ok, #{template => NewTemplate, tokens => TokensList}} or {error, term()}
-spec extract_matches_and_build_template(binary(), re:mp(), binary()) -> {ok, map()} | {error, term()}.
extract_matches_and_build_template(Text, CompiledPattern, _PatternString) ->
    case re:run(Text, CompiledPattern, [{capture, all_but_first, binary}]) of
        {match, Captures} ->
            % Build list of {TokenName, MatchValue} pairs with indices
            TokensAndMatches = build_tokens_with_index(Captures, 0, []),
            
            % Build template by replacing captures with token placeholders
            TemplateWithTokens = lists:foldl(fun({TokenName, MatchValue}, Acc) ->
                binary:replace(Acc, MatchValue, <<"{{", TokenName/binary, "}}">>, [global])
            end, Text, TokensAndMatches),
            
            % Extract just the token names and values
            Tokens = lists:map(fun({Name, Value}) -> {Name, Value} end, TokensAndMatches),
            
            Response = #{
                <<"template">> => TemplateWithTokens,
                <<"tokens">> => Tokens
            },
            {ok, Response};
        nomatch ->
            {error, no_match};
        {error, Reason} ->
            {error, Reason}
    end.

%% Helper: Build token names with indices
-spec build_tokens_with_index(list(), non_neg_integer(), list()) -> list().
build_tokens_with_index([], _Index, Acc) ->
    lists:reverse(Acc);
build_tokens_with_index([Value | Rest], Index, Acc) ->
    TokenName = iolist_to_binary(io_lib:format(<<"smdpattern_~w">>, [Index])),
    build_tokens_with_index(Rest, Index + 1, [{TokenName, Value} | Acc]).
