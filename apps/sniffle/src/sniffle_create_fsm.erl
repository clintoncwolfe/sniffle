%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 17 Oct 2012 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(sniffle_create_fsm).

-behaviour(gen_fsm).

-include("sniffle.hrl").

%% API
-export([create/4,
         start_link/4]).

%% gen_fsm callbacks
-export([
         init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         get_networks/2,
         code_change/4
        ]).

-export([
         generate_grouping_rules/2,
         get_package/2,
         get_dataset/2,
         callbacks/2,
         create/2,
         get_server/2,
         create_permissions/2,
         get_ips/2,
         build_key/2
        ]).

-define(SERVER, ?MODULE).

-ignore_xref([
              create/2,
              generate_grouping_rules/2,
              callbacks/2,
              get_dataset/2,
              get_package/2,
              start_link/4,
              get_server/2,
              create_permissions/2,
              get_networks/2,
              get_ips/2,
              build_key/2
             ]).

-record(state, {
          test_pid,
          uuid,
          package,
          package_name,
          dataset,
          dataset_name,
          config,
          owner,
          creator,
          type,
          nets,
          hypervisor,
          mapping = [],
          old_nics,
          delay = 5000,
          retry = 0,
          max_retries = 0,
          grouping_rules = []
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(UUID, Package, Dataset, Config) ->
    gen_fsm:start_link(?MODULE, [UUID, Package, Dataset, Config], []).

create(UUID, Package, Dataset, Config) ->
    supervisor:start_child(sniffle_create_fsm_sup, [UUID, Package, Dataset, Config]).


%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([UUID, Package, Dataset, Config]) ->
    lager:info("[create] Starting FSM for ~s", [UUID]),
    process_flag(trap_exit, true),
    Config1 = jsxd:from_list(Config),
    %% We're transforming the networks map {nic -> networkid} into
    %% an array that is close to what it will look after the VM was
    %% created, that way the structure stays consistant.
    Delay = case application:get_env(create_retry_delay) of
                {ok, D} ->
                    D;
                _ ->
                    5000
            end,
    MaxRetries = case application:get_env(create_max_retries) of
                     {ok, D1} ->
                         D1;
                     _ ->
                         5
                 end,
    {ok, generate_grouping_rules, #state{
                                     uuid = UUID,
                                     package_name = Package,
                                     dataset_name = Dataset,
                                     config = Config1,
                                     delay = Delay,
                                     max_retries = MaxRetries
                                    }, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% When a grouping is used during creation certain additional rules
%% need to be applied to guarantee the propper constraints. Here we get
%% them.
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
generate_grouping_rules(_Event, State = #state{
                                           uuid = UUID,
                                           config = Config
                                          }) ->
    case jsxd:get(<<"grouping">>, Config) of
        {ok, Grouping} ->
            Rules = sniffle_grouping:create_rules(Grouping),
            case sniffle_grouping:add_element(Grouping, UUID) of
                ok ->
                    sniffle_vm:set(UUID, <<"grouping">>, Grouping),

                    {next_state, create_permissions,
                     State#state{grouping_rules = Rules}, 0};
                E ->
                    lager:error("Creation Faild since grouing could not be "
                                "joined: ~p", [E]),
                    {stop, E, State}
            end;
        _ ->
            {next_state, create_permissions, State, 0}
    end.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
create_permissions(_Event, State = #state{
                                      uuid = UUID,
                                      config = Config}) ->
    {ok, Creator} = jsxd:get([<<"owner">>], Config),
    libsnarl:user_grant(Creator, [<<"vms">>, UUID, <<"...">>]),
    libsnarl:user_grant(Creator, [<<"channels">>, UUID, <<"join">>]),
    eplugin:call('create:permissions', UUID, Config, Creator),
    Owner = case libsnarl:user_active_org(Creator) of
                {ok, <<"">>} ->
                    lager:warning("User ~p has no active org.", [Creator]),
                    <<"">>;
                {ok, Org} ->
                    lager:warning("User ~p has active org: ~p.", [Creator, Org]),
                    sniffle_vm:set(UUID, <<"owner">>, Org),
                    libsnarl:org_execute_trigger(Org, vm_create, UUID),
                    Org
            end,
    libhowl:send(UUID, [{<<"event">>, <<"update">>},
                        {<<"data">>, [{<<"owner">>, Owner}]}]),
    Config1 = jsxd:set([<<"owner">>], Owner, Config),
    {next_state, get_package,
     State#state{
       config = Config1,
       creator = Creator,
       owner = Owner
      }, 0}.

