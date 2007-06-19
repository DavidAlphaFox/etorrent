%%%-------------------------------------------------------------------
%%% File    : file_system.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : Implements access to the file system through
%%%               file_process processes.
%%%
%%% Created : 19 Jun 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(file_system).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { file_dict = none,
		 file_process_dict = none }).

%%====================================================================
%% API
%%====================================================================
start_link(FileDict) ->
    gen_server:start_link(?MODULE, [FileDict], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([FileDict]) ->
    {ok, #state{file_dict = FileDict,
	        file_process_dict = dict:new() }}.

handle_call({read_piece, PieceNum}, _From, State) ->
    read_piece(PieceNum, State);
handle_call({write_piece, PieceNum, Data}, _From, State) ->
    write_piece(PieceNum, Data, State).

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid}, S) ->
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
    Pid = file_process:start_link(Path),
    NewDict = dict:store(Path, Pid, S#state.file_process_dict),
    {ok, Pid, S#state{ file_process_dict = NewDict }}.

read_pieces_and_assemble([], FileData, S) ->
    {ok, list_to_binary(lists:reverse(FileData)), S};
read_pieces_and_assemble([{Path, Offset, Size} | Rest], Done, S) ->
    case dict:find(Path, S#state.file_process_dict) of
	{ok, Pid} ->
	    {ok, Data} = file_process:get_data(Pid, Offset, Size),
	    read_pieces_and_assemble(Rest, [Data | Done], S);
	error ->
	    {ok, Pid, NS} = create_file_process(Path, S),
	    {ok, Data} = file_process:get_data(Pid, Offset, Size),
	    read_pieces_and_assemble(Rest, [Data | Done], NS)
    end.

write_piece_data(Data, [], S) ->
    0 = size(Data),
    {ok, S};
write_piece_data(Data, [{Path, Offset, Size} | Rest], S) ->
    Bytes = Size * 8,
    <<Chunk:Bytes, Remaining>> = Data,
    case dict:fetch(Path, S#state.file_process_dict) of
	{ok, Pid} ->
	    ok = file_process:put_data(Pid, Chunk, Offset, Size),
	    write_piece_data(Remaining, Rest, S);
	error ->
	    {ok, Pid, NS} = create_file_process(Path, S),
	    ok = file_process:put_data(Pid, Chunk, Offset, Size),
	    write_piece_data(Remaining, Rest, NS)
    end.

read_piece(PieceNum, S) ->
    FilesToRead = dict:fetch(PieceNum, S#state.file_dict),
    {ok, Data, NS} = read_pieces_and_assemble(FilesToRead, [], S),
    {reply, {ok, Data}, NS}.

write_piece(PieceNum, Data, S) ->
    FilesToWrite = dict:fetch(PieceNum, S#state.file_dict),
    {ok, NS} = write_piece_data(Data, FilesToWrite, S),
    {reply, ok, NS}.

remove_file_process(Pid, Dict) ->
    erase_value(Pid, Dict).

erase_value(Value, Dict) ->
    Pred = fun(_K, V) ->
		   Value == V
	   end,
    Victim = dict:filter(Pred, Dict),
    [Key] = dict:fetch_keys(Victim),
    dict:erase(Key, Dict).

