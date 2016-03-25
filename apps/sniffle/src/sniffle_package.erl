-module(sniffle_package).
-define(CMD, sniffle_package_cmd).
-include("sniffle.hrl").

-define(FM(Met, Mod, Fun, Args),
        folsom_metrics:histogram_timed_update(
          {sniffle, package, Met},
          Mod, Fun, Args)).

-export([
         create/1,
         delete/1,
         get/1,
         lookup/1,
         list/0, list/2, list/3,
         wipe/1,
         sync_repair/2,
         org_resource_inc/3, org_resource_dec/3, org_resource_remove/2,
         list_/0
        ]).

-ignore_xref([
              sync_repair/2,
              list_/0, get_/1,
              wipe/1
              ]).

-export([
         set_metadata/2,
         blocksize/2,
         compression/2,
         cpu_cap/2,
         cpu_shares/2,
         max_swap/2,
         name/2,
         quota/2,
         ram/2,
         uuid/2,
         zfs_io_priority/2,
         remove_requirement/2,
         add_requirement/2
        ]).

-spec wipe(fifo:package_id()) -> ok.
wipe(UUID) ->
    ?FM(wipe, sniffle_coverage, start, [?MASTER, ?MODULE, {wipe, UUID}]).

-spec sync_repair(fifo:package_id(), ft_obj:obj()) -> ok.
sync_repair(UUID, Obj) ->
    do_write(UUID, sync_repair, Obj).

-spec list_() -> {ok, [ft_obj:obj()]}.
list_() ->
    {ok, Res} = ?FM(list_all, sniffle_coverage, raw,
                    [?MASTER, ?MODULE, []]),
    Res1 = [R || {_, R} <- Res],
    {ok,  Res1}.

-spec lookup(Package::binary()) ->
                    not_found | {ok, Pkg::fifo:package()} | {error, timeout}.
lookup(Package) ->
    {ok, Res} = ?FM(list, sniffle_coverage, start,
                    [?MASTER, ?MODULE, {lookup, Package}]),
    lists:foldl(fun (not_found, Acc) ->
                        Acc;
                    (R, _) ->
                        {ok, R}
                end, not_found, Res).

-spec create(Package::binary()) ->
                    duplicate |
                    {error, timeout} |
                    {ok, UUID::fifo:package_id()}.
create(Package) ->
    UUID = fifo_utils:uuid(package),
    case sniffle_package:lookup(Package) of
        not_found ->
            ok = do_write(UUID, create, [Package]),
            {ok, UUID};
        {ok, _RangeObj} ->
            duplicate;
        E ->
            E
    end.

org_resource_inc(UUID, Resource, Val) ->
    do_write(UUID, org_resource_inc, [Resource, Val]).

org_resource_dec(UUID, Resource, Val) ->
    do_write(UUID, org_resource_dec, [Resource, Val]).

?SET(org_resource_remove).


-spec delete(Package::fifo:package_id()) ->
                    not_found | {error, timeout} | ok.
delete(Package) ->
    do_write(Package, delete).

-spec get(Package::fifo:package_id()) ->
                 not_found | {ok, Pkg::fifo:package()} | {error, timeout}.
get(Package) ->
    ?FM(get, sniffle_entity_read_fsm, start,
        [{?CMD, ?MODULE}, get, Package]).

-spec list() ->
                  {ok, [Pkg::fifo:package_id()]} | {error, timeout}.
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
                  {ok, [{integer(), fifo:package_id()}] |
                   [{integer(), fifo:package()}]}.

list(Requirements, Full) ->
    {ok, Res} = ?FM(list_all, sniffle_coverage, list,
                    [?MASTER, ?MODULE, Requirements]),
    Res1 = lists:sort(rankmatcher:apply_scales(Res)),
    Res2 = case Full of
               true ->
                   Res1;
               false ->
                   [{P, ft_package:uuid(O)} || {P, O} <- Res1]
           end,
    {ok, Res2}.

?SET(set_metadata).
?SET(blocksize).
?SET(compression).
?SET(cpu_cap).
?SET(cpu_shares).
?SET(max_swap).
?SET(name).
?SET(quota).
?SET(ram).
?SET(uuid).
?SET(zfs_io_priority).
?SET(remove_requirement).
?SET(add_requirement).

%%%===================================================================
%%% Internal Functions
%%%===================================================================

do_write(Package, Op) ->
    ?FM(Op, sniffle_entity_write_fsm, write,
        [{?CMD, ?MODULE}, Package, Op]).

do_write(Package, Op, Val) ->
    ?FM(Op, sniffle_entity_write_fsm, write,
        [{?CMD, ?MODULE}, Package, Op, Val]).
