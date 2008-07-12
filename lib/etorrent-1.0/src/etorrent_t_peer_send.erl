%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_send.erl
%%% Author  : Jesper Louis Andersen
%%% License : See COPYING
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by
%%%   Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_peer_send).

-include("etorrent_mnesia_table.hrl").
-include("etorrent_rate.hrl").

-behaviour(gen_server).

%% API
-export([start_link/4, remote_request/4, cancel/4, choke/1, unchoke/1,
	 local_request/2, not_interested/1, send_have_piece/2, stop/1,
	 bitfield/2, interested/1]).

%% gen_server callbacks
-export([init/1, handle_info/2, terminate/2, code_change/3,
	 handle_call/3, handle_cast/2]).

-record(state, {socket = none,
	        request_queue = none,

		rate = none,
		choke = true,
		interested = false, % Are we interested in the peer?
		timer = none,
		rate_timer = none,
		parent = none,
	        piece_cache = none,
		torrent_id = none,
	        file_system_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.
-define(RATE_FUDGE, 5). %% Consider moving to etorrent_rate.hrl
-define(RATE_UPDATE, 5 * 1000).
%%====================================================================
%% API
%%====================================================================
start_link(Socket, FilesystemPid, TorrentId, RecvPid) ->
    gen_server:start_link(?MODULE,
			  [Socket, FilesystemPid, TorrentId, RecvPid], []).

%%--------------------------------------------------------------------
%% Func: remote_request(Pid, Index, Offset, Len)
%% Description: The remote end (ie, the peer) requested a chunk
%%  {Index, Offset, Len}
%%--------------------------------------------------------------------
remote_request(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {remote_request, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: local_request(Pid, Index, Offset, Len)
%% Description: We request a piece from the peer: {Index, Offset, Len}
%%--------------------------------------------------------------------
local_request(Pid, {Index, Offset, Size}) ->
    gen_server:cast(Pid, {local_request, {Index, Offset, Size}}).

%%--------------------------------------------------------------------
%% Func: cancel(Pid, Index, Offset, Len)
%% Description: Cancel the {Index, Offset, Len} at the peer.
%%--------------------------------------------------------------------
cancel(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {cancel_piece, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: choke(Pid)
%% Description: Choke the peer.
%%--------------------------------------------------------------------
choke(Pid) ->
    gen_server:cast(Pid, choke).

%%--------------------------------------------------------------------
%% Func: unchoke(Pid)
%% Description: Unchoke the peer.
%%--------------------------------------------------------------------
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%%--------------------------------------------------------------------
%% Func: not_interested(Pid)
%% Description: Tell the peer we are not interested in him anymore
%%--------------------------------------------------------------------
not_interested(Pid) ->
    gen_server:cast(Pid, not_interested).

interested(Pid) ->
    gen_server:cast(Pid, interested).

%%--------------------------------------------------------------------
%% Func: send_have_piece(Pid, PieceNumber)
%% Description: Tell the peer we have the piece PieceNumber
%%--------------------------------------------------------------------
send_have_piece(Pid, PieceNumber) ->
    gen_server:cast(Pid, {have, PieceNumber}).

bitfield(Pid, BitField) ->
    gen_server:cast(Pid, {bitfield, BitField}).


%%--------------------------------------------------------------------
%% Func: stop(Pid)
%% Description: Tell the send process to stop the communication.
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, FilesystemPid, TorrentId, Parent]) ->
    process_flag(trap_exit, true),
    {ok, TRef} = timer:send_interval(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), keep_alive_tick),
    {ok, Tref2} = timer:send_interval(?RATE_UPDATE, self(), rate_update),
    {ok,
     #state{socket = Socket,
	    timer = TRef,
	    rate_timer = Tref2,
	    request_queue = queue:new(),
	    rate = etorrent_rate:init(?RATE_FUDGE),
	    parent = Parent,
	    torrent_id = TorrentId,
	    file_system_pid = FilesystemPid},
     0}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(keep_alive_tick, S) ->
    send_message(keep_alive, S, 0);
handle_info(rate_update, S) ->
    Rate = etorrent_rate:update(S#state.rate, 0),
    {atomic, _} = etorrent_peer:statechange(S#state.parent,
					    {upload_rate,
					     Rate#peer_rate.rate}),
    {noreply, S#state { rate = Rate }};
handle_info(timeout, S)
  when S#state.choke =:= true andalso S#state.piece_cache =:= none ->
    garbage_collect(),
    {noreply, S};
handle_info(timeout, S) when S#state.choke =:= true ->
    {noreply, S};
handle_info(timeout, S) when S#state.choke =:= false ->
    case queue:out(S#state.request_queue) of
	{empty, _} ->
	    {noreply, S};
	{{value, {Index, Offset, Len}}, NewQ} ->
	    send_piece(Index, Offset, Len, S#state { request_queue = NewQ } )
    end;
handle_info(Msg, S) ->
    error_logger:info_report([got_unknown_message, Msg, S]),
    {stop, {unknown_msg, Msg}}.

handle_cast(choke, S) when S#state.choke == true ->
    {noreply, S, 0};
handle_cast(choke, S) when S#state.choke == false ->
    send_message(choke, S#state{choke = true, piece_cache = none});
handle_cast(unchoke, S) when S#state.choke == false ->
    {noreply, S, 0};
handle_cast(unchoke, S) when S#state.choke == true ->
    send_message(unchoke, S#state{choke = false,
				  request_queue = queue:new()});
handle_cast({bitfield, BF}, S) ->
    send_message({bitfield, BF}, S);
handle_cast(not_interested, S) when S#state.interested =:= false ->
    {noreply, S, 0};
handle_cast(not_interested, S) when S#state.interested =:= true ->
    send_message(not_interested, S#state { interested = false });
handle_cast(interested, S) when S#state.interested =:= true ->
    {noreply, S, 0};
handle_cast(interested, S) when S#state.interested =:= false ->
    send_message(interested, S#state { interested = true });
handle_cast({have, Pn}, S) ->
    send_message({have, Pn}, S);
handle_cast({local_request, {Index, Offset, Size}}, S) ->
    send_message({request, Index, Offset, Size}, S);
handle_cast({remote_request, _Index, _Offset, _Len}, S)
  when S#state.choke == true ->
    {noreply, S, 0};
handle_cast({remote_request, Index, Offset, Len}, S)
  when S#state.choke == false ->
    Requests = queue:len(S#state.request_queue),
    case Requests > ?MAX_REQUESTS of
	true ->
	    {stop, max_queue_len_exceeded, S};
	false ->
	    NQ = queue:in({Index, Offset, Len}, S#state.request_queue),
	    {noreply, S#state{request_queue = NQ}, 0}
    end;
handle_cast({cancel_piece, Index, OffSet, Len}, S) ->
    NQ = etorrent_utils:queue_remove({Index, OffSet, Len}, S#state.request_queue),
    {noreply, S#state{request_queue = NQ}, 0};
handle_cast(stop, S) ->
    {stop, normal, S}.


%% Terminating normally means we should inform our recv pair
terminate(_Reason, S) ->
    timer:cancel(S#state.timer),
    timer:cancel(S#state.rate_timer),
    ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: send_piece_message/2
%% Description: Send the message Msg and handle an eventual connection
%%   close gracefully.
%%--------------------------------------------------------------------
send_piece_message(Msg, S, Timeout) ->
    case etorrent_peer_communication:send_message(S#state.rate, S#state.socket, Msg) of
	{ok, R} ->
	    {atomic, _} = etorrent_peer:statechange(S#state.parent,
						    {upload_rate,
						     R#peer_rate.rate}),
	    {noreply, S#state { rate = R }, Timeout};
	{{error, closed}, R} ->
	    {stop, normal, S#state { rate = R}}
    end.

send_piece(Index, Offset, Len, S) ->
    case S#state.piece_cache of
	{I, Binary} when I == Index ->
	    <<_Skip:Offset/binary, Data:Len/binary, _R/binary>> = Binary,
	    Msg = {piece, Index, Offset, Data},
	    %% Track uploaded size for torrent (for the tracker)
	    ok = etorrent_torrent:statechange(S#state.torrent_id,
					      {add_upload, Len}),
	    %% Track the amount uploaded by this peer.

	    send_piece_message(Msg, S, 0);
	%% Update cache and try again...
	{I, _Binary} when I /= Index ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS);
	none ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS)
    end.

load_piece(Index, S) ->
    {ok, Piece} = etorrent_fs:read_piece(S#state.file_system_pid, Index),
    S#state{piece_cache = {Index, Piece}}.

send_message(Msg, S) ->
    send_message(Msg, S, 0).

send_message(Msg, S, Timeout) ->
    case etorrent_peer_communication:send_message(S#state.rate, S#state.socket, Msg) of
	{ok, Rate} ->
	    case etorrent_peer:statechange(S#state.parent,
					   {upload_rate, Rate#peer_rate.rate}) of
		{atomic, _} ->
		    {noreply, S#state { rate = Rate}, Timeout};
		{aborted, _} ->
		    %% May seem odd, but this may fail if we are about to stop,
		    %%  and then the stop command is right next in the message
		    %%  queue.
		    {noreply, S#state { rate = Rate}, Timeout}
	    end;
	{{error, ebadf}, R} ->
	    error_logger:info_report([caught_ebadf, S#state.socket]),
	    {stop, normal, S#state { rate = R}};
	{{error, closed}, R} ->
	    {stop, normal, S#state { rate = R}}
    end.
