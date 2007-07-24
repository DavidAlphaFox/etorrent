%%%-------------------------------------------------------------------
%%% File    : peer_communication.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : Various pieces of the peer protocol that takes a bit to
%%%   handle.
%%%
%%% Created : 26 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(peer_communication).

%% API
-export([initiate_handshake/4]).
-export([send_message/2, recv_message/1,
	 construct_bitfield/2, destruct_bitfield/2]).

-define(DEFAULT_HANDSHAKE_TIMEOUT, 120000).
-define(HANDSHAKE_SIZE, 68).
-define(PROTOCOL_STRING, "BitTorrent protocol").
-define(RESERVED_BYTES, 0:64/big).

%% Packet types
-define(CHOKE, 0:8).
-define(UNCHOKE, 1:8).
-define(INTERESTED, 2:8).
-define(NOT_INTERESTED, 3:8).
-define(HAVE, 4:8).
-define(BITFIELD, 5:8).
-define(REQUEST, 6:8).
-define(PIECE, 7:8).
-define(CANCEL, 8:8).
-define(PORT, 9:8).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: recv_message(Message)
%% Description: Receive a message from a peer and decode it
%%--------------------------------------------------------------------
recv_message(Message) ->
    case Message of
	<<>> ->
	    keep_alive;
	<<?CHOKE>> ->
	    choke;
	<<?UNCHOKE>> ->
	    unchoke;
	<<?INTERESTED>> ->
	    interested;
	<<?NOT_INTERESTED>> ->
	    not_interested;
	<<?HAVE, PieceNum:32/big>> ->
	    {have, PieceNum};
	<<?BITFIELD, BitField/binary>> ->
	    {bitfield, BitField};
	<<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>> ->
	    {request, Index, Begin, Len};
	<<?PIECE, Index:32/big, Begin:32/big, Len:32/big, Data/binary>> ->
	    {piece, Index, Begin, Len, Data};
	<<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>> ->
	    {cancel, Index, Begin, Len};
	<<?PORT, Port:16/big>> ->
	    {port, Port}
    end.

%%--------------------------------------------------------------------
%% Function: send_message(Socket, Message)
%% Description: Send a message on a socket
%%--------------------------------------------------------------------
send_message(Socket, Message) ->
    Datagram = case Message of
	       keep_alive ->
		   <<>>;
	       choke ->
		   <<1:32/big, ?CHOKE>>;
	       unchoke ->
		   <<1:32/big, ?UNCHOKE>>;
	       interested ->
		   <<1:32/big, ?INTERESTED>>;
	       not_interested ->
		   <<1:32/big, ?NOT_INTERESTED>>;
	       {have, PieceNum} ->
		   <<5:32/big, ?HAVE, PieceNum:32/big>>;
	       {bitfield, BitField} ->
		   Size = size(BitField)+1,
		   <<Size:32/big, ?BITFIELD, BitField/binary>>;
	       {request, Index, Begin, Len} ->
		   <<13:32/big, ?REQUEST,
		     Index:32/big, Begin:32/big, Len:32/big>>;
	       {piece, Index, Begin, Len, Data} ->
		   Size = size(Data)+9,
		   <<Size, ?PIECE, Index:32/big, Begin:32/big, Len:32/big,
		     Data/binary>>;
	       {cancel, Index, Begin, Len} ->
		   <<13:32/big, ?CANCEL,
		     Index:32/big, Begin:32/big, Len:32/big>>;
	       {port, PortNum} ->
		   <<3:32/big, ?PORT, PortNum:16/big>>
	  end,
    gen_tcp:send(Socket, Datagram).

