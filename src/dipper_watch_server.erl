-module(dipper_watch_server).

-behaviour(gen_statem).

%% API
-export([start_link/1]).
%% gen_statem callbacks
-export([init/1, idle/3, watching/3, callback_mode/0]).

-export_type([key/0, range_end/0, func/0, mf/0]).

-type key() :: binary().
-type range_end() :: undefined | binary().
-type func() :: atom().
-type mf() :: {module(), func(), list()}.

-define(SERVER, ?MODULE).

-record(state,
{key :: key(),
    range_end :: range_end(),
    mf :: mfa(),
    stream :: undefined | grpc_client:client_stream()
}).

-type statedata() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link(list()) -> gen_statem:start_ret().
start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

-spec callback_mode() -> state_functions.
callback_mode() ->
    state_functions.

-spec init(Args) -> {ok, idle, statedata(), Action} when
    Action :: {next_event,
        state_timeout,
        create_stream},
    Args :: [key() | range_end() | mf()].
init([Key, RangeEnd, MF]) ->
    erlang:process_flag(trap_exit, true),
    State = #state{key = Key, range_end = RangeEnd, mf = MF},
    {ok, idle, State, {next_event, state_timeout, create_stream}}.

-spec idle(EventType, EventContent, statedata()) -> Result when
    EventType :: state_timeout
    | gen_statem:event_type(),
    EventContent :: create_stream | term(),
    Result :: {next_state, watching, statedata(), Action}
    | {repeat_state_and_data, Action}
    | repeat_state_and_data,
    Action :: gen_statem:action().
idle(state_timeout, create_stream, StateData) ->
    Action = {state_timeout, 2000, create_stream},
    case etcdc_conn_mgr:pick_conn() of
        {ok, Conn} ->
            new_stream(Conn, StateData);
        {error, empty_conn} ->
            lager:error("there is no grpc connection"),
            {repeat_state_and_data, Action}
    end;
idle(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, idle, StateData).

-spec watching(EventType, EventContent, statedata()) -> Result when
    EventType :: state_timeout
    | gen_statem:event_type(),
    EventContent :: watch | term(),
    Result :: {next_state, idle, statedata(), Action}
    | {repeat_state_and_data, Action}
    | {stop, normal, statedata()},
    Action :: gen_statem:action().
watching(state_timeout, watch, StateData = #state{mf = MF, stream = Stream}) ->
    CreateStreamAction = {state_timeout, 2000, create_stream},
    WatchAction = {next_event, state_timeout, watch},
    case grpc_client:rcv(Stream) of
        eof ->
            lager:info("etcdc watch is ended: ~p", [StateData]),
            {stop, {shutdown, normal}, StateData};
        {error, Reason} ->
            lager:error("etcdc watch data error ~p, StateData: ~p", [Reason, StateData]),
            {next_state, idle, StateData, CreateStreamAction};
        {headers, Headers} ->
            lager:info("etcdc watch rec header ~p, StateData: ~p ", [Headers, StateData]),
            {repeat_state_and_data, WatchAction};
        {data, Data} ->
            lager:info("etcdc watch rec data ~p, StateData: ~p", [Data, StateData]),
            case MF of
                {M, F} -> M:F(Data);
                {M, F, A} -> apply(M, F, A ++ [Data])
            end,
            {repeat_state_and_data, WatchAction}
    end;
watching(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, watching, StateData).

-spec handle_event(EventType, EventContent, StateName, statedata()) -> Result when
    EventType :: info | gen_statem:event_type(),
    EventContent :: {'EXIT', term(), term()} | term(),
    StateName :: idle | watching,
    Result :: {next_state, idle, statedata(), Action}
    | repeat_state_and_data,
    Action :: gen_statem:action().
handle_event(info, {'EXIT', _, _} = ConnExitEvent, StateName, StateData) ->
    lager:info("etcdc watch rcv conn exit: ~p, State: ~p, Data: ~p",
        [ConnExitEvent, StateName, StateData]),
    {next_state, idle, StateData, {state_timeout, 2000, create_stream}};
handle_event(EventType, EventContent, StateName, StateData) ->
    lager:info("EventType : ~p, Content: ~p, StateName: ~p, Data : ~p",
        [{EventType, EventContent, StateName, StateData}]),
    repeat_state_and_data.

-spec new_stream(Connection, statedata()) -> Result when
    Connection :: grpc_client:connection(),
    Result :: {next_state, idle, statedata(), Action}
    | {repeat_state_and_data, Action},
    Action :: gen_statem:action().
new_stream(Connection, StateData = #state{key = Key, range_end = RangeEnd}) ->
    Action = {state_timeout, 2000, create_stream},
    case grpc_client:new_stream(Connection, 'Watch', 'Watch', etcdv3_rpc) of
        {ok, Stream} ->
            IfHasRangeEnd = case RangeEnd of
                                undefined ->
                                    #{};
                                RangeEnd1 ->
                                    #{range_end => RangeEnd1}
                            end,
            WatchCreateRequest = maps:merge(#{key => Key,
                start_revision => 0,
                progress_notify => false,
                filters => [],
                prev_kv => false},
                IfHasRangeEnd),
            WatchRequest = #{request_union => {create_request, WatchCreateRequest}},
            try grpc_client:send(Stream, WatchRequest) of
                ok ->
                    {next_state, watching, StateData#state{stream = Stream},
                        {next_event, state_timeout, watch}}
            catch
                _Error:_Reason ->
                    {repeat_state_and_data, Action}
            end;
        {error, _Reason} ->
            lager:error("there is no grpc connection"),
            {repeat_state_and_data, Action}
    end.

