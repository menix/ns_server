%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
-module(ns_bucket).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([auth_type/1,
         bucket_nodes/1,
         bucket_type/1,
         config/1,
         config_string/1,
         create_bucket/3,
         credentials/1,
         delete_bucket/1,
         failover_warnings/0,
         get_bucket/1,
         get_bucket_names/0,
         get_bucket_names/1,
         get_buckets/0,
         get_buckets/1,
         is_open_proxy_port/2,
         is_persistent/1,
         is_port_free/2,
         is_valid_bucket_name/1,
         json_map/2,
         json_map_from_config/2,
         live_bucket_nodes/1,
         map_to_replicas/1,
         maybe_get_bucket/2,
         moxi_port/1,
         node_locator/1,
         num_replicas/1,
         ram_quota/1,
         raw_ram_quota/1,
         sasl_password/1,
         set_bucket_config/2,
         set_map/2,
         set_servers/2,
         update_bucket_props/2,
         update_bucket_props/3]).


%%%===================================================================
%%% API
%%%===================================================================

config(Bucket) ->
    {ok, CurrentConfig} = get_bucket(Bucket),
    config_from_info(CurrentConfig).

config_from_info(CurrentConfig) ->
    NumReplicas = proplists:get_value(num_replicas, CurrentConfig),
    NumVBuckets = proplists:get_value(num_vbuckets, CurrentConfig),
    Map = case proplists:get_value(map, CurrentConfig) of
              undefined -> lists:duplicate(NumVBuckets, lists:duplicate(NumReplicas+1, undefined));
              M -> M
          end,
    Servers = proplists:get_value(servers, CurrentConfig),
    {NumReplicas, NumVBuckets, Map, Servers}.


%% @doc Configuration parameters to start up the bucket on a node.
config_string(BucketName) ->
    Config = ns_config:get(),
    BucketConfigs = ns_config:search_prop(Config, buckets, configs),
    BucketConfig = proplists:get_value(BucketName, BucketConfigs),
    Engines = ns_config:search_node_prop(Config, memcached, engines),
    MemQuota = proplists:get_value(ram_quota, BucketConfig),
    BucketType =  proplists:get_value(type, BucketConfig),
    EngineConfig = proplists:get_value(BucketType, Engines),
    Engine = proplists:get_value(engine, EngineConfig),
    {ConfigString, ExtraParams} =
        case BucketType of
            membase ->
                DBDir = ns_config:search_node_prop(Config, memcached, dbdir),
                DBName = filename:join(DBDir, BucketName),
                %% MemQuota is our total limit for cluster
                %% LocalQuota is our limit for this node
                %% We stretch our quota on all nodes we have for this bucket
                ok = filelib:ensure_dir(DBName),
                CFG =
                    lists:flatten(
                      io_lib:format(
                        "vb0=false;waitforwarmup=false;ht_size=~B;"
                        "ht_locks=~B;failpartialwarmup=false;"
                        "shardpattern=%d/%b-%i.mb;"
                        "db_strategy=multiMTVBDB;"
                        "tap_keepalive=~B;"
                        "tap_noop_interval=~B;"
                        "max_txn_size=~B;"
                        "max_size=~B;initfile=~s;dbname=~s",
                        [proplists:get_value(ht_size, BucketConfig),
                         proplists:get_value(ht_locks, BucketConfig),
                         proplists:get_value(tap_keepalive, BucketConfig, 0),
                         proplists:get_value(tap_noop_interval, BucketConfig, 20),
                         proplists:get_value(max_txn_size, BucketConfig, 1000),
                         MemQuota,
                         proplists:get_value(initfile, EngineConfig),
                         DBName])),
                {CFG, {MemQuota, DBName}};
            memcached ->
                {lists:flatten(
                   io_lib:format("vb0=true;cache_size=~B", [MemQuota])),
                 MemQuota}
        end,
    {Engine, ConfigString, BucketType, ExtraParams}.

%% @doc Return {Username, Password} for a bucket.
-spec credentials(nonempty_string()) ->
                         {nonempty_string(), string()}.
credentials(Bucket) ->
    {ok, BucketConfig} = get_bucket(Bucket),
    {Bucket, proplists:get_value(sasl_password, BucketConfig, "")}.


