%% @doc One barrel_docdb doc per station node_id, holding the two signed
%% DHT records a station broadcasts: the `node_record' (0x01: geo,
%% hostname, capabilities) and the `station_endpoint' (0x12: the literal
%% dial address). Both are stored whole (their raw signed bytes, so a
%% client can verify them itself) beside the fields projected from them.
%%
%% Each record type owns its own fields, its own expiry and its own raw
%% bytes: an upsert of a type REPLACES everything that type wrote before
%% (a field the new record does not carry is cleared, never left behind
%% from the record before), and either can land first, since they arrive
%% independently.
%%
%% Serving is per record: `node_record_part/2' and `station_endpoint_part/2'
%% say what a caller may serve from each type at a moment in time --
%% `{serve, Raw, Fields}' while that record's expiry is in the future,
%% `expired' when it has passed, `absent' when nothing was stored. A
%% station whose records have all expired went dark without a tombstone:
%% `is_live/2' says so and the caller serves neither part.
%%
%% Missing/undefined projected fields are OMITTED, not written as a null
%% placeholder -- same convention `macula_record:with_text/3' etc. already
%% use on the write side these fields came from.
-module(station_read_model).

-define(DB, <<"mcl_stations">>).

%% The fields each record type projects, the bookkeeping that goes with it,
%% and the key its raw signed bytes are stored under. Cleared and rewritten
%% as one group by that type's upsert.
-define(NODE_RECORD_KEYS, [<<"hostname">>, <<"city">>, <<"country">>, <<"continent">>, <<"lat">>, <<"lng">>,
                           <<"capabilities">>, <<"kind">>, <<"version">>]).
-define(NODE_RECORD_BOOKKEEPING, [<<"node_record">>, <<"node_record_expires_at">>,
                                  <<"last_node_record_at">>]).
-define(STATION_ENDPOINT_KEYS, [<<"quic_port">>, <<"host_advertised">>]).
-define(STATION_ENDPOINT_BOOKKEEPING, [<<"station_endpoint">>, <<"endpoint_expires_at">>,
                                       <<"last_endpoint_at">>]).

-export([open/1, db/0]).
-export([upsert_node_record/1, upsert_station_endpoint/1, retire_node/1, fold/2, is_live/2, to_wire/1]).
-export([node_record_part/2, station_endpoint_part/2]).

