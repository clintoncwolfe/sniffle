%% @doc Interface for sniffle-admin commands.
%% A lot of the code is taken from
%% https://github.com/basho/riak_kv/blob/develop/src/riak_kv_console.erl
-module(sniffle_console).

-include_lib("sniffle.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
         db_keys/1,
         db_get/1,
         db_delete/1,
         get_ring/1,
         connections/1,
         db_update/1
        ]).

-export([
         aae_status/1,
         down/1,
         join/1,
         leave/1,
         reip/1,
         remove/1,
         ringready/1,
         staged_join/1
        ]).

-export([
         config/1,
         ds/1,
         dtrace/1,
         hvs/1,
         ips/1,
         networks/1,
         pkgs/1,
         vms/1
        ]).

-export([
         pp_json/1,
         hdr/1,
         fields/2
        ]).

-ignore_xref([
              db_keys/1,
              db_get/1,
              db_delete/1,
              get_ring/1,
              connections/1,
              aae_status/1,
              config/1,
              down/1,
              ds/1,
              dtrace/1,
              hvs/1,
              ips/1,
              networks/1,
              join/1,
              leave/1,
              pkgs/1,
              reip/1,
              remove/1,
              ringready/1,
              staged_join/1,
              vms/1,
              db_update/1
             ]).

update_part(Img, Part) ->
    io:format("."),
    Key = <<Img/binary, Part:32>>,
    case sniffle_img:list_(Key) of
        {ok, [D]} ->
            %%    sniffle_img:wipe(Key),
            sniffle_img:sync_repair(Key, D);
        _ ->
            io:format("Could not read: ~s/~p~n", [Img, Part]),
            throw({read_failure, Img, Part})
    end.

update_img(Img) ->
    {ok, Parts} = sniffle_img:list(Img),
    io:format(" Updating image '~s' (~p parts)", [Img, length(Parts)]),
    [update_part(Img, Part) || Part <- lists:sort(Parts)],
    io:format(" done.~n").

db_update([]) ->
    [db_update([E]) || E <- ["vms", "datasets", "dtraces", "hypervisors",
                             "ipranges", "networks", "packages"]],
    ok;

db_update(["img"]) ->
    io:format("Updating images...~n"),
    {ok, Imgs} = sniffle_img:list(),
    [update_img(Img) || Img <- Imgs],
    io:format("Update complete.~n");

db_update(["datasets"]) ->
    io:format("Updating datasets...~n"),
    do_update(sniffle_dataset, sniffle_dataset_state);

db_update(["dtraces"]) ->
    io:format("Updating dtrace scripts...~n"),
    do_update(sniffle_dtrace, sniffle_dtrace_state);

db_update(["hypervisors"]) ->
    io:format("Updating hypervisors...~n"),
    do_update(sniffle_hypervisor, sniffle_hypervisor_state);

db_update(["ipranges"]) ->
    io:format("Updating ipranges...~n"),
    do_update(sniffle_iprange, sniffle_iprange_state);

db_update(["networks"]) ->
    io:format("Updating networks...~n"),
    do_update(sniffle_network, sniffle_network_state);

db_update(["packages"]) ->
    io:format("Updating packages...~n"),
    do_update(sniffle_package, sniffle_package_state);

db_update(["vms"]) ->
    io:format("Updating vms...~n"),
    do_update(sniffle_vm, sniffle_vm_state).

print_endpoints(Es) ->
    io:format("Hostname            "
              "                    "
              " Node               "
              " Errors    ~n"),
    io:format("--------------------"
              "--------------------"
              "----------"
              " ---------------~n", []),
    [print_endpoint(E) || E <- Es].

print_endpoint([{{Hostname, [{port,Port},{ip,IP}]}, _, Fails}]) ->
    HostPort = <<IP/binary, ":", Port/binary>>,
    io:format("~40s ~-19s ~9b~n", [Hostname, HostPort, Fails]).

connections(["snarl"]) ->
    io:format("Snarl endpoints.~n"),
    print_endpoints(libsnarl:servers());

connections(["howl"]) ->
    io:format("Howl endpoints.~n"),
    print_endpoints(libhowl:servers());

connections([]) ->
    connections(["snarl"]),
    connections(["howl"]).

