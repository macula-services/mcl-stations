%% @doc The macula and mcl_om this service is built with, checked down to the
%% patch. A floor, not an exact version: a later compatible release must pass,
%% an earlier one must not.
%%
%% macula 15.6.0 and mcl_om 1.0.0: wire 1.0, the line the flag day moves the
%% fleet to (macula-io/macula-fleet#27). A 15 node and a 14 node do not
%% interoperate, so a floor on 14 would pass a build the fleet cannot run.
%% Both carry forward what the older floors were for: calls sealed end to end,
%% seed() naming expected_node_id, and `{mesh, required}' refusing a boot
%% without realm, realm key or pinned seeds.
-module(dependency_floors_tests).

-include_lib("eunit/include/eunit.hrl").

macula_floor_test() ->
    ?assert(at_least(vsn(macula), [15, 6, 0])).

mcl_om_floor_test() ->
    ?assert(at_least(vsn(mcl_om), [1, 0, 0])).

%% Whether an "X.Y.Z" version is at least [Major, Minor, Patch].
at_least(Vsn, Floor) ->
    [Major, Minor, Patch | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    [Major, Minor, Patch] >= Floor.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.
