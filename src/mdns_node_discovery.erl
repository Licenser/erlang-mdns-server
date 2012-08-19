%% Copyright (c) 2012, Peter Morgan <peter.james.morgan@gmail.com>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(mdns_node_discovery).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
	 start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
         terminate/2,
	 code_change/3]).

-export([advertise/0,
	 stop/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    start_link([]).

start_link(Parameters) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Parameters, []).

advertise() ->
    gen_server:call(?SERVER, advertise).

stop() ->
    gen_server:call(?SERVER, stop).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-record(state, {type,
		domain,
		port,
		address,
		ttl = 120,
		options = [],
		socket}).

init(Parameters) ->
    process_flag(trap_exit, true),
    init(Parameters, #state{}).


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
init([_ | T], State) ->
    init(T, State);
init([], #state{port = Port, address = Address} = State) ->
    {ok, Socket} = gen_udp:open(Port, [{reuseaddr, true},
				       {multicast_if, multicast_if()},
				       {ip, Address}]),
    {ok, State#state{socket = Socket}, random_timeout(initial, State)}.

handle_call(advertise, _, State) ->
    {reply, announce(State), State, random_timeout(announcements, State)};

handle_call(stop, _, State) ->
    {stop, normal, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(timeout, State) ->
    announce(State),
    {noreply, State, random_timeout(announcements, State)};
handle_info({udp, _, _, _, _}, State) ->
    {noreply, State, random_timeout(announcements, State)}.

terminate(_, #state{socket = Socket} = State) ->
    announce(State#state{ttl = 0}),
    gen_udp:close(Socket).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

random_timeout(initial, _) ->
    crypto:rand_uniform(500, 1500);
random_timeout(announcements, #state{ttl = TTL}) ->
    crypto:rand_uniform(TTL * 500, TTL * 1000).

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
    io:format("send"),
    gen_udp:send(Socket,
		 Address,
		 Port,
		 inet_dns:encode(Message)).

message(Hostname, State) ->
    inet_dns:make_msg([{header, header()},
		       {anlist, answers(Hostname, State)},
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


texts_data([{Opt, Val} | Options]) ->
    [ ensure_list(Opt) ++ "=" ++ ensure_list(Val) | texts_data(Options)];
texts_data([]) ->
    [].
    
instance(Hostname, #state{type = Type, domain = Domain}) ->
    Hostname ++ "." ++ Type ++ Domain.

ensure_list(I) when is_integer(I) ->
    integer_to_list(I);
ensure_list(B) when is_binary(B) ->
    binary_to_list(B);
ensure_list(A) when is_atom(A) ->
    atom_to_list(A);
ensure_list(L) when is_list(L)->
    L.





		       
