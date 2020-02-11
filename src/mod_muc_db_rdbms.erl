-module(mod_muc_db_rdbms).
-include("mod_muc.hrl").
-include("mongoose_logger.hrl").

-export([init/2,
         store_room/4,
         restore_room/3,
         forget_room/3,
         get_rooms/2,
         can_use_nick/4,
         get_nick/3,
         set_nick/4,
         unset_nick/3
        ]).

-define(ESC(T), mongoose_rdbms:use_escaped_string(mongoose_rdbms:escape_string(T))).

%% Defines which RDBMS pool to use
%% Parent host of the MUC service
-type server_host() :: ejabberd:server().

%% Host of MUC service
-type muc_host() :: ejabberd:server().

%% User's JID. Can be on another domain accessable over FED.
%% Only bare part (user@host) is important.
-type client_jid() :: ejabberd:jid().

-type room_opts() :: [{OptionName :: atom(), OptionValue :: term()}].

-type aff() :: atom().


%% ------------------------ Conversions ------------------------

-spec aff_atom2db(aff()) -> string().
aff_atom2db(owner) -> "1";
aff_atom2db({owner, _}) -> "1";
aff_atom2db(member) -> "2";
aff_atom2db({member, _}) -> "2".

-spec aff_db2atom(binary() | pos_integer()) -> aff().
aff_db2atom(1) -> owner;
aff_db2atom(2) -> member;
aff_db2atom(Bin) -> aff_db2atom(mongoose_rdbms:result_to_integer(Bin)).

-spec bin(integer() | binary()) -> binary().
bin(Int) when is_integer(Int) -> integer_to_binary(Int);
bin(Bin) when is_binary(Bin) -> Bin.

-spec init(server_host(), ModuleOpts :: list()) -> ok.
init(_ServerHost, _Opts) ->
    ok.

-spec store_room(server_host(), muc_host(), mod_muc:room(), room_opts()) ->
    ok | {error, term()}.
store_room(ServerHost, MucHost, RoomName, Opts) ->
    Affs = proplists:get_value(affiliations, Opts),
    % ?WARNING_MSG("AFFS: ~p", [Affs]),
    NewOpts = proplists:delete(affiliations, Opts),
    EncodedOpts = jiffy:encode({NewOpts}),
    {atomic, Res}
        = mongoose_rdbms:sql_transaction(
            ServerHost, fun() ->
                store_room_transaction(ServerHost, MucHost, RoomName, EncodedOpts, Affs) end),

    Test = mongoose_rdbms:sql_query(ServerHost, select_opts(MucHost, RoomName)),
    ?WARNING_MSG("Test Select Options: ~p", [Test]),
    Res.

store_room_transaction(ServerHost, MucHost, RoomName, Opts, Affs) ->
    case catch mongoose_rdbms:sql_query(ServerHost, insert_room(MucHost, RoomName, Opts)) of
        {aborted, Reason} ->
            mongoose_rdbms:sql_query_t("ROLLBACK;"),
            {error, Reason};
        {updated, _ } ->
            {selected, [{RoomID}| _Rest] = _AllIds} = mongoose_rdbms:sql_query_t(
                                          select_room_id(MucHost, RoomName)),
            store_aff(ServerHost, RoomID, Affs),
            ok;
        {error, Reason} -> {error, Reason}
    end.

store_aff(_, _, undefined) ->
     ok;
store_aff(ServerHost, RoomID, Affs) ->
    lists:foreach(
              fun({{UserU, UserS, _Role}, Aff}) ->
                      {updated, _}
                      = mongoose_rdbms:sql_query(
                          ServerHost, insert_aff(RoomID, UserU, UserS, Aff))
              end, Affs).
    % Test = mongoose_rdbms:sql_query(ServerHost, ["SELECT * FROM muc_room_aff"]),
    % ?WARNING_MSG("ServerHost: ~p, ~nAfiliations Table: ~p", [ServerHost,  Test]).



-spec restore_room(server_host(), muc_host(), mod_muc:room()) ->
    {ok, room_opts()} | {error, room_not_found} | {error, term()}.
