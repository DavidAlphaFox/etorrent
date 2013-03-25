-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([seed_leech/0, seed_leech/1,
     choked_seed_leech/0, choked_seed_leech/1,
	 seed_transmission/0, seed_transmission/1,
	 leech_transmission/0, leech_transmission/1,
     bep9/0, bep9/1,
     partial_downloading/0, partial_downloading/1
     ]).


suite() ->
    [{timetrap, {minutes, 3}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    %% Check or create read-only files, put them into data_dir.
    %% Many of this files will be copied into node directories.
    Directory = ?config(data_dir, Config),
%%  file:set_cwd(Directory),
    ct:pal("Data directory: ~s~n", [Directory]),
    AutoDir = filename:join(Directory, autogen),
    file:make_dir(AutoDir),
    Fn            = filename:join([AutoDir, "file30m.random"]),
    Dir           = filename:join([AutoDir, "dir2x30m.random"]),
    DumpTorrentFn = filename:join([AutoDir, "file30m-trackerless.torrent"]),
    HTTPTorrentFn = filename:join([AutoDir, "file30m-http.torrent"]),
    UDPTorrentFn  = filename:join([AutoDir, "file30m-udp.torrent"]),
    DirTorrentFn  = filename:join([AutoDir, "dir2x30m.torrent"]),
    ensure_random_file(Fn),
    ensure_random_file(Fn),
    ensure_random_dir(Dir),
    ensure_torrent_file(Fn,  HTTPTorrentFn, "http"),
    ensure_torrent_file(Fn,  UDPTorrentFn,  "udp"),
    ensure_torrent_file(Dir, DirTorrentFn,  "http"),
    ensure_torrent_file(Dir, DumpTorrentFn),
    %% Literal infohash.
    %% Both HTTP and UDP versions have the same infohash.
    {ok, TorrentIH}    = etorrent_dotdir:info_hash(HTTPTorrentFn),
    {ok, DirTorrentIH} = etorrent_dotdir:info_hash(DirTorrentFn),
    %% Start slave nodes.
    {ok, SeedNode}       = test_server:start_node(seeder, slave, []),
    {ok, LeechNode}      = test_server:start_node(leecher, slave, []),
    {ok, MiddlemanNode}  = test_server:start_node(middleman, slave, []),
    {ok, ChokedSeedNode} = test_server:start_node(choked_seeder, slave, []),
    %% Run logger on the slave nodes
    [prepare_node(Node)
     || Node <- [SeedNode, LeechNode, MiddlemanNode, ChokedSeedNode]],
    TrackerPid = start_opentracker(Directory),
    [{trackerless_torrent_file, DumpTorrentFn},
     {http_torrent_file, HTTPTorrentFn},
     {udp_torrent_file, UDPTorrentFn},
     {dir_torrent_file, DirTorrentFn},

     %% Names of data on which torrents are based.
     {data_filename, Fn},
     {data_dirname, Dir},

     {info_hash_hex, TorrentIH},
     {dir_info_hash_hex, DirTorrentIH},

     {info_hash_int, hex_to_int_hash(TorrentIH)},
     {dir_info_hash_int, hex_to_int_hash(DirTorrentIH)},

     {info_hash_bin, hex_to_bin_hash(TorrentIH)},
     {dir_info_hash_bin, hex_to_bin_hash(DirTorrentIH)},

     {tracker_port, TrackerPid},

     {leech_node, LeechNode},
     {middleman_node, MiddlemanNode},
     {choked_seed_node, ChokedSeedNode},
     {seed_node, SeedNode} | Config].



end_per_suite(Config) ->
    Pid = ?config(tracker_port, Config),
    LN = ?config(leech_node, Config),
    SN = ?config(seed_node, Config),
    stop_opentracker(Pid),
    test_server:stop_node(SN),
    test_server:stop_node(LN),
    ok.


init_per_testcase(leech_transmission, Config) ->
    %% transmission => etorrent
    PrivDir   = ?config(priv_dir, Config),
    DataDir   = ?config(data_dir, Config),
    TorrentFn = ?config(http_torrent_file, Config),
    Node      = ?config(leech_node, Config),
    Fn        = ?config(data_filename, Config),
    %% Transmission's working directory
    TranDir = file:join([PrivDir, transmission]),
    NodeDir = filename:join([PrivDir,  leech]),
    BaseFn  = filename:basename(Fn),
    SrcFn   = filename:join([NodeDir, "downloads", BaseFn]),
    DestFn  = filename:join([TranDir, BaseFn]),
    file:make_dir(TranDir),
    {ok, _} = copy_to(filename:join([DataDir, "transmission", "settings.json"]),
	             	  TranDir),
    %% Feed transmission the file to work with
    {ok, _} = file:copy(Fn, SrcFn),
    {Ref, Pid} = start_transmission(DataDir, TranDir, TorrentFn),
    ok = ct:sleep({seconds, 10}), %% Wait for transmission to start up
    create_standard_directory_layout(NodeDir),
    NodeConf = leech_configuration(NodeDir),
    start_app(Node, NodeConf), %% Start etorrent on the leecher node
    [{transmission_port, {Ref, Pid}},
     {src_filename, SrcFn},
     {dest_filename, DestFn},
     {transmission_dir, TranDir},
     {node_dir, NodeDir} | Config];

init_per_testcase(seed_transmission, Config) ->
    %% etorrent => transmission
    PrivDir   = ?config(priv_dir, Config),
    DataDir   = ?config(data_dir, Config),
    TorrentFn = ?config(http_torrent_file, Config),
    Node      = ?config(seed_node, Config),
    Fn        = ?config(data_filename, Config),
    %% Transmission's working directory
    TranDir = file:join([PrivDir, transmission]),
    NodeDir = filename:join([PrivDir,  seed]),
    BaseFn  = filename:basename(Fn),
    DestFn  = filename:join([NodeDir, "downloads", BaseFn]),
    SrcFn   = filename:join([TranDir, BaseFn]),
    file:make_dir(TranDir),
    {ok, _} = copy_to(filename:join([DataDir, "transmission", "settings.json"]),
	             	  TranDir),
    {Ref, Pid} = start_transmission(DataDir, TranDir, TorrentFn),
    ok = ct:sleep({seconds, 8}), %% Wait for transmission to start up
    NodeDir  = filename:join([PrivDir,  seed]),
    create_standard_directory_layout(NodeDir),
    NodeConf = seed_configuration(NodeDir),
    %% Feed etorrent the file to work with
    {ok, _} = file:copy(Fn, SrcFn),
    %% Copy torrent-file to torrents-directory
    {ok, _} = copy_to(TorrentFn, ?config(dir, NodeConf)),
    start_app(Node, NodeConf),
    [{transmission_port, {Ref, Pid}},
     {src_filename, SrcFn},
     {dest_filename, DestFn},
     {transmission_dir, TranDir},
     {node_dir, NodeDir} | Config];

init_per_testcase(seed_leech, Config) ->
    %% etorrent => etorrent
    PrivDir   = ?config(priv_dir, Config),
    TorrentFn = ?config(http_torrent_file, Config),
    SNode     = ?config(seed_node, Config),
    LNode     = ?config(leech_node, Config),
    Fn        = ?config(data_filename, Config),
    %% Transmission's working directory
    SNodeDir = filename:join([PrivDir,  seed]),
    LNodeDir = filename:join([PrivDir,  leech]),
    BaseFn   = filename:basename(Fn),
    SrcFn    = filename:join([SNodeDir, "downloads", BaseFn]),
    DestFn   = filename:join([LNodeDir, "downloads", BaseFn]),
    create_standard_directory_layout(SNodeDir),
    create_standard_directory_layout(LNodeDir),
    SNodeConf = seed_configuration(SNodeDir),
    LNodeConf = leech_configuration(LNodeDir),
    %% Feed etorrent the file to work with
    {ok, _} = file:copy(Fn, SrcFn),
    %% Copy torrent-file to torrents-directory
    {ok, _} = copy_to(TorrentFn, ?config(dir, SNodeConf)),
    start_app(SNode, SNodeConf),
    start_app(LNode, LNodeConf),
    [{src_filename, SrcFn},
     {dest_filename, DestFn},
     {seed_node_dir, SNodeDir},
     {leech_node_dir, LNodeDir} | Config];

init_per_testcase(choked_seed_leech, Config) ->
    %% etorrent => etorrent, one seed is choked (refuse to work).
    PrivDir   = ?config(priv_dir, Config),
    TorrentFn = ?config(http_torrent_file, Config),
    SNode     = ?config(seed_node, Config),
    CNode     = ?config(choked_seed_node, Config),
    LNode     = ?config(leech_node, Config),
    Fn        = ?config(data_filename, Config),
    %% Transmission's working directory
    SNodeDir = filename:join([PrivDir,  seed]),
    LNodeDir = filename:join([PrivDir,  leech]),
    CNodeDir = filename:join([PrivDir,  choked_seed]),
    BaseFn   = filename:basename(Fn),
    SSrcFn   = filename:join([SNodeDir, "downloads", BaseFn]),
    CSrcFn   = filename:join([CNodeDir, "downloads", BaseFn]),
    DestFn   = filename:join([LNodeDir, "downloads", BaseFn]),
    create_standard_directory_layout(SNodeDir),
    create_standard_directory_layout(LNodeDir),
    create_standard_directory_layout(CNodeDir),
    SNodeConf = seed_configuration(SNodeDir),
    LNodeConf = leech_configuration(LNodeDir),
    CNodeConf = choked_seed_configuration(CNodeDir),
    %% Feed etorrent the file to work with
    {ok, _} = file:copy(Fn, SSrcFn),
    {ok, _} = file:copy(Fn, CSrcFn),
    %% Copy torrent-file to torrents-directory
    {ok, _} = copy_to(TorrentFn, ?config(dir, SNodeConf)),
    {ok, _} = copy_to(TorrentFn, ?config(dir, CNodeConf)),
    start_app(CNode, CNodeConf),
    start_app(SNode, SNodeConf),
    start_app(LNode, LNodeConf),
    [{src_filename, SSrcFn},
     {dest_filename, DestFn},
     {choked_seed_node_dir, CNodeDir},
     {seed_node_dir, SNodeDir},
     {leech_node_dir, LNodeDir} | Config];
init_per_testcase(partial_downloading, Config) ->
    %% etorrent => etorrent
    %% passing a part of a directory
    PrivDir   = ?config(priv_dir, Config),
    TorrentFn = ?config(http_torrent_file, Config),
    SNode     = ?config(seed_node, Config),
    LNode     = ?config(leech_node, Config),
    Fn        = ?config(data_dirname, Config),
    %% Transmission's working directory
    SNodeDir = filename:join([PrivDir,  seed]),
    LNodeDir = filename:join([PrivDir,  leech]),
    BaseFn   = filename:basename(Fn),
    SrcFn    = filename:join([SNodeDir, "downloads", BaseFn]),
    DestFn   = filename:join([LNodeDir, "downloads", BaseFn]),
    create_standard_directory_layout(SNodeDir),
    create_standard_directory_layout(LNodeDir),
    SNodeConf = seed_configuration(SNodeDir),
    LNodeConf = leech_configuration(LNodeDir),
    %% Feed etorrent the directory to work with
    copy_r(Fn, SrcFn),
    %% Copy torrent-file to torrents-directory
    {ok, _} = copy_to(TorrentFn, ?config(dir, SNodeConf)),
    start_app(SNode, SNodeConf),
    start_app(LNode, LNodeConf),
    [{src_filename, SrcFn},
     {dest_filename, DestFn},
     {seed_node_dir, SNodeDir},
     {leech_node_dir, LNodeDir} | Config];
init_per_testcase(bep9, Config) ->
    %% etorrent => etorrent, using DHT and bep9.
    %% Middleman is an empty node.
    PrivDir   = ?config(priv_dir, Config),
    TorrentFn = ?config(trackerless_torrent_file, Config),
    SNode     = ?config(seed_node, Config),
    MNode     = ?config(middleman_node, Config),
    LNode     = ?config(leech_node, Config),
    Fn        = ?config(data_filename, Config),
    %% Transmission's working directory
    SNodeDir = filename:join([PrivDir,  seed]),
    LNodeDir = filename:join([PrivDir,  leech]),
    MNodeDir = filename:join([PrivDir,  middleman]),
    BaseFn   = filename:basename(Fn),
    SrcFn    = filename:join([SNodeDir, "downloads", BaseFn]),
    DestFn   = filename:join([LNodeDir, "downloads", BaseFn]),
    create_standard_directory_layout(SNodeDir),
    create_standard_directory_layout(LNodeDir),
    create_standard_directory_layout(MNodeDir),
    SNodeConf = seed_configuration(SNodeDir),
    LNodeConf = leech_configuration(LNodeDir),
    MNodeConf = middleman_configuration(MNodeDir),
    %% Feed etorrent the file to work with
    {ok, _} = file:copy(Fn, SrcFn),
    %% Copy torrent-file to torrents-directory
    {ok, _} = copy_to(TorrentFn, ?config(dir, SNodeConf)),
    start_app(MNode, MNodeConf),
    start_app(SNode, SNodeConf),
    start_app(LNode, LNodeConf),
    [{src_filename, SrcFn},
     {dest_filename, DestFn},
     {middleman_node_dir, MNodeDir},
     {seed_node_dir, SNodeDir},
     {leech_node_dir, LNodeDir} | Config];
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(leech_transmission, Config) ->
    LNode       = ?config(leech_node, Config),
    {_Ref, Pid} = ?config(transmission_port, Config),
    TranDir     = ?config(transmission_dir, Config),
    NodeDir     = ?config(node_dir, Config),
    stop_transmission(Pid),
    stop_app(LNode),
    clean_transmission_directory(TranDir),
    clean_standard_directory_layout(NodeDir),
    ok;
end_per_testcase(seed_transmission, Config) ->
    SNode       = ?config(seed_node, Config),
    {_Ref, Pid} = ?config(transmission_port, Config),
    TranDir     = ?config(transmission_dir, Config),
    NodeDir     = ?config(node_dir, Config),
    stop_transmission(Pid),
    stop_app(SNode),
    clean_transmission_directory(TranDir),
    clean_standard_directory_layout(NodeDir),
    ok;
end_per_testcase(seed_leech, Config) ->
    SNode       = ?config(seed_node, Config),
    LNode       = ?config(leech_node, Config),
    SNodeDir    = ?config(seed_node_dir, Config),
    LNodeDir    = ?config(leech_node_dir, Config),
    stop_app(SNode),
    stop_app(LNode),
    clean_standard_directory_layout(SNodeDir),
    clean_standard_directory_layout(LNodeDir),
    ok;
end_per_testcase(choked_seed_leech, Config) ->
    SNode       = ?config(seed_node, Config),
    LNode       = ?config(leech_node, Config),
    CNode       = ?config(choked_seed_node, Config),
    SNodeDir    = ?config(seed_node_dir, Config),
    LNodeDir    = ?config(leech_node_dir, Config),
    CNodeDir    = ?config(choked_seed_node_dir, Config),
    stop_app(SNode),
    stop_app(LNode),
    stop_app(CNode),
    clean_standard_directory_layout(SNodeDir),
    clean_standard_directory_layout(LNodeDir),
    clean_standard_directory_layout(CNodeDir),
    ok;
end_per_testcase(partial_downloading, Config) ->
    SNode       = ?config(seed_node, Config),
    LNode       = ?config(leech_node, Config),
    SNodeDir    = ?config(seed_node_dir, Config),
    LNodeDir    = ?config(leech_node_dir, Config),
    stop_app(SNode),
    stop_app(LNode),
    clean_standard_directory_layout(SNodeDir),
    clean_standard_directory_layout(LNodeDir),
    ok;
end_per_testcase(bep9, Config) ->
    SNode       = ?config(seed_node, Config),
    LNode       = ?config(leech_node, Config),
    MNode       = ?config(middleman_node, Config),
    SNodeDir    = ?config(seed_node_dir, Config),
    LNodeDir    = ?config(leech_node_dir, Config),
    MNodeDir    = ?config(middleman_node_dir, Config),
    stop_app(SNode),
    stop_app(LNode),
    stop_app(MNode),
    clean_standard_directory_layout(SNodeDir),
    clean_standard_directory_layout(LNodeDir),
    clean_standard_directory_layout(MNodeDir),
    ok;
end_per_testcase(_Case, _Config) ->
    ok.

%% Configuration
%% ----------------------------------------------------------------------
standard_directory_layout(Dir, AppConf) ->
    [{dir,              filename:join([Dir, "torrents"])},
     {download_dir,     filename:join([Dir, "downloads"])},
     {dht_state,        filename:join([Dir, "spool", "dht_state.dets"])},
     {fast_resume_file, filename:join([Dir, "spool", "fast_resume.dets"])},
     {logger_dir,       filename:join([Dir, "logs"])},
     {logger_fname, "leech_etorrent.log"} | AppConf].

create_standard_directory_layout(Dir) ->
    [filelib:ensure_dir(filename:join([Dir, SubDir, x]))
     || SubDir <- ["torrents", "downloads", "spool", "logs"]],
    ok.

clean_standard_directory_layout(Dir) ->
    del_dir_r(Dir),
    ok.

clean_transmission_directory(Dir) ->
    del_dir_r(Dir),
    ok.
    
    


seed_configuration(Dir) ->
    [{listen_ip, {127,0,0,2}},
     {port, 1741 },
     {udp_port, 1742 },
     {dht_port, 1743 },
     {max_upload_rate, 1000}
    | standard_directory_layout(Dir, ct:get_config(common_conf))].

leech_configuration(Dir) ->
    [{listen_ip, {127,0,0,3}},
     {port, 1751 },
     {udp_port, 1752 },
     {dht_port, 1753 }
    | standard_directory_layout(Dir, ct:get_config(common_conf))].

middleman_configuration(Dir) ->
    [{listen_ip, {127,0,0,4}},
     {port, 1761 },
     {udp_port, 1762 },
     {dht_port, 1763 }
    | standard_directory_layout(Dir, ct:get_config(common_conf))].

choked_seed_configuration(Dir) ->
    [{listen_ip, {127,0,0,5}},
     {port, 1771 },
     {udp_port, 1772 },
     {dht_port, 1773 },
     {max_upload_rate, 1000}
    | standard_directory_layout(Dir, ct:get_config(common_conf))].


%% Tests
%% ----------------------------------------------------------------------
groups() ->
    Tests = [seed_transmission, seed_leech, leech_transmission, bep9,
             partial_downloading, choked_seed_leech],
    [{main_group, [shuffle], Tests}].

all() ->
    [{group, main_group}].

seed_transmission() ->
    [{require, common_conf, etorrent_common_config}].

%% Etorrent => Transmission
seed_transmission(Config) ->
    io:format("~n======START SEED TRANSMISSION TEST CASE======~n", []),
    {Ref, _Pid} = ?config(transmission_port, Config),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(src_filename, Config))
	=:= sha1_file(?config(dest_filename, Config)).

%% Transmission => Etorrent
leech_transmission() ->
    [{require, common_conf, etorrent_common_config}].

leech_transmission(Config) ->
    io:format("~n======START LEECH TRANSMISSION TEST CASE======~n", []),
    %% Set callback and wait for torrent completion.
    {Ref, Pid} = {make_ref(), self()},
    {ok, _} = rpc:call(?config(leech_node, Config),
		  etorrent, start,
		  [?config(seed_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(tr_file, Config))
	=:= sha1_file(?config(et_leech_file, Config)).

seed_leech() ->
    [{require, common_conf, etorrent_common_config}].

seed_leech(Config) ->
    io:format("~n======START SEED AND LEECHING TEST CASE======~n", []),
    {Ref, Pid} = {make_ref(), self()},
    {ok, _} = rpc:call(?config(leech_node, Config),
		  etorrent, start,
		  [?config(seed_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(src_filename, Config))
	=:= sha1_file(?config(dest_filename, Config)).

choked_seed_leech() ->
    [{require, common_conf, etorrent_common_config}].

%% The idea of this test is to get request on a chunk from the slow seeder and
%% to chunk this server.
%% After that, the leecher will wait in engame mode for a long period of time.
%% Warning: this test CAN be passed accidently.
choked_seed_leech(Config) ->
    io:format("~n======START SLOW SEED AND LEECHING TEST CASE======~n", []),
    {Ref, Pid} = {make_ref(), self()},

    ChokedSeedNode = ?config(choked_seed_node, Config),
    LeechNode = ?config(leech_node, Config),
    BinIH = ?config(info_hash_bin, Config),
    SSTorrentID = wait_torrent_registration(ChokedSeedNode, BinIH),
    io:format("TorrentID on the choked_seed node is ~p.~n", [SSTorrentID]),

    {ok, LTorrentID} = rpc:call(LeechNode,
		  etorrent, start,
		  [?config(seed_torrent, Config), {Ref, Pid}]),

    io:format("TorrentID on the leech node is ~p.~n", [LTorrentID]),

    wait_torrent(LeechNode, LTorrentID),
    wait_progress(LeechNode, LTorrentID, 50),
    io:format("50% were downloaded.~n", []),

    %% Leech peer control process on the slow node.
    LeechId   = rpc:call(LeechNode, etorrent_ctl, local_peer_id, []),
    SSPeerPid = wait_peer_registration(ChokedSeedNode, SSTorrentID, LeechId),
    io:format("Peer registered.~n", []),
    true = is_fast_peer(ChokedSeedNode, SSPeerPid),
    io:format("Using fast protocol.~n", []),

    choke_in_the_middle(ChokedSeedNode, SSPeerPid),
    io:format("Leecher choked.~n", []),

    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(src_filename, Config))
	=:= sha1_file(?config(dest_filename, Config)).

partial_downloading() ->
    [{require, common_conf, etorrent_common_config}].

partial_downloading(Config) ->
    io:format("~n======START PARTICAL DOWNLOADING TEST CASE======~n", []),
    {Ref, Pid} = {make_ref(), self()},
    LeechNode = ?config(leech_node, Config),
    {ok, TorrentID} = rpc:call(LeechNode,
		  etorrent, start,
		  [?config(dir_torrent, Config), {Ref, Pid}]),
    io:format("TorrentID on the leech node is ~p.~n", [TorrentID]),
    rpc:call(LeechNode, etorrent_torrent_ctl, skip_file, [TorrentID, 2]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end.


bep9() ->
    [{require, common_conf, etorrent_common_config}].

bep9(Config) ->
    io:format("~n======START SEED AND LEECHING BEP-9 TEST CASE======~n", []),
    HexIH = ?config(info_hash_hex, Config),
    IntIH = ?config(info_hash_int, Config),
    error_logger:info_msg("Infohash is ~p.", [HexIH]),

    LeechNode     = ?config(leech_node, Config),
    SeedNode      = ?config(seed_node, Config),
    MiddlemanNode = ?config(middleman_node, Config),

    true = rpc:call(SeedNode,      etorrent_config, dht, []),
    true = rpc:call(LeechNode,     etorrent_config, dht, []),
    true = rpc:call(MiddlemanNode, etorrent_config, dht, []),

    timer:sleep(2000),
    %% Form DHT network.
    %% etorrent_dht_state:safe_insert_node({127,0,0,1}, 6881).
    MiddlemanDhtPort = rpc:call(MiddlemanNode, etorrent_config, dht_port, []),
    MiddlemanIP      = rpc:call(MiddlemanNode, etorrent_config, listen_ip, []),
    true = rpc:call(SeedNode,
    	  etorrent_dht_state, safe_insert_node,
    	  [MiddlemanIP, MiddlemanDhtPort]),
    true = rpc:call(LeechNode,
    	  etorrent_dht_state, safe_insert_node,
    	  [MiddlemanIP, MiddlemanDhtPort]),
    timer:sleep(1000),
    io:format("ANNOUNCE FROM SEED~n", []),
    ok = rpc:call(SeedNode,
    	  etorrent_dht_tracker, trigger_announce,
    	  []),

    %% Wait for announce.
    timer:sleep(3000),
    io:format("SEARCH FROM LEECH~n", []),

    Self = self(),
    Ref = make_ref(),
    CB = fun() -> Self ! {Ref, done} end,
    {ok, _TorrentID} = rpc:call(LeechNode,
    	  etorrent_magnet, download, [{infohash, IntIH}, [{callback, CB}]]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(src_filename, Config))
	=:= sha1_file(?config(dest_filename, Config)).



%% Helpers
%% ----------------------------------------------------------------------
start_opentracker(Dir) ->
    ToSpawn = "run_opentracker.sh -i 127.0.0.1 -p 6969 -P 6969",
    Spawn = filename:join([Dir, ToSpawn]),
    Pid = spawn(fun() ->
			Port = open_port({spawn, Spawn}, [binary, stream, eof]),
            opentracker_loop(Port, <<>>)
		end),
    Pid.

quote(Str) ->
    lists:concat(["'", Str, "'"]).

start_transmission(DataDir, DownDir, Torrent) ->
    io:format("Start transmission~n", []),
    ToSpawn = ["run_transmission-cli.sh ", quote(Torrent),
	       " -w ", quote(DownDir),
	       " -g ", quote(DownDir),
	       " -p 1780"],
    Spawn = filename:join([DataDir, lists:concat(ToSpawn)]),
    error_logger:info_report([{spawn, Spawn}]),
    Ref = make_ref(),
    Self = self(),
    Pid = spawn_link(fun() ->
			Port = open_port(
				 {spawn, Spawn},
				 [stream, binary, eof, stderr_to_stdout]),
            transmission_loop(Port, Ref, Self, <<>>, <<>>)
		     end),
    {Ref, Pid}.

stop_transmission(Pid) when is_pid(Pid) ->
    io:format("Stop transmission~n", []),
    Pid ! close,
    ok.

transmission_complete_criterion() ->
%   "Seeding, uploading to".
    "Verifying local files (0.00%, 100.00% valid)".

transmission_loop(Port, Ref, ReturnPid, OldBin, OldLine) ->
    case binary:split(OldBin, [<<"\r">>, <<"\n">>]) of
	[OnePart] ->
	    receive
		{Port, {data, Data}} ->
		    transmission_loop(Port, Ref, ReturnPid, <<OnePart/binary,
							      Data/binary>>, OldLine);
		close ->
		    port_close(Port);
		M ->
		    error_logger:error_report([received_unknown_msg, M]),
		    transmission_loop(Port, Ref, ReturnPid, OnePart, OldLine)
	    end;
	[L, Rest] ->
        %% Is it a different line? than show it.
        [io:format("TRANS: ~s~n", [L]) || L =/= OldLine],
	    case string:str(binary_to_list(L), transmission_complete_criterion()) of
		0 -> ok;
		N when is_integer(N) ->
		    ReturnPid ! {Ref, done}
	    end,
	    transmission_loop(Port, Ref, ReturnPid, Rest, L)
    end.

opentracker_loop(Port, OldBin) ->
    case binary:split(OldBin, [<<"\r">>, <<"\n">>]) of
	[OnePart] ->
	    receive
		{Port, {data, Data}} ->
		    opentracker_loop(Port, <<OnePart/binary, Data/binary>>);
		close ->
		    port_close(Port);
		M ->
		    error_logger:error_report([received_unknown_msg, M]),
		    opentracker_loop(Port, OnePart)
	    end;
	[L, Rest] ->
        io:format("TRACKER: ~s~n", [L]),
	    opentracker_loop(Port, Rest)
    end.

stop_opentracker(Pid) ->
    Pid ! close.

ensure_torrent_file(Fn, TorrentFn) ->
    case filelib:is_regular(TorrentFn) of
	true  -> ok;
	false -> etorrent_mktorrent:create(Fn, undefined, TorrentFn)
    end,
    ok.

ensure_torrent_file(Fn, TorrentFn, Proto) ->
    AnnounceUrl = Proto ++ "://localhost:6969/announce",
    case filelib:is_regular(TorrentFn) of
	true  -> ok;
	false -> etorrent_mktorrent:create(Fn, AnnounceUrl, TorrentFn)
    end,
    ok.

ensure_random_file(Fn) ->
    case filelib:is_regular(Fn) of
	true  -> ok;
	false -> create_random_file(Fn)
    end.

create_random_file(FName) ->
    Bin = crypto:rand_bytes(30*1024*1024),
    file:write_file(FName, Bin).


ensure_random_dir(DName) ->
    case filelib:is_dir(DName) of
	true  -> ok;
	false -> file:make_dir(DName)
    end,
    File1 = filename:join(DName, "xyz.bin"),
    File2 = filename:join(DName, "abc.bin"),
    ensure_random_file(File1),
    ensure_random_file(File2),
    ok.


sha1_file(F) ->
    Ctx = crypto:sha_init(),
    {ok, FD} = file:open(F, [read,binary,raw]),
    FinCtx = sha1_round(FD, file:read(FD, 1024*1024), Ctx),
    crypto:sha_final(FinCtx).

sha1_round(_FD, eof, Ctx) ->
    Ctx;
sha1_round(FD, {ok, Data}, Ctx) ->
    sha1_round(FD, file:read(FD, 1024*1024), crypto:sha_update(Ctx, Data)).



del_dir_r(DirName) ->
    {ok, SubFiles} = file:list_dir(DirName),
    [file:delete(filename:join(DirName, X)) || X <- SubFiles],
    del_dir(DirName).

del_dir(DirName) ->
    io:format("Try to delete directory ~p.~n", [DirName]),
    case file:del_dir(DirName) of
        {error,eexist} ->
            io:format("Directory is not empty. Content: ~n~p~n", 
                      [element(2, file:list_dir(DirName))]),
            ok;
        ok ->
            ok
    end.


prepare_node(Node) ->
    io:format("Prepare node ~p.~n", [Node]),
    rpc:call(Node, code, set_path, [code:get_path()]),
    true = rpc:call(Node, erlang, unregister, [user]),
    IOProxy = spawn(Node, spawn_io_proxy()),
    true = rpc:call(Node, erlang, register, [user, IOProxy]),
    Handlers = lager_handlers(Node),
    ok = rpc:call(Node, application, load, [lager]),
    ok = rpc:call(Node, application, set_env, [lager, handlers, Handlers]),
    ok = rpc:call(Node, application, start, [lager]),
    ok.

spawn_io_proxy() ->
    User = group_leader(),
    fun() -> io_proxy(User) end.
    
io_proxy(Pid) ->
    receive
        Mess -> Pid ! Mess, io_proxy(Pid)
    end.

lager_handlers(NodeName) ->
%   [Node|_] = string:tokens(atom_to_list(NodeName), "@"),
    [A,B|_] = atom_to_list(NodeName),
    Node   = [A,B],
    Format = [Node, "> ", time, " [",severity,"] ", message, "\n"],
    [{lager_console_backend, [debug, {lager_default_formatter, Format}]}].


wait_torrent(Node, TorrentID) ->
    case rpc:call(Node, etorrent_torrent, lookup, [TorrentID]) of
        {value, _Props} ->
            ok;
        not_found -> timer:sleep(500), wait_torrent(Node, TorrentID)
    end.


%% Returns torrent_id.
wait_torrent_registration(Node, BinIH) ->
    case rpc:call(Node, etorrent_table, get_torrent, [{infohash, BinIH}]) of
        {value, Props} ->
            proplists:get_value(id, Props);
        not_found -> timer:sleep(500), wait_torrent_registration(Node, BinIH)
    end.

%% Returns pid of the conrol process.
wait_peer_registration(Node, TorrentID, PeerId) ->
    case rpc:call(Node, etorrent_table, get_peer, [{peer_id, TorrentID, PeerId}]) of
        {value, Props} ->
            proplists:get_value(pid, Props);
        not_found ->
            timer:sleep(500), wait_peer_registration(Node, TorrentID, PeerId)
    end.

is_fast_peer(Node, PeerPid) ->
    case rpc:call(Node, etorrent_table, get_peer, [{pid, PeerPid}]) of
        {value, Props} ->
            proplists:get_bool(is_fast, Props)
    end.



-spec wait_progress(Node::node(), TorrentID::non_neg_integer(),
                    Percent:: 0 .. 100) -> ok.
wait_progress(Node, TorrentID, Percent) ->
    {value, Props} = rpc:call(Node, etorrent_torrent, lookup, [TorrentID]),
    Left = proplists:get_value(left, Props),
    Want = proplists:get_value(wanted, Props),
    if (Want - Left) / Want * 100 >= Percent -> ok;
        true -> timer:sleep(500), wait_progress(Node, TorrentID, Percent)
    end.

hex_to_bin_hash(HexIH) ->
    IntIH = list_to_integer(HexIH, 16),
    <<IntIH:160>>.

%% Convert a literal infohash to integer.
hex_to_int_hash(X) ->
    list_to_integer(X, 16).


%% Block the remote peer, while having unserved requests from it.
choke_in_the_middle(Node, PeerPid) ->
    rpc:call(Node, etorrent_peer_control, choke, [PeerPid]),
    HasRequests = rpc:call(Node, etorrent_peer_control,
                           has_incoming_requests, [PeerPid]),
    case HasRequests of
        true -> ok;
        false ->
            rpc:call(Node, etorrent_peer_control, unchoke, [PeerPid]),
            timer:sleep(100),
            choke_in_the_middle(Node, PeerPid)
    end.


copy_to(SrcFileName, DestDirName) ->
    SrcBaseName = filename:basename(SrcFileName),
    DestFileName = filename:join([DestDirName, SrcBaseName]),
    file:copy(SrcBaseName, DestFileName).


%% Recursively copy directories
-spec copy_r(file:filename(), file:filename()) -> ok.
copy_r(From, To) ->
    {ok, Files} = file:list_dir(From),
    [ok = copy_r(From, To, X) || X <- Files],
    ok.

-spec copy_r(list(), list(), list()) -> ok.
copy_r(From, To, File) ->
    NewFrom = filename:join(From, File),
    NewTo = filename:join(To, File),
    case filelib:is_dir(NewFrom) of
        true ->
            ok = filelib:ensure_dir(NewTo),
            copy_r(NewFrom, NewTo);
        false ->
        case filelib:is_file(NewFrom) of
        true ->
            ok = filelib:ensure_dir(NewTo),
            {ok, _} = file:copy(NewFrom, NewTo),
            ok;
        false -> ok
        end
    end.


stop_app(Node) ->
    ok = rpc:call(Node, etorrent, stop_app, []).

start_app(Node, AppConfig) ->
    ok = rpc:call(Node, etorrent, start_app, [AppConfig]).
