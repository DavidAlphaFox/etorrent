%%%-------------------------------------------------------------------
%%% File    : torrent_peer_send.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(torrent_peer_send).

-behaviour(gen_server).

%% API
-export([start_link/2, send/2, request/4, cancel/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {socket = none,
	        request_queue = none,

	        piece_cache = none,
	        file_system_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 64). % Maximal number of requests a peer may make.
%%====================================================================
%% API
%%====================================================================
start_link(Socket, FilesystemPid) ->
    gen_server:start_link(?MODULE,
			  [Socket, FilesystemPid], []).

send(Pid, Msg) ->
    gen_server:cast(Pid, {send, Msg}).

request(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {request_piece, Index, Offset, Len}).

cancel(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {cancel_piece, Index, Offset, Len}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, FilesystemPid]) ->
    {ok,
     #state{socket = Socket,
	    request_queue = queue:new(),
	    file_system_pid = FilesystemPid},
     ?DEFAULT_KEEP_ALIVE_INTERVAL}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, 0}.

handle_cast({send, Message}, S) ->
    ok = peer_communication:send_message(S#state.socket,
					 Message),
    {noreply, S, 0};
handle_cast({request_piece, Index, Offset, Len}, S) ->
    Requests = length(S#state.request_queue),
    if
	Requests > ?MAX_REQUESTS ->
	    {stop, max_queue_len_exceeded, S};
	true ->
	    NQ = queue:in({Index, Offset, Len}, S#state.request_queue),
	    {noreply, S#state{request_queue = NQ}, 0}
    end;
handle_cast({cancel_piece, Index, OffSet, Len}, S) ->
    NQ = utils:queue_remove({Index, OffSet, Len}, S#state.request_queue),
    {noreply, S#state{request_queue = NQ}, 0}.

handle_info(timeout, S) ->
    case queue:out(S#state.request_queue) of
	{empty, Q} ->
	    ok = peer_communication:send_message(S#state.socket, keep_alive),
	    {noreply,
	     S#state{request_queue = Q},
	     ?DEFAULT_KEEP_ALIVE_INTERVAL};
	{{value, {Index, Offset, Len}}, NQ} ->
	    NS = send_piece(Index, Offset, Len, S),
	    {noreply,
	     NS#state{request_queue = NQ},
	     0}
    end.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
send_piece(Index, Offset, Len, S) ->
    case S#state.piece_cache of
	{I, Binary} when I == Index ->
	    <<_Skip:Offset/binary, Data:Len/binary, _R/binary>> = Binary,
	    Msg = {piece, Index, Offset, Len, Data},
	    ok = peer_communication:send_message(S#state.socket,
						 Msg),
	    S;
	{I, _Binary} when I /= Index ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS);
	none ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS)
    end.

load_piece(Index, S) ->
    {ok, Piece} = file_system:read_piece(S#state.file_system_pid, Index),
    S#state{piece_cache = {Index, Piece}}.
