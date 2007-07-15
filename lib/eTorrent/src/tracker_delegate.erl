%%%-------------------------------------------------------------------
%%% File    : tracker_delegate.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Controls the communication with a tracker.
%%%
%%% Created : 12 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(tracker_delegate).

%%% TODO: Handle the TrackerId gracefully!

-behaviour(gen_fsm).

%% API
-export([start_link/5, contact_tracker_now/1]).

%% gen_fsm callbacks
-export([init/1, ready_to_contact/2, waiting_to_contact/2,
	 state_name/3, handle_event/3, handle_sync_event/4,
	 handle_info/3, terminate/3, code_change/4]).

-record(state, {should_contact_tracker = false,
	        state_pid = none,
	        url = none,
	        info_hash = none,
	        peer_id = none,
		trackerid = none,
	        control_pid = none}).

-define(SERVER, ?MODULE).
-define(DEFAULT_REQUEST_TIMEOUT, 180).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------
start_link(ControlPid, StatePid, Url, InfoHash, PeerId) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE,
		       [{ControlPid, StatePid, Url, InfoHash, PeerId}],
		       []).

contact_tracker_now(Pid) ->
    gen_fsm:send_event(Pid, contact_tracker_now).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to
%% initialize.
%%--------------------------------------------------------------------
init([{ControlPid, StatePid, Url, InfoHash, PeerId}]) ->
    {ok, ready_to_contact, #state{should_contact_tracker = false,
				  control_pid = ControlPid,
				  state_pid = StatePid,
				  url = Url,
				  info_hash = InfoHash,
				  peer_id = PeerId}}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName,
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also
%% called if a timeout occurs.
%%--------------------------------------------------------------------
ready_to_contact(contact_tracker_now, S) ->
    {ok, NextContactTime, NS} = contact_tracker(S),
    gen_fsm:start_timer(NextContactTime, may_contact),
    {next_state, ready_to_contact, NS};
ready_to_contact(may_contact, S) ->
    {next_state, ready_to_contact, S}.

waiting_to_contact(contact_tracker_now, S) ->
    {next_state, waiting_to_contact, S#state{should_contact_tracker = true}};
waiting_to_contact(may_contact, S) ->
    case S#state.should_contact_tracker of
	false ->
	    {next_state, ready_to_contact, S};
	true ->
	    {ok, NextContactTime, NS} = contact_tracker(S),
	    gen_fsm:start_timer(NextContactTime, may_contact),
	    {next_state, waiting_to_contact,
	     NS#state{should_contact_tracker = false}}
    end.


%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName,
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName,
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------
state_name(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, state_name, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, StateName, State) -> {next_state, NextStateName,
%%						  NextState} |
%%                                          {next_state, NextStateName,
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_sync_event(Event, From, StateName,
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState,
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState,
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState,
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
contact_tracker(S) ->
    contact_tracker(S, none).

contact_tracker(S, Event) ->
    NewUrl = build_tracker_url(S, Event),
    case http:request(NewUrl) of
	{ok, {{_, 200, _}, _, Body}} ->
	    case bcoding:decode(Body) of
		{ok, BC} ->
			handle_tracker_response(BC, S)
	    end
    end.

handle_tracker_response(BC, S) ->
    ControlPid = S#state.control_pid,
    StatePid = S#state.state_pid,
    RequestTime = find_next_request_time(BC),
    TrackerId = find_tracker_id(BC),
    Complete = find_completes(BC),
    Incomplete = find_incompletes(BC),
    NewIPs = find_ips_in_tracker_response(BC),
    ErrorMessage = fetch_error_message(BC),
    WarningMessage = fetch_warning_message(BC),
    if
	%% Change these casts!
	ErrorMessage /= none ->
	    torrent_control:tracker_error_report(ControlPid, ErrorMessage);
	WarningMessage /= none ->
	    torrent_control:tracker_warning_report(ControlPid, WarningMessage),
	    torrent_control:new_peers(ControlPid, NewIPs),
	    torrent_state:report_from_tracker(StatePid, Complete, Incomplete);
	true ->
	    torrent_control:new_peers(ControlPid, NewIPs),
	    torrent_state:report_from_tracker(StatePid, Complete, Incomplete)
    end,
    {ok, RequestTime, S#state{trackerid = TrackerId}}.

build_tracker_url(S, Event) ->
    E = case Event of
	    none ->
		"";
	    X -> lists:concat(["&event=", X])
	end,
    {ok, Downloaded, Uploaded, Left, Port} =
	torrent_state:report_to_tracker(S#state.state_pid),
    io:lib(
      "%s?info_hash=%s&peer_id=%s&uploaded=%B&downloaded=%B&left=%B&port=%B%s",
      [S#state.url, S#state.info_hash, S#state.peer_id,
       Uploaded, Downloaded, Left, Port, E]).

%%% Tracker response lookup functions
find_next_request_time(BCoded) ->
    bcoding:search_dict_default(BCoded, "interval", ?DEFAULT_REQUEST_TIMEOUT).

find_ips_in_tracker_response(BCoded) ->
    bcoding:search_dict_default(BCoded, "peers", []).

find_tracker_id(BCoded) ->
    bcoding:search_dict_default(BCoded, "trackerid", tracker_id_not_given).

find_completes(BCoded) ->
    bcoding:search_dict_default(BCoded, "complete", no_completes).

find_incompletes(BCoded) ->
    bcoding:search_dict_default(BCoded, "incomplete", no_incompletes).

fetch_error_message(BC) ->
    bcoding:search_dict_default(BC, "failure reason", none).

fetch_warning_message(BC) ->
    bcoding:search_dict_default(BC, "warning message", none).
