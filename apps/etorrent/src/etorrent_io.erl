%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc File I/O subsystem.
%% <p>A directory server (this module) is responsible for maintaining
%% the opened/closed state for each file in a torrent.</p>
%%
%% == Pieces ==
%% The directory server is responsible for mapping each piece to a set
%% of file-blocks. A piece is only mapped to multiple blocks if it spans
%% multiple files.
%%
%% == Chunks ==
%% Chunks are mapped to a set of file blocks based on the file blocks that
%% contain the piece that the chunk is a member of.
%%
%% == Scheduling ==
%% Because there is a limit on the number of file descriptors that an
%% OS-process can have open at the same time the directory server
%% attempts to limit the amount of file servers that hold an actual
%% file handle to the file it is resonsible for.
%%
%% Each time a client intends to read/write to a file it notifies the
%% directory server. If the file is not a member of the set of open files
%% the server the file server to open a file handle to the file.
%%
%% When the limit on file servers keeping open file handles has been reached
%% the file server will notify the least recently used file server to close
%% its file handle for each notification for a file that is not in the set
%% of open files.
%%
%% == Guarantees ==
%% The protocol between the directory server and the file servers is
%% asynchronous, there is no guarantee that the number of open file handles
%% will never be larger than the specified number.
%%
%% == Synchronization ==
%% The gproc application is used to keep a registry of the process ids of
%% directory servers and file servers. A file server registers under a second
%% name when it has an open file handle. The support in gproc for waiting until a
%% name is registered is used to notify clients when the file server has an
%% open file handle.
%%
%% @end
-module(etorrent_io).
-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(AWAIT_TIMEOUT, 10*1000).

-export([start_link/2,
	     allocate/1,
         piece_size/2,
         piece_sizes/1,
         read_piece/2,
         read_chunk/4,
         aread_chunk/4,
         write_chunk/4,
         awrite_chunk/4,
         file_paths/1,
         file_sizes/1,
         file_indexes/1,
         schedule_operation/2,
         register_directory/1,
         lookup_directory/1,
         await_directory/1,
         register_file_server/2,
         lookup_file_server/2]).

