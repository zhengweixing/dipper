-module(dipper_service).
-include("dipper.hrl").
-behaviour(gen_server).

%% API
-export([register/4, unregister/1]).

-export([start_link/5, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(state, {key, value, id, pid, driver, ref, opt}).
-define(SERVER(Name), list_to_atom(lists:concat([Name, '_service']))).

-type service() :: function() | {M :: module(), F :: atom(), A :: list()}.
-type opt() :: {ttl, integer()} | {keepalive, integer()} | {service, service()}.
-spec(register(Name :: atom(), Key :: binary, Value :: binary(), Opt :: [opt()]) ->
    {ok, pid()}  | {error, Reason :: term()}).

register(Name, Key, Value, Opt) ->
    BinNode = atom_to_binary(node()),
    BinName = atom_to_binary(Name),
    NewKey = <<Key/binary, "/", BinName/binary, "/", BinNode/binary>>,
    supervisor:start_child(dipper_service_sup, [Name, NewKey, Value, Opt]).


-spec unregister(Name :: atom()) -> ok.
unregister(Name) ->
    case is_pid(whereis(?SERVER(Name))) of
        false ->
            ok;
        true ->
            gen_server:call(?SERVER(Name), unregister)
    end.


start_link(Driver, Name, Key, Value, Opts) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Key, Value, [{driver, Driver} | Opts]], []).


init([Key, Value, Opts]) ->
    process_flag(trap_exit, true),
    Driver = proplists:get_value(driver, Opts),
    State = #state{
        driver = Driver,
        key = Key,
        value = Value,
        opt = proplists:delete(driver, Opts)
    },
    case do_callback(State) of
        {ok, NewState} ->
            self() ! register,
            {ok, NewState};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(unregister, _From, #state{pid = Pid} = State) ->
    NewState = hand_unregister(State),
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true ->
            erlang:unlink(Pid),
            exit(Pid, normal);
        false ->
            ok
    end,
    {stop, normal, ok, NewState};

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(register, #state{key = Key, value = Value, opt = Opts, driver = Driver} = State) ->
    TTL = proplists:get_value(ttl, Opts, 60),
    KeepAliveInterval = timer:seconds(min(TTL, proplists:get_value(keepalive, Opts, TTL))),
    case Driver:register(Key, Value, TTL) of
        {ok, LeaseId} ->
            TRef = erlang:send_after(KeepAliveInterval, self(), heartbeat),
            {noreply, State#state{id = LeaseId, ref = TRef}};
        {error, Reason} ->
            logger:error("Register Key(~p) error: ~p", [Key, Reason]),
            erlang:send_after(KeepAliveInterval, self(), register),
            {noreply, State#state{id = undefined, ref = undefined}}
    end;

handle_info(heartbeat, #state{key = Key, id = LeaseId, opt = Opts, driver = Driver} = State) ->
    TTL = proplists:get_value(ttl, Opts, 60),
    KeepAliveInterval = timer:seconds(min(TTL, proplists:get_value(keepalive, Opts, TTL))),
    case Driver:keepalive(LeaseId) of
        {ok, 0} ->
            handle_cast(register, State);
        {ok, _TTL} ->
            TRef = erlang:send_after(KeepAliveInterval, self(), heartbeat),
            {noreply, State#state{ref = TRef}};
        {error, Reason} ->
            logger:error("Register Key(~p) error: ~p", [Key, Reason]),
            erlang:send_after(KeepAliveInterval, self(), register),
            {noreply, State#state{id = undefined, ref = undefined}}
    end;

handle_info({'EXIT', Pid, Reason}, State) ->
    case State#state.pid of
        Pid ->
            case do_callback(State) of
                {ok, NewState} ->
                    {noreply, NewState};
                {error, Why} ->
                    logger:error("Service exit, Reason:~p, try start service error:~p", [Reason, Why]),
                    {stop, normal, hand_unregister(State)}
            end;
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State = #state{}) ->
    {noreply, State}.


terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

do_callback(State = #state{opt = Opts}) ->
    Callback =
        fun() ->
            case proplists:get_value(service, Opts) of
                undefined -> ok;
                {M, F, A} -> apply(M, F, A);
                Fun -> Fun()
            end
        end,
    case Callback() of
        ok ->
            {ok, State};
        {ok, Pid} ->
            erlang:link(Pid),
            {ok, State#state{pid = Pid}};
        {error, Reason} ->
            {error, Reason}
    end.

hand_unregister(#state{key = Key, ref = TRef, driver = Driver} = State) ->
    TRef =/= undefined andalso erlang:cancel_timer(TRef),
    Driver:unregister(Key),
    State#state{pid = undefined}.
