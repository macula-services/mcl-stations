%% @doc Drives station_read_model against a real, throwaway barrel_docdb
%% database opened by station_read_model:open/1 itself (read_model_fixture),
%% no mesh and no mcl_om:boot/1. Exercising barrel for real is what verifies
%% the API assumptions (put_doc's `<<"id">>' semantics, get_doc's `not_found',
%% fold_docs excluding deleted docs by default) rather than a guess at them.
-module(station_read_model_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    Dir = read_model_fixture:open(),
    Dir.

teardown(Dir) ->
    read_model_fixture:close(Dir).

node_id() -> crypto:strong_rand_bytes(32).

later() -> erlang:system_time(millisecond) + 600000.

%% `station_read_model:upsert_node_record/2' assumes its one real caller
%% (`ingest_node_records', fed by `macula_record:read_node_record/1')
%% always hands over the complete key set -- every field mandatory,
%% `undefined' for whichever weren't on the wire. `maps:get/2' with no
%% default is how that assumption is enforced: a map missing a key
%% entirely is a malformed caller, not an absent field. This helper
%% mirrors that shape so tests exercise the real contract instead of a
%% partial one `read_node_record/1' would never actually produce.
node_fields(Overrides) ->
    maps:merge(#{
        node_id => undefined, station_id => undefined, realms => [],
        capabilities => undefined, kind => undefined, hostname => undefined,
        endpoint => undefined, city => undefined, country => undefined,
        lat => undefined, lng => undefined, display_name => undefined,
        caps_hint => undefined, peers => undefined, version => undefined
    }, Overrides).

station_read_model_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun open_keeps_barrels_own_files_under_the_data_dir/1,
        fun open_again_reopens_rather_than_failing/1,
        fun upsert_node_record_creates_a_doc/1,
        fun upsert_node_record_omits_undefined_fields/1,
        fun upsert_node_record_derives_continent_from_country/1,
        fun upsert_station_endpoint_merges_onto_existing_node_doc/1,
        fun upsert_node_record_merges_onto_existing_endpoint_doc/1,
        fun retire_node_removes_the_doc_from_fold/1,
        fun retire_node_on_an_unseen_node_is_a_harmless_no_op/1,
        fun each_record_keeps_its_own_expiry/1,
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
    ok = station_read_model:upsert_node_record(node_fields(#{node_id => node_id(), capabilities => 0}),
                                               later()),
    ok = station_read_model:open(Dir),
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual(1, length(Rows)).

upsert_node_record_creates_a_doc(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => NodeId, hostname => <<"h1">>, city => <<"Leuven">>,
        country => <<"BE">>, lat => 50.8798, lng => 4.7005,
        capabilities => 0, kind => <<"station">>}), later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(<<"h1">>, maps:get(<<"hostname">>, Doc)),
     ?_assertEqual(<<"Leuven">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(<<"BE">>, maps:get(<<"country">>, Doc)),
     ?_assertEqual(<<"Europe">>, maps:get(<<"continent">>, Doc)),
     ?_assertEqual(50.8798, maps:get(<<"lat">>, Doc))].

upsert_node_record_omits_undefined_fields(_DbName) ->
    ok = station_read_model:upsert_node_record(node_fields(#{node_id => node_id(), capabilities => 0}), later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertNot(maps:is_key(<<"hostname">>, Doc)),
     ?_assertNot(maps:is_key(<<"city">>, Doc)),
     ?_assertNot(maps:is_key(<<"country">>, Doc)),
     ?_assertNot(maps:is_key(<<"continent">>, Doc)),
     ?_assertNot(maps:is_key(<<"lat">>, Doc))].

upsert_node_record_derives_continent_from_country(_DbName) ->
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => node_id(), country => <<"JP">>, capabilities => 0}), later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual(<<"Asia">>, maps:get(<<"continent">>, Doc)).

%% `version' is the station's own reported build, stamped by its
%% re-announce heartbeat.
upsert_node_record_captures_version_when_present(_DbName) ->
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => node_id(), capabilities => 0, version => <<"0.6.1">>}), later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual(<<"0.6.1">>, maps:get(<<"version">>, Doc)).