get_package(_Event, State = #state{
                               uuid = UUID,
                               package_name = PackageName
                              }) ->
    sniffle_vm:log(UUID, <<"Fetching package ", PackageName/binary>>),
    sniffle_vm:set(UUID, <<"state">>, <<"fetching_package">>),
    {ok, Package} = sniffle_package:get(PackageName),
    sniffle_vm:set(UUID, <<"package">>, PackageName),
    {next_state, get_dataset, State#state{package = Package}, 0}.

get_dataset(_Event, State = #state{
                               uuid = UUID,
                               dataset_name = DatasetName
                              }) ->
    sniffle_vm:set(UUID, <<"state">>, <<"fetching_dataset">>),
    sniffle_vm:log(UUID, <<"Fetching dataset ", DatasetName/binary>>),
    {ok, Dataset} = sniffle_dataset:get(DatasetName),
    sniffle_vm:set(UUID, <<"dataset">>, DatasetName),
    {next_state, callbacks, State#state{dataset = Dataset}, 0}.


callbacks(_Event, State = #state{
                             uuid = UUID,
                             dataset = Dataset,
                             package = Package,
                             config = Config}) ->
    {UUID, Package1, Dataset1, Config1} =
        eplugin:fold('create:update', {UUID, Package, Dataset, Config}),
    {next_state, get_networks, State#state{
                                 dataset = Dataset1,
                                 package = Package1,
                                 config = Config1}, 0}.

