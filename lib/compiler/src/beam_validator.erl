%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2004-2018. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%

-module(beam_validator).

-compile({no_auto_import,[min/2]}).

%% Avoid warning for local function error/1 clashing with autoimported BIF.
-compile({no_auto_import,[error/1]}).

%% Interface for compiler.
-export([module/2, format_error/1]).

-import(lists, [any/2,dropwhile/2,foldl/3,map/2,foreach/2,reverse/1]).

%% To be called by the compiler.

-spec module(beam_utils:module_code(), [compile:option()]) ->
                    {'ok',beam_utils:module_code()}.

module({Mod,Exp,Attr,Fs,Lc}=Code, _Opts)
  when is_atom(Mod), is_list(Exp), is_list(Attr), is_integer(Lc) ->
    case validate(Mod, Fs) of
	[] ->
	    {ok,Code};
	Es0 ->
	    Es = [{?MODULE,E} || E <- Es0],
	    {error,[{atom_to_list(Mod),Es}]}
    end.

-spec format_error(term()) -> iolist().

format_error({{_M,F,A},{I,Off,limit}}) ->
    io_lib:format(
      "function ~p/~p+~p:~n"
      "  An implementation limit was reached.~n"
      "  Try reducing the complexity of this function.~n~n"
      "  Instruction: ~p~n", [F,A,Off,I]);
format_error({{_M,F,A},{undef_labels,Lbls}}) ->
    io_lib:format(
      "function ~p/~p:~n"
      "  Internal consistency check failed - please report this bug.~n"
      "  The following label(s) were referenced but not defined:~n", [F,A]) ++
	"  " ++ [[integer_to_list(L)," "] || L <- Lbls] ++ "\n";
format_error({{_M,F,A},{I,Off,Desc}}) ->
    io_lib:format(
      "function ~p/~p+~p:~n"
      "  Internal consistency check failed - please report this bug.~n"
      "  Instruction: ~p~n"
      "  Error:       ~p:~n", [F,A,Off,I,Desc]);
format_error(Error) ->
    io_lib:format("~p~n", [Error]).

%%%
%%% Local functions follow.
%%% 

%%%
%%% The validator follows.
%%%
%%% The purpose of the validator is to find errors in the generated
%%% code that may cause the emulator to crash or behave strangely.
%%% We don't care about type errors in the user's code that will
%%% cause a proper exception at run-time.
%%%

%%% Things currently not checked. XXX
%%%
%%% - Heap allocation for binaries.
%%%

%% validate(Module, [Function]) -> [] | [Error]
%%  A list of functions with their code. The code is in the same
%%  format as used in the compiler and in .S files.

validate(Module, Fs) ->
    Ft = index_bs_start_match(Fs, []),
    validate_0(Module, Fs, Ft).

index_bs_start_match([{function,_,_,Entry,Code0}|Fs], Acc0) ->
    Code = dropwhile(fun({label,L}) when L =:= Entry -> false;
			(_) -> true
		     end, Code0),
    case Code of
	[{label,Entry}|Is] ->
	    Acc = index_bs_start_match_1(Is, Entry, Acc0),
	    index_bs_start_match(Fs, Acc);
	_ ->
	    %% Something serious is wrong. Ignore it for now.
	    %% It will be detected and diagnosed later.
	    index_bs_start_match(Fs, Acc0)
    end;
index_bs_start_match([], Acc) ->
    gb_trees:from_orddict(lists:sort(Acc)).

index_bs_start_match_1([{test,bs_start_match2,_,_,_,_}=I|_], Entry, Acc) ->
    [{Entry,[I]}|Acc];
index_bs_start_match_1([{test,_,{f,F},_},{bs_context_to_binary,_}|Is0], Entry, Acc) ->
    [{label,F}|Is] = dropwhile(fun({label,L}) when L =:= F -> false;
				  (_)  -> true
			       end, Is0),
    index_bs_start_match_1(Is, Entry, Acc);
index_bs_start_match_1(_, _, Acc) -> Acc.

validate_0(_Module, [], _) -> [];
validate_0(Module, [{function,Name,Ar,Entry,Code}|Fs], Ft) ->
    try validate_1(Code, Name, Ar, Entry, Ft) of
	_ -> validate_0(Module, Fs, Ft)
    catch
	throw:Error ->
	    %% Controlled error.
	    [Error|validate_0(Module, Fs, Ft)];
        Class:Error:Stack ->
	    %% Crash.
	    io:fwrite("Function: ~w/~w\n", [Name,Ar]),
	    erlang:raise(Class, Error, Stack)
    end.

-type index() :: non_neg_integer().
-type reg_tab() :: gb_trees:tree(index(), 'none' | {'value', _}).

-record(st,				%Emulation state
	{x=init_regs(0, term)        :: reg_tab(),%x register info.
	 y=init_regs(0, initialized) :: reg_tab(),%y register info.
	 f=init_fregs(),                %
	 numy=none,			%Number of y registers.
	 h=0,				%Available heap size.
	 hf=0,				%Available heap size for floats.
	 fls=undefined,			%Floating point state.
	 ct=[],				%List of hot catch/try labels
         setelem=false,                 %Previous instruction was setelement/3.
         puts_left=none,                %put/1 instructions left.
         defs=#{},                      %Defining expression for each register.
         aliases=#{}
	}).

-type label()        :: integer().
-type label_set()    :: gb_sets:set(label()).
-type branched_tab() :: gb_trees:tree(label(), #st{}).
-type ft_tab()       :: gb_trees:tree().

-record(vst,				%Validator state
	{current=none              :: #st{} | 'none',	%Current state
	 branched=gb_trees:empty() :: branched_tab(),	%States at jumps
	 labels=gb_sets:empty()    :: label_set(),	%All defined labels
	 ft=gb_trees:empty()       :: ft_tab()          %Some other functions
	 		% in the module (those that start with bs_start_match2).
	}).

%% Match context type.
-record(ms,
	{id=make_ref() :: reference(),		%Unique ID.
	 valid=0 :: non_neg_integer(),		%Valid slots
	 slots=0 :: non_neg_integer()		%Number of slots
	}).

validate_1(Is, Name, Arity, Entry, Ft) ->
    validate_2(labels(Is), Name, Arity, Entry, Ft).

validate_2({Ls1,[{func_info,{atom,Mod},{atom,Name},Arity}=_F|Is]},
	   Name, Arity, Entry, Ft) ->
    validate_3(labels(Is), Name, Arity, Entry, Mod, Ls1, Ft);
validate_2({Ls1,Is}, Name, Arity, _Entry, _Ft) ->
    error({{'_',Name,Arity},{first(Is),length(Ls1),illegal_instruction}}).

validate_3({Ls2,Is}, Name, Arity, Entry, Mod, Ls1, Ft) ->
    Offset = 1 + length(Ls1) + 1 + length(Ls2),
    EntryOK = lists:member(Entry, Ls2),
    if
	EntryOK ->
	    St = init_state(Arity),
	    Vst0 = #vst{current=St,
			branched=gb_trees_from_list([{L,St} || L <- Ls1]),
			labels=gb_sets:from_list(Ls1++Ls2),
			ft=Ft},
	    MFA = {Mod,Name,Arity},
	    Vst = valfun(Is, MFA, Offset, Vst0),
	    validate_fun_info_branches(Ls1, MFA, Vst);
	true ->
	    error({{Mod,Name,Arity},{first(Is),Offset,no_entry_label}})
    end.

