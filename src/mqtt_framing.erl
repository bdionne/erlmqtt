-module(mqtt_framing).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([parse/1, serialise/1]).

-export_type([mqtt_frame/0,
              return_code/0,
              parse_result/0,
              message_type/0,
              message_id/0,
              qos/0,
              subscriptions/0,
              client_id/0]).

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
-define(undefined(ExprIn, IfUndefined, IfDefined),
        case ExprIn of
            undefined -> IfUndefined;
            _         -> IfDefined
        end).

-include("include/frames.hrl").

-type(mqtt_frame() ::
        #connect{}
      | #connack{}
      | mqtt_publish(0, 'undefined')
      | mqtt_publish(1 | 2,
                     mqtt_framing:message_id())
      | #puback{}
      | #pubrec{}
      | #pubrel{}
      | #pubcomp{}
      | #subscribe{}
      | #suback{}
      | #unsubscribe{}
      | #unsuback{}
      | 'pingreq'
      | 'pingresp'
      | 'disconnect').

-type(mqtt_publish(Qos, Id) ::
      #publish{ qos :: Qos,
                message_id :: Id }).

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

%% This isn't quite adequate: client IDs are supposed to be between 1
%% and 23 characters long; however, Erlang's type notation doesn't let
%% me express that easily.
-type(client_id() :: <<_:8, _:_*8>>).

