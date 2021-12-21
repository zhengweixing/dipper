%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(eetcd_driver).
-behavior(dipper_driver).

-record(state, {name, lease_id, worker_args, pid, conn}).
%% API
-export([register/2, keepalive/1, unregister/1, start_watch/2, do_watch/2, stop_watch/1]).

-type worker_args() :: #{}.
-spec register(Name, WorkerArgs) -> {ok, State} | {error, any()} when
    Name :: atom(),
    WorkerArgs :: worker_args(),
    State :: #state{}.
register(Name, WorkerArgs) ->
    case init(Name, WorkerArgs) of
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
            Ctx = eetcd_kv:new(Name),
            case eetcd_lease:keep_alive(Ctx, LeaseId) of
                {ok, Pid} ->
                    {ok, State#state{pid = Pid, lease_id = LeaseId}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.


-spec unregister(State) -> ok | {error, any()} when
    State :: #state{}.
unregister(#state{name = Name, pid = Pid, worker_args = #{ key := Key }}) ->
    gen_server:cast(Pid, close),
    RangeEnd = eetcd:get_prefix_range_end(Key),
    Ctx = eetcd_kv:new(Name),
    Ctx1 = eetcd_kv:with_key(Ctx, Key),
    Ctx2 = eetcd_kv:with_range_end(Ctx1, RangeEnd),
    case eetcd_kv:delete(Ctx2) of
        {ok, #{deleted := _Count, header := #{}}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_watch(Name, WorkerArgs) -> {ok, Service, State} | {error, any()} when
    Name :: atom(),
    WorkerArgs :: worker_args(),
    Service :: [{'PUT' | 'DELETE' | 'ADD', Key :: binary()}],
    State :: #state{}.
start_watch(Name, WorkerArgs) ->
    case init(Name, WorkerArgs) of
        ok ->
            case get_exist_services(Name, WorkerArgs) of
                {ok, Services, Revision} ->
                    State = #state{
                        name = Name,
                        worker_args = WorkerArgs
                    },
                    case watch_services_event(Revision, State) of
                        {ok, NewState} ->
                            Services1 = update_services(Services, []),
                            {ok, Services1, NewState};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec do_watch(Msg, State) -> {ok, Service, tate} | {error, any()} when
    Service :: [{'PUT' | 'DELETE' | 'ADD', Key :: binary()}],
    State :: #state{}.
do_watch(Msg, #state{name = Name, conn = Conn } = State) ->
    logger:info("[watch Name:~p, Response:~p", [Name, Msg]),
    case eetcd_watch:watch_stream(Conn, Msg) of
        {ok, NewConn, #{events := Events}} ->
            Service = update_services(Events, []),
            {ok, Service, State#state{conn = NewConn}};
        {more, NewConn} ->
            {ok, State#state{conn = NewConn}};
        {error, _Reason} ->
            #{revision := Revision} = Conn,
            watch_services_event(Revision, State);
        unknown ->
            {ok, State}
    end.

-spec stop_watch(State) -> ok | {error, any()} when
    State :: #state{}.
stop_watch(#state{conn = Conn}) ->
    case eetcd_watch:unwatch(Conn, 3000) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.


-spec init(Name :: atom(), WorkerArgs :: worker_args()) ->
    ok | {error, any()}.
init(Name, _WorkerArgs) ->
    ok = application:ensure_started(gun),
    ok = application:ensure_started(eetcd),
    Endpoints = ["127.0.0.1:2379"],
    case eetcd:open(Name, Endpoints) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec get_exist_services(Name, WorkerArgs) -> {ok, Data :: map()} | {error, Reason :: any()} when
    Name :: atom(),
    WorkerArgs :: worker_args(),
    State :: #state{}.
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


update_services([], Acc) -> Acc;
update_services([#{kv := #{key := Key}, type := EventType} | Events], Acc) ->
    update_services(Events, [{EventType, Key} | Acc]);
update_services([#{key := Key} | Events], Acc) ->
    update_services(Events, [{'ADD', Key} | Acc]).