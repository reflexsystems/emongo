%% Copyright (c) 2009 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(emongo).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, 
		 handle_info/2, terminate/2, code_change/3]).

-export([pools/0, oid/0, add_pool/5, find/2, find/3, find/4,
		 find_all/2, find_all/3, find_all/4, get_more/4,
		 get_more/5, find_one/3, find_one/4, kill_cursors/2,
		 insert/3, update/4, update/5, delete/2, delete/3,
		 count/2, dec2hex/1, hex2dec/1]).

-include("emongo.hrl").

-record(state, {pools, oid_index, hashed_hostn}).

%%====================================================================
%% Types
%%====================================================================
%% pool_id() = atom()
%% collection() = string()
%% response() = {response, header, response_flag, cursor_id, offset, limit, documents}
%% documents() = [document()]
%% document() = [{term(), term()}]

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
		
pools() ->
	gen_server:call(?MODULE, pools, infinity).
	
oid() ->
	gen_server:call(?MODULE, oid, infinity).
	
add_pool(PoolId, Host, Port, Database, Size) ->
	gen_server:call(?MODULE, {add_pool, PoolId, Host, Port, Database, Size}, infinity).

%%------------------------------------------------------------------------------
%% find
%%------------------------------------------------------------------------------
find(PoolId, Collection) ->
	find(PoolId, Collection, [], [{timeout, ?TIMEOUT}]).

find(PoolId, Collection, Selector) when ?IS_DOCUMENT(Selector) ->
	find(PoolId, Collection, Selector, [{timeout, ?TIMEOUT}]);
	
