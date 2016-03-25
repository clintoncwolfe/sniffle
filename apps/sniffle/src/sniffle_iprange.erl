-module(sniffle_iprange).
-define(CMD, sniffle_iprange_cmd).
-include("sniffle.hrl").

-define(FM(Met, Mod, Fun, Args),
        folsom_metrics:histogram_timed_update(
          {sniffle, iprange, Met},
          Mod, Fun, Args)).

-export([
         create/8,
         delete/1,
         get/1,
         lookup/1,
         list/0,
         list/2,
         list/3,
         claim_ip/1,
         claim_specific_ip/2,
         full/1,
         release_ip/2,
         wipe/1,
         sync_repair/2,
         list_/0
        ]).

-ignore_xref([
              sync_repair/2,
              list_/0,
              wipe/1
              ]).

-export([
         name/2,
         uuid/2,
         network/2,
         netmask/2,
         gateway/2,
         set_metadata/2,
         tag/2,
         vlan/2
        ]).


-define(MAX_TRIES, 3).

-spec wipe(fifo:iprange_id()) -> ok.

wipe(UUID) ->
    ?FM(wipe, sniffle_coverage, start, [?MASTER, ?MODULE, {wipe, UUID}]).

-spec sync_repair(fifo:iprange_id(), ft_obj:obj()) -> ok.

sync_repair(UUID, Obj) ->
    do_write(UUID, sync_repair, Obj).

-spec list_() -> {ok, [ft_obj:obj()]}.

list_() ->
    {ok, Res} = ?FM(list_all, sniffle_coverage, raw,
                    [?MASTER, ?MODULE, []]),
    Res1 = [R || {_, R} <- Res],
    {ok,  Res1}.

-spec lookup(IPRange::binary()) ->
                    not_found | {ok, IPR::fifo:iprange()} | {error, timeout}.
lookup(Name) when
      is_binary(Name) ->
    {ok, Res} = ?FM(lookup, sniffle_coverage, start,
                    [?MASTER, ?MODULE, {lookup, Name}]),
    lists:foldl(fun (not_found, Acc) ->
                        Acc;
                    (R, _) ->
                        {ok, R}
                end, not_found, Res).

-spec create(Iprange::binary(),
             Network::integer(),
             Gateway::integer(),
             Netmask::integer(),
             First::integer(),
             Last::integer(),
             Tag::binary(),
             Vlan::integer()) ->
                    duplicate |
                    {error, timeout} |
                    {ok, UUID::fifo:iprange_id()}.
create(Iprange, Network, Gateway, Netmask, First, Last, Tag, Vlan) when
      is_binary(Iprange) ->
    UUID = fifo_utils:uuid(iprange),
    case sniffle_iprange:lookup(Iprange) of
        not_found ->
            ok = do_write(UUID, create, [Iprange, Network, Gateway, Netmask,
                                         First, Last, Tag, Vlan]),
            {ok, UUID};
        {ok, _RangeObj} ->
            duplicate
    end.

-spec delete(Iprange::fifo:iprange_id()) ->
                    not_found | {error, timeout} | ok.
delete(Iprange) ->
    do_write(Iprange, delete).

-spec get(Iprange::fifo:iprange_id()) ->
                 not_found | {ok, IPR::fifo:iprange()} | {error, timeout}.
get(Iprange) ->
    ?FM(get, sniffle_entity_read_fsm, start,
        [{?CMD, ?MODULE}, get, Iprange]).

-spec list() ->
                  {ok, [IPR::fifo:iprange_id()]} | {error, timeout}.
list() ->
    ?FM(list, sniffle_coverage, start, [?MASTER, ?MODULE, list]).

list(Requirements, FoldFn, Acc0) ->
    ?FM(list_all, sniffle_coverage, list,
        [?MASTER, ?MODULE, Requirements, FoldFn, Acc0]).

%%--------------------------------------------------------------------
%% @doc Lists all vm's and fiters by a given matcher set.
%% @end
%%--------------------------------------------------------------------
-spec list([fifo:matcher()], boolean()) ->
                  {error, timeout} |
                  {ok, [{Rating::integer(), Value::fifo:iprange()}] |
                   [{Rating::integer(), Value::fifo:iprange_id()}]}.

list(Requirements, Full) ->
    {ok, Res} = ?FM(list_all, sniffle_coverage, list,
                    [?MASTER, ?MODULE, Requirements]),
    Res1 = lists:sort(rankmatcher:apply_scales(Res)),
    Res2 = case Full of
               true ->
                   Res1;
               false ->
                   [{P, ft_iprange:uuid(O)} || {P, O} <- Res1]
           end,
    {ok, Res2}.

-spec release_ip(Iprange::fifo:iprange_id(),
                 IP::integer()) ->
                        ok | {error, timeout}.
release_ip(Iprange, IP) ->
    do_write(Iprange, release_ip, IP).

-spec claim_ip(Iprange::fifo:iprange_id()) ->
                      not_found |
                      {ok, {Tag::binary(),
                            IP::non_neg_integer(),
                            Netmask::non_neg_integer(),
                            Gateway::non_neg_integer(),
                            VLAN::non_neg_integer()}} |
                      {error, failed} |
                      {'error', 'no_servers'}.
claim_ip(Iprange) ->
    claim_ip(Iprange, 0).

claim_specific_ip(Iprange, IP) ->
    do_write(Iprange, claim_ip, IP).

?SET(name).
?SET(uuid).
?SET(network).
?SET(netmask).
?SET(gateway).
?SET(set_metadata).
?SET(tag).
?SET(vlan).

%%%===================================================================
%%% Internal Functions
%%%===================================================================

do_write(Iprange, Op) ->
    ?FM(Op, sniffle_entity_write_fsm, write, [{?CMD, ?MODULE}, Iprange, Op]).

do_write(Iprange, Op, Val) ->
    ?FM(Op, sniffle_entity_write_fsm, write,
        [{?CMD, ?MODULE}, Iprange, Op, Val]).

claim_ip(_Iprange, ?MAX_TRIES) ->
    {error, failed};

claim_ip(Iprange, N) ->
    case sniffle_iprange:get(Iprange) of
        {error, timeout} ->
            timer:sleep(N*50),
            claim_ip(Iprange, N + 1);
        not_found ->
            not_found;
        {ok, Obj} ->
            sniffle_ip:claim(Obj)
    end.

full(Iprange) ->
    case sniffle_iprange:get(Iprange) of
        {ok, Obj} ->
            ft_iprange:free(Obj) == [];
        E ->
            E
    end.