-export([check_piece/3]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-type block_len() :: etorrent_types:block_len().
-type block_offset() :: etorrent_types:block_offset().
-type bcode() :: etorrent_types:bcode().
-type piece_bin() :: etorrent_types:piece_bin().
-type chunk_len() :: etorrent_types:chunk_len().
-type chunk_offset() :: etorrent_types:chunk_offset().
-type chunk_bin() :: etorrent_types:chunk_bin().
-type piece_index() :: etorrent_types:piece_index().
-type file_path() :: etorrent_types:file_path().
-type torrent_id() :: etorrent_types:torrent_id().
-type block_pos() :: {string(), block_offset(), block_len()}.

-record(state, {
    torrent :: torrent_id(),
    pieces  :: array(),
    file_list :: [{string(), pos_integer()}],
    file_wheel :: queue(), %% queue(free | pid())
    file_pids  :: tuple(),
    files_max  :: pos_integer()}).

%% @doc Start the File I/O Server
%% @end
-spec start_link(torrent_id(), bcode()) -> {'ok', pid()}.
start_link(TorrentID, Torrent) ->
    gen_server:start_link(?MODULE, [TorrentID, Torrent], []).

%% @doc Allocate bytes in the end of files in a torrent
%% @end
-spec allocate(torrent_id()) -> ok.
allocate(TorrentID) ->
    DirPid = await_directory(TorrentID),
    {ok, Files}  = get_files(DirPid),
    Dldir = etorrent_config:download_dir(),
    lists:foreach(
      fun ({Pth, ISz}) ->
	      F = filename:join([Dldir, Pth]),
	      Sz = filelib:file_size(F),
	      case ISz - Sz of
		  0 -> ok;
		  N when is_integer(N), N > 0 ->
		      allocate(TorrentID, Pth, N)
	      end
      end,
      Files),
    ok.

%% @doc Allocate bytes in the end of a file
%% @end
-spec allocate(torrent_id(), string(), integer()) -> ok.
allocate(TorrentId, FilePath, BytesToWrite) ->
    FilePid = await_file_server(TorrentId, FilePath),
    ok = etorrent_io_file:allocate(FilePid, BytesToWrite).

piece_sizes(Torrent) ->
    PieceMap  = make_piece_map(Torrent),
    AllPositions = array:sparse_to_orddict(PieceMap),
    [begin
        BlockLengths = [Length || {_, _, Length} <- Positions],
        PieceLength  = lists:sum(BlockLengths),
        {PieceIndex, PieceLength}
    end || {PieceIndex, Positions} <- AllPositions].

%% @doc
%% Read a piece into memory from disc.
%% @end
-spec read_piece(torrent_id(), piece_index()) -> {'ok', piece_bin()}.
read_piece(TorrentID, Piece) ->
    DirPid = await_directory(TorrentID),
    {ok, Positions, Filepids} = get_positions(DirPid, Piece),
    BlockList = read_file_blocks(TorrentID, Positions, Filepids),
    {ok, iolist_to_binary(BlockList)}.

%% @doc Request the size of a piece
%% <p>Returns `{ok, Size}' where `Size' is the amount of bytes in that piece</p>
%% @end
-spec piece_size(torrent_id(), piece_index()) -> {ok, integer()}.
piece_size(TorrentID, Piece) ->
    DirPid = await_directory(TorrentID),
    {ok, Positions, _Filepids} = get_positions(DirPid, Piece),
    {ok, lists:sum([L || {_, _, L} <- Positions])}.


%% @doc
%% Read a chunk from a piece by reading each of the file
%% blocks that make up the chunk and concatenating them.
%% @end
-spec read_chunk(torrent_id(), piece_index(),
                 chunk_offset(), chunk_len()) -> {'ok', chunk_bin()}.
read_chunk(TorrentID, Piece, Offset, Length) ->
    DirPid = await_directory(TorrentID),
    {ok, Positions, Filepids} = get_positions(DirPid, Piece),
    ChunkPositions  = chunk_positions(Offset, Length, Positions),
    BlockList = read_file_blocks(TorrentID, ChunkPositions, Filepids),
    {ok, iolist_to_binary(BlockList)}.


%% @doc Read a chunk from disk and send it to the calling process.
%% @end
-spec aread_chunk(torrent_id(), piece_index(),
                  chunk_offset(), chunk_len()) -> {ok, pid()}.
aread_chunk(TorrentID, Piece, Offset, Length) ->
    etorrent_io_req_sup:start_read(TorrentID, Piece, Offset, Length).


%% @doc
%% Write a chunk to a piece by writing parts of the block
%% to each file that the block occurs in.
%% @end
-spec write_chunk(torrent_id(), piece_index(),
                  chunk_offset(), chunk_bin()) -> 'ok'.
write_chunk(TorrentID, Piece, Offset, Chunk) ->
    DirPid = await_directory(TorrentID),
    {ok, Positions, Filepids} = get_positions(DirPid, Piece),
    Length = byte_size(Chunk),
    ChunkPositions = chunk_positions(Offset, Length, Positions),
    ok = write_file_blocks(TorrentID, Chunk, ChunkPositions, Filepids).


%% @doc Write a chunk and send an acknowledgment to the calling process.
%% @end
-spec awrite_chunk(torrent_id(), piece_index(),
                   chunk_offset(), chunk_bin()) -> ok.
awrite_chunk(TorrentID, Piece, Offset, Chunk) ->
    Length = byte_size(Chunk),
    {ok,_} = etorrent_io_req_sup:start_write(TorrentID, Piece, Offset, Length, Chunk),
    ok.


%% @doc
%% Read a list of block sequentially from the file
%% servers in this directory responsible for each path the
%% is included in the list of positions.
%% @end
-spec read_file_blocks(torrent_id(), list(block_pos()), tuple()) -> iolist().
read_file_blocks(_, [], _) ->
    [];
read_file_blocks(TorrentID, [{Index, Offset, Length}|T], Filepids) ->
    Filepid = element(Index, Filepids),
    {ok, Block} = etorrent_io_file:read(Filepid, Offset, Length),
    [Block|read_file_blocks(TorrentID, T, Filepids)].

%% @doc
%% Write a list of blocks of a chunk seqeuntially to the file servers
%% in this directory responsible for each path that is included
%% in the lists of positions at which the block appears.
%% @end
-spec write_file_blocks(torrent_id(), chunk_bin(),
        list(block_pos()), tuple()) -> 'ok'.
write_file_blocks(_, <<>>, [], _) ->
    ok;
write_file_blocks(TorrentID, Chunk, [{Index, Offset, Length}|T], Filepids) ->
    Filepid = element(Index, Filepids),
    <<Block:Length/binary, Rest/binary>> = Chunk,
    ok = etorrent_io_file:write(Filepid, Offset, Block),
    write_file_blocks(TorrentID, Rest, T, Filepids).

file_path_len(T) ->
    case etorrent_metainfo:get_files(T) of
	[One] -> [One];
	More when is_list(More) ->
	    Name = etorrent_metainfo:get_name(T),
	    [{filename:join([Name, Path]), Len} || {Path, Len} <- More]
    end.

%% @doc
%% Return the relative paths of all files included in the .torrent.
%% If the .torrent includes more than one file, the torrent name is
%% prepended to all file paths.
%% @end
file_paths(Torrent) ->
    [Path || {Path, _} <- file_path_len(Torrent)].

%% @doc
%% Returns the relative paths and sizes of all files included in the .torrent.
%% If the .torrent includes more than one file, the torrent name is prepended
%% to all file paths.
%% @end
file_sizes(Torrent) ->
    file_path_len(Torrent).

%% @doc Return a list of file indxes and the size.
%% This function has the same purpose as the file_sizes function.
%% @end
file_indexes(Torrent) ->
    file_indexes_(Torrent).

directory_name(TorrentID) ->
    {etorrent, TorrentID, directory}.

file_server_name(TorrentID, Path) ->
    {etorrent, TorrentID, Path, file}.


%% @doc
%% Register the current process as the directory server for
%% the given torrent.
%% @end
-spec register_directory(torrent_id()) -> true.
register_directory(TorrentID) ->
    etorrent_utils:register(directory_name(TorrentID)).

%% @end
%% Register the current process as the file server for the
%% file-path in the directory. A process being registered
%% as a file server does not imply that it can perform IO
%% operations on the behalf of IO clients.
%% @doc
-spec register_file_server(torrent_id(), file_path()) -> true.
register_file_server(TorrentID, Path) ->
    Dirpid = await_directory(TorrentID),
    is_integer(Path) andalso
        gen_server:cast(Dirpid, {register_filename, Path, self()}),
    etorrent_utils:register(file_server_name(TorrentID, Path)).

%% @doc
%% Lookup the process id of the directory server responsible
%% for the given torrent. If there is no such server registered
%% this function will crash.
%% @end
-spec lookup_directory(torrent_id()) -> pid().
lookup_directory(TorrentID) ->
    etorrent_utils:lookup(directory_name(TorrentID)).

%% @doc
%% Wait for the directory server for this torrent to appear
%% in the process registry.
%% @end
-spec await_directory(torrent_id()) -> pid().
await_directory(TorrentID) ->
    etorrent_utils:await(directory_name(TorrentID), ?AWAIT_TIMEOUT).

%% @doc
%% Lookup the process id of the file server responsible for
%% performing IO operations on this path. If there is no such
%% server registered this function will crash.
%% @end
-spec lookup_file_server(torrent_id(), file_path()) -> pid().
lookup_file_server(TorrentID, Path) ->
    etorrent_utils:lookup(file_server_name(TorrentID, Path)).

%% @doc
%% Wait for the file server responsible for the given file to start
%% and return the process id of the file server.
%% @end
-spec await_file_server(torrent_id(), file_path()) -> pid().
await_file_server(TorrentID, Path) ->
    etorrent_utils:await(file_server_name(TorrentID, Path), ?AWAIT_TIMEOUT).

%% @doc
%% Fetch the offsets and length of the file blocks of the piece
%% from this directory server.
%% @end
-spec get_positions(pid(), piece_index()) -> {'ok', list(block_pos())}.
get_positions(DirPid, Piece) ->
    gen_server:call(DirPid, {get_positions, Piece}).

%% @doc
%% Fetch the file list and lengths of files in the torrent
%% @end
-spec get_files(pid()) -> {ok, list({string(), pos_integer()})}.
get_files(Pid) ->
    gen_server:call(Pid, get_files).


%% @doc Request permission from the directory server to open a file handle.
%% @end
-spec schedule_operation(torrent_id(), file_path()) -> ok.
schedule_operation(TorrentID, Relpath) ->
    schedule_io_operation(TorrentID, Relpath).


%% @private
%% Notify the directory server that the current process intends
%% to perform an IO-operation on a file. This is so that the directory
%% can notify the file server to open it's file if needed.
-spec schedule_io_operation(torrent_id(), file_path()) -> ok.
schedule_io_operation(Directory, RelPath) ->
    DirPid = await_directory(Directory),
    gen_server:cast(DirPid, {schedule_operation, RelPath}).


%% @doc Validate a piece against a SHA1 hash.
%% This reads the piece into memory before it is hashed.
%% If the piece is valid the size of the piece is returned.
%% @end
-spec check_piece(torrent_id(), integer(),
                  <<_:160>>) -> {ok, integer()} | wrong_hash.
check_piece(TorrentID, Pieceindex, Piecehash) ->
    {ok, Piecebin} = etorrent_io:read_piece(TorrentID, Pieceindex),
    case crypto:sha(Piecebin) == Piecehash of
        true  -> {ok, byte_size(Piecebin)};
        false -> wrong_hash
    end.

%% ----------------------------------------------------------------------

%% @private
init([TorrentID, Torrent]) ->
    % Let the user define a limit on the amount of files
    % that will be open at the same time
    MaxFiles = etorrent_config:max_files(),
    true = register_directory(TorrentID),
    PieceMap  = make_piece_map(Torrent),
    Files     = make_file_list(Torrent),
    Filewheel = queue:from_list(lists:duplicate(MaxFiles, free)),
    FilePids  = list_to_tuple(lists:duplicate(length(Files), undefined)),
    InitState = #state{
        torrent=TorrentID,
        pieces=PieceMap,
        file_list=Files,
        file_wheel=Filewheel,
        file_pids=FilePids,
        files_max=MaxFiles},
    {ok, InitState}.

