%% @doc The macula and mcl_om this service is built with, checked down to the
%% patch. A floor, not an exact version: a later compatible release must pass,
%% an earlier one must not.
%%
%% macula 12.5.1 carries the admission expiry fix (#37): before it, a provider
%% that has run for about two hours stops admitting callers, and this service
%% runs for weeks. mcl_om 0.29.1 sends a capability's ADVERTISE only to its
%% serving station, so two providers stop overwriting each other's
%% registration. mcl_om by itself allows macula 12.2, which is why rebar.config
%% names macula too.
-module(dependency_floors_tests).

-include_lib("eunit/include/eunit.hrl").

macula_floor_test() ->
    ?assert(at_least(vsn(macula), [12, 5, 1])).

mcl_om_floor_test() ->
    ?assert(at_least(vsn(mcl_om), [0, 29, 1])).

%% Whether an "X.Y.Z" version is at least [Major, Minor, Patch].
at_least(Vsn, Floor) ->
    [Major, Minor, Patch | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    [Major, Minor, Patch] >= Floor.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.
