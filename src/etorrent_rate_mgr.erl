%%%-------------------------------------------------------------------
%%% File    : etorrent_rate_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Rate management process
%%%
%%% Created : 17 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_rate_mgr).

-include("peer_state.hrl").
-include("rate_mgr.hrl").
-include("etorrent_rate.hrl").

-behaviour(gen_server).

-define(DEFAULT_SNUB_TIME, 30).

%% API
-export([start_link/0,

         choke/2, unchoke/2, interested/2, not_interested/2,
         local_choke/2, local_unchoke/2,

         recv_rate/4, send_rate/3,

         get_state/2,
         get_torrent_rate/2,

         fetch_recv_rate/2,
         fetch_send_rate/2,
         select_state/2,

         global_rate/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { recv,
                 send,
                 state,

                 global_recv,
                 global_send}).

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

%% Send state information
choke(Id, Pid) -> gen_server:cast(?SERVER, {choke, Id, Pid}).
unchoke(Id, Pid) -> gen_server:cast(?SERVER, {unchoke, Id, Pid}).
interested(Id, Pid) -> gen_server:cast(?SERVER, {interested, Id, Pid}).
not_interested(Id, Pid) -> gen_server:cast(?SERVER, {not_interested, Id, Pid}).
local_choke(Id, Pid) -> gen_server:cast(?SERVER, {local_choke, Id, Pid}).
local_unchoke(Id, Pid) -> gen_server:cast(?SERVER, {local_unchoke, Id, Pid}).

-spec get_state(integer(), pid()) -> {value, boolean(), #peer_state{}}.
get_state(Id, Who) ->
    P = case ets:lookup(etorrent_peer_state, {Id, Who}) of
            [] -> #peer_state{}; % Pick defaults
            [Ps] -> Ps
        end,
    Snubbed = case ets:lookup(etorrent_recv_state, {Id, Who}) of
                [] -> false;
                [#rate_mgr { snub_state = normal}] -> false;
                [#rate_mgr { snub_state = snubbed}] -> true
              end,
    {value, Snubbed, P}.

select_state(Id, Who) ->
    case ets:lookup(etorrent_peer_state, {Id, Who}) of
        [] -> {value, #peer_state { }}; % Pick defaults
        [P] -> {value, P}
    end.

fetch_recv_rate(Id, Pid) -> fetch_rate(etorrent_recv_state, Id, Pid).
fetch_send_rate(Id, Pid) -> fetch_rate(etorrent_send_state, Id, Pid).

recv_rate(Id, Pid, Rate, SnubState) ->
    gen_server:cast(?SERVER, {recv_rate, Id, Pid, Rate, SnubState}).

-spec get_torrent_rate(integer(), leeching | seeding) -> {ok, float()}.
get_torrent_rate(Id, Direction) ->
    gen_server:call(?SERVER, {get_torrent_rate, Id, Direction}).

send_rate(Id, Pid, Rate) ->
    gen_server:cast(?SERVER, {send_rate, Id, Pid, Rate, unchanged}).

global_rate() ->
    gen_server:call(?SERVER, global_rate).

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
    RTid = ets:new(etorrent_recv_state, [protected, named_table,
                                         {keypos, #rate_mgr.pid}]),
    STid = ets:new(etorrent_send_state, [protected, named_table,
                                         {keypos, #rate_mgr.pid}]),
    StTid = ets:new(etorrent_peer_state, [protected, named_table,
                                         {keypos, #peer_state.pid}]),
    {ok, #state{ recv = RTid, send = STid, state = StTid,
                 global_recv = etorrent_rate:init(?RATE_FUDGE),
                 global_send = etorrent_rate:init(?RATE_FUDGE)}}.

% @todo Lift these calls out of the process.
handle_call(global_rate, _From, S) ->
    RR = sum_global_rate(etorrent_recv_state),
    SR = sum_global_rate(etorrent_send_state),
    {reply, {RR, SR}, S};
handle_call({get_torrent_rate, Id, Direction}, _F, S) ->
    Tab = case Direction of
            leeching -> etorrent_recv_state;
            seeding  -> etorrent_send_state
          end,
    Objects = ets:match_object(Tab, #rate_mgr { pid = {Id, '_'}, _ = '_' }),
    R = lists:sum([K#rate_mgr.rate || K <- Objects]),
    {reply, {ok, R}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({What, Id, Pid}, S) ->
    ok = alter_state(What, Id, Pid),
    {noreply, S};
handle_cast({What, Id, Who, Rate, SnubState}, S) ->
    ok = alter_state(What, Id, Who, Rate, SnubState),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    true = ets:match_delete(etorrent_recv_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_send_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_peer_state, #peer_state { pid = {'_', Pid}, _='_'}),
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
terminate(_Reason, _S) ->
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
sum_global_rate(Table) ->
    Objs = ets:match_object(Table, #rate_mgr { _ = '_' }),
    lists:sum([K#rate_mgr.rate || K <- Objs]).

alter_state(What, Id, Pid) ->
    _R = case ets:lookup(etorrent_peer_state, {Id, Pid}) of
        [] ->
            ets:insert(etorrent_peer_state,
              alter_record(What,
                           #peer_state { pid = {Id, Pid},
                                         choke_state = choked,
                                         interest_state = not_interested,
                                         local_choke = true})),
            erlang:monitor(process, Pid);
        [R] ->
            ets:insert(etorrent_peer_state,
                       alter_record(What, R))
    end,
    ok.

alter_record(What, R) ->
    case What of
        choke ->
            R#peer_state { choke_state = choked };
        unchoke ->
            R#peer_state { choke_state = unchoked };
        interested ->
            R#peer_state { interest_state = interested };
        not_interested ->
            R#peer_state { interest_state = not_interested };
        local_choke ->
            R#peer_state { local_choke = true };
        local_unchoke ->
            R#peer_state { local_choke = false}
    end.

alter_state(What, Id, Who, Rate, SnubState) ->
    T = case What of
            recv_rate -> etorrent_recv_state;
            send_rate -> etorrent_send_state
        end,
    _R = case ets:lookup(T, {Id, Who}) of
        [] ->
            ets:insert(T,
              #rate_mgr { pid = {Id, Who},
                          snub_state = case SnubState of
                                         snubbed -> snubbed;
                                         normal  -> normal;
                                         unchanged -> normal
                                       end,
                          rate = Rate }),
            erlang:monitor(process, Who);
        [R] ->
            ets:insert(T, R#rate_mgr { rate = Rate,
                                       snub_state =
                                            case SnubState of
                                              unchanged -> R#rate_mgr.snub_state;
                                              X         -> X
                                            end })
    end,
    ok.

fetch_rate(Where, Id, Pid) ->
    case ets:lookup(Where, {Id, Pid}) of
        [] ->
            none;
        [R] -> R#rate_mgr.rate
    end.

