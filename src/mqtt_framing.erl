-module(mqtt_framing).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start/1]).

-export_type([return_code/0,
              parse_result/0,
              message_type/0,
              qos/0,
              mqtt_frame/0]).


-define(Top1, 128).
-define(Lower7, 127).

-define(CONNECT, 1).
-define(CONNACK, 2).
-define(PUBLISH, 3).
-define(PUBACK, 4).
-define(PUBREC, 5).
-define(PUBREL, 6).
-define(PUBCOMP, 7).
-define(SUBSCRIBE, 8).
-define(SUBACK, 9).
-define(UNSUBSCRIBE, 10).
-define(UNSUBACK, 11).
-define(PINGREQ, 12).
-define(PINGRESP, 13).
-define(DISCONNECT, 14).

-define(set(Record, Field), fun(R, V) -> R#Record{ Field = V } end).

-include("include/frames.hrl").


-type(mqtt_frame() :: #connect{}
                    | #connack{}
                    | #publish{}).

-type(qos() :: 0 | 1 | 2).
-type(message_type() ::
      ?CONNECT
    | ?CONNACK
    | ?PUBLISH
    | ?PUBACK
    | ?PUBREC
    | ?PUBREL
    | ?PUBCOMP
    | ?SUBSCRIBE
    | ?SUBACK
    | ?UNSUBSCRIBE
    | ?UNSUBACK
    | ?PINGREQ
    | ?PINGRESP
    | ?DISCONNECT).

-type(return_code() :: 'ok'
                     | 'wrong_version'
                     | 'bad_id'
                     | 'server_unavailable'
                     | 'bad_auth'
                     | 'not_authorised').

%% MQTT frames come in three parts: firstly, a fixed header, which is
%% two to five bytes with some flags, a number denoting the command,
%% and the (encoded) remaining length; then, a variable header which
%% is various serial values depending on the command; then, the
%% payload, which is simply bytes.
%%
%% We'll simply split the frame up into these sections and wrap a
%% record around it representing the command.

%% We'll take the chance that almost all of the time we'll want the
%% whole frame at once, even if we end up discarding it.

%% Fixed header.
%% bit     |7  6  5  4   |3        |2    1    |0
%% byte 1  |Message Type |DUP flag |QoS level |RETAIN
%% byte 2  |Remaining Length

%% Frame parsing is to be done as a trampoline: it starts with the
%% function `start/1`, which returns either `{frame, Frame, Rest}`,
%% indicating that a frame has been parsed and parsing should begin
%% again with `start(Rest)`; or, `{more, K}` which indicates that a
%% frame was not able to be parsed, and parsing should start again
%% with `K` when there are more bytes available.

-type(parse_result() :: {frame, mqtt_frame()}
                      | {error, term()}
                      | {more, parse()}).

-type(parse() :: fun((binary()) -> parse_result())).

-spec(start(binary()) -> parse_result()).
start(<<MessageType:4, Dup:1, QoS:2, Retain:1, Len1:8,
       Rest/binary>>) ->
    %% Invalid values?
    parse_from_length(#fixed{type = MessageType,
                             dup = flag(Dup),
                             qos = QoS,
                             retain = flag(Retain)},
                      Len1, 1, 0, Rest);
%% Not enough to even get the first bit of the header. This might
%% happen if a frame is split across packets. We don't expect to split
%% across more than two packets.
start(Bin1) ->
    {more, fun(Bin2) -> start(<<Bin1/binary, Bin2/binary>>) end}.

parse_from_length(Fixed, LenByte, Multiplier0, Value0, Bin) ->
    Length = Value0 + (LenByte band ?Lower7) * Multiplier0,
    case LenByte band ?Top1 of
        ?Top1 ->
            Multiplier = Multiplier0 * 128,
            case Bin of
                <<NextLenByte:8, Rest/binary>> ->
                    parse_from_length(Fixed, NextLenByte, Multiplier,
                                      Length, Rest);
                <<>> ->
                    %% Assumes we get at least one more byte ..
                    {more, fun(<<NextLenByte:8, Rest/binary>>) ->
                                   parse_from_length(Fixed, NextLenByte,
                                                     Multiplier,
                                                     Length, Rest)
                           end}
            end;
        0 -> % No continuation bit
            parse_variable_header(Fixed, Length, Bin)
    end.

%% Each message type has its own idea of what the variable header
%% contains.  We may as well read until we have the entire frame first
%% though.
parse_variable_header(Fixed = #fixed{ type = Type }, Length, Bin) ->
    case Bin of
        <<FrameRest:Length/binary, Rest/binary>> ->
            case parse_message_type(Type, Fixed, FrameRest) of
                Err = {error, _} ->
                    Err;
                {ok, Frame} ->
                    {frame, Frame, Rest}
            end;
        NotEnough ->
            parse_more_header(Fixed, Length, Length, [], NotEnough)
    end.

parse_more_header(Fixed, Length, Needed, FragmentsRev, Bin) ->
    Got = size(Bin),
    if Got < Needed ->
            {more, fun(NextBin) ->
                           parse_more_header(Fixed, Length, Needed - Got,
                                             [Bin | FragmentsRev], NextBin)
                   end};
       true ->
            Fragments = lists:reverse([Bin | FragmentsRev]),
            parse_variable_header(Fixed, Length, list_to_binary(Fragments))
    end.

parse_message_type(?CONNECT, Fixed,
                   %% Protocol name, Protocol version
                   <<0, 6, "MQIsdp", 3,
                    %% Flaaaags
                    UsernameFlag:1, PasswordFlag:1, WillRetain:1,
                    WillQos:2, WillFlag:1, CleanSession:1, _:1,
                    KeepAlive:16,
                    %% The content depends on the flags
                    Payload/binary>>) ->
    {ClientId, Rest} = parse_string(Payload),
    if size(ClientId) > 23 ->
            {error, identifier_rejected};
       true ->
            S = {ok, #connect{ fixed = Fixed,
                               will_retain = flag(WillRetain),
                               will_qos = WillQos,
                               clean_session = flag(CleanSession),
                               keep_alive = KeepAlive,
                               client_id = ClientId },
                 Rest},
            S1 = maybe_s(S,  WillFlag, ?set(connect, will_topic)),
            S2 = maybe_s(S1, WillFlag, ?set(connect, will_msg)),
            S3 = maybe_s(S2, UsernameFlag, ?set(connect, username)),
            S4 = maybe_s(S3, PasswordFlag, ?set(connect, password)),
            case S4 of
                {ok, Connect, <<>>} -> {ok, Connect};
                {ok, _, _} -> {error, malformed_frame};
                Err = {error, _} -> Err
            end
    end;

parse_message_type(?CONNACK, Fixed, <<_Reserved:8, Return:8>>) ->
    {ok, #connack{ fixed = Fixed,
                   return_code = byte_to_return_code(Return) }};

