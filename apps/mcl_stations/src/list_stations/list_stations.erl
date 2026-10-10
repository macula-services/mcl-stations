%% @doc RPC provider: `Org/list_stations'. Returns the live
%% directory this service has built from node_record/station_endpoint
%% DHT records, optionally filtered.
%%
%% Payload (all optional, `#{}' or absent = every known station):
%%   continent | country | city :: binary() -- exact match
%%   near => #{lat := number(), lng := number(), limit => pos_integer()}
%%     -- sorted nearest-first by great-circle distance; `limit' caps the
%%     result count. This is the shape that keeps working unchanged as
%%     the fleet grows from a handful of boxes to street-level density --
%%     see the README's filtering section.
%%   limit :: pos_integer() -- caps the result count of any of the above,
%%     applied last. One row now carries signed records (~7.2 KB), so a
%%     caller that does not want the whole directory passes this.
%%
%% Each row serves its records' fields only while that record is
%% unexpired AND verifies (a record that does not is refused, never
%% served, and shows up in the directory's health as a drop). The raw
%% signed records travel in the row (`node_record' and
%% `station_endpoint'), so a client can verify them itself instead of
%% trusting this directory.
-module(list_stations).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, undefined}.

%% Filters and sorting run on the stored docs; only the rows that go out
%% are shaped for the wire (station_read_model:to_wire/1). A payload that is
%% not a map (none, null, a bare text) asks for the whole directory.
handle_request(Payload, State) when not is_map(Payload) ->
    handle_request(#{}, State);
handle_request(Payload, State) ->
    Now = erlang:system_time(millisecond),
    {ok, Rows} = station_read_model:fold(fun(Doc, Acc) -> {ok, served(Doc, Now, Acc)} end, []),
    Stations = [station_read_model:to_wire(Row) || Row <- limit(Payload, apply_filters(Payload, Rows))],
    {reply, #{stations => Stations}, State}.

served(Doc, Now, Acc) ->
    case row(Doc, Now) of
        none -> Acc;
        Row -> [Row | Acc]
    end.

%% A row is served while at least one of its records is unexpired and
%% verifies; each type contributes its fields and its raw signed bytes
%% only while it does. A part that does not verify is refused (never
%% served) and observed in the drops gauge, keyed by row and type so a
%% bad node_record cannot be cleared by a good station_endpoint.
row(Doc, Now) ->
    Id = maps:get(<<"id">>, Doc, undefined),
    Node = record_part(node_record, Id, station_read_model:node_record_part(Doc, Now)),
    Endpoint = record_part(station_endpoint, Id, station_read_model:station_endpoint_part(Doc, Now)),
    case {Node, Endpoint} of
        {none, none} -> none;
        _ -> with_parts(base(Doc), [Node, Endpoint])
    end.

base(Doc) ->
    #{<<"id">> => maps:get(<<"id">>, Doc),
      <<"node_id">> => maps:get(<<"node_id">>, Doc)}.

record_part(_Kind, _Id, expired) -> none;
record_part(_Kind, _Id, absent) -> none;
record_part(Kind, Id, {serve, Raw, Fields}) ->
    case verified(Raw) of
        {ok, _Record} ->
            ok = station_record_drops:forget({Id, Kind}),
            {Kind, Raw, Fields};
        {error, expired} ->
            %% the stored expiry said otherwise; the record's own clock
            %% wins, and an expiry is routine, not a drop
            none;
        {error, Reason} ->
            ok = station_record_drops:observe({Id, Kind}, {Kind, Reason}),
            none
    end.

%% Verification under the node's configured crypto profile. A node with
%% no profile verifies nothing and serves nothing: fail closed, visibly.
verified(Raw) ->
    case macula_crypto_profile:configured() of
        {ok, Profile} -> macula_record:verify(Raw, Profile);
        {error, Reason} -> {error, {no_profile, Reason}}
    end.

with_parts(Row, Parts) ->
    lists:foldl(fun({Kind, Raw, Fields}, Acc) ->
                    maps:merge(Acc#{raw_key(Kind) => Raw}, Fields)
                end, Row, [Part || Part <- Parts, Part =/= none]).

raw_key(node_record) -> <<"node_record">>;
raw_key(station_endpoint) -> <<"station_endpoint">>.

apply_filters(Payload, Rows) ->
    R1 = filter_eq(Rows, <<"continent">>, mcl_om_wire:field(continent, Payload)),
    R2 = filter_eq(R1, <<"country">>, mcl_om_wire:field(country, Payload)),
    R3 = filter_eq(R2, <<"city">>, mcl_om_wire:field(city, Payload)),
    apply_near(R3, near(mcl_om_wire:field(near, Payload))).

%% The general cap beside near's own; applied after every filter.
limit(Payload, Rows) ->
    case mcl_om_wire:field(limit, Payload) of
        N when is_integer(N), N >= 0 -> lists:sublist(Rows, N);
        _ -> Rows
    end.

near(#{} = Near) ->
    #{lat => mcl_om_wire:field(lat, Near),
      lng => mcl_om_wire:field(lng, Near),
      limit => mcl_om_wire:field(limit, Near)};
near(_Absent) ->
    undefined.

filter_eq(Rows, _Key, undefined) ->
    Rows;
filter_eq(Rows, Key, Value) ->
    [R || R <- Rows, maps:get(Key, R, undefined) =:= Value].

apply_near(Rows, undefined) ->
    Rows;
apply_near(Rows, #{lat := Lat, lng := Lng, limit := Limit}) when is_number(Lat), is_number(Lng) ->
    WithDistance = [{distance_km(Lat, Lng, R), R} || R <- Rows, has_geo(R)],
    Sorted = [R || {_D, R} <- lists:keysort(1, WithDistance)],
    limited(Sorted, Limit).

has_geo(R) ->
    maps:get(<<"lat">>, R, undefined) =/= undefined andalso
    maps:get(<<"lng">>, R, undefined) =/= undefined.

distance_km(Lat, Lng, Row) ->
    haversine_km(Lat, Lng, maps:get(<<"lat">>, Row), maps:get(<<"lng">>, Row)).

limited(Sorted, undefined) -> Sorted;
limited(Sorted, N) when is_integer(N), N >= 0 -> lists:sublist(Sorted, N).

%% Great-circle distance in km. Earth radius 6371km, standard mean value
%% -- fine for "which station is nearest", not survey-grade.
haversine_km(Lat1, Lng1, Lat2, Lng2) ->
    EarthRadiusKm = 6371.0,
    Phi1 = Lat1 * math:pi() / 180,
    Phi2 = Lat2 * math:pi() / 180,
    DPhi = (Lat2 - Lat1) * math:pi() / 180,
    DLambda = (Lng2 - Lng1) * math:pi() / 180,
    A = math:sin(DPhi / 2) * math:sin(DPhi / 2) +
        math:cos(Phi1) * math:cos(Phi2) *
        math:sin(DLambda / 2) * math:sin(DLambda / 2),
    C = 2 * math:atan2(math:sqrt(A), math:sqrt(1 - A)),
    EarthRadiusKm * C.