%% @doc Open the read model under `DataDir', creating it on first boot and
%% reopening it after a restart. Called from the service's start/1 before
%% the ingest worker starts writing.
%%
%% barrel_docdb first gets its own `data_dir' pointed under `DataDir': it keeps
%% a system database there recording where each database lives, and its
%% default is the RELATIVE "data/barrel_docdb", which in the container is
%% /app/data, outside the service's data dir.
-spec open(file:filename_all()) -> ok.
open(DataDir) ->
    ok = application:set_env(barrel_docdb, data_dir, filename:join(DataDir, "barrel_docdb")),
    Dir = filename:join(DataDir, binary_to_list(?DB)),
    ok = filelib:ensure_path(Dir),
    opened(barrel_docdb:create_db(?DB, #{data_dir => Dir})).

opened({ok, _Pid}) -> ok;
opened({error, already_exists}) -> ok.

%% @doc The read model's database name.
-spec db() -> binary().
db() -> ?DB.

%% @doc Project a verified `node_record' (its raw signed bytes and its
%% fields) onto the station's doc, replacing whatever that record type
%% wrote before. The join key is the signer's key id.
-spec upsert_node_record(macula_record:m_record()) -> ok.
upsert_node_record(Record) ->
    Fields = macula_record:read_node_record(Record),
    NodeId = macula_record:key_id(Record),
    Doc0 = cleared(existing_or_new(node_id_hex(NodeId), NodeId),
                   ?NODE_RECORD_KEYS ++ ?NODE_RECORD_BOOKKEEPING),
    Doc1 = Doc0#{<<"node_record">> => macula_record:encode(Record),
                 <<"node_record_expires_at">> => macula_record:expires_at(Record),
                 <<"last_node_record_at">> => now_ms()},
    Doc2 = maybe_puts(Doc1, [{<<"hostname">>, maps:get(hostname, Fields)},
                             {<<"city">>, maps:get(city, Fields)},
                             {<<"country">>, maps:get(country, Fields)},
                             {<<"continent">>, continent_of(maps:get(country, Fields))},
                             {<<"lat">>, maps:get(lat, Fields)},
                             {<<"lng">>, maps:get(lng, Fields)},
                             {<<"capabilities">>, maps:get(capabilities, Fields)},
                             {<<"kind">>, maps:get(kind, Fields)},
                             {<<"version">>, maps:get(version, Fields)}]),
    put(Doc2).

%% @doc Project a verified `station_endpoint' onto the station's doc,
%% replacing whatever that record type wrote before. `NodeId' is the
%% record's signer key id, the same 32 bytes a node_record carries as its
%% `node_id', which is what lets the two land in one doc.
-spec upsert_station_endpoint(macula_record:m_record()) -> ok.
upsert_station_endpoint(Record) ->
    Fields = macula_record:read_station_endpoint(Record),
    NodeId = macula_record:key_id(Record),
    Doc0 = cleared(existing_or_new(node_id_hex(NodeId), NodeId),
                   ?STATION_ENDPOINT_KEYS ++ ?STATION_ENDPOINT_BOOKKEEPING),
    Doc1 = Doc0#{<<"station_endpoint">> => macula_record:encode(Record),
                 <<"endpoint_expires_at">> => macula_record:expires_at(Record),
                 <<"last_endpoint_at">> => now_ms()},
    Doc2 = maybe_puts(Doc1, [{<<"quic_port">>, maps:get(quic_port, Fields)},
                             {<<"host_advertised">>, maps:get(host_advertised, Fields, [])}]),
    put(Doc2).

%% @doc Retire a station whose node_record was tombstoned. `fold_docs/3'
%% (behind `fold/2' below) excludes deleted docs by default, so a
%% retired station stops appearing in list_stations with no change
%% needed there -- barrel_docdb keeps the revision history for conflict
%% resolution rather than actually erasing the row.
-spec retire_node(<<_:256>>) -> ok.
retire_node(<<_:256>> = NodeId) ->
    Id = node_id_hex(NodeId),
    deleted(barrel_docdb:delete_doc(?DB, Id)).

deleted({ok, _}) -> ok;
deleted({error, not_found}) -> ok.

%% @doc Fold every station doc through Fun/2 (same shape as
%% barrel_docdb:fold_docs/3's own callback) -- list_stations builds its
%% filtered result over this.
fold(Fun, Acc) ->
    barrel_docdb:fold_docs(?DB, Fun, Acc).

%% @doc Whether any of the station's records is still unexpired at `NowMs'.
-spec is_live(map(), integer()) -> boolean().
is_live(Doc, NowMs) ->
    lists:any(fun(Key) -> maps:get(Key, Doc, 0) > NowMs end,
              [<<"node_record_expires_at">>, <<"endpoint_expires_at">>]).

%% @doc What may be served from the station's node_record at `NowMs':
%% `{serve, Raw, Fields}' while it is unexpired (Raw is the signed record
%% as stored; whether it verifies is the caller's check), `expired' when
%% its expiry has passed, `absent' when none was ever stored.
-spec node_record_part(map(), integer()) ->
          {serve, binary(), map()} | expired | absent.
node_record_part(Doc, NowMs) ->
    part(Doc, <<"node_record">>, <<"node_record_expires_at">>,
         ?NODE_RECORD_KEYS ++ [<<"node_record_expires_at">>, <<"last_node_record_at">>], NowMs).

%% @doc As `node_record_part/2', for the station_endpoint.
-spec station_endpoint_part(map(), integer()) ->
          {serve, binary(), map()} | expired | absent.
station_endpoint_part(Doc, NowMs) ->
    part(Doc, <<"station_endpoint">>, <<"endpoint_expires_at">>,
         ?STATION_ENDPOINT_KEYS ++ [<<"endpoint_expires_at">>, <<"last_endpoint_at">>], NowMs).

part(Doc, RawKey, ExpiresKey, FieldKeys, NowMs) ->
    case {maps:get(RawKey, Doc, undefined), maps:get(ExpiresKey, Doc, 0)} of
        {Raw, Expires} when is_binary(Raw), is_integer(Expires), Expires > NowMs ->
            {serve, Raw, maps:with(FieldKeys, Doc)};
        {Raw, _Expired} when is_binary(Raw) ->
            expired;
        {_Absent, _} ->
            absent
    end.

%% @doc A station doc shaped for the list_stations reply: the text fields
%% (hostname, city, country, continent, kind, version, and each
%% host_advertised entry) tagged `{text, Bin}', every other field as
%% stored -- the raw signed records included, as byte strings, since that
%% is what a client verifies.
%%
%% macula encodes a bare binary as a CBOR byte string and `{text, Bin}' as
%% a CBOR text string, so untagged text reaches non-BEAM callers
%% (macula-mcp, macula-cli, the SDKs) as bytes. `id', `node_id' and `_rev'
%% are identifiers and stay bytes; numbers are unaffected.
-spec to_wire(map()) -> map().
to_wire(Doc) ->
    maps:map(fun wire_value/2, Doc).

wire_value(<<"host_advertised">>, Hosts) when is_list(Hosts) ->
    [text(Host) || Host <- Hosts];
wire_value(Key, Value) ->
    text_if(is_text_field(Key), Value).

is_text_field(Key) ->
    lists:member(Key, [<<"hostname">>, <<"city">>, <<"country">>, <<"continent">>,
                       <<"kind">>, <<"version">>]).

text_if(true, Value) -> text(Value);
text_if(false, Value) -> Value.

text(Bin) when is_binary(Bin) -> {text, Bin};
text(Other) -> Other.

existing_or_new(Id, NodeId) ->
    case barrel_docdb:get_doc(?DB, Id) of
        {ok, Doc} -> Doc;
        {error, not_found} -> #{<<"id">> => Id, <<"node_id">> => NodeId}
    end.

%% Remove every key one record type owns, so that type's next write is a
%% replacement and never a merge (a field the new record does not carry
%% must not survive from the record before it).
cleared(Doc, Keys) ->
    maps:without(Keys, Doc).

put(Doc) ->
    {ok, _} = barrel_docdb:put_doc(?DB, Doc),
    ok.

maybe_puts(Doc, Pairs) ->
    lists:foldl(fun({Key, Value}, Acc) -> maybe_put(Acc, Key, Value) end, Doc, Pairs).

maybe_put(Doc, _Key, undefined) -> Doc;
maybe_put(Doc, Key, Value) -> Doc#{Key => Value}.

continent_of(undefined) -> undefined;
continent_of(Country) -> continent_lookup:continent(Country).

node_id_hex(NodeId) ->
    binary:encode_hex(NodeId, lowercase).

now_ms() ->
    erlang:system_time(millisecond).
