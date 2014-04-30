-module(sniffle_vm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("sniffle.hrl").

-define(MASTER, sniffle_vm_vnode_master).
-define(VNODE, sniffle_vm_vnode).
-define(SERVICE, sniffle_vm).

-export([
         add_nic/2,
         children/2,
         commit_snapshot_rollback/2,
         create/3,
         create_backup/4,
         delete/1,
         delete_backup/2,
         delete_snapshot/2,
         get/1,
         list/0,
         list/2,
         log/2,
         logs/1,
         primary_nic/2,
         promote_to_image/3,
         reboot/1,
         reboot/2,
         register/2,
         remove_backup/2,
         remove_nic/2,
         restore/3,
         restore_backup/2,
         rollback_snapshot/2,
         service_clear/2,
         service_disable/2,
         service_enable/2,
         set/2,
         set/3,
         set_owner/2,
         snapshot/2,
         start/1,
         stop/1,
         stop/2,
         store/1,
         unregister/1,
         update/3,
         wipe/1,
         sync_repair/2,
         list_/0
        ]).

-ignore_xref([logs/1,
              sync_repair/2,
              list_/0,
              wipe/1,
              children/2]).

-type backup_opts() ::
        delete |
        {delete, parent} |
        xml.

wipe(UUID) ->
    sniffle_coverage:start(?MASTER, ?SERVICE, {wipe, UUID}).

sync_repair(UUID, Obj) ->
    do_write(UUID, sync_repair, Obj).

list_() ->
    {ok, Res} = sniffle_full_coverage:start(
                  ?MASTER, ?SERVICE, {list, [], true, true}),
    Res1 = [R || {_, R} <- Res],
    {ok,  Res1}.

store(Vm) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            Bs = jsxd:get(<<"backups">>, [], V),
            case has_xml(Bs) of
                true ->
                    {ok, H} = jsxd:get(<<"hypervisor">>, V),
                    set(Vm, <<"state">>, <<"storing">>),
                    [sniffle_vm:set(Vm, [<<"backups">>, B, <<"local">>], false)
                     || {B, _} <- Bs],
                    [sniffle_vm:set(Vm, [<<"backups">>, B, <<"local_size">>], 0)
                     || {B, _} <- Bs],
                    sniffle_vm:set(Vm, <<"snapshots">>, delete),
                    sniffle_vm:set(Vm, <<"hypervisor">>, delete),
                    {Host, Port} = get_hypervisor(H),
                    libchunter:delete_machine(Host, Port, Vm);
                false ->
                    {error, no_backup}
            end;
        _ ->
            not_found
    end.

has_xml([]) ->
    false;
has_xml([{_, B} | Bs]) ->
    case jsxd:get(<<"xml">>, false, B) of
        true ->
            true;
        false ->
            has_xml(Bs)
    end.

restore(Vm, BID, Hypervisor) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get(<<"hypervisor">>, V) of
                {ok, _} ->
                    already_deployed;
                _ ->
                    {Server, Port} = get_hypervisor(Hypervisor),
                    case jsxd:get([<<"backups">>, BID, <<"xml">>], true, V) of
                        true ->
                            case sniffle_s3:config(snapshot) of
                                error ->
                                    {error, not_supported};
                                {ok, {S3Host, S3Port, AKey, SKey, Bucket}} ->
                                    libchunter:restore_backup(Server, Port, Vm,
                                                              BID, S3Host,
                                                              S3Port, Bucket,
                                                              AKey, SKey)
                            end;
                        false ->
                            no_xml
                    end
            end;
        _ ->
            not_found
    end.

%% Removes a backup from the hypervisor
remove_backup(Vm, BID) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {Server, Port} = get_hypervisor(H),
            case jsxd:get([<<"backups">>, BID], V) of
                {ok, _} ->
                    libchunter:delete_backup(Server, Port, Vm, BID);
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

delete_backup(VM, BID) ->
    case sniffle_vm:get(VM) of
        {ok, V} ->
            case jsxd:get([<<"backups">>, BID], V) of
                {ok, _} ->
                    Children = children(V, BID, true),
                    [do_delete_backup(VM, V, C) || C <- Children],
                    do_delete_backup(VM, V, BID);
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

-spec restore_backup(Vm::fifo:uuid(), Snap::fifo:uuid()) ->
                            not_found |
                            {error, not_supported} |
                            {error, nopath}.
restore_backup(Vm, Snap) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {Server, Port} = get_hypervisor(H),

            case jsxd:get([<<"backups">>, Snap], V) of
                {ok, _} ->
                    case sniffle_s3:config(snapshot) of
                        error ->
                            {error, not_supported};
                        {ok, {S3Host, S3Port, AKey, SKey, Bucket}} ->
                            libchunter:restore_backup(Server, Port, Vm, Snap,
                                                      S3Host, S3Port, Bucket,
                                                      AKey, SKey)
                    end;
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

-spec create_backup(Vm::fifo:uuid(), Type::full | incremental,
                    Comment::binary(), Opts::[backup_opts()]) ->
                           not_found |
                           {error, no_parent} |
                           {error, timeout} |
                           {error, not_supported} |
                           {ok, fifo:uuid()}.
create_backup(Vm, full, Comment, Opts) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            do_snap(Vm, V, Comment, Opts);
        _ ->
            not_found
    end;

create_backup(Vm, incremental, Comment, Opts) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            Parent = proplists:get_value(parent, Opts),
            case jsxd:get([<<"backups">>, Parent, <<"local">>], V) of
                {ok, true} ->
                    do_snap(Vm, V, Comment, Opts);
                _ ->
                    {error, parent}
            end;
        _ ->
            not_found
    end.

service_enable(Vm, Service) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {Server, Port} = get_hypervisor(H),
            libchunter:service_enable(Server, Port, Vm, Service);
        _ ->
            not_found
    end.

service_disable(Vm, Service) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {Server, Port} = get_hypervisor(H),
            libchunter:service_disable(Server, Port, Vm, Service);
        _ ->
            not_found
    end.

service_clear(Vm, Service) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {Server, Port} = get_hypervisor(H),
            libchunter:service_clear(Server, Port, Vm, Service);
        _ ->
            not_found
    end.

do_snap(Vm, V, Comment, Opts) ->
    UUID = uuid:uuid4s(),
    Opts1 = [create | Opts],
    {ok, H} = jsxd:get(<<"hypervisor">>, V),
    {Server, Port} = get_hypervisor(H),
    case sniffle_s3:config(snapshot) of
        error ->
            {error, not_supported};
        {ok, {S3Host, S3Port, AKey, SKey, Bucket}} ->
            libchunter:backup(Server, Port, Vm, UUID,
                              S3Host, S3Port, Bucket, AKey,
                              SKey, Bucket, Opts1),
            C = [{[<<"backups">>, UUID, <<"comment">>], Comment},
                 {[<<"backups">>, UUID, <<"timestamp">>], timestamp()},
                 {[<<"backups">>, UUID, <<"state">>], <<"pending">>}],
            sniffle_vm:set(Vm, C),
            {ok, UUID}
    end.

promote_to_image(Vm, SnapID, Config) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get([<<"snapshots">>, SnapID, <<"timestamp">>], V) of
                {ok, _} ->
                    {ok, H} = jsxd:get(<<"hypervisor">>, V),
                    {Server, Port} = get_hypervisor(H),
                    Img = uuid:uuid4s(),
                    {ok, C} = jsxd:get(<<"config">>, V),
                    Config1 = jsxd:select([<<"name">>, <<"version">>, <<"os">>, <<"description">>],
                                          jsxd:from_list(Config)),
                    {ok, Nets} = jsxd:get([<<"networks">>], C),
                    Nets1 =
                        jsxd:map(fun (Idx, E) ->
                                         Name = io_lib:format("net~p", [Idx]),
                                         [{<<"description">>, jsxd:get(<<"tag">>, <<"undefined">>, E)},
                                          {<<"name">>, list_to_binary(Name)}]
                                 end, Nets),
                    Config2 =
                        jsxd:thread([{set, <<"type">>, jsxd:get([<<"type">>], <<"zone">>, C)},
                                     {set, <<"dataset">>, Img},
                                     {set, <<"networks">>, Nets1}], Config1),
                    Config3 =
                        case jsxd:get(<<"type">>, Config2) of
                            {ok, <<"zone">>} ->
                                Config2;
                            _ ->
                                ND = case jsxd:get(<<"nic_driver">>, Config) of
                                         {ok, ND0} ->
                                             ND0;
                                         _ ->
                                             jsxd:get([<<"networks">>, 0, model], <<"virtio">>, C)
                                     end,
                                DD = case jsxd:get(<<"disk_driver">>, Config)  of
                                         {ok, DD0} ->
                                             DD0;
                                         _ ->
                                             jsxd:get([<<"disks">>, 0, model], <<"virtio">>, C)
                                     end,
                                jsxd:thread([{set, <<"disk_driver">>, DD},
                                             {set, <<"nic_driver">>, ND}],
                                            Config2)
                        end,
                    ok = sniffle_dataset:create(Img),
                    sniffle_dataset:set(Img, Config3),
                    case {backend(), sniffle_s3:config(image)} of
                        {s3, {ok, {S3Host, S3Port, AKey, SKey, Bucket}}} ->
                            ok = libchunter:store_snapshot(
                                   Server, Port, Vm, SnapID, Img, S3Host,
                                   S3Port, Bucket, AKey, SKey, []);
                        _ ->
                            ok = libchunter:store_snapshot(Server, Port, Vm,
                                                           SnapID, Img)
                        end,
                    {ok, Img};
                undefined ->
                    not_found
            end;
        E ->
            E
    end.

add_nic(Vm, Network) ->
    lager:info("[NIC ADD] Adding a new nic in ~s to ~s", [Network, Vm]),
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            lager:info("[NIC ADD] VM found.", []),
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {ok, HypervisorObj} = sniffle_hypervisor:get(H),
            {ok, Port} = jsxd:get(<<"port">>, HypervisorObj),
            {ok, HostB} = jsxd:get(<<"host">>, HypervisorObj),
            HypervisorsNetwork = jsxd:get([<<"networks">>], [], HypervisorObj),
            Server = binary_to_list(HostB),
            libchunter:ping(Server, Port),
            case jsxd:get(<<"state">>, V) of
                {ok, <<"stopped">>} ->
                    Requirements = [{must, oneof, <<"tag">>, HypervisorsNetwork}],
                    lager:info("[NIC ADD] Checking requirements: ~p.", [Requirements]),
                    case sniffle_network:claim_ip(Network, Requirements) of
                        {ok, IPRange, {Tag, IP, Net, Gw}} ->
                            {ok, Range} = sniffle_iprange:get(IPRange),
                            IPb = sniffle_iprange_state:to_bin(IP),
                            Netb = sniffle_iprange_state:to_bin(Net),
                            GWb = sniffle_iprange_state:to_bin(Gw),

                            NicSpec0 =
                                jsxd:from_list([{<<"ip">>, IPb},
                                                {<<"gateway">>, GWb},
                                                {<<"netmask">>, Netb},
                                                {<<"nic_tag">>, Tag }]),
                            NicSpec1 =
                                case jsxd:get([<<"config">>, <<"networks">>], V) of
                                    {ok, [_|_]} ->
                                        NicSpec0;
                                    _ ->
                                        jsxd:set([<<"primary">>], true, NicSpec0)
                                end,
                            NicSpec2 =
                                case jsxd:get(<<"vlan">>, 0, Range) of
                                    0 ->
                                        eplugin:apply(
                                          'vm:ip_assigned',
                                          [Vm, update, <<"unknown">>, Tag, IPb, Netb, GWb, none]),
                                        NicSpec1;
                                    VLAN ->
                                        eplugin:apply(
                                          'vm:ip_assigned',
                                          [Vm, update, <<"unknown">>, Tag, IPb, Netb, GWb, VLAN]),
                                        jsxd:set(<<"vlan_id">>, VLAN, NicSpec1)
                                end,
                            UR = [{<<"add_nics">>, [NicSpec2]}],
                            ok = libchunter:update_machine(Server, Port, Vm, [], UR),
                            M = [{<<"network">>, IPRange},
                                 {<<"ip">>, IP}],
                            Ms1= case jsxd:get([<<"network_mappings">>], V) of
                                     {ok, Ms} ->
                                         [M | Ms];
                                     _ ->
                                         [M]
                                 end,
                            sniffle_vm:set(Vm, [<<"network_mappings">>], Ms1);
                        E ->
                            lager:error("Could not get claim new IP: ~p for ~p ~p",
                                        [E, Network, Requirements]),
                            {error, claim_failed}
                    end;
                E ->
                    lager:error("VM needs to be stoppped: ~p", [E]),
                    {error, not_stopped}
            end;
        E ->
            lager:error("Could not get new IP - could not get VM: ~p", [E]),
            E
    end.

remove_nic(Vm, Mac) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            NicMap = make_nic_map(V),
            case jsxd:get(Mac, NicMap) of
                {ok, Idx}  ->
                    {ok, H} = jsxd:get(<<"hypervisor">>, V),
                    {Server, Port} = get_hypervisor(H),
                    libchunter:ping(Server, Port),
                    case jsxd:get(<<"state">>, V) of
                        {ok, <<"stopped">>} ->
                            UR = [{<<"remove_nics">>, [Mac]}],
                            {ok, IpStr} = jsxd:get([<<"config">>, <<"networks">>, Idx, <<"ip">>], V),
                            IP = sniffle_iprange_state:parse_bin(IpStr),
                            {ok, Ms} = jsxd:get([<<"network_mappings">>], V),
                            ok = libchunter:update_machine(Server, Port, Vm, [], UR),
                            case [ Network || [{<<"network">>, Network},
                                               {<<"ip">>, IP1}] <- Ms, IP1 =:= IP] of
                                [Network] ->
                                    sniffle_iprange:release_ip(Network, IP),
                                    Ms1 = [ [{<<"network">>, N},
                                             {<<"ip">>, IP1}] ||
                                              [{<<"network">>, N},
                                               {<<"ip">>, IP1}] <- Ms,
                                              IP1 =/= IP],
                                    sniffle_vm:set(Vm, [<<"network_mappings">>], Ms1);
                                _ ->
                                    ok
                            end;
                        _ ->
                            {error, not_stopped}
                    end;
                _ ->
                    {error, not_found}
            end;
        E ->
            E
    end.

primary_nic(Vm, Mac) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            NicMap = make_nic_map(V),
            case jsxd:get(Mac, NicMap) of
                {ok, _Idx}  ->
                    {ok, H} = jsxd:get(<<"hypervisor">>, V),
                    {Server, Port} = get_hypervisor(H),
                    libchunter:ping(Server, Port),
                    case jsxd:get(<<"state">>, V) of
                        {ok, <<"stopped">>} ->
                            UR = [{<<"update_nics">>, [[{<<"mac">>, Mac}, {<<"primary">>, true}]]}],
                            libchunter:update_machine(Server, Port, Vm, [], UR);
                        _ ->
                            {error, not_stopped}
                    end;
                _ ->
                    {error, not_found}
            end;
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Updates a virtual machine form a package uuid and a config
%%   object.
%% @end
%%--------------------------------------------------------------------
-spec update(Vm::fifo:uuid(), Package::fifo:uuid(), Config::fifo:config()) ->
                    not_found | {error, timeout} | ok.
update(Vm, Package, Config) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, Hypervisor} = jsxd:get(<<"hypervisor">>, V),
            {ok, HypervisorObj} = sniffle_hypervisor:get(Hypervisor),
            {ok, Port} = jsxd:get(<<"port">>, HypervisorObj),
            {ok, HostB} = jsxd:get(<<"host">>, HypervisorObj),
            Host = binary_to_list(HostB),
            {ok, OrigRam} = jsxd:get([<<"config">>, <<"ram">>], V),
            OrigPkg = jsxd:get(<<"package">>, <<"custom">>, V),
            case Package of
                undefined ->
                    libchunter:update_machine(Host, Port, Vm, [], Config);
                _ ->
                    case sniffle_package:get(Package) of
                        {ok, P} ->
                            {ok, NewRam} = jsxd:get(<<"ram">>, P),
                            case jsxd:get([<<"resources">>, <<"free-memory">>], HypervisorObj) of
                                {ok, Ram} when
                                      Ram > (NewRam - OrigRam) ->
                                    set(Vm, <<"package">>, Package),
                                    log(Vm, <<"Updating VM from package '",
                                              OrigPkg/binary, "' to '",
                                              Package/binary, "'.">>),
                                    libchunter:update_machine(Host, Port, Vm, P, Config);
                                _ ->
                                    {error, not_enough_resources}
                            end;
                        E2 ->
                            E2
                    end
            end;
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Registers am existing VM, no checks made here.
%% @end
%%--------------------------------------------------------------------
-spec register(VM::fifo:uuid(), Hypervisor::binary()) ->
                      {error, timeout} | ok.