%% @private
handle_call(get_files, _From, #state{file_list=Filelist}=State) ->
    {reply, {ok, Filelist}, State};
handle_call({get_positions, Piece}, _, State) ->
    #state{pieces=PieceMap, file_pids=Filepids} = State,
    Positions = array:get(Piece, PieceMap),
    {reply, {ok, Positions, Filepids}, State}.

%% @private
handle_cast({register_filename, Index, Pid}, State) ->
    #state{file_pids=Filepids} = State,
    Filepids1 = setelement(Index, Filepids, Pid),
    State1 = State#state{file_pids=Filepids1},
    {noreply, State1};

handle_cast({schedule_operation, Index}, State) ->
    #state{file_wheel=Filewheel, file_pids=Filepids} = State,
    Filepid = element(Index, Filepids),
    {{value, Head}, Filewheel1} = queue:out(Filewheel),
    is_pid(Head) andalso etorrent_io_file:close(Head),
    ok = etorrent_io_file:open(Filepid),
    Filewheel2 = queue:in(Filepid, Filewheel1),
    State1 = State#state{file_wheel=Filewheel2},
    {noreply, State1}.

%% @private
handle_info(Msg, State) ->
    {stop, Msg, State}.

%% @private
terminate(_, _) ->
    not_implemented.

%% @private
code_change(_, _, _) ->
    not_implemented.

%% ----------------------------------------------------------------------

%%
%%
make_piece_map(Torrent) ->
    PieceLength = etorrent_metainfo:get_piece_length(Torrent),
    Files = file_indexes_(Torrent),
    Files1 = [{Index, Length} || {Index, _, Length} <- Files],
    MapEntries  = make_piece_map_(PieceLength, Files1),
    lists:foldl(fun({File, Piece, Offset, Length}, Acc) ->
        Prev = array:get(Piece, Acc),
        With = Prev ++ [{File, Offset, Length}],
        array:set(Piece, With, Acc)
    end, array:new({default, []}), MapEntries).

make_file_list(Torrent) ->
    Files = etorrent_metainfo:get_files(Torrent),
    Name = etorrent_metainfo:get_name(Torrent),
    case Files of
	[_] -> Files;
	[_|_] ->
	    [{filename:join([Name, Filename]), Size}
	     || {Filename, Size} <- Files]
    end.

%%
%% Calculate the positions where pieces start and continue in the
%% the list of files included in a torrent file.
%%
%% The piece offset is non-zero if the piece spans two files. The piece
%% index for the second entry should be the amount of bytes included
%% (length in output) in the first entry.
%%
make_piece_map_(PieceLength, FileLengths) ->
    make_piece_map_(PieceLength, 0, 0, 0, FileLengths).

make_piece_map_(_, _, _, _, []) ->
    [];
make_piece_map_(PieceLen, PieceOffs, Piece, FileOffs, [{File, Len}|T]=L) ->
    BytesToEnd = PieceLen - PieceOffs,
    case FileOffs + BytesToEnd of
        %% This piece ends at the end of this file
        NextOffs when NextOffs == Len ->
            Entry = {File, Piece, FileOffs, BytesToEnd},
            [Entry|make_piece_map_(PieceLen, 0, Piece+1, 0, T)];
        %% This piece ends in the middle of this file
        NextOffset when NextOffset < Len ->
            NewFileOffs  = FileOffs + BytesToEnd,
            Entry = {File, Piece, FileOffs, BytesToEnd},
            [Entry|make_piece_map_(PieceLen, 0, Piece+1, NewFileOffs, L)];
        %% This piece ends in the next file
        NextOffset when NextOffset > Len ->
            InThisFile = Len - FileOffs,
            NewPieceOffs = PieceOffs + InThisFile,
            Entry = {File, Piece, FileOffs, InThisFile},
            [Entry|make_piece_map_(PieceLen, NewPieceOffs, Piece, 0, T)]
    end.

%%
%% Calculate the positions where a chunk starts and continues in the
%% file blocks that make up a piece. 
%% Piece offset will only be non-zero at the initial call. After the block
%% has crossed a file boundry the offset of the block in the piece is zeroed
%% and the amount of bytes included in the first file block is subtracted 
%% from the chunk length.
%%
chunk_positions(_, _, []) ->
    [];

chunk_positions(ChunkOffs, ChunkLen, [{Path, FileOffs, BlockLen}|T]) ->
    LastBlockByte = FileOffs + BlockLen,
    EffectiveOffs = FileOffs + ChunkOffs,
    LastChunkByte = EffectiveOffs + ChunkLen,
    if  %% The first byte of the chunk is in the next file
        ChunkOffs > BlockLen ->
            NewChunkOffs = ChunkOffs - BlockLen,
            chunk_positions(NewChunkOffs, ChunkLen, T);
        %% The chunk ends at the end of this file block
        LastChunkByte =< LastBlockByte -> % false
            [{Path, EffectiveOffs, ChunkLen}];
        %% This chunk ends in the next file block
        LastChunkByte > LastBlockByte ->
            OutBlockLen = LastBlockByte - EffectiveOffs,
            NewChunkLen = ChunkLen - OutBlockLen,
            Entry = {Path, EffectiveOffs, OutBlockLen},
            [Entry|chunk_positions(0, NewChunkLen, T)]
    end.

%%
%% Each file has an alias which is the index of the file name within the
%% torrent file. This is used internally within, and only within, the io
%% subsystem because it uses less memory than the file name.
%%
file_indexes_(Torrent) ->
    Filelengths = file_path_len(Torrent),
    Paths = [Path || {Path, _} <- Filelengths],
    Lenghts = [Length || {_, Length} <- Filelengths],
    Indexes = lists:seq(1, length(Paths)),
    lists:zip3(Indexes, Paths, Lenghts).


-ifdef(TEST).
piece_map_0_test() ->
    Size  = 2,
    Files = [{a, 4}],
    Map   = [{a, 0, 0, 2}, {a, 1, 2, 2}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

piece_map_1_test() ->
    Size  = 2,
    Files = [{a, 2}, {b, 2}],
    Map   = [{a, 0, 0, 2}, {b, 1, 0, 2}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

piece_map_2_test() ->
    Size  = 2,
    Files = [{a, 3}, {b, 1}],
    Map   = [{a, 0, 0, 2}, {a, 1, 2, 1}, {b, 1, 0, 1}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

chunk_pos_0_test() ->
    Offs = 1,
    Len  = 3,
    Map  = [{a, 0, 4}],
    Pos  = [{a, 1, 3}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)).

chunk_pos_1_test() ->
    Offs = 2,
    Len  = 4,
    Map  = [{a, 1, 8}],
    Pos  = [{a, 3, 4}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_pos_2_test() ->
    Offs = 3,
    Len  = 9,
    Map  = [{a, 2, 4}, {b, 0, 10}],
    Pos  = [{a, 5, 1}, {b, 0, 8}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_post_3_test() ->
    Offs = 8,
    Len  = 5,
    Map  = [{a, 0, 3}, {b, 0, 13}],
    Pos  = [{b, 5, 5}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 
    
-endif.
