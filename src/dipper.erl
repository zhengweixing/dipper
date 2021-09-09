-module(dipper).

%% API
-export([start/0, subscribe/2, get_subscriber/1, unsubscribe/1, get_all_service/1, get_service/2, update_event/2]).

-type event_type() :: 'DELETE' | 'ADD' | 'PUT'.
-type event() :: {event_type(), Key :: binary(), Value :: binary()}.

-export_type([event/0, callback/0]).

-spec start() -> ok.
start() ->
    ets:new(?MODULE, [named_table, {read_concurrency, true}, public]),
    ok.

-type callback() :: {M :: module(), F :: atom(), A :: list()} | fun((event()) -> ok).
-spec subscribe(Name, Hook) -> reference() when
    Name :: atom(),
    Hook :: callback().
subscribe(Name, Hook) ->
    Ref = erlang:make_ref(),
    ets:insert(?MODULE, {{Name, Ref, hook}, Hook}),
    Services = get_all_service(Name),
    [dipper_event:notify(Hook, {'ADD', Key, Value}) || [Key, Value] <- Services],
    Ref.

-spec get_subscriber(Name :: atom()) -> list().
get_subscriber(Name) ->
    ets:match(?MODULE, {{Name, '_', hook}, '$1'}).

-spec unsubscribe(reference()) -> true.
unsubscribe(Ref) ->
    ets:match_delete(?MODULE, {{'_', Ref, hook}, '_'}).

-spec get_all_service(Name :: atom()) -> list().
get_all_service(Name) ->
    ets:match(?MODULE, {{'$1', Name}, '$2'}).

-spec get_service(Name, Key) -> undefined | Value when
    Name :: atom(),
    Key :: binary(),
    Value :: binary().
get_service(Name, Key) ->
    case ets:lookup(?MODULE, {Key, Name}) of
        [{_, Value}] ->
            Value;
        [] ->
            undefined
    end.


-spec update_event(Name, Event) -> boolean() when
    Name :: atom(),
    Event :: event().
update_event(Name, {Type, Key, Value}) ->
    OldValue = dipper:get_service(Name, Key),
    case Type =/= 'DELETE' andalso OldValue == Value of
        true ->
            false;
        false ->
            case Type of
                'ADD' ->
                    ets:insert(?MODULE, {{Key, Name}, Value});
                'PUT' ->
                    ets:insert(?MODULE, {{Key, Name}, Value});
                'DELETE' ->
                    ets:delete(?MODULE, {Key, Name}),
                    ets:insert(?MODULE, {{Key, Name, delete}, Value})
            end
    end.
