-module(gliner_manager).
-behaviour(gen_server).

%% API
-export([start_link/0, get_model_dir/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    model_dir :: string(),
    ready = false :: boolean()
}).

%% URLs for model and tokenizer from HuggingFace
-define(TOKENIZER_URL, "https://huggingface.co/onnx-community/gliner_small-v2.1/raw/main/tokenizer.json").
-define(MODEL_URL, "https://huggingface.co/onnx-community/gliner_small-v2.1/resolve/main/onnx/model.onnx").

%%====================================================================
%% API
%%====================================================================

-doc """
Start the GLiNER manager
Ensures model and tokenizer files are downloaded
""".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Get the directory where model files are stored
""".
-spec get_model_dir() -> string().
get_model_dir() ->
    gen_server:call(?MODULE, get_model_dir).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ?LOG_INFO("GLiNER Manager starting..."),
    ModelDir = get_model_cache_dir(),
    try ensure_model_files(ModelDir) of
        ok ->
            ?LOG_INFO("✓ Model and tokenizer files ready"),
            {ok, #state{model_dir = ModelDir, ready = true}}
    catch
        throw:Reason ->
            ?LOG_ERROR("✗ Failed to ensure model files: ~w", [Reason]),
            % Return error to fail fast - don't start the system without model files
            {stop, {model_files_not_available, Reason}};
        error:Reason ->
            ?LOG_ERROR("✗ Error during model file initialization: ~w", [Reason]),
            {stop, {model_file_initialization_error, Reason}}
    end.

handle_call(get_model_dir, _From, State = #state{model_dir = Dir}) ->
    {reply, Dir, State};
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

%% Get stable cache directory for model files
-spec get_model_cache_dir() -> string().
get_model_cache_dir() ->
    % Try to use XDG_CACHE_HOME on Linux/macOS, or $HOME/.cache
    case os:getenv("XDG_CACHE_HOME") of
        false ->
            case os:getenv("HOME") of
                false ->
                    % Windows fallback: %APPDATA%/gliner_worker
                    case os:getenv("APPDATA") of
                        false ->
                            % Last resort: /tmp/gliner_worker
                            CacheDir = "/tmp/gliner_worker",
                            filelib:ensure_dir(CacheDir ++ "/"),
                            CacheDir;
                        AppData ->
                            CacheDir = filename:join([AppData, "gliner_worker"]),
                            filelib:ensure_dir(CacheDir ++ "/"),
                            CacheDir
                    end;
                Home ->
                    CacheDir = filename:join([Home, ".cache", "gliner_worker"]),
                    filelib:ensure_dir(CacheDir ++ "/"),
                    CacheDir
            end;
        CacheHome ->
            CacheDir = filename:join([CacheHome, "gliner_worker"]),
            filelib:ensure_dir(CacheDir ++ "/"),
            CacheDir
    end.

%% Ensure model and tokenizer files exist, downloading if necessary
-spec ensure_model_files(string()) -> ok | {error, term()}.
ensure_model_files(ModelDir) ->
    TokenizerPath = filename:join([ModelDir, "tokenizer.json"]),
    ModelPath = filename:join([ModelDir, "model.onnx"]),
    
    % Check and download tokenizer
    case filelib:is_file(TokenizerPath) of
        true ->
            ?LOG_INFO("✓ Using cached tokenizer: ~s", [TokenizerPath]);
        false ->
            ?LOG_INFO("Downloading tokenizer.json to ~s...", [TokenizerPath]),
            case download_file(?TOKENIZER_URL, TokenizerPath) of
                ok ->
                    ?LOG_INFO("✓ Tokenizer downloaded successfully");
                {error, E1} ->
                    ?LOG_ERROR("✗ Failed to download tokenizer: ~w", [E1]),
                    throw({tokenizer_download_failed, E1})
            end
    end,
    
    % Check and download model
    case filelib:is_file(ModelPath) of
        true ->
            ?LOG_INFO("✓ Using cached model: ~s", [ModelPath]);
        false ->
            ?LOG_INFO("Downloading model.onnx to ~s (this may take several minutes)...", [ModelPath]),
            case download_file(?MODEL_URL, ModelPath) of
                ok ->
                    ?LOG_INFO("✓ Model downloaded successfully");
                {error, E2} ->
                    ?LOG_ERROR("✗ Failed to download model: ~w", [E2]),
                    throw({model_download_failed, E2})
            end
    end,
    
    ok.

%% Download a file from URL and save to disk using httpc
-spec download_file(string(), string()) -> ok | {error, term()}.
download_file(Url, DestPath) ->
    TempPath = DestPath ++ ".tmp",
    
    % Ensure inets is started for httpc
    case application:ensure_started(inets) of
        ok -> ok;
        {error, {already_started, inets}} -> ok;
        {error, InetReason} ->
            ?LOG_ERROR("Failed to start inets: ~w", [InetReason]),
            throw({inets_start_failed, InetReason})
    end,
    
    % Ensure ssl is started for https
    case application:ensure_started(ssl) of
        ok -> ok;
        {error, {already_started, ssl}} -> ok;
        {error, SslReason} ->
            ?LOG_ERROR("Failed to start ssl: ~w", [SslReason]),
            throw({ssl_start_failed, SslReason})
    end,
    
    % Configure httpc options
    HttpOptions = [
        {timeout, 300000},          % 5 minute timeout
        {connect_timeout, 10000},   % 10 second connect timeout
        {ssl, [{verify, verify_none}]}  % Allow self-signed certs (HuggingFace should be fine)
    ],
    
    % Make the HTTP request
    case httpc:request(get, {Url, [{"User-Agent", "GLiNER-Erlang/1.0"}]}, HttpOptions, [{body_format, binary}]) of
        {ok, {{_HttpVersion, StatusCode, _Reason}, _Headers, Body}} when StatusCode >= 200, StatusCode < 300 ->
            % Success - write to temp file then rename
            case file:write_file(TempPath, Body) of
                ok ->
                    case file:rename(TempPath, DestPath) of
                        ok -> 
                            ?LOG_INFO("Downloaded ~w bytes to ~s", [byte_size(Body), DestPath]),
                            ok;
                        {error, RenameReason} ->
                            ?LOG_ERROR("Failed to rename temp file to ~s: ~w", [DestPath, RenameReason]),
                            file:delete(TempPath),
                            {error, {rename_failed, RenameReason}}
                    end;
                {error, WriteReason} ->
                    ?LOG_ERROR("Failed to write temp file ~s: ~w", [TempPath, WriteReason]),
                    {error, {write_failed, WriteReason}}
            end;
        {ok, {{_HttpVersion, StatusCode, StatusReason}, _Headers, _Body}} ->
            % HTTP error status
            ?LOG_ERROR("HTTP error ~w: ~s", [StatusCode, StatusReason]),
            {error, {http_error, StatusCode, StatusReason}};
        {error, HttpError} ->
            ?LOG_ERROR("HTTP request failed: ~w", [HttpError]),
            {error, {http_request_failed, HttpError}}
    end.