%% A node_record from a station whose heartbeat has not stamped a build yet
%% carries `version => undefined': omitted, like every other absent field.
upsert_node_record_omits_an_unreported_version(_DbName) ->
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => node_id(), capabilities => 0}), later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertNot(maps:is_key(<<"version">>, Doc)).

%% A station's node_record and station_endpoint arrive independently and
%% in either order -- this is the case the plan's own design calls out.
upsert_station_endpoint_merges_onto_existing_node_doc(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => NodeId, city => <<"Falkenstein">>, capabilities => 0}), later()),
    ok = station_read_model:upsert_station_endpoint(
           NodeId, #{quic_port => 4433, host_advertised => [<<"1.2.3.4">>]}, later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(<<"Falkenstein">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual([<<"1.2.3.4">>], maps:get(<<"host_advertised">>, Doc))].

upsert_node_record_merges_onto_existing_endpoint_doc(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_station_endpoint(
           NodeId, #{quic_port => 4433, host_advertised => []}, later()),
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => NodeId, city => <<"Nuremberg">>, capabilities => 0}), later()),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual(<<"Nuremberg">>, maps:get(<<"city">>, Doc))].

%% Exercises the exact path a graceful shutdown's tombstone drives:
%% ingest_node_records retires by node_id, and the doc must be gone from
%% fold immediately -- not lingering until any TTL.
retire_node_removes_the_doc_from_fold(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{node_id => NodeId, capabilities => 0}), later()),
    ok = station_read_model:retire_node(NodeId),
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual([], Rows).

retire_node_on_an_unseen_node_is_a_harmless_no_op(_DbName) ->
    ok = station_read_model:retire_node(node_id()),
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual([], Rows).

%% A station is live while ANY of its records is: node_record and
%% station_endpoint have different lifetimes and refresh independently.
each_record_keeps_its_own_expiry(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{node_id => NodeId, capabilities => 0}), 1000),
    ok = station_read_model:upsert_station_endpoint(
           NodeId, #{quic_port => 4433, host_advertised => []}, 2000),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(1000, maps:get(<<"node_record_expires_at">>, Doc)),
     ?_assertEqual(2000, maps:get(<<"endpoint_expires_at">>, Doc)),
     ?_assert(station_read_model:is_live(Doc, 1999)),
     ?_assertNot(station_read_model:is_live(Doc, 2000))].

%% to_wire/1 needs no database: it only reshapes a doc for the
%% list_stations reply. Text fields and host_advertised entries become
%% `{text, Bin}'; ids, the revision and numbers pass through untouched.
to_wire_tags_text_fields_and_leaves_ids_and_numbers_test() ->
    NodeId = node_id(),
    Doc = #{<<"id">> => binary:encode_hex(NodeId, lowercase), <<"node_id">> => NodeId,
            <<"_rev">> => <<"2-abc">>, <<"hostname">> => <<"station-de-falkenstein.macula.io">>,
            <<"city">> => <<"Falkenstein">>, <<"country">> => <<"DE">>,
            <<"continent">> => <<"Europe">>, <<"kind">> => <<"station">>,
            <<"version">> => <<"a1b2c3d">>, <<"lat">> => 50.4779, <<"lng">> => 12.3713,
            <<"capabilities">> => 0, <<"quic_port">> => 4433,
            <<"host_advertised">> => [<<"2a01:4f8::1">>, <<"5.6.7.8">>],
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
    Doc = #{<<"id">> => <<"ab">>, <<"node_id">> => node_id(), <<"quic_port">> => 4433,
            <<"host_advertised">> => []},
    ?assertEqual(Doc, station_read_model:to_wire(Doc)).
