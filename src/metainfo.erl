%%%-------------------------------------------------------------------
%%% File    : metainfo.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : Code for manipulating the metainfo file
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(metainfo).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-vsn(1).

%% API
-export([get_piece_length/1, get_pieces/1, get_url/1, get_infohash/1,
	 parse/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: get_piece_length/1
%% Description: Search a torrent file, return the piece length
%%--------------------------------------------------------------------
get_piece_length(Torrent) ->
    case bcoding:search_dict({string, "info"}, Torrent) of
	{ok, D} ->
	    case bcoding:search_dict({string, "piece length"}, D) of
		{ok, {integer, Size}} ->
		    Size
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_pieces/1
%% Description: Search a torrent, return pieces as a list
%%--------------------------------------------------------------------
get_pieces(Torrent) ->
    case bcoding:search_dict({string, "info"}, Torrent) of
	{ok, D} ->
	    case bcoding:search_dict({string, "pieces"}, D) of
		{ok, {string, Ps}} ->
		    lists:map(fun(Str) -> list_to_binary(Str) end,
			      split_into_chunks(20, [], Ps))
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_url/1
%% Description: Return the URL of a torrent
%%--------------------------------------------------------------------
get_url(Torrent) ->
    case bcoding:search_dict({string, "announce"}, Torrent) of
	{ok, {string, Url}} ->
	    Url
    end.

%%--------------------------------------------------------------------
%% Function: get_infohash/1
%% Description: Return the infohash for a torrent
%%--------------------------------------------------------------------
get_infohash(Torrent) ->
    {ok, InfoDict} = bcoding:search_dict({string, "info"}, Torrent),
    {ok, InfoString} = bcoding:encode(InfoDict),
    Digest = crypto:sha(list_to_binary(InfoString)),
    %% We almost positively need to change this thing.
    hexify(Digest).

%%--------------------------------------------------------------------
%% Function: parse/1
%% Description: Parse a file into a Torrent structure.
%%--------------------------------------------------------------------
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

%%====================================================================
%% Internal functions
%%====================================================================

split_into_chunks(_N, Accum, []) ->
    Accum;
split_into_chunks(N, Accum, String) ->
    {Chunk, Rest} = lists:split(N, String),
    split_into_chunks(N, [Chunk | Accum], Rest).

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


hexify(Digest) ->
    Characters = lists:map(fun(Item) ->
				   lists:concat(io_lib:format("~.16B",
							      [Item])) end,
			   binary_to_list(Digest)),
    lists:concat(Characters).





