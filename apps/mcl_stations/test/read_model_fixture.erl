%% @doc A throwaway station read model for the suites that need one, opened
%% exactly the way the service opens it (station_read_model:open/1), in a
%% fresh directory per test.
%%
%% The directory name carries wall-clock time as well as a unique integer:
%% `erlang:unique_integer/1' is unique only within one VM, and `rebar3 eunit'
%% starts a fresh VM per run, so an integer-only name could reopen a crashed
%% run's leftover files.
-module(read_model_fixture).

-export([open/0, close/1]).

open() ->
    Dir = filename:join(filename:basedir(user_cache, "mcl-stations-test"),
                        integer_to_list(erlang:system_time(microsecond)) ++ "_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    ok = station_read_model:open(Dir),
    Dir.

close(Dir) ->
    ok = barrel_docdb:delete_db(station_read_model:db()),
    _ = file:del_dir_r(Dir),
    ok.
