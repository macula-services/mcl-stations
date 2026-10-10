%% @doc Drives station_read_model against a real, throwaway barrel_docdb
%% database opened by station_read_model:open/1 itself (read_model_fixture),
%% no mesh and no mcl_om:boot/1. Exercising barrel for real is what verifies
%% the API assumptions (put_doc's `<<"id">>' semantics, get_doc's `not_found',
%% fold_docs excluding deleted docs by default) rather than a guess at them.
%%
%% The writes go through real signed records (read_model_fixture), the same
%% shape ingest_node_records is handed by the mesh facade.
-module(station_read_model_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    ok = application:set_env(macula, crypto_profile, pq_hybrid),
    {ok, _} = application:ensure_all_started(barrel_docdb),
    _ = station_record_drops:reset(),
    Dir = read_model_fixture:open(),
    Dir.

teardown(Dir) ->
    read_model_fixture:close(Dir).


node_record(Key, Opts) ->
    read_model_fixture:node_record(Key, Opts).

node_record(Key, Opts, CtorOpts) ->
    read_model_fixture:node_record(Key, Opts, CtorOpts).

station_endpoint(Key, Fields, CtorOpts) ->
    read_model_fixture:station_endpoint(Key, Fields, CtorOpts).

key() -> read_model_fixture:station_key().

key_id(Key) -> macula_node_keys:key_id(Key).

docs() ->
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    Rows.

one_doc() ->
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    Doc.

station_read_model_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun open_keeps_barrels_own_files_under_the_data_dir/1,
        fun open_again_reopens_rather_than_failing/1,
        fun upsert_node_record_creates_a_doc/1,
        fun upsert_node_record_omits_undefined_fields/1,
        fun upsert_node_record_derives_continent_from_country/1,
        fun upsert_node_record_stores_its_raw_signed_record/1,
        fun upsert_node_record_replaces_its_own_fields/1,
        fun upsert_station_endpoint_leaves_node_record_fields_alone/1,
        fun upsert_node_record_leaves_endpoint_fields_alone/1,
        fun upsert_station_endpoint_replaces_its_own_fields/1,
        fun retire_node_removes_the_doc_from_fold/1,
        fun retire_node_on_an_unseen_node_is_a_harmless_no_op/1,
        fun each_record_keeps_its_own_expiry/1,
        fun a_part_serves_while_its_record_is_unexpired/1,
        fun a_part_is_expired_once_its_record_lapsed/1,
        fun upsert_node_record_captures_version_when_present/1,
        fun upsert_node_record_omits_an_unreported_version/1
    ]}.

