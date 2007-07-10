%%%-------------------------------------------------------------------
%%% File    : torrent_piecemap.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : Maintain a map of pieces downloaded and what is missing
%%%
%%% Created : 31 Jan 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(torrent_piecemap).

-behaviour(gen_server).

%% API
-export([request_piece/3, start_link/1, peer_got_piece/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%%-record(state, {}).

%%====================================================================
%% API
%%====================================================================
start_link(Amount) ->
    gen_server:start_link(?MODULE, Amount, []).

%%--------------------------------------------------------------------
%% Function: request_piece(Pid, TorrentId, PiecesPeerHas)
%% Description: Request a new batch of pieces
%%--------------------------------------------------------------------
request_piece(Pid, _TorrentId, PiecesPeerHas) ->
    gen_server:call(Pid, {request_piece, PiecesPeerHas}).

%%--------------------------------------------------------------------
%% Function: peer_got_piece(Pid, Piece)
%% Description: Called whenever a peer has a new piece
%%--------------------------------------------------------------------
peer_got_piece(Pid, Piece) ->
    gen_server:call(Pid, {peer_got_piece, Piece}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(NumberOfPieces) ->
    PieceTable = initialize_piece_table(NumberOfPieces),
    {ok, PieceTable}.

handle_call({request_piece, PiecesPeerHas}, Who, PieceTable) ->
    case find_appropriate_piece(PieceTable, Who, PiecesPeerHas) of
	{ok, P} ->
	    {reply, {piece_to_get, P}};
	none_applies ->
	    {reply, no_pieces_are_interesting}
    end;
handle_call({peer_got_piece, _Piece}, _Who, S) ->
    {reply, interested, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
initialize_piece_table(Amount) ->
    Table = ets:new(piece_table, []),
    populate_table(Table, Amount).

populate_table(Table, 0) ->
    Table;
populate_table(Table, N) ->
    ets:insert(Table, {N, unclaimed}),
    populate_table(Table, N-1).

find_appropriate_piece(PieceTable, Who, PiecesPeerHas) ->
    case find_eligible_pieces(PiecesPeerHas, PieceTable) of
	{ok, Pieces} ->
	    P = pick_random(Pieces),
	    mark_as_requested(PieceTable, P, Who),
	    {ok, P};
	none ->
	    none_applies
    end.

mark_as_requested(PieceTable, PNum, Who) ->
    ets:insert(PieceTable, {PNum, Who}).

find_eligible_pieces(PiecesPeerHas, PieceTable) ->
    Unclaimed = sets:from_list(ets:select(PieceTable, [{{'$1', unclaimed}, [], ['$1']}])),
    Eligible = sets:intersection(Unclaimed, PiecesPeerHas),
    EligibleSize = sets:size(Eligible),
    if
	EligibleSize > 0 ->
	    {ok, Eligible};
	true ->
	    none
    end.

pick_random(PieceSet) ->
    Size = sets:size(PieceSet),
    {ok, N} = random_source:pick_random_piece(Size),
    lists:nth(N, sets:to_list(PieceSet)).


