%% @doc The macula and mcl_om this service is built with, checked down to the
%% patch. A floor, not an exact version: a later compatible release must pass,
%% an earlier one must not.
%%
%% macula 14.2.0 and mcl_om 0.38.0: the SDK base every deployed service runs
%% on (identity per user account, rustls 0.23.45, a content fetch bounded by
%% root_timeout_ms). Both carry forward what the older floors were for: calls
%% sealed end to end, seed() naming expected_node_id, and `{mesh, required}'
%% refusing a boot without realm, realm key or pinned seeds.
-module(dependency_floors_tests).

-include_lib("eunit/include/eunit.hrl").

macula_floor_test() ->
    ?assert(at_least(vsn(macula), [14, 2, 0])).

mcl_om_floor_test() ->
    ?assert(at_least(vsn(mcl_om), [0, 38, 0])).

%% Whether an "X.Y.Z" version is at least [Major, Minor, Patch].
at_least(Vsn, Floor) ->
    [Major, Minor, Patch | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    [Major, Minor, Patch] >= Floor.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.
