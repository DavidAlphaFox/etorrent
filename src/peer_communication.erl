-module(peer_communication).

-export([recv_handshake/3, send_handshake/3]).
-export([send_message/2, recv_message/1]).

-define(PROTOCOL_STRING, "BitTorrent protocol").
-define(RESERVED_BYTES, <<0:64>>).

%% Packet types
-define(KEEP_ALIVE, 0:32/big).
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

recv_message(Message) ->
    case Message of
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

send_message(Socket, Message) ->
    Datagram = case Message of
	       keep_alive ->
		   <<?KEEP_ALIVE>>;
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
		   <<Size, ?PIECE, Index:32/big, Begin:32/big, Len:32/big, Data/binary>>;
	       {cancel, Index, Begin, Len} ->
		   <<13:32/big, ?CANCEL,
		     Index:32/big, Begin:32/big, Len:32/big>>;
	       {port, PortNum} ->
		   <<3:32/big, ?PORT, PortNum:16/big>>
	  end,
    gen_tcp:send(Socket, Datagram).

build_handshake(PeerId, InfoHash) ->
    PStringLength = length(?PROTOCOL_STRING),
    <<PStringLength:8, ?PROTOCOL_STRING, ?RESERVED_BYTES, InfoHash, PeerId>>.

send_handshake(Socket, PeerId, InfoHash) ->
    ok = gen_tcp:send(Socket, build_handshake(PeerId, InfoHash)).

recv_handshake(Socket, PeerId, InfoHash) ->
    Size = size(build_handshake(PeerId, InfoHash)),
    {ok, Packet} = gen_tcp:recv(Socket, Size),
    <<PSL:8,
     ?PROTOCOL_STRING,
     _ReservedBytes:64/binary, IH:160/binary, PI:160/binary>> = Packet,
    if
	PSL /= Size ->
	    {error, "Size mismatch"};
	IH /= InfoHash ->
	    {error, "Infohash mismatch"};
	true ->
	    {ok, PI}
    end.

