%% @doc This service links rocksdb against the system library.
%%
%% barrel_docdb brings the erlang `rocksdb' binding, whose compile pre_hook
%% configures a C++ build of the RocksDB it bundles: tens of minutes of CPU in
%% every CI run, image build and local test. The binding's `WITH_SYSTEM_ROCKSDB'
%% option links the prebuilt librocksdb in macula-ci-otp-rocksdb instead. An
%% `overrides' entry in rebar.config applies it (the same mechanism was proven
%% to reach rocksdb from a dependency's rebar.config, with a stand-in cmake
%% recording its arguments). This suite guards that the override stays in
%% place and keeps its shape.
-module(rocksdb_link_tests).

-include_lib("eunit/include/eunit.hrl").

rocksdb_configures_against_the_system_library_test() ->
    Hooks = rocksdb_override(pre_hooks),
    Compile = [Cmd || {"(linux|darwin|solaris)", compile, Cmd} <- Hooks],
    ?assertMatch([_], Compile),
    [Cmd] = Compile,
    ?assertMatch({match, _}, re:run(Cmd, "^\\./do_cmake\\.sh -DWITH_SYSTEM_ROCKSDB=ON ")),
    %% A consumer can still add its own options on top.
    ?assertNotEqual(nomatch, string:find(Cmd, "$ERLANG_ROCKSDB_OPTS")).

%% An `override' replaces the key wholesale, so the binding's clean hooks have
%% to be carried over or `rebar3 clean' leaves a stale NIF behind.
rocksdb_clean_hooks_survive_the_override_test() ->
    Hooks = rocksdb_override(pre_hooks),
    ?assert(lists:member({clean, "rm -f priv/*.so"}, Hooks)),
    ?assert(lists:member({clean, "rm -rf _build/cmake"}, Hooks)).

rocksdb_override(Key) ->
    {ok, Terms} = file:consult(alongside("rebar.config")),
    Overrides = proplists:get_value(overrides, Terms, []),
    [Opts] = [O || {override, rocksdb, O} <- Overrides],
    proplists:get_value(Key, Opts, []).

%% Relative to the beam rather than the working directory.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate) andalso is_ours(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) -> climb(filename:dirname(Dir), Name, Left - 1).

%% The first rebar.config above the beam could be a dependency's; ours
%% names this service's release.
is_ours(Path) ->
    {ok, Bin} = file:read_file(Path),
    binary:match(Bin, <<"{release, {mcl_stations">>) =/= nomatch.