find(PoolId, Collection, Query) when is_record(Query, emo_query) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Packet = emongo_packet:do_query(Pool#pool.database, Collection, Pool#pool.req_id, Query),
	emongo_conn:send_recv(Pid, Pool#pool.req_id, Packet, ?TIMEOUT).
	
%% @spec find(PoolId, Collection, Selector, Options) -> Result
%%		 PoolId = atom()
%%		 Collection = string()
%%		 Selector = document()
%%		 Options = [Option]
%%		 Option = {timeout, Timeout} | {limit, Limit} | {offset, Offset} | {orderby, Orderby} | {fields, Fields} | response_options
%%		 Timeout = integer (timeout in milliseconds)
%%		 Limit = integer
%%		 Offset = integer
%%		 Orderby = [{Key, Direction}]
%%		 Key = string() | binary() | atom() | integer()
%%		 Direction = 1 (Asc) | -1 (Desc)
%%		 Fields = [Field]
%%		 Field = string() | binary() | atom() | integer() = specifies a field to return in the result set
%%		 response_options = return {response, header, response_flag, cursor_id, offset, limit, documents}
%%		 Result = documents() | response()
find(PoolId, Collection, Selector, Options) when ?IS_DOCUMENT(Selector) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Query = create_query(Options, #emo_query{q=Selector}),
	Packet = emongo_packet:do_query(Pool#pool.database, Collection, Pool#pool.req_id, Query),
	Resp = emongo_conn:send_recv(Pid, Pool#pool.req_id, Packet, proplists:get_value(timeout, Options, ?TIMEOUT)),
	case lists:member(response_options, Options) of
		true -> Resp;
		false -> Resp#response.documents
	end.

create_query([], Query) ->
	Query;
	
create_query([{limit, Limit}|Options], Query) ->
	Query1 = Query#emo_query{limit=Limit},
	create_query(Options, Query1);
	
create_query([{offset, Offset}|Options], Query) ->
	Query1 = Query#emo_query{offset=Offset},
	create_query(Options, Query1);

create_query([{orderby, Orderby}|Options], Query) ->
	Selector = Query#emo_query.q,
	Query1 = Query#emo_query{q=[{<<"orderby">>, Orderby}|Selector]},
	create_query(Options, Query1);
	
create_query([{fields, Fields}|Options], Query) ->
	Query1 = Query#emo_query{field_selector=[{Field, 1} || Field <- Fields]},
	create_query(Options, Query1);
	
create_query([_|Options], Query) ->
	create_query(Options, Query).
	
%%------------------------------------------------------------------------------
%% find_all
%%------------------------------------------------------------------------------
find_all(PoolId, Collection) ->
	find_all(PoolId, Collection, [], ?TIMEOUT).

find_all(PoolId, Collection, Document) ->
	find_all(PoolId, Collection, Document, ?TIMEOUT).

find_all(PoolId, Collection, Document, Timeout) when ?IS_DOCUMENT(Document) ->
	find_all(PoolId, Collection, #emo_query{q=Document}, Timeout);

find_all(PoolId, Collection, Query, Timeout) when is_record(Query, emo_query) ->
	Resp = find(PoolId, Collection, Query, Timeout),
	find_all(PoolId, Collection, Resp, Timeout);
	
find_all(_PoolId, _Collection, Resp, _Timeout) when is_record(Resp, response), Resp#response.cursor_id == 0 ->
	Resp;
	
find_all(PoolId, Collection, Resp, Timeout) when is_record(Resp, response) ->
	Resp1 = get_more(PoolId, Collection, Resp#response.cursor_id, Timeout),
	Documents = lists:append(Resp#response.documents, Resp1#response.documents),
	find_all(PoolId, Collection, Resp1#response{documents=Documents}, Timeout).

%%------------------------------------------------------------------------------
%% find_one
%%------------------------------------------------------------------------------
find_one(PoolId, Collection, Document) when ?IS_DOCUMENT(Document) ->
	find_one(PoolId, Collection, Document, ?TIMEOUT).

find_one(PoolId, Collection, Document, Timeout) when ?IS_DOCUMENT(Document) ->
	find(PoolId, Collection, #emo_query{q=Document, limit=1}, Timeout);

find_one(PoolId, Collection, {oid, OID}, Timeout) when is_binary(OID) ->
	find(PoolId, Collection, #emo_query{q=[{"_id", {oid, OID}}], limit=1}, Timeout).

%%------------------------------------------------------------------------------
%% get_more
%%------------------------------------------------------------------------------
get_more(PoolId, Collection, CursorID, Timeout) ->
	get_more(PoolId, Collection, CursorID, 0, Timeout).
	
get_more(PoolId, Collection, CursorID, NumToReturn, Timeout) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Packet = emongo_packet:get_more(Pool#pool.database, Collection, Pool#pool.req_id, NumToReturn, CursorID),
	emongo_conn:send_recv(Pid, Pool#pool.req_id, Packet, Timeout).
	
kill_cursors(PoolId, CursorID) when is_integer(CursorID) ->
	kill_cursors(PoolId, [CursorID]);
	
kill_cursors(PoolId, CursorIDs) when is_list(CursorIDs) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Packet = emongo_packet:kill_cursors(Pool#pool.req_id, CursorIDs),
	emongo_conn:send(Pid, Pool#pool.req_id, Packet).
	
%%------------------------------------------------------------------------------
%% insert
%%------------------------------------------------------------------------------
insert(PoolId, Collection, Document) when ?IS_DOCUMENT(Document) ->
	insert(PoolId, Collection, [Document]);
	
insert(PoolId, Collection, Documents) when ?IS_LIST_OF_DOCUMENTS(Documents) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Packet = emongo_packet:insert(Pool#pool.database, Collection, Pool#pool.req_id, Documents),
	emongo_conn:send(Pid, Pool#pool.req_id, Packet).

%%------------------------------------------------------------------------------
%% update
%%------------------------------------------------------------------------------
update(PoolId, Collection, Selector, Document) when ?IS_DOCUMENT(Selector), ?IS_DOCUMENT(Document) ->
	update(PoolId, Collection, Selector, Document, false).
	
update(PoolId, Collection, Selector, Document, Upsert) when ?IS_DOCUMENT(Selector), ?IS_DOCUMENT(Document) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Packet = emongo_packet:update(Pool#pool.database, Collection, Pool#pool.req_id, Upsert, Selector, Document),
	emongo_conn:send(Pid, Pool#pool.req_id, Packet).

%%------------------------------------------------------------------------------
%% delete
%%------------------------------------------------------------------------------
delete(PoolId, Collection) ->
	delete(PoolId, Collection, []).
	
delete(PoolId, Collection, Selector) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Packet = emongo_packet:delete(Pool#pool.database, Collection, Pool#pool.req_id, Selector),
	emongo_conn:send(Pid, Pool#pool.req_id, Packet).

%%ensure_index

count(PoolId, Collection) ->
	{Pid, Pool} = gen_server:call(?MODULE, {pid, PoolId}, infinity),
	Query = #emo_query{q=[{<<"count">>, Collection}, {<<"ns">>, Pool#pool.database}], limit=1},
	Packet = emongo_packet:do_query(Pool#pool.database, "$cmd", Pool#pool.req_id, Query),
	case emongo_conn:send_recv(Pid, Pool#pool.req_id, Packet, ?TIMEOUT) of
		#response{documents=[[{<<"n">>,Count}|_]]} ->
			round(Count);
		_ ->
			undefined
	end.

%drop_collection(PoolId, Collection) when is_atom(PoolId), is_list(Collection) ->

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init(_) ->
	process_flag(trap_exit, true),
	Pools = initialize_pools(),
	{ok, HN} = inet:gethostname(),
	<<HashedHN:3/binary,_/binary>> = erlang:md5(HN),
	{ok, #state{pools=Pools, oid_index=1, hashed_hostn=HashedHN}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(pools, _From, State) ->
	{reply, State#state.pools, State};
	
handle_call(oid, _From, State) ->
	{Total_Wallclock_Time, _} = erlang:statistics(wall_clock),
	Front = Total_Wallclock_Time rem 16#ffffffff,
	<<_:20/binary,PID:2/binary,_/binary>> = term_to_binary(self()),
	Index = State#state.oid_index rem 16#ffffff,
	{reply, <<Front:32, (State#state.hashed_hostn)/binary, PID/binary, Index:24>>, State#state{oid_index = State#state.oid_index + 1}};
	
handle_call({add_pool, PoolId, Host, Port, Database, Size}, _From, #state{pools=Pools}=State) ->
	{Result, Pools1} = 
		case proplists:is_defined(PoolId, Pools) of
			true ->
				{{error, pool_already_exists}, Pools};
			false ->
				Pool = #pool{
					id=PoolId,
					host=Host,
					port=Port,
					database=Database,
					size=Size
				},
				Pool1 = do_open_connections(Pool),
				{ok, [{PoolId, Pool1}|Pools]}
		end,
	{reply, Result, State#state{pools=Pools1}};
	
handle_call({pid, PoolId}, _From, #state{pools=Pools}=State) ->
	case get_pool(PoolId, Pools) of
		undefined ->
			{reply, {undefined, undefined}, State};
		{Pool, Others} ->			
			case queue:out(Pool#pool.conn_pids) of
				{{value, Pid}, Q2} ->
					Pool1 = Pool#pool{conn_pids = queue:in(Pid, Q2), req_id = ((Pool#pool.req_id)+1)},
					Pools1 = [{PoolId, Pool1}|Others],
					{reply, {Pid, Pool}, State#state{pools=Pools1}};
				{empty, _} ->
					{reply, {undefined, Pool}, State}
			end
	end;
	
handle_call(_, _From, State) -> {reply, {error, invalid_call}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, {PoolId, tcp_closed}}, #state{pools=Pools}=State) ->
	io:format("EXIT ~p, {~p, tcp_closed}~n", [Pid, PoolId]),
	State1 =
		case get_pool(PoolId, Pools) of
			undefined ->
				State;
			{Pool, Others} ->
				Pids1 = queue:filter(fun(Item) -> Item =/= Pid end, Pool#pool.conn_pids),
				Pool1 = Pool#pool{conn_pids = Pids1},
				Pool2 = do_open_connections(Pool1),
				Pools1 = [{PoolId, Pool2}|Others],
				State#state{pools=Pools1}
		end,
	{noreply, State1};
	
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
initialize_pools() ->
	case application:get_env(emongo, pools) of
		undefined ->
			[];
		{ok, Pools} ->
			[begin
				Pool = #pool{
					id = PoolId, 
					size = proplists:get_value(size, Props, 1),
					host = proplists:get_value(host, Props, "localhost"), 
					port = proplists:get_value(port, Props, 27017), 
					database = proplists:get_value(database, Props, "test")
				},
				{PoolId, do_open_connections(Pool)}
			 end || {PoolId, Props} <- Pools]
	end.
		
do_open_connections(#pool{conn_pids=Pids, size=Size}=Pool) -> 
	case queue:len(Pids) < Size of
		true ->
			Pid = emongo_conn:start_link(Pool#pool.id, Pool#pool.host, Pool#pool.port),
			do_open_connections(Pool#pool{conn_pids = queue:in(Pid, Pids)});
		false ->
			Pool
	end.

get_pool(PoolId, Pools) ->
	get_pool(PoolId, Pools, []).
	
get_pool(_, [], _) ->
	undefined;
		
get_pool(PoolId, [{PoolId, Pool}|Tail], Others) ->
	{Pool, lists:append(Tail, Others)};
	
get_pool(PoolId, [Pool|Tail], Others) ->
	get_pool(PoolId, Tail, [Pool|Others]).
	
dec2hex(Dec) ->
	dec2hex(<<>>, Dec).
	
dec2hex(N, <<I:8,Rem/binary>>) ->
	dec2hex(<<N/binary, (hex0((I band 16#f0) bsr 4)):8, (hex0((I band 16#0f))):8>>, Rem);
dec2hex(N,<<>>) ->
	N.

hex2dec(Hex) when is_list(Hex) ->
	hex2dec(list_to_binary(Hex));
	
hex2dec(Hex) ->
	hex2dec(<<>>, Hex).
	
hex2dec(N,<<A:8,B:8,Rem/binary>>) ->
	hex2dec(<<N/binary, ((dec0(A) bsl 4) + dec0(B)):8>>, Rem);
hex2dec(N,<<>>) ->
	N.

dec0($a) ->	10;
dec0($b) ->	11;
dec0($c) ->	12;
dec0($d) ->	13;
dec0($e) ->	14;
dec0($f) ->	15;
dec0(X) ->	X - $0.

hex0(10) -> $a;
hex0(11) -> $b;
hex0(12) -> $c;
hex0(13) -> $d;
hex0(14) -> $e;
hex0(15) -> $f;
hex0(I) ->  $0 + I.
	