%% @doc One barrel_docdb doc per station node_id, merging fields from
%% node_record (geo, hostname, capabilities) and station_endpoint (the
%% literal dial address) as each arrives independently -- read-modify-
%% write against whatever's already there, since either can land first.
%%
%% Each record's own expiry is kept beside its fields (`node_record_expires_at',
%% `endpoint_expires_at'). The DHT forgets a record when it lapses and a live
%% station refreshes its records well before then, so a station whose records
%% have ALL lapsed went dark without a tombstone: `is_live/2' says so, and
%% list_stations leaves it out.
%%
%% Missing/undefined fields are OMITTED, not written as a null placeholder
%% -- same convention `macula_record:with_text/3' etc. already use on the
%% write side these fields came from.
-module(station_read_model).

-define(DB, <<"mcl_stations">>).

-export([open/1, db/0]).
-export([upsert_node_record/2, upsert_station_endpoint/3, retire_node/1, fold/2, is_live/2, to_wire/1]).

%% @doc Open the read model under `DataDir', creating it on first boot and
%% reopening it after a restart. Called from the service's start/1 before the
%% ingest worker starts writing.
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

upsert_node_record(#{node_id := <<_:256>> = NodeId} = Fields, ExpiresAt) when is_integer(ExpiresAt) ->
    Id = node_id_hex(NodeId),
    Doc0 = existing_or_new(Id, NodeId),
    Doc1 = Doc0#{<<"last_node_record_at">> => now_ms(),
                 <<"node_record_expires_at">> => ExpiresAt},
    Doc2 = maybe_put(Doc1, <<"hostname">>, maps:get(hostname, Fields)),
    Doc3 = maybe_put(Doc2, <<"city">>, maps:get(city, Fields)),
    Doc4 = maybe_put(Doc3, <<"country">>, maps:get(country, Fields)),
    Doc5 = maybe_put(Doc4, <<"continent">>, continent_of(maps:get(country, Fields))),
    Doc6 = maybe_put(Doc5, <<"lat">>, maps:get(lat, Fields)),
    Doc7 = maybe_put(Doc6, <<"lng">>, maps:get(lng, Fields)),
    Doc8 = maybe_put(Doc7, <<"capabilities">>, maps:get(capabilities, Fields)),
    Doc9 = maybe_put(Doc8, <<"kind">>, maps:get(kind, Fields)),
    Doc10 = maybe_put(Doc9, <<"version">>, maps:get(version, Fields)),
    put(Doc10).

%% @doc Merge a station_endpoint onto the station's doc. `NodeId' is the
%% endpoint record's key id, the same 32 bytes a node_record carries as its
%% `node_id', which is what lets the two land in one doc.
upsert_station_endpoint(<<_:256>> = NodeId, #{quic_port := Port} = Fields, ExpiresAt)
  when is_integer(ExpiresAt) ->
    Id = node_id_hex(NodeId),
    Doc0 = existing_or_new(Id, NodeId),
    Doc1 = Doc0#{
        <<"quic_port">>              => Port,
        <<"host_advertised">>        => maps:get(host_advertised, Fields, []),
        <<"last_endpoint_at">>       => now_ms(),
        <<"endpoint_expires_at">>    => ExpiresAt
    },
    put(Doc1).

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

%% @doc A station doc shaped for the list_stations reply: the text fields
%% (hostname, city, country, continent, kind, version, and each
%% host_advertised entry) tagged `{text, Bin}', every other field as
%% stored.
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

put(Doc) ->
    {ok, _} = barrel_docdb:put_doc(?DB, Doc),
    ok.

maybe_put(Doc, _Key, undefined) -> Doc;
maybe_put(Doc, Key, Value) -> Doc#{Key => Value}.

continent_of(undefined) -> undefined;
continent_of(Country) -> continent_lookup:continent(Country).

node_id_hex(NodeId) ->
    binary:encode_hex(NodeId, lowercase).

now_ms() ->
    erlang:system_time(millisecond).
