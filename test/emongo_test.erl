-module(emongo_test).
-include("emongo.hrl").
-include("emongo_test.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(NUM_PROCESSES,     100).
-define(NUM_TESTS_PER_PID, 500).
-define(POOL,              pool1).
-define(POOL_SIZE,         10).
-define(COLL,              <<"test">>).
-define(TIMEOUT,           60000).
-define(OUT(F, D),         ?debugFmt(F, D)).
-define(FIND_OPTIONS,      [?USE_PRIMARY]).

setup() ->
  ensure_started(sasl),
  ensure_started(emongo),
  emongo:add_pool(?POOL, "localhost", 27017, "testdatabase", ?POOL_SIZE),
  emongo:delete_sync(?POOL, ?COLL),
  ok.

cleanup(_) ->
  emongo:drop_database(?POOL),
  ok.

clear_coll() ->
  emongo:delete_sync(?POOL, ?COLL).

run_test_() ->
  [{setup,
    fun setup/0,
    fun cleanup/1,
    [
      fun test_upsert/0,
      fun test_fetch_collections/0,
      fun test_timing/0,
      fun test_drop_collection/0,
      fun test_drop_database/0,
      fun test_upsert/0, % rerun upsert to make sure we can still do our work
      fun test_empty_sel_with_orderby/0,
      fun test_count/0,
      fun test_encoding_performance/0,
      {timeout, ?TIMEOUT div 1000, [fun test_performance/0]}
    ]
  }].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

test_upsert() ->
  ?OUT("Testing upsert", []),
  Selector = [{<<"_id">>, <<"upsert_test">>}],
  UpsertRes1 = emongo:update_sync(?POOL, ?COLL, Selector,
                                  [{"$set", [{"data", 1}]}], true),
  ?assertEqual(ok, UpsertRes1),
  Find1 = emongo:find_all(?POOL, ?COLL, Selector, ?FIND_OPTIONS),
  ?assertEqual([Selector ++ [{<<"data">>, 1}]], Find1),

  UpsertRes2 = emongo:update_sync(?POOL, ?COLL, Selector,
                                  [{"$set", [{"data", 2}]}], true),
  ?assertEqual(ok, UpsertRes2),
  Find2 = emongo:find_all(?POOL, ?COLL, Selector, ?FIND_OPTIONS),
  ?assertEqual([Selector ++ [{<<"data">>, 2}]], Find2),
  clear_coll(),
  ?OUT("Test passed", []).

test_fetch_collections() ->
  ?OUT("Testing fetch collections", []),
  [<<"system.indexes">>, ?COLL] = lists:sort(emongo:get_collections(?POOL, ?FIND_OPTIONS)),
  ?OUT("Test passed", []).

test_timing() ->
  ?OUT("Testing timing", []),
  emongo:clear_timing(),
  run_single_test(1, 1),
  ?OUT("DB Total Time: ~p usec",  [emongo:total_db_time_usec()]),
  ?OUT("DB Timing Breakdown: ~p", [emongo:db_timing()]),
  ?OUT("DB Queue Lengths: ~p",    [emongo:queue_lengths()]),
  ?OUT("Test passed", []).

test_drop_collection() ->
  ?OUT("Testing drop collection", []),
  ok = emongo:drop_collection(?POOL, ?COLL),
  ?assertEqual(false, lists:member(?COLL, emongo:get_collections(?POOL, ?FIND_OPTIONS))),
  ?OUT("Test passed", []).

test_drop_database() ->
  ?OUT("Testing drop database", []),
  ok = emongo:drop_database(?POOL),
  ?OUT("Test passed", []).

test_empty_sel_with_orderby() ->
  ?OUT("Testing empty selector with orderby option", []),
  emongo:insert_sync(?POOL, ?COLL, [[{<<"a">>, 2}],
                                    [{<<"a">>, 1}]]),
  Res = emongo:find_all(?POOL, ?COLL, [], [{fields, [{<<"_id">>, 0}]}, {orderby, [{<<"a">>, 1}]} | ?FIND_OPTIONS]),
  ?assertEqual([[{<<"a">>, 1}],
                [{<<"a">>, 2}]], Res),
  clear_coll(),
  ?assertEqual([], emongo:find_all(?POOL, ?COLL, [], ?FIND_OPTIONS)),
  ?OUT("Test passed", []).

test_count() ->
  ?OUT("Testing count", []),
  emongo:insert_sync(?POOL, ?COLL, [[{<<"a">>, 1}], [{<<"a">>, 2}], [{<<"a">>, 3}], [{<<"a">>, 4}], [{<<"a">>, 5}]]),
  %?OUT("Resp = ~p", [emongo:count(?POOL, ?COLL, [{<<"$or">>, [[{<<"a">>, [{lte, 2}]}], [{<<"a">>, [{gte, 4}]}]]}],
  %                                [response_options])]),
  ?assertEqual(5, emongo:count(?POOL, ?COLL, [], ?FIND_OPTIONS)),
  ?assertEqual(3, emongo:count(?POOL, ?COLL, [{<<"a">>, [{lte, 3}]}], ?FIND_OPTIONS)),
  ?assertEqual(2, emongo:count(?POOL, ?COLL, [{<<"a">>, [{gt,  3}]}], ?FIND_OPTIONS)),
  ?assertEqual(4, emongo:count(?POOL, ?COLL, [{<<"$or">>,  [[{<<"a">>, [{lte, 2}]}], [{<<"a">>, [{gte, 4}]}]]}],
                               ?FIND_OPTIONS)),
  ?assertEqual(3, emongo:count(?POOL, ?COLL, [{<<"$and">>, [[{<<"a">>, [{gte, 2}]}], [{<<"a">>, [{lte, 4}]}]]}],
                               ?FIND_OPTIONS)),
  clear_coll(),
  ?OUT("Test passed", []).

test_encoding_performance() ->
  ?OUT("Testing encoding performance", []),
  {EncodeTime, ok} = timer:tc(fun() ->
    lists:foreach(fun(_) ->
      <<_/binary>> = emongo_bson:encode(?REALLY_BIG_DOCUMENT)
    end, lists:seq(1, 1000))
  end),
  ?OUT("Encoding a really big document 1000 times took ~p microseconds", [EncodeTime]),
  {WriteTime, ok} = timer:tc(fun() ->
    lists:foreach(fun(_) ->
      emongo:insert_sync(?POOL, ?COLL, ?REALLY_BIG_DOCUMENT)
    end, lists:seq(1, 1000))
  end),
  ?OUT("Encoding and writing a really big document to DB 1000 times took ~p microseconds", [WriteTime]),
  clear_coll(),
  ?OUT("Test passed", []).

test_performance() ->
  ?OUT("Testing performance.", []),
  Start = cur_time_ms(),
  Ref = make_ref(),
  start_processes(Ref),
  block_until_done(Ref),
  clear_coll(),
  End = cur_time_ms(),
  ?OUT("Test passed in ~p ms\n", [End - Start]).

start_processes(Ref) ->
  Pid = self(),
  lists:foreach(fun(X) ->
    proc_lib:spawn(fun() ->
      lists:map(fun(Y) ->
        run_single_test(X, Y)
      end, lists:seq(1, ?NUM_TESTS_PER_PID)),
      Pid ! {Ref, done}
    end)
  end, lists:seq(1, ?NUM_PROCESSES)).

run_single_test(X, Y) ->
  Num = (X bsl 16) bor Y, % Make up a unique number for this run
  Selector = [{<<"_id">>, Num}],
  try
    IRes = emongo:insert_sync(?POOL, ?COLL, Selector, [response_options]),
    ok = check_result("insert_sync", IRes, 0),

    [FMRes] = emongo:find_and_modify(?POOL, ?COLL, Selector,
      [{<<"$set">>, [{<<"fm">>, Num}]}], [{new, true}]),
    FMVal = proplists:get_value(<<"value">>, FMRes),
    ?assertEqual(Selector ++ [{<<"fm">>, Num}], FMVal),

    URes = emongo:update_sync(?POOL, ?COLL, Selector,
      [{<<"$set">>, [{<<"us">>, Num}]}], false, [response_options]),
    ok = check_result("update_sync", URes, 1),

    FARes = emongo:find_all(?POOL, ?COLL, Selector, ?FIND_OPTIONS),
    ?assertEqual([Selector ++ [{<<"fm">>, Num}, {<<"us">>, Num}]], FARes),

    DRes = emongo:delete_sync(?POOL, ?COLL, Selector, [response_options]),
    ok = check_result("delete_sync", DRes, 1)
  catch _:E ->
    ?OUT("Exception occurred for test ~.16b: ~p\n~p\n",
              [Num, E, erlang:get_stacktrace()]),
    throw(test_failed)
  end.

check_result(Desc,
             {response, _,_,_,_,_, [List]},
             ExpectedN) when is_list(List) ->
  {_, Err} = lists:keyfind(<<"err">>, 1, List),
  {_, N}   = lists:keyfind(<<"n">>,   1, List),
  if Err == undefined, N == ExpectedN -> ok;
  true ->
    ?OUT("Unexpected result for ~p: Err = ~p; N = ~p", [Desc, Err, N]),
    throw({error, invalid_db_response})
  end.

block_until_done(Ref) ->
  block_until_done(Ref, 0).

block_until_done(_, ?NUM_PROCESSES) -> ok;
block_until_done(Ref, NumDone) ->
  ToAdd =
    receive {Ref, done} -> 1
    after 1000 ->
      ?OUT("DB Queue Lengths: ~p", [emongo:queue_lengths()]),
      0
    end,
  block_until_done(Ref, NumDone + ToAdd).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

ensure_started(App) ->
  case application:start(App) of
    ok -> ok;
    {error, {already_started, App}} -> ok
  end.

cur_time_ms() ->
  {MegaSec, Sec, MicroSec} = erlang:now(),
  MegaSec * 1000000000 + Sec * 1000 + erlang:round(MicroSec / 1000).
