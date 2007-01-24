-module(torrent).
-behaviour(gen_server).

-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-export([parse/1, start_link/3, start/1, stop/1]).

-export([get_piece_length/1, get_pieces/1]).

-author("jesper.louis.andersen@gmail.com").

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Foo, State) ->
    {noreply, State}.

start_link(F, Torrent, PeerId) ->
    gen_server:start_link(torrent, {F, Torrent, PeerId}, []).

start(TorrentPid) ->
    gen_server:cast(TorrentPid, start).

stop(TorrentPid) ->
    gen_server:cast(TorrentPid, stop).

init({F, Torrent, PeerId}) ->
    {ok, StatePid} = gen_server:start_link(torrent_state, [], []),
    {ok, TrackerDelegatePid} = gen_server:start_link(tracker_delegate,
 						     {self(), StatePid,
 						      get_url(Torrent),
 						      get_infohash(Torrent),
 						      PeerId}, []),
    io:format("Process for torrent ~s started~n", [F]),
    {ok, {F, Torrent, StatePid, TrackerDelegatePid}}.

handle_call(_Call, _Who, S) ->
    {noreply, S}.

terminate_children(_StatePid, _TrackerDelegatePid) ->
    ok.

terminate(shutdown, {_F, _Torrent, StatePid, TrackerDelegatePid}) ->
    terminate_children(StatePid, TrackerDelegatePid),
    ok.

handle_cast(start, {F, Torrent, StatePid, TrackerDelegatePid}) ->
    gen_server:cast(TrackerDelegatePid, start),
    {noreply, {F, Torrent, StatePid, TrackerDelegatePid}};
handle_cast(stop, {_F, _Torrent, StatePid, TrackerDelegatePid}) ->
    gen_server:cast(StatePid, stop),
    gen_server:cast(TrackerDelegatePid, stop);


%% These are Error cases. We should just try again later (Default request timeout value)
handle_cast({tracker_request_failed, Err}, State) ->
    error_logger:error_msg("Tracker request failed ~s~n", [Err]),
    {noreply, State};
handle_cast({tracker_responded_not_bcode, Err}, State) ->
    error_logger:error_msg("Tracker did not respond with a bcoded dict: ~s~n", [Err]),
    {noreply, State}.

%%%%% Subroutines
parse(File) ->
    case file:open(File, [read]) of
	{ok, IODev} ->
	    Data = read_data(IODev),
	    case bcoding:decode(Data) of
		{ok, Torrent} ->
		    {ok, Torrent};
		{error, Reason} ->
		    {not_a_torrent, Reason}
	    end;
	{error, Reason} ->
	    {could_not_read_file, Reason}
    end.

read_data(IODev) ->
    eat_lines(IODev, []).

eat_lines(IODev, Accum) ->
    case io:get_chars(IODev, ">", 8192) of
	eof ->
	    lists:concat(lists:reverse(Accum));
	String ->
	    eat_lines(IODev, [String | Accum])
    end.

%% TODO: Implement the protocol for alternative URLs at some point.

get_url(Torrent) ->
    case bcoding:search_dict({string, "announce"}, Torrent) of
	{ok, {string, Url}} ->
	    Url
    end.

get_infohash(Torrent) ->
    {ok, InfoDict} = bcoding:search_dict({string, "info"}, Torrent),
    {ok, InfoString} = bcoding:encode(InfoDict),
    Digest = crypto:sha(list_to_binary(InfoString)),
    %% We almost positively need to change this thing.
    hexify(Digest).

get_piece_length(Torrent) ->
    {ok, InfoDict} = bcoding:search_dict({string, "info"}, Torrent),
    {ok, PL} = bcoding:search_dict({string, "piece_length"}, InfoDict),
    {integer, Size} = PL,
    Size.

get_pieces(Torrent) ->
    {ok, InfoDict} = bcoding:search_dict({string, "info"}, Torrent),
    {ok, PString} = bcoding:search_dict({string, "pieces"}, InfoDict),
    {string, Ps} = PString,
    split_into_chunks(20, [], Ps).

split_into_chunks(_N, Accum, []) ->
    Accum;
split_into_chunks(N, Accum, String) ->
    {Chunk, Rest} = lists:split(N, String),
    split_into_chunks(N, [Chunk | Accum], Rest).

hexify(Digest) ->
    Characters = lists:map(fun(Item) ->
				   lists:concat(io_lib:format("~.16B",
							      [Item])) end,
			   binary_to_list(Digest)),
    lists:concat(Characters).



