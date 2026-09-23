%% @doc Drives ingest_node_records' `handle_info/2' directly with real,
%% signed macula 12 records -- no mesh, no macula:subscribe_records/3,
%% just the exact messages try_connect/2's own subscription callbacks send
%% to `self()'. Same throwaway-read-model rationale as
%% station_read_model_tests: this verifies that `read_node_record/1',
%% `read_station_endpoint/1' and `read_tombstone/1' field extraction and
%% the key-id join between the three are wired correctly, not assumed.
%%
%% Every record is handed over VERIFIED, the way the macula 12 facade
%% delivers it: `find_records_by_type/2' and `subscribe_records/3' verify
%% under the node's crypto profile and drop what fails, so a tampered
%% record never reaches this process and there is no verify step here to
%% test.
-module(ingest_node_records_tests).

-include_lib("eunit/include/eunit.hrl").

%% The profile production sets in config/sys.config.src; macula has none
%% by default and refuses to sign or verify without one.
setup() ->
    ok = application:set_env(macula, crypto_profile, pq_hybrid),
    {ok, _} = application:ensure_all_started(barrel_docdb),
    Dir = read_model_fixture:open(),
    Dir.

teardown(Dir) ->
    read_model_fixture:close(Dir).

docs() ->
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    Rows.

profile() ->
    {ok, Profile} = macula_crypto_profile:configured(),
    Profile.

station_key() ->
    {ok, Key} = macula_node_keys:generate(identity, profile()),
    Key.

%% A record as the facade hands it over: signed, encoded, verified.
verified(Unsigned, Key) ->
    Signed = macula_record:sign(Unsigned, Key),
    {ok, Verified} = macula_record:verify(macula_record:encode(Signed), profile()),
    Verified.

node_record(Key, Opts) ->
    verified(macula_record:node_record(macula_node_keys:key_id(Key), [], 0, Opts), Key).

%% A station's announcer stamps its build into the payload itself, as a text
%% field `node_record/4' has no option for (macula_station_announcer's
%% inject_identity_metadata/2); `read_node_record/1' reads it back.
node_record_with_version(Key, Opts, Version) ->
    #{payload := P} = Unsigned = macula_record:node_record(macula_node_keys:key_id(Key), [], 0, Opts),
    verified(Unsigned#{payload := P#{{text, <<"version">>} => {text, Version}}}, Key).

station_endpoint(Key) ->
    verified(macula_record:station_endpoint(4433, #{host_advertised => [<<"2a01:4f8::1">>]}),
             Key).

ingest(Message) ->
    {noreply, state} = ingest_node_records:handle_info(Message, state),
    ok.

ingest_node_records_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun a_node_record_is_projected_under_its_key_id/1,
        fun a_station_endpoint_merges_onto_the_node_doc_by_key_id/1,
        fun a_station_endpoint_that_lands_first_is_joined_by_the_node_record/1,
        fun a_graceful_shutdown_tombstone_retires_the_station/1,
        fun a_tombstone_withdrawing_an_endpoint_leaves_the_station_listed/1
    ]}.

a_node_record_is_projected_under_its_key_id(_) ->
    Key = station_key(),
    Record = node_record_with_version(Key, #{city => <<"Milan">>}, <<"0.6.1">>),
    ok = ingest({node_record, Record}),
    [Doc] = docs(),
    [?_assertEqual(<<"Milan">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(macula_record:expires_at(Record), maps:get(<<"node_record_expires_at">>, Doc)),
     ?_assertEqual(<<"0.6.1">>, maps:get(<<"version">>, Doc)),
     ?_assertEqual(macula_node_keys:key_id(Key), maps:get(<<"node_id">>, Doc))].

%% The endpoint record's `key' is the station's full public key, not its
%% 32-byte id, so the join has to go through `macula_record:key_id/1'. A
%% join on `key' would file the endpoint under a second, geo-less doc.
a_station_endpoint_merges_onto_the_node_doc_by_key_id(_) ->
    Key = station_key(),
    Endpoint = station_endpoint(Key),
    ok = ingest({node_record, node_record(Key, #{city => <<"Stockholm">>})}),
    ok = ingest({station_endpoint, Endpoint}),
    [Doc] = docs(),
    [?_assertEqual(macula_record:expires_at(Endpoint), maps:get(<<"endpoint_expires_at">>, Doc)),
     ?_assertEqual(<<"Stockholm">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual([<<"2a01:4f8::1">>], maps:get(<<"host_advertised">>, Doc))].

a_station_endpoint_that_lands_first_is_joined_by_the_node_record(_) ->
    Key = station_key(),
    ok = ingest({station_endpoint, station_endpoint(Key)}),
    ok = ingest({node_record, node_record(Key, #{city => <<"Helsinki">>})}),
    [Doc] = docs(),
    [?_assertEqual(<<"Helsinki">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc))].

%% A station's announcer withdraws its node_record on graceful shutdown.
%% The tombstone occupies the withdrawn record's slot, which for a
%% node_record is the signer's key id, so the station to retire is the
%% tombstone's own signer.
a_graceful_shutdown_tombstone_retires_the_station(_) ->
    Key = station_key(),
    NodeRecord = node_record(Key, #{}),
    ok = ingest({node_record, NodeRecord}),
    ?assertEqual(1, length(docs())),
    ok = ingest({tombstone, verified(macula_record:tombstone(NodeRecord, shutdown), Key)}),
    ?_assertEqual([], docs()).

%% Only a withdrawn node_record retires a station. A withdrawn endpoint
%% means the station stopped offering a dial address, not that it left.
a_tombstone_withdrawing_an_endpoint_leaves_the_station_listed(_) ->
    Key = station_key(),
    Endpoint = station_endpoint(Key),
    ok = ingest({node_record, node_record(Key, #{})}),
    ok = ingest({station_endpoint, Endpoint}),
    ok = ingest({tombstone, verified(macula_record:tombstone(Endpoint, moved), Key)}),
    [Doc] = docs(),
    ?_assertEqual(macula_node_keys:key_id(Key), maps:get(<<"node_id">>, Doc)).
