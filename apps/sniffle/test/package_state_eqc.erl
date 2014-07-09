-module(package_state_eqc).

-ifdef(TEST).
-ifdef(EQC).

-import(sniffle_test_helper, [id/1, maybe_oneof/1]).

-include_lib("eqc/include/eqc_fsm.hrl").
-include_lib("fqc/include/fqc.hrl").

-compile(export_all).

-define(P, sniffle_package_state).
%% This is larger then and time we ever get in the size, used for ensure setting data
%% in LWW registers.
-define(BIG_TIME, 1000000000).

package() ->
    ?SIZED(Size, package(Size+1)).

non_neg_int() ->
    ?SUCHTHAT(I, int(), I > 0).

compression() ->
    oneof([<<"on">>, <<"off">>, <<"lzjb">>, <<"gzip">>, <<"zle">>, <<"lz4">>]).

package(Size) ->
    ?LAZY(oneof([{call, ?P, new, [id(Size)]} || Size == 1] ++
                    [?LETSHRINK(
                        [O], [package(Size - 1)],
                        oneof([
                               {call, ?P, load, [id(Size), O]},
                               %% {call, ?P, merge, [O, O]},

                               {call, ?P, uuid, [id(Size), non_blank_string(), O]},
                               {call, ?P, name, [id(Size), non_blank_string(), O]},
                               {call, ?P, blocksize, [id(Size), non_neg_int(), O]},
                               {call, ?P, compression, [id(Size), compression(), O]},
                               {call, ?P, cpu_cap, [id(Size), non_neg_int(), O]},
                               {call, ?P, cpu_shares, [id(Size), non_neg_int(), O]},
                               {call, ?P, max_swap, [id(Size), non_neg_int(), O]},
                               {call, ?P, quota, [id(Size), non_neg_int(), O]},
                               {call, ?P, ram, [id(Size), non_neg_int(), O]},
                               {call, ?P, zfs_io_priority, [id(Size), non_neg_int(), O]},

                               {call, ?P, set_metadata, [id(Size), non_blank_string(), non_blank_string(), O]},
                               {call, ?P, set_metadata, [id(Size), maybe_oneof(calc_map(set_metadata, O)), delete, O]}

                              ]))
                     || Size > 1])).

type() ->
    oneof([none, cluster, stack]).

calc_map(M, {call, _, M, [_, delete, K, U]}) ->
    lists:delete(K, lists:usort(calc_map(M, U)));
calc_map(M, {call, _, M, [_, I, _K, U]}) ->
    [I | calc_map(M, U)];
calc_map(M, {call, _, _, P}) ->
    calc_map(M, lists:last(P));
calc_map(_M, _) ->
    [].

r(K, V, U) ->
    lists:usort(lists:keystore(K, 1, U, {K, V})).

model_uuid(N, R) ->
    r(<<"uuid">>, N, R).

model_name(N, R) ->
    r(<<"name">>, N, R).

model_blocksize(N, R) ->
    r(<<"blocksize">>, N, R).

model_compression(N, R) ->
    r(<<"compression">>, N, R).

model_cpu_cap(N, R) ->
    r(<<"cpu_cap">>, N, R).

model_cpu_shares(N, R) ->
    r(<<"cpu_shares">>, N, R).

model_max_swap(N, R) ->
    r(<<"max_swap">>, N, R).

model_quota(N, R) ->
    r(<<"quota">>, N, R).

model_ram(N, R) ->
    r(<<"ram">>, N, R).

model_zfs_io_priority(N, R) ->
    r(<<"zfs_io_priority">>, N, R).

model_set_metadata(K, V, U) ->
    r(<<"metadata">>, lists:usort(r(K, V, metadata(U))), U).

model_delete_metadata(K, U) ->
    r(<<"metadata">>, lists:keydelete(K, 1, metadata(U)), U).

model(R) ->
    ?P:to_json(R).

metadata(U) ->
    {<<"metadata">>, M} = lists:keyfind(<<"metadata">>, 1, U),
    M.

prop_merge() ->
    ?FORALL(R,
            package(),
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R, Hv]),
                          model(?P:merge(Hv, Hv)) ==
                              model(Hv))
            end).

prop_load() ->
    ?FORALL(R,
            package(),
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R, Hv]),
                          model(?P:load(id(?BIG_TIME), Hv)) ==
                              model(Hv))
            end).

prop_uuid() ->
    ?FORALL({N, R},
            {non_blank_string(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R, Hv]),
                          model(?P:uuid(id(?BIG_TIME), N, Hv)) ==
                              model_uuid(N, model(Hv)))
            end).

prop_name() ->
    ?FORALL({N, R},
            {non_blank_string(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:name(id(?BIG_TIME), N, Hv)) ==
                              model_name(N, model(Hv)))
            end).

prop_blocksize() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                Exp = model_blocksize(N, model(Hv)),
                Act = model(?P:blocksize(id(?BIG_TIME), N, Hv)),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n"
                                   "Expected: ~p~nActual: ~p~n",
                                    [R,Hv, Exp, Act]),
                          Exp == Act)
            end).

prop_compression() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:compression(id(?BIG_TIME), N, Hv)) ==
                              model_compression(N, model(Hv)))
            end).

prop_cpu_cap() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:cpu_cap(id(?BIG_TIME), N, Hv)) ==
                              model_cpu_cap(N, model(Hv)))
            end).

prop_cpu_shares() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:cpu_shares(id(?BIG_TIME), N, Hv)) ==
                              model_cpu_shares(N, model(Hv)))
            end).

prop_max_swap() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:max_swap(id(?BIG_TIME), N, Hv)) ==
                              model_max_swap(N, model(Hv)))
            end).

prop_quota() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:quota(id(?BIG_TIME), N, Hv)) ==
                              model_quota(N, model(Hv)))
            end).

prop_ram() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:ram(id(?BIG_TIME), N, Hv)) ==
                              model_ram(N, model(Hv)))
            end).

prop_zfs_io_priority() ->
    ?FORALL({N, R},
            {non_neg_int(), package()},
            begin
                Hv = eval(R),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~n", [R,Hv]),
                          model(?P:zfs_io_priority(id(?BIG_TIME), N, Hv)) ==
                              model_zfs_io_priority(N, model(Hv)))
            end).

prop_set_metadata() ->
    ?FORALL({K, V, O}, {non_blank_string(), non_blank_string(), package()},
            begin
                Hv = eval(O),
                O1 = ?P:set_metadata(id(?BIG_TIME), K, V, Hv),
                M1 = model_set_metadata(K, V, model(Hv)),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~nModel: ~p~n"
                                    "Hv': ~p~nModel': ~p~n", [O, Hv, model(Hv), O1, M1]),
                          model(O1) == M1)
            end).

prop_remove_metadata() ->
    ?FORALL({O, K}, ?LET(O, package(), {O, maybe_oneof(calc_map(set_metadata, O))}),
            begin
                Hv = eval(O),
                O1 = ?P:set_metadata(id(?BIG_TIME), K, delete, Hv),
                M1 = model_delete_metadata(K, model(Hv)),
                ?WHENFAIL(io:format(user, "History: ~p~nHv: ~p~nModel: ~p~n"
                                    "Hv': ~p~nModel': ~p~n", [O, Hv, model(Hv), O1, M1]),
                          model(O1) == M1)
            end).

-endif.
-endif.
