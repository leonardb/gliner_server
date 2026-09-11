-module(gliner_cache).

%% API
-export([
    generate_pattern/2,
    try_match_pattern/2,
    add_to_cache/4
]).

-include_lib("kernel/include/logger.hrl").

-type pattern_entry() :: {re:mp(), binary()}.  % {CompiledPattern, PatternString}

%%====================================================================
%% API
%%====================================================================

%% Generate a regex pattern from GLiNER response
%% Input: Template text, GLiNER response entities
%% Output: {ok, {CompiledPattern, PatternString}} or {error, term()}
%% The pattern string is what gets returned on cache hits
%% Since all entities become (.*?) capture groups, we don't need to track positions
-spec generate_pattern(binary(), list()) -> {ok, pattern_entry()} | {error, term()}.
generate_pattern(Text, Entities) ->
    try
        % Extract unique entity texts
        UniqueTexts = lists:usort([maps:get(<<"text">>, E) || E <- Entities]),
        
        % Replace each unique entity text with (.*) capture group
        % Start with original text, replace entities one by one
        PatternStr = lists:foldl(fun(EntityText, Acc) ->
            binary:replace(Acc, EntityText, <<"(.*)">>, [global])
        end, Text, UniqueTexts),
        
        % Anchor pattern at both ends
        AnchoredPattern = <<"^", PatternStr/binary, "$">>,
        
        % Compile pattern
        case re:compile(AnchoredPattern) of
            {ok, CompiledPattern} ->
                {ok, {CompiledPattern, AnchoredPattern}};
            {error, CompileReason} ->
                ?LOG_WARNING("Failed to compile pattern ~s: ~w", [AnchoredPattern, CompileReason]),
                {error, {compile_failed, CompileReason}}
        end
    catch
        error:CatchReason ->
            {error, CatchReason}
    end.

%% Try to match text against a cached pattern
%% Returns {ok, PatternString} if match, or no_match
%% The PatternString can be reused for other texts with same structure
-spec try_match_pattern(binary(), pattern_entry()) -> {ok, binary()} | no_match.
try_match_pattern(Text, {CompiledPattern, PatternString}) ->
    case re:run(Text, CompiledPattern) of
        {match, _Captures} ->
            % Match successful, return the pattern string for reuse
            {ok, PatternString};
        nomatch ->
            no_match;
        {error, _Reason} ->
            no_match
    end.

%% Add pattern to cache, maintaining max size
%% Returns {UpdatedCache, NewCacheSize}
%% CurrentSize should be passed from state for O(1) calculation
-spec add_to_cache(pattern_entry(), list(), non_neg_integer(), pos_integer()) -> {list(), non_neg_integer()}.
add_to_cache(PatternEntry, Cache, CurrentSize, MaxSize) ->
    case CurrentSize < MaxSize of
        true ->
            % Cache not full yet, just prepend
            {[PatternEntry | Cache], CurrentSize + 1};
        false ->
            % Cache is full, replace oldest (remove last element, add at head)
            {[PatternEntry | lists:droplast(Cache)], MaxSize}
    end.

%%====================================================================
%% Internal functions
%%====================================================================
