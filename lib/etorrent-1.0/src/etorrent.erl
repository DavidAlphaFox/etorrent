-module(etorrent).
-behaviour(application).

-include("etorrent_mnesia_table.hrl").

-export([db_initialize/0, stop/0, start/0]).
-export([start/2, stop/1]).
-export([help/0, h/0, list/0, l/0, show/0, s/0, show/1, s/1]).

start() ->
    ok = application:start(crypto),
    ok = application:start(inets),
    ok = application:start(sasl),
    ok = application:start(mnesia),
    db_initialize(),
    application:start(etorrent).

start(_Type, _Args) ->
    etorrent_sup:start_link().

stop() ->
    ok = application:stop(etorrent),
    halt().

stop(_State) ->
    ok.

db_initialize() ->
    %% May already exist, we do not care at the moment.
    case mnesia:create_schema([]) of
	ok -> error_logger:info_report([schema, created]);
	E -> error_logger:info_report([schema, E])
    end,
    etorrent_mnesia_init:init().

%%--------------------------------------------------------------------
%% Function: list() -> io()
%% Description: List currently active torrents.
%%--------------------------------------------------------------------
list() ->
    {atomic, A} = etorrent_torrent:all(),
    io:format("~3s ~11s ~11s ~11s ~11s ~3s ~3s ~7s~n",
	      ["Id:", "total", "left", "uploaded", "downloaded",
	       "I", "C", "Comp."]),
    lists:foreach(fun (R) ->
			  io:format("~3.B ~11.B ~11.B ~11.B ~11.B ~3.B ~3.B ~7.3f% ~n",
				    [R#torrent.id,
				     R#torrent.total,
				     R#torrent.left,
				     R#torrent.uploaded,
				     R#torrent.downloaded,
				     R#torrent.leechers,
				     R#torrent.seeders,
				     percent_complete(R)])
		  end, A).

%%--------------------------------------------------------------------
%% Function: show(Item) -> io()
%% Description: Show detailed information for Item
%%--------------------------------------------------------------------
show() ->
    io:format("You must supply a torrent Id number~n").

show(Item) when is_integer(Item) ->
    %{atomic, Torrent} = etorrent_torrent:select(Item),
    case etorrent_tracking_map:select(Item) of
	{atomic, [R]} ->
	    io:format("Id: ~3.B Name: ~s~n",
		      [R#tracking_map.id, R#tracking_map.filename]);
	{atomic, []} ->
	    io:format("No such torrent Id~n")
    end;
show(_) ->
    io:format("Item supplied is not an integer~n").

%%--------------------------------------------------------------------
%% Function: help() -> io()
%% Description: Provide a simple help message for the commands supported.
%%--------------------------------------------------------------------
help() ->
    io:format("Available commands:~n", []),

    Commands = [{"help, h", "This help"},
		{"list, l", "List torrents in system"},
		{"show, s", "Show detailed information for a given torrent"},
	        {"stop", "Stop the system"}],

    lists:foreach(fun({Command, Desc}) ->
			  io:format("~-12.s - ~s~n", [Command, Desc])
		  end,
		  Commands),
    ok.

%%--------------------------------------------------------------------
%% Abbreviations
%%--------------------------------------------------------------------
h() -> help().
l() -> list().
s() -> show().
s(Item) -> show(Item).

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------
percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.