restore_room(ServerHost, MucHost, RoomName) ->
    SelectOpts = select_opts(MucHost,RoomName),
    ?WARNING_MSG("Select opts: ~p", [SelectOpts]),
    Res = mongoose_rdbms:sql_query_t(SelectOpts),
    {selected, Opts} = Res,
    ?WARNING_MSG("Res: ~p, Host:~p, RoomName~p", [Res, MucHost, RoomName]),

    Test2 = mongoose_rdbms:sql_query(ServerHost, ["SELECT * FROM muc_rooms"]),
    ?WARNING_MSG("Test2: ~p", [Test2]),

    {selected, [{RoomID} | _Rest] = _AllIds} = mongoose_rdbms:sql_query_t(
         select_room_id(MucHost, RoomName)),
    ResAff = mongoose_rdbms:sql_query_t(select_aff(RoomID)),
    case {Opts, ResAff} of
        {[], {selected, []}} ->
            {error, room_not_found};
        {[], {selected, [_]}} ->
            {error, room_not_found};
        {[Options], {selected, Affs}} ->
            DecodedOpts = jiffy:decode(Options),
            ?WARNING_MSG("Decoded Opts: ~p", [DecodedOpts]),
            AffsList = [{{UserU, UserS, <<>>}, aff_db2atom(Aff)} || {UserU, UserS, Aff} <- Affs],
            NewDecodedOpts = proplists:append_values(AffsList, DecodedOpts),
            {ok, NewDecodedOpts}
    end.

-spec forget_room(server_host(), muc_host(), mod_muc:room()) ->
    ok | {error, term()}.
forget_room(ServerHost, MucHost, RoomName) ->
    {atomic, _Res}
        = mongoose_rdbms:sql_transaction(ServerHost,
            fun() -> forget_room_transaction(MucHost, RoomName) end),
    ok.

forget_room_transaction(MucHost, RoomName) ->
    case mongoose_rdbms:sql_query_t(select_room_id(MucHost, RoomName)) of
        {selected, [{RoomID}]} ->
            {updated, _} = mongoose_rdbms:sql_query_t(delete_affs(RoomID)),
            {updated, _} = mongoose_rdbms:sql_query_t(delete_room(MucHost, RoomName)),
            ok;
        {selected, []} ->
            {error, not_exists}
    end.


