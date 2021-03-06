-module(tcp_connector).
-author('kajetan.rzepecki@zadane.pl').
-behaviour(gen_server).
-behaviour(hive_connector).
-behaviour(hive_plugin).

-export([load/0, unload/1, validate/2]).
-export([common_init/2, start_pool/2, checkout/2, transaction/2, checkin/2, stop_pool/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
-export([remove/2, add/2]).

-include("hive_connectors.hrl").

-record(tcp_state, {
          listener,
          pool_name,
          froms,
          froms_len,
          froms_limit,
          workers,
          workers2kill
         }).

-include("hive_monitor.hrl").
-define(TCP_CONN_COUNTERS, [?CONN_TCP_CONNECTORS, ?CONN_TCP_REQUESTS, ?CONN_TCP_ERRORS, ?CONN_TCP_SEND,
                            ?CONN_TCP_RECV]).

-import(hive_monitor_utils, [inc/2, init_counters/1, name/2]).
-define(inc(Counter), inc(Counter, State#tcp_state.pool_name)).
-define(dec(Counter), dec(Counter, State#tcp_state.pool_name)).

%% External Functions
load() ->
    {ok, [{<<"connector.tcp">>, ?MODULE}], undefined}.

unload(_State) ->
    ok.

validate(<<"connector.tcp">>, Descriptor) ->
    %% NOTE Built-in schema validation facility is currently unsupported in plugins.
    Schema = <<"{
    \"type\" : \"object\",
    \"properties\" : {
        \"port\" : {
            \"type\" : \"integer\",
            \"minimum\" : 0,
            \"maximum\" : 65535,
            \"required\" : true
        },
        \"restart_timeout\" : {
            \"type\" : \"integer\",
            \"minimum\" : 0,
            \"required\" : true
        },
        \"max_connection_timeout\" : {
            \"type\" : \"integer\",
            \"minimum\" : 0,
            \"optional\" : true,
            \"default\" : 5000
        }
    }
}">>,
    Args = proplists:get_value(<<"args">>, Descriptor),
    case jesse:validate_with_schema(jsonx:decode(Schema), Args) of
        {ok, _Args} ->
            %% NOTE TCP conncetor is used to listen on the hive side. It's assumed to be fine.
            ok;

        {error, Error} ->
            ErrorMsg = hive_error_utils:prettify(<<"">>, [{<<"">>, Error}], <<",">>),
            {error, {bad_tcp_connector_args, ErrorMsg}}
    end.

%% Hive connector callbacks:
common_init(PoolName, Pool) ->
    init_counters(lists:map(fun(C) -> name(C, PoolName) end, ?TCP_CONN_COUNTERS)),
    WorkerArgs = proplists:get_value(<<"args">>, Pool),
    {ok, Pool, [proplists:property(pool_name, PoolName) | WorkerArgs]}.

start_pool(PoolArgs, WorkerArgs) ->
    gen_server:start_link(?MODULE, {PoolArgs, WorkerArgs}, []).

checkout(Pool, Timeout) ->
    gen_server:call(Pool, {checkout, Timeout}).

checkin(Pool, Worker) ->
    gen_server:cast(Pool, {checkin, Worker}).

transaction(Pool, Transaction) ->
    gen_server:call(Pool, {transaction, Transaction}).

stop_pool(Pool) ->
    gen_server:call(Pool, stop).

%% Internal TCP connector functions:
remove(Pool, Worker) ->
    gen_server:cast(Pool, {remove, Worker}).

add(Pool, Worker) ->
    gen_server:cast(Pool, {add, Worker}).

%% Gen Server callbacks:
init({PoolArgs, WorkerArgs}) ->
    process_flag(trap_exit, true), %% NOTE In order to clean up properly.
    PoolName = proplists:get_value(pool_name, WorkerArgs),
    Size = proplists:get_value(<<"size">>, PoolArgs),
    %% NOTE This won't spawn more connections, but rather will increase
    %% NOTE the maximal request queue size.
    Overflow = proplists:get_value(<<"overflow">>, PoolArgs),
    Port = proplists:get_value(<<"port">>, WorkerArgs),
    State = #tcp_state{
               pool_name = PoolName,
               workers = [],
               workers2kill = [],
               froms = queue:new(),
               froms_len = 0,
               froms_limit = Size + Overflow
              },
    case ranch:start_listener(PoolName, Size,
                              ranch_tcp, [{port, Port}],
                              tcp_worker, [self(), WorkerArgs])
    of
        {ok, _Pid} ->
            {ok, State#tcp_state{listener = PoolName}};

        {error, {already_started, _Pid}} ->
            ranch:set_protocol_options(PoolName, [self(), WorkerArgs]),
            ?inc(?CONN_TCP_ERRORS),
            lager:warning("Hive TCP Connector listener already started!"),
            {ok, State#tcp_state{listener = PoolName}};

        {error, Error} ->
            ?inc(?CONN_TCP_ERRORS),
            ErrorMsg = hive_error_utils:format("Hive TCP Connector ~s is unable to initialize the listener: ~p",
                                                [PoolName, Error]),
            lager:error(ErrorMsg),
            {stop, {tcp_error, ErrorMsg}}
    end.

terminate(_Reason, State) ->
    ranch:stop_listener(State#tcp_state.listener),
    stop_workers(State),
    stop_requests(State).

handle_call({checkout, Timeout}, From, State) ->
    case checkout_worker(State) of
        retry_later ->
            Timer = erlang:start_timer(Timeout, self(), {checkout_timeout, From}),
            Queue = State#tcp_state.froms,
            Len = State#tcp_state.froms_len,
            Limit = State#tcp_state.froms_limit,
            case Len of
                Limit ->
                    ?inc(?CONN_TCP_ERRORS),
                    ErrorMsg = hive_error_utils:format("Hive TCP Connector ~s's request queue is full.",
                                                       [State#tcp_state.pool_name]),
                    lager:error(ErrorMsg),
                    {reply, {error, {tcp_error, ErrorMsg}}, State};

                _Otherwise ->
                    {noreply, State#tcp_state{froms = queue:in({From, Timer}, Queue), froms_len = Len + 1}}
            end;

        {ok, Worker, NewState} ->
            {reply, {ok, Worker}, NewState};

        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({transaction, Transaction}, From, State) ->
    case checkout_worker(State) of
        retry_later ->
            Queue = State#tcp_state.froms,
            Len = State#tcp_state.froms_len,
            Limit = State#tcp_state.froms_limit,
            case Len of
                Limit ->
                    ?inc(?CONN_TCP_ERRORS),
                    ErrorMsg = hive_error_utils:format("Hive TCP Connector ~s's request queue is full.",
                                                       [State#tcp_state.pool_name]),
                    lager:error(ErrorMsg),
                    {reply, {error, {tcp_error, ErrorMsg}}, State};

                _Otherwise ->
                    {noreply, State#tcp_state{froms = queue:in({From, Transaction}, Queue), froms_len = Len + 1}}
            end;



        {ok, Worker, NewState} ->
            %% NOTE This is ungodly slow. It's not even funny.
            Reply = Transaction(Worker),
            case checkin_worker(Worker, NewState) of
                {ok, NewestState} ->
                    {reply, Reply, NewestState};

                {error, Error} ->
                    {reply, {error, Error}, State}
            end;

        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call(stop, _From, State) ->
    {stop, shutdown, State};

handle_call(Message, _From, State) ->
    ?inc(?CONN_TCP_ERRORS),
    lager:warning("Unhandled Hive TCP Connector call: ~p", [Message]),
    {reply, ok, State}.

handle_cast({remove, Worker}, State) ->
    case lists:member(Worker, State#tcp_state.workers) of
        %% NOTE We can remove directly...
        true  -> tcp_worker:kill(Worker, shutdown),
                 {noreply, remove_worker(Worker, State)};
        %% NOTE ...or we need to schedule termination for later.
        false -> W2K = [Worker | State#tcp_state.workers2kill],
                 {noreply, State#tcp_state{workers2kill = W2K}}
    end;

handle_cast({checkin, Worker}, State) ->
    case checkin_worker(Worker, State) of
        {ok, NewState} ->
            {noreply, NewState};

        {error, Error} ->
            lager:error("Hive TCP Connector encountered an error: ~p", [Error]),
            {noreply, State}
    end;

handle_cast({add, Worker}, State) ->
    Workers = State#tcp_state.workers,
    case checkin_worker(Worker, State) of
        {ok, NewState} ->
            {noreply, NewState};

        {error, Error} ->
            lager:error("Hive TCP Connector encountered an error: ~p", [Error]),
            {noreply, State}
    end;

handle_cast(Message, State) ->
    ?inc(?CONN_TCP_ERRORS),
    lager:warning("Unhandled Hive TCP Connector cast: ~p", [Message]),
    {noreply, State}.

handle_info({timeout, _Ref, {checkout_timeout, From}}, State) ->
    PoolName = State#tcp_state.pool_name,
    ?inc(?CONN_TCP_ERRORS),
    ErrorMsg = hive_error_utils:format("Hive TCP Connector ~s's request timed out!", [PoolName]),
    lager:error(ErrorMsg),
    gen_server:reply(From, {error, {tcp_error, ErrorMsg}}),
    NewFroms = queue:filter(fun({F, _T}) -> F =/= From end, State#tcp_state.froms),
    NewLen = queue:len(NewFroms),
    {noreply, State#tcp_state{froms = NewFroms, froms_len = NewLen}};

handle_info({'EXIT', Worker, _Reason}, State) ->
    {noreply, remove_worker(Worker, State)};

handle_info(Info, State) ->
    ?inc(?CONN_TCP_ERRORS),
    lager:warning("Unhandled Hive TCP Connector info: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    ?inc(?CONN_TCP_ERRORS),
    lager:warning("Unhandled Hive TCP Connector code change."),
    {ok, State}.

%% Internal functions:
checkout_worker(State) ->
    case State#tcp_state.workers of
        [Worker | Workers] -> {ok, Worker, State#tcp_state{workers = Workers}};
        []                 -> retry_later
    end.

checkin_worker(Worker, State) ->
    W2K = State#tcp_state.workers2kill,
    case lists:member(Worker, W2K) of
        true ->
            %% NOTE We need to remove workers that requested termination while bussy...
            tcp_worker:kill(Worker, shutdown),
            {ok, remove_worker(Worker, State)};

        false ->
            %% NOTE ...or just use them right away.
            Froms = State#tcp_state.froms,
            Len = State#tcp_state.froms_len,
            case queue:out(Froms) of
                %% NOTE We have an ongoing transaction which has to be carried out...
                {{value, {From, Transaction}}, NewFroms} when is_function(Transaction, 1) ->
                    %% FIXME This shouldn't run here as it may clog the entire connector up.
                    %% NOTE This is currently unused as it is too slow.
                    gen_server:reply(From, Transaction(Worker)),
                    checkin_worker(Worker, State#tcp_state{froms = NewFroms, froms_len = Len - 1});

                %% NOTE ...or an ongoing checkout request...
                {{value, {From, Timer}}, NewFroms} ->
                    erlang:cancel_timer(Timer),
                    gen_server:reply(From, {ok, Worker}),
                    {ok, State#tcp_state{froms = NewFroms, froms_len = Len - 1}};

                %% NOTE ...or we're good to go.
                {empty, Froms} ->
                    Workers = State#tcp_state.workers,
                    {ok, State#tcp_state{workers = [Worker | Workers]}}
            end
    end.

stop_requests(State) ->
    PoolName = State#tcp_state.pool_name,
    lists:foreach(fun({From, _Transaction}) ->
                          ?inc(?CONN_TCP_ERRORS),
                          ErrorMsg = hive_error_utils:format("Hive TCP Connector ~s's request failed!",
                                                              [PoolName]),
                          lager:error(ErrorMsg),
                          gen_server:reply(From, {error, {tcp_error, ErrorMsg}})
                  end,
                  queue:to_list(State#tcp_state.froms)).

stop_workers(State) ->
    lists:foreach(fun(Worker) ->
                          tcp_worker:kill(Worker, shutdown)
                  end,
                  State#tcp_state.workers).

remove_worker(Worker, State) ->
    Workers = State#tcp_state.workers,
    W2K = State#tcp_state.workers2kill,
    State#tcp_state{workers = lists:delete(Worker, Workers),
                    workers2kill = lists:delete(Worker, W2K)}.