register(Vm, Hypervisor) ->
    do_write(Vm, register, Hypervisor).

%%--------------------------------------------------------------------
%% @doc Unregisteres an existing VM, this includs freeling the IP
%%   addresses it had.
%% @end
%%--------------------------------------------------------------------
-spec unregister(VM::fifo:uuid()) ->
                        {error, timeout} |
                        ok.
unregister(Vm) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            lists:map(fun(N) ->
                              {ok, Net} = jsxd:get(<<"network">>, N),
                              {ok, Ip} = jsxd:get(<<"ip">>, N),
                              sniffle_iprange:release_ip(Net, Ip)
                      end,jsxd:get(<<"network_mappings">>, [], V)),
            VmPrefix = [<<"vms">>, Vm],
            ChannelPrefix = [<<"channels">>, Vm],
            case libsnarl:user_list() of
                {ok, Users} ->
                    spawn(fun () ->
                                  [libsnarl:user_revoke_prefix(U, VmPrefix) || U <- Users],
                                  [libsnarl:user_revoke_prefix(U, ChannelPrefix) || U <- Users]
                          end);
                _ ->
                    ok
            end,
            case libsnarl:role_list() of
                {ok, Roles} ->
                    spawn(fun () ->
                                  [libsnarl:role_revoke_prefix(G, VmPrefix) || G <- Roles],
                                  [libsnarl:role_revoke_prefix(G, ChannelPrefix) || G <- Roles]
                          end);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    do_write(Vm, unregister).

