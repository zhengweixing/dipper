-module(eetcd_driver).
-behavior(dipper_service).
-behavior(dipper_watch).

-record(state, {name, lease_id, worker_args, pid, conn}).
%% API
-export([register/2, keepalive/1, unregister/1, start_watch/2, stop_watch/1, handle_msg/2]).

-type worker_args() :: #{
    ttl => integer(),
    key => binary(),
    value => binary(),
    endpoints => [{Host :: string(), Port :: integer()}]
}.

-spec register(Name, WorkerArgs) -> {ok, State} | {error, any()} when
    Name :: dipper:name(),
    WorkerArgs :: worker_args(),
    State :: #state{}.
register(Name, WorkerArgs) ->
    case start_connect(Name, WorkerArgs) of
        ok ->
            #{ttl := TTL, key := Key, value := Value} = WorkerArgs,
            Ctx = eetcd_kv:new(Name),
            case eetcd_lease:grant(Ctx, TTL) of
                {ok, #{'ID' := LeaseId}} ->
                    Ctx1 = eetcd_kv:with_lease(Ctx, LeaseId),
                    case eetcd_kv:put(Ctx1, Key, Value) of
                        {ok, _} ->
                            {ok, #state{
                                name = Name,
                                worker_args = WorkerArgs,
                                lease_id = LeaseId
                            }};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.


-spec keepalive(#state{}) -> ok | {error, any()}.
keepalive(#state{name = Name, lease_id = LeaseId, pid = Pid} = State) ->
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true ->
            {ok, State};
        false ->
            case eetcd_lease:keep_alive(Name, LeaseId) of
                {ok, KeepAlive} ->
                    erlang:monitor(process, KeepAlive),
                    {ok, State#state{pid = KeepAlive, lease_id = LeaseId}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.


-spec unregister(State) -> ok | {error, any()} when
    State :: #state{}.
unregister(#state{name = Name, pid = Pid, worker_args = #{ key := Key }}) ->
    RangeEnd = eetcd:get_prefix_range_end(Key),
    Ctx = eetcd_kv:new(Name),
    Ctx1 = eetcd_kv:with_key(Ctx, Key),
    Ctx2 = eetcd_kv:with_range_end(Ctx1, RangeEnd),
    case eetcd_kv:delete(Ctx2) of
        {ok, #{deleted := _Count, header := #{}}} ->
            gen_server:cast(Pid, close),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_watch(Name, WorkerArgs) -> {ok, Service, State} | {error, any()} when
    Name :: dipper:name(),
    WorkerArgs :: worker_args(),
    Service :: [dipper:event()],
    State :: #state{}.
start_watch(Name, WorkerArgs) ->
    case start_connect(Name, WorkerArgs) of
        ok ->
            case get_exist_services(Name, WorkerArgs) of
                {ok, Events, Revision} ->
                    State = #state{
                        name = Name,
                        worker_args = WorkerArgs
                    },
                    case watch_services_event(Revision, State) of
                        {ok, NewState} ->
                            Events1 = update_services(Events, []),
                            {ok, Events1, NewState};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.


-spec stop_watch(State) -> ok | {error, any()} when
    State :: #state{}.
stop_watch(#state{conn = Conn}) ->
    case eetcd_watch:unwatch(Conn, 3000) of
        {ok, _WatchResponse, _OtherEvents} ->
            ok;
        {error, Reason, _OtherEvents} ->
            {error, Reason}
    end.

-spec handle_msg(Info, State) -> {ok, State} | {error, any()} when
    Info :: any(),
    State :: #state{}.
handle_msg({'DOWN', Pid, Reason}, #state{pid = Pid} = State) ->
    logger:error("DOWN ~p ~p~n", [Pid, Reason]),
    keepalive(State);

handle_msg({gun_data, _, _, _, _} = Msg, #state{conn = Conn, name = Name} = State) ->
    case eetcd_watch:watch_stream(Conn, Msg) of
        {ok, NewConn, #{events := Events}} ->
            Events1 = update_services(Events, []),
            {ok, {event, Events1}, State#state{conn = NewConn}};
        {more, NewConn} ->
            {ok, State#state{conn = NewConn}};
        {error, Reason} ->
            logger:info("[watch Name:~p, Response:~p", [Name, Reason]),
            #{revision := Revision} = Conn,
            watch_services_event(Revision, State);
        unknown ->
            ok
    end;

handle_msg(_Info, State) ->
    {ok, State}.


-spec start_connect(Name :: dipper:name(), WorkerArgs :: worker_args()) ->
    ok | {error, any()}.
start_connect(Name, #{endpoints := EndPoints}) ->
    ok = application:ensure_started(cowlib),
    ok = application:ensure_started(gun),
    ok = application:ensure_started(eetcd),
    Endpoints = [lists:concat([Host, ":", Port]) || {Host, Port} <- EndPoints],
    case eetcd:open(Name, Endpoints) of
        {ok, _} ->
            ok;
        {error, [{_, already_started}]} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec get_exist_services(Name, WorkerArgs) -> {ok, Services, Revision} | {error, Reason :: any()} when
    Name :: dipper:name(),
    WorkerArgs :: worker_args(),
    Services :: map(),
    Revision :: integer().
get_exist_services(Name, #{ key := Key }) ->
    Ctx = eetcd_kv:new(Name),
    Ctx1 = eetcd_kv:with_key(Ctx, Key),
    RangeEnd = eetcd:get_prefix_range_end(Key),
    Ctx2 = eetcd_kv:with_range_end(Ctx1, RangeEnd),
    Ctx3 = eetcd_kv:with_sort(Ctx2, 'KEY', 'ASCEND'),
    case eetcd_kv:get(Ctx3) of
        {ok, #{header := #{revision := Revision}, kvs := Services}} ->
            {ok, Services, Revision};
        {error, Reason} ->
            {error, Reason}
    end.

-spec watch_services_event(Revision, State) -> {ok, State} | {error, any()} when
    Revision :: integer(),
    State :: #state{}.
watch_services_event(Revision, #state{name = Name, worker_args = #{key := Key}} = State) ->
    Ctx = eetcd_watch:new(),
    Ctx1 = eetcd_watch:with_key(Ctx, Key),
    Ctx2 = eetcd_watch:with_prefix(Ctx1),
    Ctx3 = eetcd_watch:with_start_revision(Ctx2, Revision),
    case eetcd_watch:watch(Name, Ctx3) of
        {ok, Conn} ->
            {ok, State#state{conn = Conn}};
        {error, Reason} ->
            {error, Reason}
    end.


update_services([], Acc) -> lists:reverse(Acc);
update_services([#{kv := #{key := Key, value := Value}, type := EventType} | Events], Acc) ->
    update_services(Events, [{EventType, Key, Value} | Acc]);
update_services([#{key := Key, value := Value} | Events], Acc) ->
    update_services(Events, [{'ADD', Key, Value} | Acc]).