get_networks(_event, State = #state{uuid = UUID, retry = R, max_retries = Max})
  when R > Max ->
    sniffle_vm:set(UUID, <<"state">>, <<"failed">>),
    BR = list_to_binary(integer_to_list(R)),
    BMax= list_to_binary(integer_to_list(Max)),
    sniffle_vm:log(UUID, <<"Failed after too many retries: ", BR/binary, " > ",
                           BMax/binary>>),
    {stop, failed, State};

get_networks(_Event, State = #state{config = Config, retry = Try}) ->
    Nets = jsxd:get([<<"networks">>], [], Config),
    Nets1 = lists:map(fun({Name, Network}) ->
                              {ok, N} = sniffle_network:get(Network),
                              {ok, Rs} = jsxd:get(<<"ipranges">>, N),
                              Rs1 = [{R, sniffle_iprange:get(R)} || R <- Rs],
                              Rs2 = [{R, D} || {R, {ok, D}} <- Rs1],
                              Rs3 = lists:map(fun({ID, R}) ->
                                                      {ok, Tag} = jsxd:get(<<"tag">>, R),
                                                      {ID, Tag}
                                              end, Rs2),
                              {Name, Rs3}
                      end, Nets),
    {next_state, get_server, State#state{nets = Nets1, retry = Try + 1}, 0}.

get_server(_Event, State = #state{
                              dataset = Dataset,
                              uuid = UUID,
                              creator = Creator,
                              config = Config,
                              nets = Nets,
                              package = Package,
                              grouping_rules = GroupingRules}) ->
    lager:debug("get_server: ~p", [Nets]),
    {ok, Ram} = jsxd:get(<<"ram">>, Package),
    sniffle_vm:set(UUID, <<"state">>, <<"fetching_server">>),
    Permission = [<<"hypervisors">>, {<<"res">>, <<"name">>}, <<"create">>],
    {ok, Type} = jsxd:get(<<"type">>, Dataset),
    case libsnarl:user_cache(Creator) of
        {ok, Permissions} ->
            Conditions0 = jsxd:get(<<"requirements">>, [], Package)
                ++ jsxd:get(<<"requirements">>, [], Dataset)
                ++ jsxd:get(<<"requirements">>, [], Config),
            Conditions1 = [{must, 'allowed', Permission, Permissions},
                           {must, 'element', <<"virtualisation">>, Type},
                           {must, '>=', <<"resources.free-memory">>, Ram}] ++
                lists:map(fun(C) -> make_condition(C, Permissions) end, Conditions0),
            Conditions2 = Conditions1 ++ GroupingRules,
            {UUID, Config, Conditions} = eplugin:fold('create:conditions', {UUID, Config, Conditions2}),
            lager:debug("[CREATE] Finding hypervisor: ~p", [Conditions]),
            {ok, Hypervisors} = sniffle_hypervisor:list(Conditions, false),
            Hypervisors1 = eplugin:fold('create:hypervisor_select', Hypervisors),
            Hypervisors2 = lists:reverse(lists:sort(Hypervisors1)),
            lager:debug("[CREATE] Hypervisors found: ~p", [Hypervisors2]),
            case test_hypervisors(UUID, Hypervisors2, Nets) of
                {ok, HypervisorID, H, Nets1} ->
                    RamB = list_to_binary(integer_to_list(Ram)),
                    sniffle_vm:log(UUID, <<"Assigning memory ", RamB/binary>>),
                    sniffle_vm:log(UUID, <<"Deploying on hypervisor ", HypervisorID/binary>>),
                    eplugin:call('create:handoff', UUID, HypervisorID),
                    {next_state, get_ips,
                     State#state{hypervisor = H,
                                 nets = Nets1}, 0};
                _ ->
                    do_retry(State)
            end;
        _ ->
            do_retry(State)
    end.
do_retry(State = #state{test_pid = undefined, delay = Delay}) ->
    {next_state, get_networks, State, Delay};
do_retry(State = #state{test_pid = Pid}) ->
    Pid ! failed,
    {stop, normal, State}.


get_ips(_Event, State = #state{nets = Nets,
                               uuid = UUID,
                               config = Config,
                               dataset = Dataset}) ->
    lager:debug("get_ips: ~p", [Nets]),
    {ok, Nics0} = jsxd:get(<<"networks">>, Dataset),
    case update_nics(UUID, Nics0, Config, Nets) of
        {error, E, Mapping} ->
            lager:error("[create] Failed to get ips: ~p", [E]),
            [sniffle_iprange:release_ip(Range, IP) ||{Range, IP} <- Mapping],
            do_retry(State);
        {Nics1, Mapping} ->
            Dataset1 = jsxd:set(<<"networks">>, Nics1, Dataset),
            MappingsJSON = jsxd:from_list([[{<<"ip">>, IP},
                                            {<<"network">>, Range}]
                                           || {Range, IP} <- Mapping]),
            sniffle_vm:set(UUID,
                           <<"network_mappings">>,
                           MappingsJSON),
            {next_state, build_key,
             State#state{dataset = Dataset1, mapping = Mapping, old_nics = Nics0},
             0}
    end.

build_key(_Event, State = #state{
                             creator = Creator,
                             config = Config}) ->
    case libsnarl:user_keys(Creator) of
        {ok, []} ->
            {next_state, create, State, 0};
        {ok, Keys} ->
            KeysB = iolist_to_binary(merge_keys(Keys)),
            Config1 = jsxd:update([<<"ssh_keys">>],
                                  fun (Ks) ->
                                          <<KeysB/binary, Ks/binary>>
                                  end, KeysB, Config),
            {next_state, create, State#state{config = Config1}, 0}
    end.


create(_Event, State = #state{
                          dataset = Dataset,
                          package = Package,
                          uuid = UUID,
                          config = Config,
                          hypervisor = {Host, Port},
                          mapping = Mapping,
                          old_nics = Nics}) ->
    sniffle_vm:log(UUID, <<"Handing off to hypervisor.">>),
    sniffle_vm:set(UUID, <<"state">>, <<"creating">>),
    case libchunter:create_machine(Host, Port, UUID, Package, Dataset, Config) of
        {error, lock} ->
            [sniffle_iprange:release_ip(Range, IP) ||{Range, IP} <- Mapping],
            do_retry(
              State#state{dataset = jsxd:set(<<"networks">>, Nics, Dataset)});
        ok ->
            {stop, normal, State}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------

terminate(_, create, _StateData) ->
    ok;

terminate(shutdown, _StateName, _StateData) ->
    ok;

terminate(_Reason, StateName, _State = #state{uuid=UUID}) ->
    eplugin:call('create:fail', UUID, StateName),
    StateBin = list_to_binary(atom_to_list(StateName)),
    sniffle_vm:set(UUID, <<"state">>, <<"failed-", StateBin/binary>>),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

merge_keys(Keys) ->
    [[Key, "\n"] || {_ID, Key} <- Keys].

test_net(Have, [{ID, Tag} | R]) ->
    lager:debug("test_net: ~p ~p", [Have, [{ID, Tag} | R]]),
    case lists:member(Tag, Have) of
        true ->
            case sniffle_iprange:full(ID) of
                true ->
                    test_net(Have, R);
                false ->
                    ID
            end;
        _ ->
            test_net(Have, R)
    end;

test_net(_Have, []) ->
    lager:debug("test_net: false"),
    false.

test_hypervisors(UUID, [{_, HypervisorID} | R], Nets) ->
    lager:debug("test_hypervisors: ~p ~p",
                [HypervisorID, Nets]),
    {ok, H} = sniffle_hypervisor:get(HypervisorID),
    case test_hypervisor(UUID, jsxd:get([<<"networks">>], [], H), Nets, []) of
        {ok, Nets1} ->
            {ok, Port} = jsxd:get(<<"port">>, H),
            {ok, Host} = jsxd:get(<<"host">>, H),
            HostS = binary_to_list(Host),
            case libchunter:lock(HostS, Port, UUID) of
                ok ->
                    {ok, HypervisorID, {HostS, Port}, Nets1};
                _ ->
                    test_hypervisors(UUID, R, Nets)
            end;
        _ ->
            test_hypervisors(UUID, R, Nets)
    end;

test_hypervisors(_, [], _) ->
    {error, no_hypervisors}.


test_hypervisor(UUID, H, [{NetName, Posibilities} | Nets], Acc) ->
    lager:debug("test_hypervisor: ~p ~p ~p",
                [H, [{NetName, Posibilities} | Nets], Acc]),
    case test_net(H, Posibilities) of
        false ->
            false;
        ID ->
            test_hypervisor(UUID, H, Nets, [{NetName, ID} | Acc])
    end;

test_hypervisor(_UUID, _, [], Acc) ->
    {ok, Acc}.


make_condition(C, Permissions) ->
    case jsxd:get(<<"weight">>, <<"must">>, C) of
        <<"must">> ->
            make_rule(must, C, Permissions);
        <<"cant">> ->
            make_rule(cant, C, Permissions);
        <<"scale">> ->
            make_scale(scale, C);
        <<"random">> ->
            make_random(random, C);
        I when is_integer(I) ->
            make_rule(I, C, Permissions)
    end.

make_rule(Weight, C, Permissions) ->
    Condition = case jsxd:get(<<"condition">>, C) of
                    {ok, <<">=">>} -> '>=';
                    {ok, <<">">>} -> '>';
                    {ok, <<"=<">>} -> '=<';
                    {ok, <<"<">>} -> '<';
                    {ok, <<"=:=">>} -> '=:=';
                    {ok, <<"=/=">>} -> '=/=';
                    {ok, <<"subset">>} -> 'subset';
                    {ok, <<"superset">>} -> 'superset';
                    {ok, <<"disjoint">>} -> 'disjoint';
                    {ok, <<"element">>} -> 'element';
                    {ok, <<"allowed">>} -> 'allowed'
                end,
    {ok, Attribute} = jsxd:get(<<"attribute">>, C),
    case Condition of
        'allowed' ->
            {Weight, Condition, Attribute, Permissions};
        _ ->
            {ok, Value} = jsxd:get(<<"value">>, C),
            {Weight, Condition, Attribute, Value}
    end.

make_scale(Weight, C) ->
    {ok, Attribute} = jsxd:get(<<"attribute">>, C),
    {ok, Low} = jsxd:get(<<"low">>, C),
    {ok, High} = jsxd:get(<<"high">>, C),
    {Weight, Attribute, Low, High}.

make_random(Weight, C) ->
    {ok, Low} = jsxd:get(<<"low">>, C),
    {ok, High} = jsxd:get(<<"high">>, C),
    {Weight, Low, High}.


update_nics(UUID, Nics, Config, Nets) ->
    jsxd:fold(
      fun (_, _, {error, E, Mps}) ->
              {error, E, Mps};
          (K, Nic, {NicsF, Mappings}) ->
              {ok, Name} = jsxd:get(<<"name">>, Nic),
              {ok, NicTag} = jsxd:get(Name, Nets),
              sniffle_vm:log(UUID, <<"Fetching network ", NicTag/binary, " for NIC ", Name/binary>>),
              case sniffle_iprange:claim_ip(NicTag) of
                  {ok, {Tag, IP, Net, Gw}} ->
                      {ok, Range} = sniffle_iprange:get(NicTag),
                      IPb = sniffle_iprange_state:to_bin(IP),
                      Netb = sniffle_iprange_state:to_bin(Net),
                      GWb = sniffle_iprange_state:to_bin(Gw),
                      sniffle_vm:log(UUID,
                                     <<"Assigning IP ", IPb/binary,
                                       " netmask ", Netb/binary,
                                       " gateway ", GWb/binary,
                                       " tag ", Tag/binary>>),
                      Res = jsxd:from_list([{<<"nic_tag">>, Tag},
                                            {<<"ip">>, IPb},
                                            {<<"netmask">>, Netb},
                                            {<<"gateway">>, GWb}]),
                      Res1 = case jsxd:get(<<"vlan">>, 0, Range) of
                                 0 ->
                                     eplugin:apply(
                                       'vm:ip_assigned',
                                       [UUID, Config, Name, Tag, IPb, Netb, GWb, none]),
                                     Res;
                                 VLAN ->
                                     eplugin:apply(
                                       'vm:ip_assigned',
                                       [UUID, Config, Name, Tag, IPb, Netb, GWb, VLAN]),
                                     jsxd:set(<<"vlan_id">>, VLAN, Res)
                             end,
                      NicsF1 = jsxd:set(K, Res1, NicsF),
                      Mappings1 = [{NicTag, IP} | Mappings],
                      {NicsF1, Mappings1};
                  E ->
                      {error, E, Mappings}
              end
      end, {[], []}, Nics).
