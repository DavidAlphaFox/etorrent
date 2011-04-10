-module(etorrent_download).
-export([await_servers/1,
         update/2,
         request_chunks/3,
         chunk_dropped/4,
         chunk_fetched/4,
         chunk_stored/4]).

-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceset()    :: etorrent_pieceset:pieceset().
-type pieceindex()  :: etorrent_types:pieceindex().
-type chunkoffset() :: etorrent_types:chunkoffset().
-type chunklength() :: etorrent_types:chunklength().
-type chunkspec()   :: {pieceindex(), chunkoffset(), chunklength()}.

-type tupdate() :: {endgame, boolean()}.

-record(tservices, {
    torrent_id :: torrent_id(),
    in_endgame :: boolean(),
    pending    :: pid(),
    progress   :: pid(),
    histogram  :: pid(),
    endgame    :: pid()}).
-define(endgame(Handle), (Handle#tservices.in_endgame)).
-opaque tservices() :: #tservices{}.
-export_type([tservices/0]).


%% @doc
%% @end
-spec await_servers(torrent_id()) -> tservices().
await_servers(TorrentID) ->
    Pending   = etorrent_pending:await_server(TorrentID),
    Progress  = etorrent_progress:await_server(TorrentID),
    Histogram = etorrent_histogram:await_server(TorrentID),
    Endgame   = etorrent_endgame:await_server(TorrentID),
    Inendgame = etorrent_endgame:is_active(Endgame),
    Handle = #tservices{
        torrent_id=TorrentID,
        in_endgame=Inendgame,
        pending=Pending,
        progress=Progress,
        histogram=Histogram,
        endgame=Endgame},
    Handle.


%% @doc
%% @end
-spec update(tupdate(), tservices()) -> tservices().
update({endgame, Inendgame}, Handle) when is_boolean(Inendgame) ->
    Handle#tservices{in_endgame=Inendgame}.


%% @doc
%% @end
-spec request_chunks(non_neg_integer(), pieceset(), tservices()) ->
    {ok, assigned | not_interested | [chunkspec()]}.
request_chunks(Numchunks, Peerset, Handle) when ?endgame(Handle) ->
    #tservices{endgame=Endgame} = Handle,
    etorrent_chunkstate:request_chunks(Numchunks, Peerset, Endgame);

request_chunks(Numchunks, Peerset, Handle) ->
    #tservices{progress=Progress} = Handle,
    etorrent_chunkstate:request_chunks(Numchunks, Peerset, Progress).


%% @doc
%% @end
-spec chunk_dropped(pieceindex(), chunkoffset(), chunklength(), tservices()) -> ok.
chunk_dropped(Piece, Offset, Length, Handle) when ?endgame(Handle) ->
    #tservices{pending=Pending, endgame=Endgame} = Handle,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, Endgame),
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, Pending);

chunk_dropped(Piece, Offset, Length, Handle) ->
    #tservices{pending=Pending, progress=Progress} = Handle,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, Progress),
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, Pending).


%% @doc
%% @end
-spec chunk_fetched(pieceindex(), chunkoffset(), chunklength(), tservices()) -> ok.
chunk_fetched(Piece, Offset, Length, Handle) when ?endgame(Handle) ->
    #tservices{endgame=Endgame} = Handle,
    ok = etorrent_chunkstate:fetched(Piece, Offset, Length, Endgame);

chunk_fetched(_, _, _, _) ->
    ok.


%% @doc
%% @end
-spec chunk_stored(pieceindex(), chunkoffset(), chunklength(), tservices()) -> ok.
chunk_stored(Piece, Offset, Length, Handle) ->
   #tservices{pending=Pending, progress=Progress} = Handle,
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, Progress),
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, Pending).
