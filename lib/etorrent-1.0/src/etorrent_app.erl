-module(etorrent_app).
-behaviour(application).

-export([db_initialize/0]).
-export([start/2, stop/1, start/0]).

start() ->
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:start(sasl),
    mnesia:start(),
    application:start(etorrent),

start(_Type, _Args) ->
    etorrent_sup:start_link().

stop(_State) ->
    ok.

db_initialize() ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    etorrent_mnesia_init:init(),
    mnesia:stop().


