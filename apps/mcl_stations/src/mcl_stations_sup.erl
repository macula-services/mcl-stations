%% @doc Supervises this service's own processes: the one ingest worker that
%% keeps the station read model current.
-module(mcl_stations_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id       => ingest_node_records,
          start    => {ingest_node_records, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [ingest_node_records]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