get_bucket(Bucket) ->
    BucketConfigs = get_buckets(),
    case lists:keysearch(Bucket, 1, BucketConfigs) of
        {value, {_, Config}} ->
            {ok, Config};
        false -> not_present
    end.

maybe_get_bucket(BucketName, undefined) ->
    get_bucket(BucketName);
maybe_get_bucket(_, BucketConfig) ->
    {ok, BucketConfig}.

get_bucket_names() ->
    BucketConfigs = get_buckets(),
    proplists:get_keys(BucketConfigs).

get_bucket_names(Type) ->
    [Name || {Name, Config} <- get_buckets(),
             proplists:get_value(type, Config) == Type].

get_buckets() ->
    get_buckets(ns_config:get()).

get_buckets(Config) ->
    ns_config:search_prop(Config, buckets, configs, []).

live_bucket_nodes(Bucket) ->
    {ok, BucketConfig} = get_bucket(Bucket),
    Servers = proplists:get_value(servers, BucketConfig),
    LiveNodes = [node()|nodes()],
    [Node || Node <- Servers, lists:member(Node, LiveNodes) ].

%% returns cluster-wide ram_quota. For memcached buckets it's
%% ram_quota field times number of servers
-spec ram_quota([{_,_}]) -> integer().
ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            X * length(proplists:get_value(servers, Bucket, []))
    end.

%% returns cluster-wide ram_quota. For memcached buckets it's
%% ram_quota field times number of servers
-spec raw_ram_quota([{_,_}]) -> integer().
raw_ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            X
    end.

-define(FS_HARD_NODES_NEEDED, 4).
-define(FS_FAILOVER_NEEDED, 3).
-define(FS_REBALANCE_NEEDED, 2).
-define(FS_SOFT_REBALANCE_NEEDED, 1).
-define(FS_OK, 0).

bucket_failover_safety(BucketConfig, LiveNodes) ->
    ReplicaNum = ns_bucket:num_replicas(BucketConfig),
    case ReplicaNum of
        %% if replica count for bucket is 0 we cannot failover at all
        0 -> {?FS_OK, ok};
        _ ->
            MinLiveCopies = min_live_copies(LiveNodes, BucketConfig),
            BucketNodes = proplists:get_value(servers, BucketConfig),
            BaseSafety =
                if
                    MinLiveCopies =:= undefined -> % janitor run pending
                        case LiveNodes of
                            [_,_|_] -> ?FS_OK;
                            _ -> ?FS_HARD_NODES_NEEDED
                        end;
                    MinLiveCopies =:= undefined orelse MinLiveCopies =< 1 ->
                        %% we cannot failover without losing data
                        %% is some of chain nodes are down ?
                        DownBucketNodes = lists:any(fun (N) -> not lists:member(N, LiveNodes) end,
                                                    BucketNodes),
                        if
                            DownBucketNodes ->
                                %% yes. User should bring them back or failover/replace them (and possibly add more)
                                ?FS_FAILOVER_NEEDED;
                            %% Can we replace missing chain nodes with other live nodes ?
                            LiveNodes =/= [] andalso tl(LiveNodes) =/= [] -> % length(LiveNodes) > 1, but more efficent
                                %% we're generally fault tolerant, just not balanced enough
                                ?FS_REBALANCE_NEEDED;
                            true ->
                                %% we have one (or 0) of live nodes, need at least one more to be fault tolerant
                                ?FS_HARD_NODES_NEEDED
                        end;
                    true ->
                        case ns_rebalancer:unbalanced(proplists:get_value(map, BucketConfig),
                                                      proplists:get_value(servers, BucketConfig)) of
                            true ->
                                ?FS_SOFT_REBALANCE_NEEDED;
                            _ ->
                                ?FS_OK
                        end
                end,
            ExtraSafety =
                if
                    length(LiveNodes) =< ReplicaNum andalso BaseSafety =/= ?FS_HARD_NODES_NEEDED ->
                        %% if we don't have enough nodes to put all replicas on
                        softNodesNeeded;
                    true ->
                        ok
                end,
            {BaseSafety, ExtraSafety}
    end.

