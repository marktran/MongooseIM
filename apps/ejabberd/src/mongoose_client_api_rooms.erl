-module(mongoose_client_api_rooms).

-export([init/3]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([is_authorized/2]).
-export([allowed_methods/2]).
-export([resource_exists/2]).

-export([to_json/2]).
-export([from_json/2]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include_lib("exml/include/exml.hrl").

%% yes, there is no other option, this API has to run over encrypted connection
init({ssl, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_rest}.

is_authorized(Req, State) ->
    mongoose_client_api:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {[
      {<<"application/json">>, to_json}
     ], Req, State}.

content_types_accepted(Req, State) ->
    {[
      {<<"application/json">>, from_json}
     ], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PUT">>], Req, State}.

resource_exists(Req, {_, #jid{lserver = Server}} = State) ->
    {RoomID, Req2} = cowboy_req:binding(id, Req),
    MUCLightDomain = muc_light_domain(Server),
    case RoomID of
        undefined ->
            {false, Req2, State};
        _ ->
            does_room_exist({RoomID, MUCLightDomain}, Req2, State)
    end.

does_room_exist(RoomUS, Req, State) ->
    case mod_muc_light_db_backend:get_info(RoomUS) of
        {ok, Config, Users, Version} ->
            ?WARNING_MSG("Config: ~p", [Config]),
            ?WARNING_MSG("Users: ~p", [Users]),
            ?WARNING_MSG("Version: ~p", [Version]),
            {true, Req, State};
        _ ->
            {Method, Req2} = cowboy_req:method(Req),
            case Method of
                <<"PUT">> ->
                    {ok, Req3} = cowboy_req:reply(404, Req2),
                    {halt, Req3, State};
                _ ->
                    {false, Req, State}
            end
    end.



to_json(Req, {_User, #jid{lserver = Server}} = State) ->
    {RoomID, Req2} = cowboy_req:binding(id, Req),
    MUCLightDomain = muc_light_domain(Server),
    case mod_muc_light_db_backend:get_info({RoomID, MUCLightDomain}) of
        {ok, Config, Users, _Version} ->
            Resp = #{name => proplists:get_value(roomname, Config),
                     subject => proplists:get_value(subject, Config),
                     participants => [user_to_json(U) || U <- Users]
                    },
            {jiffy:encode(Resp), Req2, State};
        _ ->
            {ok, Req3} = cowboy_req:reply(404, Req2),
            {halt, Req3, State}
    end.

from_json(Req, State) ->
    {Method, Req2} = cowboy_req:method(Req),
    {ok, Body, Req3} = cowboy_req:body(Req2),
    JSONData = jiffy:decode(Body, [return_maps]),
    handle_request(Method, JSONData, Req3, State).

handle_request(<<"POST">>, JSONData, Req,
               {User, #jid{lserver = Server}} = State) ->
    #{<<"name">> := RoomName, <<"subject">> := Subject} = JSONData,
    case mod_muc_light_admin:create_unique_room(Server, RoomName, User, Subject) of
        {error, _} ->
            {false, Req, State};
        Room ->
            RoomJID = jid:from_binary(Room),
            RespBody = #{<<"id">> => RoomJID#jid.luser},
            RespReq = cowboy_req:set_resp_body(jiffy:encode(RespBody), Req),
            {true, RespReq, State}
    end;
handle_request(<<"PUT">>, JSONData, Req,
               {User, #jid{lserver = Server} = From} = State) ->
    #{<<"user">> := UserToInvite} = JSONData,
    {RoomId, Req2} = cowboy_req:binding(id, Req),
    mod_muc_light_admin:invite_to_room_id(Server, RoomId, User, UserToInvite),
    {true, Req2, State}.

user_to_json({UserServer, Role}) ->
    #{user => jid:to_binary(UserServer),
      role => Role}.

muc_light_domain(Server) ->
    gen_mod:get_module_opt_host(Server, mod_muc, <<"muclight.@HOST@">>).