%%--------------------------------------------------------------------
%% @doc Tries to creat a VM from a Package and dataset uuid. This
%%   function just creates the UUID and returns it after handing the
%%   data off to the create fsm.
%% @end
%%--------------------------------------------------------------------
-spec create(Package::binary(), Dataset::binary(), Config::fifo:config()) ->
                    {error, timeout} | {ok, fifo:uuid()}.
create(Package, Dataset, Config) ->
    UUID = uuid:uuid4s(),
    do_write(UUID, register, <<"pooled">>), %we've to put pending here since undefined will cause a wrong call!
    Config1 = jsxd:from_list(Config),
    Config2 = jsxd:update(<<"networks">>,
                          fun (N) ->
                                  jsxd:from_list(
                                    lists:map(fun ({Iface, Net}) ->
                                                      [{<<"interface">>, Iface},
                                                       {<<"network">>, Net}]
                                              end, N))
                          end, [], Config1),
    sniffle_vm:set(UUID, <<"config">>, Config2),
    sniffle_vm:set(UUID, <<"state">>, <<"pooled">>),
    sniffle_vm:set(UUID, <<"package">>, Package),
    sniffle_vm:set(UUID, <<"dataset">>, Dataset),
    libhowl:send(UUID, [{<<"event">>, <<"update">>},
                        {<<"data">>,
                         [{<<"config">>, Config2},
                          {<<"package">>, Package}]}]),
    sniffle_create_pool:add(UUID, Package, Dataset, Config),
    %%sniffle_create_fsm:create(UUID, Package, Dataset, Config),
    {ok, UUID}.


