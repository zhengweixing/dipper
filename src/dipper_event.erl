-module(dipper_event).

-behaviour(gen_server).

-export([start_link/0, add/2, notify/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

-spec add(Name, Events) -> ok when
    Name :: atom(),
    Events :: [dipper:event()].
add(Name, Events) ->
    lists:foreach(
        fun(Event) ->
            case dipper:update_event(Name, Event) of
                false -> 
                    ok;
                true ->
                    Hooks = dipper:get_subscriber(Name),
                    lists:foreach(
                        fun([Hook]) ->
                            notify(Hook, Event)
                        end, Hooks)
            end
        end, Events).

-spec notify(Hook, Event) -> ok when
    Hook :: dipper:callback(),
    Event :: dipper:event().
notify(Hook, Event) ->
    case Hook of
        {M, F, A} ->
            apply(M, F, A ++ [Event]);
        Fun ->
            apply(Fun, [Event])
    end.
    

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}, 100}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(timeout, State) ->
    {noreply, State};

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.
