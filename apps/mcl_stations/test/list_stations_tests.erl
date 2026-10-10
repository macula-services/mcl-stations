%% @doc Drives the `mcl-stations/list_stations' RPC responder against a
%% real, throwaway barrel_docdb read model seeded via station_read_model --
%% same rationale as station_read_model_tests: exercising the actual fold
%% is what verifies the filter/haversine logic against real docs instead
%% of a hand-shaped fixture that might not match what upsert actually
%% writes.
%%
%% The rows now carry their records' raw signed bytes, so the seed writes
%% real signed records (read_model_fixture) and the suite checks the raw
%% bytes it gets back verify.
-module(list_stations_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    ok = application:set_env(macula, crypto_profile, pq_hybrid),
    {ok, _} = application:ensure_all_started(barrel_docdb),
    _ = station_record_drops:reset(),
    Dir = read_model_fixture:open(),
    seed(),
    Dir.

teardown(Dir) ->
    read_model_fixture:close(Dir).

%% Six stations plus one deliberately geo-less node
%% (`kind => daemon', the way a thin client's own self-announced
%% node_record would look -- present in the directory but never a `near'
%% result, and excluded from the count the same way `has_geo/1' excludes
%% it in `list_stations.erl').
%%
%% One station (Amsterdam) is seeded with a node_record whose TTL has
%% lapsed by the end of setup: never listed, no tombstone involved.
seed() ->
    station(#{city => <<"Leuven">>, country => <<"BE">>, lat => 50.8798, lng => 4.7005}),
    station(#{city => <<"Falkenstein">>, country => <<"DE">>, lat => 50.4779, lng => 12.3713}),
    station(#{city => <<"Paris">>, country => <<"FR">>, lat => 48.8566, lng => 2.3522}),
    station(#{city => <<"Tokyo">>, country => <<"JP">>, lat => 35.6762, lng => 139.6503}),
    station(#{kind => <<"daemon">>}),
    %% A station that went dark without a tombstone: its record lapsed and
    %% nothing refreshed it.
    station(#{city => <<"Amsterdam">>, country => <<"NL">>, lat => 52.37, lng => 4.89},
            #{ttl_ms => 300}),
    timer:sleep(400).

%% `continent' is derived server-side from `country' by station_read_model
%% itself (via continent_lookup), so the seed never sets it.
station(Fields) ->
    station(Fields, #{}).

station(Fields, CtorOpts) ->
    Key = read_model_fixture:station_key(),
    ok = station_read_model:upsert_node_record(
           read_model_fixture:node_record(Key, Fields#{capabilities => 0}, CtorOpts)).

%% A station with both record types, the node_record deliberately short-lived.
station_with_live_endpoint(Fields, NodeTtlMs) ->
    Key = read_model_fixture:station_key(),
    ok = station_read_model:upsert_node_record(
           read_model_fixture:node_record(Key, Fields#{capabilities => 0}, #{ttl_ms => NodeTtlMs})),
    ok = station_read_model:upsert_station_endpoint(
           read_model_fixture:station_endpoint(Key, [{quic_port, 4433}, {host_advertised, []}], #{})),
    Key.

%% Reply rows carry `city' as `{text, Bin}' (station_read_model:to_wire/1);
%% a row whose city went out as bare bytes counts as having none.
cities(Rows) -> lists:sort([city(R) || R <- Rows]).

city(#{<<"city">> := {text, City}}) -> City;
city(_Row) -> undefined.

list_stations_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun no_filter_returns_every_station/1,
        fun continent_filter/1,
        fun country_filter/1,
        fun city_filter/1,
        fun near_sorts_nearest_first_and_excludes_geo_less_stations/1,
        fun near_respects_limit/1,
        fun limit_caps_a_listing_whatever_the_filter/1,
        fun reply_sends_text_as_text_and_node_id_as_bytes/1,
        fun reply_rows_carry_their_raw_signed_records/1,
        fun filters_arrive_the_way_a_peer_sends_them/1,
        fun a_payload_that_is_not_a_map_lists_every_station/1,
        fun a_station_whose_records_lapsed_is_not_listed/1,
        fun a_lapsed_record_stops_being_served_while_the_other_serves/1,
        fun a_row_whose_record_does_not_verify_is_not_served/1
    ]}.

no_filter_returns_every_station(_DbName) ->
    {ok, undefined} = list_stations:init([]),
    {reply, #{stations := Rows}, undefined} = list_stations:handle_request(#{}, undefined),
    ?_assertEqual(5, length(Rows)).

continent_filter(_DbName) ->
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{continent => <<"Asia">>}, undefined),
    ?_assertEqual([<<"Tokyo">>], cities(Rows)).

country_filter(_DbName) ->
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{country => <<"DE">>}, undefined),
    ?_assertEqual([<<"Falkenstein">>], cities(Rows)).

city_filter(_DbName) ->
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{city => <<"Paris">>}, undefined),
    ?_assertEqual([<<"Paris">>], cities(Rows)).

%% Leuven is the query point: Falkenstein and Paris are both closer than
%% Tokyo, and the geo-less fifth station must never appear.
near_sorts_nearest_first_and_excludes_geo_less_stations(_DbName) ->
    {reply, #{stations := Rows}, _} = list_stations:handle_request(
        #{near => #{lat => 50.8798, lng => 4.7005}}, undefined),
    [?_assertEqual(4, length(Rows)),
     ?_assertEqual(<<"Tokyo">>, city(lists:last(Rows)))].

near_respects_limit(_DbName) ->
    {reply, #{stations := Rows}, _} = list_stations:handle_request(
        #{near => #{lat => 50.8798, lng => 4.7005, limit => 2}}, undefined),
    ?_assertEqual(2, length(Rows)).

%% The general cap: any listing, filtered or not, can be bounded. One row
%% now carries signed records (~7.2 KB each), so this is the knob a caller
%% uses to avoid pulling the whole directory.
limit_caps_a_listing_whatever_the_filter(_DbName) ->
    {reply, #{stations := All}, _} = list_stations:handle_request(#{limit => 2}, undefined),
    {reply, #{stations := Europe}, _} = list_stations:handle_request(
        #{continent => <<"Europe">>, limit => 2}, undefined),
    [?_assertEqual(2, length(All)),
     ?_assertEqual(2, length(Europe))].

%% Non-BEAM callers read these fields; bare binaries reach them as bytes.
reply_sends_text_as_text_and_node_id_as_bytes(_DbName) ->
    {reply, #{stations := [Row]}, _} =
        list_stations:handle_request(#{country => <<"DE">>}, undefined),
    NodeId = maps:get(<<"node_id">>, Row),
    [?_assertEqual({text, <<"DE">>}, maps:get(<<"country">>, Row)),
     ?_assertEqual({text, <<"Europe">>}, maps:get(<<"continent">>, Row)),
     ?_assert(is_binary(NodeId) andalso byte_size(NodeId) =:= 32),
     ?_assertEqual(50.4779, maps:get(<<"lat">>, Row))].

%% A row carries the raw signed node_record, so a client verifies it
%% itself instead of trusting this directory; what it gets back verifies
%% under the profile and is signed about the row's node_id.
reply_rows_carry_their_raw_signed_records(_DbName) ->
    {reply, #{stations := [Row]}, _} =
        list_stations:handle_request(#{country => <<"DE">>}, undefined),
    Raw = maps:get(<<"node_record">>, Row),
    {ok, Verified} = macula_record:verify(Raw, read_model_fixture:profile()),
    [?_assertEqual(maps:get(<<"node_id">>, Row), macula_record:key_id(Verified)),
     ?_assertEqual(50.4779, maps:get(lat, macula_record:read_node_record(Verified)))].

%% What a peer's map payload looks like when it reaches the handler: keys
%% as `{text, Bin}', text values as `{text, Bin}', nested maps the same.
%% A filter that only matched atom keys would silently return everything.
filters_arrive_the_way_a_peer_sends_them(_DbName) ->
    ByCountry = #{{text, <<"country">>} => {text, <<"FR">>}, caller => <<7:256>>},
    Near = #{{text, <<"near">>} => #{{text, <<"lat">>} => 50.8798,
                                      {text, <<"lng">>} => 4.7005,
                                      {text, <<"limit">>} => 1}},
    {reply, #{stations := ByCountryRows}, _} = list_stations:handle_request(ByCountry, undefined),
    {reply, #{stations := NearRows}, _} = list_stations:handle_request(Near, undefined),
    [?_assertEqual([<<"Paris">>], cities(ByCountryRows)),
     ?_assertEqual([<<"Leuven">>], cities(NearRows))].

%% An SDK quickstart may call with no arguments at all (null, or a bare
%% text); that is a request for the whole directory, not a crash.
a_payload_that_is_not_a_map_lists_every_station(_DbName) ->
    {reply, #{stations := NullRows}, _} = list_stations:handle_request(null, undefined),
    {reply, #{stations := TextRows}, _} = list_stations:handle_request({text, <<"hi">>}, undefined),
    [?_assertEqual(5, length(NullRows)),
     ?_assertEqual(5, length(TextRows))].

a_station_whose_records_lapsed_is_not_listed(_DbName) ->
    {reply, #{stations := All}, _} = list_stations:handle_request(#{}, undefined),
    {reply, #{stations := Dutch}, _} = list_stations:handle_request(#{country => <<"NL">>}, undefined),
    [?_assertNot(lists:member(<<"Amsterdam">>, cities(All))),
     ?_assertEqual([], Dutch)].

%% Serving is per record: a lapsed node_record contributes neither its
%% fields nor its raw bytes, while the station's live endpoint keeps the
%% row listed (it is still reachable, just no longer advertised in full).
a_lapsed_record_stops_being_served_while_the_other_serves(_DbName) ->
    station_with_live_endpoint(#{city => <<"Helsinki">>, country => <<"FI">>,
                                 lat => 60.1699, lng => 24.9384}, 300),
    timer:sleep(400),
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{city => <<"Helsinki">>}, undefined),
    [?_assertEqual(0, length(Rows)),
     begin
         {reply, #{stations := All}, _} = list_stations:handle_request(#{}, undefined),
         [Row] = [R || R <- All, maps:get(<<"quic_port">>, R, undefined) =:= 4433],
         [?_assertNot(maps:is_key(<<"city">>, Row)),
          ?_assertNot(maps:is_key(<<"node_record">>, Row)),
          ?_assert(maps:is_key(<<"station_endpoint">>, Row)),
          ?_assertEqual(#{}, station_record_drops:counts())]
     end].

%% A row whose stored record no longer verifies is refused, never served,
%% and shows up in the drops gauge; restoring the record clears it again.
a_row_whose_record_does_not_verify_is_not_served(_DbName) ->
    Key = read_model_fixture:station_key(),
    Record = read_model_fixture:node_record(Key, #{city => <<"Milan">>, country => <<"IT">>,
                                                   lat => 45.4642, lng => 9.19, capabilities => 0}),
    ok = station_read_model:upsert_node_record(Record),
    Id = binary:encode_hex(macula_node_keys:key_id(Key), lowercase),
    {ok, Doc} = barrel_docdb:get_doc(station_read_model:db(), Id),
    Raw = maps:get(<<"node_record">>, Doc),
    <<First, Rest/binary>> = Raw,
    Tampered = <<(First bxor 16#FF), Rest/binary>>,
    {ok, _} = barrel_docdb:put_doc(station_read_model:db(), Doc#{<<"node_record">> => Tampered}),
    {reply, #{stations := TamperedRows}, _} =
        list_stations:handle_request(#{country => <<"IT">>}, undefined),
    Counts = station_record_drops:counts(),
    {ok, Current} = barrel_docdb:get_doc(station_read_model:db(), Id),
    {ok, _} = barrel_docdb:put_doc(station_read_model:db(), Current#{<<"node_record">> => Raw}),
    {reply, #{stations := RestoredRows}, _} =
        list_stations:handle_request(#{country => <<"IT">>}, undefined),
    [?_assertEqual(0, length(TamperedRows)),
     ?_assertEqual(1, map_size(Counts)),
     ?_assertEqual(1, length(RestoredRows)),
     ?_assertEqual(#{}, station_record_drops:counts())].
