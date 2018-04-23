% @hidden
-module(kafe_protocol_fetch).
-compile([{parse_transform, lager_transform}]).

-include("../include/kafe.hrl").
-define(MAX_VERSION, 7).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
         run/3,
         request/4,
         response/2
        ]).

run(ReplicaID, Topics, Options) ->
  case dispatch(Topics, Options) of
    {ok, Dispatch} ->
      consolidate(
        [kafe_protocol:run(
           ?FETCH_REQUEST,
           ?MAX_VERSION,
           {fun ?MODULE:request/4, [ReplicaID, Topics0, Options]},
           fun ?MODULE:response/2,
           #{broker => BrokerID})
         || {BrokerID, Topics0} <- Dispatch]);
    {error, _} = Error ->
      Error
  end.

consolidate([Response|_] = Responses) ->
  case Response of
    {ok, #{throttle_time := ThrottleTime}} ->
      {ok, #{throttle_time => ThrottleTime,
             topics => consolidate(Responses, #{})}};
    {ok, _} ->
      {ok, consolidate(Responses, #{})};
    Error ->
      Error
  end.

consolidate([], Acc) ->
  maps:fold(fun(Topic, Partitions, Acc0) ->
                [#{name => Topic, partitions => Partitions}|Acc0]
            end, [], Acc);
consolidate([{ok, #{topics := Topics}}|Rest], Acc) ->
  consolidate([Topics|Rest], Acc);
consolidate([{ok, Topics}|Rest], Acc) ->
  consolidate([Topics|Rest], Acc);
consolidate([Topics|Rest], Acc) ->
  consolidate(
    Rest,
    lists:foldl(fun(#{name := Name, partitions := Partitions}, Acc0) ->
                    maps:put(
                      Name,
                      maps:get(Name, Acc, []) ++ Partitions,
                      Acc0)
                end, Acc, Topics)).


% Fetch Request (Version: 0) => replica_id max_wait_time min_bytes [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 1) => replica_id max_wait_time min_bytes [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 2) => replica_id max_wait_time min_bytes [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 3) => replica_id max_wait_time min_bytes max_bytes [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   max_bytes => INT32
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 4) => replica_id max_wait_time min_bytes max_bytes isolation_level [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   max_bytes => INT32
%   isolation_level => INT8
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 5) => replica_id max_wait_time min_bytes max_bytes isolation_level [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   max_bytes => INT32
%   isolation_level => INT8
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset log_start_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       log_start_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 6) => replica_id max_wait_time min_bytes max_bytes isolation_level [topics]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   max_bytes => INT32
%   isolation_level => INT8
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset log_start_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       log_start_offset => INT64
%       max_bytes => INT32
%
% Fetch Request (Version: 7) => replica_id max_wait_time min_bytes max_bytes isolation_level session_id epoch [topics] [forgetten_topics_data]
%   replica_id => INT32
%   max_wait_time => INT32
%   min_bytes => INT32
%   max_bytes => INT32
%   isolation_level => INT8
%   session_id => INT32
%   epoch => INT32
%   topics => topic [partitions]
%     topic => STRING
%     partitions => partition fetch_offset log_start_offset max_bytes
%       partition => INT32
%       fetch_offset => INT64
%       log_start_offset => INT64
%       max_bytes => INT32
%   forgetten_topics_data => topic [partitions]
%     topic => STRING
%     partitions => INT32
request(ReplicaID, Topics, Options, #{api_version := ApiVersion} = State) when ApiVersion == ?V0;
                                                                               ApiVersion == ?V1;
                                                                               ApiVersion == ?V2 ->
  MinBytes = maps:get(min_bytes, Options, ?DEFAULT_FETCH_MIN_BYTES),
  MaxWaitTime = maps:get(max_wait_time, Options, ?DEFAULT_FETCH_MAX_WAIT_TIME),
  kafe_protocol:request(
    <<ReplicaID:32/signed,
      MaxWaitTime:32/signed,
      MinBytes:32/signed,
      (topics(Topics, ApiVersion))/binary>>,
    State);
request(ReplicaID, Topics, Options, #{api_version := ApiVersion} = State) when ApiVersion == ?V3 ->
  MinBytes = maps:get(min_bytes, Options, ?DEFAULT_FETCH_MIN_BYTES),
  ResponseMaxBytes = maps:get(response_max_bytes, Options, response_max_bytes(Topics)),
  MaxWaitTime = maps:get(max_wait_time, Options, ?DEFAULT_FETCH_MAX_WAIT_TIME),
  kafe_protocol:request(
    <<ReplicaID:32/signed,
      MaxWaitTime:32/signed,
      MinBytes:32/signed,
      ResponseMaxBytes:32/signed,
      (topics(Topics, ApiVersion))/binary>>,
    State);
request(ReplicaID, Topics, Options, #{api_version := ApiVersion} = State) when ApiVersion == ?V4;
                                                                               ApiVersion == ?V5;
                                                                               ApiVersion == ?V6 ->
  MinBytes = maps:get(min_bytes, Options, ?DEFAULT_FETCH_MIN_BYTES),
  ResponseMaxBytes = maps:get(response_max_bytes, Options, response_max_bytes(Topics)),
  MaxWaitTime = maps:get(max_wait_time, Options, ?DEFAULT_FETCH_MAX_WAIT_TIME),
  IsolationLevel = maps:get(isolation_level, Options, ?DEFAULT_FETCH_ISOLATION_LEVEL),
  kafe_protocol:request(
    <<ReplicaID:32/signed,
      MaxWaitTime:32/signed,
      MinBytes:32/signed,
      ResponseMaxBytes:32/signed,
      IsolationLevel:8/signed,
      (topics(Topics, ApiVersion))/binary>>,
    State);
request(ReplicaID, Topics, Options, #{api_version := ApiVersion} = State) when ApiVersion == ?V7 ->
  MinBytes = maps:get(min_bytes, Options, ?DEFAULT_FETCH_MIN_BYTES),
  ResponseMaxBytes = maps:get(response_max_bytes, Options, response_max_bytes(Topics)),
  MaxWaitTime = maps:get(max_wait_time, Options, ?DEFAULT_FETCH_MAX_WAIT_TIME),
  IsolationLevel = maps:get(isolation_level, Options, ?DEFAULT_FETCH_ISOLATION_LEVEL),
  SessionId = maps:get(session_id, Options, ?DEFAULT_FETCH_SESSION_ID),
  Epoch = maps:get(epoch, Options, ?DEFAULT_FETCH_EPOCH),
  ForgottenTopics = maps:get(forgotten_topics, Options, ?DEFAULT_FETCH_FORGOTTEN_TOPICS),
  kafe_protocol:request(
    <<ReplicaID:32/signed,
      MaxWaitTime:32/signed,
      MinBytes:32/signed,
      ResponseMaxBytes:32/signed,
      IsolationLevel:8/signed,
      SessionId:32/signed,
      Epoch:32/signed,
      (topics(Topics, ApiVersion))/binary,
      (forgetten_topics(ForgottenTopics, ApiVersion))/binary>>,
    State).

topics(Topics, ApiVersion) ->
  topics(Topics, ApiVersion, []).

topics([], _ApiVersion, Acc) ->
  kafe_protocol:encode_array(Acc);
topics([{Topic, Partitions}|Rest], ApiVersion, Acc) ->
  topics(Rest, ApiVersion, [<<
                              (kafe_protocol:encode_string(Topic))/binary,
                              (partitions(Partitions, ApiVersion))/binary
                            >>|Acc]).

partitions(Partitions, ApiVersion) ->
  partitions(Partitions, ApiVersion, []).

partitions([], _ApiVersion, Acc) ->
  kafe_protocol:encode_array(Acc);
partitions([{Partition, Offset, MaxBytes}|Rest], ApiVersion, Acc) when ApiVersion == ?V0;
                                                                       ApiVersion == ?V1;
                                                                       ApiVersion == ?V2;
                                                                       ApiVersion == ?V3;
                                                                       ApiVersion == ?V4 ->
  partitions(Rest, ApiVersion, [<<
                                  Partition:32/signed,
                                  Offset:64/signed,
                                  MaxBytes:32/signed
                                >>|Acc]);
partitions([{Partition, Offset, MaxBytes}|Rest], ApiVersion, Acc) when ApiVersion == ?V5;
                                                                       ApiVersion == ?V6;
                                                                       ApiVersion == ?V7 ->
  partitions(Rest, ApiVersion, [<<
                                  Partition:32/signed,
                                  Offset:64/signed,
                                  0:64/signed,
                                  MaxBytes:32/signed
                                >>|Acc]);
partitions([{Partition, Offset, LogStartOffset, MaxBytes}|Rest], ApiVersion, Acc) when ApiVersion == ?V5;
                                                                                       ApiVersion == ?V6;
                                                                                       ApiVersion == ?V7 ->
  partitions(Rest, ApiVersion, [<<
                                  Partition:32/signed,
                                  Offset:64/signed,
                                  LogStartOffset:64/signed,
                                  MaxBytes:32/signed
                                >>|Acc]).

forgetten_topics(Topics, ApiVersion) ->
  forgetten_topics(Topics, ApiVersion, []).

forgetten_topics([], _ApiVersion, Acc) ->
  kafe_protocol:encode_array(Acc);
forgetten_topics([{Topic, Partitions}|Rest], ApiVersion, Acc) when ApiVersion == ?V7 ->
  forgetten_topics(
    Rest,
    ApiVersion,
    [<<
       (kafe_protocol:encode_string(Topic))/binary,
       (kafe_protocol:encode_array([<<P:32>> || P <- Partitions]))/binary
     >>|Acc]).

% Fetch Response (Version: 0) => [responses]
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition error_code high_watermark record_set
%       partition => INT32
%       error_code => INT16
%       high_watermark => INT64
%       record_set => BYTES
%
% Fetch Response (Version: 1) => throttle_time_ms [responses]
%   throttle_time_ms => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition error_code high_watermark record_set
%       partition => INT32
%       error_code => INT16
%       high_watermark => INT64
%       record_set => BYTES
%
% Fetch Response (Version: 2) => throttle_time_ms [responses]
%   throttle_time_ms => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition error_code high_watermark record_set
%       partition => INT32
%       error_code => INT16
%       high_watermark => INT64
%       record_set => BYTES
%
% Fetch Response (Version: 3) => throttle_time_ms [responses]
%   throttle_time_ms => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition error_code high_watermark record_set
%       partition => INT32
%       error_code => INT16
%       high_watermark => INT64
%       record_set => BYTES
%
% Fetch Response (Version: 4) => trottle_time_ms [responses]
%   throttle_time_ms => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition_header record_set
%       partition_header => partition error_code high_watermark last_stable_offset [aborted_transactions]
%         partition => INT32
%         error_code => INT16
%         high_watermark => INT64
%         last_stable_offset => INT64
%         aborted_transactions => producer_id first_offset
%           producer_id => INT64
%           first_offset => INT64
%       record_set => RECORDS
%
% Fetch Response (Version: 5) => throttle_time_ms [responses]
%   throttle_time_ms => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition_header record_set
%       partition_header => partition error_code high_watermark last_stable_offset log_start_offset [aborted_transactions]
%         partition => INT32
%         error_code => INT16
%         high_watermark => INT64
%         last_stable_offset => INT64
%         log_start_offset => INT64
%         aborted_transactions => producer_id first_offset
%           producer_id => INT64
%           first_offset => INT64
%       record_set => RECORDS
%
% Fetch Response (Version: 6) => throttle_time_ms [responses]
%   throttle_time_ms => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition_header record_set
%       partition_header => partition error_code high_watermark last_stable_offset log_start_offset [aborted_transactions]
%         partition => INT32
%         error_code => INT16
%         high_watermark => INT64
%         last_stable_offset => INT64
%         log_start_offset => INT64
%         aborted_transactions => producer_id first_offset
%           producer_id => INT64
%           first_offset => INT64
%       record_set => RECORDS
%
% Fetch Response (Version: 7) => throttle_time_ms error_code session_id [responses]
%   throttle_time_ms => INT32
%   error_code => INT16
%   session_id => INT32
%   responses => topic [partition_responses]
%     topic => STRING
%     partition_responses => partition_header record_set
%       partition_header => partition error_code high_watermark last_stable_offset log_start_offset [aborted_transactions]
%         partition => INT32
%         error_code => INT16
%         high_watermark => INT64
%         last_stable_offset => INT64
%         log_start_offset => INT64
%         aborted_transactions => producer_id first_offset
%           producer_id => INT64
%           first_offset => INT64
%       record_set => RECORDS
response(<<NumberOfTopics:32/signed,
           Remainder/binary>>,
         #{api_version := ApiVersion}) when ApiVersion == ?V0 ->
  topics(NumberOfTopics, Remainder, ApiVersion, []);
response(<<ThrottleTime:32/signed,
           NumberOfTopics:32/signed,
           Remainder/binary>>,
         #{api_version := ApiVersion}) when ApiVersion == ?V1;
                                            ApiVersion == ?V2;
                                            ApiVersion == ?V3;
                                            ApiVersion == ?V4;
                                            ApiVersion == ?V5;
                                            ApiVersion == ?V6;
                                            ApiVersion == ?V7 ->
  case topics(NumberOfTopics, Remainder, ApiVersion, []) of
    {ok, Response} ->
      {ok, #{topics => Response,
             throttle_time => ThrottleTime}};
    Error ->
      Error
  end;
response(_, _) ->
  {error, incomplete_data}.

% Private

topics(0, _Remainder, _ApiVersion, Result) ->
  {ok, Result};
topics(
  N,
  <<TopicNameLength:16/signed,
    TopicName:TopicNameLength/bytes,
    NumberOfPartitions:32/signed,
    PartitionRemainder/binary>>,
  ApiVersion,
  Acc) ->
  case partitions(NumberOfPartitions, PartitionRemainder, ApiVersion, []) of
    {ok, Partitions, Remainder} ->
      topics(N - 1, Remainder, ApiVersion, [#{name => TopicName,
                                              partitions => Partitions}|Acc]);
    Error ->
      Error
  end;
topics(_N, _Remainder, _ApiVersion, _Result) ->
  {error, incomplete_data}.

partitions(0, Remainder, _ApiVersion, Acc) ->
  {ok, Acc, Remainder};
partitions(
  N,
  <<Partition:32/signed,
    ErrorCode:16/signed,
    HighwaterMarkOffset:64/signed,
    MessageSetSize:32/signed,
    MessageSet:MessageSetSize/binary,
    Remainder/binary>>,
  ApiVersion,
  Acc) when ApiVersion == ?V0;
            ApiVersion == ?V1;
            ApiVersion == ?V2;
            ApiVersion == ?V3 ->
  partitions(
    N - 1,
    Remainder,
    ApiVersion,
    [#{partition => Partition,
       error_code => kafe_error:code(ErrorCode),
       high_watermark_offset => HighwaterMarkOffset,
       messages => message(MessageSet)} | Acc]);
partitions(
  N,
  <<Partition:32/signed,
    ErrorCode:16/signed,
    HighwaterMarkOffset:64/signed,
    LastStableOffset:64/signed,
    AbortedTransactionsSize:32/signed,
    Remainder0/binary>>,

  ApiVersion,
  Acc) when ApiVersion == ?V4 ->
  case aborted_transactions(AbortedTransactionsSize, Remainder0, []) of
    {ok, AbortedTransactions,
     <<
       MessageSetSize:32/signed,
       MessageSet:MessageSetSize/binary,
       Remainder1/binary
     >>} ->
      partitions(
        N - 1,
        Remainder1,
        ApiVersion,
        [#{partition => Partition,
           error_code => kafe_error:code(ErrorCode),
           high_watermark_offset => HighwaterMarkOffset,
           last_stable_offset => LastStableOffset,
           aborted_transactions => AbortedTransactions,
           messages => message(MessageSet)} | Acc]);
    Error ->
      Error
  end;
partitions(
  N,
  <<Partition:32/signed,
    ErrorCode:16/signed,
    HighwaterMarkOffset:64/signed,
    LastStableOffset:64/signed,
    LogStartOffset:64/signed,
    AbortedTransactionsSize:32/signed,
    Remainder0/binary>>,

  ApiVersion,
  Acc) when ApiVersion == ?V5;
            ApiVersion == ?V6;
            ApiVersion == ?V7 ->
  case aborted_transactions(AbortedTransactionsSize, Remainder0, []) of
    {ok, AbortedTransactions,
     <<
       MessageSetSize:32/signed,
       MessageSet:MessageSetSize/binary,
       Remainder1/binary
     >>} ->
      partitions(
        N - 1,
        Remainder1,
        ApiVersion,
        [#{partition => Partition,
           error_code => kafe_error:code(ErrorCode),
           high_watermark_offset => HighwaterMarkOffset,
           last_stable_offset => LastStableOffset,
           log_start_offset => LogStartOffset,
           aborted_transactions => AbortedTransactions,
           messages => message(MessageSet)} | Acc]);
    Error ->
      Error
  end;
partitions(_N, _Remainder, _ApiVersion, _Result) ->
  {error, incomplete_data}.

aborted_transactions(0, Remainder, Acc) ->
  {ok, lists:reverse(Acc), Remainder};
aborted_transactions(
  N,
  <<
    ProducerID:64/signed,
    FirstOffset:64/signed,
    Remainder/binary
  >>,
  Acc) ->
  aborted_transactions(
    N-1,
    Remainder,
    [#{producer_id => ProducerID,
       first_offset => FirstOffset}|Acc]);
aborted_transactions(_N, _Remainder, _Acc) ->
  {error, incomplete_data}.

message(Data) ->
  message(Data, []).

message(<<Offset:64/signed,
          MessageSize:32/signed,
          Message:MessageSize/binary,
          Remainder/binary>>, Acc) ->
  case Message of
    <<Crc:32/signed,
      0:8/signed,
      Attibutes:8/signed,
      MessageRemainder/binary>> ->
      {Key, MessageRemainder1} = get_kv(MessageRemainder),
      {Value, <<>>} = get_kv(MessageRemainder1),
      message(Remainder, [#{offset => Offset,
                            crc => Crc,
                            magic_byte => 0,
                            attributes => Attibutes,
                            key => Key,
                            value => Value}|Acc]);
    <<Crc:32/signed,
      1:8/signed,
      Attibutes:8/signed,
      Timestamp:64/signed,
      MessageRemainder/binary>> ->
      {Key, MessageRemainder1} = get_kv(MessageRemainder),
      {Value, <<>>} = get_kv(MessageRemainder1),
      message(Remainder, [#{offset => Offset,
                            crc => Crc,
                            magic_byte => 1,
                            attributes => Attibutes,
                            timestamp => Timestamp,
                            key => Key,
                            value => Value}|Acc])
  end;
message(_, Acc) ->
  lists:reverse(Acc).

get_kv(<<KVSize:32/signed, Remainder/binary>>) when KVSize =:= -1 ->
  {<<>>, Remainder};
get_kv(<<KVSize:32/signed, KV:KVSize/binary, Remainder/binary>>) ->
  {KV, Remainder}.


dispatch(Topics, Options) ->
  dispatch(Topics, Options, []).

dispatch([], _, Result) ->
  {ok, Result};
dispatch([{Topic, Partitions}|Rest], Options, Result) when is_binary(Topic),
                                                           is_list(Partitions) ->
  case dispatch(Topic, Partitions, Options, Result) of
    {error, _} = Error ->
      Error;
    Result0 ->
      dispatch(Rest, Options, Result0)
  end;
dispatch([{Topic, Partition}|Rest], Options, Result) when is_binary(Topic),
                                                          is_integer(Partition) ->
  {Partition, Offset} = case maps:get(offset, Options, undefined) of
                          undefined ->
                            kafe:max_offset(Topic, Partition);
                          Offset1 ->
                            {Partition, Offset1}
                        end,
  dispatch([{Topic, [{Partition, Offset}]}|Rest], Options, Result);
dispatch([Topic|Rest], Options, Result) when is_binary(Topic) ->
  {Partition, Offset} = case {maps:get(partition, Options, undefined),
                              maps:get(offset, Options, undefined)} of
                          {undefined, undefined} ->
                            kafe:max_offset(Topic);
                          {Partition1, undefined} ->
                            kafe:max_offset(Topic, Partition1);
                          {undefined, Offset1} ->
                            kafe:partition_for_offset(Topic, Offset1);
                          R -> R
                        end,
  dispatch([{Topic, [{Partition, Offset}]}|Rest], Options, Result).

dispatch(_, [], _, Result) ->
  Result;
dispatch(Topic, [{Partition, _, _} = P|Rest], Options, Result) ->
  case kafe_brokers:broker_id_by_topic_and_partition(Topic, Partition) of
    undefined ->
      {error, {leader_not_available, {Topic, Partition}}};
    BrokerID ->
      TopicsForBroker = buclists:keyfind(BrokerID, 1, Result, []),
      PartitionsForTopic = buclists:keyfind(Topic, 1, TopicsForBroker, []),
      dispatch(
        Topic,
        Rest,
        Options,
        buclists:keyupdate(
          BrokerID,
          1,
          Result,
          {BrokerID,
           buclists:keyupdate(
             Topic,
             1,
             TopicsForBroker,
             {Topic, [P|PartitionsForTopic]})}))
  end;
dispatch(Topic, [{Partition, Offset}|Rest], Options, Result) ->
  MaxBytes = maps:get(max_bytes, Options, ?DEFAULT_FETCH_MAX_BYTES),
  dispatch(Topic, [{Partition, Offset, MaxBytes}|Rest], Options, Result);
dispatch(Topic, [Partition|Rest], Options, Result) when is_integer(Partition) ->
  {Partition, Offset} = case maps:get(offset, Options, undefined) of
                          undefined ->
                            kafe:max_offset(Topic, Partition);
                          Offset1 ->
                            {Partition, Offset1}
                        end,
  MaxBytes = maps:get(max_bytes, Options, ?DEFAULT_FETCH_MAX_BYTES),
  dispatch(Topic, [{Partition, Offset, MaxBytes}|Rest], Options, Result).

response_max_bytes(List) ->
  response_max_bytes(List, 0).

response_max_bytes([], Acc) ->
  Acc;
response_max_bytes([{_, Partitions}|Rest], Acc) ->
  response_max_bytes(Rest, Acc + lists:sum([erlang:element(3, P) || P <- Partitions])).

-ifdef(TEST).
kafe_protocol_fetch_test_() ->
  {setup,
   fun() ->
       meck:new(kafe_brokers, [passthrough]),
       meck:expect(kafe_brokers, broker_id_by_topic_and_partition,
                   fun
                     (<<"topic1">>, 0) -> 'broker1';
                     (<<"topic1">>, 1) -> 'broker2';
                     (<<"topic1">>, 2) -> 'broker3';
                     (<<"topic2">>, 0) -> 'broker1';
                     (<<"topic2">>, 1) -> 'broker1';
                     (<<"topic2">>, 2) -> 'broker2';
                     (<<"topic3">>, 0) -> 'broker3';
                     (<<"topic3">>, 1) -> 'broker3';
                     (<<"topic3">>, 2) -> 'broker3';
                     (_, _) -> undefined
                   end),
       meck:new(kafe, [passthrough]),
       meck:expect(kafe, max_offset, fun(_, P) -> {P, 1000} end),
       meck:expect(kafe, max_offset, fun(_) -> {0, 2000} end),
       ok
   end,
   fun(_) ->
       meck:unload(kafe),
       meck:unload(kafe_brokers),
       ok
   end,
   [
    fun() ->
        ?assertEqual(
           {ok,
            [{broker3,
              [{<<"topic3">>, [{2, 302, 1048576}, {1, 301, 1048576}, {0, 300, 1048576}]},
               {<<"topic1">>, [{2, 102, 1048576}]}]},
             {broker2,
              [{<<"topic2">>, [{2, 202, 1048576}]},
               {<<"topic1">>, [{1, 101, 1048576}]}]},
             {broker1,
              [{<<"topic2">>, [{1, 201, 1048576}, {0, 200, 1048576}]},
               {<<"topic1">>, [{0, 100, 1048576}]}]}]},
           dispatch([{<<"topic1">>, [{0, 100}, {1, 101}, {2, 102}]},
                     {<<"topic2">>, [{0, 200}, {1, 201}, {2, 202}]},
                     {<<"topic3">>, [{0, 300}, {1, 301}, {2, 302}]}], #{})),
        ?assertEqual(
           {ok,
            [{broker3,
              [{<<"topic3">>, [{2, 1000, 1048576}, {1, 1000, 1048576}, {0, 1000, 1048576}]},
               {<<"topic1">>, [{2, 102, 1048576}]}]},
             {broker2,
              [{<<"topic2">>, [{2, 202, 1048576}]},
               {<<"topic1">>, [{1, 101, 1048576}]}]},
             {broker1,
              [{<<"topic2">>, [{1, 1000, 1048576}, {0, 1000, 1048576}]},
               {<<"topic1">>, [{0, 1000, 1048576}]}]}]},
           dispatch([{<<"topic1">>, [0, {1, 101}, {2, 102}]},
                     {<<"topic2">>, [0, 1, {2, 202}]},
                     {<<"topic3">>, [0, 1, 2]}], #{})),
        ?assertEqual(
           {ok,
            [{broker3,
              [{<<"topic3">>, [{0, 2000, 1048576}]},
               {<<"topic1">>, [{2, 102, 1048576}]}]},
             {broker2,
              [{<<"topic2">>, [{2, 202, 1048576}]},
               {<<"topic1">>, [{1, 101, 1048576}]}]},
             {broker1,
              [{<<"topic2">>, [{1, 1000, 1048576}, {0, 1000, 1048576}]},
               {<<"topic1">>, [{0, 1000, 1048576}]}]}]},
           dispatch([{<<"topic1">>, [0, {1, 101}, {2, 102}]},
                     {<<"topic2">>, [0, 1, {2, 202}]},
                     <<"topic3">>], #{})),
        ?assertEqual(
           {error, {leader_not_available, {<<"topic4">>, 0}}},
           dispatch([<<"topic4">>], #{})),
        ?assertEqual(
           {error, {leader_not_available, {<<"topic4">>, 0}}},
           dispatch([{<<"topic1">>, [0, {1, 101}, {2, 102}]},
                     {<<"topic2">>, [0, 1, {2, 202}]},
                     <<"topic3">>,
                     <<"topic4">>], #{}))
    end,
    fun() ->
        ?assertEqual(
           21,
           response_max_bytes([{<<"topic1">>, [{0, 0, 1},
                                               {1, 0, 2},
                                               {2, 0, 3}]},
                               {<<"topic2">>, [{0, 0, 4},
                                               {1, 0, 5},
                                               {2, 0, 6}]}]))
    end
   ]}.
-endif.