%%--------------------------------------------------------------------
%% @doc Reads a VM object form the DB.
%% @end
%%--------------------------------------------------------------------
-spec get(Vm::fifo:uuid()) ->
                 not_found | {error, timeout} | fifo:vm_config().
get(Vm) ->
    sniffle_entity_read_fsm:start({?VNODE, ?SERVICE}, get, Vm).

%%--------------------------------------------------------------------
%% @doc Lists all vm's.
%% @end
%%--------------------------------------------------------------------
-spec list() ->
                  {error, timeout} | [fifo:uuid()].
list() ->
    sniffle_coverage:start(?MASTER, ?SERVICE, list).

%%--------------------------------------------------------------------
%% @doc Lists all vm's and fiters by a given matcher set.
%% @end
%%--------------------------------------------------------------------
-spec list([fifo:matcher()], boolean()) -> {error, timeout} | {ok, [fifo:uuid()]}.

list(Requirements, true) ->
    {ok, Res} = sniffle_full_coverage:start(
                  ?MASTER, ?SERVICE, {list, Requirements, true}),
    Res1 = rankmatcher:apply_scales(Res),
    {ok,  lists:sort(Res1)};

list(Requirements, false) ->
    {ok, Res} = sniffle_coverage:start(
                  ?MASTER, ?SERVICE, {list, Requirements}),
    Res1 = rankmatcher:apply_scales(Res),
    {ok,  lists:sort(Res1)}.

