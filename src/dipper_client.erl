-module(dipper_client).
-behaviour(gen_server).
%% API
-export([watch/3, watch/4, stop_watch/1, start_link/5]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-include("dipper.hrl").
-record(state, {name, watch, driver, key, range_end, mfa}).
-define(SERVER(Name), list_to_atom(lists:concat([Name, '_watcher']))).

%%-type mfa() :: {Mod :: atom(), Fun :: atom(), Args :: list()}.
-type opt() :: {callback, mfa()}.
-spec watch(Name :: atom(), Key :: binary(), Opts :: [opt()]) -> 
    {ok, pid()} | {error, Reason :: any()}.
watch(Name, Key, Opts) ->
    watch(Name, Key, undefined, Opts).

-spec watch(Name :: atom(), Key :: binary(), RangeEnd :: undefined | binary(), Opts :: [opt()]) -> 
    {ok, pid()} | {error, Reason :: any()}.
watch(Name, Key, RangeEnd, Opts) ->
    supervisor:start_child(dipper_client_sup, [Name, Key, RangeEnd, Opts]).

-spec stop_watch(Name :: atom()) -> ok.
stop_watch(Name) ->
    Pid = whereis(?SERVER(Name)),
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true ->
            gen_server:call(?SERVER(Name), stop);
        false ->
            ok
    end.

start_link(Driver, Name, Key, RangeEnd, Opts) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Name, Key, RangeEnd, [{driver, Driver} | Opts]], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Name, Key, RangeEnd, Opts]) ->
    Driver = proplists:get_value(driver, Opts),
    MFA = proplists:get_value(callback, Opts),
    State = #state{name = Name, driver = Driver, key = Key, range_end = RangeEnd, mfa = MFA},
    case do_watch(State) of
        {error, Reason} ->
            {stop, Reason};
        {ok, NewState} ->
            {ok, NewState}
    end.

handle_call(stop, _From, #state{watch = _Pid} = State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({watch_error, _From, Reason}, #state{name = Name} = State) ->
    logger:error("[dipper_worker] watch_error Name:~p, Reason:~p", [Name, Reason]),
    {noreply, State};

handle_info({watch, _From, Data}, #state{name = Name} = State) ->
    logger:info("[dipper_worker] watch Name:~p, Response:~p", [Name, Data]),
    Events = maps:get(events, Data, []),
    handle_watch_event(Name, Events, State),
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #state{name = Name} = State) ->
    case Pid == State#state.watch of
        true ->
            logger:error("~p watch exit, ~p~n", [Name, Reason]),
            case do_watch(State) of
                {error, Reason} ->
                    {stop, Reason, State};
                {ok, NewState} ->
                    {noreply, NewState}
            end;
        false ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


do_watch(#state{name = Name, key = Key, range_end = RangeEnd, driver = Driver} = State) ->
    case Driver:watch(Key, RangeEnd) of
        {error, Reason} ->
            {error, Reason};
        {ok, Pid} ->
            case Driver:get(Key, RangeEnd) of
                {ok, #{kvs := Kvs}} ->
                    handle_watch_event(Name, Kvs, State);
                {error, Reason} ->
                    logger:error("~p:simple_range/2 error,Key:~p,  RangeEnd:~p, Reason:~p~n",
                        [Driver, Key, RangeEnd, Reason])
            end,
            {ok, State#state{watch = Pid}}
    end.

handle_watch_event(_Name, [], _State) ->
    ok;
handle_watch_event(Name, [#{kv := Kv, type := Method} | Events], State)
    when Method == 'PUT'; Method == 'DELETE' ->
    do_watch_data(Name, Method, Kv, State#state.mfa),
    handle_watch_event(Name, Events, State);
handle_watch_event(Name, [Kv | Events], State) ->
    do_watch_data(Name, 'PUT', Kv, State#state.mfa),
    handle_watch_event(Name, Events, State).

-spec do_watch_data(Name :: any(), Method :: 'DELETE' | 'PUT', Kv :: binary(), mfa()) ->
    no_return().
do_watch_data(Name, Method, Kv, {Mod, Fun}) ->
    case catch apply(Mod, Fun, [Name, Method, Kv]) of
        {Err, Reason} when Err == error; Err == 'EXIT' ->
            logger:error("handle watch ~p Kv ~p, Reason:~p", [Method, Kv, Reason]);
        _ -> ok
    end;
do_watch_data(Name, Method, Kv, {Mod, Fun, Args}) ->
    case catch apply(Mod, Fun, [Name, Method, Kv] ++ Args) of
        {Err, Reason} when Err == error; Err == 'EXIT' ->
            logger:error("handle watch ~p Kv ~p, Reason:~p", [Method, Kv, Reason]);
        _ -> ok
    end.