-type(message_id() :: 1..16#ffff).

-type(subscriptions() :: [#subscription{}]).

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

-type(parse_result() :: {frame, mqtt_frame(), binary()}
                      | {error, term()}
                      | {more, parse()}).
-type(parse() :: fun((binary()) -> parse_result())).

-spec(parse(binary()) -> parse_result()).
parse(Bin) ->
    try start(Bin)
    catch
        throw:A -> {error, A}
    end.

-spec(start(binary()) -> parse_result()).
start(<<MessageType:4, Flags:4, Len1:8,
       Rest/binary>>) ->
    %% Invalid values?
    parse_from_length(MessageType, Flags, Len1, 1, 0, Rest);
%% Not enough to even get the first bit of the header. This might
%% happen if a frame is split across packets. We don't expect to split
%% across more than two packets.
start(Bin1) ->
    {more, fun(Bin2) -> start(<<Bin1/binary, Bin2/binary>>) end}.


parse_from_length(Type, Flags, LenByte, Multiplier0, Value0, Bin) ->
    Length = Value0 + (LenByte band ?Lower7) * Multiplier0,
    case LenByte band ?Top1 of
        ?Top1 ->
            Multiplier = Multiplier0 * 128,
            case Bin of
                <<NextLenByte:8, Rest/binary>> ->
                    parse_from_length(Type, Flags,
                                      NextLenByte, Multiplier,
                                      Length, Rest);
                <<>> ->
                    %% Assumes we get at least one more byte ..
                    {more, fun(<<NextLenByte:8, Rest/binary>>) ->
                                   parse_from_length(Type, Flags,
                                                     NextLenByte,
                                                     Multiplier,
                                                     Length, Rest)
                           end}
            end;
        0 -> % No continuation bit
            parse_variable_header(Type, Flags, Length, Bin)
    end.

%% Each message type has its own idea of what the variable header
%% contains.  We may as well read until we have the entire frame first
%% though.
parse_variable_header(Type, Flags, Length, Bin) ->
    case Bin of
        <<FrameRest:Length/binary, Rest/binary>> ->
            case parse_message_type(Type, Flags, FrameRest) of
                Err = {error, _} ->
                    Err;
                {ok, Frame} ->
                    {frame, Frame, Rest}
            end;
        NotEnough ->
            parse_more_header(Type, Flags, Length, Length,
                              [], NotEnough)
    end.

parse_more_header(Type, Flags, Length, Needed, FragmentsRev, Bin) ->
    Got = size(Bin),
    if Got < Needed ->
            {more, fun(NextBin) ->
                           parse_more_header(Type, Flags, Length,
                                             Needed - Got,
                                             [Bin | FragmentsRev], NextBin)
                   end};
       true ->
            Fragments = lists:reverse([Bin | FragmentsRev]),
            parse_variable_header(Type, Flags, Length,
                                  list_to_binary(Fragments))
    end.

parse_message_type(?CONNECT, _Flags,
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
            C = #connect{ will = undefined,
                          clean_session = flag(CleanSession),
                          keep_alive = KeepAlive,
                          client_id = ClientId },
            S1 = case WillFlag of
                     0 ->
                         {ok, C, Rest};
                     1 ->
                         {Topic, Rest1} = parse_string(Rest),
                         {Message, Rest2} = parse_string(Rest1),
                         {ok, C#connect{ will = #will{
                                           topic = Topic,
                                           message = Message,
                                           qos = WillQos,
                                           retain = flag(WillRetain)
                                          }
                                        }, Rest2}
                 end,
            S2 = maybe_s(S1, UsernameFlag, ?set(connect, username)),
            S3 = maybe_s(S2, PasswordFlag, ?set(connect, password)),
            case S3 of
                {ok, Connect, <<>>} -> {ok, Connect};
                {ok, _, _} -> {error, malformed_frame};
                Err = {error, _} -> Err
            end
    end;

parse_message_type(?CONNACK, _Flags, <<_Reserved:8, Return:8>>) ->
    {ok, #connack{ return_code = byte_to_return_code(Return) }};

parse_message_type(?PUBLISH, Flags,
                   <<TopicLen:16, Topic:TopicLen/binary,
                    MessageIdAndPayload/binary>>) ->
    Dup = dup_flag(Flags),
    Retain = retain_flag(Flags),
    Qos = qos_flag(Flags),
    {MessageId, Payload} =
        case Qos of
            0 ->
                {undefined, MessageIdAndPayload};
            _ ->
                <<MsgId:16, P/binary>> = MessageIdAndPayload,
                check_message_id(MsgId),
                {MsgId, P}
        end,
    {ok, #publish{ dup = Dup, retain = Retain, qos = Qos,
                   topic = Topic, message_id = MessageId,
                   payload = Payload }};

parse_message_type(?PUBACK, _Flags, <<MessageId:16>>) ->
    check_message_id(MessageId),
    {ok, #puback{ message_id = MessageId }};
parse_message_type(?PUBREC, _Flags, <<MessageId:16>>) ->
    check_message_id(MessageId),
    {ok, #pubrec{ message_id = MessageId }};
parse_message_type(?PUBREL, Flags, <<MessageId:16>>) ->
    check_message_id(MessageId),
    Dup = dup_flag(Flags),
    Qos = case qos_flag(Flags) of
              1    -> 1;
              Else -> throw({invalid_qos_value, Else})
          end,
    {ok, #pubrel{ dup = Dup, qos = Qos,
                  message_id = MessageId }};
parse_message_type(?PUBCOMP, _Flags, <<MessageId:16>>) ->
    check_message_id(MessageId),
    {ok, #pubcomp{ message_id = MessageId }};

parse_message_type(?SUBSCRIBE, Flags,
                   <<MessageId:16, SubsBin/binary>>) ->
    check_message_id(MessageId),
    Qos = qos_flag(Flags),
    Dup = dup_flag(Flags),
    Subs = parse_subs(SubsBin, []),
    {ok, #subscribe{ dup = Dup, qos = Qos,
                     message_id = MessageId, subscriptions = Subs }};

parse_message_type(?SUBACK, _Flags,
                   <<MessageId:16, QosBin/binary>>) ->
    check_message_id(MessageId),
    {ok, #suback{ message_id = MessageId,
                  qoses = parse_qoses(QosBin, []) }};

parse_message_type(?UNSUBSCRIBE, Flags,
                   <<MessageId:16, TopicsBin/binary>>) ->
    check_message_id(MessageId),
    Topics = parse_topics(TopicsBin, []),
    {ok, #unsubscribe{ message_id = MessageId,
                       qos = qos_flag(Flags),
                       topics = Topics }};

