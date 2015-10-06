%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2015, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created :  6 Oct 2015 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(mdns_server_fsm).

-behaviour(gen_fsm).

%% API
-export([start_link/1,
         start/0, stop/0, announce/0]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4,
         running/2, running/3,
         initialized/2, initialized/3]).

-define(SERVER, ?MODULE).

-record(state, {type,
                domain,
                port,
                address,
                ttl = 120,
                options = [],
                interface,
                service,
                socket,
                timer}).

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
start_link(Parameters) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, Parameters, []).

start() ->
    gen_fsm:send_event(?SERVER, start).

stop() ->
    gen_fsm:send_event(?SERVER, stop).

announce() ->
    gen_fsm:send_event(?SERVER, announce).

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
init(Parameters) ->
    process_flag(trap_exit, true),
    init(Parameters, #state{}).

init([{listener, {Address, Port}} | T], State) ->
    init(T, State#state{address = Address, port=Port});
init([{port, Port} | T], State) ->
    init(T, State#state{port = Port});
init([{address, Address} | T], State) ->
    init(T, State#state{address = Address});
init([{type, Type} | T], State) ->
    init(T, State#state{type = Type});
init([{domain, Domain} | T], State) ->
    init(T, State#state{domain = Domain});
init([{ttl, TTL} | T], State) ->
    init(T, State#state{ttl = TTL});
init([{options, Options} | T], State) ->
    init(T, State#state{options=Options});
init([{interface, Iface} | T], State) ->
    init(T, State#state{interface=Iface});
init([_ | T], State) ->
    init(T, State);
init([], #state{type = Type, domain = Domain} = State) ->
    {ok, initialized, State#state{service = Type ++ Domain}}.

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
initialized(connect, #state{port = Port, address = Address,
                           interface = IFace} = State) ->
    If = case IFace of
             undefined ->
                 multicast_if();
             _ ->
                 IFace
         end,
    {ok, Socket} = gen_udp:open(Port, [{reuseaddr, true},
                                       {multicast_if, If},
                                       {ip, Address},
                                       {multicast_loop, true},
                                       {add_membership, {Address, If}},
                                       binary]),
    {ok, T} = timer:apply_after(random_timeout(initial, State), ?MODULE, announce, []),
    {next_state, running, State#state{socket = Socket, timer = T}};

initialized(_, State) ->
    {next_state, initialized, State}.

running(stop, State = #state{socket = Socket}) ->
    announce(State#state{ttl = 0}),
    gen_udp:close(Socket),
    {next_State, initialized, State#state{socket = undefined}};

running(announce, State = #state{timer = T}) ->
    erlang:cancel_timer(T),
    announce(State),
    {ok, T} = timer:apply_after(random_timeout(initial, State), ?MODULE, announce, []),
    {next_state, running, State#state{timer = T}};
running({udp, _Sock, _IP, 5353, Data}, State) ->
    check_data(Data, State),
    {next_state, running, State};
running(_, State) ->
    {next_state, running, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/[2,3], the instance of this function with
%% the same name as the current state name StateName is called to
%% handle the event.
%%
%% @spec state_name(Event, From, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------

initialized(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, initialized, State}.

running(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, running, State}.

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
terminate(_Reason, _StateName, _State) ->
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

random_timeout(initial, _) ->
    crypto:rand_uniform(500, 1500);
random_timeout(announcements, #state{ttl = TTL}) ->
    crypto:rand_uniform(TTL * 100, TTL * 500).

multicast_if() ->
    {ok, Interfaces} = inet:getifaddrs(),
    multicast_if(Interfaces).

multicast_if([{_, H} | T]) ->
    case is_running_multicast_interface(proplists:get_value(flags, H)) andalso proplists:is_defined(addr, H) of
        true ->
            v4(proplists:get_all_values(addr, H));
        false ->
            multicast_if(T)
    end.

v4([{_, _, _, _} = V4 | _]) ->
    V4;
v4([_ | T]) ->
    v4(T).

is_running_multicast_interface(Flags) ->
    lists:member(up, Flags) andalso
        lists:member(broadcast, Flags) andalso
        lists:member(running, Flags) andalso
        lists:member(multicast, Flags).

announce(State) ->
    {ok, Hostname} = inet:gethostname(),
    announce(Hostname, State).

announce(Hostname, #state{address = Address, port = Port, socket = Socket} = State) ->
    Message = message(Hostname, State),
    gen_udp:send(Socket,
                 Address,
                 Port,
                 inet_dns:encode(Message)).

message(Hostname, State) ->
    inet_dns:make_msg([{header, header()},
                       {anlist, answers(Hostname, State) ++ as(Hostname, State)},
                       {arlist, resources(Hostname, State)}]).

header() ->
    inet_dns:make_header([{id,0},
                          {qr,true},
                          {opcode,'query'},
                          {aa,true},
                          {tc,false},
                          {rd,false},
                          {ra,false},
                          {pr,false},
                          {rcode,0}]).

answers(Hostname, #state{type = Type, domain = Domain, ttl = TTL} = State) ->
    [inet_dns:make_rr([{type, ptr},
                       {domain, Type ++ Domain},
                       {class, in},
                       {ttl, TTL},
                       {data, instance(Hostname, State)}
                      ])].

resources(Hostname, State) ->
    services(Hostname, State) ++ texts(Hostname, State).

services(Hostname, #state{domain = Domain, ttl = TTL, port=Port} = State) ->
    [inet_dns:make_rr([{domain, instance(Hostname, State)},
                       {type, srv},
                       {class, in},
                       {ttl, TTL},
                       {data, {0, 0, Port, Hostname ++ Domain}}])].

texts(Hostname, #state{ttl = TTL, options = Options} = State) ->
    [inet_dns:make_rr([{domain, instance(Hostname, State)},
                       {type, txt},
                       {class, in},
                       {ttl, TTL},
                       {data, texts_data(Options)}])].

as(Hostname, #state{ttl = TTL, interface = IP} = State) ->
    [inet_dns:make_rr([{domain, instance(Hostname, State)},
                       {type, a},
                       {class, in},
                       {ttl, TTL},
                       {data, IP}])].


texts_data([{Opt, Val} | Options]) ->
    [ ensure_list(Opt) ++ "=" ++ ensure_list(Val) | texts_data(Options)];
texts_data([]) ->
    [].

instance(Hostname, #state{service = Service}) ->
    Hostname ++ "." ++ Service.

ensure_list(I) when is_integer(I) ->
    integer_to_list(I);
ensure_list(B) when is_binary(B) ->
    binary_to_list(B);
ensure_list(A) when is_atom(A) ->
    atom_to_list(A);
ensure_list(L) when is_list(L)->
    L.

check_data(Data, State) ->
    case inet_dns:decode(Data) of
        {ok, Q} ->
            check_query(Q, State);
        _ ->
            ok
    end.

check_query({dns_rec,
             DnsHeader,
             [{dns_query, Service, _, _}],
             [],[],[]}, #state{service = Service}) ->
    case inet_dns:header(DnsHeader, opcode) of
        'query' ->
            self() ! announce;
        _ ->
            ok
    end;

check_query({dns_rec,
             DnsHeader,
             [{dns_query, "_services._dns-sd._udp." ++ Domain, ptr, in}],
             [],[],[]}, #state{domain = Domain}) ->
    case inet_dns:header(DnsHeader, opcode) of
        'query' ->
            self() ! announce;
        _ ->
            ok
    end;

check_query(_, _) ->
    ok.