%%--------------------------------------------------------------------
%% @doc Tries to delete a VM, either unregistering it if no
%%   Hypervisor was assigned or triggering the delete on hypervisor
%%   site.
%% @end
%%--------------------------------------------------------------------
-spec delete(Vm::fifo:uuid()) ->
                    {error, timeout} | not_found | ok.
delete(Vm) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get(<<"hypervisor">>, V) of
                undefined ->
                    case jsxd:get(<<"state">>, V) of
                        {ok, <<"storing">>} ->
                            libhowl:send(<<"command">>,
                                         [{<<"event">>, <<"vm-stored">>},
                                          {<<"uuid">>, uuid:uuid4s()},
                                          {<<"data">>,
                                           [{<<"uuid">>, Vm}]}]),
                            set(Vm, [{<<"state">>, <<"stored">>},
                                     {<<"hypervisor">>, delete}]);
                        _ ->
                            finish_delete(Vm)
                    end;
                {ok, <<"pooled">>} ->
                    finish_delete(Vm);
                {ok, <<"pending">>} ->
                    finish_delete(Vm);
                {ok, H} ->
                    case jsxd:get(<<"state">>, V) of
                        undefined ->
                            finish_delete(Vm);
                        {ok, <<"deleting">>} ->
                            finish_delete(Vm);
                        %% When the vm was in failed state it got never handed off to the hypervisor
                        {ok, <<"failed-", _/binary>>} ->
                            finish_delete(Vm);
                        {ok, <<"storing">>} ->
                            libhowl:send(<<"command">>,
                                         [{<<"event">>, <<"vm-stored">>},
                                          {<<"uuid">>, uuid:uuid4s()},
                                          {<<"data">>,
                                           [{<<"uuid">>, Vm}]}]),
                            set(Vm, [{<<"state">>, <<"stored">>},
                                     {<<"hypervisor">>, delete}]);
                        _ ->
                            set(Vm, <<"state">>, <<"deleting">>),
                            {Host, Port} = get_hypervisor(H),
                            libchunter:delete_machine(Host, Port, Vm)
                    end
            end,
            ok;
        E ->
            E
    end.

