%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.
%%
%% @doc Rebalancing functions.
%%

-module(ns_rebalancer).

-include("ns_common.hrl").

-export([failover/1,
         generate_initial_map/3,
         rebalance/3,
         unbalanced/2]).


%%
%% API
%%

%% @doc Fail a node. Doesn't eject the node from the cluster. Takes
%% effect immediately.
failover(Node) ->
    lists:foreach(fun (Bucket) -> failover(Bucket, Node) end,
                  ns_bucket:get_bucket_names()).

-spec failover(string(), atom()) -> ok.
failover(Bucket, Node) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    Servers = proplists:get_value(servers, BucketConfig),
    case proplists:get_value(type, BucketConfig) of
        membase ->
            %% Promote replicas of vbuckets on this node
            Map = proplists:get_value(map, BucketConfig),
            Map1 = promote_replicas(Map, [Node]),
            case [I || {I, [undefined|_]} <- misc:enumerate(Map1, 0)] of
                [] -> ok; % Phew!
                MissingVBuckets ->
                    ?log_error("Lost data in ~p for ~w", [Bucket, MissingVBuckets]),
                    ns_log:log(?MODULE, 1,
                               "Data has been lost for ~B% of vbuckets in bucket ~p.",
                               [length(MissingVBuckets) * 100 div length(Map), Bucket])
            end,
            ns_bucket:set_map(Bucket, Map1),
            ns_bucket:set_servers(Bucket, lists:delete(Node, Servers)),
            try
                ns_janitor:cleanup(Bucket)
            catch
                E:R ->
                    ?log_error("Janitor cleanup of ~p failed after failover of ~p: ~p",
                               [Bucket, Node, {E, R}])
            end;
        memcached ->
            ns_bucket:set_servers(Bucket, lists:delete(Node, Servers))
    end.


generate_initial_map(NumReplicas, NumVBuckets, Servers) ->
    generate_initial_map(NumReplicas, NumVBuckets, Servers, []).


generate_initial_map(_, 0, _, Map) ->
    Map;
generate_initial_map(NumReplicas, NumVBuckets, Servers, Map) ->
    U = lists:duplicate(erlang:max(0, NumReplicas + 1 - length(Servers)),
                        undefined),
    Chain = lists:sublist(Servers, NumReplicas + 1) ++ U,
    [H|T] = Servers,
    generate_initial_map(NumReplicas, NumVBuckets - 1, T ++ [H], [Chain|Map]).


rebalance(KeepNodes, EjectNodes, FailedNodes) ->
    LiveNodes = KeepNodes ++ EjectNodes,
    AllNodes = LiveNodes ++ FailedNodes,
    DeactivateNodes = EjectNodes ++ FailedNodes,
    BucketConfigs = ns_bucket:get_buckets(),
    NumBuckets = length(BucketConfigs),
    try
        %% Eject failed nodes first so they don't cause trouble
        eject_nodes(FailedNodes -- [node()]),
        lists:foreach(fun ({I, {BucketName, BucketConfig}}) ->
                              BucketCompletion = I / NumBuckets,
                              ns_orchestrator:update_progress(
                                dict:from_list([{N, BucketCompletion}
                                                || N <- AllNodes])),
                              case proplists:get_value(type, BucketConfig) of
                                  memcached ->
                                      ns_bucket:set_servers(BucketName, KeepNodes);
                                  membase ->
                                      %% Only start one bucket at a time to avoid
                                      %% overloading things
                                      ns_bucket:set_servers(BucketName, LiveNodes),
                                      wait_for_memcached(LiveNodes, BucketName, 10),
                                      ns_janitor:cleanup(BucketName),
                                      rebalance(BucketName, KeepNodes,
                                                DeactivateNodes, BucketCompletion,
                                                NumBuckets)
                              end
                      end, misc:enumerate(BucketConfigs, 0))
    catch
        E:R ->
            %% Eject this node since the orchestrator can still be running on a
            %% failed node (should be fixed)
            case lists:member(node(), FailedNodes) of
                true ->
                    eject_nodes([node()]);
                false ->
                    ok
            end,
            erlang:E(R)
    end,
    ns_config_rep:synchronize(),
    eject_nodes(DeactivateNodes).