%%--------------------------------------------------------------------
%% Function: initiate_handshake
%% Description: Handshake with a peer where we have initiated with him.
%%  This call is used if we are the initiator of a torrent handshake as
%%  we then know the peer_id completely.
%%--------------------------------------------------------------------
initiate_handshake(Socket, PeerId, MyPeerId, InfoHash) ->
    PSSize = length(?PROTOCOL_STRING),
    BinPeerId = list_to_binary(PeerId),
    % Since we are the initiator, send out this handshake
    Header = <<PSSize:8, ?PROTOCOL_STRING, ?RESERVED_BYTES>>,
    ok = gen_tcp:send(Socket, Header),
    ok = gen_tcp:send(Socket, InfoHash),
    ok = gen_tcp:send(Socket, MyPeerId),
    % Now, we wait for his handshake to arrive on the socket
    % Since we are the initiator, he is requested to fire off everything
    % to us.
    case gen_tcp:recv(Socket, ?HANDSHAKE_SIZE, ?DEFAULT_HANDSHAKE_TIMEOUT) of
	{ok, Packet} ->
	    <<PSL:8/integer, ?PROTOCOL_STRING, ReservedBytes:8/binary,
	      IH:20/binary, PI:20/binary>> = Packet,
	    if
		PSL /= PSSize ->
		    {error, packet_size_mismatch};
		IH /= InfoHash ->
		    {error, infohash_mismatch};
		PI /= BinPeerId ->
		    {error, peer_id_mismatch};
		true ->
		    {ok, ReservedBytes}
	    end;
	{error, X} ->
	    {error, X}
    end.

%%--------------------------------------------------------------------
%% Function: recv_handshake
%% Description: Receive a handshake message
%%--------------------------------------------------------------------
%% recv_handshake(Socket, PeerId, InfoHash) ->
%%     Size = size(build_handshake(PeerId, InfoHash)),
%%     {ok, Packet} = gen_tcp:recv(Socket, Size),
%%     <<PSL:8,
%%      ?PROTOCOL_STRING,
%%      _ReservedBytes:64/binary, IH:160/binary, PI:160/binary>> = Packet,
%%     if
%% 	PSL /= Size ->
%% 	    {error, "Size mismatch"};
%% 	IH /= InfoHash ->
%% 	    {error, "Infohash mismatch"};
%% 	true ->
%% 	    {ok, PI}
%%     end.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: construct_bitfield
%% Description: Construct a BitField for sending to the peer
%%--------------------------------------------------------------------
construct_bitfield(Size, PieceSet) ->
    PadBits = 8 - (Size rem 8),
    Bits = lists:append(
	     [utils:list_tabulate(
		Size,
		fun(N) ->
			case set:is_element(N, PieceSet) of
			    true -> 1;
			    false -> 0
			end
		end),
	      utils:list_tabulate(
	       PadBits,
	       fun(_N) -> 0 end)]),
    0 = length(Bits) rem 8,
    build_bytes(Bits).

build_bytes(BitField) ->
    build_bytes(BitField, []).

build_bytes([], Acc) ->
    lists:reverse(Acc);
build_bytes(L, Acc) ->
    {Byte, Rest} = lists:split(8, L),
    build_bytes(Rest, [bytify(Byte) | Acc]).

bytify([B1, B2, B3, B4, B5, B6, B7, B8]) ->
    <<B1:1/integer, B2:1/integer, B3:1/integer, B4:1/integer,
      B5:1/integer, B6:1/integer, B7:1/integer, B8:1/integer>>.

destruct_bitfield(Size, BinaryLump) ->
    ByteList = binary_to_list(BinaryLump),
    Numbers = decode_bytes(0, ByteList, []),
    PieceSet = sets:from_list(lists:flatten(Numbers)),
    case max_element(PieceSet) =< Size of
	true ->
	    {ok, PieceSet};
	false ->
	    {error, bitfield_had_wrong_padding}
    end.

max_element(Set) ->
    sets:fold(fun(E, Max) ->
		      case E > Max of
			  true ->
			      E;
			  false ->
			      Max
		      end
	      end, 0, Set).

decode_byte(B, Add) ->
    <<B1:1, B2:1, B3:1, B4:1, B5:1, B6:1, B7:1, B8:1>> = <<B>>,
    Select = lists:filter(fun(X) ->
				  case X of
				      {1, _} ->
					  true;
				      _ ->
					  false
				  end
			  end, [{B1, 1}, {B2, 2}, {B3, 3}, {B4, 4},
				{B5, 5}, {B6, 6}, {B7, 7}, {B8, 8}]),
    Res = lists:map(fun({_, N}) ->
		      N + Add
	      end, Select),
    Res.

decode_bytes(_SoFar, [], Numbers) ->
    Numbers;
decode_bytes(SoFar, [Byte | Rest], Numbers) ->
    decode_bytes(SoFar + 8, Rest, [decode_byte(Byte, SoFar) | Numbers]).

