%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_operations.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Various mnesia operations
%%%
%%% Created : 25 Mar 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_mnesia_operations).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").


%% API
%%% TODO: Consider splitting this code into more parts. Easily done per table.
-export([set_torrent_state/2,
	 select_torrent/1, delete_torrent/1, delete_torrent_by_pid/1,
	 store_peer/4, select_peer_ip_port_by_pid/1, delete_peer/1,
	 peer_statechange/2, is_peer_connected/3, select_interested_peers/1,
	 reset_round/1, delete_peers/1, peer_statechange_infohash/2]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: set_torrent_state(InfoHash, State) -> ok | not_found
%% Description: Set the state of an info hash.
%%--------------------------------------------------------------------
set_torrent_state(Id, S) when is_integer(Id) ->
    F = fun() ->
		case mnesia:read(torrent, Id, write) of
		    [T] ->
			New = case S of
				  unknown ->
				      T#torrent{state = unknown};
				  leeching ->
				      T#torrent{state = leeching};
				  seeding ->
				      T#torrent{state = seeding};
				  endgame ->
				      T#torrent{state = endgame};
				  {add_downloaded, Amount} ->
				      T#torrent{downloaded = T#torrent.downloaded + Amount};
				  {add_upload, Amount} ->
				      T#torrent{uploaded = T#torrent.uploaded + Amount};
				  {subtract_left, Amount} ->
				      T#torrent{left = T#torrent.left - Amount};
				  {tracker_report, Seeders, Leechers} ->
				      T#torrent{seeders = Seeders, leechers = Leechers}
			      end,
			mnesia:write(New),
			ok;
		    [] ->
			not_found
		end
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: select_torrent(Id, Pid) -> Rows
%% Description: Return the torrent identified by Id
%%--------------------------------------------------------------------
select_torrent(Id) ->
    mnesia:dirty_read(torrent, Id).

%%--------------------------------------------------------------------
%% Function: delete_torrent(InfoHash) -> transaction
%% Description: Remove the row with InfoHash in it
%%--------------------------------------------------------------------
delete_torrent(InfoHash) when is_binary(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      case mnesia:read(torrent, infohash, write) of
		  [R] ->
		      {atomic, _} = delete_torrent(R);
		  [] ->
		      ok
	      end
      end);
delete_torrent(Torrent) when is_record(Torrent, torrent) ->
    F = fun() ->
		mnesia:delete_object(Torrent)
	end,
    mnesia:transaction(F).


%%--------------------------------------------------------------------
%% Function: delete_torrent_by_pid(Pid) -> transaction
%% Description: Remove the row with Pid in it
%%--------------------------------------------------------------------
delete_torrent_by_pid(Id) ->
    error_logger:info_report([delete_torrent_by_pid, Id]),
    F = fun () ->
		Tr = mnesia:read(torrent, Id),
		mnesia:delete(Tr)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: store_peer(IP, Port, InfoHash, Pid) -> transaction
%% Description: Store a row for the peer
%%--------------------------------------------------------------------
store_peer(IP, Port, InfoHash, Pid) ->
    F = fun() ->
		{atomic, Ref} = create_peer_info(),
		mnesia:write(#peer_map { pid = Pid,
					 ip = IP,
					 port = Port,
					 info_hash = InfoHash}),

		mnesia:write(#peer { map = Pid,
				     info = Ref })
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: select_peer_ip_port_by_pid(Pid) -> rows
%% Description: Select the IP and Port pair of a Pid
%%--------------------------------------------------------------------
select_peer_ip_port_by_pid(Pid) ->
    Q = qlc:q([{PM#peer_map.ip,
		PM#peer_map.port} || PM <- mnesia:table(peer_map),
				     PM#peer_map.pid =:= Pid]),
    qlc:e(Q).

%%--------------------------------------------------------------------
%% Function: delete_peer(Pid) -> transaction
%% Description: Delete all references to the peer owned by Pid
%%--------------------------------------------------------------------
delete_peer(Pid) ->
    mnesia:transaction(
      fun () ->
	      [P] = mnesia:read(peer_map, Pid, write),
	      mnesia:delete(torrent, P#peer_map.info_hash, write),
	      mnesia:delete(peer_map, Pid, write)
      end).

peer_statechange_infohash(InfoHash, What) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([P#peer_map.pid || P <- mnesia:table(peer_map),
					   P#peer_map.info_hash =:= InfoHash]),
	      Pids = qlc:e(Q),
	      lists:foreach(fun (Pid) ->
				    peer_statechange(Pid, What)
			    end,
			    Pids)
      end).

peer_statechange(Pid, What) ->
    F = fun () ->
		[Peer] = mnesia:read(peer, Pid, read), %% Read lock here?
		[PI] = mnesia:read(peer_info, Peer#peer.info, write),
		case What of
		    {optimistic_unchoke, Val} ->
			New = PI#peer_info{ optimistic_unchoke = Val };
		    remove_optimistic_unchoke ->
			New = PI#peer_info{ optimistic_unchoke = false };
		    remote_choking ->
			New = PI#peer_info{ remote_choking = true};
		    remote_unchoking ->
			New = PI#peer_info{ remote_choking = false};
		    interested ->
			New = PI#peer_info{ interested = true};
		    not_intersted ->
			New = PI#peer_info{ interested = false};
		    {uploaded, Amount} ->
			Uploaded = PI#peer_info.uploaded,
			New = PI#peer_info{ uploaded = Uploaded + Amount };
		    {downloaded, Amount} ->
			Downloaded = PI#peer_info.downloaded,
			New = PI#peer_info{ downloaded = Downloaded + Amount }
		end,
		mnesia:write(New),
		ok
	end,
    mnesia:transaction(F).


is_peer_connected(IP, Port, InfoHash) ->
    Query =
	fun () ->
		Q = qlc:q([PM#peer_map.pid || PM <- mnesia:table(peer_map),
					      PM#peer_map.ip =:= IP,
					      PM#peer_map.port =:= Port,
					      PM#peer_map.info_hash =:= InfoHash]),
		case qlc:e(Q) of
		    [] ->
			false;
		    _ ->
			true
		end
	end,
    mnesia:transaction(Query).

select_interested_peers(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      InterestedQuery = build_interest_query(true, InfoHash),
	      NotInterestedQuery = build_interest_query(false, InfoHash),
	      {qlc:e(InterestedQuery), qlc:e(NotInterestedQuery)}
      end).


reset_round(InfoHash) ->
    F = fun() ->
		Q1 = qlc:q([P || PM <- mnesia:table(peer_map),
				 P  <- mnesia:table(peer),
				 PM#peer_map.info_hash =:= InfoHash,
				 P#peer.map =:= PM#peer_map.pid]),
		Q2 = qlc:q([PI || P <- Q1,
				  PI <- mnesia:table(peer_info),
				  PI#peer_info.id =:= P#peer.info]),
		Peers = qlc:e(Q2),
		lists:foreach(fun (P) ->
				      New = P#peer_info{uploaded = 0, downloaded = 0},
				      mnesia:write(New) end,
			      Peers)
	end,
    mnesia:transaction(F).

delete_peers(Pid) ->
    mnesia:transaction(fun () ->
      delete_peer_info_hash(Pid),
      delete_peer_map(Pid)
       end).


delete_peer_map(Pid) ->
   mnesia:transaction(fun () ->
     mnesia:delete(peer_map, Pid, write) end).

delete_peer_info_hash(Pid) ->
  mnesia:transaction(fun () ->
    Q = qlc:q([PI#peer_info.id || P <- mnesia:table(peer),
				  P#peer.map =:= Pid,
				  PI <- mnesia:table(peer_info),
				  PI#peer_info.id =:= P#peer.info]),
    Refs = qlc:e(Q),
    lists:foreach(fun (R) -> mnesia:delete(peer_info, R, write) end,
                  Refs)
    end).



%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

build_interest_query(Interest, InfoHash) ->
    Q = qlc:q([P || PM <- mnesia:table(peer_map),
		    P <- mnesia:table(peer),
		    P#peer.map =:= PM#peer_map.pid,
		    PM#peer_map.info_hash =:= InfoHash]),
    qlc:q([{P#peer.map,
	    PI#peer_info.uploaded,
	    PI#peer_info.downloaded}
	   || P <- Q,
	      PI <- mnesia:table(peer_info),
	      PI#peer_info.id =:= P#peer.info,
	      PI#peer_info.interested =:= Interest]).

create_peer_info() ->
    F = fun() ->
		Ref = make_ref(),
		mnesia:write(#peer_info { id = Ref,
					  uploaded = 0,
					  downloaded = 0,
					  interested = false,
					  remote_choking = true,
					  optimistic_unchoke = false}),
		Ref
	end,
    mnesia:transaction(F).