finish_delete(Vm) ->
    sniffle_vm:unregister(Vm),
    libhowl:send(Vm, [{<<"event">>, <<"delete">>}]),
    libhowl:send(<<"command">>,
                 [{<<"event">>, <<"vm-delete">>},
                  {<<"uuid">>, uuid:uuid4s()},
                  {<<"data">>,
                   [{<<"uuid">>, Vm}]}]).

%%--------------------------------------------------------------------
%% @doc Triggers the start of a VM on the hypervisor.
%% @end
%%--------------------------------------------------------------------
-spec start(Vm::fifo:uuid()) ->
                   {error, timeout} | not_found | ok.
start(Vm) ->
    case fetch_hypervisor(Vm) of
        {ok, Server, Port} ->
            libchunter:start_machine(Server, Port, Vm);
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Triggers the stop of a VM on the hypervisor.
%% @end
%%--------------------------------------------------------------------
-spec stop(Vm::fifo:uuid()) ->
                  {error, timeout} | not_found | ok.
stop(Vm) ->
    stop(Vm, []).

%%--------------------------------------------------------------------
%% @doc Triggers the start of a VM on the hypervisor allowing options.
%% @end
%%--------------------------------------------------------------------
-spec stop(Vm::fifo:uuid(), Options::[atom()|{atom(), term()}]) ->
                  {error, timeout} | not_found | ok.
stop(Vm, Options) ->
    case fetch_hypervisor(Vm) of
        {ok, Server, Port} ->
            libchunter:stop_machine(Server, Port, Vm, Options);
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Triggers the reboot of a VM on the hypervisor.
%% @end
%%--------------------------------------------------------------------
-spec reboot(Vm::fifo:uuid()) ->
                    {error, timeout} | not_found | ok.
reboot(Vm) ->
    reboot(Vm, []).

%%--------------------------------------------------------------------
%% @doc Triggers the reboot of a VM on the hypervisor allowing
%%   options.
%% @end
%%--------------------------------------------------------------------
-spec reboot(Vm::fifo:uuid(), Options::[atom()|{atom(), term()}]) ->
                    {error, timeout} | not_found | ok.
reboot(Vm, Options) ->
    case fetch_hypervisor(Vm) of
        {ok, Server, Port} ->
            libchunter:reboot_machine(Server, Port, Vm, Options);
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Reads the logs of a vm.
%% @end
%%--------------------------------------------------------------------
-spec logs(Vm::fifo:uuid()) ->
                  not_found | {error, timeout} | [fifo:log()].
logs(Vm) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, jsxd:get(<<"log">>, [], V)};
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Sets the owner of a VM.
%% @end
%%--------------------------------------------------------------------
-spec set_owner(Vm::fifo:uuid(), Owner::fifo:uuid()) ->
                       not_found | {error, timeout} | [fifo:log()].
set_owner(Vm, Owner) ->
    libsnarl:org_execute_trigger(Owner, vm_create, Vm),
    libhowl:send(Vm, [{<<"event">>, <<"update">>},
                      {<<"data">>,
                       [{<<"owner">>, Owner}]}]),
    set(Vm, <<"owner">>, Owner).

