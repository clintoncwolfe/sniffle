-module(sniffle_iprange_vnode).
-behaviour(riak_core_vnode).
-behaviour(riak_core_aae_vnode).
-include("sniffle.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([
         repair/4,
         get/3,
         create/4,
         delete/3,
         claim_ip/4,
         release_ip/4,
         set/4
        ]).

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3,
         handle_info/2,
         sync_repair/4]).

-export([
         master/0,
         aae_repair/2,
         hash_object/2
        ]).

-ignore_xref([
              release_ip/4,
              create/4,
              delete/3,
              get/3,
              set/4,
              claim_ip/4,
              repair/4,
              release_ip/4,
              start_vnode/1,
              handle_info/2,
              sync_repair/4
             ]).

-define(SERVICE, sniffle_iprange).

-define(MASTER, sniffle_iprange_vnode_master).

%%%===================================================================
%%% AAE
%%%===================================================================

master() ->
    ?MASTER.

hash_object(BKey, RObj) ->
    lager:debug("Hashing Key: ~p", [BKey]),
    list_to_binary(integer_to_list(erlang:phash2({BKey, RObj}))).

aae_repair(_, Key) ->
    lager:debug("AAE Repair: ~p", [Key]),
    sniffle_iprange:get(Key).

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

repair(IdxNode, Iprange, VClock, Obj) ->
    riak_core_vnode_master:command(IdxNode,
                                   {repair, Iprange, VClock, Obj},
                                   ignore,
                                   ?MASTER).

%%%===================================================================
%%% API - reads
%%%===================================================================

get(Preflist, ReqID, Iprange) ->
    riak_core_vnode_master:command(Preflist,
                                   {get, ReqID, Iprange},
                                   {fsm, undefined, self()},
                                   ?MASTER).

%%%===================================================================
%%% API - writes
%%%===================================================================

sync_repair(Preflist, ReqID, UUID, Obj) ->
    riak_core_vnode_master:command(Preflist,
                                   {sync_repair, ReqID, UUID, Obj},
                                   {fsm, undefined, self()},
                                   ?MASTER).

create(Preflist, ReqID, UUID, Data) ->
    riak_core_vnode_master:command(Preflist,
                                   {create, ReqID, UUID, Data},
                                   {fsm, undefined, self()},
                                   ?MASTER).

delete(Preflist, ReqID, Iprange) ->
    riak_core_vnode_master:command(Preflist,
                                   {delete, ReqID, Iprange},
                                   {fsm, undefined, self()},
                                   ?MASTER).

claim_ip(Preflist, ReqID, Iprange, Ip) ->
    riak_core_vnode_master:command(Preflist,
                                   {ip, claim, ReqID, Iprange, Ip},
                                   {fsm, undefined, self()},
                                   ?MASTER).

release_ip(Preflist, ReqID, Iprange, IP) ->
    riak_core_vnode_master:command(Preflist,
                                   {ip, release, ReqID, Iprange, IP},
                                   {fsm, undefined, self()},
                                   ?MASTER).

set(Preflist, ReqID, Hypervisor, Data) ->
    riak_core_vnode_master:command(Preflist,
                                   {set, ReqID, Hypervisor, Data},
                                   {fsm, undefined, self()},
                                   ?MASTER).

%%%===================================================================
%%% VNode
%%%===================================================================

init([Part]) ->
    sniffle_vnode:init(Part, <<"iprange">>, ?SERVICE, ?MODULE,
                       sniffle_iprange_state).

handle_command({create, {ReqID, Coordinator}, UUID,
                [Iprange, Network, Gateway, Netmask, First, Last, Tag, Vlan]},
               _Sender, State) ->
    I0 = statebox:new(fun sniffle_iprange_state:new/0),
    I1 = lists:foldl(
           fun (OP, SB) ->
                   statebox:modify(OP, SB)
           end, I0, [{fun sniffle_iprange_state:uuid/2, [UUID]},
                     {fun sniffle_iprange_state:name/2, [Iprange]},
                     {fun sniffle_iprange_state:network/2, [Network]},
                     {fun sniffle_iprange_state:gateway/2, [Gateway]},
                     {fun sniffle_iprange_state:netmask/2, [Netmask]},
                     {fun sniffle_iprange_state:first/2, [First]},
                     {fun sniffle_iprange_state:current/2, [First]},
                     {fun sniffle_iprange_state:last/2, [Last]},
                     {fun sniffle_iprange_state:tag/2, [Tag]},
                     {fun sniffle_iprange_state:vlan/2, [Vlan]}]),
    VC0 = vclock:fresh(),
    VC = vclock:increment(Coordinator, VC0),
    Obj = #sniffle_obj{val=I1, vclock=VC},
    sniffle_vnode:put(UUID, Obj, State),
    {reply, {ok, ReqID}, State};

