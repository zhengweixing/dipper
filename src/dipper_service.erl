-module(dipper_service).
-behaviour(gen_server).

-define(BLOCK, 3).

%% API
-export([register/3, unregister/1]).

-export([start_link/3, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {driver, next_ref, child_state, count = 0}).

-define(SERVER(Name), list_to_atom(lists:concat([Name, '_service']))).


-callback register(Name :: dipper:name(), WorkerArgs :: map()) ->
    {ok, State :: any()} | {error, Reason :: any()}.

-callback keepalive(State :: any()) ->
    ok | {error, Reason :: any()}.

-callback unregister(State :: any()) ->
    ok | {error, Reason :: any()}.

-optional_callbacks([keepalive/1]).


-spec register(Name, Driver, WorkerArgs) -> supervisor:startlink_ret() when
    Driver :: module(),
    Name :: dipper:name(),
    WorkerArgs :: any().
register(Name, Driver, WorkerArgs) ->
    supervisor:start_child(dipper_service, [Name, Driver, WorkerArgs]).

-spec unregister(Name :: dipper:name()) -> ok.
unregister(Name) ->
    gen_server:call(?SERVER(Name), unregister).


start_link(Name, Driver, WorkerArgs) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Name, Driver, WorkerArgs], []).


init([Name, Driver, WorkerArgs]) ->
    State = #state{
        driver = Driver
    },
    case Driver:register(Name, WorkerArgs) of
        {ok, ChildState} ->
            TTL = maps:get(ttl, WorkerArgs, 60),
            After = erlang:max(round(TTL / ?BLOCK), 1) * 1000,
            TimeRef = schedule_next_keep_alive(Driver, After),
            {ok, State#state{next_ref = TimeRef, child_state = ChildState}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(unregister, _From, #state{driver = Driver} = State) ->
    case Driver:unregister(State#state.child_state) of
        ok ->
            {stop, normal, ok, State};
        {error, Reason} ->
            {ok, {error, Reason}, State}
    end;

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.


handle_info({keep_alive, Next}, #state{driver = Driver, count = Count} = State) ->
    TimeRef = schedule_next_keep_alive(Driver, Next),
    case Driver:keepalive(State#state.child_state) of
        {ok, ChildState} ->
            {noreply, State#state{count = 0, child_state = ChildState, next_ref = TimeRef}};
        {error, Reason} ->
            logger:error("keepalive error, ~p ~p", [State#state.child_state, Reason]),
            case Count + 1 > 2 of
                true ->
                    {stop, keep_alive_error, State};
                false ->
                    {noreply, State#state{count = Count + 1, next_ref = TimeRef}}
            end
    end;

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    handle_msg({'DOWN', Pid, Reason}, State);

handle_info(Info, State) ->
    handle_msg(Info, State).

terminate(_Reason, #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

handle_msg(Msg, #state{driver = Driver} = State) ->
    case erlang:function_exported(Driver, handle_msg, 2) of
        true ->
            case Driver:handle_msg(Msg, State#state.child_state) of
                {ok, ChildState} ->
                    {noreply, State#state{child_state = ChildState}};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        false ->
            {noreply, State}
    end.

schedule_next_keep_alive(Driver, After) ->
    case erlang:function_exported(Driver, keepalive, 1) of
        true ->
            erlang:send_after(After, self(), {keep_alive, After});
        false ->
            ok
    end.
