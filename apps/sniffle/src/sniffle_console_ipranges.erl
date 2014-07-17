%% @doc Interface for sniffle-admin commands.
-module(sniffle_console_ipranges).
-export([command/2, help/0]).

-define(F(Hs, Vs), sniffle_console:fields(Hs,Vs)).
-define(H(Hs), sniffle_console:hdr(Hs)).
-define(Hdr, [{"UUID", 18}, {"Name", 10}, {"Tag", 8}, {"First", 15},
              {"Next", 15}, {"Last", 15}, {"Netmask", 15}, {"Gatewau", 15},
              {"Vlan", 4}]).

help() ->
    io:format("Usage~n"
              "  list~n"
              "  get <uuid>~n"
              "  claim <uuid>~n"
              "  release <uuid> <ip>~n"
              "  delete <uuid>~n").

command(text, ["delete", UUID]) ->
    case sniffle_iprange:delete(list_to_binary(UUID)) of
        ok ->
            io:format("Network ~s removed.~n", [UUID]),
            ok;
        E ->
            io:format("Network ~s not removed (~p).~n", [UUID, E]),
            ok
    end;

command(text, ["get", ID]) ->
    ?H(?Hdr),
    case sniffle_iprange:get(list_to_binary(ID)) of
        {ok, N} ->
            print(N),
            ok;
        _ ->
            error
    end;

command(text, ["list"]) ->
    ?H(?Hdr),
    case sniffle_iprange:list() of
        {ok, Hs} ->
            lists:map(fun (ID) ->
                              {ok, N} = sniffle_iprange:get(ID),
                              print(N)
                      end, Hs);
        _ ->
            []
    end;

command(text, ["claim", ID]) ->
    case get_ip(ID) of
        {ok, {Tag, IP, Netmask, Gateway}} ->
            io:format("A IP address has been claimed from the netowkr ~s.~n"
                      "Tag:     ~s~n"
                      "IP:      ~s~n"
                      "Netmask: ~s~n"
                      "Gateway: ~s~n",
                      [ID, Tag, IP, Netmask, Gateway]),
            ok;
        _ ->
            io:format("Could not get IP address.~n"),
            error
    end;

command(json, ["claim", ID]) ->
    case get_ip(ID) of
        {ok, {Tag, IP, Netmask, Gateway}} ->
            sniffle_console:pp_json(
              [{<<"tag">>, Tag},
               {<<"ip">>, IP},
               {<<"netmask">>, Netmask},
               {<<"gateway">>, Gateway}]),
            ok;
        _ ->
            error
    end;

command(text, ["release", ID, IPS]) ->
    IP = ft_iprange:parse_bin(IPS),
    case sniffle_iprange:release_ip(list_to_binary(ID), IP) of
        ok ->
            io:format("Released ip.~n"),
            ok;
        _ ->
            io:format("Release failed ip.~n"),
            error
    end;

command(_, C) ->
    io:format("Unknown parameters: ~p~n", [C]),
    error.

get_ip(ID) ->
    case sniffle_iprange:claim_ip(list_to_binary(ID)) of
        {ok, {Tag, IP, Netmask, Gateway}} ->
            {ok, {Tag,
                  ft_iprange:to_bin(IP),
                  ft_iprange:to_bin(Netmask),
                  ft_iprange:to_bin(Gateway)}};
        _ ->
            error
    end.

print(N) ->
    ?F(?Hdr, [jsxd:get(<<"uuid">>, <<"-">>, N),
              jsxd:get(<<"name">>, <<"-">>, N),
              jsxd:get(<<"tag">>, <<"-">>, N),
              ft_iprange:to_bin(jsxd:get(<<"first">>, 0, N)),
              ft_iprange:to_bin(jsxd:get(<<"current">>, 0, N)),
              ft_iprange:to_bin(jsxd:get(<<"last">>, 0, N)),
              ft_iprange:to_bin(jsxd:get(<<"netmask">>, 0, N)),
              ft_iprange:to_bin(jsxd:get(<<"gateway">>, 0, N)),
              jsxd:get(<<"vlan">>, 0, N)]).
