%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.

-module(mcl_stations_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
%% Exported for mcl_stations_service_tests.erl: the verdict for a subscription state.
-export([health_of/1]).

info() ->
    #{name => <<"mcl-stations">>,
      version => <<"0.3.1">>,
      description => <<"Live, filterable directory of macula stations: geo, liveness and direct-dial address, so clients never hand-maintain a station list">>}.

%% The read model is this service's own: opened here, before the supervisor
%% starts the worker that writes it.
start(_Opts) ->
    ok = station_read_model:open(data_dir()),
    mcl_stations_sup:start_link().

stop(_State) -> ok.

%% Green while the directory is being fed: the ingest worker holds its record
%% subscriptions through a live pool. Without them list_stations serves
%% frozen rows until they expire, then none, so that is degraded, never
%% silently green.
health() ->
    health_of(ingest_node_records:subscribed()).

%% @doc The health verdict for a subscription state; exported for the tests.
-spec health_of(boolean()) -> ok | {degraded, not_subscribed_to_records}.
health_of(true)  -> ok;
health_of(false) -> {degraded, not_subscribed_to_records}.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. Other services find this one by these
%% names, so each entry is a promise that something answers.
%%
%% The station directory, answered by the list_stations desk. On the wire the
%% procedure is `Org/list_stations', the org (and the realm it lives in) being
%% deploy config, not code; mcl_om refuses to advertise under an unset org.
%% Open, because every row in the reply is public already: stations
%% broadcast these records to the whole DHT.
capabilities() ->
    [#{name => <<"list_stations">>,
       version => 1,
       handler => {list_stations, []},
       auth => open}].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% Nothing: the records it ingests live in the DHT's own realm, which no
%% identity_spec governs, and serving an RPC needs no realm-granted topic.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"mcl-stations">>,
      actions => [],
      resources => [],
      ttl_days => 30}.

%% Where the read model lives. It is a cache of what the DHT says, rebuilt
%% from the snapshot on every boot, so losing it loses nothing.
data_dir() ->
    os:getenv("MCL_DATA_DIR", "/var/lib/mcl-stations").
