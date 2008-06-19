%%%-------------------------------------------------------------------
%%% File    : file_system.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Implements access to the file system through
%%%               file_process processes.
%%%
%%% Created : 19 Jun 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_fs).

-include("etorrent_mnesia_table.hrl").

-behaviour(gen_server).

%% API
-export([start_link/2, load_file_information/2,
	 stop/1, read_piece/2, write_piece/3, size_of_ops/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { torrent_id = none, %% id of torrent we are serving
		 file_pool = none,
		 file_process_dict = none}).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: size_of_ops(operation_list) -> integer()
%% Description: Return the file size of the given operations
%%--------------------------------------------------------------------
size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
                       Size + Total end,
               0,
               Ops).

%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Spawn and link a new file_system process
%%--------------------------------------------------------------------
start_link(IDHandle, FSPool) ->
    gen_server:start_link(?MODULE, [IDHandle, FSPool], []).

%%--------------------------------------------------------------------
%% Function: stop(Pid) -> ok
%% Description: Stop the file_system process identified by Pid
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%--------------------------------------------------------------------
%% Function: load_file_information(Pid, FileDict) -> ok
%% Description: Load the FileDict into the process and ask it to
%%   process requests from this filedict.
%%--------------------------------------------------------------------
load_file_information(Pid, FileDict) ->
    gen_server:cast(Pid, {load_filedict, FileDict}).

%%--------------------------------------------------------------------
%% Function: read_piece(Pid, N) -> {ok, Binary}
%% Description: Ask file_system process Pid to retrieve Piece N
%%--------------------------------------------------------------------
read_piece(Pid, Pn) ->
    gen_server:call(Pid, {read_piece, Pn}).

%%--------------------------------------------------------------------
%% Function: write_piece(Pid, N, Binary) -> ok | wrong_hash
%% Description: file_system process Pid is asked to write Binary into
%%   piece slot N. Returns either ok, or wrong_hash if the hash fails.
%%--------------------------------------------------------------------
write_piece(Pid, Pn, Data) ->
    gen_server:call(Pid, {write_piece, Pn, Data}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([IDHandle, FSPool]) when is_integer(IDHandle) ->
    {ok, #state{file_process_dict = dict:new(),
		file_pool = FSPool,
		torrent_id = IDHandle}}.

handle_call({read_piece, PieceNum}, _From, S) ->
    {atomic, [#piece { files = Operations}]} =
	etorrent_piece:get_piece(S#state.torrent_id, PieceNum),
    {ok, Data, NS} = read_pieces_and_assemble(Operations, [], S),
    {reply, {ok, Data}, NS};
handle_call({write_piece, PieceNum, Data}, _From, S) ->
    {atomic, [#piece { hash = Hash, files = FilesToWrite }]} =
	etorrent_piece:get_piece(S#state.torrent_id, PieceNum),
    D = iolist_to_binary(Data),
    case Hash == crypto:sha(D) of
	true ->
	    {ok, NS} = write_piece_data(D, FilesToWrite, S),
	    {reply, ok, NS};
	false ->
	    {reply, wrong_hash, S}
    end.


handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    Nd = remove_file_process(Pid, S#state.file_process_dict),
    {noreply, S#state { file_process_dict = Nd }};
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
create_file_process(Path, S) ->
    {ok, Pid} = etorrent_fs_pool_sup:add_file_process(S#state.file_pool, Path),
    erlang:monitor(process, Pid),
    NewDict = dict:store(Path, Pid, S#state.file_process_dict),
    {ok, Pid, S#state{ file_process_dict = NewDict }}.

read_pieces_and_assemble([], FileData, S) ->
    {ok, list_to_binary(lists:reverse(FileData)), S};
read_pieces_and_assemble([{Path, Offset, Size} | Rest], Done, S) ->
    case dict:find(Path, S#state.file_process_dict) of
	{ok, Pid} ->
	    Ref = make_ref(),
	    case catch({Ref,
			etorrent_fs_process:get_data(Pid, Offset, Size)}) of
		{Ref, {ok, Data}} ->
		    read_pieces_and_assemble(Rest, [Data | Done], S);
		{'EXIT', {noproc, _}} ->
		    D = remove_file_process(Pid, S#state.file_process_dict),
		    read_pieces_and_assemble([{Path, Offset, Size} | Rest],
					     Done,
					     S#state{file_process_dict = D})
	    end;
	error ->
	    {ok, Pid, NS} = create_file_process(Path, S),
	    {ok, Data} = etorrent_fs_process:get_data(Pid, Offset, Size),
	    read_pieces_and_assemble(Rest, [Data | Done], NS)
    end.

write_piece_data(<<>>, [], S) ->
    {ok, S};
write_piece_data(Data, [{Path, Offset, Size} | Rest], S) ->
    <<Chunk:Size/binary, Remaining/binary>> = Data,
    case dict:find(Path, S#state.file_process_dict) of
	{ok, Pid} ->
	    Ref = make_ref(),
	    case catch({Ref,
			etorrent_fs_process:put_data(Pid, Chunk,
						     Offset, Size)}) of
		{Ref, ok} ->
		    write_piece_data(Remaining, Rest, S);
		{'EXIT', {noproc, _}} ->
		    D = remove_file_process(Pid, S#state.file_process_dict),
		    write_piece_data(Data, [{Path, Offset, Size} | Rest],
				     S#state{file_process_dict = D})
	    end;
	error ->
	    {ok, Pid, NS} = create_file_process(Path, S),
	    ok = etorrent_fs_process:put_data(Pid, Chunk, Offset, Size),
	    write_piece_data(Remaining, Rest, NS)
    end.

remove_file_process(Pid, Dict) ->
    erase_value(Pid, Dict).

erase_value(Value, Dict) ->
    Pred = fun(_K, V) ->
		   Value == V
	   end,
    Victim = dict:filter(Pred, Dict),
    [Key] = dict:fetch_keys(Victim),
    dict:erase(Key, Dict).

