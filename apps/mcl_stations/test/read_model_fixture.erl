%% @doc A throwaway station read model for the suites that need one, opened
%% exactly the way the service opens it (station_read_model:open/1), in a
%% fresh directory per test.
%%
%% The directory name carries wall-clock time as well as a unique integer:
%% `erlang:unique_integer/1' is unique only within one VM, and `rebar3 eunit'
%% starts a fresh VM per run, so an integer-only name could reopen a crashed
%% run's leftover files.
%%
%% It also builds the signed records the read model and list_stations take
%% now: real keys, real signatures, verified exactly as the mesh facade
%% verifies them, so a suite never feeds the read model a shape the ingest
%% path could not actually hand it.
-module(read_model_fixture).

-export([open/0, close/1]).
-export([profile/0, station_key/0, node_record/2, node_record/3, station_endpoint/3, signed/2]).

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

%% The profile production sets in config/sys.config.src; macula has none by
%% default and refuses to sign or verify without one.
profile() ->
    {ok, Profile} = macula_crypto_profile:configured(),
    Profile.

station_key() ->
    {ok, Key} = macula_node_keys:generate(identity, profile()),
    Key.

%% A record as the facade hands it over: signed, encoded, verified.
signed(Unsigned, Key) ->
    Signed = macula_record:sign(Unsigned, Key),
    {ok, Verified} = macula_record:verify(macula_record:encode(Signed), profile()),
    Verified.

node_record(Key, Opts) ->
    node_record(Key, Opts, #{}).

%% A station's own node_record: signed by `Key' about `Key''s node id,
%% which is the shape every station broadcasts. The optional third
%% argument carries constructor options (`ttl_ms' matters for expiry
%% tests); `Opts' carries the record's own fields (hostname, city, ...).
node_record(Key, Opts, CtorOpts) ->
    signed(macula_record:node_record(macula_node_keys:key_id(Key), [], 0,
                                     maps:merge(CtorOpts, Opts)), Key).

station_endpoint(Key, Fields, CtorOpts) ->
    {quic_port, Port} = lists:keyfind(quic_port, 1, Fields),
    Rest = lists:keydelete(quic_port, 1, Fields),
    signed(macula_record:station_endpoint(Port, maps:merge(CtorOpts, maps:from_list(Rest))), Key).
