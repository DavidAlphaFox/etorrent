%%%-------------------------------------------------------------------
%%% File    : torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Representation of a torrent for downloading
%%%
%%% Created :  9 Jul 2007 by Jesper Louis Andersen
%%%   <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_t_control).

-behaviour(gen_fsm).

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/3, token/1, start/1, stop/1, load_new_torrent/3,
	torrent_checked/2, tracker_error_report/2, seed/1,
	tracker_warning_report/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/2, waiting_check/2, started/2,
	 stopped/2, handle_sync_event/4, handle_info/3, terminate/3,
	 code_change/4]).

-record(state, {id = none,

		path = none,
		torrent = none,
		peer_id = none,
		work_dir = none,

		parent_pid = none,
		tracker_pid = none,
		file_system_pid = none,
		peer_master_pid = none,

		disk_state = none,
		available_peers = []}).

-define(CHECK_WAIT_TIME, 3000).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------
start_link(Id, Path, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, Path, PeerId], []).

token(Pid) ->
    gen_fsm:send_event(Pid, token).

stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

start(Pid) ->
    gen_fsm:send_event(Pid, start).

load_new_torrent(Pid, File, PeerId) ->
    gen_fsm:send_event(Pid, {load_new_torrent, File, PeerId}).

torrent_checked(Pid, DiskState) ->
    gen_fsm:send_event(Pid, {torrent_checked, DiskState}).

tracker_error_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_error_report, Report}).

tracker_warning_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_warning_report, Report}).

seed(Pid) ->
    gen_fsm:send_event(Pid, seed).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to
%% initialize.
%%--------------------------------------------------------------------
init([Parent, Id, Path, PeerId]) ->
    {ok, WorkDir} = application:get_env(etorrent, dir),
    etorrent_tracking_map:new(Path, Parent, Id),
    {ok, initializing, #state{work_dir = WorkDir,
			      id = Id,
			      path = Path,
			      peer_id = PeerId,
			      parent_pid = Parent}, 0}. % Force timeout instantly.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName,
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also
%% called if a timeout occurs.
%%--------------------------------------------------------------------
% Load a torrent at Path with Torrent
initializing(timeout, S) ->
    {ok, Torrent, Files} =
	etorrent_fs_checker:load_torrent(S#state.work_dir, S#state.path),
    Name = etorrent_metainfo:get_name(Torrent),
    etorrent_event:starting_torrent(Name),
    case etorrent_tracking_map:is_ready_for_checking(S#state.id) of
	false ->
	    {next_state, initializing, S, ?CHECK_WAIT_TIME};
	true ->
	    ok = etorrent_fs_checker:ensure_file_sizes_correct(Files),
	    {ok, FileDict} =
		etorrent_fs_checker:build_dictionary_on_files(Torrent, Files),
	    {ok, FS} = add_filesystem(FileDict, S),

	    NS = S#state{torrent = Torrent, file_system_pid = FS},
	    {next_state, started, check_and_start_torrent(FS, NS)}
    end.

check_and_start_torrent(FS, S) ->
    ok = etorrent_fs_checker:check_torrent_contents(FS, S#state.id),
    ok = etorrent_fs_serializer:release_token(),
    error_logger:info_report(adding_state),
    InfoHash = etorrent_metainfo:get_infohash(S#state.torrent),
    {atomic, _} =
	etorrent_torrent:new(S#state.id,
			     {{uploaded, 0},
			      {downloaded, 0},
			      {left, calculate_amount_left(S#state.id)}}),
    error_logger:info_report(adding_peer_pool),
    {ok, GroupPid} = etorrent_t_sup:add_peer_pool(S#state.parent_pid),
    error_logger:info_report(full_check),
    {atomic, TorrentFull} = etorrent_pieces:is_complete(S#state.id),
    TorrentState = case TorrentFull of
		       true ->
			   seeding;
		       false ->
			   leeching
		   end,
    etorrent_tracking_map:set_state(S#state.id, started),
    {ok, PeerMasterPid} =
	etorrent_t_sup:add_peer_group(
	  S#state.parent_pid,
	  GroupPid,
	  S#state.peer_id,
	  InfoHash,
	  FS,
	  TorrentState,
	  S#state.id),

    InfoHash = etorrent_metainfo:get_infohash(S#state.torrent),
    {atomic, _} = etorrent_mnesia_operations:set_torrent_state(S#state.id, TorrentState),

    {ok, TrackerPid} =
	etorrent_t_sup:add_tracker(
	  S#state.parent_pid,
	  PeerMasterPid,
	  etorrent_metainfo:get_url(S#state.torrent),
	  etorrent_metainfo:get_infohash(S#state.torrent),
	  S#state.peer_id,
	  S#state.id),
    etorrent_tracker_communication:start_now(TrackerPid),
    S#state{file_system_pid = FS,
	    tracker_pid = TrackerPid,
	    peer_master_pid = PeerMasterPid}.

waiting_check(token, S) ->
    NS = check_and_start_torrent(S#state.file_system_pid, S),
    {next_state, started, NS};
waiting_check(stop, S) ->
    {next_state, stopped, S}.

started(stop, S) ->
    {stop, argh, S};
started({tracker_error_report, Reason}, S) ->
    io:format("Got tracker error: ~s~n", [Reason]),
    {next_state, started, S};
started(seed, S) ->
    etorrent_t_peer_group:seed(S#state.peer_master_pid),
    etorrent_mnesia_operations:set_torrent_state(S#state.id, seeding),
    {ok, Name} = etorrent_metainfo:get_name(S#state.torrent),
    etorrent_event:completed_torrent(Name),
    etorrent_tracker_communication:torrent_completed(S#state.tracker_pid),
    {next_state, started, S};
started(token, S) ->
    ok = etorrent_fs_serializer:release_token(),
    {next_state, started, S}.

stopped(start, S) ->
    {stop, argh, S};
stopped(token, S) ->
    ok = etorrent_fs_serializer:release_token(),
    {stop, argh, S}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName,
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName,
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, StateName, State) -> {next_state, NextStateName,
%%						  NextState} |
%%                                          {next_state, NextStateName,
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(Msg, SN, S) ->
    io:format("Problem: ~p~n", [Msg]),
    {next_state, SN, S}.

%%--------------------------------------------------------------------
%% Function:
%% handle_sync_event(Event, From, StateName,
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState,
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState,
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState,
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(Info, StateName, State) ->
    error_logger:info_report([unknown_info, Info, StateName]),
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, S) ->
    etorrent_pieces:delete(S#state.id),
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
add_filesystem(FileDict, S) ->
    etorrent_pieces:new(S#state.id, FileDict),
    FSP = case etorrent_t_sup:add_file_system_pool(S#state.parent_pid) of
	      {ok, FSPool} ->
		  FSPool;
	      {error, {already_started, FSPool}} ->
		  FSPool
	  end,
    etorrent_t_sup:add_file_system(S#state.parent_pid, FSP, S#state.id).

calculate_amount_left(Id) when is_integer(Id) ->
    {atomic, Pieces} = etorrent_pieces:get_pieces(Id),
    Sum = lists:foldl(fun(#piece{files = Files, state = State}, Sum) ->
			      case State of
				  fetched ->
				      Sum;
				  not_fetched ->
				      Sum + size_of_ops(Files)
			      end
		      end,
		      0,
		      Pieces),
    Sum.

size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
                       Size + Total end,
               0,
               Ops).
