%%%-------------------------------------------------------------------
%%% File    : info_hash_map.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Global mapping of infohashes to peer groups and a mapping
%%%   of peers we are connected to.
%%%
%%% Created : 31 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------

%% TODO: When a peer dies, we need an automatic way to pull it out of
%%   the peer_map ETS. Either we grab the peer_group process and take it with
%%   the monitor, or we need seperate monitors on Peers. I am most keen on the
%%   first solution.
-module(etorrent_t_mapper).

-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").

%% API
-export([start_link/0, store_hash/1, remove_hash/1, lookup/1,
	 store_peer/4, remove_peer/1, is_connected_peer/3,
	 is_connected_peer_bad/3,
	 choked/1, unchoked/1, uploaded_data/2, downloaded_data/2,
	 interested/1, not_interested/1,
	 set_optimistic_unchoke/2,
	 remove_optimistic_unchoking/1,
	 interest_split/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { info_hash_map = none,
		 peer_map = none}).

-record(peer_info, {uploaded = 0,
		    downloaded = 0,
		    interested = false,
		    remote_choking = true,

		    optimistic_unchoke = false}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

store_hash(InfoHash) ->
    gen_server:call(?SERVER, {store_hash, InfoHash}).

remove_hash(InfoHash) ->
    gen_server:call(?SERVER, {remove_hash, InfoHash}).

store_peer(IP, Port, InfoHash, Pid) ->
    gen_server:call(?SERVER, {store_peer, IP, Port, InfoHash, Pid}).

remove_peer(Pid) ->
    gen_server:call(?SERVER, {remove_peer, Pid}).

is_connected_peer(IP, Port, InfoHash) ->
    gen_server:call(?SERVER, {is_connected_peer, IP, Port, InfoHash}).

% TODO: Change when we want to do smart peer handling.
is_connected_peer_bad(IP, Port, InfoHash) ->
    gen_server:call(?SERVER, {is_connected_peer, IP, Port, InfoHash}).

choked(Pid) ->
    gen_server:call(?SERVER, {modify_peer, Pid,
			      fun(PI) ->
				      PI#peer_info{remote_choking = true}
			      end}).

unchoked(Pid) ->
    gen_server:call(?SERVER, {modify_peer, Pid,
			      fun(PI) ->
				      PI#peer_info{remote_choking = false}
			      end}).

uploaded_data(Pid, Amount) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{
			       uploaded = PI#peer_info.uploaded + Amount}
		     end}).

downloaded_data(Pid, Amount) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{
			       downloaded = PI#peer_info.downloaded + Amount}
		     end}).

interested(Pid) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{interested = true}
		     end}).

not_interested(Pid) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{interested = false}
		     end}).

set_optimistic_unchoke(Pid, Val) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{optimistic_unchoke = Val}
		     end}).

remove_optimistic_unchoking(InfoHash) ->
    gen_server:call(?SERVER,
		    {remove_optistic_unchoking, InfoHash}).

interest_split(InfoHash) ->
    gen_server:call(?SERVER,
		    {interest_split, InfoHash}).

lookup(InfoHash) ->
    gen_server:call(?SERVER, {lookup, InfoHash}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{info_hash_map = ets:new(infohash_map, [named_table]),
	        peer_map      = ets:new(peer_map, [named_table])}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({store_peer, IP, Port, InfoHash, Pid}, _From, S) ->
    ets:insert(S#state.peer_map, {Pid, {IP, Port}, InfoHash, #peer_info{}}),
    {reply, ok, S};
handle_call({remove_peer, Pid}, _From, S) ->
    ets:match_delete(S#state.peer_map, {Pid, '_', '_', '_'}),
    {reply, ok, S};
handle_call({interest_split, InfoHash}, _From, S) ->
    % TODO: Can be optimized into a single call
    Intersted = find_interested_peers(S, InfoHash, true),
    NotInterested = find_interested_peers(S, InfoHash, false),
    {reply, {Intersted, NotInterested}, S};
handle_call({modify_peer, Pid, F}, _From, S) ->
    [[IPPort, InfoHash, PI]] = ets:match(S#state.peer_map,
					      {Pid, '$1', '$2', '$3'}),
    ets:insert(S#state.peer_map, {Pid, IPPort, InfoHash, F(PI)}),
    {reply, ok, S};
handle_call({remove_optistic_unchoking, InfoHash}, _From, S) ->
    Matches = ets:match(S#state.peer_map, {'$1', '$2', InfoHash, '$3'}),
    lists:foreach(fun([Pid, IPPort, PI]) ->
			  ets:insert(
			    S#state.peer_map,
			    {Pid, IPPort, InfoHash,
			     PI#peer_info{optimistic_unchoke = false}})
		  end,
		  Matches),
    {reply, ok, S};
handle_call({is_connected_peer, IP, Port, InfoHash}, _From, S) ->
    case ets:match(S#state.peer_map, {'_', {IP, Port}, InfoHash, '_'}) of
	[] ->
	    {reply, false, S};
	X when is_list(X) ->
	    {reply, true, S}
    end;
handle_call({store_hash, InfoHash}, {Pid, _Tag}, S) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(S#state.info_hash_map, {InfoHash, Pid, Ref}),
    {reply, ok, S};
handle_call({remove_hash, InfoHash}, {Pid, _Tag}, S) ->
    case ets:match(S#state.info_hash_map, {InfoHash, Pid, '$1'}) of
	[[Ref]] ->
	    erlang:demonitor(Ref),
	    ets:delete(S#state.info_hash_map, {InfoHash, Pid, Ref}),
	    {reply, ok, S};
	_ ->
	    error_logger:error_msg("Pid ~p is not in info_hash_map~n",
				   [Pid]),
	    {reply, ok, S}
    end;
handle_call({lookup, InfoHash}, _From, S) ->
    case ets:match(S#state.info_hash_map, {InfoHash, '$1', '_'}) of
	[[Pid]] ->
	    {reply, {ok, Pid}, S};
	[] ->
	    {reply, not_found, S}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    ets:match_delete(S#state.info_hash_map, {'_', Pid}),
    {noreply, S};
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
find_interested_peers(S, InfoHash, Val) ->
    MS = ets:fun2ms(fun({P, _IP, IH, PI})
		       when (PI#peer_info.interested == Val andalso
			     IH == InfoHash) ->
			    {P, PI#peer_info.downloaded, PI#peer_info.uploaded}
		    end),
    match:select(S#state.peer_map, MS).

%%--------------------------------------------------------------------
%% Function: reset_round(state(), InfoHash) -> ()
%% Description: Reset the amount of uploaded and downloaded data
%%--------------------------------------------------------------------
reset_round(S, InfoHash) ->
    Matches = ets:match(S#state.peer_map, {'$1', '$2', InfoHash, '$3'}),
    lists:foreach(fun([Pid, IPPort, PI]) ->
			  ets:insert(S#state.peer_map,
				     {Pid, IPPort, InfoHash,
				      PI#peer_info{uploaded = 0,
						   downloaded = 0}})
		  end,
		  Matches).
