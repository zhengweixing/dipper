-module(dipper_service_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-spec(start_link(Driver::module()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Driver) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Driver]).


-spec(init(Args :: term()) ->
    {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
        MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
        [ChildSpec :: supervisor:child_spec()]}}
    | ignore | {error, Reason :: term()}).
init([Driver]) ->
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,
    SupFlags = #{strategy => simple_one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts},
    AChild = #{id => dipper_service,
        start => {dipper_service, start_link, [Driver]},
        restart => transient,
        shutdown => 2000,
        type => worker,
        modules => [dipper_service]},
    {ok, {SupFlags, [AChild]}}.
