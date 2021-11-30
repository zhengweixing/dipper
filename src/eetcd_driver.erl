%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(eetcd_driver).
-define(TIMEOUT, 3000).
-define(NAME, ?MODULE).
%% API
-export([
    start/0,
    watch/2,
    keepalive/1,
    register/3,
    unregister/1,
    get/2
]).

-spec start() -> ok | {error, any()}.
start() ->
    ok = application:ensure_started(gun),
    ok = application:ensure_started(eetcd),
    Endpoints = ["127.0.0.1:2379"],
    case eetcd:open(?NAME, Endpoints) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec watch(Key :: binary(), RangeEnd :: binary()) ->
    supervisor:startlink_ret().
watch(Key, RangeEnd0) ->
    RangeEnd =
        case RangeEnd0 == undefined of
            true ->
                eetcd:get_prefix_range_end(Key);
            false ->
                RangeEnd0
        end,
    eetcd:watch(Key, RangeEnd).


-spec get(Key :: binary(), RangeEnd :: binary()) ->
    {ok, Data :: map()} | {error, Reason :: any()}.
get(Key, RangeEnd0) ->
    RangeEnd =
        case RangeEnd0 == undefined of
            true ->
                eetcd:get_prefix_range_end(Key);
            false ->
                RangeEnd0
        end,
    Ctx = eetcd_kv:new(?NAME),
    Ctx1 = eetcd_kv:with_key(Ctx, Key),
    Ctx2 = eetcd_kv:with_range_end(Ctx1, RangeEnd),
    Ctx3 = eetcd_kv:with_sort(Ctx2, 'KEY', 'ASCEND'),
    eetcd_kv:get(Ctx3).


-spec register(Key :: binary, Value :: binary, TTL :: integer()) ->
    {ok, LeaseId :: integer()} | {error, any()}.
register(Key, Value, TTL) ->
    case eetcd:lease_grant(TTL, ?TIMEOUT) of
        {ok, #{'ID' := LeaseId}} ->
            case eetcd:put(Key, Value, LeaseId, ?TIMEOUT) of
                {ok, _} ->
                    {ok, LeaseId};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec keepalive(LeaseId :: integer()) ->
    {ok, TTL :: integer()} | {error, Reason :: any()}.
keepalive(LeaseId) ->
    try eetcd:lease_keepalive(LeaseId, ?TIMEOUT) of
        {ok, #{'TTL' := TTL}} ->
            {ok, TTL};
        {error, ErrorType} ->
            {error, ErrorType}
    catch _Class:Reason:_StackTrace ->
        {error, Reason}
    end.

-spec unregister(Key :: binary) -> ok | {error, any()}.
unregister(Key) ->
    RangeEnd = eetcd:get_prefix_range_end(Key),
    Ctx = eetcd_kv:new(?NAME),
    Ctx1 = eetcd_kv:with_key(Ctx, Key),
    Ctx2 = eetcd_kv:with_range_end(Ctx1, RangeEnd),
    case eetcd_kv:delete(Ctx2) of
        {ok, #{deleted := _Count, header := #{}}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.
