-module(dipper_client).
-behaviour(gen_server).
%% API
-export([watch/3, stop_watch/1, start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(state, {driver, child_state}).
-define(SERVER(Name), list_to_atom(lists:concat([Name, '_watcher']))).


-spec watch(Driver, Name, WorkerArgs) -> {ok, pid()} | {error, Reason :: any()} when
    Driver :: module(),
    Name :: atom(),
    WorkerArgs :: any().
watch(Driver, Name, WorkerArgs) ->
    supervisor:start_child(dipper_client, [Driver, Name, WorkerArgs]).

-spec stop_watch(Name :: atom()) -> ok.
stop_watch(Name) ->
    gen_server:call(?SERVER(Name), stop).

start_link(Driver, Name, WorkerArgs) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Driver, Name, WorkerArgs], []).


init([Driver, Name, WorkerArgs]) ->
    State = #state{
        driver = Driver
    },
    case Driver:start_watch(Name, WorkerArgs) of
        {ok, Service, ChildState} ->
            {ok, do_event(Service, State#state{child_state = ChildState})};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(stop, _From, #state{driver = Driver} = State) ->
    case Driver:stop_watch(State#state.child_state) of
        ok ->
            {stop, normal, ok, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(Msg, #state{driver = Driver} = State) ->
    case Driver:do_watch(Msg, State#state.child_state) of
        {ok, Service, ChildState} ->
            {noreply, do_event(Service, State#state{child_state = ChildState})};
        {error, Reason} ->
            {stop, Reason, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


do_event(Service, State) ->
    logger:info("do_event ~p~n", [Service]),
    State.
