%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.

-module(mcl_stations_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
-export([read_model_id/0, data_dir/0]).

info() ->
    #{name => <<"mcl-stations">>,
      version => <<"0.1.0">>,
      description => <<"Live, filterable directory of macula stations: geo, health and direct-dial address, so clients never hand-maintain a station list">>}.

start(_Opts) -> mcl_stations_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
health() -> ok.

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

%% The barrel_docdb read model ingest_node_records keeps and list_stations
%% reads. mcl_om:boot/1 opens it before start/1 because both callbacks are
%% exported. It is a cache of what the DHT says, rebuilt from the snapshot on
%% every boot, so losing it loses nothing.
read_model_id() -> <<"mcl_stations">>.

data_dir() ->
    os:getenv("MCL_DATA_DIR", "/var/lib/mcl-stations").
