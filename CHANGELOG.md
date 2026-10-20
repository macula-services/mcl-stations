# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.4.1 - 2026-10-20

- **`list_stations` answers `id` as text** (mcl-stations#6). `id` is 64 ASCII hex characters as stored, but it arrived as a CBOR byte string, so every non-BEAM client saw an opaque blob and had to base64-decode it before it could show or compare a station. It now goes out tagged as text, in `station_read_model:to_wire/1`. `_rev` and the raw signed records stay bytes: one is a docdb handle, the others are what a client verifies. A test asserts `id` survives the encoder as text, so a regression to bytes fails rather than shipping a blob.
- **`node_id` stays the 32 raw bytes, deliberately.** Hex text was written and reverted before release: a BEAM client dials a discovered station only when its row's `node_id` is 32 bytes (`macula_client:seed_from_fields/4` pins it as `expected_node_id`), so 64-byte hex makes it skip every row, silently emptying station discovery for every pool that finds stations through this service. Moving `node_id` to hex is SDK first; the macula issue filed from mcl-stations#6 tracks it, and the field changes here only after that release.

## 0.4.0 - 2026-10-17

- wire 1.0: on macula 15.6 / mcl_om 1.0 (macula-io/macula#105). A wire 1.0 node and a 0.10.3-fleet node do not interoperate, so this release reaches a box only on the flag day (macula-io/macula-fleet#27).

## 0.3.4 - 2026-10-15

- **Rebuilt on mcl_om 0.42** (mcl-om#26): advertisement renewals move to a 70 s interval under a 280 s TTL (from 30 s / 120 s), so a station sends far fewer renewal frames; the health windows derive from the interval. Carries macula 14.11.0 (mcl_om 0.42's floor).

## 0.3.3 - 2026-10-14

- **Rebuilt on mcl_om 0.40** (mcl-om#25): a lapsed provider delegation claims again and comes back without a restart, and `/health` shows each authorization's `not_after_ms`, degraded as `expiring` with a third or less of its life left.

## [0.3.2] - 2026-10-11

- **Health degrades when the ingest pool has no live station link** (`no_live_station_link`): a pool whose every seed is refused stays `subscribed` while nothing arrives, and the directory kept reporting `ok` through a 35h outage that hid a station the whole time (#2).

- **Rebuilt on macula 14.8.2** (refused dials back off further each time, macula#95).

## [0.3.1] - 2026-10-10

- **Rebuilt on macula ~> 14 (newest release):** request admission frees the slot when the reply is sent, and caller attribution covers every payload shape (macula#89, macula#60).

## [0.3.0] - 2026-10-07

- **On mcl_om 0.39.0 and macula 14.2** (`mcl_om ~> 0.39`, `macula ~> 14.2`, released versions only), the SDK base
  every deployed service runs on. With `macula ~> 13.5` main resolved mcl_om 0.38 on a macula 13, a pair mcl_om 0.38
  was not built for. The dependency floors follow. (#1)

- **`/health` is served on a Unix socket only** (`/run/mcl/health.sock`, mcl_om 0.39 `health_socket`). No TCP
  health listener runs and no health port is bound on the host: `MCL_HEALTH_PORT`, the `health_port` setting and
  its `EXPOSE` are gone. The image creates `/run/mcl` and probes the socket; `scripts/health.sh` asks it through
  the container engine. A deploy that probed the port must probe the socket.

## [0.2.0] - 2026-10-05

- **On mcl_om 0.37.6 and macula 13.5.0** (`mcl_om ~> 0.37`, `macula ~> 13.5`, released versions only). mcl_om 0.37 brings
  the inbound guard pipeline (mcl-om#14); macula 13.5 adds `macula_record:decode_payload/1`, no wire
  change. This release is what the dev fleet's `:latest` follows: CI signs it, then moves `:latest`.

## [0.1.0] - 2026-09-28

### Changed

- **Every pushed image is signed by digest** (keyless, SBOM and provenance attested) by an
  attest job after the build, calling macula-ci-images' `attest-image.yml` pinned by commit,
  as mcl-echo does. The fleet refuses an unsigned digest.
- **The directory says when it is not being fed.** The ingest worker monitors the mesh pool it
  subscribed through and, when the pool restarts under a new pid, drops it and resubscribes,
  snapshot first. `/health` is `degraded` (`not_subscribed_to_records`) while no subscription is
  held; the scaffold's `health() -> ok` stayed green while `list_stations` served frozen rows.
- **macula 13.0.1 and mcl_om 0.33.1**, checked down to the patch by the
  dependency floor test. The release sets `{mesh, required}`: the service
  refuses to boot without `MCL_REALM`, `MCL_REALM_KEY`,
  `MACULA_STATION_SEEDS` and `MACULA_STATION_NODE_IDS`, naming each missing
  one, instead of running green with no mesh.
- Built on the current rocksdb image pair, 20260928-1642, republished with
  every download checked against a pinned checksum; the lint job runs in
  exactly the builder image, which a test now checks.
- build-push: only `main` publishes `:latest` and only a `v*` tag publishes a
  version; a hand-run from any other ref is refused.
- A unit test that the `-behaviour(mcl_om_service)` attribute is present.

- Floors raised to macula 12.5.1 and mcl_om 0.29.1. macula 12.5.1 fixes
  admission expiry (#37): before it, a provider that had run for about two
  hours stopped admitting callers. mcl_om 0.29.1 sends a capability's ADVERTISE
  only to its serving station. `dependency_floors_tests` checks both down to
  the patch.

### Added

- `mcl-stations/list_stations`, the station directory, ported from
  hecate-stations onto macula 12 and mcl_om 0.26. Filters by continent,
  country and city, or nearest-first around a point. Replaces
  `hecate_stations.list_stations`, which has had no provider since hecate left
  the fleet.
- `ingest_node_records`: snapshot-then-subscribe over the station
  `node_record`, `station_endpoint` and `tombstone` DHT records into a
  `barrel_docdb` read model, joined on the signer's key id.
- Payload filters read through `mcl_om_wire:field/2`, so they match the
  `{text, _}` keys and values a peer's call actually carries.
- CI runs `rebar3 dialyzer` alongside lint and eunit.
- On mcl_om 0.27, which no longer brings barrel_docdb: the service declares
  barrel_docdb itself and opens the read model in its own `start/1`
  (`station_read_model:open/1`), with barrel's system files under
  `MCL_DATA_DIR/barrel_docdb` instead of barrel's relative default.
- rocksdb links the system librocksdb 11.1.x (an `overrides` entry, guarded by
  `rocksdb_link_tests`) instead of compiling the copy it bundles. CI and the
  image build run in `macula-ci-otp-rocksdb`, and the image runs on
  `macula-pq-runtime-rocksdb`, both pinned by digest; the Alpine builder and
  runtime are gone.
- mcl_om `~> 0.28` (macula 12.2): the service answers `mcl-stations/info` with
  no code of its own, its publishes can no longer kill it, and /health counts
  failed publishes.
- The boot claim is labelled: the compose file sets `MCL_SERVICE_NAME` and
  passes `MCL_BOX` through from the host.

- The scaffold, generated by `rebar3 new mcl_service`: an OTP release that
  boots on `mcl_om`, joins the mesh, and answers `/health` on 8495.
- `mcl_stations_service`, the six-callback `mcl_om_service` contract.
- Unit tests asserting the contract's shape, including that the mesh-facing name
  and the reported version match the application's own.
- `deploy/docker-compose.yml`, the service's own run contract.
- CI: `lint-and-test` on every push and pull request; `build-and-push` to the
  registry, where `main` publishes `:latest` and a `v*` tag publishes that
  version only.
