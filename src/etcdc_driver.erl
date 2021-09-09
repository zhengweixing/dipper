-module(etcdc_driver).
-define(TIMEOUT, 3000).

%% API
-export([watch/3, keepalive/1, register/3, put_data/3, simple_range/1, simple_range/2, delete_range/1, delete_range/2, get_range/1]).

-type mf() :: {Module::atom(), Fun::atom()} | {Module::atom(), Fun::atom(), Args::list()}.

-spec watch(Key :: binary(), RangeEnd :: binary(), MFA :: mf()) ->
    supervisor:startlink_ret().
watch(Key, RangeEnd, {M, F}) ->
    etcdc:watch(Key, RangeEnd, {M, F});
watch(Key, RangeEnd, {M, F, A}) ->
    erlang:process_flag(trap_exit, true),
    dipper_watch_server:start_link([Key, RangeEnd, {M, F, A}]).


-spec simple_range(Key :: binary()) ->
    {ok, Kvs :: list()} | {error, Reason :: any()}.
simple_range(Key) ->
    {Key, RangeEnd} = get_range(Key),
    simple_range(Key, RangeEnd).

-spec simple_range(Key :: binary(), RangeEnd :: binary()) ->
    {ok, Data :: map()} | {error, Reason :: any()}.
simple_range(Key, RangeEnd) ->
    case etcdc:simple_range(Key, RangeEnd, ?TIMEOUT) of
        {ok, Data} ->
            {ok, Data};
        {error, Reason} ->
            {error, Reason}
    end.


-spec delete_range(Key :: binary()) ->
    true | false | {error, Reason :: any()}.
delete_range(Key) ->
    {Key, RangeEnd} = get_range(Key),
    delete_range(Key, RangeEnd).


-spec delete_range(Key :: binary(), RangeEnd :: binary()) ->
    true | false | {error, Reason :: any()}.
delete_range(Key, RangeEnd) ->
    case etcdc:delete_range(Key, RangeEnd, ?TIMEOUT) of
        {ok, #{deleted := Deleted}} ->
            Deleted == 1;
        {error, Reason} ->
            {error, Reason}
    end.


-spec keepalive(LeaseId :: integer()) ->
    {ok, TTL :: integer()} | {error, Reason :: any()}.
keepalive(LeaseId) ->
    try etcdc:lease_keepalive(LeaseId, ?TIMEOUT) of
        {ok, #{'TTL' := TTL}} ->
            {ok, TTL};
        {error, ErrorType} ->
            {error, ErrorType}
    catch _Class:Reason:_StackTrace ->
        {error, Reason}
    end.


-spec register(Key :: binary, Value :: binary, TTL :: integer()) ->
    {ok, LeaseId :: integer()} | {error, any()}.
register(Key, Value, TTL) ->
    case etcdc:lease_grant(TTL, ?TIMEOUT) of
        {ok, #{'ID' := LeaseId}} ->
            put_data(Key, Value, LeaseId);
        {error, Reason} ->
            {error, Reason}
    end.

-spec put_data(Key :: binary(), Value :: binary, LeaseId :: integer()) ->
    {ok, LeaseId :: integer()} | {error, any()}.
put_data(Key, Value, LeaseId) ->
    case etcdc:put(Key, Value, LeaseId, ?TIMEOUT) of
        {ok, _} ->
            {ok, LeaseId};
        {error, Reason} ->
            {error, Reason}
    end.


-spec get_range(Path :: binary()) ->
    {Path :: binary(), EndPath :: binary()}.
get_range(Path) ->
    Size = byte_size(Path) - 1,
    <<PrePath:Size/bytes, Last>> = Path,
    EndPath = <<PrePath/binary, (Last + 1)>>,
    {Path, EndPath}.
