-module(dipper_watch).
-behaviour(gen_server).
%% API
-export([start/3, stop/1, start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, driver, child_state}).

-define(SERVER(Name), list_to_atom(lists:concat([Name, '_watcher']))).

-callback start_watch(Name :: dipper:name(), WorkerArgs :: map()) ->
    {ok, Service :: [dipper:event()], State :: any()} |
    {error, Reason :: any()}.

-callback stop_watch(State :: any()) ->
    ok | {error, Reason :: any()}.

-callback handle_msg(Info :: any(), State :: any()) ->
    ok | {ok, NewState :: any()} | {ok, Reply, NewState :: any()} | {stop, Reason :: any()} when
    Reply :: {event, [dipper:event()]} | any().

-optional_callbacks([handle_msg/2]).

-spec start(Name, Driver, WorkerArgs) -> {ok, pid()} | {error, Reason :: any()} when
    Driver :: module(),
    Name :: dipper:name(),
    WorkerArgs :: map().
start(Name, Driver, WorkerArgs) ->
    supervisor:start_child(dipper_watch, [Name, Driver, WorkerArgs]).

-spec stop(Name :: dipper:name()) -> ok.
stop(Name) ->
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
    case erlang:function_exported(Driver, handle_msg, 2) of
        true ->
            case Driver:handle_msg(Msg, State#state.child_state) of
                ok ->
                    {noreply, State};
                {ok, ChildState} ->
                    {noreply, State#state{child_state = ChildState}};
                {ok, {event, Events}, ChildState} ->
                    dipper_event:add(Name, Events),
                    {noreply, State#state{child_state = ChildState}};
                {ok, Reply, ChildState} ->
                    {reply, Reply, State#state{child_state = ChildState}};
                {stop, Reason} ->
                    {stop, Reason, State}
            end;
        false ->
            {noreply, State}
    end.
