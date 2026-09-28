%% @doc The macula and mcl_om this service is built with, checked down to the
%% patch. A floor, not an exact version: a later compatible release must pass,
%% an earlier one must not.
%%
%% macula 13.0.1: calls sealed end to end, and seed() names expected_node_id,
%% so this service's pinned dial checks in its own dialyzer (13.0.0 broke the
%% contract). It carries 12.5.1's admission expiry fix (#37) forward. mcl_om
%% 0.33.1 honours `{mesh, required}' in config/sys.config.src (a boot without
%% realm, realm key or pinned seeds is refused, naming each); older releases
%% ignore it and boot green with no mesh.
-module(dependency_floors_tests).

-include_lib("eunit/include/eunit.hrl").

macula_floor_test() ->
    ?assert(at_least(vsn(macula), [13, 0, 1])).

mcl_om_floor_test() ->
    ?assert(at_least(vsn(mcl_om), [0, 33, 1])).

%% Whether an "X.Y.Z" version is at least [Major, Minor, Patch].
at_least(Vsn, Floor) ->
    [Major, Minor, Patch | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    [Major, Minor, Patch] >= Floor.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.
