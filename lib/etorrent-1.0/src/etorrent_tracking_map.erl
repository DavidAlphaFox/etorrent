%%%-------------------------------------------------------------------
%%% File    : etorrent_tracking_map.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Tracking Map manipulations
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_tracking_map).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([new/3, delete/1, by_file/1, by_infohash/1, set_state/2,
	 is_ready_for_checking/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: new(Filename, Supervisor) -> ok
%% Description: Add a new torrent given by File with the Supervisor
%%   pid as given to the database structure.
%%--------------------------------------------------------------------
new(File, Supervisor, Id) ->
    mnesia:dirty_write(#tracking_map { id = Id,
				       filename = File,
				       supervisor_pid = Supervisor,
				       info_hash = unknown,
				       state = awaiting}).

%%--------------------------------------------------------------------
%% Function: by_file(Filename) -> [SupervisorPid]
%% Description: Find torrent specs matching the filename in question.
%%--------------------------------------------------------------------
by_file(Filename) ->
    mnesia:transaction(
      fun () ->
	      Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
							T#tracking_map.filename == Filename]),
	      qlc:e(Query)
      end).

%%--------------------------------------------------------------------
%% Function: by_infohash(Infohash) -> [#tracking_map]
%% Description: Find tracking map matching a given infohash.
%%--------------------------------------------------------------------
by_infohash(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([T || T <- mnesia:table(tracking_map),
			      T#tracking_map.info_hash =:= InfoHash]),
	      qlc:e(Q)
      end).

%%--------------------------------------------------------------------
%% Function: delete(Pid) -> ok
%% Description: Clean out all references to torrents matching Pid
%%--------------------------------------------------------------------
delete(Pid) ->
    F = fun() ->
		Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
							  T#tracking_map.supervisor_pid =:= Pid]),
		lists:foreach(fun (F) -> mnesia:delete(tracking_map, F, write) end, qlc:e(Query))
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: set_state(Id, State) -> ok
%% Description: Set the tracking map state to State for entry Id
%%--------------------------------------------------------------------
set_state(Id, State) ->
    F = fun () ->
		[TM] = mnesia:read(tracking_map, Id, write),
		mnesia:write(TM#tracking_map { state = State })
	end,
    {atomic, _} = mnesia:transaction(F),
    ok.

%%--------------------------------------------------------------------
%% Function: is_ready_for_checking(Id) -> bool()
%% Description: Attempt to mark the torrent for checking. If this
%%   succeeds, returns true, else false
%%--------------------------------------------------------------------
is_ready_for_checking(Id) ->
    F = fun () ->
		Q = qlc:q([TM || TM <- mnesia:table(tracking_map),
				 TM#tracking_map.state =:= checking]),
		case length(qlc:e(Q)) of
		    0 ->
			[TM] = mnesia:read(tracking_map, Id, write),
			mnesia:write(TM#tracking_map { state = checking }),
			true;
		    _ ->
			false
		end
	end,
    {atomic, T} = mnesia:transaction(F),
    T.

%%====================================================================
%% Internal functions
%%====================================================================