%%--------------------------------------------------------------------
%% @doc Adds a new log to the VM and timestamps it.
%% @end
%%--------------------------------------------------------------------
-spec log(Vm::fifo:uuid(), Log::term()) ->
                 {error, timeout} | not_found | ok.
log(Vm, Log) ->
    Timestamp = timestamp(),
    case do_write(Vm, log, {Timestamp, Log}) of
        ok ->
            libhowl:send(Vm, [{<<"event">>, <<"log">>},
                              {<<"data">>,
                               [{<<"log">>, Log},
                                {<<"date">>, Timestamp}]}]),
            ok;
        R ->
            R
    end.

%%--------------------------------------------------------------------
%% @doc Creates a new ZFS snapshot of the Vm's disks on the
%%   hypervisor.
%% @end
%%--------------------------------------------------------------------
-spec snapshot(VM::fifo:uuid(), Comment::binary()) ->
                      {error, timeout} | not_found | {ok, UUID::fifo:uuid()}.
snapshot(Vm, Comment) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            {ok, H} = jsxd:get(<<"hypervisor">>, V),
            {Server, Port} = get_hypervisor(H),
            UUID = uuid:uuid4s(),
            TimeStamp = timestamp(),
            libchunter:snapshot(Server, Port, Vm, UUID),
            Prefix = [<<"snapshots">>, UUID],
            do_write(Vm, set,
                     [{Prefix ++ [<<"timestamp">>], TimeStamp},
                      {Prefix ++ [<<"comment">>], Comment},
                      {Prefix ++ [<<"state">>], <<"pending">>}]),
            log(Vm, <<"Created snapshot ", UUID/binary, ": ", Comment/binary>>),
            {ok, UUID};
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Deletes a ZFS snapshot of the Vm's disks on the ahypervisor.
%% @end
%%--------------------------------------------------------------------
-spec delete_snapshot(VM::fifo:uuid(), UUID::binary()) ->
                             {error, timeout} | not_found | ok.
delete_snapshot(Vm, UUID) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get([<<"snapshots">>, UUID, <<"timestamp">>], V) of
                {ok, _} ->
                    {ok, H} = jsxd:get(<<"hypervisor">>, V),
                    {Server, Port} = get_hypervisor(H),
                    libchunter:delete_snapshot(Server, Port, Vm, UUID),
                    Prefix = [<<"snapshots">>, UUID],
                    do_write(Vm, set,
                             [{Prefix ++ [<<"state">>], <<"deleting">>}]),
                    log(Vm, <<"Deleting snapshot ", UUID/binary, ".">>),
                    ok;
                undefined ->
                    {error, not_found}
            end;
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Rolls back a ZFS snapshot of the Vm's disks on the
%%   ahypervisor.
%% @end
%%--------------------------------------------------------------------
-spec rollback_snapshot(VM::fifo:uuid(), UUID::binary()) ->
                               {error, timeout} | not_found | ok.
rollback_snapshot(Vm, UUID) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get(<<"state">>, V) of
                {ok, <<"stopped">>} ->
                    {ok, H} = jsxd:get(<<"hypervisor">>, V),
                    {Server, Port} = get_hypervisor(H),
                    libchunter:rollback_snapshot(Server, Port, Vm, UUID);
                {ok, State} ->
                    log(Vm, <<"Not rolled back since state is ",
                              State/binary, ".">>),
                    {error, not_stopped}
            end;
        E ->
            E
    end.

-spec commit_snapshot_rollback(VM::fifo:uuid(), UUID::binary()) ->
                                      {error, timeout} | not_found | ok.

commit_snapshot_rollback(Vm, UUID) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get([<<"snapshots">>, UUID, <<"timestamp">>], V) of
                {ok, T} when is_number(T) ->
                    Snapshots1 =
                        jsxd:fold(
                          fun (SUUID, Sn, A) ->
                                  case jsxd:get(<<"timestamp">>, 0, Sn) of
                                      X when is_number(X),
                                             X > T ->
                                          A;
                                      _ ->
                                          jsxd:set(SUUID, Sn, A)
                                  end
                          end, [], jsxd:get(<<"snapshots">>, [], V)),
                    do_write(Vm, set, [{[<<"snapshots">>], Snapshots1}]);
                undefined ->
                    {error, not_found}
            end;
        E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc Sets a attribute on the VM object.
