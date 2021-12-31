-module(dipper).

%% API
-export([start/0, subscribe/2, get_subscriber/1, unsubscribe/1, get_services/1, update_event/2]).

-type name() :: atom().
-type event_type() :: 'DELETE' | 'ADD' | 'PUT'.
-type event() :: {event_type(), Key :: binary(), Value :: binary()}.

-export_type([name/0, event/0, hook/0]).

-spec start() -> ok.
start() ->
    ets:new(?MODULE, [named_table, public]),
    ok.

-type hook() :: {M :: module(), F :: atom(), A :: list()} | fun((event()) -> ok).
-spec subscribe(Name, Hook) -> reference() when
    Name :: name(),
    Hook :: hook().
subscribe(Name, Hook) ->
    Ref = erlang:make_ref(),
    ets:insert(?MODULE, {{Name, Ref, hook}, Hook}),
    Services = get_services(Name),
    [dipper_event:notify(Hook, {'ADD', Key, Value}) || [Key, Value] <- Services],
    Ref.

-spec get_subscriber(Name :: name()) -> list().
get_subscriber(Name) ->
    ets:match(?MODULE, {{Name, '_', hook}, '$1'}).

-spec unsubscribe(reference()) -> true.
unsubscribe(Ref) ->
    ets:match_delete(?MODULE, {{'_', Ref, hook}, '_'}).

-spec get_services(Name :: name()) -> list().
get_services(Name) ->
    ets:match(?MODULE, {{'$1', Name}, '$2'}).


-spec update_event(Name, Event) -> boolean() when
    Name :: name(),
    Event :: event().
update_event(Name, {Type, Key, Value}) ->
    OldValue = case ets:lookup(?MODULE, {Key, Name}) of
                   [{_, V}] -> V;
                   [] -> undefined
               end,
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
                    ets:insert(?MODULE, {{Key, Name, delete}, OldValue})
            end
    end.
