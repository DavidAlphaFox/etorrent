%%%-------------------------------------------------------------------
%%% File    : peer_communication.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Various pieces of the peer protocol that takes a bit to
%%%   handle.
%%%
%%% Created : 26 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(etorrent_peer_communication).

%% API
-export([initiate_handshake/3, receive_handshake/1,
	 complete_handshake/3]).
-export([send_message/3, recv_message/2,
	 construct_bitfield/2, destruct_bitfield/2]).

-define(DEFAULT_HANDSHAKE_TIMEOUT, 120000).
-define(HANDSHAKE_SIZE, 68).
-define(PROTOCOL_STRING, "BitTorrent protocol").

%% Extensions
-define(EXT_BASIS, 0). % The protocol basis
-define(EXT_FAST,  4). % The Fast Extension

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

%% FAST EXTENSION Packet types
-define(SUGGEST, 13:8).
-define(HAVE_ALL, 14:8).
-define(HAVE_NONE, 15:8).
-define(REJECT_REQUEST, 16:8).
-define(ALLOWED_FAST, 17:8).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: recv_message(Message) -> keep_alive | choke | unchoke |
%%   interested | not_interested | {have, integer()} | ...
%% Description: Receive a message from a peer and decode it
%%--------------------------------------------------------------------
recv_message(Rate, Message) ->
    MSize = size(Message),
    Decoded =
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
	    <<?PIECE, Index:32/big, Begin:32/big, Data/binary>> ->
		{piece, Index, Begin, Data};
	    <<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>> ->
		{cancel, Index, Begin, Len};
	    <<?PORT, Port:16/big>> ->
		{port, Port};
	    %% FAST EXTENSION MESSAGES
	    <<?SUGGEST, Index:32/big>> ->
		{suggest, Index};
	    <<?HAVE_ALL>> ->
		have_all;
	    <<?HAVE_NONE>> ->
		have_none;
	    <<?REJECT_REQUEST, Index:32, Offset:32, Len:32>> ->
		{reject_request, Index, Offset, Len};
	    <<?ALLOWED_FAST, FastSet/binary>> ->
		{allowed_fast, decode_allowed_fast(FastSet)}
	end,
    {Decoded, etorrent_rate:update(Rate, MSize), MSize}.

%%--------------------------------------------------------------------
%% Function: send_message(Socket, Message)
%% Description: Send a message on a socket
%%--------------------------------------------------------------------
send_message(Rate, Socket, Message) ->
    Datagram =
	case Message of
	    keep_alive ->
		<<>>;
	    choke ->
		<<?CHOKE>>;
	    unchoke ->
		<<?UNCHOKE>>;
	    interested ->
		<<?INTERESTED>>;
	    not_interested ->
		<<?NOT_INTERESTED>>;
	    {have, PieceNum} ->
		<<?HAVE, PieceNum:32/big>>;
	    {bitfield, BitField} ->
		<<?BITFIELD, BitField/binary>>;
	    {request, Index, Begin, Len} ->
		<<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>>;
	    {piece, Index, Begin, Data} ->
		<<?PIECE,
		 Index:32/big, Begin:32/big, Data/binary>>;
	    {cancel, Index, Begin, Len} ->
		<<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>>;
	    {port, PortNum} ->
		<<?PORT, PortNum:16/big>>;
	    %% FAST EXTENSION
	    {suggest, Index} ->
		<<?SUGGEST, Index:32>>;
	    have_all ->
		<<?HAVE_ALL>>;
	    have_none ->
		<<?HAVE_NONE>>;
	    {reject_request, Index, Offset, Len} ->
		<<?REJECT_REQUEST, Index, Offset, Len>>;
	    {allowed_fast, FastSet} ->
		BinFastSet = encode_fastset(FastSet),
		<<?ALLOWED_FAST, BinFastSet>>
        end,
    Sz = size(Datagram),
    Res = gen_tcp:send(Socket, <<Sz:32/big, Datagram/binary>>),
    {Res, etorrent_rate:update(Rate, Sz), Sz}.

%%--------------------------------------------------------------------
%% Function: receive_handshake(Socket) -> {ok, protocol_version,
%%                                             remote_peer_id()} |
%%                                       {ok, proto_version(),
%%                                            info_hash(),
%%                                            remote_peer_id()} |
%%                                        {error, Reason}
%% Description: Receive a handshake from another peer. In the receive,
%%  we don't send the info_hash, but expect the initiator to send what
%%  he thinks is the correct hash. For the return value, see the
%%  function receive_header()
%%--------------------------------------------------------------------
receive_handshake(Socket) ->
    Header = build_peer_protocol_header(),
    case gen_tcp:send(Socket, Header) of
	ok ->
	    receive_header(Socket, await);
	{error, X}  ->
	    {error, X}
    end.

%%--------------------------------------------------------------------
%% Function: initiate_handshake(socket(), peer_id(), info_hash()) ->
%%                                         {ok, protocol_version()} |
%%                                              {error, Reason}
%% Description: Handshake with a peer where we have initiated with him.
%%  This call is used if we are the initiator of a torrent handshake as
%%  we then know the peer_id completely.
%%--------------------------------------------------------------------
initiate_handshake(Socket, LocalPeerId, InfoHash) ->
    % Since we are the initiator, send out this handshake
    Header = build_peer_protocol_header(),
    try
	ok = gen_tcp:send(Socket, Header),
	ok = gen_tcp:send(Socket, InfoHash),
	ok = gen_tcp:send(Socket, LocalPeerId),
	receive_header(Socket, InfoHash)
    catch
	error:_ -> {error, stop}
    end.

