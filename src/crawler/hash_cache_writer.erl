%%
%% hash_cache_writer.erl
%% Kevin Lynx
%% 07.17.2013
%% cache received hashes and pre-process theses hashes before inserted into database
%%
-module(hash_cache_writer).
-include("db_common.hrl").
-include("vlog.hrl").
-behaviour(gen_server).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([start_link/5, stop/0, insert/1]).
-record(state, {cache_time, cache_max}).
-define(TBLNAME, hash_table).
-define(DBPOOL, hash_write_db).

start_link(IP, Port, DBConn, MaxTime, MaxCnt) ->
	gen_server:start_link({local, srv_name()}, ?MODULE, [IP, Port, DBConn, MaxTime, MaxCnt], []).

stop() ->
	gen_server:cast(srv_name(), stop).

insert(Hash) when is_list(Hash) ->
	gen_server:cast(srv_name(), {insert, Hash}).

srv_name() ->
	?MODULE.

init([IP, Port, DBConn, MaxTime, Max]) ->
	mongo_sup:start_pool(?DBPOOL, DBConn, {IP, Port}),
	ets:new(?TBLNAME, [set, named_table]),
	{ok, #state{cache_time = 1000 * MaxTime, cache_max = Max}, 0}.

terminate(_, State) ->
	mongo_sup:stop_pool(?DBPOOL),
    {ok, State}.

code_change(_, _, State) ->
    {ok, State}.

handle_cast({insert, Hash}, State) ->
	do_insert(Hash),
	try_save(State),
	{noreply, State};

handle_cast(stop, State) ->
	{stop, normal, State}.

handle_call(_, _From, State) ->
	{noreply, State}.

handle_info(do_save_cache, #state{cache_time = Time} = State) ->
	?T("timeout to save cache hashes"),
	do_save(table_size(?TBLNAME)),
	schedule_save(Time),
	{noreply, State};

handle_info(timeout, #state{cache_time = Time} = State) ->
	schedule_save(Time),
	{noreply, State}.

schedule_save(Time) ->
	timer:send_after(Time, do_save_cache).

%%
do_insert(Hash) when is_list(Hash) ->
	NewVal = 1 + get_req_cnt(Hash),
	ets:insert(?TBLNAME, {Hash, NewVal}).

table_size(Tbl) ->
	Infos = ets:info(Tbl),
	proplists:get_value(size, Infos).

try_save(#state{cache_max = Max}) ->
	TSize = table_size(?TBLNAME),
	try_save(TSize, Max).

try_save(Size, Max) when Size >= Max ->
	?T(?FMT("try save all cache hashes ~p", [Size])),
	do_save(Size);
try_save(_, _) ->
	ok.

do_save(0) ->
	ok;
do_save(_) ->
	Conn = mongo_pool:get(?DBPOOL),
	First = ets:first(?TBLNAME),
	ReqAt = time_util:now_seconds(),
	{ReqSum, Docs} = to_docs(First, ReqAt),
	ets:delete_all_objects(?TBLNAME),
	do_save(Conn, Docs, ReqSum).

to_docs('$end_of_table', _) ->
	{0, []};
to_docs(Key, ReqAt) ->
	ReqCnt = get_req_cnt(Key),
	Doc = {hash, list_to_binary(Key), req_at, ReqAt, req_cnt, ReqCnt},
	Next = ets:next(?TBLNAME, Key),
	{ReqSum, Docs} = to_docs(Next, ReqAt),
	{ReqSum + ReqCnt, [Doc|Docs]}.

do_save(Conn, Docs, ReqSum) ->
	?T(?FMT("send ~p hashes req-count ~p to db", [length(Docs), ReqSum])),
	% `safe' may cause this process message queue increasing, but `unsafe' may cause the 
	% database crashes.
	mongo:do(safe, master, Conn, ?HASH_DBNAME, fun() ->
		mongo:insert(?HASH_COLLNAME, Docs)
	end),
	db_system:stats_cache_query_inserted(Conn, length(Docs)),
	db_system:stats_query_inserted(Conn, ReqSum).

get_req_cnt(Hash) ->
	case ets:lookup(?TBLNAME, Hash) of
		[{Hash, ReqCnt}] -> ReqCnt;
		[] -> 0
	end.