parse_message_type(?PUBLISH, Fixed, <<TopicLen:16, Topic:TopicLen/binary,
                                     MsgId:16,
                                     Payload/binary>>) ->
    {ok, #publish{ fixed = Fixed, topic = Topic, message_id = MsgId,
                   payload = Payload }};
parse_message_type(_, _, _) ->
    {error, unrecognised}.

parse_string(<<Length:16, String:Length/binary, Rest/binary>>) ->
    {String, Rest};
parse_string(_Bin) ->
    {error, malformed_frame}.

maybe_s(Err = {error, _}, _, _) ->
    Err;
maybe_s({ok, Frame, Bin}, 0, _Setter) ->
    {ok, Frame, Bin};
maybe_s({ok, Frame, Bin}, 1, Setter) ->
    case parse_string(Bin) of
        Error = {error, _} ->
            Error;
        {String, Rest} ->
            {ok, Setter(Frame, String), Rest}
    end.

flag(0) -> true;
flag(1) -> false.

-spec(byte_to_return_code(byte()) -> return_code()). 
byte_to_return_code(0) -> ok;
byte_to_return_code(1) -> wrong_version;
byte_to_return_code(2) -> bad_id;
byte_to_return_code(3) -> server_unavailable;
byte_to_return_code(4) -> bad_auth;
byte_to_return_code(5) -> not_authorised;
byte_to_return_code(Else) -> throw({reserved_return_code, Else}).

-spec(return_code_to_byte(return_code()) -> byte()).
return_code_to_byte(ok) -> 0;
return_code_to_byte(wrong_version) -> 1;
return_code_to_byte(bad_id) -> 2;
return_code_to_byte(server_unavailable) -> 3;
return_code_to_byte(bad_auth) -> 4;
return_code_to_byte(not_authorised) -> 5;
return_code_to_byte(Else) -> throw({unknown_return_code, Else}).

%% ---------- properties

-ifdef(TEST).
prop_return_code() ->
    ?FORALL(Code, mqtt_framing:return_code(),
            begin
                B = return_code_to_byte(Code),
                C = byte_to_return_code(B),
                Code =:= C
            end).

proper_module_test() ->
    ?assertEqual([], proper:module(?MODULE, [long_result])).

-endif.
