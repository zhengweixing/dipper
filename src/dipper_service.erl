-module(dipper_service).
-behaviour(gen_server).

-define(BLOCK, 3).

%% API
-export([register/3, unregister/1]).

-export([start_link/3, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(state, {driver, next_ref, child_state, count = 0}).
-define(SERVER(Name), list_to_atom(lists:concat([Name, '_service']))).

-spec register(Driver, Name, WorkerArgs) -> supervisor:startlink_ret() when
    Driver :: module(),
    Name :: atom(),
    WorkerArgs :: any().
register(Driver, Name, WorkerArgs) ->
    supervisor:start_child(dipper_service, [Driver, Name, WorkerArgs]).

-spec unregister(Name :: atom()) -> ok.
unregister(Name) ->
    gen_server:call(?SERVER(Name), unregister).


start_link(Driver, Name, WorkerArgs) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Driver, Name, WorkerArgs], []).


init([Driver, Name, WorkerArgs]) ->
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


handle_info({keep_alive, Next}, #state{driver = Driver, count = Count } = State) ->
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

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

schedule_next_keep_alive(Driver, After) ->
    case erlang:function_exported(Driver, keepalive, 1) of
        true ->
            erlang:send_after(After, self(), {keep_alive, After});
        false ->
            ok
    end.