failover_safety_rec(?FS_HARD_NODES_NEEDED, _ExtraSafety, _, _LiveNodes) -> {?FS_HARD_NODES_NEEDED, ok};
failover_safety_rec(BaseSafety, ExtraSafety, [], _LiveNodes) -> {BaseSafety, ExtraSafety};
failover_safety_rec(BaseSafety, ExtraSafety, [BucketConfig | RestConfigs], LiveNodes) ->
    {ThisBaseSafety, ThisExtraSafety} = bucket_failover_safety(BucketConfig, LiveNodes),
    NewBaseSafety = case BaseSafety < ThisBaseSafety of
                        true -> ThisBaseSafety;
                        _ -> BaseSafety
                    end,
    NewExtraSafety = if ThisExtraSafety =:= softNodesNeeded
                        orelse ExtraSafety =:= softNodesNeeded ->
                             softNodesNeeded;
                        true ->
                             ok
                     end,
    failover_safety_rec(NewBaseSafety, NewExtraSafety,
                        RestConfigs, LiveNodes).

-spec failover_warnings() -> [failoverNeeded | rebalanceNeeded | hardNodesNeeded | softNodesNeeded].
failover_warnings() ->
    LiveNodes = ns_cluster_membership:actual_active_nodes(),
    {BaseSafety0, ExtraSafety}
        = failover_safety_rec(?FS_OK, ok,
                              [C || {_, C} <- get_buckets(),
                                    membase =:= bucket_type(C)],
                              LiveNodes),
    BaseSafety = case BaseSafety0 of
                     ?FS_HARD_NODES_NEEDED -> hardNodesNeeded;
                     ?FS_FAILOVER_NEEDED -> failoverNeeded;
                     ?FS_REBALANCE_NEEDED -> rebalanceNeeded;
                     ?FS_SOFT_REBALANCE_NEEDED -> softRebalanceNeeded;
                     ?FS_OK -> ok
                 end,
    [S || S <- [BaseSafety, ExtraSafety], S =/= ok].


map_to_replicas(Map) ->
    map_to_replicas(Map, 0, []).

map_to_replicas([], _, Replicas) ->
    lists:append(Replicas);
map_to_replicas([Chain|Rest], V, Replicas) ->
    Pairs = [{Src, Dst, V}||{Src, Dst} <- misc:pairs(Chain),
                            Src /= undefined andalso Dst /= undefined],
    map_to_replicas(Rest, V+1, [Pairs|Replicas]).


%% @doc Return the minimum number of live copies for all vbuckets.
-spec min_live_copies([node()], list()) -> non_neg_integer() | undefined.
min_live_copies(LiveNodes, Config) ->
    case proplists:get_value(map, Config) of
        undefined -> undefined;
        Map ->
            lists:foldl(
              fun (Chain, Min) ->
                      NumLiveCopies =
                          lists:foldl(
                            fun (Node, Acc) ->
                                    case lists:member(Node, LiveNodes) of
                                        true -> Acc + 1;
                                        false -> Acc
                                    end
                            end, 0, Chain),
                      erlang:min(Min, NumLiveCopies)
              end, length(hd(Map)), Map)
    end.

node_locator(BucketConfig) ->
    case proplists:get_value(type, BucketConfig) of
        membase ->
            vbucket;
        memcached ->
            ketama
    end.

-spec num_replicas([{_,_}]) -> integer().
num_replicas(Bucket) ->
    case proplists:get_value(num_replicas, Bucket) of
        X when is_integer(X) ->
            X
    end.

bucket_type(Bucket) ->
    proplists:get_value(type, Bucket).

auth_type(Bucket) ->
    proplists:get_value(auth_type, Bucket).

sasl_password(Bucket) ->
    proplists:get_value(sasl_password, Bucket, "").

moxi_port(Bucket) ->
    proplists:get_value(moxi_port, Bucket).

bucket_nodes(Bucket) ->
    proplists:get_value(servers, Bucket).

json_map(BucketId, LocalAddr) ->
    {ok, BucketConfig} = get_bucket(BucketId),
    json_map_from_config(LocalAddr, BucketConfig).

