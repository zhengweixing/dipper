-module(dipper_sup).
-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

%% @doc Starts the supervisor
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).


-spec(init(Args :: term()) ->
    {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
        MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
        [ChildSpec :: supervisor:child_spec()]}}
    | ignore | {error, Reason :: term()}).
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 1000,
        period => 3600
    },
    Children = [
        #{
            id => dipper_event,
            start => {dipper_event, start_link, []},
            restart => permanent, shutdown => 2000, type => supervisor,
            modules => [dipper_event]
        },
        #{
            id => dipper_service,
            start => {dipper_worker_sup, start_link, [dipper_service]},
            restart => transient, shutdown => 2000, type => supervisor,
            modules => [dipper_worker_sup]
        },
        #{
            id => dipper_watch,
            start => {dipper_worker_sup, start_link, [dipper_watch]},
            restart => transient, shutdown => 2000, type => supervisor,
            modules => [dipper_watch]
        }
    ],
    dipper:start(),
    {ok, {SupFlags, Children}}.
