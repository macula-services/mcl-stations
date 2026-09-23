# mcl-stations

**Live, filterable directory of macula stations: geo, health and direct-dial address, so clients never hand-maintain a station list**

## Status: serving list_stations

The service boots, joins the mesh and answers `/health` on 8495. It keeps a
directory of every macula station and serves it as one RPC.

**What it reads.** Three DHT record types, the ones every macula-station
already broadcasts: `node_record` (0x01: hostname, city, country, lat/lng,
kind, and the build the station reports), `station_endpoint` (0x12: QUIC port
and the literal addresses to dial), and the `tombstone` (0x0C) a station
publishes when it shuts down gracefully. A snapshot at boot
(`macula:find_records_by_type/2`), then live subscriptions
(`macula:subscribe_records/3`). The macula facade verifies every record under
the node's crypto profile and drops what fails, so nothing unverified reaches
the read model. The two records of one station are joined on the signer's key
id, and a tombstone that withdraws a node_record removes that station at once.

**What it serves.** `mcl-stations/list_stations`, open to any caller:

| Argument | Effect |
|----------|--------|
| none, or not a map | every known station |
| `continent`, `country`, `city` | exact match; continent is derived from the ISO country code |
| `near => #{lat, lng, limit}` | nearest first by great-circle distance, `limit` optional; stations without coordinates are left out |

The reply is `#{stations => [Row]}`. Text fields (`hostname`, `city`,
`country`, `continent`, `kind`, `version`, each `host_advertised` entry) go out
as CBOR text, so non-BEAM callers read strings, not bytes. `node_id` is the
station's 32-byte key id and stays bytes.

It asks the realm for no authority: the records it reads live in the DHT's own
realm, and serving an RPC needs no realm-granted topic.

**Stations that go dark.** Each row keeps the expiry of the records it came
from. A live station refreshes them well before they lapse; one that crashed
or lost its link stops refreshing, and once all its records have expired it
is no longer listed, with no tombstone needed.

**The read model** is a `barrel_docdb` database under `MCL_DATA_DIR`
(`/var/lib/mcl-stations`), a cache rebuilt from the DHT snapshot on every boot.
It has no volume on purpose. The service opens it itself in `start/1`
(`station_read_model:open/1`), and points barrel's own system files at
`MCL_DATA_DIR/barrel_docdb` rather than barrel's relative default.

## Running it

⚠ **Building needs librocksdb 11.1.x.** The read model's rocksdb binding
links the system RocksDB instead of compiling the copy it bundles (the
`overrides` entry in `rebar.config`), and no distribution packages 11.1.x.
Without it `rebar3 compile` stops at rocksdb's configure step with "Could not
find RocksDB", on purpose. Build and test inside the team's build image, the
one lint.yml and the Containerfile pin:

    podman run --rm -v "$PWD:/w:Z" -w /w \
        ghcr.io/macula-io/macula-ci-otp-rocksdb@sha256:da4ea316b91f4f29efc8036fa9d95a3b1f3efde8b85cb5997780f140e0f2f6d8 \
        sh -c 'rebar3 lint && rebar3 eunit && rebar3 dialyzer'

or install librocksdb 11.1.x and run the same commands directly:

    rebar3 compile
    rebar3 eunit
    rebar3 lint
    rebar3 dialyzer

    scripts/health.sh                      # against a running node

The image builds in `macula-ci-otp-rocksdb` and runs on
`macula-pq-runtime-rocksdb`, both Debian trixie and pinned by digest: the
release needs `librocksdb.so.11` at run time, which the runtime image carries.

    podman build -t mcl-stations -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `MCL_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MCL_REALM_KEY` | required | The realm's public signing key, hex encoded: the **trust anchor**, not an identifier. Every org-namespaced advertisement is verified against it, so without it nothing resolves, the boot claim never reaches the realm, and the service stays green while unreachable. Public material, not a secret. |
| `MACULA_STATION_SEEDS` | required | Station hosts to dial, `host[:port]`, comma-separated. No default: naming a realm costs nothing, dialling a production station from every dev clone does. |
| `MACULA_STATION_NODE_IDS` | required | The matching 64-hex station node ids, comma-separated, index-paired with the seeds. The dial is pinned (D5): mcl_om refuses to boot a pool with an unpinned seed. |
| `MCL_DATA_DIR` | `/var/lib/mcl-stations` | Where the read model lives. A cache, rebuilt at boot. |
| `MCL_SERVICE_NAME` | `mcl-stations` | Label on the boot claim the realm's operator sees. |
| `MCL_BOX` | from the host | Label naming the box, also on the boot claim. Set it where you deploy. |
| `MCL_HEALTH_PORT` | `8495` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `MCL_NODE_NAME` | `mcl_stations` | Erlang node name. |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `MCL_COOKIE` | `mcl_stations` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

The image has two channels. A push to `main` publishes
`ghcr.io/macula-services/mcl-stations:latest`, the deploy channel: a host that follows
`:latest` deploys every merge. A `v*` tag publishes its own version and nothing
else, the rollback archive: pin a host to one to roll back. A push that changes
only documentation builds no image (`scripts/is_image_push.sh`).

The service's org, the `<org>` in every procedure it offers (`<org>/<name>`), is
this repository's name, fixed in `config/sys.config.src`. The realm's grant names
it; without an org mcl_om advertises nothing.

Two things CI cannot do for you, both of which have bitten:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `MCL_REALM` and the pinned station pair supplied from
   somewhere they are not committed.

## The service contract

Six callbacks in `mcl_stations_service`, all required, all resolved **by name** by
`mcl_om` at startup on a live node. The `-behaviour(mcl_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

### Adding a store later

This service has no `reckon-db` store, which is the right answer for most. The
reckon-db applications run either way; what a store adds is a data directory, an
open handle, and something written.

The cheapest way to get one is to scaffold again with `store=1`, which generates
the callbacks, the config and the guards together.

⚠ **By hand it is three things and not one, and the missing third crash-loops the
node.** Export `store_id/0` and `data_dir/0`; add the `evoq` adapter block to
`config/sys.config.src`, without which boot raises
`{not_configured, event_store_adapter}` before any service code runs; and mount a
volume in the compose file. A sibling service put two of three fleet nodes into a
boot loop by doing the first and not the second.

## Licence

Apache-2.0.