%%--------------------------------------------------------------------
%% Function: complete_handshake/3
%% Args: Socket ::= socket()
%%       InfoHash ::= binary()
%%       LocalPeerId ::= binary()
%% Description: Complete a handshake.
%%--------------------------------------------------------------------
complete_handshake(Socket, InfoHash, LocalPeerId) ->
    Header = build_peer_protocol_header(),
    try
	ok = gen_tcp:send(Socket, Header),
	ok = gen_tcp:send(Socket, InfoHash),
	ok = gen_tcp:send(Socket, LocalPeerId),
	ok
    catch
	error:_ -> {error, stop}
    end.


%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: build_peer_protocol_header() -> binary()
%% Description: Returns the Peer Protocol header.
%%--------------------------------------------------------------------
build_peer_protocol_header() ->
    PSSize = length(?PROTOCOL_STRING),
    ReservedBytes = protocol_capabilities(),
    <<PSSize:8, ?PROTOCOL_STRING, ReservedBytes/binary>>.

protocol_capabilities() ->
    ProtoSpec = lists:sum([%?EXT_FAST,
			   ?EXT_BASIS]),
    <<ProtoSpec:64/big>>.

%%--------------------------------------------------------------------
%% Function: receive_header(socket()) -> {ok, proto_version(),
%%                                            remote_peer_id()} |
%%                                       {ok, proto_version(),
%%                                            info_hash(),
%%                                            remote_peer_id()} |
%%                                       {error, Reason}
%% Description: Receive the full header from a peer. The function
%% returns either with an error or successfully with a
%% protocol_version string, the infohash the remote sent us and his
%% peer_id.
%% --------------------------------------------------------------------
receive_header(Socket, InfoHash) ->
    %% Last thing we do on the socket, catch an error here.
    case gen_tcp:recv(Socket, ?HANDSHAKE_SIZE, ?DEFAULT_HANDSHAKE_TIMEOUT) of
	%% Fail if the header length is wrong
	{ok, <<PSL:8/integer, ?PROTOCOL_STRING, _:8/binary,
	       _IH:20/binary, _PI:20/binary>>}
	  when PSL /= length(?PROTOCOL_STRING) ->
	    {error, packet_size_mismatch};
	%% If the infohash is await, return the infohash along.
	{ok, <<_PSL:8/integer, ?PROTOCOL_STRING, ReservedBytes:64/big,
	       IH:20/binary, PI:20/binary>>}
	  when InfoHash =:= await ->
	    {ok, decode_protocol_capabilities(ReservedBytes), IH, PI};
	%% Infohash mismatches. Error it.
	{ok, <<_PSL:8/integer, ?PROTOCOL_STRING, _ReservedBytes:64/big,
	       IH:20/binary, _PI:20/binary>>}
	  when IH /= InfoHash ->
	    {error, infohash_mismatch};
	%% Everything ok
	{ok, <<_PSL:8/integer, ?PROTOCOL_STRING, ReservedBytes:64/big,
	       _IH:20/binary, PI:20/binary>>} ->
	    {ok, decode_protocol_capabilities(ReservedBytes), PI};
	%% This is not even a header!
	{ok, X} when is_binary(X) ->
	    {error, {bad_header, X}};
	%% Propagate errors upwards, most importantly, {error, closed}
	{error, Reason} ->
	    {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Function: decode_protocol_capabilities(Integer)
%% Description: Decode the capabilities of the protocol
%%--------------------------------------------------------------------
decode_protocol_capabilities(N) ->
    Capabilities = [{?EXT_FAST,  fast_extension}],
    lists:foldl(
      fun
	  ({M, Cap}, Acc) when (M band N) > 0 -> [Cap | Acc];
	  (_Capability, Acc) -> Acc
      end,
      Capabilities,
      []).

%%--------------------------------------------------------------------
%% Function: construct_bitfield
%% Description: Construct a BitField for sending to the peer
%%--------------------------------------------------------------------
construct_bitfield(Size, PieceSet) ->
    PadBits = 8 - (Size rem 8),
    F = fun(N) ->
		case gb_sets:is_element(N, PieceSet) of
		    true -> 1;
		    false -> 0
		end
	end,
    Bits = lists:append([F(N) || N <- lists:seq(0, Size-1)],
			[0 || _N <- lists:seq(1,PadBits)]),
    0 = length(Bits) rem 8,
    list_to_binary(build_bytes(Bits)).

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
    Numbers = decode_bytes(0, ByteList),
    PieceSet = gb_sets:from_list(lists:flatten(Numbers)),
    case max_element(PieceSet) < Size of
	true ->
	    {ok, PieceSet};
	false ->
	    {error, bitfield_had_wrong_padding}
    end.

max_element(Set) ->
    gb_sets:fold(fun(E, Max) ->
			 case E > Max of
			     true ->
				 E;
			     false ->
				 Max
			 end
		 end, 0, Set).

decode_byte(B, Add) ->
    <<B1:1/integer, B2:1/integer, B3:1/integer, B4:1/integer,
      B5:1/integer, B6:1/integer, B7:1/integer, B8:1/integer>> = <<B>>,
    Bytes = [{B1, 0}, {B2, 1}, {B3, 2}, {B4, 3},
	     {B5, 4}, {B6, 5}, {B7, 6}, {B8, 7}],
    [N+Add || {K, N} <- Bytes, K =:= 1].

decode_bytes(_SoFar, []) -> [];
decode_bytes(SoFar, [B | Rest]) ->
    [decode_byte(B, SoFar) | decode_bytes(SoFar + 8, Rest)].


decode_allowed_fast(<<>>) -> [];
decode_allowed_fast(<<Index:32, Rest/binary>>) ->
    [Index | decode_allowed_fast(Rest)].

encode_fastset([]) -> <<>>;
encode_fastset([Idx | Rest]) ->
    R = encode_fastset(Rest),
    <<R/binary, Idx:32>>.
