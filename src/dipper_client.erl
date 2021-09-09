-module(dipper_client).
-behaviour(gen_server).
%% API
-export([watch/3, watch/4, stop_watch/1]).
-export([handle_watch_data/2, start_link/4]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-include("dipper.hrl").
-record(state, {name, watch, driver, key, range_end, mfa}).
-define(SERVER(Name), list_to_atom(lists:concat([Name, '_watcher']))).

%%-type mfa() :: {Mod :: atom(), Fun :: atom(), Args :: list()}.
-type opts() :: {callback, mfa()} | {driver, module()}.
-spec watch(Name :: atom(), Key :: binary(), Opts :: [opts()]) -> {ok, pid()} | {error, Reason :: any()}.
watch(Name, Key, Opts) ->
    watch(Name, Key, undefined, Opts).

-spec watch(Name :: atom(), Key :: binary(), RangeEnd :: undefined | binary(), Opts :: [opts()]) -> {ok, pid()} | {error, Reason :: any()}.
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

handle_watch_data(Name, Data) ->
    Events = maps:get(events, Data, []),
    handle_watch_event(Name, Events).


start_link(Name, Key, RangeEnd, Opts) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Name, Key, RangeEnd, Opts], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Name, Key0, RangeEnd0, Opts]) ->
    Driver = proplists:get_value(driver, Opts, etcdc_driver),
    MFA = proplists:get_value(callback, Opts),
    {Key, RangeEnd} =
        case RangeEnd0 == undefined of
            true ->
                Driver:prefixed(Key0);
            false ->
                {Key0, RangeEnd0}
        end,
    State = #state{name = Name, driver = Driver, key = Key, range_end = RangeEnd, mfa = MFA},
    case do_watch(State) of
        {error, Reason} ->
            {stop, Reason};
        {ok, NewState} ->
            {ok, NewState}
    end.

handle_call(stop, _From, #state{watch = Pid} = State) ->
    is_pid(Pid) andalso is_process_alive(Pid) andalso exit(Pid, normal),
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({Type, Kv}, #state{ name = Name, mfa = MFA } = State) when Type == 'PUT'; Type == 'ADD'; Type == 'DELETE' ->
    case do_watch_data(Name, Type, Kv, MFA) of
        ok ->
            ok;
        {error, Reason} ->
            logger:error("[dipper_worker]handle error, Name:~p, Reason:~p, Type~p, Kv:~p", [Name, Reason, Type, Kv])
    end,
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

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_watch(#state{name = Name, key = Key, range_end = RangeEnd, driver = Driver} = State) ->
    case Driver:watch(Key, RangeEnd, {?MODULE, handle_watch_data, [Name]}) of
        {error, Reason} ->
            {error, Reason};
        {ok, Pid} ->
            case Driver:simple_range(Key, RangeEnd) of
                {ok, #{kvs := Kvs}} ->
                    handle_watch_event(Name, Kvs);
                {error, Reason} ->
                    logger:error("~p:simple_range/2 error,Key:~p,  RangeEnd:~p, Reason:~p~n", [Driver, Key, RangeEnd, Reason])
            end,
            {ok, State#state{watch = Pid}}
    end.

-spec do_watch_data(Name :: any(), Type :: 'DELETE' | 'ADD' | 'PUT', Kv :: binary(), mfa()) -> ok | {error, any()}.
do_watch_data(Name, Type, Kv, {Mod, Fun}) ->
    case catch apply(Mod, Fun, [Name, Type, Kv]) of
        {Err, Reason} when Err == error; Err == 'EXIT' ->
            {error, Reason};
        _ -> ok
    end;
do_watch_data(Name, Type, Kv, {Mod, Fun, Args}) ->
    case catch apply(Mod, Fun, [Name, Type, Kv] ++ Args) of
        {Err, Reason} when Err == error; Err == 'EXIT' ->
            {error, Reason};
        _ -> ok
    end.

handle_watch_event(_Name, []) ->
    ok;
handle_watch_event(Name, [#{kv := Kv, type := Method} | Events])
    when Method == 'PUT'; Method == 'DELETE' ->
    ?SERVER(Name) ! {Method, Kv},
    handle_watch_event(Name, Events);
handle_watch_event(Name, [Kv | Events]) ->
    ?SERVER(Name) ! {'ADD', Kv},
    handle_watch_event(Name, Events).