parse_message_type(?UNSUBACK, _Flags,
                   <<MessageId:16>>) ->
    check_message_id(MessageId),
    {ok, #unsuback{ message_id = MessageId }};

parse_message_type(?PINGREQ, _Flags, <<>>) ->
    {ok, pingreq};
parse_message_type(?PINGRESP, _Flags, <<>>) ->
    {ok, pingresp};
parse_message_type(?DISCONNECT, _Flags, <<>>) ->
    {ok, disconnect};

parse_message_type(_, _, _) ->
    {error, unrecognised}.



parse_string(<<Length:16, String:Length/binary, Rest/binary>>) ->
    {String, Rest};
parse_string(_Bin) ->
    {error, malformed_frame}.

parse_subs(<<>>, Subs) ->
    lists:reverse(Subs);
parse_subs(<<Len:16, Topic:Len/binary, Qos:8, Rest/binary>>,
           Subs) when Qos < 3 ->
    parse_subs(Rest, [#subscription{ topic = Topic, qos = Qos } | Subs]);
parse_subs(Else, _Subs) ->
    throw({unparsable_as_sub, Else}).

parse_qoses(<<>>, Qoses) ->
    lists:reverse(Qoses);
parse_qoses(<<Qos:8, Rest/binary>>, Qoses) when Qos < 3 ->
    parse_qoses(Rest, [Qos | Qoses]);
parse_qoses(Else, _) ->
    throw({unparsable_as_qos, Else}).

parse_topics(<<>>, Topics) ->
    lists:reverse(Topics);
parse_topics(<<Len:16, Topic:Len/binary, Rest/binary>>, Topics) ->
    parse_topics(Rest, [Topic | Topics]);
parse_topics(Else, _Topics) ->
    throw({unparsable_as_topic, Else}).

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

%% To avoid a bitshift, accept any non-zero value as true
flag(0) -> false;
flag(_) -> true.

qos_flag(Flags) ->
    case (Flags band 2#0110) bsr 1 of
        3 -> throw({invalid_qos_value, 3});
        Q -> Q
    end.

dup_flag(Flags) ->
    flag(Flags band 2#1000).

retain_flag(Flags) ->
    flag(Flags band 2#0001).

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
return_code_to_byte(not_authorised) -> 5.

%% To enforce the type of message_id when parsing arbitrary binaries.
check_message_id(Id) when Id > 0, Id < 16#ffff ->
    ok;
check_message_id(Else) ->
    throw({out_of_bounds_message_id, Else}).


%% --- serialise

-spec(serialise(mqtt_frame()) -> iolist() | binary()).

serialise(#connect{ clean_session = Clean,
                    will = Will,
                    username = Username,
                    password = Password,
                    client_id = ClientId,
                    keep_alive = KeepAlive }) ->
    FixedByte = fixed_byte(?CONNECT),

    WillQos = ?undefined(Will, 0, Will#will.qos),
    WillRetain = ?undefined(Will, false, Will#will.retain),
    WillTopic = ?undefined(Will, undefined, Will#will.topic),
    WillMsg = ?undefined(Will, undefined, Will#will.message),

    Flags = flag_bit(Clean, 1) +
        defined_bit(Will, 2) + %% assume will if topic given
        (WillQos bsl 3) +
        flag_bit(WillRetain, 5) +
        string_bit(Password, 6) +
        string_bit(Username, 7),

    Strings = << <<(size(Str)):16, Str/binary>> ||
                  Str <- [ClientId, WillTopic, WillMsg,
                          Username, Password], is_binary(Str)>>,
    {LenEncoded, LenSize} = encode_length(12 + size(Strings)),
    [<<FixedByte:8,
      LenEncoded:LenSize, %% remaining length
      6:16, "MQIsdp", 3:8, %% protocol name and version
      Flags:8,
      KeepAlive:16>>,
     Strings];

serialise(#connack{ return_code = ReturnCode }) ->
    FixedByte = fixed_byte(?CONNACK),
    <<FixedByte:8,
     2:8, %% always 2
     0:8, %% reserved
     (return_code_to_byte(ReturnCode)):8>>;

serialise(#publish{ dup = Dup, qos = Qos, retain = Retain,
                    topic = Topic,
                    message_id = MessageId,
                    payload = Payload }) ->
    FixedByte = fixed_byte(?PUBLISH, Dup, Qos, Retain),
    TopicSize = size(Topic),
    case Qos of
        0 ->
            MessageId = undefined,
            {Num, Bits} = encode_length(2 + TopicSize +
                                        size(Payload)),
            [<<FixedByte:8, Num:Bits,
              TopicSize:16, Topic/binary>>, Payload];
        _ ->
            {Num, Bits} = encode_length(2 + TopicSize +
                                        2 + %% message id
                                        size(Payload)),
            [<<FixedByte:8, Num:Bits,
              TopicSize:16, Topic/binary,
              MessageId:16>>, Payload]
    end;

serialise(#puback{ message_id = MsgId }) ->
    <<(fixed_byte(?PUBACK)):8, 2:8, MsgId:16>>;
serialise(#pubrec{ message_id = MsgId }) ->
    <<(fixed_byte(?PUBREC)):8, 2:8, MsgId:16>>;
serialise(#pubrel{ dup = Dup, qos = 1, message_id = MsgId }) ->
    <<(fixed_byte(?PUBREL, Dup, 1, false)):8, 2:8, MsgId:16>>;
serialise(#pubcomp{ message_id = MsgId }) ->
    <<(fixed_byte(?PUBCOMP)):8, 2:8, MsgId:16>>;

serialise(#subscribe{ dup = Dup, qos = SubQos,
                      message_id = MessageId,
                      subscriptions = Subs }) ->
    SubsBin = << <<(size(Topic)):16, Topic/binary, Qos:8>> ||
                  #subscription{ topic = Topic,
                                 qos = Qos } <- Subs >>,
    {Num, Bits} = encode_length(2 + size(SubsBin)),
    [<<(fixed_byte(?SUBSCRIBE, Dup, SubQos, false)):8,
      Num:Bits, MessageId:16>>, SubsBin];

serialise(#suback{ message_id = MessageId,
                   qoses = Qoses }) ->
    QosesBin = << <<0:6, Qos:2>> || Qos <- Qoses>>,
    {Num, Bits} = encode_length(2 + size(QosesBin)),
    <<(fixed_byte(?SUBACK)):8, Num:Bits,
     MessageId:16, QosesBin/binary>>;

serialise(#unsubscribe{ message_id = MessageId,
                        qos = Qos,
                        topics = Topics }) ->
    TopicsBin = << <<(size(T)):16, T/binary>> || T <- Topics >>,
    {Num, Bits} = encode_length(2 + size(TopicsBin)),
    [<<(fixed_byte(?UNSUBSCRIBE, false, Qos, false)):8,
      Num:Bits, MessageId:16>>, TopicsBin];

serialise(#unsuback{ message_id = MessageId }) ->
    <<(fixed_byte(?UNSUBACK)):8, 2:8, MessageId:16>>;

serialise(pingreq) ->
    <<?PINGREQ:4, 0:4, 0:8>>;
serialise(pingresp) ->
    <<?PINGRESP:4, 0:4, 0:8>>;
serialise(disconnect) ->
    <<?DISCONNECT:4, 0:4, 0:8>>;

serialise(Else) ->
    throw({unserialisable, Else}).

-type(frame_length() :: 0..268435455).
-type(length_num() :: 0..16#ffffffff).
-type(length_bits() :: 8 | 16 | 24 | 32).

-spec(encode_length(frame_length()) ->
             {length_num(), length_bits()}).
encode_length(L) when L < 16#80 ->
    {L, 8};
encode_length(L) ->
    encode_length(L, 0, 0).

encode_length(0, Bits, Sum) ->
    {Sum, Bits};
encode_length(L, Bits, Sum) ->
    Mod128 = L band 16#7f,
    X = L bsr 7,
    Digit = case X of
                0 -> Mod128;
                _ -> Mod128 bor 16#80
            end,
    encode_length(X, Bits + 8, (Sum bsl 8) + Digit).

%% Many message types use none of the flags: for these, assume default
%% (ignored) values.
fixed_byte(MessageType) ->
    fixed_byte(MessageType, false, 0, false).

fixed_byte(Type, Dup, Qos, Retain) ->
    (Type bsl 4) +
        flag_bit(Dup, 3) +
        (Qos bsl 1) +
        flag_bit(Retain, 0).

flag_bit(false, _)  -> 0;
flag_bit(true, Bit) -> 1 bsl Bit.

string_bit(undefined, _) -> 0;
string_bit(Str, Bit) when is_binary(Str) -> 1 bsl Bit.

defined_bit(undefined, _) -> 0;
defined_bit(_, Bit) -> 1 bsl Bit.

%% ---------- properties

-ifdef(TEST).
-include("include/module_tests.hrl").

encode_length_boundary_test_() ->
    [?_test(?assertEqual({Num, Bits}, encode_length(Len))) ||
        {Len, Num, Bits} <- [{0, 0, 8},
                             {127, 127, 8},
                             {128, 16#8001, 16},
                             {16383, 16#ff7f, 16},
                             {16384, 16#808001, 24},
                             {2097151, 16#ffff7f, 24},
                             {2097152, 16#80808001, 32},
                             {268435455, 16#ffffff7f, 32}]].

prop_return_code() ->
    ?FORALL(Code, mqtt_framing:return_code(),
            begin
                B = return_code_to_byte(Code),
                C = byte_to_return_code(B),
                Code =:= C
            end).

%% NB #connect has a special case because it's difficult to express
%% the type for client ID (a string between 1 and 23 bytes long).
prop_roundtrip_frame() ->
    ?FORALL(Frame, mqtt_frame(),
            ?IMPLIES(case Frame of
                         #connect{ client_id = ClientId } ->
                             size(ClientId) < 24;
                         _ -> true
                     end,
                     begin
                         Ser = iolist_to_binary(serialise(Frame)),
                         {frame, F, <<>>} = start(Ser),
                         F =:= Frame
                     end)).

-endif.
