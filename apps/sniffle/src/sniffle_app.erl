-module(sniffle_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    case sniffle_sup:start_link() of
        {ok, Pid} ->
            ok = riak_core:register([{vnode_module, sniffle_vnode}]),
            ok = riak_core:register([{vnode_module, sniffle_hypervisor_vnode}]),

            ok = riak_core_ring_events:add_guarded_handler(sniffle_ring_event_handler, []),
            ok = riak_core_node_watcher_events:add_guarded_handler(sniffle_node_event_handler, []),

            ok = riak_core_node_watcher:service_up(sniffle, self()),
            ok = riak_core_node_watcher:service_up(sniffle_hypervisor, self()),

            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

stop(_State) ->
    ok.