%% @doc Rebalance the cluster. Operates on a single bucket. Will
%% either return ok or exit with reason 'stopped' or whatever reason
%% was given by whatever failed.
rebalance(Bucket, KeepNodes, EjectNodes, BucketCompletion, NumBuckets) ->
    %% MB-3195: Shut down replication to avoid competing with
    %% rebalance and causing spurious errors.
    ns_vbm_sup:set_replicas(Bucket, []),
    {_, _, Map, _} = ns_bucket:config(Bucket),
    Histograms1 = histograms(Map, KeepNodes),
    Moves1 = master_moves(Bucket, EjectNodes, Map, Histograms1),
    ProgressFun =
        fun (P) ->
                Progress = dict:map(fun (_, N) ->
                                            N / NumBuckets + BucketCompletion
                                    end, P),
                ns_orchestrator:update_progress(Progress)
        end,
    try
        %% 'stopped' can be thrown past this point.
        Map2 = perform_moves(Bucket, Map, Moves1, ProgressFun),
        maybe_stop(),
        Histograms2 = histograms(Map2, KeepNodes),
        Moves2 = balance_nodes(Bucket, Map2, Histograms2, 1),
        Map3 = perform_moves(Bucket, Map2, Moves2, ProgressFun),
        maybe_stop(),
        Histograms3 = histograms(Map3, KeepNodes),
        Map4 = new_replicas(Bucket, EjectNodes, Map3, Histograms3),
        ns_bucket:set_map(Bucket, Map4),
        maybe_stop(),
        Histograms4 = histograms(Map4, KeepNodes),
        ChainLength = length(lists:nth(1, Map4)),
        {Map5, _} =
            lists:foldl(
              fun (I, {M, H}) ->
                      Moves = balance_nodes(Bucket, M, H, I),
                      M1 = apply_moves(I, Moves, M),
                      H1 = histograms(M1, KeepNodes),
                      M2 = new_replicas(Bucket, EjectNodes, M1, H1),
                      H2 = histograms(M2, KeepNodes),
                      {M2, H2}
              end, {Map4, Histograms4}, lists:seq(2, ChainLength)),
        ns_bucket:set_servers(Bucket, KeepNodes),
        ns_bucket:set_map(Bucket, Map5),
        %% Push out the config with the new map in case this node is
        %% being removed
        ns_config_rep:push(),
        maybe_stop()
    catch
        throw:stopped ->
            fixup_replicas(Bucket, KeepNodes, EjectNodes),
            exit(stopped);
        E:R ->
            fixup_replicas(Bucket, KeepNodes, EjectNodes),
            erlang:E(R)
    end.


%% @doc Determine if a particular bucket is unbalanced. Returns true
%% iff the max vbucket count in any class on any server is >2 more
%% than the min.
-spec unbalanced(map(), [atom()]) -> boolean().
unbalanced(Map, Servers) ->
    lists:any(fun (Histogram) ->
                      case [N || {_, N} <- Histogram] of
                          [] -> false;
                          Counts -> lists:max(Counts) - lists:min(Counts) > 2
                      end
              end, histograms(Map, Servers)).


%%
%% Internal functions
%%

%% applies given list of moves to given turn of given map. Returns
%% produced map. Does not move data, only computes final map.
-spec apply_moves(non_neg_integer(), moves(), map()) -> map() | no_return().
apply_moves(_, [], Map) ->
    Map;
apply_moves(I, [{V, _, New}|Tail], Map) ->
    Chain = lists:nth(V+1, Map),
    NewChain = lists:sublist(Chain, I-1) ++ [New] ++ lists:duplicate(length(Chain) - I, undefined),
    apply_moves(I, Tail, misc:nthreplace(V+1, NewChain, Map)).

%% picks least utilized node from given Histogram thats not in list of
%% AvoidNodes
assign(Histogram, AvoidNodes) ->
    Histogram1 = lists:keysort(2, Histogram),
    case lists:splitwith(fun ({N, _}) -> lists:member(N, AvoidNodes) end,
                         Histogram1) of
        {Head, [{Node, N}|Rest]} ->
            {Node, Head ++ [{Node, N+1}|Rest]};
        {_, []} ->
            {undefined, Histogram1}
    end.

%% calculates list of moves to balance turn I of Map.
balance_nodes(Bucket, Map, Histograms, I) when is_integer(I) ->
    VNF = [{V, lists:nth(I, Chain), lists:sublist(Chain, I-1)} ||
              {V, Chain} <- misc:enumerate(Map, 0)],
    Hist = lists:nth(I, Histograms),
    balance_nodes(Bucket, VNF, Hist, []);