-spec get_rooms(server_host(), muc_host()) -> {ok, [#muc_room{}]} | {error, term()}.
get_rooms(_ServerHost, MucHost) ->
    SelectRooms = select_rooms(MucHost),
    case mongoose_rdbms:sql_query_t(SelectRooms) of
            {selected, [Rooms]} ->
                {ok, Rooms};
            {selected, []} ->
                {error, not_exists}
        end.

-spec can_use_nick(server_host(), muc_host(), client_jid(), mod_muc:nick()) -> boolean().
can_use_nick(ServerHost, MucHost, Jid, Nick) ->
    {UserU, UserS} = jid:to_lus(Jid),
    SelectQuery = select_nick_user(MucHost, UserS, Nick),
    case mongoose_rdbms:sql_query(ServerHost, SelectQuery) of
        {selected, []} -> true;
        {selected, [U]} -> U == UserU
    end.

%% Get nick associated with jid client_jid() across muc_host() domain
-spec get_nick(server_host(), muc_host(), client_jid()) ->
    {ok, mod_muc:nick()} | {error, not_registered} | {error, term()}.
get_nick(ServerHost, MucHost, Jid) ->
    {UserU, UserS} = jid:to_lus(Jid),
    SelectQuery = select_nick(MucHost, UserU, UserS),
    case mongoose_rdbms:sql_query(ServerHost, SelectQuery) of
        {selected, []} -> {error, not_registered};
        {selected, [Nick]} -> {ok, Nick}
    end.

%% Register nick
-spec set_nick(server_host(), muc_host(), client_jid(), mod_muc:nick()) ->
    ok | {error, conflict} | {error, term()}.
set_nick(ServerHost, MucHost, Jid, Nick) when is_binary(Nick), Nick =/= <<>> ->
    CanUseNick = can_use_nick(ServerHost, MucHost, Jid, Nick),
   {atomic, Res}
        = mongoose_rdbms:sql_transaction(
            ServerHost, fun() ->
                store_nick_transaction(ServerHost, MucHost, Jid, Nick, CanUseNick) end),
    Res.

store_nick_transaction(_ServerHost, _MucHost, _Jid, _Nick, false) ->
    {error, conflict};
store_nick_transaction(ServerHost, MucHost, Jid, Nick, true) ->
    LUS = jid:to_lus(Jid),
    case catch mongoose_rdbms:sql_query(ServerHost, insert_nick( MucHost, LUS, Nick)) of
            {aborted, Reason} ->
                    mongoose_rdbms:sql_query_t("ROLLBACK;"),
                    ?ERROR_MSG("event=set_nick_failed jid=~ts nick=~ts reason=~1000p",
                         [jid:to_binary(Jid), Nick, Reason]),
                    {error, Reason};
            {updated, _ } ->
                ok
    end.

%% Unregister nick
%% Unregistered nicks can be used by someone else
-spec unset_nick(server_host(), muc_host(), client_jid()) ->
    ok | {error, term()}.
unset_nick(ServerHost, MucHost, Jid) ->
    {UserU, UserS} = jid:to_lus(Jid),
    mongoose_rdbms:sql_query(ServerHost, delete_nick(MucHost, UserU, UserS)).

insert_room(MucHost, RoomName, Opts) ->
    ["INSERT INTO muc_rooms (muc_host, room, options)"
     " VALUES (", ?ESC(MucHost), ", ", ?ESC(RoomName), ",", ?ESC(Opts) ,")"].

-spec insert_aff(RoomID :: integer() | binary(), UserU :: jid:luser(),
                 UserS :: jid:lserver(), Aff :: aff()) -> iolist().
insert_aff(RoomID, UserU, UserS, Aff) ->
    ["INSERT INTO muc_room_aff (room_id, luser, lserver, aff)"
     " VALUES(", bin(RoomID), ", ", ?ESC(UserU), ", ", ?ESC(UserS), ", ",
              aff_atom2db(Aff), ")"].

select_aff(RoomID) ->
    ["SELECT luser, lserver, aff FROM muc_room_aff WHERE room_id = ", ?ESC(RoomID)].

select_room_id(MucHost, RoomName) ->
    ["SELECT id FROM muc_rooms WHERE muc_host = ", ?ESC(MucHost),
    " AND room = ", ?ESC(RoomName)].

select_opts(MucHost, RoomName) ->
    ["SELECT options FROM muc_rooms WHERE muc_host = ", ?ESC(MucHost),
    " AND room = ", ?ESC(RoomName)].

delete_affs(RoomID) ->
     ["DELETE FROM muc_room_aff WHERE room_id = ", bin(RoomID)].

delete_room(MucHost, RoomName) ->
    ["DELETE FROM muc_rooms"
     " WHERE muc_host = ", ?ESC(MucHost), " AND room = ", ?ESC(RoomName)].

select_rooms(MucHost) ->
    ["SELECT room FROM muc_rooms WHERE muc_host = ", ?ESC(MucHost)].

insert_nick(MucHost, {UserU, UserS}, Nick) ->
    ["INSERT INTO muc_registered (muc_host, luser, lserver, nick)"
     " VALUES (", ?ESC(MucHost), ", ", ?ESC(UserU), ",", ?ESC(UserS), ",", ?ESC(Nick), ")"].

select_nick_user(MucHost, UserS, Nick) ->
    ["SELECT luser FROM muc_registered WHERE muc_host = ", ?ESC(MucHost),
    " AND lserver = ", ?ESC(UserS), "AND nick =", ?ESC(Nick)].

select_nick(MucHost, UserU, UserS) ->
    ["SELECT nick FROM muc_registered WHERE muc_host = ", ?ESC(MucHost),
    " AND luser = ", ?ESC(UserU), "AND lserver =", ?ESC(UserS)].

delete_nick(MucHost, UserU, UserS) ->
       ["DELETE FROM muc_registered WHERE muc_host = ", ?ESC(MucHost),
         " AND luser = ", ?ESC(UserU), "AND lserver =", ?ESC(UserS)].


