%% @doc The macula and mcl_om this service is built with, checked down to the
%% patch. A floor, not an exact version: a later compatible release must pass,
%% an earlier one must not.
%%
%% macula 18.0.0 and mcl_om 1.6.0: the macula-18 line, where an advertise that
%% names no call class is refused (macula#147) and mcl_om refuses the boot of a
%% capability that names no caller (mcl-om#41). The floor moved with the wire
%% before this (15.6) and with the caller rules now; a floor left on 15.6 would
%% pass a build on an SDK this service could not have been built against.
%% Both carry forward what the older floors were for: calls sealed end to end,
%% seed() naming expected_node_id, and `{mesh, required}' refusing a boot
%% without realm, realm key or pinned seeds.
-module(dependency_floors_tests).

-include_lib("eunit/include/eunit.hrl").

macula_floor_test() ->
    ?assert(at_least(vsn(macula), [18, 0, 0])).

mcl_om_floor_test() ->
    ?assert(at_least(vsn(mcl_om), [1, 6, 0])).

%% Whether an "X.Y.Z" version is at least [Major, Minor, Patch].
at_least(Vsn, Floor) ->
    [Major, Minor, Patch | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    [Major, Minor, Patch] >= Floor.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.