balance_nodes(Bucket, VNF, Hist, Moves) ->
    {MinNode, MinCount} = misc:keymin(2, Hist),
    {MaxNode, MaxCount} = misc:keymax(2, Hist),
    case MaxCount - MinCount > 1 of
        true ->
            %% Get the first vbucket that is on MaxNode and for which MinNode is not forbidden
            case lists:splitwith(
                   fun ({_, N, F}) ->
                           N /= MaxNode orelse
                               lists:member(MinNode, F)
                   end, VNF) of
                {Prefix, [{V, N, F}|Tail]} ->
                    N = MaxNode,
                    VNF1 = Prefix ++ [{V, MinNode, F}|Tail],
                    Hist1 = lists:keyreplace(MinNode, 1, Hist, {MinNode, MinCount + 1}),
                    Hist2 = lists:keyreplace(MaxNode, 1, Hist1, {MaxNode, MaxCount - 1}),
                    balance_nodes(Bucket, VNF1, Hist2, [{V, MaxNode, MinNode}|Moves]);
                X ->
                    error_logger:info_msg("~p:balance_nodes(~p, ~p, ~p): No further moves (~p)~n",
                                          [?MODULE, VNF, Hist, Moves, X]),
                    Moves
            end;
        false ->
            Moves
    end.


%% @doc Eject a list of nodes from the cluster, making sure this node is last.
eject_nodes(Nodes) ->
    %% Leave myself last
    LeaveNodes = case lists:member(node(), Nodes) of
                     true ->
                         (Nodes -- [node()]) ++ [node()];
                     false ->
                         Nodes
                 end,
    lists:foreach(fun (N) ->
                          ns_cluster_membership:deactivate([N]),
                          ns_cluster:leave(N)
                  end, LeaveNodes).


%% @doc Ensure there are replicas for any unreplicated buckets if we stop.
fixup_replicas(Bucket, KeepNodes, EjectNodes) ->
    {_, _, Map, _} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, KeepNodes),
    Map1 = new_replicas(Bucket, EjectNodes, Map, Histograms),
    ns_bucket:set_servers(Bucket, KeepNodes ++ EjectNodes),
    ns_bucket:set_map(Bucket, Map1).


%% for each replication turn in Map returns list of pairs {node(),
%% integer()} representing histogram of occurences of nodes in this
%% replication turn. Missing Servers are represented with counts of 0.
%% Nodes that are not present in Servers are ignored.
histograms(Map, Servers) ->
    Histograms = [lists:keydelete(
                    undefined, 1,
                    misc:uniqc(
                      lists:sort(
                        [N || N<-L,
                              lists:member(N, Servers)]))) ||
                     L <- misc:rotate(Map)],
    lists:map(fun (H) ->
                      Missing = [{N, 0} || N <- Servers,
                                           not lists:keymember(N, 1, H)],
                      Missing ++ H
              end, Histograms).


-spec master_moves(string(), [atom()], map(), [histogram()]) -> moves().
master_moves(Bucket, EvacuateNodes, Map, Histograms) ->
    master_moves(Bucket, EvacuateNodes, Map, Histograms, 0, []).

%% calculates list of moves necessary to replaces missing or
%% to-be-evacuated masters. Utililizes first item of Histograms (that
%% represents utilization of turn 0 i.e. masters) to pick least
%% utilized nodes for new masters.
-spec master_moves(string(), [atom()], map(), [histogram()], non_neg_integer(),
                   moves()) -> moves().
master_moves(_, _, [], _, _, Moves) ->
    Moves;
master_moves(Bucket, EvacuateNodes, [[OldMaster|_]|MapTail], Histograms, V,
                 Moves) ->
    [MHist|RHists] = Histograms,
    case (OldMaster == undefined) orelse lists:member(OldMaster, EvacuateNodes) of
        true ->
            {NewMaster, MHist1} = assign(MHist, []),
            master_moves(Bucket, EvacuateNodes, MapTail, [MHist1|RHists],
                             V+1, [{V, OldMaster, NewMaster}|Moves]);
        false ->
            master_moves(Bucket, EvacuateNodes, MapTail, Histograms, V+1,
                             Moves)
    end.


maybe_stop() ->
    receive stop ->
            throw(stopped)
    after 0 ->
            ok
    end.

