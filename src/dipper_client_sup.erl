-module(dipper_client_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Starts the supervisor
-spec(start_link(Driver::module()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Driver) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Driver]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

-spec(init(Args :: term()) ->
    {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
        MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
        [ChildSpec :: supervisor:child_spec()]}}
    | ignore | {error, Reason :: term()}).
init([Driver]) ->
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts
    },
    AChild = #{
        id => dipper_client,
        start => {dipper_client, start_link, [Driver]},
        restart => transient,
        shutdown => 2000,
        type => worker,
        modules => [dipper_client]
    },
    {ok, {SupFlags, [AChild]}}.
