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
%% Uses non-greedy (.*?) capture groups to prevent over-matching
-spec generate_pattern(binary(), list()) -> {ok, pattern_entry()} | {error, term()}.
generate_pattern(Text, Entities) ->
    try
        % Extract unique entity texts
        UniqueTexts = lists:usort([maps:get(<<"text">>, E) || E <- Entities]),
        
        % Sort by length (longest first) to prevent partial replacements
        % Example: if we have ["New York", "New York City"], replace "New York City" first
        SortedByLength = lists:sort(fun(A, B) -> byte_size(B) =< byte_size(A) end, UniqueTexts),
        
        % Replace each unique entity text with (.*?) non-greedy capture group
        % Start with original text, replace entities one by one (longest first)
        PatternStr = lists:foldl(fun(EntityText, Acc) ->
            binary:replace(Acc, EntityText, <<"(.*?)">>, [global])
        end, Text, SortedByLength),
        
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
%% Validates that captures look reasonable (don't contain excessive text)
-spec try_match_pattern(binary(), pattern_entry()) -> {ok, binary()} | no_match.
try_match_pattern(Text, {CompiledPattern, PatternString}) ->
    case re:run(Text, CompiledPattern, [{capture, all_but_first, binary}]) of
        {match, Captures} ->
            % Match successful, now validate that captures are reasonable
            % Reject if any capture contains newlines or excessive punctuation
            case validate_captures(Captures) of
                true ->
                    {ok, PatternString};
                false ->
                    no_match
            end;
        nomatch ->
            no_match;
        {error, _Reason} ->
            no_match
    end.

%% Validate that captured text looks like entity text (no newlines, no excessive text)
%% Rejects captures containing markup patterns like {{, newlines, or URLs
-spec validate_captures(list(binary())) -> boolean().
validate_captures(Captures) ->
    lists:all(fun validate_capture/1, Captures).

%% Check a single capture - reject if it contains suspicious patterns
-spec validate_capture(binary()) -> boolean().
validate_capture(Capture) ->
    % Reject if contains template/markup patterns
    not (binary:match(Capture, <<"{{">>) =/= nomatch orelse
         binary:match(Capture, <<"}}">>) =/= nomatch orelse
         binary:match(Capture, <<"http">>) =/= nomatch orelse
         binary:match(Capture, <<"\n">>) =/= nomatch orelse
         % Reject if contains sentence endings or multiple periods
         (length(binary:split(Capture, <<".">>)) - 1) > 1).

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