%% assigns new nodes to replicas in given map so that chains don't
%% have multiple appearances of any node and no chain contains node
%% from EjectNodes. When it has to change some node it picks least
%% utilized from Histograms.
new_replicas(Bucket, EjectNodes, Map, Histograms) ->
    new_replicas(Bucket, EjectNodes, Map, Histograms, 0, []).

new_replicas(_, _, [], _, _, NewMapReversed) ->
    lists:reverse(NewMapReversed);
new_replicas(Bucket, EjectNodes, [Chain|MapTail], Histograms, V,
              NewMapReversed) ->
    %% Split off the masters - we don't want to move them!
    {[Master|Replicas], [MHist|RHists]} = {Chain, Histograms},
    ChainHist = lists:zip(Replicas, RHists),
    {Replicas1, RHists1} = % These will be reversed
        lists:foldl(fun ({undefined, Histogram}, {C, H}) ->
                            {N1, H1} = assign(Histogram, C ++ [Master|EjectNodes]),
                            {[N1|C], [H1|H]};
                        ({OldNode, Histogram}, {C, H}) ->
                            case lists:member(OldNode, C ++ EjectNodes) of
                                true ->
                                    {N1, H1} = assign(Histogram, C ++ Chain ++
                                                          EjectNodes),
                                    {[N1|C], [H1|H]};
                                false ->
                                    {[OldNode|C], [Histogram|H]}
                            end
                  end, {[], []}, ChainHist),
    new_replicas(Bucket, EjectNodes, MapTail, [MHist|lists:reverse(RHists1)],
                 V + 1, [[Master|lists:reverse(Replicas1)]|NewMapReversed]).


%% performs given list of moves of master replicas. Actually moves
%% data. Returns new vbuckets map with new values of master replicas
%% and undefined for all other replicas.
-spec perform_moves(string(), map(), moves(), fun((dict()) -> any())) ->
                           map() | no_return().
perform_moves(Bucket, Map, Moves, ProgressFun) ->
    process_flag(trap_exit, true),
    {ok, Pid} =
        ns_vbucket_mover:start_link(Bucket, Moves, ProgressFun),
    case wait_for_mover(Pid) of
        ok ->
            MoveDict = dict:from_list([{V, N} || {V, _, N} <- Moves]),
            [[case dict:find(V, MoveDict) of error -> M; {ok, N} -> N end |
              lists:duplicate(length(C), undefined)]
             || {V, [M|C]} <- misc:enumerate(Map, 0)];
        stopped -> throw(stopped)
    end.


%% removes RemapNodes from head of vbucket map Map. Returns new map
promote_replicas(Map, RemapNodes) ->
    [promote_replica(Chain, RemapNodes) || Chain <- Map].

%% removes RemapNodes from head of vbucket map Chain for vbucket
%% V. Actually switches master if head of Chain is in
%% RemapNodes. Returns new chain.
promote_replica(Chain, RemapNodes) ->
    Chain1 = [case lists:member(Node, RemapNodes) of
                  true -> undefined;
                  false -> Node
              end || Node <- Chain],
    %% Chain now might begin with undefined - put all the undefineds
    %% at the end
    {Undefineds, Rest} = lists:splitwith(fun (undefined) -> true;
                                             (_) -> false
                                         end, Chain1),
    Rest ++ Undefineds.


%% @doc Wait until either all memcacheds are up or stop is pressed.
wait_for_memcached(_Nodes, _Bucket, -1) ->
    exit(wait_for_memcached_failed);
wait_for_memcached(Nodes, Bucket, Tries) ->
    case [Node || Node <- Nodes, not ns_memcached:connected(Node, Bucket)] of
        [] ->
            ok;
        Down ->
            receive
                stop ->
                    exit(stopped)
            after 1000 ->
                    ?log_info("Waiting for ~p", [Down]),
                    wait_for_memcached(Down, Bucket, Tries-1)
            end
    end.


-spec wait_for_mover(pid()) -> ok | stopped.
wait_for_mover(Pid) ->
    receive
        stop ->
            exit(Pid, stopped),
            wait_for_mover(Pid);
        {'EXIT', Pid, stopped} ->
            stopped;
        {'EXIT', Pid, normal} ->
            ok;
        {'EXIT', Pid, Reason} ->
            exit(Reason)
    end.
