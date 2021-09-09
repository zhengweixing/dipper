-module(dipper_worker_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).


%% @doc Starts the supervisor
-spec(start_link(Driver::module()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Mod) ->
    supervisor:start_link({local, Mod}, ?MODULE, [Mod]).


-spec(init(Args :: term()) ->
    {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
        MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
        [ChildSpec :: supervisor:child_spec()]}}
    | ignore | {error, Reason :: term()}).
init([Mod]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 1000,
        period => 3600
    },
    AChild = #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => transient,
        shutdown => 2000,
        type => worker,
        modules => [Mod]
    },
    {ok, {SupFlags, [AChild]}}.
