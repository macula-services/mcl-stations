%% @doc Drives the `mcl-stations/list_stations' RPC responder against a
%% real, throwaway barrel_docdb read model seeded via station_read_model --
%% same rationale as station_read_model_tests: exercising the actual fold
%% is what verifies the filter/haversine logic against real docs instead
%% of a hand-shaped fixture that might not match what upsert actually
%% writes.
-module(list_stations_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    Dir = read_model_fixture:open(),
    seed(),
    Dir.

teardown(Dir) ->
    read_model_fixture:close(Dir).

%% Four stations plus one deliberately geo-less node
%% (`kind => daemon', the way a thin client's own self-announced
%% node_record would look -- present in the directory but never a `near'
%% result, and excluded from the count the same way `has_geo/1' excludes
%% it in `list_stations.erl').
seed() ->
    station_read_model:upsert_node_record(fields(#{
        city => <<"Leuven">>, country => <<"BE">>, continent_override => <<"Europe">>,
        lat => 50.8798, lng => 4.7005}), later()),
    station_read_model:upsert_node_record(fields(#{
        city => <<"Falkenstein">>, country => <<"DE">>, continent_override => <<"Europe">>,
        lat => 50.4779, lng => 12.3713}), later()),
    station_read_model:upsert_node_record(fields(#{
        city => <<"Paris">>, country => <<"FR">>, continent_override => <<"Europe">>,
        lat => 48.8566, lng => 2.3522}), later()),
    station_read_model:upsert_node_record(fields(#{
        city => <<"Tokyo">>, country => <<"JP">>, continent_override => <<"Asia">>,
        lat => 35.6762, lng => 139.6503}), later()),
    station_read_model:upsert_node_record(fields(#{
        city => undefined, country => undefined, lat => undefined, lng => undefined}), later()),
    %% A station that went dark without a tombstone: its record lapsed a
    %% minute ago and nothing refreshed it. Never listed.
    station_read_model:upsert_node_record(fields(#{
        city => <<"Amsterdam">>, country => <<"NL">>, lat => 52.37, lng => 4.89}),
        erlang:system_time(millisecond) - 60000).

later() -> erlang:system_time(millisecond) + 600000.

%% `continent' is derived server-side from `country' by station_read_model
%% itself (via continent_lookup), so seeding never sets it directly --
%% `continent_override' here is discarded, kept only so callers read as
%% self-documenting about which continent a fixture ends up in.
fields(Overrides) ->
    Base = #{
        node_id => crypto:strong_rand_bytes(32), station_id => undefined, realms => [],
        capabilities => 0, kind => undefined, hostname => undefined, endpoint => undefined,
        city => undefined, country => undefined, lat => undefined, lng => undefined,
        display_name => undefined, caps_hint => undefined, peers => undefined,
        version => undefined
    },
    maps:merge(Base, maps:remove(continent_override, Overrides)).

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
        fun reply_sends_text_as_text_and_node_id_as_bytes/1,
        fun filters_arrive_the_way_a_peer_sends_them/1,
        fun a_payload_that_is_not_a_map_lists_every_station/1,
        fun a_station_whose_records_lapsed_is_not_listed/1
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

%% Non-BEAM callers read these fields; bare binaries reach them as bytes.
reply_sends_text_as_text_and_node_id_as_bytes(_DbName) ->
    {reply, #{stations := [Row]}, _} =
        list_stations:handle_request(#{country => <<"DE">>}, undefined),
    NodeId = maps:get(<<"node_id">>, Row),
    [?_assertEqual({text, <<"DE">>}, maps:get(<<"country">>, Row)),
     ?_assertEqual({text, <<"Europe">>}, maps:get(<<"continent">>, Row)),
     ?_assert(is_binary(NodeId) andalso byte_size(NodeId) =:= 32),
     ?_assertEqual(50.4779, maps:get(<<"lat">>, Row))].

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