get_ring([]) ->
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHash} = riak_core_ring:chash(RingData),
    io:format("Hash                "
              "                    "
              "          "
              " Node~n"),
    io:format("--------------------"
              "--------------------"
              "----------"
              " ---------------~n", []),
    lists:map(fun({K, H}) ->
                      io:format("~50b ~-15s~n", [K, H])
              end, CHash),
    ok.

is_prefix(Prefix, K) ->
    binary:longest_common_prefix([Prefix, K]) =:= byte_size(Prefix).

db_delete([CHashS, CatS, KeyS]) ->
    Cat = list_to_binary(CatS),
    Key = list_to_binary(KeyS),
    CHash = list_to_integer(CHashS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    case lists:keyfind(CHash, 1, CHashs) of
        false ->
            io:format("C-Hash ~b does not exist.~n", [CHash]),
            error;
        _ ->
            CHashA = list_to_atom(CHashS),
            fifo_db:delete(CHashA, Cat, Key)
    end.
db_get([CHashS, CatS, KeyS]) ->
    Cat = list_to_binary(CatS),
    Key = list_to_binary(KeyS),
    CHash = list_to_integer(CHashS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    case lists:keyfind(CHash, 1, CHashs) of
        false ->
            io:format("C-Hash ~b does not exist.~n", [CHash]),
            error;
        _ ->
            CHashA = list_to_atom(CHashS),
            case fifo_db:get(CHashA, Cat, Key) of
                {ok, E} ->
                    io:format("~p~n", [E]);
                _ ->
                    io:format("Not found.~n", []),
                    error
            end
    end.

db_keys([]) ->
    db_keys(["-p", ""]);

db_keys(["-p", PrefixS]) ->
    Prefix = list_to_binary(PrefixS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    lists:map(fun({Hash, H}) ->
                      io:format("~n~50b ~-15s~n", [Hash, H]),
                      io:format("--------------------"
                                "--------------------"
                                "--------------------"
                                "------~n", []),
                      CHashA = list_to_atom(integer_to_list(Hash)),
                      Keys = fifo_db:list_keys(CHashA, <<>>),
                      [io:format("~s~n", [K])
                       || K <- Keys,
                          is_prefix(Prefix, K) =:= true]
              end, CHashs),
    ok;

db_keys([CHashS]) ->
    db_keys([CHashS, ""]);

db_keys([CHashS, PrefixS]) ->
    Prefix = list_to_binary(PrefixS),
    CHash = list_to_integer(CHashS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    case lists:keyfind(CHash, 1, CHashs) of
        false ->
            io:format("C-Hash ~b does not exist.", [CHash]),
            error;
        _ ->
            CHashA = list_to_atom(CHashS),
            Keys = fifo_db:list_keys(CHashA, Prefix),
            [io:format("~s~n", [K]) || K <- Keys],
            ok
    end.

aae_status([]) ->
    Services = [{sniffle_hypervisor, "Hypervisor"}, {sniffle_vm, "VM"},
                {sniffle_iprange, "IP Range"}, {sniffle_package, "Package"},
                {sniffle_dataset, "Dataset"}, {sniffle_network, "Network"},
                {sniffle_dtrace, "DTrace"}],
    Services1 = case sniffle_opt:get(storage, general, backend,
                                     large_data_backend, internal) of
                    internal ->
                        [{sniffle_img, "Image"} | Services];
                    _ ->
                        Services
                end,
    [aae_status(E) || E <- Services1];

aae_status({System, Name}) ->
    ExchangeInfo = riak_core_entropy_info:compute_exchange_info(System),
    io:format("~s~n~n", [Name]),
    aae_exchange_status(ExchangeInfo),
    io:format("~n"),
    aae_tree_status(System),
    io:format("~n"),
    aae_repair_status(ExchangeInfo).

reip([OldNode, NewNode]) ->
    try
        %% reip is called when node is down (so riak_core_ring_manager is not running),
        %% so it has to use the basic ring operations.
        %%
        %% Do *not* convert to use riak_core_ring_manager:ring_trans.
        %%
        application:load(riak_core),
        RingStateDir = app_helper:get_env(riak_core, ring_state_dir),
        {ok, RingFile} = riak_core_ring_manager:find_latest_ringfile(),
        BackupFN = filename:join([RingStateDir, filename:basename(RingFile)++".BAK"]),
        {ok, _} = file:copy(RingFile, BackupFN),
        io:format("Backed up existing ring file to ~p~n", [BackupFN]),
        Ring = riak_core_ring_manager:read_ringfile(RingFile),
        NewRing = riak_core_ring:rename_node(Ring, OldNode, NewNode),
        riak_core_ring_manager:do_write_ringfile(NewRing),
        io:format("New ring file written to ~p~n",
            [element(2, riak_core_ring_manager:find_latest_ringfile())])
    catch
        Exception:Reason ->
            lager:error("Reip failed ~p:~p", [Exception,
                    Reason]),
            io:format("Reip failed, see log for details~n"),
            error
    end.


dtrace([C, "-j" | R]) ->
    sniffle_console_dtrace:command(json, [C | R]);

dtrace([]) ->
    sniffle_console_dtrace:help(),
    ok;

dtrace(R) ->
    sniffle_console_dtrace:command(text, R).

vms([C, "-j" | R]) ->
    sniffle_console_vms:command(json, [C | R]);

vms([]) ->
    sniffle_console_vms:help(),
    ok;

vms(R) ->
    sniffle_console_vms:command(text, R).

hvs([C, "-j" | R]) ->
    sniffle_console_hypervisors:command(json, [C | R]);

hvs([]) ->
    sniffle_console_hypervisors:help(),
    ok;

hvs(R) ->
    sniffle_console_hypervisors:command(text, R).

pkgs([C, "-j" | R]) ->
    sniffle_console_packages:command(json, [C | R]);

pkgs([]) ->
    sniffle_console_packages:help(),
    ok;

pkgs(R) ->
    sniffle_console_packages:command(text, R).

ds([C, "-j" | R]) ->
    sniffle_console_datasets:command(json, [C | R]);

ds([]) ->
    sniffle_console_datasets:help(),
    ok;

ds(R) ->
    sniffle_console_datasets:command(text, R).

ips([]) ->
    sniffle_console_ipranges:help(),
    ok;

ips([C, "-j" | R]) ->
    sniffle_console_ipranges:command(json, [C | R]);

ips(R) ->
    sniffle_console_ipranges:command(text, R).

networks([]) ->
    sniffle_console_networks:help(),
    ok;

networks([C, "-j" | R]) ->
    sniffle_console_networks:command(json, [C | R]);

networks(R) ->
    sniffle_console_networks:command(text, R).

config(["show"]) ->    io:format("Storage~n  General Section~n"),
    print_config(storage, general),
    io:format("  S3 Section~n"),
    print_config(storage, s3),
    ok;

config(["set", Ks, V]) ->
    Ks1 = [binary_to_list(K) || K <- re:split(Ks, "\\.")],
    config(["set" | Ks1] ++ [V]);

config(["set" | R]) ->
    [K1, K2, K3, V] = R,
    Ks = [K1, K2, K3],
    case sniffle_opt:set(Ks, V) of
        {invalid, key, K} ->
            io:format("Invalid key: ~p~n", [K]),
            error;
        {invalid, type, T} ->
            io:format("Invalid type: ~p~n", [T]),
            error;
        _ ->
            io:format("Setting changed~n", []),
            ok
    end.

%%compied from riak_kv

join([NodeStr]) ->
    join(NodeStr, fun riak_core:join/1,
         "Sent join request to ~s~n", [NodeStr]).

staged_join([NodeStr]) ->
    Node = list_to_atom(NodeStr),
    join(NodeStr, fun riak_core:staged_join/1,
         "Success: staged join request for ~p to ~p~n", [node(), Node]).

join(NodeStr, JoinFn, SuccessFmt, SuccessArgs) ->
    try
        case JoinFn(NodeStr) of
            ok ->
                io:format(SuccessFmt, SuccessArgs),
                ok;
            {error, not_reachable} ->
                io:format("Node ~s is not reachable!~n", [NodeStr]),
                error;
            {error, different_ring_sizes} ->
                io:format("Failed: ~s has a different ring_creation_size~n",
                          [NodeStr]),
                error;
            {error, unable_to_get_join_ring} ->
                io:format("Failed: Unable to get ring from ~s~n", [NodeStr]),
                error;
            {error, not_single_node} ->
                io:format("Failed: This node is already a member of a "
                          "cluster~n"),
                error;
            {error, self_join} ->
                io:format("Failed: This node cannot join itself in a "
                          "cluster~n"),
                error;
            {error, _} ->
                io:format("Join failed. Try again in a few moments.~n", []),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Join failed ~p:~p", [Exception, Reason]),
            io:format("Join failed, see log for details~n"),
            error
    end.

leave([]) ->
    try
        case riak_core:leave() of
            ok ->
                io:format("Success: ~p will shutdown after handing off "
                          "its data~n", [node()]),
                ok;
            {error, already_leaving} ->
                io:format("~p is already in the process of leaving the "
                          "cluster.~n", [node()]),
                ok;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [node()]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [node()]),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Leave failed ~p:~p", [Exception, Reason]),
            io:format("Leave failed, see log for details~n"),
            error
    end.

remove([Node]) ->
    try
        case riak_core:remove(list_to_atom(Node)) of
            ok ->
                io:format("Success: ~p removed from the cluster~n", [Node]),
                ok;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [Node]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [Node]),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Remove failed ~p:~p", [Exception, Reason]),
            io:format("Remove failed, see log for details~n"),
            error
    end.

down([Node]) ->
    try
        case riak_core:down(list_to_atom(Node)) of
            ok ->
                io:format("Success: ~p marked as down~n", [Node]),
                ok;
            {error, is_up} ->
                io:format("Failed: ~s is up~n", [Node]),
                error;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [Node]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [Node]),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Down failed ~p:~p", [Exception, Reason]),
            io:format("Down failed, see log for details~n"),
            error
    end.


-spec(ringready([]) -> ok | error).
ringready([]) ->
    try riak_core_status:ringready() of
        {ok, Nodes} ->
            io:format("TRUE All nodes agree on the ring ~p\n", [Nodes]);
        {error, {different_owners, N1, N2}} ->
            io:format("FALSE Node ~p and ~p list different partition owners\n",
                      [N1, N2]),
            error;
        {error, {nodes_down, Down}} ->
            io:format("FALSE ~p down.  All nodes need to be up to check.\n",
                      [Down]),
            error
    catch
        Exception:Reason ->
            lager:error("Ringready failed ~p:~p", [Exception, Reason]),
            io:format("Ringready failed, see log for details~n"),
            error
    end.

%%%===================================================================
%%% Private
%%%===================================================================

pp_json(Obj) ->
    io:format("~s~n", [jsx:prettify(jsx:encode(Obj))]).

hdr(F) ->
    hdr_lines(lists:reverse(F), {"~n", [], "~n", []}).


hdr_lines([{N, n} | R], {Fmt, Vars, FmtLs, VarLs}) ->
    hdr_lines(R, {
                "~20s " ++ Fmt,
                [N | Vars],
                "~20c " ++ FmtLs,
                [$- | VarLs]});

hdr_lines([{N, S}|R], {Fmt, Vars, FmtLs, VarLs}) ->
    %% there is a space that matters here ---------v
    hdr_lines(R, {
                [$~ | integer_to_list(S) ++ [$s, $\  | Fmt]],
                [N | Vars],
                [$~ | integer_to_list(S) ++ [$c, $\  | FmtLs]],
                [$- | VarLs]});

hdr_lines([], {Fmt, Vars, FmtL, VarLs}) ->
    io:format(Fmt, Vars),
    io:format(FmtL, VarLs).


fields(F, Vs) ->
    fields(lists:reverse(F),
           lists:reverse(Vs),
           {"~n", []}).

fields([{_, n}|R], [V | Vs], {Fmt, Vars}) when is_list(V)
                                     orelse is_binary(V) ->
    fields(R, Vs, {"~s " ++ Fmt, [V | Vars]});

fields([{_, n}|R], [V | Vs], {Fmt, Vars}) ->
    fields(R, Vs, {"~p " ++ Fmt, [V | Vars]});

fields([{_, S}|R], [V | Vs], {Fmt, Vars}) when is_list(V)
                                     orelse is_binary(V) ->
    %% there is a space that matters here ------------v
    fields(R, Vs, {[$~ | integer_to_list(S) ++ [$s, $\  | Fmt]], [V | Vars]});


fields([{_, S}|R], [V | Vs], {Fmt, Vars}) ->
    %% there is a space that matters here ------------v
    fields(R, Vs, {[$~ | integer_to_list(S) ++ [$p, $\  | Fmt]], [V | Vars]});

fields([], [], {Fmt, Vars}) ->
    io:format(Fmt, Vars).

print_config(Prefix, SubPrefix) ->
    Fmt = [{"Key", 20}, {"Value", 50}],
    hdr(Fmt),
    PrintFn = fun({K, [V|_]}, _) ->
                      fields(Fmt, [key(Prefix, SubPrefix, K), V])
              end,
    riak_core_metadata:fold(PrintFn, ok, {Prefix, SubPrefix}).

key(Prefix, SubPrefix, Key) ->
    io_lib:format("~p.~p.~p", [Prefix, SubPrefix, Key]).

aae_exchange_status(ExchangeInfo) ->
    io:format("~s~n", [string:centre(" Exchanges ", 79, $=)]),
    io:format("~-49s  ~-12s  ~-12s~n", ["Index", "Last (ago)", "All (ago)"]),
    io:format("~79..-s~n", [""]),
    [begin
         Now = os:timestamp(),
         LastStr = format_timestamp(Now, LastTS),
         AllStr = format_timestamp(Now, AllTS),
         io:format("~-49b  ~-12s  ~-12s~n", [Index, LastStr, AllStr]),
         ok
     end || {Index, LastTS, AllTS, _Repairs} <- ExchangeInfo],
    ok.

aae_repair_status(ExchangeInfo) ->
    io:format("~s~n", [string:centre(" Keys Repaired ", 79, $=)]),
    io:format("~-49s  ~s  ~s  ~s~n", ["Index",
                                      string:centre("Last", 8),
                                      string:centre("Mean", 8),
                                      string:centre("Max", 8)]),
    io:format("~79..-s~n", [""]),
    [begin
         io:format("~-49b  ~s  ~s  ~s~n", [Index,
                                           string:centre(integer_to_list(Last), 8),
                                           string:centre(integer_to_list(Mean), 8),
                                           string:centre(integer_to_list(Max), 8)]),
         ok
     end || {Index, _, _, {Last,_Min,Max,Mean}} <- ExchangeInfo],
    ok.

aae_tree_status(System) ->
    TreeInfo = riak_core_entropy_info:compute_tree_info(System),
    io:format("~s~n", [string:centre(" Entropy Trees ", 79, $=)]),
    io:format("~-49s  Built (ago)~n", ["Index"]),
    io:format("~79..-s~n", [""]),
    [begin
         Now = os:timestamp(),
         BuiltStr = format_timestamp(Now, BuiltTS),
         io:format("~-49b  ~s~n", [Index, BuiltStr]),
         ok
     end || {Index, BuiltTS} <- TreeInfo],
    ok.

format_timestamp(_Now, undefined) ->
    "--";
format_timestamp(Now, TS) ->
    riak_core_format:human_time_fmt("~.1f", timer:now_diff(Now, TS)).


do_update(MainMod, StateMod) ->
    {ok, US} = MainMod:list_(),
    io:format("  Entries found: ~p~n", [length(US)]),

    io:format("  Grabbing UUIDs"),
    US1 = [begin
               io:format("."),
               %%flush(),
               {StateMod:uuid(V), U}
           end|| U = #sniffle_obj{val = V} <- US],
    io:format(" done.~n"),

    io:format("  Wiping old entries"),
    [begin
         io:format("."),
         %%flush(),
         MainMod:wipe(UUID)
     end || {UUID, _} <- US1],
    io:format(" done.~n"),

    io:format("  Restoring entries"),
    [begin
         io:format("."),
         %%flush(),
         MainMod:sync_repair(UUID, O)
     end || {UUID, O} <- US1],
    io:format(" done.~n"),
    io:format("Update complete.~n"),
    ok.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

named_test() ->
    ?assertEqual(
       ok, sniffle_console:fields(
             [{"Desc", n}, {"Imported",7}, {"Version",8},
              {"Name",15}, {"OS",7}, {"UUID",36}],
             [<<"Base template to build other templates on">>,
              100,<<"1.6.1">>,<<"smartos64">>, <<"smartos">>,
              <<"f4c23828-7981-11e1-912f-8b6d67c68076">>])).
-endif.