json_map_from_config(LocalAddr, BucketConfig) ->
    NumReplicas = num_replicas(BucketConfig),
    Config = ns_config:get(),
    {NumReplicas, _, EMap, BucketNodes} = config_from_info(BucketConfig),
    ENodes = lists:delete(undefined, lists:usort(lists:append([BucketNodes |
                                                               EMap]))),
    Servers = lists:map(
                fun (ENode) ->
                        Port = ns_config:search_node_prop(ENode, Config,
                                                          memcached, port),
                        Host = case misc:node_name_host(ENode) of
                                   {_Name, "127.0.0.1"} -> LocalAddr;
                                   {_Name, H} -> H
                               end,
                        list_to_binary(Host ++ ":" ++ integer_to_list(Port))
                end, ENodes),
    Map = lists:map(fun (Chain) ->
                            lists:map(fun (undefined) -> -1;
                                          (N) -> misc:position(N, ENodes) - 1
                                      end, Chain)
                    end, EMap),
    {struct, [{hashAlgorithm, <<"CRC">>},
              {numReplicas, NumReplicas},
              {serverList, Servers},
              {vBucketMap, Map}]}.

set_bucket_config(Bucket, NewConfig) ->
    update_bucket_config(Bucket, fun (_) -> NewConfig end).

%% Here's code snippet from bucket-engine.  We also disallow '.' &&
%% '..' which cause problems with browsers even when properly
%% escaped. See bug 953
%%
%% static bool has_valid_bucket_name(const char *n) {
%%     bool rv = strlen(n) > 0;
%%     for (; *n; n++) {
%%         rv &= isalpha(*n) || isdigit(*n) || *n == '.' || *n == '%' || *n == '_' || *n == '-';
%%     }
%%     return rv;
%% }
is_valid_bucket_name([]) -> false;
is_valid_bucket_name(".") -> false;
is_valid_bucket_name("..") -> false;
is_valid_bucket_name([Char | Rest]) ->
    case ($A =< Char andalso Char =< $Z)
        orelse ($a =< Char andalso Char =< $z)
        orelse ($0 =< Char andalso Char =< $9)
        orelse Char =:= $. orelse Char =:= $%
        orelse Char =:= $_ orelse Char =:= $- of
        true ->
            case Rest of
                [] -> true;
                _ -> is_valid_bucket_name(Rest)
            end;
        _ -> false
    end.

is_open_proxy_port(BucketName, Port) ->
    UsedPorts = lists:filter(fun (undefined) -> false;
                                 (_) -> true
                             end,
                             [proplists:get_value(moxi_port, Config)
                              || {Name, Config} <- get_buckets(),
                                 Name /= BucketName]),
    not lists:member(Port, UsedPorts).

is_port_free(BucketName, Port) ->
    is_port_free(BucketName, Port, ns_config:get()).

is_port_free(BucketName, Port, Config) ->
    Port =/= ns_config:search_node_prop(Config, memcached, port)
        andalso Port =/= ns_config:search_node_prop(Config, moxi, port)
        andalso Port =/= proplists:get_value(port, menelaus_web:webconfig(Config))
        andalso is_open_proxy_port(BucketName, Port).

validate_bucket_config(BucketName, NewConfig) ->
    case is_valid_bucket_name(BucketName) of
        true ->
            Port = proplists:get_value(moxi_port, NewConfig),
            case is_port_free(BucketName, Port) of
                false ->
                    {error, {port_conflict, Port}};
                true ->
                    ok
            end;
        false ->
            {error, {invalid_bucket_name, BucketName}}
    end.

new_bucket_default_params(membase) ->
    [{type, membase},
     {num_vbuckets,
      case (catch list_to_integer(os:getenv("VBUCKETS_NUM"))) of
          EnvBuckets when is_integer(EnvBuckets) -> EnvBuckets;
          _ -> 1024
      end},
     {num_replicas, 1},
     {ram_quota, 0},
     {ht_size, 3079},
     {tap_keepalive, 0},
     {tap_noop_interval, 20},
     {max_txn_size, 1000},
     {ht_locks, 5},
     {servers, []},
     {map, undefined}];
new_bucket_default_params(memcached) ->
    [{type, memcached},
     {num_vbuckets, 0},
     {num_replicas, 0},
     {servers, ns_cluster_membership:active_nodes()},
     {map, []},
     {ram_quota, 0}].

cleanup_bucket_props(Props) ->
    case proplists:get_value(auth_type, Props) of
        sasl -> lists:keydelete(moxi_port, 1, Props);
        none -> lists:keydelete(sasl_password, 1, Props)
    end.