%% @end
%%--------------------------------------------------------------------
-spec set(Vm::fifo:uuid(), Attribute::fifo:keys(), Value::fifo:value()|delete) ->
                 {error, timeout} | not_found | ok.
set(Vm, Attribute, Value) ->
    do_write(Vm, set, [{Attribute, Value}]).


%%--------------------------------------------------------------------
%% @doc Sets multiple attributes on the VM object.
%% @end
%%--------------------------------------------------------------------
-spec set(Vm::fifo:uuid(), Attributes::fifo:attr_list()) ->
                 {error, timeout} | not_found | ok.
set(Vm, Attributes) ->
    do_write(Vm, set, Attributes).

%%%===================================================================
%%% Internal Functions
%%%===================================================================

-spec do_write(VM::fifo:uuid(), Op::atom()) -> fifo:write_fsm_reply().

do_write(VM, Op) ->
    sniffle_entity_write_fsm:write({?VNODE, ?SERVICE}, VM, Op).

-spec do_write(VM::fifo:uuid(), Op::atom(), Val::term()) -> fifo:write_fsm_reply().

do_write(VM, Op, Val) ->
    sniffle_entity_write_fsm:write({?VNODE, ?SERVICE}, VM, Op, Val).

get_hypervisor(Hypervisor) ->
    case sniffle_hypervisor:get(Hypervisor) of
        {ok, HypervisorObj} ->
            {ok, Port} = jsxd:get(<<"port">>, HypervisorObj),
            {ok, Host} = jsxd:get(<<"host">>, HypervisorObj),
            {binary_to_list(Host), Port};
        E ->
            E
    end.

fetch_hypervisor(Vm) ->
    case sniffle_vm:get(Vm) of
        {ok, V} ->
            case jsxd:get(<<"hypervisor">>, V) of
                {ok, H} ->
                    {Server, Port} = get_hypervisor(H),
                    {ok, Server, Port};
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

make_nic_map(V) ->
    jsxd:map(fun(Idx, Nic) ->
                     {ok, NicMac} = jsxd:get([<<"mac">>], Nic),
                     {NicMac, Idx}
             end, jsxd:get([<<"config">>, <<"networks">>], [], V)).

timestamp() ->
    {Mega,Sec,Micro} = erlang:now(),
    (Mega*1000000+Sec)*1000000+Micro.

children(VM, Parent) ->
    children(VM, Parent, false).

children(VM, Parent, Recursive) ->
    case jsxd:get([<<"backups">>], VM) of
        {ok, Backups} ->
            R = [U ||
                    {U, B} <- Backups,
                    jsxd:get(<<"parent">>, B) =:= {ok, Parent}],
            case Recursive of
                true ->
                    lists:flatten([children(VM, C, true) || C <- R]) ++ R;
                false ->
                    R
            end;
        _ ->
            []
    end.

do_delete_backup(UUID, VM, BID) ->
    {ok, Files} = jsxd:get([<<"backups">>, BID, <<"files">>], VM),
    Fs = case jsxd:get([<<"backups">>, BID, <<"xml">>], false, VM) of
             true ->
                 [<<UUID/binary, "/", BID/binary, ".xml">> | Files];
             false ->
                 Files
         end,
    [sniffle_s3:delete(snapshot, F) || F <- Fs],
    {ok, H} = jsxd:get(<<"hypervisor">>, VM),
    {Server, Port} = get_hypervisor(H),
    libchunter:delete_snapshot(Server, Port, UUID, BID),
    sniffle_vm:set(UUID, [<<"backups">>, BID], delete),
    libhowl:send(UUID, [{<<"event">>, <<"backup">>},
                        {<<"data">>, [{<<"action">>, <<"deleted">>},
                                      {<<"uuid">>, BID}]}]).

backend() ->
    sniffle_opt:get(storage, general, backend, large_data_backend, internal).

-ifdef(TEST).

children_test() ->
    VM = [{<<"backups">>,
           [{<<"b">>,
             [{<<"parent">>, <<"a">>}]},
            {<<"c">>,
             [{<<"parent">>, <<"b">>}]},
            {<<"e">>,
             [{<<"parent">>, <<"c">>}]},
            {<<"d">>,
             [{<<"parent">>, <<"a">>}]},
            {<<"a">>, []}
           ]}],
    C = children(VM, <<"a">>),
    C1 = children(VM, <<"a">>, true),
    ?assertEqual(C, [<<"b">>, <<"d">>]),
    ?assertEqual(C1, [<<"e">>, <<"c">>, <<"b">>, <<"d">>]),
    ok.

-endif.
