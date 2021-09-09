-module(dipper_client).
-behaviour(gen_server).
%% API
-export([start_watch/3, stop_watch/1, start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(state, {name, driver, child_state}).
-define(SERVER(Name), list_to_atom(lists:concat([Name, '_watcher']))).


-spec start_watch(Name, Driver, WorkerArgs) -> {ok, pid()} | {error, Reason :: any()} when
    Driver :: module(),
    Name :: atom(),
    WorkerArgs :: any().
start_watch(Name, Driver, WorkerArgs) ->
    supervisor:start_child(dipper_client, [Name, Driver, WorkerArgs]).

-spec stop_watch(Name :: atom()) -> ok.
stop_watch(Name) ->
    gen_server:call(?SERVER(Name), stop).

start_link(Name, Driver, WorkerArgs) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Name, Driver, WorkerArgs], []).


init([Name, Driver, WorkerArgs]) ->
    State = #state{
        name = Name,
        driver = Driver
    },
    case Driver:start_watch(Name, WorkerArgs) of
        {ok, Events, ChildState} ->
            dipper_event:add(Name, Events),
            {ok, State#state{child_state = ChildState}};
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


handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    handle_msg({'DOWN', Pid, Reason}, State);

handle_info(Info, State) ->
    handle_msg(Info, State).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_msg(Msg, #state{name = Name, driver = Driver} = State) ->
    case erlang:function_exported(Driver, handle, 2) of
        true ->
            case Driver:handle(Msg, State#state.child_state) of
                {ok, ChildState} ->
                    {noreply, State#state{child_state = ChildState}};
                {ok, Events, ChildState} ->
                    dipper_event:add(Name, Events),
                    {noreply, State#state{child_state = ChildState}};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        false ->
            {noreply, State}
    end.