validate_fun_info_branches([L|Ls], MFA, #vst{branched=Branches}=Vst0) ->
    Vst = Vst0#vst{current=gb_trees:get(L, Branches)},
    validate_fun_info_branches_1(0, MFA, Vst),
    validate_fun_info_branches(Ls, MFA, Vst);
validate_fun_info_branches([], _, _) -> ok.

validate_fun_info_branches_1(Arity, {_,_,Arity}, _) -> ok;
validate_fun_info_branches_1(X, {Mod,Name,Arity}=MFA, Vst) ->
    try
        case Vst of
            #vst{current=#st{numy=none}} ->
                ok;
            #vst{current=#st{numy=Size}} ->
                error({unexpected_stack_frame,Size})
        end,
	get_term_type({x,X}, Vst)
    catch Error ->
	    I = {func_info,{atom,Mod},{atom,Name},Arity},
	    Offset = 2,
	    error({MFA,{I,Offset,Error}})
    end,
    validate_fun_info_branches_1(X+1, MFA, Vst).

first([X|_]) -> X;
first([]) -> [].

labels(Is) ->
    labels_1(Is, []).

labels_1([{label,L}|Is], R) ->
    labels_1(Is, [L|R]);
labels_1([{line,_}|Is], R) ->
    labels_1(Is, R);
labels_1(Is, R) ->
    {reverse(R),Is}.

init_state(Arity) ->
    Xs = init_regs(Arity, term),
    Ys = init_regs(0, initialized),
    kill_heap_allocation(#st{x=Xs,y=Ys,numy=none,ct=[]}).

kill_heap_allocation(St) ->
    St#st{h=0,hf=0}.

init_regs(0, _) ->
    gb_trees:empty();
init_regs(N, Type) ->
    gb_trees_from_list([{R,Type} || R <- lists:seq(0, N-1)]).

valfun([], MFA, _Offset, #vst{branched=Targets0,labels=Labels0}=Vst) ->
    Targets = gb_trees:keys(Targets0),
    Labels = gb_sets:to_list(Labels0),
    case Targets -- Labels of
	[] -> Vst;
	Undef ->
	    Error = {undef_labels,Undef},
	    error({MFA,Error})
    end;
valfun([I|Is], MFA, Offset, Vst0) ->
    valfun(Is, MFA, Offset+1,
	   try
	       Vst = val_dsetel(I, Vst0),
	       valfun_1(I, Vst)
	   catch Error ->
		   error({MFA,{I,Offset,Error}})
	   end).

%% Instructions that are allowed in dead code or when failing,
%% that is while the state is undecided in some way.
valfun_1({label,Lbl}, #vst{current=St0,branched=B,labels=Lbls}=Vst) ->
    St = merge_states(Lbl, St0, B),
    Vst#vst{current=St,branched=gb_trees:enter(Lbl, St, B),
	    labels=gb_sets:add(Lbl, Lbls)};
valfun_1(_I, #vst{current=none}=Vst) ->
    %% Ignore instructions after erlang:error/1,2, which
    %% the original R10B compiler thought would return.
    Vst;
valfun_1({badmatch,Src}, Vst) ->
    assert_term(Src, Vst),
    verify_y_init(Vst),
    kill_state(Vst);
valfun_1({case_end,Src}, Vst) ->
    assert_term(Src, Vst),
    verify_y_init(Vst),
    kill_state(Vst);
valfun_1(if_end, Vst) ->
    verify_y_init(Vst),
    kill_state(Vst);
valfun_1({try_case_end,Src}, Vst) ->
    verify_y_init(Vst),
    assert_term(Src, Vst),
    kill_state(Vst);
%% Instructions that cannot cause exceptions
valfun_1({bs_context_to_binary,Ctx}, #vst{current=#st{x=Xs}}=Vst) ->
    case Ctx of
	{Tag,X} when Tag =:= x; Tag =:= y ->
	    Type = case gb_trees:lookup(X, Xs) of
		       {value,#ms{}} -> term;
		       _ -> get_term_type(Ctx, Vst)
		   end,
	    set_type_reg(Type, Ctx, Vst);
	_ ->
	    error({bad_source,Ctx})
    end;
valfun_1(bs_init_writable=I, Vst) ->
    call(I, 1, Vst);
valfun_1(build_stacktrace=I, Vst) ->
    call(I, 1, Vst);
valfun_1({move,{y,_}=Src,{y,_}=Dst}, Vst) ->
    %% The stack trimming optimization may generate a move from an initialized
    %% but unassigned Y register to another Y register.
    case get_term_type_1(Src, Vst) of
	{catchtag,_} -> error({catchtag,Src});
	{trytag,_} -> error({trytag,Src});
	Type -> set_type_reg(Type, Dst, Vst)
    end;
valfun_1({move,Src,Dst}, Vst0) ->
    Type = get_move_term_type(Src, Vst0),
    Vst = set_type_reg(Type, Dst, Vst0),
    set_alias(Src, Dst, Vst);
valfun_1({fmove,Src,{fr,_}=Dst}, Vst) ->
    assert_type(float, Src, Vst),
    set_freg(Dst, Vst);
valfun_1({fmove,{fr,_}=Src,Dst}, Vst0) ->
    assert_freg_set(Src, Vst0),
    assert_fls(checked, Vst0),
    Vst = eat_heap_float(Vst0),
    set_type_reg({float,[]}, Dst, Vst);
valfun_1({kill,{y,_}=Reg}, Vst) ->
    set_type_y(initialized, Reg, Vst);
valfun_1({init,{y,_}=Reg}, Vst) ->
    set_type_y(initialized, Reg, Vst);
valfun_1({test_heap,Heap,Live}, Vst) ->
    test_heap(Heap, Live, Vst);
valfun_1({bif,Op,{f,_},Src,Dst}=I, Vst) ->
    case is_bif_safe(Op, length(Src)) of
	false ->
	    %% Since the BIF can fail, make sure that any catch state
	    %% is updated.
	    valfun_2(I, Vst);
	true ->
	    %% It can't fail, so we finish handling it here (not updating
	    %% catch state).
	    validate_src(Src, Vst),
	    Type = bif_type(Op, Src, Vst),
	    set_type_reg_expr(Type, I, Dst, Vst)
    end;
%% Put instructions.
valfun_1({put_list,A,B,Dst}, Vst0) ->
    assert_term(A, Vst0),
    assert_term(B, Vst0),
    Vst = eat_heap(2, Vst0),
    set_type_reg(cons, Dst, Vst);
valfun_1({put_tuple2,Dst,{list,Elements}}, Vst0) ->
    _ = [assert_term(El, Vst0) || El <- Elements],
    Size = length(Elements),
    Vst = eat_heap(Size+1, Vst0),
    Type = {tuple,Size},
    set_type_reg(Type, Dst, Vst);
valfun_1({put_tuple,Sz,Dst}, Vst0) when is_integer(Sz) ->
    Vst1 = eat_heap(1, Vst0),
    Vst = set_type_reg(tuple_in_progress, Dst, Vst1),
    #vst{current=St0} = Vst,
    St = St0#st{puts_left={Sz,{Dst,{tuple,Sz}}}},
    Vst#vst{current=St};
valfun_1({put,Src}, Vst0) ->
    assert_term(Src, Vst0),
    Vst = eat_heap(1, Vst0),
    #vst{current=St0} = Vst,
    case St0 of
        #st{puts_left=none} ->
            error(not_building_a_tuple);
        #st{puts_left={1,{Dst,Type}}} ->
            St = St0#st{puts_left=none},
            set_type_reg(Type, Dst, Vst#vst{current=St});
        #st{puts_left={PutsLeft,Info}} when is_integer(PutsLeft) ->
            St = St0#st{puts_left={PutsLeft-1,Info}},
            Vst#vst{current=St}
    end;
%% Instructions for optimization of selective receives.
valfun_1({recv_mark,{f,Fail}}, Vst) when is_integer(Fail) ->
    Vst;
valfun_1({recv_set,{f,Fail}}, Vst) when is_integer(Fail) ->
    Vst;
%% Misc.
valfun_1(remove_message, Vst) ->
    %% The message term is no longer fragile. It can be used
    %% without restrictions.
    remove_fragility(Vst);
valfun_1({'%',_}, Vst) ->
    Vst;
valfun_1({line,_}, Vst) ->
    Vst;
%% Exception generating calls
valfun_1({call_ext,Live,Func}=I, Vst) ->
    case return_type(Func, Vst) of
	exception ->
	    verify_live(Live, Vst),
            %% The stack will be scanned, so Y registers
            %% must be initialized.
            verify_y_init(Vst),
	    kill_state(Vst);
	_ ->
	    valfun_2(I, Vst)
    end;
valfun_1(_I, #vst{current=#st{ct=undecided}}) ->
    error(unknown_catch_try_state);
%%
%% Allocate and deallocate, et.al
valfun_1({allocate,Stk,Live}, Vst) ->
    allocate(false, Stk, 0, Live, Vst);
valfun_1({allocate_heap,Stk,Heap,Live}, Vst) ->
    allocate(false, Stk, Heap, Live, Vst);
valfun_1({allocate_zero,Stk,Live}, Vst) ->
    allocate(true, Stk, 0, Live, Vst);
valfun_1({allocate_heap_zero,Stk,Heap,Live}, Vst) ->
    allocate(true, Stk, Heap, Live, Vst);
valfun_1({deallocate,StkSize}, #vst{current=#st{numy=StkSize}}=Vst) ->
    verify_no_ct(Vst),
    deallocate(Vst);
valfun_1({deallocate,_}, #vst{current=#st{numy=NumY}}) ->
    error({allocated,NumY});
valfun_1({trim,N,Remaining}, #vst{current=#st{y=Yregs0,numy=NumY}=St}=Vst) ->
    if
	N =< NumY, N+Remaining =:= NumY ->
	    Yregs1 = [{Y-N,Type} || {Y,Type} <- gb_trees:to_list(Yregs0), Y >= N],
	    Yregs = gb_trees_from_list(Yregs1),
	    Vst#vst{current=St#st{y=Yregs,numy=NumY-N,aliases=#{}}};
	true ->
	    error({trim,N,Remaining,allocated,NumY})
    end;
%% Catch & try.
valfun_1({'catch',Dst,{f,Fail}}, Vst) when Fail =/= none ->
    init_try_catch_branch(catchtag, Dst, Fail, Vst);
valfun_1({'try',Dst,{f,Fail}}, Vst)  when Fail =/= none ->
    init_try_catch_branch(trytag, Dst, Fail, Vst);
valfun_1({catch_end,Reg}, #vst{current=#st{ct=[Fail|Fails]}}=Vst0) ->
    case get_special_y_type(Reg, Vst0) of
	{catchtag,Fail} ->
	    Vst = #vst{current=St} = set_catch_end(Reg, Vst0),
            Xregs = gb_trees:enter(0, term, St#st.x),
	    Vst#vst{current=St#st{x=Xregs,ct=Fails,fls=undefined,aliases=#{}}};
	Type ->
	    error({bad_type,Type})
    end;
valfun_1({try_end,Reg}, #vst{current=#st{ct=[Fail|Fails]}=St0}=Vst) ->
    case get_special_y_type(Reg, Vst) of
	{trytag,Fail} ->
	    St = St0#st{ct=Fails,fls=undefined},
	    set_catch_end(Reg, Vst#vst{current=St});
	Type ->
	    error({bad_type,Type})
    end;
valfun_1({try_case,Reg}, #vst{current=#st{ct=[Fail|Fails]}}=Vst0) ->
    case get_special_y_type(Reg, Vst0) of
	{trytag,Fail} ->
	    Vst = #vst{current=St} = set_catch_end(Reg, Vst0),
	    Xs = gb_trees_from_list([{0,{atom,[]}},{1,term},{2,term}]),
	    Vst#vst{current=St#st{x=Xs,ct=Fails,fls=undefined,aliases=#{}}};
	Type ->
	    error({bad_type,Type})
    end;
valfun_1({get_list,Src,D1,D2}, Vst0) ->
    assert_type(cons, Src, Vst0),
    Vst = set_type_reg(term, Src, D1, Vst0),
    set_type_reg(term, Src, D2, Vst);
valfun_1({get_hd,Src,Dst}, Vst) ->
    assert_type(cons, Src, Vst),
    set_type_reg(term, Src, Dst, Vst);
valfun_1({get_tl,Src,Dst}, Vst) ->
    assert_type(cons, Src, Vst),
    set_type_reg(term, Src, Dst, Vst);
valfun_1({get_tuple_element,Src,I,Dst}, Vst) ->
    assert_type({tuple_element,I+1}, Src, Vst),
    set_type_reg(term, Src, Dst, Vst);
valfun_1({jump,{f,Lbl}}, Vst) ->
    kill_state(branch_state(Lbl, Vst));
valfun_1(I, Vst) ->
    valfun_2(I, Vst).

init_try_catch_branch(Tag, Dst, Fail, Vst0) ->
    Vst1 = set_type_y({Tag,[Fail]}, Dst, Vst0),
    #vst{current=#st{ct=Fails}=St0} = Vst1,
    CurrentSt = St0#st{ct=[[Fail]|Fails]},

    %% Set the initial state at the try/catch label.
    %% Assume that Y registers contain terms or try/catch
    %% tags.
    Yregs0 = map(fun({Y,uninitialized}) -> {Y,term};
                    ({Y,initialized}) -> {Y,term};
                    (E) -> E
                 end, gb_trees:to_list(CurrentSt#st.y)),
    Yregs = gb_trees:from_orddict(Yregs0),
    BranchSt = CurrentSt#st{y=Yregs},

    Vst = branch_state(Fail, Vst1#vst{current=BranchSt}),
    Vst#vst{current=CurrentSt}.

%% Update branched state if necessary and try next set of instructions.
valfun_2(I, #vst{current=#st{ct=[]}}=Vst) ->
    valfun_3(I, Vst);
valfun_2(I, #vst{current=#st{ct=[[Fail]|_]}}=Vst) when is_integer(Fail) ->
    %% Update branched state.
    valfun_3(I, branch_state(Fail, Vst));
valfun_2(_, _) ->
    error(ambiguous_catch_try_state).

%% Handle the remaining floating point instructions here.
%% Floating point.
valfun_3({fconv,Src,{fr,_}=Dst}, Vst) ->
    assert_term(Src, Vst),
    set_freg(Dst, Vst);
valfun_3({bif,fadd,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fdiv,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fmul,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fnegate,_,[_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fsub,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3(fclearerror, Vst) ->
    case get_fls(Vst) of
	undefined -> ok;
	checked -> ok;
	Fls -> error({bad_floating_point_state,Fls})
    end,
    set_fls(cleared, Vst);
valfun_3({fcheckerror,_}, Vst) ->
    assert_fls(cleared, Vst),
    set_fls(checked, Vst);
valfun_3(I, Vst) ->
    %% The instruction is not a float instruction.
    case get_fls(Vst) of
	undefined ->
	    valfun_4(I, Vst);
	checked ->
	    valfun_4(I, Vst);
	Fls ->
	    error({unsafe_instruction,{float_error_state,Fls}})
    end.

%% Instructions that can cause exceptions.
valfun_4({apply,Live}, Vst) ->
    call(apply, Live+2, Vst);
valfun_4({apply_last,Live,_}, Vst) ->
    tail_call(apply, Live+2, Vst);
valfun_4({call_fun,Live}, Vst) ->
    validate_src([{x,Live}], Vst),
    call('fun', Live+1, Vst);
valfun_4({call,Live,Func}, Vst) ->
    call(Func, Live, Vst);
valfun_4({call_ext,Live,Func}, Vst) ->
    %% Exception BIFs has already been taken care of above.
    call(Func, Live, Vst);
valfun_4({call_only,Live,Func}, Vst) ->
    tail_call(Func, Live, Vst);
valfun_4({call_ext_only,Live,Func}, Vst) ->
    tail_call(Func, Live, Vst);
valfun_4({call_last,Live,Func,StkSize}, #vst{current=#st{numy=StkSize}}=Vst) ->
    tail_call(Func, Live, Vst);
valfun_4({call_last,_,_,_}, #vst{current=#st{numy=NumY}}) ->
    error({allocated,NumY});
valfun_4({call_ext_last,Live,Func,StkSize}, 
	 #vst{current=#st{numy=StkSize}}=Vst) ->
    tail_call(Func, Live, Vst);
valfun_4({call_ext_last,_,_,_}, #vst{current=#st{numy=NumY}}) ->
    error({allocated,NumY});
valfun_4({make_fun2,_,_,_,Live}, Vst) ->
    call(make_fun, Live, Vst);
%% Other BIFs
valfun_4({bif,tuple_size,{f,Fail},[Tuple],Dst}=I, Vst0) ->
    TupleType0 = get_term_type(Tuple, Vst0),
    Vst1 = branch_state(Fail, Vst0),
    TupleType = upgrade_tuple_type({tuple,[0]}, TupleType0),
    Vst = set_aliased_type(TupleType, Tuple, Vst1),
    set_type_reg_expr({integer,[]}, I, Dst, Vst);
valfun_4({bif,element,{f,Fail},[Pos,Tuple],Dst}, Vst0) ->
    TupleType0 = get_term_type(Tuple, Vst0),
    PosType = get_term_type(Pos, Vst0),
    Vst1 = branch_state(Fail, Vst0),
    TupleType = upgrade_tuple_type({tuple,[get_tuple_size(PosType)]}, TupleType0),
    Vst = set_aliased_type(TupleType, Tuple, Vst1),
    set_type_reg(term, Tuple, Dst, Vst);
valfun_4({bif,raise,{f,0},Src,_Dst}, Vst) ->
    validate_src(Src, Vst),
    kill_state(Vst);
valfun_4(raw_raise=I, Vst) ->
    call(I, 3, Vst);
valfun_4({bif,map_get,{f,Fail},[_Key,Map]=Src,Dst}, Vst0) ->
    validate_src(Src, Vst0),
    Vst1 = branch_state(Fail, Vst0),
    Vst = set_aliased_type(map, Map, Vst1),
    Type = propagate_fragility(term, Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_4({bif,is_map_key,{f,Fail},[_Key,Map]=Src,Dst}, Vst0) ->
    validate_src(Src, Vst0),
    Vst1 = branch_state(Fail, Vst0),
    Vst = set_aliased_type(map, Map, Vst1),
    Type = propagate_fragility(bool, Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_4({bif,Op,{f,Fail},[Cons]=Src,Dst}, Vst0)
  when Op =:= hd; Op =:= tl ->
    validate_src(Src, Vst0),
    Vst1 = branch_state(Fail, Vst0),
    Vst = set_aliased_type(cons, Cons, Vst1),
    Type0 = bif_type(Op, Src, Vst),
    Type = propagate_fragility(Type0, Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_4({bif,Op,{f,Fail},Src,Dst}, Vst0) ->
    validate_src(Src, Vst0),
    Vst = branch_state(Fail, Vst0),
    Type0 = bif_type(Op, Src, Vst),
    Type = propagate_fragility(Type0, Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_4({gc_bif,Op,{f,Fail},Live,Src,Dst}, #vst{current=St0}=Vst0) ->
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    St = kill_heap_allocation(St0),
    Vst1 = Vst0#vst{current=St},
    Vst2 = branch_state(Fail, Vst1),
    Vst3 = prune_x_regs(Live, Vst2),
    Vst = case Op of
              map_size ->
                  set_type(map, hd(Src), Vst3);
              _ ->
                  Vst3
          end,
    validate_src(Src, Vst),
    Type0 = bif_type(Op, Src, Vst),
    Type = propagate_fragility(Type0, Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_4(return, #vst{current=#st{numy=none}}=Vst) ->
    assert_term({x,0}, Vst),
    kill_state(Vst);
valfun_4(return, #vst{current=#st{numy=NumY}}) ->
    error({stack_frame,NumY});
valfun_4({loop_rec,{f,Fail},Dst}, Vst0) ->
    Vst = branch_state(Fail, Vst0),
    %% This term may not be part of the root set until
    %% remove_message/0 is executed. If control transfers
    %% to the loop_rec_end/1 instruction, no part of
    %% this term must be stored in a Y register.
    set_type_reg({fragile,term}, Dst, Vst);
valfun_4({wait,_}, Vst) ->
    verify_y_init(Vst),
    kill_state(Vst);
valfun_4({wait_timeout,_,Src}, Vst) ->
    assert_term(Src, Vst),
    verify_y_init(Vst),
    prune_x_regs(0, Vst);
valfun_4({loop_rec_end,_}, Vst) ->
    verify_y_init(Vst),
    kill_state(Vst);
valfun_4(timeout, #vst{current=St}=Vst) ->
    Vst#vst{current=St#st{x=init_regs(0, term)}};
valfun_4(send, Vst) ->
    call(send, 2, Vst);
valfun_4({set_tuple_element,Src,Tuple,I}, Vst) ->
    assert_term(Src, Vst),
    assert_type({tuple_element,I+1}, Tuple, Vst),
    Vst;
%% Match instructions.
valfun_4({select_val,Src,{f,Fail},{list,Choices}}, Vst0) ->
    assert_term(Src, Vst0),
    assert_choices(Choices),
    Vst = branch_state(Fail, Vst0),
    kill_state(select_val_branches(Src, Choices, Vst));
valfun_4({select_tuple_arity,Tuple,{f,Fail},{list,Choices}}, Vst) ->
    assert_type(tuple, Tuple, Vst),
    assert_arities(Choices),
    TupleType = case get_term_type(Tuple, Vst) of
                    {fragile,TupleType0} -> TupleType0;
                    TupleType0 -> TupleType0
                end,
    kill_state(branch_arities(Choices, Tuple, TupleType,
                              branch_state(Fail, Vst)));

%% New bit syntax matching instructions.
valfun_4({test,bs_start_match2,{f,Fail},Live,[Ctx,NeedSlots],Ctx}, Vst0) ->
    %% If source and destination registers are the same, match state
    %% is OK as input.
    CtxType = get_move_term_type(Ctx, Vst0),
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    Vst1 = prune_x_regs(Live, Vst0),
    BranchVst = case CtxType of
		    #ms{} ->
			%% The failure branch will never be taken when Ctx
			%% is a match context. Therefore, the type for Ctx
			%% at the failure label must not be match_context
			%% (or we could reject legal code).
			set_type_reg(term, Ctx, Vst1);
		    _ ->
			Vst1
		end,
    Vst = branch_state(Fail, BranchVst),
    set_type_reg(bsm_match_state(NeedSlots), Ctx, Vst);
valfun_4({test,bs_start_match2,{f,Fail},Live,[Src,Slots],Dst}, Vst0) ->
    assert_term(Src, Vst0),
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    Vst1 = prune_x_regs(Live, Vst0),
    Vst = branch_state(Fail, Vst1),
    set_type_reg(bsm_match_state(Slots), Src, Dst, Vst);
valfun_4({test,bs_match_string,{f,Fail},[Ctx,_,_]}, Vst) ->
    bsm_validate_context(Ctx, Vst),
    branch_state(Fail, Vst);
valfun_4({test,bs_skip_bits2,{f,Fail},[Ctx,Src,_,_]}, Vst) ->
    bsm_validate_context(Ctx, Vst),
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({test,bs_test_tail2,{f,Fail},[Ctx,_]}, Vst) ->
    bsm_validate_context(Ctx, Vst),
    branch_state(Fail, Vst);
valfun_4({test,bs_test_unit,{f,Fail},[Ctx,_]}, Vst) ->
    bsm_validate_context(Ctx, Vst),
    branch_state(Fail, Vst);
valfun_4({test,bs_skip_utf8,{f,Fail},[Ctx,Live,_]}, Vst) ->
    validate_bs_skip_utf(Fail, Ctx, Live, Vst);
valfun_4({test,bs_skip_utf16,{f,Fail},[Ctx,Live,_]}, Vst) ->
    validate_bs_skip_utf(Fail, Ctx, Live, Vst);
valfun_4({test,bs_skip_utf32,{f,Fail},[Ctx,Live,_]}, Vst) ->
    validate_bs_skip_utf(Fail, Ctx, Live, Vst);
valfun_4({test,bs_get_integer2,{f,Fail},Live,[Ctx,_,_,_],Dst}, Vst) ->
    validate_bs_get(Fail, Ctx, Live, {integer, []}, Dst, Vst);
valfun_4({test,bs_get_float2,{f,Fail},Live,[Ctx,_,_,_],Dst}, Vst) ->
    validate_bs_get(Fail, Ctx, Live, {float, []}, Dst, Vst);
valfun_4({test,bs_get_binary2,{f,Fail},Live,[Ctx,_,_,_],Dst}, Vst) ->
    Type = propagate_fragility(term, [Ctx], Vst),
    validate_bs_get(Fail, Ctx, Live, Type, Dst, Vst);
valfun_4({test,bs_get_utf8,{f,Fail},Live,[Ctx,_],Dst}, Vst) ->
    validate_bs_get(Fail, Ctx, Live, {integer, []}, Dst, Vst);
valfun_4({test,bs_get_utf16,{f,Fail},Live,[Ctx,_],Dst}, Vst) ->
    validate_bs_get(Fail, Ctx, Live, {integer, []}, Dst, Vst);
valfun_4({test,bs_get_utf32,{f,Fail},Live,[Ctx,_],Dst}, Vst) ->
    validate_bs_get(Fail, Ctx, Live, {integer, []}, Dst, Vst);
valfun_4({bs_save2,Ctx,SavePoint}, Vst) ->
    bsm_save(Ctx, SavePoint, Vst);
valfun_4({bs_restore2,Ctx,SavePoint}, Vst) ->
    bsm_restore(Ctx, SavePoint, Vst);

%% Other test instructions.
valfun_4({test,is_float,{f,Lbl},[Float]}, Vst) ->
    assert_term(Float, Vst),
    set_type({float,[]}, Float, branch_state(Lbl, Vst));
valfun_4({test,is_tuple,{f,Lbl},[Tuple]}, Vst) ->
    Type0 = get_term_type(Tuple, Vst),
    Type = upgrade_tuple_type({tuple,[0]}, Type0),
    set_aliased_type(Type, Tuple, branch_state(Lbl, Vst));
valfun_4({test,is_nonempty_list,{f,Lbl},[Cons]}, Vst) ->
    assert_term(Cons, Vst),
    Type = cons,
    set_aliased_type(Type, Cons, branch_state(Lbl, Vst));
valfun_4({test,test_arity,{f,Lbl},[Tuple,Sz]}, Vst) when is_integer(Sz) ->
    assert_type(tuple, Tuple, Vst),
    Type = {tuple,Sz},
    set_aliased_type(Type, Tuple, branch_state(Lbl, Vst));
valfun_4({test,is_tagged_tuple,{f,Lbl},[Src,Sz,_Atom]}, Vst) ->
    validate_src([Src], Vst),
    Type = {tuple,Sz},
    set_aliased_type(Type, Src, branch_state(Lbl, Vst));
valfun_4({test,has_map_fields,{f,Lbl},Src,{list,List}}, Vst) ->
    assert_type(map, Src, Vst),
    assert_unique_map_keys(List),
    branch_state(Lbl, Vst);
valfun_4({test,is_map,{f,Lbl},[Src]}, Vst0) ->
    Vst = branch_state(Lbl, Vst0),
    case Src of
	{Tag,_} when Tag =:= x; Tag =:= y ->
            Type = map,
	    set_aliased_type(Type, Src, Vst);
	{literal,Map} when is_map(Map) ->
	    Vst0;
	_ ->
	    kill_state(Vst0)
    end;
valfun_4({test,is_eq_exact,{f,Lbl},[Src,Val]=Ss}, Vst0) ->
    validate_src(Ss, Vst0),
    Infer = infer_types(Src, Vst0),
    Vst1 = Infer(Val, Vst0),
    Vst = branch_state(Lbl, Vst1),
    case Val of
        {literal,Tuple} when is_tuple(Tuple) ->
            Type0 = get_term_type(Val, Vst),
            Type = upgrade_tuple_type({tuple,tuple_size(Tuple)},
                                      Type0),
            set_aliased_type(Type, Src, Vst);
        _ ->
            Vst
    end;
valfun_4({test,_Op,{f,Lbl},Src}, Vst) ->
    validate_src(Src, Vst),
    branch_state(Lbl, Vst);
valfun_4({bs_add,{f,Fail},[A,B,_],Dst}, Vst) ->
    assert_term(A, Vst),
    assert_term(B, Vst),
    set_type_reg({integer,[]}, Dst, branch_state(Fail, Vst));
valfun_4({bs_utf8_size,{f,Fail},A,Dst}, Vst) ->
    assert_term(A, Vst),
    set_type_reg({integer,[]}, Dst, branch_state(Fail, Vst));
valfun_4({bs_utf16_size,{f,Fail},A,Dst}, Vst) ->
    assert_term(A, Vst),
    set_type_reg({integer,[]}, Dst, branch_state(Fail, Vst));
valfun_4({bs_init2,{f,Fail},Sz,Heap,Live,_,Dst}, Vst0) ->
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    if
	is_integer(Sz) ->
	    ok;
	true ->
	    assert_term(Sz, Vst0)
    end,
    Vst1 = heap_alloc(Heap, Vst0),
    Vst2 = branch_state(Fail, Vst1),
    Vst = prune_x_regs(Live, Vst2),
    set_type_reg(binary, Dst, Vst);
valfun_4({bs_init_bits,{f,Fail},Sz,Heap,Live,_,Dst}, Vst0) ->
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    if
	is_integer(Sz) ->
	    ok;
	true ->
	    assert_term(Sz, Vst0)
    end,
    Vst1 = heap_alloc(Heap, Vst0),
    Vst2 = branch_state(Fail, Vst1),
    Vst = prune_x_regs(Live, Vst2),
    set_type_reg(binary, Dst, Vst);
valfun_4({bs_append,{f,Fail},Bits,Heap,Live,_Unit,Bin,_Flags,Dst}, Vst0) ->
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    assert_term(Bits, Vst0),
    assert_term(Bin, Vst0),
    Vst1 = heap_alloc(Heap, Vst0),
    Vst2 = branch_state(Fail, Vst1),
    Vst = prune_x_regs(Live, Vst2),
    set_type_reg(binary, Dst, Vst);
valfun_4({bs_private_append,{f,Fail},Bits,_Unit,Bin,_Flags,Dst}, Vst0) ->
    assert_term(Bits, Vst0),
    assert_term(Bin, Vst0),
    Vst = branch_state(Fail, Vst0),
    set_type_reg(binary, Dst, Vst);
valfun_4({bs_put_string,Sz,_}, Vst) when is_integer(Sz) ->
    Vst;
valfun_4({bs_put_binary,{f,Fail},Sz,_,_,Src}, Vst) ->
    assert_term(Sz, Vst),
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({bs_put_float,{f,Fail},Sz,_,_,Src}, Vst) ->
    assert_term(Sz, Vst),
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({bs_put_integer,{f,Fail},Sz,_,_,Src}, Vst) ->
    assert_term(Sz, Vst),
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({bs_put_utf8,{f,Fail},_,Src}, Vst) ->
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({bs_put_utf16,{f,Fail},_,Src}, Vst) ->
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({bs_put_utf32,{f,Fail},_,Src}, Vst) ->
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
%% Map instructions.
valfun_4({put_map_assoc,{f,Fail},Src,Dst,Live,{list,List}}, Vst) ->
    verify_put_map(Fail, Src, Dst, Live, List, Vst);
valfun_4({put_map_exact,{f,Fail},Src,Dst,Live,{list,List}}, Vst) ->
    verify_put_map(Fail, Src, Dst, Live, List, Vst);
valfun_4({get_map_elements,{f,Fail},Src,{list,List}}, Vst) ->
    verify_get_map(Fail, Src, List, Vst);
valfun_4(_, _) ->
    error(unknown_instruction).

verify_get_map(Fail, Src, List, Vst0) ->
    assert_type(map, Src, Vst0),
    Vst1 = foldl(fun(D, Vsti) ->
                         case is_reg_defined(D,Vsti) of
                             true -> set_type_reg(term,D,Vsti);
                             false -> Vsti
                         end
                 end, Vst0, extract_map_vals(List)),
    Vst2 = branch_state(Fail, Vst1),
    Keys = extract_map_keys(List),
    assert_unique_map_keys(Keys),
    verify_get_map_pair(List, Src, Vst0, Vst2).

extract_map_vals([_Key,Val|T]) ->
    [Val|extract_map_vals(T)];
extract_map_vals([]) -> [].

extract_map_keys([Key,_Val|T]) ->
    [Key|extract_map_keys(T)];
extract_map_keys([]) -> [].

verify_get_map_pair([Src,Dst|Vs], Map, Vst0, Vsti0) ->
    assert_term(Src, Vst0),
    Vsti = set_type_reg(term, Map, Dst, Vsti0),
    verify_get_map_pair(Vs, Map, Vst0, Vsti);
verify_get_map_pair([], _Map, _Vst0, Vst) -> Vst.

verify_put_map(Fail, Src, Dst, Live, List, Vst0) ->
    assert_type(map, Src, Vst0),
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    foreach(fun (Term) -> assert_term(Term, Vst0) end, List),
    Vst1 = heap_alloc(0, Vst0),
    Vst2 = branch_state(Fail, Vst1),
    Vst = prune_x_regs(Live, Vst2),
    Keys = extract_map_keys(List),
    assert_unique_map_keys(Keys),
    set_type_reg(map, Dst, Vst).

%%
%% Common code for validating bs_get* instructions.
%%
validate_bs_get(Fail, Ctx, Live, Type, Dst, Vst0) ->
    bsm_validate_context(Ctx, Vst0),
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    Vst1 = prune_x_regs(Live, Vst0),
    Vst = branch_state(Fail, Vst1),
    set_type_reg(Type, Dst, Vst).

%%
%% Common code for validating bs_skip_utf* instructions.
%%
validate_bs_skip_utf(Fail, Ctx, Live, Vst0) ->
    bsm_validate_context(Ctx, Vst0),
    verify_y_init(Vst0),
    verify_live(Live, Vst0),
    Vst = prune_x_regs(Live, Vst0),
    branch_state(Fail, Vst).

%%
%% Special state handling for setelement/3 and set_tuple_element/3 instructions.
%% A possibility for garbage collection must not occur between setelement/3 and
%% set_tuple_element/3.
%%
%% Note that #vst.current will be 'none' if the instruction is unreachable.
%%
val_dsetel({move,_,_}, Vst) ->
    Vst;
val_dsetel({call_ext,3,{extfunc,erlang,setelement,3}}, #vst{current=#st{}=St}=Vst) ->
    Vst#vst{current=St#st{setelem=true}};
val_dsetel({set_tuple_element,_,_,_}, #vst{current=#st{setelem=false}}) ->
    error(illegal_context_for_set_tuple_element);
val_dsetel({set_tuple_element,_,_,_}, #vst{current=#st{setelem=true}}=Vst) ->
    Vst;
val_dsetel({get_tuple_element,_,_,_}, Vst) ->
    Vst;
val_dsetel({line,_}, Vst) ->
    Vst;
val_dsetel(_, #vst{current=#st{setelem=true}=St}=Vst) ->
    Vst#vst{current=St#st{setelem=false}};
val_dsetel(_, Vst) -> Vst.

kill_state(Vst) ->
    Vst#vst{current=none}.

%% A "plain" call.
%%  The stackframe must be initialized.
%%  The instruction will return to the instruction following the call.
call(Name, Live, #vst{current=St}=Vst) ->
    verify_call_args(Name, Live, Vst),
    verify_y_init(Vst),
    case return_type(Name, Vst) of
	Type when Type =/= exception ->
	    %% Type is never 'exception' because it has been handled earlier.
	    Xs = gb_trees_from_list([{0,Type}]),
	    Vst#vst{current=St#st{x=Xs,f=init_fregs(),aliases=#{}}}
    end.

%% Tail call.
%%  The stackframe must have a known size and be initialized.
%%  Does not return to the instruction following the call.
tail_call(Name, Live, Vst0) ->
    verify_y_init(Vst0),
    Vst = deallocate(Vst0),
    verify_call_args(Name, Live, Vst),
    verify_no_ct(Vst),
    kill_state(Vst).

verify_call_args(_, 0, #vst{}) ->
    ok;
verify_call_args({f,Lbl}, Live, Vst) when is_integer(Live)->
    verify_local_call(Lbl, Live, Vst);
verify_call_args(_, Live, Vst) when is_integer(Live)->
    verify_call_args_1(Live, Vst);
verify_call_args(_, Live, _) ->
    error({bad_number_of_live_regs,Live}).

verify_call_args_1(0, _) -> ok;
verify_call_args_1(N, Vst) ->
    X = N - 1,
    get_term_type({x,X}, Vst),
    verify_call_args_1(X, Vst).

verify_local_call(Lbl, Live, Vst) ->
    case all_ms_in_x_regs(Live, Vst) of
	[{R,Ctx}] ->
	    %% Verify that there is a suitable bs_start_match2 instruction.
	    verify_call_match_context(Lbl, R, Vst),

	    %% Since the callee has consumed the match context,
	    %% there must be no additional copies in Y registers.
	    #ms{id=Id} = Ctx,
	    case ms_in_y_regs(Id, Vst) of
		[] ->
		    ok;
		[_|_]=Ys ->
		    error({multiple_match_contexts,[R|Ys]})
	    end;
	[_,_|_]=Xs0 ->
	    Xs = [R || {R,_} <- Xs0],
	    error({multiple_match_contexts,Xs});
	[] ->
	    ok
    end.

all_ms_in_x_regs(0, _Vst) ->
    [];
all_ms_in_x_regs(Live0, Vst) ->
    Live = Live0 - 1,
    R = {x,Live},
    case get_move_term_type(R, Vst) of
	#ms{}=M ->
	    [{R,M}|all_ms_in_x_regs(Live, Vst)];
	_ ->
	    all_ms_in_x_regs(Live, Vst)
    end.

ms_in_y_regs(Id, #vst{current=#st{y=Ys0}}) ->
    Ys = gb_trees:to_list(Ys0),
    [{y,Y} || {Y,#ms{id=OtherId}} <- Ys, OtherId =:= Id].

verify_call_match_context(Lbl, Ctx, #vst{ft=Ft}) ->
    case gb_trees:lookup(Lbl, Ft) of
	none ->
	    error(no_bs_start_match2);
	{value,[{test,bs_start_match2,_,_,[Ctx,_],Ctx}|_]} ->
	    ok;
	{value,[{test,bs_start_match2,_,_,_,_}=I|_]} ->
	    error({unsuitable_bs_start_match2,I})
    end.

allocate(Zero, Stk, Heap, Live, #vst{current=#st{numy=none}}=Vst0) ->
    verify_live(Live, Vst0),
    Vst = #vst{current=St} = prune_x_regs(Live, Vst0),
    Ys = init_regs(Stk, case Zero of 
			    true -> initialized;
			    false -> uninitialized
			end),
    heap_alloc(Heap, Vst#vst{current=St#st{y=Ys,numy=Stk}});
allocate(_, _, _, _, #vst{current=#st{numy=Numy}}) ->
    error({existing_stack_frame,{size,Numy}}).

deallocate(#vst{current=St}=Vst) ->
    Vst#vst{current=St#st{y=init_regs(0, initialized),numy=none}}.

test_heap(Heap, Live, Vst0) ->
    verify_live(Live, Vst0),
    verify_y_init(Vst0),
    Vst = prune_x_regs(Live, Vst0),
    heap_alloc(Heap, Vst).

heap_alloc(Heap, #vst{current=St0}=Vst) ->
    St1 = kill_heap_allocation(St0),
    St = heap_alloc_1(Heap, St1),
    Vst#vst{current=St}.

heap_alloc_1({alloc,Alloc}, St) ->
    heap_alloc_2(Alloc, St);
heap_alloc_1(HeapWords, St) when is_integer(HeapWords) ->
    St#st{h=HeapWords}.

heap_alloc_2([{words,HeapWords}|T], St0) ->
    St = St0#st{h=HeapWords},
    heap_alloc_2(T, St);
heap_alloc_2([{floats,Floats}|T], St0) ->
    St = St0#st{hf=Floats},
    heap_alloc_2(T, St);
heap_alloc_2([], St) -> St.

prune_x_regs(Live, #vst{current=St0}=Vst)
  when is_integer(Live) ->
    #st{x=Xs0,defs=Defs0,aliases=Aliases0} = St0,
    Xs1 = gb_trees:to_list(Xs0),
    Xs = [P || {R,_}=P <- Xs1, R < Live],
    Defs = maps:filter(fun({x,X}, _) -> X < Live;
                          ({y,_}, _) -> true
                       end, Defs0),
    Aliases = maps:filter(fun({x,X1}, {x,X2}) ->
                                  X1 < Live andalso X2 < Live;
                             ({x,X}, _) ->
                                  X < Live;
                             (_, {x,X}) ->
                                  X < Live;
                             (_, _) ->
                                  true
                          end, Aliases0),
    St = St0#st{x=gb_trees:from_orddict(Xs),defs=Defs,aliases=Aliases},
    Vst#vst{current=St}.

%% All choices in a select_val list must be integers, floats, or atoms.
%% All must be of the same type.
assert_choices([{Tag,_},{f,_}|T]) ->
    if
        Tag =:= atom; Tag =:= float; Tag =:= integer ->
            assert_choices_1(T, Tag);
        true ->
            error(bad_select_list)
    end;
assert_choices([]) -> ok.

assert_choices_1([{Tag,_},{f,_}|T], Tag) ->
    assert_choices_1(T, Tag);
assert_choices_1([_,{f,_}|_], _Tag) ->
    error(bad_select_list);
assert_choices_1([], _Tag) -> ok.

assert_arities([Arity,{f,_}|T]) when is_integer(Arity) ->
    assert_arities(T);
assert_arities([]) -> ok;
assert_arities(_) -> error(bad_tuple_arity_list).


%%%
%%% Floating point checking.
%%%
%%% Possible values for the fls field (=floating point error state).
%%%
%%% undefined 	- Undefined (initial state). No float operations allowed.
%%%
%%% cleared	- fclearerror/0 has been executed. Float operations
%%%		  are allowed (such as fadd).
%%%
%%% checked	- fcheckerror/1 has been executed. It is allowed to
%%%               move values out of floating point registers.
%%%
%%% The following instructions may be executed in any state:
%%%
%%%   fconv Src {fr,_}             
%%%   fmove Src {fr,_}		%% Move INTO floating point register.
%%%

float_op(Src, Dst, Vst0) ->
    foreach (fun(S) -> assert_freg_set(S, Vst0) end, Src),
    assert_fls(cleared, Vst0),
    Vst = set_fls(cleared, Vst0),
    set_freg(Dst, Vst).

assert_fls(Fls, Vst) ->
    case get_fls(Vst) of
	Fls -> ok;
	OtherFls -> error({bad_floating_point_state,OtherFls})
    end.

set_fls(Fls, #vst{current=#st{}=St}=Vst) when is_atom(Fls) ->
    Vst#vst{current=St#st{fls=Fls}}.

get_fls(#vst{current=#st{fls=Fls}}) when is_atom(Fls) -> Fls.

init_fregs() -> 0.

set_freg({fr,Fr}=Freg, #vst{current=#st{f=Fregs0}=St}=Vst)
  when is_integer(Fr), 0 =< Fr ->
    check_limit(Freg),
    Bit = 1 bsl Fr,
    if
	Fregs0 band Bit =:= 0 ->
	    Fregs = Fregs0 bor Bit,
	    Vst#vst{current=St#st{f=Fregs}};
	true -> Vst
    end;
set_freg(Fr, _) -> error({bad_target,Fr}).

assert_freg_set({fr,Fr}=Freg, #vst{current=#st{f=Fregs}})
  when is_integer(Fr), 0 =< Fr ->
    if
	(Fregs bsr Fr) band 1 =:= 0 ->
	    error({uninitialized_reg,Freg});
	true ->
	    ok
    end;
assert_freg_set(Fr, _) -> error({bad_source,Fr}).

%%% Maps

%% A single item list may be either a list or a register.
%%
%% A list with more than item must contain unique literals.
%%
%% An empty list is not allowed.

assert_unique_map_keys([]) ->
    %% There is no reason to use the get_map_elements and
    %% has_map_fields instructions with empty lists.
    error(empty_field_list);
assert_unique_map_keys([_]) ->
    ok;
assert_unique_map_keys([_,_|_]=Ls) ->
    Vs = [get_literal(L) || L <- Ls],
    case length(Vs) =:= sets:size(sets:from_list(Vs)) of
	true -> ok;
	false -> error(keys_not_unique)
    end.

%%%
%%% New binary matching instructions.
%%%

bsm_match_state(Slots) ->
    #ms{slots=Slots}.

bsm_validate_context(Reg, Vst) ->
    _ = bsm_get_context(Reg, Vst),
    ok.

bsm_get_context({x,X}=Reg, #vst{current=#st{x=Xs}}=_Vst) when is_integer(X) ->
    case gb_trees:lookup(X, Xs) of
	{value,#ms{}=Ctx} -> Ctx;
	{value,{fragile,#ms{}=Ctx}} -> Ctx;
	_ -> error({no_bsm_context,Reg})
    end;
bsm_get_context(Reg, _) -> error({bad_source,Reg}).

bsm_save(Reg, {atom,start}, Vst) ->
    %% Save point refering to where the match started.
    %% It is always valid. But don't forget to validate the context register.
    bsm_validate_context(Reg, Vst),
    Vst;
bsm_save(Reg, SavePoint, Vst) ->
    case bsm_get_context(Reg, Vst) of
	#ms{valid=Bits,slots=Slots}=Ctxt0 when SavePoint < Slots ->
	    Ctx = Ctxt0#ms{valid=Bits bor (1 bsl SavePoint),slots=Slots},
	    set_type_reg(Ctx, Reg, Vst);
	_ -> error({illegal_save,SavePoint})
    end.

bsm_restore(Reg, {atom,start}, Vst) ->
    %% (Mostly) automatic save point refering to where the match started.
    %% It is always valid. But don't forget to validate the context register.
    bsm_validate_context(Reg, Vst),
    Vst;
bsm_restore(Reg, SavePoint, Vst) ->
    case bsm_get_context(Reg, Vst) of
	#ms{valid=Bits,slots=Slots} when SavePoint < Slots ->
	    case Bits band (1 bsl SavePoint) of
		0 -> error({illegal_restore,SavePoint,not_set});
		_ -> Vst
	    end;
	_ -> error({illegal_restore,SavePoint,range})
    end.

select_val_branches(Src, Choices, Vst) ->
    Infer = infer_types(Src, Vst),
    select_val_branches_1(Choices, Infer, Vst).

select_val_branches_1([Val,{f,L}|T], Infer, Vst0) ->
    Vst = branch_state(L, Infer(Val, Vst0)),
    select_val_branches_1(T, Infer, Vst);
select_val_branches_1([], _, Vst) -> Vst.

infer_types(Src, Vst) ->
    case get_def(Src, Vst) of
        {bif,is_map,{f,_},[Map],_} ->
            fun({atom,true}, S) -> set_type_reg(map, Map, S);
               (_, S) -> S
            end;
        {bif,tuple_size,{f,_},[Tuple],_} ->
            fun({integer,Arity}, S) ->
                    Type0 = get_term_type(Tuple, S),
                    Type = upgrade_tuple_type({tuple,Arity}, Type0),
                    set_type(Type, Tuple, S);
               (_, S) -> S
            end;
        {bif,'=:=',{f,_},[ArityReg,{integer,_}=Val],_} when ArityReg =/= Src ->
            fun({atom,true}, S) ->
                    Infer = infer_types(ArityReg, S),
                    Infer(Val, S);
               (_, S) -> S
            end;
        _ ->
            fun(_, S) -> S end
    end.

%%%
%%% Keeping track of types.
%%%

set_alias(Reg1, Reg2, #vst{current=St0}=Vst) ->
    case Reg1 of
        {Kind,_} when Kind =:= x; Kind =:= y ->
            #st{aliases=Aliases0} = St0,
            Aliases = Aliases0#{Reg1=>Reg2,Reg2=>Reg1},
            St = St0#st{aliases=Aliases},
            Vst#vst{current=St};
        _ ->
            Vst
    end.

set_aliased_type(Type, Reg, #vst{current=#st{aliases=Aliases}}=Vst0) ->
    Vst1 = set_type(Type, Reg, Vst0),
    case Aliases of
        #{Reg:=OtherReg} ->
            Vst = set_type_reg(Type, OtherReg, Vst1),
            #vst{current=St} = Vst,
            Vst#vst{current=St#st{aliases=Aliases}};
        #{} ->
            Vst1
    end.

kill_aliases(Reg, #st{aliases=Aliases0}=St) ->
    case Aliases0 of
        #{Reg:=OtherReg} ->
            Aliases = maps:without([Reg,OtherReg], Aliases0),
            St#st{aliases=Aliases};
        #{} ->
            St
    end.

set_type(Type, {x,_}=Reg, Vst) -> set_type_reg(Type, Reg, Vst);
set_type(Type, {y,_}=Reg, Vst) -> set_type_y(Type, Reg, Vst);
set_type(_, _, #vst{}=Vst) -> Vst.

set_type_reg(Type, Src, Dst, Vst) ->
    case get_term_type_1(Src, Vst) of
        {fragile,_} ->
            set_type_reg(make_fragile(Type), Dst, Vst);
        _ ->
            set_type_reg(Type, Dst, Vst)
    end.

set_type_reg(Type, Reg, Vst) ->
    set_type_reg_expr(Type, none, Reg, Vst).

set_type_reg_expr(Type, Expr, {x,_}=Reg, Vst) ->
    set_type_x(Type, Expr, Reg, Vst);
set_type_reg_expr(Type, Expr, Reg, Vst) ->
    set_type_y(Type, Expr, Reg, Vst).

set_type_y(Type, Reg, Vst) ->
    set_type_y(Type, none, Reg, Vst).

set_type_x(Type, Expr, {x,X}=Reg, #vst{current=#st{x=Xs0,defs=Defs0}=St0}=Vst)
  when is_integer(X), 0 =< X ->
    check_limit(Reg),
    Xs = case gb_trees:lookup(X, Xs0) of
             none ->
                 gb_trees:insert(X, Type, Xs0);
             {value,{fragile,_}} ->
                 gb_trees:update(X, make_fragile(Type), Xs0);
             {value,_} ->
                 gb_trees:update(X, Type, Xs0)
         end,
    Defs = Defs0#{Reg=>Expr},
    St = kill_aliases(Reg, St0),
    Vst#vst{current=St#st{x=Xs,defs=Defs}};
set_type_x(Type, _Expr, Reg, #vst{}) ->
    error({invalid_store,Reg,Type}).

set_type_y(Type, Expr, {y,Y}=Reg, #vst{current=#st{y=Ys0,defs=Defs0}=St0}=Vst)
  when is_integer(Y), 0 =< Y ->
    check_limit(Reg),
    Ys = case gb_trees:lookup(Y, Ys0) of
	     none ->
		 error({invalid_store,Reg,Type});
	     {value,{catchtag,_}=Tag} ->
		 error(Tag);
	     {value,{trytag,_}=Tag} ->
		 error(Tag);
	     {value,_} ->
		 gb_trees:update(Y, Type, Ys0)
	 end,
    check_try_catch_tags(Type, Y, Ys0),
    Defs = Defs0#{Reg=>Expr},
    St = kill_aliases(Reg, St0),
    Vst#vst{current=St#st{y=Ys,defs=Defs}};
set_type_y(Type, _Expr, Reg, #vst{}) ->
    error({invalid_store,Reg,Type}).

make_fragile({fragile,_}=Type) -> Type;
make_fragile(Type) -> {fragile,Type}.

set_catch_end({y,Y}, #vst{current=#st{y=Ys0}=St}=Vst) ->
    Ys = gb_trees:update(Y, initialized, Ys0),
    Vst#vst{current=St#st{y=Ys}}.

check_try_catch_tags(Type, LastY, Ys) ->
    case is_try_catch_tag(Type) of
        false ->
            ok;
        true ->
            %% Every catch or try/catch must use a lower Y register
            %% number than any enclosing catch or try/catch. That will
            %% ensure that when the stack is scanned when an
            %% exception occurs, the innermost try/catch tag is found
            %% first.
            Bad = [{{y,Y},Tag} || {Y,Tag} <- gb_trees:to_list(Ys),
                                  Y < LastY, is_try_catch_tag(Tag)],
            case Bad of
                [] ->
                    ok;
                [_|_] ->
                    error({bad_try_catch_nesting,{y,LastY},Bad})
            end
    end.

is_try_catch_tag({catchtag,_}) -> true;
is_try_catch_tag({trytag,_}) -> true;
is_try_catch_tag(_) -> false.

is_reg_defined({x,_}=Reg, Vst) -> is_type_defined_x(Reg, Vst);
is_reg_defined({y,_}=Reg, Vst) -> is_type_defined_y(Reg, Vst);
is_reg_defined(V, #vst{}) -> error({not_a_register, V}).

is_type_defined_x({x,X}, #vst{current=#st{x=Xs}}) ->
    gb_trees:is_defined(X,Xs).

is_type_defined_y({y,Y}, #vst{current=#st{y=Ys}}) ->
    gb_trees:is_defined(Y,Ys).

assert_term(Src, Vst) ->
    get_term_type(Src, Vst),
    ok.

%% The possible types.
%%
%% First non-term types:
%%
%% initialized		Only for Y registers. Means that the Y register
%%			has been initialized with some valid term so that
%%			it is safe to pass to the garbage collector.
%%			NOT safe to use in any other way (will not crash the
%%			emulator, but clearly points to a bug in the compiler).
%%
%% {catchtag,[Lbl]}	A special term used within a catch. Must only be used
%%			by the catch instructions; NOT safe to use in other
%%			instructions.
%%
%% {trytag,[Lbl]}	A special term used within a try block. Must only be
%%			used by the catch instructions; NOT safe to use in other
%%			instructions.
%%
%% exception		Can only be used as a type returned by return_type/2
%%			(which gives the type of the value returned by a BIF).
%%			Thus 'exception' is never stored as type descriptor
%%			for a register.
%%
%% #ms{}	        A match context for bit syntax matching. We do allow
%%			it to moved/to from stack, but otherwise it must only
%%			be accessed by bit syntax matching instructions.
%%
%%
%% Normal terms:
%%
%% term			Any valid Erlang (but not of the special types above).
%%
%% bool			The atom 'true' or the atom 'false'.
%%
%% cons         	Cons cell: [_|_]
%%
%% nil			Empty list: []
%%
%% {tuple,[Sz]}		Tuple. An element has been accessed using
%%              	element/2 or setelement/3 so that it is known that
%%              	the type is a tuple of size at least Sz.
%%
%% {tuple,Sz}		Tuple. A test_arity instruction has been seen
%%           		so that it is known that the size is exactly Sz.
%%
%% {atom,[]}		Atom.
%% {atom,Atom}
%%
%% {integer,[]}		Integer.
%% {integer,Integer}
%%
%% {float,[]}		Float.
%% {float,Float}
%%
%% number		Integer or Float of unknown value
%%
%% map			Map.
%%
%%
%%
%% FRAGILITY
%% ---------
%%
%% The loop_rec/2 instruction may return a reference to a term that is
%% not part of the root set. That term or any part of it must not be
%% included in a garbage collection. Therefore, the term (or any part
%% of it) must not be stored in an Y register.
%%
%% Such terms are wrapped in a {fragile,Type} tuple, where Type is one
%% of the types described above.

assert_type(WantedType, Term, Vst) ->
    case get_term_type(Term, Vst) of
        {fragile,Type} ->
            assert_type(WantedType, Type);
        Type ->
            assert_type(WantedType, Type)
    end.

assert_type(Correct, Correct) -> ok;
assert_type(float, {float,_}) -> ok;
assert_type(tuple, {tuple,_}) -> ok;
assert_type(tuple, {literal,Tuple}) when is_tuple(Tuple) -> ok;
assert_type({tuple_element,I}, {tuple,[Sz]})
  when 1 =< I, I =< Sz ->
    ok;
assert_type({tuple_element,I}, {tuple,Sz})
  when is_integer(Sz), 1 =< I, I =< Sz ->
    ok;
assert_type({tuple_element,I}, {literal,Lit}) when I =< tuple_size(Lit) ->
    ok;
assert_type(cons, {literal,[_|_]}) ->
    ok;
assert_type(Needed, Actual) ->
    error({bad_type,{needed,Needed},{actual,Actual}}).

%% upgrade_tuple_type(NewTupleType, OldType) -> TupleType.
%%  upgrade_tuple_type/2 is used when linear code finds out more and
%%  more information about a tuple type, so that the type gets more
%%  specialized. If OldType is not a tuple type, the type information
%%  is inconsistent, and we know that some instructions will never
%%  be executed at run-time.

upgrade_tuple_type(NewType, {fragile,OldType}) ->
    make_fragile(upgrade_tuple_type_1(NewType, OldType));
upgrade_tuple_type(NewType, OldType) ->
    upgrade_tuple_type_1(NewType, OldType).

upgrade_tuple_type_1({tuple,[Sz]}, {tuple,[OldSz]}=T) when Sz < OldSz ->
    %% The old type has a higher value for the least tuple size.
    T;
upgrade_tuple_type_1({tuple,[Sz]}, {tuple,OldSz}=T)
  when is_integer(Sz), is_integer(OldSz), Sz =< OldSz ->
    %% The old size is exact, and the new size is smaller than the old size.
    T;
upgrade_tuple_type_1({tuple,_}=T, _) ->
    %% The new type information is exact or has a higher value for
    %% the least tuple size.
    %%     Note that inconsistencies are also handled in this
    %% clause, e.g. if the old type was an integer or a tuple accessed
    %% outside its size; inconsistences will generally cause an exception
    %% at run-time but are safe from our point of view.
    T.

get_tuple_size({integer,[]}) -> 0;
get_tuple_size({integer,Sz}) -> Sz;
get_tuple_size(_) -> 0.

validate_src(Ss, Vst) when is_list(Ss) ->
    foreach(fun(S) -> get_term_type(S, Vst) end, Ss).

%% get_move_term_type(Src, ValidatorState) -> Type
%%  Get the type of the source Src. The returned type Type will be
%%  a standard Erlang type (no catch/try tags). Match contexts are OK.

get_move_term_type(Src, Vst) ->
    case get_term_type_1(Src, Vst) of
	initialized -> error({unassigned,Src});
	{catchtag,_} -> error({catchtag,Src});
	{trytag,_} -> error({trytag,Src});
        tuple_in_progress -> error({tuple_in_progress,Src});
	Type -> Type
    end.

%% get_term_type(Src, ValidatorState) -> Type
%%  Get the type of the source Src. The returned type Type will be
%%  a standard Erlang type (no catch/try tags or match contexts).

get_term_type(Src, Vst) ->
    case get_move_term_type(Src, Vst) of
	#ms{} -> error({match_context,Src});
	Type -> Type
    end.

%% get_special_y_type(Src, ValidatorState) -> Type
%%  Return the type for the Y register without doing any validity checks.

get_special_y_type({y,_}=Reg, Vst) -> get_term_type_1(Reg, Vst);
get_special_y_type(Src, _) -> error({source_not_y_reg,Src}).

get_term_type_1(nil=T, _) -> T;
get_term_type_1({atom,A}=T, _) when is_atom(A) -> T;
get_term_type_1({float,F}=T, _) when is_float(F) -> T;
get_term_type_1({integer,I}=T, _) when is_integer(I) -> T;
get_term_type_1({literal,Map}, _) when is_map(Map) -> map;
get_term_type_1({literal,Tuple}, _) when is_tuple(Tuple) ->
    {tuple,tuple_size(Tuple)};
get_term_type_1({literal,_}=T, _) -> T;
get_term_type_1({x,X}=Reg, #vst{current=#st{x=Xs}}) when is_integer(X) ->
    case gb_trees:lookup(X, Xs) of
	{value,Type} -> Type;
	none -> error({uninitialized_reg,Reg})
    end;
get_term_type_1({y,Y}=Reg, #vst{current=#st{y=Ys}}) when is_integer(Y) ->
    case gb_trees:lookup(Y, Ys) of
 	none -> error({uninitialized_reg,Reg});
	{value,uninitialized} -> error({uninitialized_reg,Reg});
	{value,Type} -> Type
    end;
get_term_type_1(Src, _) -> error({bad_source,Src}).

get_def(Src, #vst{current=#st{defs=Defs}}) ->
    case Defs of
        #{Src:=Def} -> Def;
        #{} -> none
    end.

%% get_literal(Src) -> literal_value().
get_literal(nil) -> [];
get_literal({atom,A}) when is_atom(A) -> A;
get_literal({float,F}) when is_float(F) -> F;
get_literal({integer,I}) when is_integer(I) -> I;
get_literal({literal,L}) -> L;
get_literal(T) -> error({not_literal,T}).

branch_arities([Sz,{f,L}|T], Tuple, {tuple,[_]}=Type0, Vst0) when is_integer(Sz) ->
    Vst1 = set_aliased_type({tuple,Sz}, Tuple, Vst0),
    Vst = branch_state(L, Vst1),
    branch_arities(T, Tuple, Type0, Vst);
branch_arities([Sz,{f,L}|T], Tuple, {tuple,Sz}=Type, Vst0) when is_integer(Sz) ->
    %% The type is already correct. (This test is redundant.)
    Vst = branch_state(L, Vst0),
    branch_arities(T, Tuple, Type, Vst);
branch_arities([Sz0,{f,_}|T], Tuple, {tuple,Sz}=Type, Vst)
  when is_integer(Sz), Sz0 =/= Sz ->
    %% We already have an established different exact size for the tuple.
    %% This label can't possibly be reached.
    branch_arities(T, Tuple, Type, Vst);
branch_arities([], _, _, #vst{}=Vst) -> Vst.

branch_state(0, #vst{}=Vst) ->
    %% If the instruction fails, the stack may be scanned
    %% looking for a catch tag. Therefore the Y registers
    %% must be initialized at this point.
    verify_y_init(Vst),
    Vst;
branch_state(L, #vst{current=St,branched=B}=Vst) ->
    Vst#vst{
      branched=case gb_trees:is_defined(L, B) of
		   false ->
		       gb_trees:insert(L, St, B);
		   true ->
		       MergedSt = merge_states(L, St, B),
		       gb_trees:update(L, MergedSt, B)
	       end}.

%% merge_states/3 is used when there are more than one way to arrive
%% at this point, and the type states for the different paths has
%% to be merged. The type states are downgraded to the least common
%% subset for the subsequent code.

merge_states(L, St, Branched) when L =/= 0 ->
    case gb_trees:lookup(L, Branched) of
	none -> St;
	{value,OtherSt} when St =:= none -> OtherSt;
	{value,OtherSt} -> merge_states_1(St, OtherSt)
    end.

merge_states_1(#st{x=Xs0,y=Ys0,numy=NumY0,h=H0,ct=Ct0,aliases=Aliases0},
	       #st{x=Xs1,y=Ys1,numy=NumY1,h=H1,ct=Ct1,aliases=Aliases1}) ->
    NumY = merge_stk(NumY0, NumY1),
    Xs = merge_regs(Xs0, Xs1),
    Ys = merge_y_regs(Ys0, Ys1),
    Ct = merge_ct(Ct0, Ct1),
    Aliases = merge_aliases(Aliases0, Aliases1),
    #st{x=Xs,y=Ys,numy=NumY,h=min(H0, H1),ct=Ct,aliases=Aliases}.

merge_stk(S, S) -> S;
merge_stk(_, _) -> undecided.

merge_ct(S, S) -> S;
merge_ct(Ct0, Ct1) -> merge_ct_1(Ct0, Ct1).

merge_ct_1([C0|Ct0], [C1|Ct1]) ->
    [ordsets:from_list(C0++C1)|merge_ct_1(Ct0, Ct1)];
merge_ct_1([], []) -> [];
merge_ct_1(_, _) -> undecided.

merge_regs(Rs0, Rs1) ->
    Rs = merge_regs_1(gb_trees:to_list(Rs0), gb_trees:to_list(Rs1)),
    gb_trees_from_list(Rs).

merge_regs_1([Same|Rs1], [Same|Rs2]) ->
    [Same|merge_regs_1(Rs1, Rs2)];
merge_regs_1([{R1,_}|Rs1], [{R2,_}|_]=Rs2) when R1 < R2 ->
    merge_regs_1(Rs1, Rs2);
merge_regs_1([{R1,_}|_]=Rs1, [{R2,_}|Rs2]) when R1 > R2 ->
    merge_regs_1(Rs1, Rs2);
merge_regs_1([{R,Type1}|Rs1], [{R,Type2}|Rs2]) ->
    [{R,merge_types(Type1, Type2)}|merge_regs_1(Rs1, Rs2)];
merge_regs_1([], []) -> [];
merge_regs_1([], [_|_]) -> [];
merge_regs_1([_|_], []) -> [].

merge_y_regs(Rs0, Rs1) ->
    case {gb_trees:size(Rs0),gb_trees:size(Rs1)} of
	{Sz0,Sz1} when Sz0 < Sz1 ->
	    merge_y_regs_1(Sz0-1, Rs1, Rs0);
	{_,Sz1} ->
	    merge_y_regs_1(Sz1-1, Rs0, Rs1)
    end.

merge_y_regs_1(Y, S, Regs0) when Y >= 0 ->
    Type0 = gb_trees:get(Y, Regs0),
    case gb_trees:get(Y, S) of
	Type0 ->
	    merge_y_regs_1(Y-1, S, Regs0);
	Type1 ->
	    Type = merge_types(Type0, Type1),
	    Regs = gb_trees:update(Y, Type, Regs0),
	    merge_y_regs_1(Y-1, S, Regs)
    end;
merge_y_regs_1(_, _, Regs) -> Regs.

%% merge_types(Type1, Type2) -> Type
%%  Return the most specific type possible.
%%  Note: Type1 must NOT be the same as Type2.
merge_types({fragile,Same}=Type, Same) ->
    Type;
merge_types({fragile,T1}, T2) ->
    make_fragile(merge_types(T1, T2));
merge_types(Same, {fragile,Same}=Type) ->
    Type;
merge_types(T1, {fragile,T2}) ->
    make_fragile(merge_types(T1, T2));
merge_types(uninitialized=I, _) -> I;
merge_types(_, uninitialized=I) -> I;
merge_types(initialized=I, _) -> I;
merge_types(_, initialized=I) -> I;
merge_types({catchtag,T0},{catchtag,T1}) ->
    {catchtag,ordsets:from_list(T0++T1)};
merge_types({trytag,T0},{trytag,T1}) ->
    {trytag,ordsets:from_list(T0++T1)};
merge_types({tuple,A}, {tuple,B}) ->
    {tuple,[min(tuple_sz(A), tuple_sz(B))]};
merge_types({Type,A}, {Type,B}) 
  when Type =:= atom; Type =:= integer; Type =:= float ->
    if A =:= B -> {Type,A};
       true -> {Type,[]}
    end;
merge_types({Type,_}, number) 
  when Type =:= integer; Type =:= float ->
    number;
merge_types(number, {Type,_}) 
  when Type =:= integer; Type =:= float ->
    number;
merge_types(bool, {atom,A}) ->
    merge_bool(A);
merge_types({atom,A}, bool) ->
    merge_bool(A);
merge_types(cons, {literal,[_|_]}) ->
    cons;
merge_types({literal,[_|_]}, cons) ->
    cons;
merge_types({literal,[_|_]}, {literal,[_|_]}) ->
    cons;
merge_types(#ms{id=Id1,valid=B1,slots=Slots1},
	    #ms{id=Id2,valid=B2,slots=Slots2}) ->
    Id = if
             Id1 =:= Id2 -> Id1;
             true -> make_ref()
         end,
    #ms{id=Id,valid=B1 band B2,slots=min(Slots1, Slots2)};
merge_types(T1, T2) when T1 =/= T2 ->
    %% Too different. All we know is that the type is a 'term'.
    term.

tuple_sz([Sz]) -> Sz;
tuple_sz(Sz) -> Sz.

merge_bool([]) -> {atom,[]};
merge_bool(true) -> bool;
merge_bool(false) -> bool;
merge_bool(_) -> {atom,[]}.

merge_aliases(Al0, Al1) when map_size(Al0) =< map_size(Al1) ->
    maps:filter(fun(K, V) ->
                        case Al1 of
                            #{K:=V} -> true;
                            #{} -> false
                        end
                end, Al0);
merge_aliases(Al0, Al1) ->
    merge_aliases(Al1, Al0).

verify_y_init(#vst{current=#st{y=Ys}}) ->
    verify_y_init_1(gb_trees:to_list(Ys)).

verify_y_init_1([]) -> ok;
verify_y_init_1([{Y,uninitialized}|_]) ->
    error({uninitialized_reg,{y,Y}});
verify_y_init_1([{Y,{fragile,_}}|_]) ->
    %% Unsafe. This term may be outside any heap belonging
    %% to the process and would be corrupted by a GC.
    error({fragile_message_reference,{y,Y}});
verify_y_init_1([{_,_}|Ys]) ->
    verify_y_init_1(Ys).

verify_live(0, #vst{}) -> ok;
verify_live(N, #vst{current=#st{x=Xs}}) ->
    verify_live_1(N, Xs).

verify_live_1(0, _) -> ok;
verify_live_1(N, Xs) when is_integer(N) ->
    X = N-1,
    case gb_trees:is_defined(X, Xs) of
	false -> error({{x,X},not_live});
	true -> verify_live_1(X, Xs)
    end;
verify_live_1(N, _) -> error({bad_number_of_live_regs,N}).

verify_no_ct(#vst{current=#st{numy=none}}) -> ok;
verify_no_ct(#vst{current=#st{numy=undecided}}) ->
    error(unknown_size_of_stackframe);
verify_no_ct(#vst{current=#st{y=Ys}}) ->
    case [Y || Y <- gb_trees:to_list(Ys), verify_no_ct_1(Y)] of
	[] -> ok;
	CT -> error({unfinished_catch_try,CT})
    end.

verify_no_ct_1({_, {catchtag, _}}) -> true;
verify_no_ct_1({_, {trytag, _}}) -> true;
verify_no_ct_1({_, _}) -> false.

eat_heap(N, #vst{current=#st{h=Heap0}=St}=Vst) ->
    case Heap0-N of
	Neg when Neg < 0 ->
	    error({heap_overflow,{left,Heap0},{wanted,N}});
	Heap ->
	    Vst#vst{current=St#st{h=Heap}}
    end.

eat_heap_float(#vst{current=#st{hf=HeapFloats0}=St}=Vst) ->
    case HeapFloats0-1 of
	Neg when Neg < 0 ->
	    error({heap_overflow,{left,{HeapFloats0,floats}},{wanted,{1,floats}}});
	HeapFloats ->
	    Vst#vst{current=St#st{hf=HeapFloats}}
    end.

remove_fragility(#vst{current=#st{x=Xs0,y=Ys0}=St0}=Vst) ->
    F = fun(_, {fragile,Type}) -> Type;
           (_, Type) -> Type
        end,
    Xs = gb_trees:map(F, Xs0),
    Ys = gb_trees:map(F, Ys0),
    St = St0#st{x=Xs,y=Ys},
    Vst#vst{current=St}.

propagate_fragility(Type, Ss, Vst) ->
    F = fun(S) ->
                case get_term_type_1(S, Vst) of
                    {fragile,_} -> true;
                    _ -> false
                end
        end,
    case any(F, Ss) of
        true -> make_fragile(Type);
        false -> Type
    end.

bif_type('-', Src, Vst) ->
    arith_type(Src, Vst);
bif_type('+', Src, Vst) ->
    arith_type(Src, Vst);
bif_type('*', Src, Vst) ->
    arith_type(Src, Vst);
bif_type(abs, [Num], Vst) ->
    case get_term_type(Num, Vst) of
	{float,_}=T -> T;
	{integer,_}=T -> T;
	_ -> number
    end;
bif_type(float, _, _) -> {float,[]};
bif_type('/', _, _) -> {float,[]};
%% Integer operations.
bif_type(ceil, [_], _) -> {integer,[]};
bif_type('div', [_,_], _) -> {integer,[]};
bif_type(floor, [_], _) -> {integer,[]};
bif_type('rem', [_,_], _) -> {integer,[]};
bif_type(length, [_], _) -> {integer,[]};
bif_type(size, [_], _) -> {integer,[]};
bif_type(trunc, [_], _) -> {integer,[]};
bif_type(round, [_], _) -> {integer,[]};
bif_type('band', [_,_], _) -> {integer,[]};
bif_type('bor', [_,_], _) -> {integer,[]};
bif_type('bxor', [_,_], _) -> {integer,[]};
bif_type('bnot', [_], _) -> {integer,[]};
bif_type('bsl', [_,_], _) -> {integer,[]};
bif_type('bsr', [_,_], _) -> {integer,[]};
%% Booleans.
bif_type('==', [_,_], _) -> bool;
bif_type('/=', [_,_], _) -> bool;
bif_type('=<', [_,_], _) -> bool;
bif_type('<', [_,_], _) -> bool;
bif_type('>=', [_,_], _) -> bool;
bif_type('>', [_,_], _) -> bool;
bif_type('=:=', [_,_], _) -> bool;
bif_type('=/=', [_,_], _) -> bool;
bif_type('not', [_], _) -> bool;
bif_type('and', [_,_], _) -> bool;
bif_type('or', [_,_], _) -> bool;
bif_type('xor', [_,_], _) -> bool;
bif_type(is_atom, [_], _) -> bool;
bif_type(is_boolean, [_], _) -> bool;
bif_type(is_binary, [_], _) -> bool;
bif_type(is_float, [_], _) -> bool;
bif_type(is_function, [_], _) -> bool;
bif_type(is_integer, [_], _) -> bool;
bif_type(is_list, [_], _) -> bool;
bif_type(is_map, [_], _) -> bool;
bif_type(is_number, [_], _) -> bool;
bif_type(is_pid, [_], _) -> bool;
bif_type(is_port, [_], _) -> bool;
bif_type(is_reference, [_], _) -> bool;
bif_type(is_tuple, [_], _) -> bool;
%% Misc.
bif_type(node, [], _) -> {atom,[]};
bif_type(node, [_], _) -> {atom,[]};
bif_type(hd, [_], _) -> term;
bif_type(tl, [_], _) -> term;
bif_type(get, [_], _) -> term;
bif_type(Bif, _, _) when is_atom(Bif) -> term.

is_bif_safe('/=', 2) -> true;
is_bif_safe('<', 2) -> true;
is_bif_safe('=/=', 2) -> true;
is_bif_safe('=:=', 2) -> true;
is_bif_safe('=<', 2) -> true;
is_bif_safe('==', 2) -> true;
is_bif_safe('>', 2) -> true;
is_bif_safe('>=', 2) -> true;
is_bif_safe(is_atom, 1) -> true;
is_bif_safe(is_boolean, 1) -> true;
is_bif_safe(is_binary, 1) -> true;
is_bif_safe(is_bitstring, 1) -> true;
is_bif_safe(is_float, 1) -> true;
is_bif_safe(is_function, 1) -> true;
is_bif_safe(is_integer, 1) -> true;
is_bif_safe(is_list, 1) -> true;
is_bif_safe(is_map, 1) -> true;
is_bif_safe(is_number, 1) -> true;
is_bif_safe(is_pid, 1) -> true;
is_bif_safe(is_port, 1) -> true;
is_bif_safe(is_reference, 1) -> true;
is_bif_safe(is_tuple, 1) -> true;
is_bif_safe(get, 1) -> true;
is_bif_safe(self, 0) -> true;
is_bif_safe(node, 0) -> true;
is_bif_safe(_, _) -> false.

arith_type([A], Vst) ->
    %% Unary '+' or '-'.
    case get_term_type(A, Vst) of
	{float,_} -> {float,[]};
        _ -> number
    end;
arith_type([A,B], Vst) ->
    case {get_term_type(A, Vst),get_term_type(B, Vst)} of
	{{float,_},_} -> {float,[]};
	{_,{float,_}} -> {float,[]};
	{_,_} -> number
    end;
arith_type(_, _) -> number.

return_type({extfunc,M,F,A}, Vst) -> return_type_1(M, F, A, Vst);
return_type(_, _) -> term.

return_type_1(erlang, setelement, 3, Vst) ->
    Tuple = {x,1},
    TupleType =
	case get_term_type(Tuple, Vst) of
	    {tuple,_}=TT ->
		TT;
	    {literal,Lit} when is_tuple(Lit) ->
		{tuple,tuple_size(Lit)};
	    _ ->
		{tuple,[0]}
	end,
    case get_term_type({x,0}, Vst) of
	{integer,[]} -> TupleType;
	{integer,I} -> upgrade_tuple_type({tuple,[I]}, TupleType);
	_ -> TupleType
    end;
return_type_1(erlang, F, A, _) ->
    return_type_erl(F, A);
return_type_1(math, F, A, _) ->
    return_type_math(F, A);
return_type_1(M, F, A, _) when is_atom(M), is_atom(F), is_integer(A), A >= 0 ->
    term.

return_type_erl(exit, 1) -> exception;
return_type_erl(throw, 1) -> exception;
return_type_erl(error, 1) -> exception;
return_type_erl(error, 2) -> exception;
return_type_erl(F, A) when is_atom(F), is_integer(A), A >= 0 -> term.

return_type_math(cos, 1) -> {float,[]};
return_type_math(cosh, 1) -> {float,[]};
return_type_math(sin, 1) -> {float,[]};
return_type_math(sinh, 1) -> {float,[]};
return_type_math(tan, 1) -> {float,[]};
return_type_math(tanh, 1) -> {float,[]};
return_type_math(acos, 1) -> {float,[]};
return_type_math(acosh, 1) -> {float,[]};
return_type_math(asin, 1) -> {float,[]};
return_type_math(asinh, 1) -> {float,[]};
return_type_math(atan, 1) -> {float,[]};
return_type_math(atanh, 1) -> {float,[]};
return_type_math(erf, 1) -> {float,[]};
return_type_math(erfc, 1) -> {float,[]};
return_type_math(exp, 1) -> {float,[]};
return_type_math(log, 1) -> {float,[]};
return_type_math(log2, 1) -> {float,[]};
return_type_math(log10, 1) -> {float,[]};
return_type_math(sqrt, 1) -> {float,[]};
return_type_math(atan2, 2) -> {float,[]};
return_type_math(pow, 2) -> {float,[]};
return_type_math(ceil, 1) -> {float,[]};
return_type_math(floor, 1) -> {float,[]};
return_type_math(fmod, 2) -> {float,[]};
return_type_math(pi, 0) -> {float,[]};
return_type_math(F, A) when is_atom(F), is_integer(A), A >= 0 -> term.

check_limit({x,X}) when is_integer(X), X < 1023 ->
    %% Note: x(1023) is reserved for use by the BEAM loader.
    ok;
check_limit({y,Y}) when is_integer(Y), Y < 1024 ->
    ok;
check_limit({fr,Fr}) when is_integer(Fr), Fr < 1024 ->
    ok;
check_limit(_) ->
    error(limit).

min(A, B) when is_integer(A), is_integer(B), A < B -> A;
min(A, B) when is_integer(A), is_integer(B) -> B.

gb_trees_from_list(L) -> gb_trees:from_orddict(lists:sort(L)).

error(Error) -> throw(Error).
