-module(dipper_sup).
-include("dipper.hrl").
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Starts the supervisor
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

-spec(init(Args :: term()) ->
    {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
        MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
        [ChildSpec :: supervisor:child_spec()]}}
    | ignore | {error, Reason :: term()}).
init([]) ->
    ets:new(?ETS, [public, named_table, {write_concurrency, true}, {read_concurrency, true}]),
    {ok, Driver} = application:get_env(dipper, driver),
    ok = Driver:start(),
    Children = [
        #{
            id => dipper_service_sup,
            start => {dipper_service_sup, start_link, [Driver]},
            restart => permanent, shutdown => 2000, type => supervisor,
            modules => [dipper_service_sup]
        },
        #{
            id => dipper_client_sup,
            start => {dipper_client_sup, start_link, [Driver]},
            restart => permanent, shutdown => 2000, type => supervisor,
            modules => [dipper_client_sup]
        }
    ],
    SupFlags = #{
        strategy => one_for_one,
        intensity => 1000,
        period => 3600
    },
    {ok, {SupFlags, Children}}.
