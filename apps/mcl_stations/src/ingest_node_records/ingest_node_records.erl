%% @doc Consumes node_record (type 0x01) and station_endpoint (type 0x12)
%% DHT records, the geo, hostname and literal dial address every
%% macula-station broadcasts, and projects them into the read model, one
%% barrel_docdb doc per station key id. Also consumes tombstones (type
%% 0x0C) that withdraw a node_record, published by the station's announcer
%% on graceful shutdown, and retires that station immediately rather than
%% waiting out its TTL.
%%
%% Snapshot-then-subscribe, the same pattern evoq's own catch-up uses:
%% `macula:find_records_by_type/2' for what is already there at boot,
%% `macula:subscribe_records/3' for what arrives after. It retries the
%% initial connect until `mcl_om' has the mesh pool: the pool comes up off
%% this process's init path, so a single inline attempt at boot can race it
%% and lose.
%%
%% No tombstone snapshot at boot: a tombstone occupies its withdrawn
%% record's own DHT slot, so a station withdrawn before this service started
%% was never in the node_record snapshot to begin with.
%%
%% EVERY RECORD ARRIVES VERIFIED. The macula 12 facade verifies each record
%% under the node's crypto profile in both calls above and drops what fails,
%% so this module trusts what it is handed and verifies nothing itself.
%%
%% THE JOIN KEY IS THE KEY ID. A node_record names its station in
%% `node_id', which is the signer's 32-byte key id. A station_endpoint and a
%% tombstone name nobody in their payload: their slot is the signer's key
%% id, read with `macula_record:key_id/1'. A record's `key' is the full
%% public key, never the id.
-module(ingest_node_records).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TYPE_NODE_RECORD, 16#01).
-define(TYPE_TOMBSTONE, 16#0C).
-define(TYPE_STATION_ENDPOINT, 16#12).
-define(RETRY_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    self() ! connect,
    {ok, #{}}.

handle_call(_Msg, _From, State) -> {reply, {error, unknown_call}, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(connect, State) ->
    {noreply, try_connect(mcl_om:mesh_handles(), State)};
handle_info({node_record, Record}, State) ->
    ok = station_read_model:upsert_node_record(macula_record:read_node_record(Record),
                                               macula_record:expires_at(Record)),
    {noreply, State};
handle_info({station_endpoint, Record}, State) ->
    ok = station_read_model:upsert_station_endpoint(macula_record:key_id(Record),
                                                    macula_record:read_station_endpoint(Record),
                                                    macula_record:expires_at(Record)),
    {noreply, State};
handle_info({tombstone, Record}, State) ->
    ok = retire_if_node_record(macula_record:read_tombstone(Record), macula_record:key_id(Record)),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

try_connect({ok, Pool, _Realm}, State) ->
    Self = self(),
    ok = snapshot(Pool, ?TYPE_NODE_RECORD, node_record),
    ok = snapshot(Pool, ?TYPE_STATION_ENDPOINT, station_endpoint),
    {ok, _} = macula:subscribe_records(Pool, ?TYPE_NODE_RECORD,
                                       fun(R) -> Self ! {node_record, R} end),
    {ok, _} = macula:subscribe_records(Pool, ?TYPE_STATION_ENDPOINT,
                                       fun(R) -> Self ! {station_endpoint, R} end),
    {ok, _} = macula:subscribe_records(Pool, ?TYPE_TOMBSTONE,
                                       fun(R) -> Self ! {tombstone, R} end),
    State#{pool => Pool};
try_connect(_NoMesh, State) ->
    erlang:send_after(?RETRY_MS, self(), connect),
    State.

%% Replayed through this process's own mailbox, so a snapshot record and a
%% live one take the same path.
snapshot(Pool, Type, Tag) ->
    {ok, Records} = macula:find_records_by_type(Pool, Type),
    lists:foreach(fun(R) -> self() ! {Tag, R} end, Records).

retire_if_node_record(#{withdrawn_type := ?TYPE_NODE_RECORD}, NodeId) ->
    station_read_model:retire_node(NodeId);
retire_if_node_record(#{}, _NodeId) ->
    ok.