%% barrel keeps a system database recording where each database lives, under
%% its `data_dir' app env, whose default is the RELATIVE "data/barrel_docdb":
%% in the container, /app/data, outside the service's data dir. open/1 points
%% it under the data dir before opening anything.
%% barrel opens that system database once per VM, so an earlier test in this
%% run may hold it open in its own directory: close it, and open the read
%% model again, as a fresh node would.
open_keeps_barrels_own_files_under_the_data_dir(Dir) ->
    _ = barrel_docdb:close_db(<<"_barrel_system">>),
    ok = barrel_docdb:close_db(station_read_model:db()),
    ok = station_read_model:open(Dir),
    Barrel = filename:join(Dir, "barrel_docdb"),
    [?_assertEqual({ok, Barrel}, application:get_env(barrel_docdb, data_dir)),
     ?_assert(filelib:is_dir(filename:join(Barrel, "_barrel_system"))),
     ?_assert(filelib:is_dir(filename:join(Dir, "mcl_stations")))].

%% A restart opens the same directory again; that must be the same database.
open_again_reopens_rather_than_failing(Dir) ->
    ok = station_read_model:upsert_node_record(node_record(key(), #{})),
    ok = station_read_model:open(Dir),
    ?_assertEqual(1, length(docs())).

upsert_node_record_creates_a_doc(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_node_record(node_record(Key, #{
        hostname => <<"h1">>, city => <<"Leuven">>,
        country => <<"BE">>, lat => 50.8798, lng => 4.7005,
        capabilities => 0, kind => <<"station">>})),
    Doc = one_doc(),
    [?_assertEqual(binary:encode_hex(key_id(Key), lowercase), maps:get(<<"id">>, Doc)),
     ?_assertEqual(key_id(Key), maps:get(<<"node_id">>, Doc)),
     ?_assertEqual(<<"h1">>, maps:get(<<"hostname">>, Doc)),
     ?_assertEqual(<<"Leuven">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(<<"BE">>, maps:get(<<"country">>, Doc)),
     ?_assertEqual(<<"Europe">>, maps:get(<<"continent">>, Doc)),
     ?_assertEqual(50.8798, maps:get(<<"lat">>, Doc))].

upsert_node_record_omits_undefined_fields(_Dir) ->
    ok = station_read_model:upsert_node_record(node_record(key(), #{capabilities => 0})),
    Doc = one_doc(),
    [?_assertNot(maps:is_key(<<"hostname">>, Doc)),
     ?_assertNot(maps:is_key(<<"city">>, Doc)),
     ?_assertNot(maps:is_key(<<"country">>, Doc)),
     ?_assertNot(maps:is_key(<<"continent">>, Doc)),
     ?_assertNot(maps:is_key(<<"lat">>, Doc))].

upsert_node_record_derives_continent_from_country(_Dir) ->
    ok = station_read_model:upsert_node_record(node_record(key(), #{country => <<"JP">>, capabilities => 0})),
    ?_assertEqual(<<"Asia">>, maps:get(<<"continent">>, one_doc())).

%% The row keeps the record's own signed bytes, so a client can verify it
%% instead of trusting this directory: what was stored verifies again and
%% is signed by the station's key.
upsert_node_record_stores_its_raw_signed_record(_Dir) ->
    Key = key(),
    Record = node_record(Key, #{city => <<"Milan">>}),
    ok = station_read_model:upsert_node_record(Record),
    Raw = maps:get(<<"node_record">>, one_doc()),
    [?_assertEqual(macula_record:encode(Record), Raw),
     ?_assertMatch({ok, #{key_id := _}}, macula_record:verify(Raw, read_model_fixture:profile()))].

%% A record type replaces its own fields: a field the new record does not
%% carry is cleared, never left behind from the record before it. The other
%% record type's fields are untouched.
upsert_node_record_replaces_its_own_fields(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_node_record(node_record(Key, #{city => <<"Leuven">>, capabilities => 0})),
    ok = station_read_model:upsert_station_endpoint(station_endpoint(Key, [{quic_port, 4433},
                                                                           {host_advertised, []}], #{})),
    ok = station_read_model:upsert_node_record(node_record(Key, #{capabilities => 0})),
    Doc = one_doc(),
    [?_assertNot(maps:is_key(<<"city">>, Doc)),
     ?_assertNot(maps:is_key(<<"continent">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc))].

%% A station's node_record and station_endpoint arrive independently and
%% in either order -- this is the case the plan's own design calls out.
%% Each write must leave the other type's fields alone.
upsert_station_endpoint_leaves_node_record_fields_alone(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_node_record(node_record(Key, #{city => <<"Falkenstein">>, capabilities => 0})),
    ok = station_read_model:upsert_station_endpoint(
           station_endpoint(Key, [{quic_port, 4433}, {host_advertised, [<<"1.2.3.4">>]}], #{})),
    Doc = one_doc(),
    [?_assertEqual(<<"Falkenstein">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual([<<"1.2.3.4">>], maps:get(<<"host_advertised">>, Doc))].

upsert_node_record_leaves_endpoint_fields_alone(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_station_endpoint(
           station_endpoint(Key, [{quic_port, 4433}, {host_advertised, []}], #{})),
    ok = station_read_model:upsert_node_record(node_record(Key, #{city => <<"Nuremberg">>, capabilities => 0})),
    Doc = one_doc(),
    [?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual(<<"Nuremberg">>, maps:get(<<"city">>, Doc))].

upsert_station_endpoint_replaces_its_own_fields(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_station_endpoint(
           station_endpoint(Key, [{quic_port, 4433}, {host_advertised, [<<"1.2.3.4">>]}], #{})),
    ok = station_read_model:upsert_station_endpoint(
           station_endpoint(Key, [{quic_port, 4434}, {host_advertised, [<<"5.6.7.8">>]}], #{})),
    Doc = one_doc(),
    {ok, Verified} = macula_record:verify(maps:get(<<"station_endpoint">>, Doc), read_model_fixture:profile()),
    [?_assertEqual(4434, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual([<<"5.6.7.8">>], maps:get(<<"host_advertised">>, Doc)),
     ?_assertEqual(4434, maps:get(quic_port, macula_record:read_station_endpoint(Verified)))].

%% Exercises the exact path a graceful shutdown's tombstone drives:
%% ingest_node_records retires by node_id, and the doc must be gone from
%% fold immediately -- not lingering until any TTL.
retire_node_removes_the_doc_from_fold(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_node_record(node_record(Key, #{capabilities => 0})),
    ok = station_read_model:retire_node(key_id(Key)),
    ?_assertEqual([], docs()).

retire_node_on_an_unseen_node_is_a_harmless_no_op(_Dir) ->
    ok = station_read_model:retire_node(key_id(key())),
    ?_assertEqual([], docs()).

%% A station is live while ANY of its records is: node_record and
%% station_endpoint have different lifetimes and refresh independently.
each_record_keeps_its_own_expiry(_Dir) ->
    Key = key(),
    Node = node_record(Key, #{capabilities => 0}, #{ttl_ms => 60000}),
    Endpoint = station_endpoint(Key, [{quic_port, 4433}, {host_advertised, []}], #{ttl_ms => 120000}),
    ok = station_read_model:upsert_node_record(Node),
    ok = station_read_model:upsert_station_endpoint(Endpoint),
    Doc = one_doc(),
    EndpointExpires = macula_record:expires_at(Endpoint),
    [?_assertEqual(macula_record:expires_at(Node), maps:get(<<"node_record_expires_at">>, Doc)),
     ?_assertEqual(EndpointExpires, maps:get(<<"endpoint_expires_at">>, Doc)),
     ?_assert(station_read_model:is_live(Doc, EndpointExpires - 1)),
     ?_assertNot(station_read_model:is_live(Doc, EndpointExpires))].

%% The serving accessor: an unexpired record yields its raw bytes and its
%% fields; nothing about the record's trust is decided here.
a_part_serves_while_its_record_is_unexpired(_Dir) ->
    Key = key(),
    Record = node_record(Key, #{city => <<"Paris">>, capabilities => 0}),
    ok = station_read_model:upsert_node_record(Record),
    Doc = one_doc(),
    Now = erlang:system_time(millisecond),
    {serve, Raw, Fields} = station_read_model:node_record_part(Doc, Now),
    [?_assertEqual(macula_record:encode(Record), Raw),
     ?_assertEqual(<<"Paris">>, maps:get(<<"city">>, Fields)),
     ?_assertEqual(absent, station_read_model:station_endpoint_part(Doc, Now))].

a_part_is_expired_once_its_record_lapsed(_Dir) ->
    Key = key(),
    ok = station_read_model:upsert_node_record(node_record(Key, #{capabilities => 0}, #{ttl_ms => 300})),
    Doc = one_doc(),
    timer:sleep(400),
    Now = erlang:system_time(millisecond),
    [?_assertEqual(expired, station_read_model:node_record_part(Doc, Now))].

%% `version' is the station's own reported build, stamped by its
%% re-announce heartbeat into the payload itself (there is no constructor
%% option for it: macula_station_announcer:inject_identity_metadata/2).
upsert_node_record_captures_version_when_present(_Dir) ->
    Key = key(),
    Unsigned = with_version(macula_record:node_record(key_id(Key), [], 0, #{capabilities => 0}),
                            <<"0.6.1">>),
    ok = station_read_model:upsert_node_record(read_model_fixture:signed(Unsigned, Key)),
    ?_assertEqual(<<"0.6.1">>, maps:get(<<"version">>, one_doc())).

%% A node_record from a station whose heartbeat has not stamped a build yet
%% carries no version field: omitted, like every other absent field.
upsert_node_record_omits_an_unreported_version(_Dir) ->
    ok = station_read_model:upsert_node_record(node_record(key(), #{capabilities => 0})),
    ?_assertNot(maps:is_key(<<"version">>, one_doc())).

with_version(#{payload := P} = Unsigned, Version) ->
    Unsigned#{payload := P#{{text, <<"version">>} => {text, Version}}}.

%% to_wire/1 needs no database: it only reshapes a doc for the
%% list_stations reply. Text fields and host_advertised entries become
%% `{text, Bin}'; ids, the revision and numbers pass through untouched.
to_wire_tags_text_fields_and_leaves_ids_and_numbers_test() ->
    NodeId = crypto:strong_rand_bytes(32),
    Doc = #{<<"id">> => binary:encode_hex(NodeId, lowercase), <<"node_id">> => NodeId,
            <<"_rev">> => <<"2-abc">>, <<"hostname">> => <<"station-de-falkenstein.macula.io">>,
            <<"city">> => <<"Falkenstein">>, <<"country">> => <<"DE">>,
            <<"continent">> => <<"Europe">>, <<"kind">> => <<"station">>,
            <<"version">> => <<"a1b2c3d">>, <<"lat">> => 50.4779, <<"lng">> => 12.3713,
            <<"capabilities">> => 0, <<"quic_port">> => 4433,
            <<"host_advertised">> => [<<"2a01:4f8::1">>, <<"5.6.7.8">>],
            <<"node_record">> => <<"raw-signed-bytes">>,
            <<"last_node_record_at">> => 1788355047886, <<"last_endpoint_at">> => 1788355047999},
    ?assertEqual(Doc#{<<"hostname">> => {text, <<"station-de-falkenstein.macula.io">>},
                      <<"city">> => {text, <<"Falkenstein">>},
                      <<"country">> => {text, <<"DE">>},
                      <<"continent">> => {text, <<"Europe">>},
                      <<"kind">> => {text, <<"station">>},
                      <<"version">> => {text, <<"a1b2c3d">>},
                      <<"host_advertised">> => [{text, <<"2a01:4f8::1">>}, {text, <<"5.6.7.8">>}]},
                 station_read_model:to_wire(Doc)).

to_wire_leaves_a_doc_without_text_fields_unchanged_test() ->
    Doc = #{<<"id">> => <<"ab">>, <<"node_id">> => crypto:strong_rand_bytes(32), <<"quic_port">> => 4433,
            <<"host_advertised">> => []},
    ?assertEqual(Doc, station_read_model:to_wire(Doc)).