create_bucket(BucketType, BucketName, NewConfig) ->
    case validate_bucket_config(BucketName, NewConfig) of
        ok ->
            MergedConfig0 =
                misc:update_proplist(new_bucket_default_params(BucketType),
                                     NewConfig),
            MergedConfig = cleanup_bucket_props(MergedConfig0),
            ns_config:update_sub_key(
              buckets, configs,
              fun (List) ->
                      case lists:keyfind(BucketName, 1, List) of
                          false -> ok;
                          Tuple ->
                              exit({already_exists, Tuple})
                      end,
                      [{BucketName, MergedConfig} | List]
              end),
            %% The janitor will handle creating the map.
            ok;
        E -> E
    end.

delete_bucket(BucketName) ->
    ns_config:update_sub_key(buckets, configs,
                             fun (List) ->
                                     case lists:keyfind(BucketName, 1, List) of
                                         false -> exit({not_found, BucketName});
                                         Tuple ->
                                             lists:delete(Tuple, List)
                                     end
                             end).

%% Updates properties of bucket of given name and type.  Check of type
%% protects us from type change races in certain cases.
%%
%% If bucket with given name exists, but with different type, we
%% should return {exit, {not_found, _}, _}
update_bucket_props(Type, BucketName, Props) ->
    case lists:member(BucketName, get_bucket_names(Type)) of
        true ->
            update_bucket_props(BucketName, Props);
        false ->
            {exit, {not_found, BucketName}, []}
    end.

update_bucket_props(BucketName, Props) ->
    ns_config:update_sub_key(
      buckets, configs,
      fun (List) ->
              RV = misc:key_update(
                     BucketName, List,
                     fun (OldProps) ->
                             NewProps = lists:foldl(
                                          fun ({K, _V} = Tuple, Acc) ->
                                                  [Tuple | lists:keydelete(K, 1, Acc)]
                                          end, OldProps, Props),
                             cleanup_bucket_props(NewProps)
                     end),
              case RV of
                  false -> exit({not_found, BucketName});
                  _ -> ok
              end,
              RV
      end).

set_map(Bucket, Map) ->
    %% Make sure all lengths are the same
    ChainLengths = [length(Chain) || Chain <- Map],
    true = lists:max(ChainLengths) == lists:min(ChainLengths),
    %% Make sure there are no repeated nodes
    true = lists:all(
             fun (Chain) ->
                     Chain1 = [N || N <- Chain, N /= undefined],
                     length(lists:usort(Chain1)) == length(Chain1)
             end, Map),
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(map, 1, OldConfig, {map, Map})
      end).

set_servers(Bucket, Servers) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(servers, 1, OldConfig, {servers, Servers})
      end).

% Update the bucket config atomically.
update_bucket_config(Bucket, Fun) ->
    ok = ns_config:update_key(
           buckets,
           fun (List) ->
                   Buckets = proplists:get_value(configs, List, []),
                   OldConfig = proplists:get_value(Bucket, Buckets),
                   NewConfig = Fun(OldConfig),
                   NewBuckets = lists:keyreplace(Bucket, 1, Buckets, {Bucket, NewConfig}),
                   lists:keyreplace(configs, 1, List, {configs, NewBuckets})
           end).

%% returns true iff bucket with given names is membase bucket.
is_persistent(BucketName) ->
    {ok, BucketConfig} = get_bucket(BucketName),
    bucket_type(BucketConfig) =:= membase.

%%
%% Internal functions
%%

%%
%% Tests
%%

min_live_copies_test() ->
    ?assertEqual(min_live_copies([node1], []), undefined),
    ?assertEqual(min_live_copies([node1], [{map, undefined}]), undefined),
    Map1 = [[node1, node2], [node2, node1]],
    ?assertEqual(2, min_live_copies([node1, node2], [{map, Map1}])),
    ?assertEqual(1, min_live_copies([node1], [{map, Map1}])),
    ?assertEqual(0, min_live_copies([node3], [{map, Map1}])),
    Map2 = [[undefined, node2], [node2, node1]],
    ?assertEqual(1, min_live_copies([node1, node2], [{map, Map2}])),
    ?assertEqual(0, min_live_copies([node1, node3], [{map, Map2}])).
