%%%-------------------------------------------------------------------
%%% File    : etorrent.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Etorrent call API
%%%
%%% Created :  3 Sep 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent).


-include("etorrent_torrent.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([help/0, h/0, list/0, l/0, show/0, s/0, show/1, s/1, check/1]).

-ignore_xref([{h, 0}, {l, 0}, {s, 0}, {s, 1}, {check, 1}]).

%%====================================================================

%% @doc List currently active torrents.
%% <p>This function will list the torrent files which are currently in
%% the active state in the etorrent system. A general breakdown of each
%% torrent and its current states is given. The function is given as a
%% convenience in the shell while the system is running.</p>
%% @end
-spec list() -> ok.
list() ->
    A = etorrent_torrent:all(),
    {DownloadRate, UploadRate} = etorrent_rate_mgr:global_rate(),
    io:format("~3s ~11s ~11s ~11s ~11s ~3s ~3s ~7s~n",
              ["Id:", "total", "left", "uploaded", "downloaded",
               "I", "C", "Comp."]),

    lists:foreach(
      fun (R) ->
	      Eta = etorrent_rate:format_eta(R#torrent.left, DownloadRate),
              {atomic, [#tracking_map { filename = FN, _=_}]} =
                  etorrent_tracking_map:select(R#torrent.id),
              io:format("~3.B ~11.B ~11.B ~11.B ~11.B ~3.B ~3.B ~7.3f% ~s ~n",
                        [R#torrent.id,
                         R#torrent.total,
                         R#torrent.left,
                         R#torrent.uploaded,
                         R#torrent.downloaded,
                         R#torrent.leechers,
                         R#torrent.seeders,
                         percent_complete(R),
			 Eta]),
              io:format("    ~s~n", [FN])
      end, A),
    io:format("Rate Up/Down: ~8.2f / ~8.2f~n", [UploadRate / 1024.0,
                                                DownloadRate / 1024.0]).

%% @doc Show detailed information for Item.
%% @end
show() ->
    io:format("You must supply a torrent Id number~n").

%% @doc Show detailed information for Item.
%% @end
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

%% @doc Check a torrents contents. For debugging.
%% @end
check(Id) ->
    etorrent_mgr:check(Id).

%% @doc Provide a simple help message for the commands supported.
%% <p>This function will output a simple help message for the usage of the
%% CLI to etorrent.</p>
%% @end
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
h() -> help().
l() -> list().
s() -> show().
s(Item) -> show(Item).

%%=====================================================================
percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.
