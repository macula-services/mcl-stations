%% @doc The rows the directory is currently refusing to serve because a
%% stored raw record did not verify. A gauge, not an event count: keyed by
%% (row id, record type), so one corrupt record that stays corrupt reads
%% as one however many calls walk past it, and it clears the moment that
%% row's record verifies again. `list_stations' observes a failure and
%% forgets the row on a clean pass; the service's health reports the
%% aggregate, so a directory quietly dropping rows is degraded, never
%% silently green.
-module(station_record_drops).

-export([observe/2, forget/1, counts/0, reset/0]).

-define(TABLE, mcl_stations_record_drops).

%% @doc Record that `Key' (a row id and record type) is being refused for
%% `Reason' (its latest reason wins; the gauge counts keys, not failures).
-spec observe(term(), term()) -> ok.
observe(Id, Reason) ->
    _ = ensure(),
    true = ets:insert(?TABLE, {Id, Reason}),
    ok.

%% @doc The key serves again: drop it from the gauge.
-spec forget(term()) -> ok.
forget(Id) ->
    _ = ensure(),
    true = ets:delete(?TABLE, Id),
    ok.

%% @doc How many rows are being refused right now, per reason.
-spec counts() -> #{term() => pos_integer()}.
counts() ->
    _ = ensure(),
    lists:foldl(fun({_Id, Reason}, Acc) -> Acc#{Reason => maps:get(Reason, Acc, 0) + 1} end,
                #{}, ets:tab2list(?TABLE)).

%% @doc Clear the gauge; for tests and for an operator restart of the check.
-spec reset() -> ok.
reset() ->
    _ = ensure(),
    true = ets:delete_all_objects(?TABLE),
    ok.

%% A public named table created on first use; a concurrent creator losing
%% the race gets `badarg' and finds the winner's table already there.
ensure() ->
    case ets:info(?TABLE) of
        undefined -> create();
        _Info -> ?TABLE
    end.

create() ->
    try
        ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}, {read_concurrency, true}])
    catch
        error:badarg -> ?TABLE
    end.
