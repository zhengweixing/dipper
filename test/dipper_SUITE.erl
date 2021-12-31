-module(dipper_SUITE).
-include_lib("eunit/include/eunit.hrl").
%% API
-export([all/0, init_per_suite/1, end_per_suite/1]).

all() ->
    [
        app_check
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.