handle_command({ip, claim,
                {ReqID, Coordinator}, Iprange, IP}, _Sender, State) ->
    case fifo_db:get(State#vstate.db, <<"iprange">>, Iprange) of
        {ok, #sniffle_obj{val=H0} = O} ->
            case sniffle_iprange_state:is_free(IP, statebox:value(H0)) of
                true ->
                    H1 = statebox:modify({fun sniffle_iprange_state:load/1,[]}, H0),
                    H2 = statebox:modify({fun sniffle_iprange_state:claim_ip/2,[IP]}, H1),
                    H3 = statebox:expire(?STATEBOX_EXPIRE, H2),
                    Obj =  sniffle_obj:update(H3, Coordinator, O),
                    sniffle_vnode:put(Iprange, Obj, State),
                    V1 = statebox:value(H3),
                    {reply, {ok, ReqID,
                             {jsxd:get(<<"tag">>, <<"">>, V1),
                              IP,
                              jsxd:get(<<"netmask">>, 0, V1),
                              jsxd:get(<<"gateway">>, 0, V1)}}, State};
                false ->
                    {reply, {error, ReqID, duplicate}, State}
            end;
        _ ->
            {reply, {ok, ReqID, not_found}, State}
    end;

handle_command({ip, release,
                {ReqID, Coordinator}, Iprange, IP}, _Sender, State) ->
    case fifo_db:get(State#vstate.db, <<"iprange">>, Iprange) of
        {ok, #sniffle_obj{val=H0} = O} ->

            H1 = statebox:modify({fun sniffle_iprange_state:load/1,[]}, H0),
            H2 = statebox:modify({fun sniffle_iprange_state:release_ip/2,[IP]}, H1),
            H3 = statebox:expire(?STATEBOX_EXPIRE, H2),
            Obj =  sniffle_obj:update(H3, Coordinator, O),
            sniffle_vnode:put(Iprange, Obj, State),
            {reply, {ok, ReqID}, State};

        _ ->
            {reply, {ok, ReqID, not_found}, State}
    end;

handle_command(Message, Sender, State) ->
    sniffle_vnode:handle_command(Message, Sender, State).

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, _Sender, State) ->
    Acc = fifo_db:fold(State#vstate.db, <<"iprange">>, Fun, Acc0),
    {reply, Acc, State};

handle_handoff_command({get, _ReqID, _Iprange} = Req, Sender, State) ->
    handle_command(Req, Sender, State);

handle_handoff_command(Req, Sender, State) ->
    S1 = case handle_command(Req, Sender, State) of
             {noreply, NewState} ->
                 NewState;
             {reply, _, NewState} ->
                 NewState
         end,
    {forward, S1}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, State) ->
    {Iprange, Obj} = binary_to_term(Data),
    sniffle_vnode:put(Iprange, Obj, State),
    {reply, ok, State}.

encode_handoff_item(Iprange, Data) ->
    term_to_binary({Iprange, Data}).

is_empty(State) ->
    sniffle_vnode:is_empty(State).

delete(State) ->
    sniffle_vnode:delete(State).

handle_coverage({overlap, ReqID, _Start, _Stop}, _KeySpaces, _Sender, State) ->
    {reply,
     {ok, ReqID, {State#vstate.partition, State#vstate.node}},
     State};

handle_coverage(Req, KeySpaces, Sender, State) ->
    sniffle_vnode:handle_coverage(Req, KeySpaces, Sender, State).


handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% AAE
%%%===================================================================

handle_info(Msg, State) ->
    sniffle_vnode:handle_info(Msg, State).
