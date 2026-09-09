-module(gliner_server).
-behaviour(gen_server).

%% API
-export([start_link/0, analyze/1, wait_ready/1, get_binary_path/0]).

%% gen_server callbacks
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    port :: port() | undefined,
    buffer = <<>> :: binary(),
    ready = false :: boolean(),
    reconnect_attempt = 0 :: non_neg_integer(),
    reconnect_timer = undefined :: reference() | undefined
}).

%%====================================================================
%% API
%%====================================================================

-doc """
Start the GLiNER server
Args: [] (no args needed)
Returns: {ok, Pid} or {error, Reason}
""".
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
Analyze text and extract entities
Args: Text (binary)
Returns: {ok, map()} with entities
""".
-spec analyze(binary()) -> {ok, map()} | {error, term()}.
analyze(Text) when is_binary(Text) ->
    gen_server:call(?SERVER, {analyze, Text}).

-doc """
Wait for the server to be ready (model loaded, READY signal received)
Args: TimeoutMs - timeout in milliseconds
Returns: ok or {error, timeout}
""".
-spec wait_ready(non_neg_integer()) -> ok | {error, timeout}.
wait_ready(TimeoutMs) ->
    gen_server:call(?SERVER, {wait_ready}, TimeoutMs).

-doc """
Get the path to the native GLiNER binary
Returns: Path as string
""".
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

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    % Trap EXIT messages so we can handle port crashes
    process_flag(trap_exit, true),
    
    % Defer port opening to handle_continue to allow proper startup sequencing
    % This lets us wait for READY signal from Rust binary
    ?LOG_INFO("GLiNER server initializing..."),
    {ok, #state{ready = false}, {continue, start_port}}.

handle_continue(start_port, State) ->
    % Open port to Rust binary
    % Note: {packet, 0} not supported in Erlang 28+ for spawned ports
    BinaryPath = get_binary_path(),
    
    case open_port({spawn, BinaryPath}, [binary, exit_status]) of
        Port when is_port(Port) ->
            % Link to the port so we get EXIT messages when it dies
            link(Port),
            ?LOG_INFO("Port opened, waiting for READY signal from Rust binary...", []),
            % Return state with port but ready=false until we get READY message
            {noreply, State#state{port = Port, reconnect_attempt = 0}}
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
    ?LOG_ERROR("Port ~w exited with reason: ~w", [Port, Reason]),
    % Schedule reconnection with exponential backoff
    DelayMs = calculate_backoff(State#state.reconnect_attempt),
    {noreply, schedule_reconnect(State#state{port = undefined, ready = false}, DelayMs)};

handle_info({Port, {data, Data}}, State = #state{port = Port, buffer = Buffer}) ->
    % Check if this is a READY signal from startup (ID="S")
    NewBuffer = <<Buffer/binary, Data/binary>>,
    case try_parse_ready_signal(NewBuffer) of
        {ready, Rest} ->
            ?LOG_INFO("✓ Received READY signal from Rust binary - server is now ready"),
            {noreply, State#state{buffer = Rest, ready = true}};
        {not_ready, _Rest} ->
            % Not a READY signal, keep in buffer for regular message handling
            {noreply, State#state{buffer = NewBuffer}}
    end;

handle_info({reconnect}, State) ->
    ?LOG_INFO("Attempting to reconnect (attempt ~w)...", [State#state.reconnect_attempt + 1]),
    BinaryPath = get_binary_path(),
    case erlang:open_port({spawn, BinaryPath}, [binary, exit_status]) of
        Port when is_port(Port) ->
            link(Port),
            ?LOG_INFO("Successfully reconnected to port: ~w", [Port]),
            {noreply, State#state{
                port = Port,
                reconnect_attempt = 0,
                reconnect_timer = undefined,
                ready = false
            }}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{port = Port, reconnect_timer = Timer}) ->
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
%% Attempt 0: 1s, 1: 2s, 2: 4s, 3: 8s, etc.
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
