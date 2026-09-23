# mcl-stations
#
# Live, filterable directory of macula stations: geo, health and direct-dial address, so clients never hand-maintain a station list
#
# NO DATA VOLUME, ON PURPOSE. The one thing this service writes is its
# barrel_docdb read model under MCL_DATA_DIR (/var/lib/mcl-stations), and that
# is a cache of what the DHT says: every boot replays the DHT snapshot into it.
# A volume would only carry stale rows from before a restart, so the model
# lives and dies with the container.

# ⚠ THE ROCKSDB PAIR, PINNED BY DIGEST. The station read model runs on
# barrel_docdb, whose rocksdb binding this repo links against the system
# librocksdb (the override in rebar.config) rather than compiling the copy it
# bundles. macula-ci-otp-rocksdb carries librocksdb 11.1.2, OTP 28.4.3 on an
# OpenSSL with ML-DSA, rebar3, Rust and cmake; a release built in it needs
# librocksdb.so.11 at run time, which macula-pq-runtime-rocksdb carries. Both
# are Debian trixie, so the release's ERTS and NIFs match the runtime's glibc.
# Their tags move daily; the digests are what build. lint.yml pins the same
# build image, and mcl_stations_service_tests guards all three pins.
FROM ghcr.io/macula-io/macula-ci-otp-rocksdb@sha256:da4ea316b91f4f29efc8036fa9d95a3b1f3efde8b85cb5997780f140e0f2f6d8 AS builder

# ⚠ THE OTP RELEASE, ASSERTED HERE because the image tag names a date, not a
# release. The same check as lint.yml's toolchain step; the service tests read
# this line and compare it with .tool-versions and lint's.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime-rocksdb@sha256:ecb492cff20a84e88b197cf7d2c660ec1a51b26b3742def95f084499c1124c9f
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-stations"
# The runtime image carries everything the release loads: librocksdb.so.11,
# the codec libraries it links, OpenSSL 3.5, ncurses, libstdc++, and curl for
# the healthcheck below.
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_stations ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_stations
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_stations
ENV MCL_HEALTH_PORT=8495

VOLUME ["/etc/mcl/secrets"]

EXPOSE 8495
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_stations", "foreground"]
