%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(gliner_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([single_request/1, sequential_requests/1, parallel_requests/1, response_id_matching/1, date_and_month_detection/1, financial_entity_detection/1, prefix_detection/1, expanded_financial_formats/1]).

suite() ->
    [{timetrap, {minutes, 20}}].

all() ->
    [sequential_requests, single_request, parallel_requests, response_id_matching, date_and_month_detection, financial_entity_detection, prefix_detection, expanded_financial_formats].

init_per_suite(Config) ->
    ct:log("Starting GLiNER test suite", []),
    
    % Start the application (which starts the supervisor and gen_server)
    case application:start(gliner_server) of
        ok ->
            ct:log("✓ gliner_server application started", []);
        {error, {already_started, gliner_server}} ->
            ct:log("✓ gliner_server application already started", []);
        AppError ->
            ct:log("✗ Failed to start application: ~w", [AppError]),
            throw({failed_to_start_app, AppError})
    end,
    
    % Log binary path for debugging
    BinaryPath = gliner_server:get_binary_path(),
    ct:log("Binary path: ~s", [BinaryPath]),
    ct:log("Binary exists: ~w", [filelib:is_file(BinaryPath)]),
    ct:log("Current working directory: ~s", [element(2, file:get_cwd())]),
    
    % Wait for the READY signal from the Rust binary
    % This signal indicates the model has been loaded successfully
    % Model download can take 30-60 seconds on first run
    ct:log("Waiting for READY signal from Rust binary (model loading, may take 1-3 minutes on first run)...", []),
    case wait_for_ready_signal(180, 500) of  % Wait up to 180*500=90000ms (1.5 minutes)
        ok ->
            ct:log("✓ Received READY signal - model is loaded and server is ready", []);
        ReadyError ->
            ct:log("✗ Failed to receive READY signal: ~w", [ReadyError]),
            throw({server_not_ready, ReadyError})
    end,
    
    % Verify process is registered
    case whereis(gliner_server) of
        undefined ->
            ct:log("✗ ERROR: gliner_server not found after receiving READY signal!", []),
            throw(gliner_server_disappeared);
        Pid ->
            ct:log("✓ Final verification: gliner_server registered as ~w", [Pid]),
            [{server_pid, Pid} | Config]
    end.

%% Helper: Wait for the READY signal from the Rust binary
wait_for_ready_signal(0, _Interval) ->
    {error, ready_signal_timeout};
wait_for_ready_signal(Attempts, Interval) ->
    case gliner_server:wait_ready(Interval) of
        ok ->
            ok;
        {error, not_ready} ->
            timer:sleep(Interval),
            wait_for_ready_signal(Attempts - 1, Interval);
        Error ->
            Error
    end.

end_per_suite(_Config) ->
    % Stop the application (which stops supervisor and gen_server)
    case application:stop(gliner_server) of
        ok ->
            ct:log("Application stopped successfully", []);
        {error, {not_started, gliner_server}} ->
            ct:log("Application was not running", []);
        Error ->
            ct:log("Error stopping application: ~w", [Error])
    end,
    ok.

%% Test 1: Single request processing
single_request(_Config) ->
    ct:log("TEST 1: Single Request - Basic entity extraction", []),
    
    % Verify server is still running
    case whereis(gliner_server) of
        undefined ->
            ct:log("✗ ERROR: gliner_server not found at test start", []),
            throw({error, gliner_server_missing});
        Pid ->
            ct:log("  gliner_server running as: ~w", [Pid])
    end,
    
    % Give system extra time to settle before first test
    timer:sleep(500),
    
    Text = <<"John Doe works at Microsoft in Seattle">>,
    
    ct:log("  Calling gliner_server:analyze/1...", []),
    try gliner_server:analyze(Text) of
        {ok, Response} ->
            ct:log("  Response received: ~w keys", [map_size(Response)]),
            
            Count = maps:get(<<"count">>, Response),
            Entities = maps:get(<<"entities">>, Response),
            
            case Count > 0 of
                true -> ok;
                false -> throw("Expected entities but got none")
            end,
            
            case length(Entities) > 0 of
                true -> ok;
                false -> throw("Expected entity list but got empty")
            end,
            
            lists:foreach(fun(Entity) ->
                Type = maps:get(<<"entity_type">>, Entity),
                EntityText = maps:get(<<"text">>, Entity),
                Score = maps:get(<<"score">>, Entity),
                ct:log("  Found: ~s (~s) ~.2f%", [EntityText, Type, Score * 100])
            end, Entities),
            
            ct:log("✓ Single request test passed (~w entities)", [Count]),
            ok
    catch
        Error:Reason ->
            ct:log("✗ ERROR in single_request: ~w:~w", [Error, Reason]),
            throw({test_failed, single_request, Error, Reason})
    end.

%% Test 2: Sequential requests (same connection)
sequential_requests(_Config) ->
    ct:log("TEST 2: Sequential Requests - Multiple requests on same connection", []),
    
    Requests = [
        {<<"req1">>, <<"John Doe">>},
        {<<"req2">>, <<"Microsoft">>},
        {<<"req3">>, <<"Seattle, Washington">>},
        {<<"req4">>, <<"Sarah Johnson works for Google">>}
    ],
    
    try
        Results = lists:map(fun({ReqId, TestText}) ->
            {ok, Response} = gliner_server:analyze(TestText),
            Count = maps:get(<<"count">>, Response),
            ct:log("  ~s: '~s' -> ~w entities", [ReqId, TestText, Count]),
            Count > 0
        end, Requests),
        
        case lists:all(fun(X) -> X end, Results) of
            true -> 
                ct:log("✓ Sequential requests test passed", []),
                ok;
            false -> 
                throw({test_failed, "Some requests returned no entities"})
        end
    catch
        Error:Reason ->
            ct:log("✗ ERROR in sequential_requests: ~w:~w", [Error, Reason]),
            throw({test_failed, sequential_requests, Error, Reason})
    end.

%% Test 3: Parallel concurrent requests
parallel_requests(_Config) ->
    ct:log("TEST 3: Parallel Requests - 4 concurrent requests", []),
    
    Requests = [
        {<<"parallel1">>, <<"John Doe works at Microsoft">>},
        {<<"parallel2">>, <<"Sarah Johnson at Google">>},
        {<<"parallel3">>, <<"John Doe works at Microsoft in Seattle">>},
        {<<"parallel4">>, <<"Dr. Jane Smith, Chief Executive Officer, works at Apple Inc., located in Cupertino, California">>}
    ],
    
    try
        ParallelStart = erlang:system_time(millisecond),
        
        % Send all requests in parallel
        Pids = lists:map(fun({ReqId, TestText}) ->
            spawn(fun() ->
                try
                    {ok, Response} = gliner_server:analyze(TestText),
                    Count = maps:get(<<"count">>, Response),
                    ct:log("  ~s: ~w entities", [ReqId, Count])
                catch E:R ->
                    ct:log("  ERROR in ~s: ~w:~w", [ReqId, E, R])
                end
            end)
        end, Requests),
        
        % Wait for all to complete
        lists:foreach(fun(Pid) ->
            monitor(process, Pid),
            receive
                {'DOWN', _, process, Pid, _} -> ok
            after 60000 -> throw({timeout, parallel_requests})
            end
        end, Pids),
        
        ParallelDuration = erlang:system_time(millisecond) - ParallelStart,
        ct:log("✓ Parallel requests test passed (~.2fs)", [ParallelDuration / 1000]),
        ok
    catch
        Error:Reason ->
            ct:log("✗ ERROR in parallel_requests: ~w:~w", [Error, Reason]),
            throw({test_failed, parallel_requests, Error, Reason})
    end.

%% Test 4: Response ID matching (verify unordered processing doesn't break ID correlation)
response_id_matching(_Config) ->
    ct:log("TEST 4: Response ID Matching - Unordered processing validation", []),
    
    Requests = [
        {<<"id_short">>, <<"John">>},
        {<<"id_medium">>, <<"John Doe works at Microsoft">>},
        {<<"id_long">>, <<"Dr. Jane Smith, Chief Executive Officer at Apple Inc., based in Cupertino, California">>}
    ],
    
    try
        Results = lists:map(fun({ReqId, TestText}) ->
            {ok, Response} = gliner_server:analyze(TestText),
            Count = maps:get(<<"count">>, Response),
            ct:log("  Request '~s': entities=~w", [ReqId, Count]),
            {ReqId, Count}
        end, Requests),
        
        % Verify all IDs were processed
        case length(Results) =:= length(Requests) of
            true -> 
                ct:log("✓ Response ID matching test passed", []),
                ok;
            false -> 
                throw({test_failed, "Not all response IDs matched"})
        end
    catch
        Error:Reason ->
            ct:log("✗ ERROR in response_id_matching: ~w:~w", [Error, Reason]),
            throw({test_failed, response_id_matching, Error, Reason})
    end.

%% Test 5: Date and Month Detection
date_and_month_detection(_Config) ->
    ct:log("TEST 5: Date and Month Detection - Verify temporal entity extraction", []),
    
    TestCases = [
        {<<"date_formats">>, <<"The meeting is on January 15, 2025 or 2025-01-15 or 01/15/2025">>},
        {<<"short_dates">>, <<"Reminder: 01/15 and 12/25 and 03-20 are important dates">>},
        {<<"months">>, <<"Events in January, February, March and Dec are scheduled">>},
        {<<"mixed">>, <<"John Doe called on December 25, 2024 about the project due March 31, 2025">>},
        {<<"with_entities">>, <<"Sarah from Microsoft contacted us on January 15, 2025 in Seattle">>}
    ],
    
    try
        Results = lists:map(fun({TestId, TestText}) ->
            {ok, Response} = gliner_server:analyze(TestText),
            Count = maps:get(<<"count">>, Response),
            Entities = maps:get(<<"entities">>, Response),
            
            % Filter for date and month entities
            TemporalEntities = lists:filter(fun(Entity) ->
                Type = maps:get(<<"entity_type">>, Entity),
                (Type =:= <<"date">>) orelse (Type =:= <<"month">>)
            end, Entities),
            
            TemporalCount = length(TemporalEntities),
            ct:log("  ~s: ~w total entities, ~w temporal (dates/months)", [TestId, Count, TemporalCount]),
            
            % Log detected temporal entities
            lists:foreach(fun(Entity) ->
                Text = maps:get(<<"text">>, Entity),
                Type = maps:get(<<"entity_type">>, Entity),
                Score = maps:get(<<"score">>, Entity),
                ct:log("    - ~s (~s) confidence: ~.2f%", [Text, Type, Score * 100])
            end, TemporalEntities),
            
            TemporalCount > 0
        end, TestCases),
        
        case lists:all(fun(X) -> X end, Results) of
            true -> 
                ct:log("✓ Date and month detection test passed", []),
                ok;
            false -> 
                throw({test_failed, "Some test cases did not detect dates/months"})
        end
    catch
        Error:Reason ->
            ct:log("✗ ERROR in date_and_month_detection: ~w:~w", [Error, Reason]),
            throw({test_failed, date_and_month_detection, Error, Reason})
    end.

%% Test 6: Financial Entity Detection (dollar amounts and payment rates)
financial_entity_detection(_Config) ->
    ct:log("TEST 6: Financial Entity Detection - Verify dollar amounts and payment rates", []),
    
    TestCases = [
        {<<"dollar_amounts">>, <<"The project costs $1,500 or about 2000 dollars for the work">>},
        {<<"hourly_rates">>, <<"The contractor charges $25/hour or 30 per hour for skilled work">>},
        {<<"daily_rates">>, <<"The consultant's daily rate is $300/day or 400 per day">>},
        {<<"monthly_rates">>, <<"Monthly rate: $2,500/month or 3000 mo, with annual contract worth $30,000">>},
        {<<"mixed_financial">>, <<"John earns $50,000 annually at $35/hr, daily consulting rate is $280/d">>},
        {<<"large_amounts">>, <<"The contract is worth $2.5M and includes $10K upfront payment">>},
        {<<"with_entities">>, <<"Sarah works for Apple at $45/hour with daily rates of $350/day and monthly contract at $5000/mo">>}
    ],
    
    try
        Results = lists:map(fun({TestId, TestText}) ->
            {ok, Response} = gliner_server:analyze(TestText),
            Count = maps:get(<<"count">>, Response),
            Entities = maps:get(<<"entities">>, Response),
            
            % Filter for financial entities
            FinancialEntities = lists:filter(fun(Entity) ->
                Type = maps:get(<<"entity_type">>, Entity),
                (Type =:= <<"dollar_amount">>) orelse (Type =:= <<"payment_rate">>)
            end, Entities),
            
            FinancialCount = length(FinancialEntities),
            ct:log("  ~s: ~w total entities, ~w financial", [TestId, Count, FinancialCount]),
            
            % Log detected financial entities
            lists:foreach(fun(Entity) ->
                Text = maps:get(<<"text">>, Entity),
                Type = maps:get(<<"entity_type">>, Entity),
                Score = maps:get(<<"score">>, Entity),
                ct:log("    - ~s (~s) confidence: ~.2f%", [Text, Type, Score * 100])
            end, FinancialEntities),
            
            FinancialCount > 0
        end, TestCases),
        
        case lists:all(fun(X) -> X end, Results) of
            true -> 
                ct:log("✓ Financial entity detection test passed", []),
                ok;
            false -> 
                throw({test_failed, "Some test cases did not detect financial entities"})
        end
    catch
        Error:Reason ->
            ct:log("✗ ERROR in financial_entity_detection: ~w:~w", [Error, Reason]),
            throw({test_failed, financial_entity_detection, Error, Reason})
    end.

%% Test 7: Prefix Detection (alphanumeric prefixes followed by colon)
prefix_detection(_Config) ->
    ct:log("TEST 7: Prefix Detection - Verify prefix extraction", []),
    
    TestCases = [
        {<<"simple_prefix">>, <<"ID123: John Doe works at Microsoft">>},
        {<<"word_prefix">>, <<"PREFIX: some text here">>},
        {<<"case_id">>, <<"CASE001: Sarah contacted about renewal">>},
        {<<"letter_prefix">>, <<"REQ: Hiring for senior developer">>}
    ],
    
    try
        Results = lists:map(fun({TestId, TestText}) ->
            {ok, Response} = gliner_server:analyze(TestText),
            Count = maps:get(<<"count">>, Response),
            Entities = maps:get(<<"entities">>, Response),
            
            ct:log("  ~s: total ~w entities", [TestId, Count]),
            
            % Log all entities for debugging
            lists:foreach(fun(Entity) ->
                Text = maps:get(<<"text">>, Entity),
                Type = maps:get(<<"entity_type">>, Entity),
                ct:log("    * ~s (~s)", [Text, Type])
            end, Entities),
            
            % Filter for prefix entities
            PrefixEntities = lists:filter(fun(Entity) ->
                Type = maps:get(<<"entity_type">>, Entity),
                Type =:= <<"prefix">>
            end, Entities),
            
            PrefixCount = length(PrefixEntities),
            ct:log("  ~s: Found ~w prefixes", [TestId, PrefixCount]),
            
            % Log prefix entities
            lists:foreach(fun(Entity) ->
                Text = maps:get(<<"text">>, Entity),
                Score = maps:get(<<"score">>, Entity),
                ct:log("    ✓ prefix: ~s (~.2f%)", [Text, Score * 100])
            end, PrefixEntities),
            
            PrefixCount > 0
        end, TestCases),
        
        case lists:all(fun(X) -> X end, Results) of
            true -> 
                ct:log("✓ Prefix detection test passed", []),
                ok;
            false -> 
                throw({test_failed, "Some test cases did not detect prefixes"})
        end
    catch
        Error:Reason ->
            ct:log("✗ ERROR in prefix_detection: ~w:~w", [Error, Reason]),
            throw({test_failed, prefix_detection, Error, Reason})
    end.

%% Test 8: Expanded Financial Formats (without $, amounts with +, extended time units)
expanded_financial_formats(_Config) ->
    ct:log("TEST 8: Expanded Financial Formats - Verify new rate and amount patterns", []),
    
    TestCases = [
        {<<"rates_without_dollar">>, <<"25/hr for basic work, 50/hr for expert">>},
        {<<"weekly_rates">>, <<"Weekly rate: 1000/week or $1200/w is typical">>},
        {<<"yearly_rates">>, <<"Yearly rates: 50000/year or $60000/yr are negotiable">>},
        {<<"minute_rates">>, <<"Charged at 2/min or $3/minute for short consultations">>},
        {<<"amounts_with_plus">>, <<"Salary range is 80,000+ for junior or 150,000+ for senior">>},
        {<<"mixed_expanded">>, <<"Rate: 30/hr, weekly 1200/w, monthly 5000/month, or annual 60000/year, salary 100,000+">>},
        {<<"with_entities">>, <<"John from Microsoft available at 45/hr, Sarah from Google at 1500/week, or annual contract at $80000/year">>}
    ],
    
    try
        Results = lists:map(fun({TestId, TestText}) ->
            {ok, Response} = gliner_server:analyze(TestText),
            Count = maps:get(<<"count">>, Response),
            Entities = maps:get(<<"entities">>, Response),
            
            % Filter for financial entities
            FinancialEntities = lists:filter(fun(Entity) ->
                Type = maps:get(<<"entity_type">>, Entity),
                (Type =:= <<"dollar_amount">>) orelse (Type =:= <<"payment_rate">>)
            end, Entities),
            
            FinancialCount = length(FinancialEntities),
            ct:log("  ~s: ~w total entities, ~w financial", [TestId, Count, FinancialCount]),
            
            % Log detected financial entities
            lists:foreach(fun(Entity) ->
                Text = maps:get(<<"text">>, Entity),
                Type = maps:get(<<"entity_type">>, Entity),
                Score = maps:get(<<"score">>, Entity),
                ct:log("    - ~s (~s) confidence: ~.2f%", [Text, Type, Score * 100])
            end, FinancialEntities),
            
            FinancialCount > 0
        end, TestCases),
        
        case lists:all(fun(X) -> X end, Results) of
            true -> 
                ct:log("✓ Expanded financial formats test passed", []),
                ok;
            false -> 
                throw({test_failed, "Some test cases did not detect expanded financial formats"})
        end
    catch
        Error:Reason ->
            ct:log("✗ ERROR in expanded_financial_formats: ~w:~w", [Error, Reason]),
            throw({test_failed, expanded_financial_formats, Error, Reason})
    end.
