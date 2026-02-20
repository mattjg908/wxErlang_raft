-module(raftscope_wx_gui).

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").
-include_lib("raftscope_wx/include/raftscope.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_event/2, handle_info/2, terminate/2,
         code_change/3]).
-export([handle_sync_event/3]).

-record(st,
        {frame,
         canvas,
         info_txt,
         btn_run,
         running = true,
         speed = 20,            %% 1..200
         selected = 1,
         model = raftscope:new()}).

-define(ID_RUN, 1001).
-define(ID_STEP, 1002).
-define(ID_CLIENT, 1003).
-define(ID_TIMEOUT, 1004).
-define(ID_STOP, 1005).
-define(ID_RESUME, 1006).
-define(ID_RESTART, 1007).
-define(ID_ALIGN, 1008).
-define(ID_SPREAD, 1009).
-define(ID_SPEED, 1010).

start_link() ->
    %% wx_object:start_link/* returns a wxWindow (wx_ref), not {ok,Pid}.
    %% Supervisors require {ok,Pid}, so we translate the handle -> pid().
    case wx_object:start_link({local, ?MODULE}, ?MODULE, [], []) of
        Obj when is_tuple(Obj), tuple_size(Obj) >= 1, element(1, Obj) =:= wx_ref ->
            {ok, wx_object:get_pid(Obj)};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_wx_object_return, Other}}
    end.

%% Create a wxButton safely on OTP 26:
%% wxButton:new/3 is (Parent, Id, Options). Passing a string as arg#3 causes {badoption,80}.
mk_button(Parent, Id, Label) ->
    B = wxButton:new(Parent, Id, []),
    wxButton:setLabel(B, Label),
    B.

%% Create a wxPanel across wx wrapper variants.
%% Different wx builds expose different constructor signatures, e.g.:
%%   wxPanel:new(Parent, Id, Options)
%%   wxPanel:new(Parent, Options)
%%   wxPanel:new(Parent, Id)
%%   wxPanel:new(Parent)
mk_panel(Parent, Id, Opts) ->
    case try_new(fun() -> wxPanel:new(Parent, Id, Opts) end) of
        {ok, P} ->
            P;
        _ ->
            case try_new(fun() -> wxPanel:new(Parent, Opts) end) of
                {ok, P2} ->
                    P2;
                _ ->
                    case try_new(fun() -> wxPanel:new(Parent, Id) end) of
                        {ok, P3} ->
                            P3;
                        _ ->
                            wxPanel:new(Parent)
                    end
            end
    end.

%% Create a wxTextCtrl across wx wrapper variants.
mk_textctrl(Parent, Id, Value, Opts) ->
    case try_new(fun() -> wxTextCtrl:new(Parent, Id, Value, Opts) end) of
        {ok, T} ->
            T;
        _ ->
            case try_new(fun() -> wxTextCtrl:new(Parent, Id, Opts) end) of
                {ok, T2} ->
                    catch wxTextCtrl:setValue(T2, Value),
                    T2;
                _ ->
                    case try_new(fun() -> wxTextCtrl:new(Parent, Id) end) of
                        {ok, T3} ->
                            catch wxTextCtrl:setValue(T3, Value),
                            T3;
                        _ ->
                            T4 = wxTextCtrl:new(Parent),
                            catch wxTextCtrl:setValue(T4, Value),
                            T4
                    end
            end
    end.

try_new(Fun) ->
    try Fun() of
        P when is_tuple(P), tuple_size(P) >= 1, element(1, P) =:= wx_ref ->
            {ok, P};
        _ ->
            {error, badret}
    catch
        error:undef ->
            {error, undef};
        error:function_clause ->
            {error, function_clause};
        error:badarg ->
            {error, badarg};
        exit:_ ->
            {error, exit}
    end.

%% Ensure the info pane uses a fixed-width font so tabular data aligns.
%% This is UI-only; failures fall back to the default font.
set_info_mono_font(Txt) ->
    %% Prefer a monospace family; exact support varies by platform/wx build.
    FontRes =
        try_new(fun() ->
                   wxFont:new(10, ?wxFONTFAMILY_MODERN, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL)
                end),
    case FontRes of
        {ok, Font} ->
            catch wxWindow:setFont(Txt, Font),
            ok;
        _ ->
            ok
    end.

init([]) ->
    wx:new(),

    %% Slightly larger default window so the info panel can show all details
    %% without needing to scroll.
    Frame =
        wxFrame:new(
            wx:null(), ?wxID_ANY, "raftscope_wx", [{size, {1350, 850}}]),
    Main = mk_panel(Frame, ?wxID_ANY, []),

    Canvas =
        mk_panel(Main, ?wxID_ANY, [{style, ?wxFULL_REPAINT_ON_RESIZE bor ?wxBORDER_NONE}]),
    wxWindow:setBackgroundStyle(Canvas, ?wxBG_STYLE_PAINT),
    Sidebar = mk_panel(Main, ?wxID_ANY, [{style, ?wxBORDER_NONE}]),
    %% Give the sidebar a sensible minimum width so the info pane can remain
    %% readable without constantly scrolling.
    catch wxWindow:setMinSize(Sidebar, {420, -1}),

    %% Layout: Canvas expands, Sidebar fixed-ish.
    MainSizer = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(MainSizer, Canvas, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxSizer:add(MainSizer, Sidebar, [{proportion, 0}, {flag, ?wxEXPAND}]),
    wxWindow:setSizer(Main, MainSizer),

    %% Sidebar layout
    Sizer = wxBoxSizer:new(?wxVERTICAL),

    %% Make the info box larger and allow it to expand to fill remaining
    %% vertical space in the sidebar.
    Info =
        mk_textctrl(Sidebar,
                    ?wxID_ANY,
                    "",
                    [{style, ?wxTE_MULTILINE bor ?wxTE_READONLY bor ?wxTE_DONTWRAP},
                     {size, {420, 520}}]),
    %% Use a fixed-width font in the info pane so the servers table columns
    %% align reliably across platforms.
    set_info_mono_font(Info),
    wxSizer:add(Sizer, Info, [{flag, ?wxEXPAND bor ?wxALL}, {proportion, 1}, {border, 8}]),

    BtnGrid = wxFlexGridSizer:new(0, 2, 6, 6),

    BtnRun = mk_button(Sidebar, ?ID_RUN, "Pause"),
    BtnStep = mk_button(Sidebar, ?ID_STEP, "Step"),
    BtnClient = mk_button(Sidebar, ?ID_CLIENT, "Client req → leader"),
    BtnTimeout = mk_button(Sidebar, ?ID_TIMEOUT, "Timeout (selected)"),
    BtnStop = mk_button(Sidebar, ?ID_STOP, "Stop (selected)"),
    BtnResume = mk_button(Sidebar, ?ID_RESUME, "Resume (selected)"),
    BtnRestart = mk_button(Sidebar, ?ID_RESTART, "Restart (selected)"),
    BtnAlign = mk_button(Sidebar, ?ID_ALIGN, "Align timers"),
    BtnSpread = mk_button(Sidebar, ?ID_SPREAD, "Spread timers"),

    lists:foreach(fun(B) -> wxSizer:add(BtnGrid, B, [{flag, ?wxEXPAND}, {proportion, 1}]) end,
                  [BtnRun,
                   BtnStep,
                   BtnClient,
                   BtnTimeout,
                   BtnStop,
                   BtnResume,
                   BtnRestart,
                   BtnAlign,
                   BtnSpread]),

    wxSizer:add(Sizer,
                BtnGrid,
                [{flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM}, {border, 8}]),

    wxSizer:add(Sizer,
                wxStaticText:new(Sidebar, ?wxID_ANY, "Speed"),
                [{flag, ?wxLEFT bor ?wxRIGHT}, {border, 8}]),
    Speed =
        wxSlider:new(Sidebar,
                     ?ID_SPEED,
                     20,
                     1,
                     200,
                     [{style, ?wxSL_HORIZONTAL bor ?wxSL_VALUE_LABEL}]),
    wxSizer:add(Sizer, Speed, [{flag, ?wxEXPAND bor ?wxALL}, {border, 8}]),

    wxWindow:setSizer(Sidebar, Sizer),

    %% Events
    wxEvtHandler:connect(Frame, close_window),
    wxEvtHandler:connect(Canvas, paint, [callback]),
    wxEvtHandler:connect(Canvas, left_down),
    wxEvtHandler:connect(Canvas, size, [{skip, true}]),

    lists:foreach(fun({Obj, Ev}) -> wxEvtHandler:connect(Obj, Ev) end,
                  [{BtnRun, command_button_clicked},
                   {BtnStep, command_button_clicked},
                   {BtnClient, command_button_clicked},
                   {BtnTimeout, command_button_clicked},
                   {BtnStop, command_button_clicked},
                   {BtnResume, command_button_clicked},
                   {BtnRestart, command_button_clicked},
                   {BtnAlign, command_button_clicked},
                   {BtnSpread, command_button_clicked},
                   {Speed, command_slider_updated}]),

    wxFrame:show(Frame),

    %% Drive simulation via erlang:send_after/3
    _ = erlang:send_after(16, self(), gui_tick),

    St0 = #st{frame = Frame,
              canvas = Canvas,
              info_txt = Info,
              btn_run = BtnRun},

    St1 = refresh_info(St0),
    {Frame, St1}.

handle_call(_Req, _From, St) ->
    {reply, ok, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_event(#wx{event = #wxClose{}}, St) ->
    wxFrame:destroy(St#st.frame),
    {stop, normal, St};
handle_event(#wx{id = ?ID_RUN, event = #wxCommand{type = command_button_clicked}}, St) ->
    Running = not St#st.running,
    Label =
        case Running of
            true ->
                "Pause";
            false ->
                "Run"
        end,
    wxButton:setLabel(St#st.btn_run, Label),
    {noreply, St#st{running = Running}};
handle_event(#wx{id = ?ID_STEP, event = #wxCommand{type = command_button_clicked}}, St) ->
    St1 = do_tick(St),
    {noreply, St1#st{running = false}};
handle_event(#wx{id = ?ID_CLIENT, event = #wxCommand{type = command_button_clicked}},
             St) ->
    St1 = apply_model(St,
                      fun(Model0) ->
                         case raftscope:leader(Model0) of
                             {LeaderId, _Term} ->
                                 raftscope:client_request(Model0, LeaderId);
                             none ->
                                 Model0
                         end
                      end),
    {noreply, St1};
handle_event(#wx{id = ?ID_TIMEOUT, event = #wxCommand{type = command_button_clicked}},
             St) ->
    St1 = apply_model(St, fun(M) -> raftscope:timeout(M, St#st.selected) end),
    {noreply, St1};
handle_event(#wx{id = ?ID_STOP, event = #wxCommand{type = command_button_clicked}}, St) ->
    St1 = apply_model(St, fun(M) -> raftscope:stop(M, St#st.selected) end),
    {noreply, St1};
handle_event(#wx{id = ?ID_RESUME, event = #wxCommand{type = command_button_clicked}},
             St) ->
    St1 = apply_model(St, fun(M) -> raftscope:resume(M, St#st.selected) end),
    {noreply, St1};
handle_event(#wx{id = ?ID_RESTART, event = #wxCommand{type = command_button_clicked}},
             St) ->
    St1 = apply_model(St, fun(M) -> raftscope:restart(M, St#st.selected) end),
    {noreply, St1};
handle_event(#wx{id = ?ID_ALIGN, event = #wxCommand{type = command_button_clicked}},
             St) ->
    St1 = apply_model(St, fun(M) -> raftscope:align_timers(M) end),
    {noreply, St1};
handle_event(#wx{id = ?ID_SPREAD, event = #wxCommand{type = command_button_clicked}},
             St) ->
    St1 = apply_model(St, fun(M) -> raftscope:spread_timers(M) end),
    {noreply, St1};
handle_event(#wx{id = ?ID_SPEED,
                 event = #wxCommand{type = command_slider_updated, commandInt = V}},
             St) ->
    {noreply, St#st{speed = V}};
handle_event(#wx{event =
                     #wxMouse{type = left_down,
                              x = X,
                              y = Y}},
             St) ->
    Sel = pick_server({X, Y}, canvas_geometry(St#st.canvas), St#st.selected),
    St1 = St#st{selected = Sel},
    wxWindow:refresh(St#st.canvas),
    {noreply, refresh_info(St1)};
handle_event(#wx{event = #wxPaint{}}, St) ->
    %% paint is handled in handle_sync_event/3 (callback)
    {noreply, St};
handle_event(_Ev, St) ->
    {noreply, St}.

handle_sync_event(#wx{event = #wxPaint{}}, _WxObj, St) ->
    draw(St),
    ok;
handle_sync_event(_Ev, _WxObj, _St) ->
    ok.

handle_info(gui_tick, St) ->
    _ = erlang:send_after(16, self(), gui_tick),
    St1 = case St#st.running of
              true ->
                  do_tick(St);
              false ->
                  St
          end,
    {noreply, St1};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) ->
    catch wx:destroy(),
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% --- Tick & UI helpers ------------------------------------------------------

apply_model(St, Fun) ->
    Model1 = Fun(St#st.model),
    St1 = St#st{model = Model1},
    wxWindow:refresh(St#st.canvas),
    refresh_info(St1).

do_tick(St) ->
    %% Slow down simulated time so humans can follow RPCs and elections.
    %% We advance 50us * Speed per GUI tick (~16ms wall clock).
    %% With the default Speed=20, that's 1ms of simulated time per frame.
    Delta = 50 * St#st.speed,
    Model1 = raftscope:tick(St#st.model, Delta),
    St1 = St#st{model = Model1},
    wxWindow:refresh(St#st.canvas),
    refresh_info(St1).

refresh_info(St) ->
    #model{time = T,
           servers = Ss,
           messages = Ms} =
        St#st.model,
    Leader0 = raftscope:leader(St#st.model),
    Sel = St#st.selected,
    SelS = lists:nth(Sel, Ss),
    LeaderTxt =
        case Leader0 of
            none ->
                "none";
            {LId, LTerm} ->
                lists:flatten(
                    io_lib:format("S~p (term ~p)", [LId, LTerm]))
        end,
    Txt =
        io_lib:format("time: ~p us~nleader: ~s~nmessages_in_flight: ~p~n~nselected: S~p~nstate: ~p~nterm: ~p~nvoted_for: ~p~nlog_len: ~p~ncommit_index: ~p~nelection_due_in: ~p us~n~nservers:~n~s",
                      [T,
                       LeaderTxt,
                       length(Ms),
                       Sel,
                       SelS#server.state,
                       SelS#server.term,
                       SelS#server.voted_for,
                       length(SelS#server.log),
                       SelS#server.commit_index,
                       erlang:max(0, SelS#server.election_alarm - T),
                       servers_summary(Ss, T)]),
    wxTextCtrl:setValue(St#st.info_txt, lists:flatten(Txt)),
    St.

servers_summary(Ss, Now) ->
    %% Use fixed-width string columns (rendered with a monospace font) so all
    %% values land under their respective headers.
    %% NOTE: keep the elect_due(us) column wide enough for the header itself
    %% (length 13) so data stays directly under the header.
    Fmt = "  ~-4s ~-10s ~4s ~4s ~3s ~6s ~13s~n",
    Header =
        io_lib:format(Fmt, ["id", "state", "term", "vote", "log", "commit", "elect_due(us)"]),
    Rows =
        lists:map(fun(S) ->
                     Id = lists:flatten(
                              io_lib:format("S~p", [S#server.id])),
                     State = atom_to_list(S#server.state),
                     Term = integer_to_list(S#server.term),
                     Vote =
                         case S#server.voted_for of
                             undefined ->
                                 "-";
                             V when is_integer(V) ->
                                 integer_to_list(V);
                             V ->
                                 lists:flatten(
                                     io_lib:format("~p", [V]))
                         end,
                     LogLen = integer_to_list(length(S#server.log)),
                     Commit = integer_to_list(S#server.commit_index),
                     ElectDue =
                         case S#server.state of
                             leader ->
                                 "**********";
                             _ ->
                                 case S#server.election_alarm of
                                     A when A >= ?INF ->
                                         "**********";
                                     _ ->
                                         integer_to_list(erlang:max(0,
                                                                    S#server.election_alarm - Now))
                                 end
                         end,
                     io_lib:format(Fmt, [Id, State, Term, Vote, LogLen, Commit, ElectDue])
                  end,
                  Ss),
    lists:flatten([Header | Rows]).

%% --- Drawing ----------------------------------------------------------------

%% wxDC API arities differ across OTP versions.  OTP 26 on some platforms only
%% provides tuple-based drawing calls (e.g. drawLine/3) rather than drawLine/5.
%% These helpers try the common arities and fall back without crashing.
-define(WARN_KEY(Op, Arity), {draw_op_missing, Op, Arity}).

warn_once(Op, Arity) ->
    Key = ?WARN_KEY(Op, Arity),
    case persistent_term:get(Key, false) of
        true ->
            ok;
        false ->
            persistent_term:put(Key, true),
            logger:warning("missing draw op ~p/~p", [Op, Arity])
    end.

to_text(S) when is_list(S) ->
    S;
to_text(S) when is_binary(S) ->
    binary_to_list(S);
to_text(S) ->
    io_lib:format("~ts", [S]).

dc_setBackground(DC, Brush) ->
    catch wxDC:setBackground(DC, Brush),
    ok.

dc_clear(DC) ->
    case erlang:function_exported(wxDC, clear, 1) of
        true ->
            _ = (catch wxDC:clear(DC));
        false ->
            warn_once(clear, 1)
    end,
    ok.

dc_setPen(DC, Pen) ->
    catch wxDC:setPen(DC, Pen),
    ok.

dc_setBrush(DC, Brush) ->
    catch wxDC:setBrush(DC, Brush),
    ok.

dc_setTextForeground(DC, Col) ->
    case erlang:function_exported(wxDC, setTextForeground, 2) of
        true ->
            _ = (catch wxDC:setTextForeground(DC, Col));
        false ->
            warn_once(setTextForeground, 2)
    end,
    ok.

dc_drawLine(DC, X1, Y1, X2, Y2) ->
    case erlang:function_exported(wxDC, drawLine, 5) of
        true ->
            case catch wxDC:drawLine(DC, X1, Y1, X2, Y2) of
                {'EXIT', _} ->
                    dc_drawLine_tuple(DC, X1, Y1, X2, Y2);
                _ ->
                    ok
            end;
        false ->
            dc_drawLine_tuple(DC, X1, Y1, X2, Y2)
    end.

dc_drawLine_tuple(DC, X1, Y1, X2, Y2) ->
    case erlang:function_exported(wxDC, drawLine, 3) of
        true ->
            _ = (catch wxDC:drawLine(DC, {X1, Y1}, {X2, Y2}));
        false ->
            warn_once(drawLine, 3)
    end,
    ok.

dc_drawCircle(DC, X, Y, R) ->
    case erlang:function_exported(wxDC, drawCircle, 4) of
        true ->
            case catch wxDC:drawCircle(DC, X, Y, R) of
                {'EXIT', _} ->
                    dc_drawCircle_tuple(DC, X, Y, R);
                _ ->
                    ok
            end;
        false ->
            dc_drawCircle_tuple(DC, X, Y, R)
    end.

dc_drawCircle_tuple(DC, X, Y, R) ->
    case erlang:function_exported(wxDC, drawCircle, 3) of
        true ->
            _ = (catch wxDC:drawCircle(DC, {X, Y}, R));
        false ->
            warn_once(drawCircle, 3)
    end,
    ok.

dc_drawRectangle(DC, X, Y, W, H) ->
    case erlang:function_exported(wxDC, drawRectangle, 5) of
        true ->
            case catch wxDC:drawRectangle(DC, X, Y, W, H) of
                {'EXIT', _} ->
                    dc_drawRectangle_tuple(DC, X, Y, W, H);
                _ ->
                    ok
            end;
        false ->
            dc_drawRectangle_tuple(DC, X, Y, W, H)
    end.

dc_drawRectangle_tuple(DC, X, Y, W, H) ->
    case erlang:function_exported(wxDC, drawRectangle, 3) of
        true ->
            _ = (catch wxDC:drawRectangle(DC, {X, Y, W, H}));
        false ->
            warn_once(drawRectangle, 3)
    end,
    ok.

dc_drawText(DC, Str0, X, Y) ->
    Str = to_text(Str0),
    case erlang:function_exported(wxDC, drawText, 4) of
        true ->
            case catch wxDC:drawText(DC, Str, X, Y) of
                {'EXIT', _} ->
                    dc_drawText_tuple(DC, Str, X, Y);
                _ ->
                    ok
            end;
        false ->
            dc_drawText_tuple(DC, Str, X, Y)
    end.

dc_drawText_tuple(DC, Str, X, Y) ->
    case erlang:function_exported(wxDC, drawText, 3) of
        true ->
            _ = (catch wxDC:drawText(DC, Str, {X, Y}));
        false ->
            warn_once(drawText, 3)
    end,
    ok.

draw(St) ->
    Canvas = St#st.canvas,
    DC = wxPaintDC:new(Canvas),
    try
        {_W, _H, CX, CY, R} = canvas_geometry(Canvas),

        %% Background
        dc_setBackground(DC, wxBrush:new({245, 245, 245})),
        dc_clear(DC),

        Positions = server_positions(CX, CY, R),

        draw_links(DC, Positions),
        draw_messages(DC, St#st.model, Positions),
        draw_servers(DC, St#st.model, Positions, St#st.selected)
    after
        wxPaintDC:destroy(DC)
    end.

canvas_geometry(Canvas) ->
    {W, H} = wxWindow:getClientSize(Canvas),
    CX = W div 2,
    CY = H div 2,
    R = erlang:min(W, H) div 3,
    {W, H, CX, CY, R}.

server_positions(CX, CY, R) ->
    N = ?NUM_SERVERS,
    lists:foldl(fun(I, Acc) ->
                   Angle = 2.0 * math:pi() * (I - 1) / N - math:pi() / 2,
                   X = CX + trunc(R * math:cos(Angle)),
                   Y = CY + trunc(R * math:sin(Angle)),
                   maps:put(I, {X, Y}, Acc)
                end,
                #{},
                lists:seq(1, N)).

draw_links(DC, Positions) ->
    dc_setPen(DC, wxPen:new({210, 210, 210}, [{width, 1}])),
    lists:foreach(fun(I) ->
                     {X1, Y1} = maps:get(I, Positions),
                     lists:foreach(fun(J) ->
                                      if J > I ->
                                             {X2, Y2} = maps:get(J, Positions),
                                             dc_drawLine(DC, X1, Y1, X2, Y2);
                                         true ->
                                             ok
                                      end
                                   end,
                                   lists:seq(1, ?NUM_SERVERS))
                  end,
                  lists:seq(1, ?NUM_SERVERS)).

draw_messages(DC, #model{time = Now, messages = Ms}, Positions) ->
    SolidPen = wxPen:new({60, 60, 60}, [{width, 1}]),
    SolidBrush = wxBrush:new({60, 60, 60}),
    %% RaftScope uses a circled-plus glyph for successful replies.
    OutlinePen = wxPen:new({60, 60, 60}, [{width, 1}]),
    %% Use the canvas background color as the fill so this works across
    %% wx/OTP builds without depending on a transparent-brush constant.
    HollowBrush = wxBrush:new({245, 245, 245}),
    lists:foreach(fun(Msg) ->
                     From = maps:get(from, Msg),
                     To = maps:get(to, Msg),
                     Send = maps:get(send_time, Msg),
                     Recv = maps:get(recv_time, Msg),
                     case Recv =:= Send of
                         true ->
                             ok;
                         false ->
                             P = (Now - Send) / (Recv - Send),
                             P2 = clamp(P, 0.0, 1.0),
                             {X1, Y1} = maps:get(From, Positions),
                             {X2, Y2} = maps:get(To, Positions),
                             X = trunc(X1 + (X2 - X1) * P2),
                             Y = trunc(Y1 + (Y2 - Y1) * P2),
                             case is_success_reply(Msg) of
                                 true ->
                                     dc_setPen(DC, OutlinePen),
                                     dc_setBrush(DC, HollowBrush),
                                     dc_drawCircle(DC, X, Y, 5),
                                     draw_plus(DC, X, Y, 3);
                                 false ->
                                     dc_setPen(DC, SolidPen),
                                     dc_setBrush(DC, SolidBrush),
                                     dc_drawCircle(DC, X, Y, 4)
                             end
                     end
                  end,
                  Ms).

is_success_reply(Msg) ->
    maps:get(direction, Msg, request) =:= reply
    andalso case maps:get(type, Msg, undefined) of
                request_vote ->
                    maps:get(granted, Msg, false) =:= true;
                append_entries ->
                    maps:get(success, Msg, false) =:= true;
                _ ->
                    false
            end.

draw_plus(DC, X, Y, HalfLen) ->
    dc_drawLine(DC, X - HalfLen, Y, X + HalfLen, Y),
    dc_drawLine(DC, X, Y - HalfLen, X, Y + HalfLen).

draw_servers(DC, #model{time = Now, servers = Ss}, Positions, Selected) ->
    VisibleLeader = choose_visible_leader(Ss),
    lists:foreach(fun(S) ->
                     Id = S#server.id,
                     {X, Y} = maps:get(Id, Positions),
                     Radius = 32,
                     State0 = S#server.state,
                     State =
                         case State0 of
                             leader when VisibleLeader =:= Id ->
                                 leader;
                             leader ->
                                 follower;
                             Other ->
                                 Other
                         end,
                     {Fill, Outline, PenW} = server_style(State, Id =:= Selected),
                     dc_setPen(DC, wxPen:new(Outline, [{width, PenW}])),
                     dc_setBrush(DC, wxBrush:new(Fill)),
                     dc_drawCircle(DC, X, Y, Radius),

                     maybe_draw_stopped_overlay(DC, State0, X, Y, Radius),
                     maybe_draw_countdown_arc(DC, S, State, Now, X, Y, Radius, PenW),

                     %% Labels (closer to the RaftScope demo)
                     dc_setTextForeground(DC, {20, 20, 20}),
                     dc_drawText(DC, io_lib:format("S~p", [Id]), X - 10, Y - Radius - 18),
                     dc_drawText(DC, io_lib:format("~p", [S#server.term]), X - 6, Y - 8),
                     dc_drawText(DC, role_short(State0), X - 4, Y + 10),

                     %% Leader hint
                     case State0 of
                         leader when VisibleLeader =:= Id ->
                             dc_drawText(DC, "L", X - 4, Y - Radius - 34);
                         _ ->
                             ok
                     end,

                     draw_log(DC, S, X, Y + 50)
                  end,
                  Ss).

choose_visible_leader(Ss) ->
    Leaders = [S || S <- Ss, S#server.state =:= leader],
    case Leaders of
        [] ->
            none;
        _ ->
            MaxTerm = lists:max([S#server.term || S <- Leaders]),
            Cand = [S || S <- Leaders, S#server.term =:= MaxTerm],
            lists:min([S#server.id || S <- Cand])
    end.

server_style(State, IsSelected) ->
    %% {Fill, Outline, PenWidth}
    FillFollower = {150, 180, 230},
    FillCandidate = {245, 230, 170},
    FillLeader = {190, 160, 240},
    Fill =
        case State of
            stopped ->
                {190, 190, 190};
            leader ->
                FillLeader;
            candidate ->
                FillCandidate;
            _ ->
                FillFollower
        end,

    {Outline, W0} =
        case State of
            leader ->
                {{110, 110, 110}, 2};
            candidate ->
                {{80, 80, 80}, 3};
            follower ->
                {{110, 110, 110}, 2};
            stopped ->
                {{160, 0, 0}, 3};
            _ ->
                {{110, 110, 110}, 2}
        end,

    {Outline2, W1} =
        case IsSelected of
            true ->
                {{0, 0, 0}, erlang:max(6, W0)};
            false ->
                {Outline, W0}
        end,
    {Fill, Outline2, W1}.

maybe_draw_stopped_overlay(DC, State0, X, Y, Radius) ->
    case State0 of
        stopped ->
            dc_setPen(DC, wxPen:new({160, 0, 0}, [{width, 3}])),
            dc_drawLine(DC, X - Radius + 6, Y - Radius + 6, X + Radius - 6, Y + Radius - 6),
            dc_drawLine(DC, X - Radius + 6, Y + Radius - 6, X + Radius - 6, Y - Radius + 6),
            ok;
        _ ->
            ok
    end.

maybe_draw_countdown_arc(DC, S, State, Now, X, Y, Radius, PenW) ->
    case countdown_spec(S, State, Now) of
        none ->
            ok;
        {Frac, Col, W} when Frac =< 0.0 ->
            _ = {Col, W},
            ok;
        {Frac, Col, W} ->
            R2 = Radius - erlang:max(2, PenW div 2) - 1,
            dc_setPen(DC, wxPen:new(Col, [{width, W}])),
            draw_progress_arc(DC, X, Y, R2, Frac)
    end.

countdown_spec(S, State, Now) ->
    case State of
        stopped ->
            none;
        leader ->
            case leader_next_due(S, Now) of
                none ->
                    none;
                {Due, Period} ->
                    Frac = fraction(Now, Due - Period, Period),
                    {Frac, {70, 70, 70}, 4}
            end;
        candidate ->
            case candidate_next_due(S, Now) of
                none ->
                    none;
                {_Due, Start, Period} ->
                    Frac = fraction(Now, Start, Period),
                    {Frac, {70, 70, 70}, 4}
            end;
        _ ->
            case election_next_due(S, Now) of
                none ->
                    none;
                {_Due, Start, Period} ->
                    Frac = fraction(Now, Start, Period),
                    {Frac, {70, 70, 70}, 4}
            end
    end.

election_next_due(S, _Now) ->
    Due = S#server.election_alarm,
    Start = S#server.election_start,
    Period = S#server.election_timeout,
    case Due =:= ?INF orelse Period =:= 0 of
        true ->
            none;
        false ->
            {Due, Start, erlang:max(1, Period)}
    end.

candidate_next_due(S, Now) ->
    RpcDue0 = min_map_value(S#server.rpc_due),
    RpcCand =
        case RpcDue0 of
            none ->
                none;
            RpcDue ->
                {RpcDue, RpcDue - ?RPC_TIMEOUT, ?RPC_TIMEOUT}
        end,
    ElectCand = election_next_due(S, Now),
    pick_earlier3(RpcCand, ElectCand).

pick_earlier3(none, Best) ->
    Best;
pick_earlier3(Cand, none) ->
    Cand;
pick_earlier3({Due, _Start, _Period} = Cand, {BestDue, _BestStart, _BestPeriod} = Best) ->
    case Due < BestDue of
        true ->
            Cand;
        false ->
            Best
    end.

leader_next_due(S, _Now) ->
    LogLen = length(S#server.log),
    Peers = S#server.peers,
    HbPeriod = ?ELECTION_TIMEOUT div 2,
    lists:foldl(fun(Peer, Best) ->
                   HbDue = maps:get(Peer, S#server.heartbeat_due, ?INF),
                   NextIdx = maps:get(Peer, S#server.next_index, LogLen + 1),
                   RpcDue = maps:get(Peer, S#server.rpc_due, ?INF),
                   NeedsReplicate = NextIdx =< LogLen,
                   {Due, Period} =
                       case NeedsReplicate of
                           true ->
                               if HbDue =< RpcDue ->
                                      {HbDue, HbPeriod};
                                  true ->
                                      {RpcDue, ?RPC_TIMEOUT}
                               end;
                           false ->
                               {HbDue, HbPeriod}
                       end,
                   pick_earlier({Due, Period}, Best)
                end,
                none,
                Peers).

pick_earlier({Due, _Period}, Best) when Due =:= none; Due =:= ?INF ->
    Best;
pick_earlier(Cand, none) ->
    Cand;
pick_earlier({Due, _Period} = Cand, {BestDue, _BestPeriod} = Best) ->
    case Due < BestDue of
        true ->
            Cand;
        false ->
            Best
    end.

min_map_value(Map) ->
    Vs = [V || V <- maps:values(Map), V =/= ?INF],
    case Vs of
        [] ->
            none;
        _ ->
            lists:min(Vs)
    end.

fraction(Now, Start0, Period0) ->
    Period = erlang:max(1, Period0),
    Start = erlang:max(0, Start0),
    clamp((Now - Start) / Period, 0.0, 1.0).

draw_progress_arc(_DC, _X, _Y, _R, Frac) when Frac =< 0.0 ->
    ok;
draw_progress_arc(DC, X, Y, R, Frac0) ->
    Frac = clamp(Frac0, 0.0, 1.0),
    StartA = -math:pi() / 2,
    EndA = StartA + 2.0 * math:pi() * Frac,
    Steps = erlang:max(6, trunc(64 * Frac)),
    Step = (EndA - StartA) / Steps,
    {X0, Y0} = arc_point(X, Y, R, StartA),
    lists:foldl(fun(I, {PX, PY}) ->
                   A = StartA + Step * I,
                   {NX, NY} = arc_point(X, Y, R, A),
                   dc_drawLine(DC, PX, PY, NX, NY),
                   {NX, NY}
                end,
                {X0, Y0},
                lists:seq(1, Steps)),
    ok.

arc_point(CX, CY, R, A) ->
    X = CX + trunc(R * math:cos(A)),
    Y = CY + trunc(R * math:sin(A)),
    {X, Y}.

draw_log(DC, S, X, Y0) ->
    Log = S#server.log,
    LogLen = length(Log),
    Commit = S#server.commit_index,
    MaxShow = 16,
    Show =
        case LogLen of
            0 ->
                [];
            _ ->
                lists:sublist(Log, erlang:max(1, LogLen - MaxShow + 1), erlang:min(MaxShow, LogLen))
        end,
    ShowLen = length(Show),
    BaseIndex = LogLen - ShowLen,
    StartX = X - 8 * MaxShow,
    BoxW = 10,
    BoxH = 10,
    lists:foreach(fun({Entry, K}) ->
                     Term = Entry#entry.term,
                     Col = term_color(Term),
                     dc_setPen(DC, wxPen:new({120, 120, 120}, [{width, 1}])),
                     dc_setBrush(DC, wxBrush:new(Col)),
                     Xi = StartX + (K - 1) * BoxW,
                     dc_drawRectangle(DC, Xi, Y0, BoxW - 1, BoxH - 1),
                     Index = BaseIndex + K,
                     case Index =< Commit andalso Commit > 0 of
                         true ->
                             dc_setPen(DC, wxPen:new({0, 0, 0}, [{width, 1}])),
                             dc_drawLine(DC, Xi, Y0 + BoxH + 2, Xi + BoxW - 2, Y0 + BoxH + 2);
                         false ->
                             ok
                     end
                  end,
                  lists:zip(Show, lists:seq(1, ShowLen))).

role_short(leader) ->
    "L";
role_short(candidate) ->
    "C";
role_short(follower) ->
    "F";
role_short(stopped) ->
    "X";
role_short(_) ->
    "?".

term_color(Term) ->
    case Term rem 6 of
        0 ->
            {180, 200, 240};
        1 ->
            {240, 180, 180};
        2 ->
            {180, 240, 200};
        3 ->
            {240, 220, 160};
        4 ->
            {220, 180, 240};
        5 ->
            {180, 240, 240}
    end.

clamp(V, Lo, _Hi) when V < Lo ->
    Lo;
clamp(V, _Lo, Hi) when V > Hi ->
    Hi;
clamp(V, _Lo, _Hi) ->
    V.

pick_server({X, Y}, {W, H, CX, CY, R}, DefaultSelected) ->
    _ = {W, H},
    Positions = server_positions(CX, CY, R),
    Th = 40,
    {BestId, _BestD} =
        lists:foldl(fun(I, {Best, BestD}) ->
                       {Xi, Yi} = maps:get(I, Positions),
                       D = dist2(X, Y, Xi, Yi),
                       if D < BestD ->
                              {I, D};
                          true ->
                              {Best, BestD}
                       end
                    end,
                    {DefaultSelected, 1.0e18},
                    lists:seq(1, ?NUM_SERVERS)),
    {Bx, By} = maps:get(BestId, Positions),
    case dist2(X, Y, Bx, By) =< Th * Th of
        true ->
            BestId;
        false ->
            DefaultSelected
    end.

dist2(X1, Y1, X2, Y2) ->
    DX = X1 - X2,
    DY = Y1 - Y2,
    DX * DX + DY * DY.
