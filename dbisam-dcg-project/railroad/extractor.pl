% ============================================================
% extractor.pl — DBISAM DCG → railroad-ready EBNF
% ============================================================
%
% Reads grammar/dcg.pl as Prolog TERMS (not as text) and emits a
% railroad-ready EBNF in three forms:
%
%   grammar.ebnf.pl    — Prolog facts (consumed by the equivalence gate)
%   grammar.ebnf.json  — JSON IR        (consumed by the SVG renderer)
%   grammar.ebnf       — human-readable EBNF text (the doc artifact)
%
% Clause-reading strategy (open question 4, resolved): read terms
% BEFORE DCG expansion via read_term/3. Pre-expansion bodies carry no
% S0/S threading, so the `_list`/`_list_rest` recursive-tail idiom is
% trivially detectable — `Body` is literally `elem(X), rest(Xs)` rather
% than a difference-list goal soup. This is "ask the grammar what its
% rules are" in the sense the doc intends: we parse Prolog terms with
% the reader, never regex source text.
%
% Mapping (per railroad-diagrams.md §"The extractor"):
%   conjunction A,B,C        -> seq([...])
%   ws / ws1                 -> elided (no element)
%   keyword(k)               -> term("K")            (uppercase terminal)
%   ['x'] / ['<','=']        -> term("x") / term("<=") (literal terminal)
%   {Goal} / !               -> elided
%   alternation (>1 clause)  -> choice([...])
%   clause + empty `[]`      -> opt(...)
%   identifier/string_literal/integer_literal/decimal_literal
%                            -> leaf(Name) (terminal box, not expanded)
%   any other nonterminal    -> nt(Name) (hyperlinked reference)
%
% THE one heuristic — the recursive-tail fold. A `*_rest` / `*_more`
% predicate whose clauses are an empty base plus self-recursive tails
% collapses to a zero-or-more loop; a head `elem, rest` in front of it
% becomes a OneOrMore (with separator when the tail carries one). This
% folds the `_list`/`_list_rest` family AND the accumulator families
% (or_rest, and_rest, add_rest, join_rest, union_rest, …) uniformly.
%
% Fails LOUDLY (throw/1) on any body construct it cannot map — never
% skips silently.

:- use_module(library(lists)).
:- use_module(library(format)).

:- initialization(main).

main :-
    catch(run, E, (report_error(E), halt(1))),
    halt(0).

report_error(E) :-
    format("extractor: ERROR ~q~n", [E]).

run :-
    GrammarFile = '../grammar/dcg.pl',
    read_file_terms(GrammarFile, Terms),
    collect_dcg_rules(Terms, Pairs),     % list of Name-Body
    ordered_names(Pairs, [], Names),     % names in first-appearance order
    % Build folded table for inlinable *_rest / *_more predicates.
    build_folds(Names, Pairs, Folds),
    % Directly self-recursive list heads (e.g. modifier_list) collapse
    % to a kept zero-or-more loop diagram rather than being inlined.
    build_loops(Names, Pairs, Loops),
    % Build the diagram node for every non-folded predicate.
    build_rules(Names, Pairs, Folds, Loops, Rules0),
    % Reachable set from `statement`, leaves/ws as boundaries.
    reachable_order(Rules0, Order),
    keep_rules(Order, Rules0, Rules),
    % Emit the three artifacts.
    emit_prolog('grammar.ebnf.pl', Order, Rules),
    emit_json('grammar.ebnf.json', Order, Rules),
    emit_text('grammar.ebnf', Order, Rules),
    length(Order, N),
    format("extractor: emitted ~w diagrams~n", [N]).

% ------------------------------------------------------------
% Reading the grammar as terms
% ------------------------------------------------------------

read_file_terms(File, Terms) :-
    open(File, read, Stream),
    read_terms_loop(Stream, Terms),
    close(Stream).

read_terms_loop(Stream, Terms) :-
    read_term(Stream, T, []),
    ( T == end_of_file
    -> Terms = []
    ; Terms = [T|Rest],
      read_terms_loop(Stream, Rest)
    ).

% Keep only DCG rules `(Head --> Body)`. Pushback heads (Head,PB-->Body)
% are not used by this grammar; if one appears, fail loudly.
collect_dcg_rules([], []).
collect_dcg_rules([T|Ts], Out) :-
    ( T = (H --> B)
    -> ( H = (_,_)
       -> throw(pushback_head_unsupported(H))
       ;  functor(H, Name, _),
          Out = [Name-B|Rest],
          collect_dcg_rules(Ts, Rest)
       )
    ;  collect_dcg_rules(Ts, Out)
    ).

ordered_names([], _, []).
ordered_names([N-_|Ps], Seen, Out) :-
    ( memberchk(N, Seen)
    -> ordered_names(Ps, Seen, Out)
    ;  Out = [N|Out1],
       ordered_names(Ps, [N|Seen], Out1)
    ).

bodies_of(_, [], []).
bodies_of(N, [N-B|Ps], [B|Bs]) :- !, bodies_of(N, Ps, Bs).
bodies_of(N, [_|Ps], Bs) :- bodies_of(N, Ps, Bs).

% ------------------------------------------------------------
% Classification sets
% ------------------------------------------------------------

elide_nt(ws).
elide_nt(ws1).

leaf_nt(identifier).
leaf_nt(string_literal).
leaf_nt(integer_literal).
leaf_nt(decimal_literal).

% ------------------------------------------------------------
% Body → node mapping
% ------------------------------------------------------------

body_to_node(Body, Node) :-
    conj_to_list(Body, Es),
    map_elems(Es, Ns0),
    drop_eps(Ns0, Ns),
    ( Ns = []       -> Node = eps
    ; Ns = [Single] -> Node = Single
    ; Node = seq(Ns)
    ).

conj_to_list((A,B), L) :- !, conj_to_list(A, LA), conj_to_list(B, LB), append(LA, LB, L).
conj_to_list(X, [X]).

map_elems([], []).
map_elems([E|Es], [N|Ns]) :- map_elem(E, N), map_elems(Es, Ns).

% Control constructs we must reject loudly if they ever appear at the
% DCG body level (they don't in this grammar, but silence would be a bug).
map_elem(G, _) :- ( G = (_ -> _) ; G = (\+ _) ; G = call(_) ), !,
    throw(unrecognised_construct(G)).
map_elem(G, eps) :- ( G == ! ; G == [] ), !.
map_elem({_}, eps) :- !.
map_elem((A;B), choice(Ns)) :- !,
    semic_to_list((A;B), Alts),
    map_alts(Alts, Ns).
map_elem(List, Node) :- List = [_|_], !,
    ( ground(List)
    -> list_text(List, T), Node = term(T)
    ;  Node = term('<char>')    % single-char terminal in a lexical helper;
    ).                          % never reachable (leaves are terminals)
map_elem(keyword(K), term(T)) :- !, atom_upper(K, T).
map_elem(G, Node) :-
    callable(G), !,
    functor(G, Name, _),
    ( elide_nt(Name) -> Node = eps
    ; leaf_nt(Name)  -> Node = leaf(Name)
    ; Node = nt(Name)
    ).
map_elem(G, _) :- throw(unrecognised_construct(G)).

semic_to_list((A;B), L) :- !, semic_to_list(A, LA), semic_to_list(B, LB), append(LA, LB, L).
semic_to_list(X, [X]).

map_alts([], []).
map_alts([A|As], [N|Ns]) :- body_to_node(A, N), map_alts(As, Ns).

drop_eps([], []).
drop_eps([eps|T], R) :- !, drop_eps(T, R).
drop_eps([X|T], [X|R]) :- drop_eps(T, R).

% List of single-char atoms → one terminal token atom.
list_text(Cs, Atom) :- atom_chars(Atom, Cs).

atom_upper(A, U) :-
    atom_chars(A, Cs),
    map_upper(Cs, Us),
    atom_chars(U, Us).

map_upper([], []).
map_upper([C|Cs], [U|Us]) :- char_upper(C, U), map_upper(Cs, Us).

char_upper(C, U) :-
    ( char_code(C, X), X >= 0'a, X =< 0'z
    -> Y is X - 32, char_code(U, Y)
    ;  U = C
    ).

% ------------------------------------------------------------
% The fold heuristic — inlinable recursive-tail predicates
% ------------------------------------------------------------

build_folds([], _, []).
build_folds([N|Ns], Pairs, Folds) :-
    bodies_of(N, Pairs, Bodies),
    ( foldable_rest(N, Bodies, FoldedNode)
    -> Folds = [N-FoldedNode|Rest]
    ;  Folds = Rest
    ),
    build_folds(Ns, Pairs, Rest).

% A predicate folds to a zero-or-more loop iff:
%   - it has >= 1 empty (`[]`) clause (the base)
%   - every other clause is a sequence whose LAST element is a
%     self-call nt(Name) (the recursive tail), with a non-empty prefix.
% The loop node is zero_or_more(Inner) where Inner is the prefix
% (or a choice of prefixes across multiple recursive clauses).
%
% `_rest`/`_more` helpers are INLINED into their caller (no own
% diagram); other self-recursive list heads keep their diagram but
% render as the loop.
foldable_rest(Name, Bodies, Loop) :-
    ( atom_suffix(Name, '_rest') ; atom_suffix(Name, '_more') ),
    self_recursive_loop(Name, Bodies, Loop).

build_loops([], _, []).
build_loops([N|Ns], Pairs, Loops) :-
    bodies_of(N, Pairs, Bodies),
    ( \+ ( atom_suffix(N, '_rest') ; atom_suffix(N, '_more') ),
      self_recursive_loop(N, Bodies, Loop)
    -> Loops = [N-Loop|Rest]
    ;  Loops = Rest
    ),
    build_loops(Ns, Pairs, Rest).

self_recursive_loop(Name, Bodies, zero_or_more(Inner)) :-
    map_bodies(Bodies, Nodes),
    partition_self(Nodes, Name, Prefixes, EpsCount),
    EpsCount >= 1,
    Prefixes = [_|_],
    ( Prefixes = [P] -> Inner = P ; Inner = choice(Prefixes) ).

map_bodies([], []).
map_bodies([B|Bs], [N|Ns]) :- body_to_node(B, N), map_bodies(Bs, Ns).

partition_self([], _, [], 0).
partition_self([Node|Ns], Name, Prefixes, EpsN) :-
    ( Node == eps
    -> partition_self(Ns, Name, Prefixes, E0), EpsN is E0 + 1
    ;  self_tail(Node, Name, Prefix),
       partition_self(Ns, Name, P0, EpsN),
       Prefixes = [Prefix|P0]
    ).

self_tail(seq(L), Name, Prefix) :-
    append(Init, [Last], L),
    Last == nt(Name),
    Init = [_|_],
    ( Init = [One] -> Prefix = One ; Prefix = seq(Init) ).

atom_suffix(Atom, Suf) :-
    atom_chars(Atom, AC),
    atom_chars(Suf, SC),
    append(_, SC, AC).

% ------------------------------------------------------------
% Build the diagram node per (non-folded) predicate
% ------------------------------------------------------------

build_rules([], _, _, _, []).
build_rules([N|Ns], Pairs, Folds, Loops, Rules) :-
    ( memberchk(N-_, Folds)         % folded away → no own diagram
    -> Rules = Rest
    ; ( elide_nt(N) ; leaf_nt(N) )  % structural / leaf → no diagram
    -> Rules = Rest
    ;  ( memberchk(N-LoopNode, Loops) % directly self-recursive list head
       -> Node0 = LoopNode
       ;  bodies_of(N, Pairs, Bodies),
          combine_clauses(Bodies, Node0)
       ),
       inline_node(Folds, Node0, Node1),
       normalize(Node1, Node),
       Rules = [N-Node|Rest]
    ),
    build_rules(Ns, Pairs, Folds, Loops, Rest).

% Combine a predicate's clauses: an empty clause makes the whole thing
% optional; otherwise multiple clauses are a choice.
combine_clauses(Bodies, Node) :-
    map_bodies(Bodies, Nodes),
    ( select(eps, Nodes, Rest)
    -> ( Rest = []       -> Node = eps
       ; Rest = [Single] -> Node = opt(Single)
       ; Node = opt(choice(Rest))
       )
    ; Nodes = [Single]   -> Node = Single
    ; Node = choice(Nodes)
    ).

% Replace nt(R) by R's folded loop wherever R is foldable.
inline_node(Folds, nt(R), Out) :-
    memberchk(R-F, Folds), !,
    inline_node(Folds, F, Out).
inline_node(_, nt(R), nt(R)) :- !.
inline_node(_, leaf(L), leaf(L)) :- !.
inline_node(_, term(T), term(T)) :- !.
inline_node(_, eps, eps) :- !.
inline_node(F, seq(L), seq(L2)) :- !, inline_list(F, L, L2).
inline_node(F, choice(L), choice(L2)) :- !, inline_list(F, L, L2).
inline_node(F, opt(N), opt(N2)) :- !, inline_node(F, N, N2).
inline_node(F, zero_or_more(N), zero_or_more(N2)) :- !, inline_node(F, N, N2).
inline_node(F, one_or_more(N,S), one_or_more(N2,S)) :- !, inline_node(F, N, N2).

inline_list(_, [], []).
inline_list(F, [N|Ns], [N2|Ns2]) :- inline_node(F, N, N2), inline_list(F, Ns, Ns2).

% ------------------------------------------------------------
% Normalisation: flatten nested seqs, collapse the head-list pattern
%   seq([E, zero_or_more(seq([Sep,E]))]) -> one_or_more(E, Sep)
%   seq([E, zero_or_more(E)])            -> one_or_more(E, none)
% ------------------------------------------------------------

normalize(nt(R), nt(R)) :- !.
normalize(leaf(L), leaf(L)) :- !.
normalize(term(T), term(T)) :- !.
normalize(eps, eps) :- !.
normalize(opt(N), opt(N2)) :- !, normalize(N, N2).
normalize(zero_or_more(N), zero_or_more(N2)) :- !, normalize(N, N2).
normalize(one_or_more(N,S), one_or_more(N2,S)) :- !, normalize(N, N2).
normalize(choice(L), choice(L2)) :- !, normalize_list(L, L2).
normalize(seq(L), Out) :- !,
    normalize_list(L, L1),
    flatten_seq(L1, L2),
    ( one_or_more_pattern(L2, OOM)
    -> Out = OOM
    ;  ( L2 = [Single] -> Out = Single ; Out = seq(L2) )
    ).

normalize_list([], []).
normalize_list([N|Ns], [N2|Ns2]) :- normalize(N, N2), normalize_list(Ns, Ns2).

flatten_seq([], []).
flatten_seq([seq(Inner)|T], Out) :- !, flatten_seq(Inner, FI), flatten_seq(T, FT), append(FI, FT, Out).
flatten_seq([X|T], [X|Out]) :- flatten_seq(T, Out).

one_or_more_pattern([E, zero_or_more(B)], one_or_more(E, Sep)) :-
    ( B == E
    -> Sep = none
    ;  B = seq([SepNode, E2]),
       E2 == E,
       Sep = SepNode
    ).

% ------------------------------------------------------------
% Reachability from `statement` (leaves/ws are boundaries)
% ------------------------------------------------------------

reachable_order(Rules, Order) :-
    bfs([statement], Rules, [], Order).

bfs([], _, _, []).
bfs([N|Queue], Rules, Seen, Out) :-
    ( memberchk(N, Seen)
    -> bfs(Queue, Rules, Seen, Out)
    ;  ( memberchk(N-Node, Rules)
       -> node_refs(Node, Refs0),
          exclude_known(Refs0, Rules, Seen, Refs),
          append(Queue, Refs, Queue1),
          Out = [N|Out1],
          bfs(Queue1, Rules, [N|Seen], Out1)
       ;  % referenced name with no rule (leaf already filtered) — skip
          bfs(Queue, Rules, [N|Seen], Out)
       )
    ).

exclude_known([], _, _, []).
exclude_known([R|Rs], Rules, Seen, Out) :-
    ( memberchk(R, Seen)
    -> exclude_known(Rs, Rules, Seen, Out)
    ;  memberchk(R-_, Rules)
    -> Out = [R|Out1], exclude_known(Rs, Rules, Seen, Out1)
    ;  exclude_known(Rs, Rules, Seen, Out)   % leaf/elide: not a diagram
    ).

node_refs(Node, Refs) :- node_refs_(Node, [], Refs).
node_refs_(nt(R), Acc, [R|Acc]) :- !.
node_refs_(leaf(_), Acc, Acc) :- !.
node_refs_(term(_), Acc, Acc) :- !.
node_refs_(eps, Acc, Acc) :- !.
node_refs_(opt(N), Acc, Out) :- !, node_refs_(N, Acc, Out).
node_refs_(zero_or_more(N), Acc, Out) :- !, node_refs_(N, Acc, Out).
node_refs_(one_or_more(N,S), Acc, Out) :- !,
    node_refs_(N, Acc, Acc1), ( S == none -> Out = Acc1 ; node_refs_(S, Acc1, Out) ).
node_refs_(seq(L), Acc, Out) :- !, node_refs_list(L, Acc, Out).
node_refs_(choice(L), Acc, Out) :- !, node_refs_list(L, Acc, Out).

node_refs_list([], Acc, Acc).
node_refs_list([N|Ns], Acc, Out) :- node_refs_(N, Acc, Acc1), node_refs_list(Ns, Acc1, Out).

keep_rules([], _, []).
keep_rules([N|Ns], Rules, [N-Node|Out]) :-
    memberchk(N-Node, Rules), !,
    keep_rules(Ns, Rules, Out).
keep_rules([_|Ns], Rules, Out) :- keep_rules(Ns, Rules, Out).

% ------------------------------------------------------------
% Emit: Prolog facts
% ------------------------------------------------------------

emit_prolog(File, Order, Rules) :-
    open(File, write, S),
    format(S, "% Auto-generated by railroad/extractor.pl — do not edit by hand.~n", []),
    format(S, "% EBNF intermediate representation for the railroad diagrams.~n~n", []),
    format(S, ":- module(ebnf, [ebnf_rule/2, ebnf_start/1, ebnf_leaf/1, ebnf_order/1]).~n~n", []),
    format(S, "ebnf_start(statement).~n~n", []),
    emit_leaf_facts(S),
    nl(S),
    emit_order_fact(S, Order),
    nl(S),
    emit_rule_facts(S, Rules),
    close(S).

emit_leaf_facts(S) :-
    ( leaf_nt(L),
      format(S, "ebnf_leaf(~q).~n", [L]),
      fail
    ; true
    ).

emit_order_fact(S, Order) :-
    format(S, "ebnf_order(~q).~n", [Order]).

emit_rule_facts(_, []).
emit_rule_facts(S, [N-Node|Rest]) :-
    format(S, "ebnf_rule(~q, ", [N]),
    write_term(S, Node, [quoted(true)]),
    format(S, ").~n", []),
    emit_rule_facts(S, Rest).

% ------------------------------------------------------------
% Emit: JSON
% ------------------------------------------------------------

emit_json(File, Order, Rules) :-
    open(File, write, S),
    format(S, "{~n", []),
    format(S, "  \"start\": \"statement\",~n", []),
    json_leaves(S),
    json_order(S, Order),
    format(S, "  \"rules\": [~n", []),
    json_rules(S, Rules),
    format(S, "~n  ]~n}~n", []),
    close(S).

json_leaves(S) :-
    findall(L, leaf_nt(L), Ls),
    format(S, "  \"leaves\": [", []),
    json_str_list(S, Ls),
    format(S, "],~n", []).

json_order(S, Order) :-
    format(S, "  \"order\": [", []),
    json_str_list(S, Order),
    format(S, "],~n", []).

json_str_list(_, []).
json_str_list(S, [X]) :- !, json_string(S, X).
json_str_list(S, [X|Xs]) :- json_string(S, X), format(S, ", ", []), json_str_list(S, Xs).

json_string(S, A) :-
    atom_chars(A, Cs),
    format(S, "\"", []),
    json_escape(S, Cs),
    format(S, "\"", []).

json_escape(_, []).
json_escape(S, [C|Cs]) :-
    char_code(C, Code),
    ( Code =:= 34 -> emit_bslash(S), emit_dquote(S)   % "  -> \"
    ; Code =:= 92 -> emit_bslash(S), emit_bslash(S)   % \  -> \\
    ; put_char(S, C)
    ),
    json_escape(S, Cs).

emit_dquote(S) :- char_code(D, 34), put_char(S, D).
emit_bslash(S) :- char_code(B, 92), put_char(S, B).

json_rules(_, []).
json_rules(S, [N-Node|Rest]) :-
    format(S, "    {\"name\": ", []),
    json_string(S, N),
    format(S, ", \"node\": ", []),
    json_node(S, Node),
    ( Rest = [] -> format(S, "}", []) ; format(S, "},~n", []) ),
    json_rules(S, Rest).

json_node(S, term(T)) :- !, format(S, "{\"t\":\"term\",\"text\":", []), json_string(S, T), format(S, "}", []).
json_node(S, leaf(L)) :- !, format(S, "{\"t\":\"leaf\",\"name\":", []), json_string(S, L), format(S, "}", []).
json_node(S, nt(R))   :- !, format(S, "{\"t\":\"nt\",\"name\":", []), json_string(S, R), format(S, "}", []).
json_node(S, eps)     :- !, format(S, "{\"t\":\"eps\"}", []).
json_node(S, seq(L))  :- !, format(S, "{\"t\":\"seq\",\"items\":[", []), json_node_list(S, L), format(S, "]}", []).
json_node(S, choice(L)) :- !, format(S, "{\"t\":\"choice\",\"items\":[", []), json_node_list(S, L), format(S, "]}", []).
json_node(S, opt(N))  :- !, format(S, "{\"t\":\"opt\",\"item\":", []), json_node(S, N), format(S, "}", []).
json_node(S, zero_or_more(N)) :- !, format(S, "{\"t\":\"zeroOrMore\",\"item\":", []), json_node(S, N), format(S, "}", []).
json_node(S, one_or_more(N, Sep)) :- !,
    format(S, "{\"t\":\"oneOrMore\",\"item\":", []), json_node(S, N),
    ( Sep == none -> format(S, ",\"sep\":null}", [])
    ; format(S, ",\"sep\":", []), json_node(S, Sep), format(S, "}", [])
    ).

json_node_list(_, []).
json_node_list(S, [X]) :- !, json_node(S, X).
json_node_list(S, [X|Xs]) :- json_node(S, X), format(S, ",", []), json_node_list(S, Xs).

% ------------------------------------------------------------
% Emit: human-readable EBNF text
% ------------------------------------------------------------

emit_text(File, Order, Rules) :-
    open(File, write, S),
    format(S, "(* Auto-generated by railroad/extractor.pl from grammar/dcg.pl. *)~n", []),
    format(S, "(* Whitespace is elided; keywords are uppercase terminals. *)~n", []),
    format(S, "(* Lexical leaves drawn as terminals: identifier, string-literal,~n", []),
    format(S, "   integer-literal, decimal-literal. *)~n~n", []),
    emit_text_rules(S, Order, Rules),
    close(S).

emit_text_rules(_, [], _).
emit_text_rules(S, [N|Ns], Rules) :-
    ( memberchk(N-Node, Rules)
    -> format(S, "~a ::= ", [N]),
       text_node(S, Node),
       format(S, " ;~n", [])
    ; true
    ),
    emit_text_rules(S, Ns, Rules).

text_node(S, term(T)) :- !, format(S, "\"~a\"", [T]).
text_node(S, leaf(L)) :- !, format(S, "~a", [L]).
text_node(S, nt(R))   :- !, format(S, "~a", [R]).
text_node(S, eps)     :- !, format(S, "(* empty *)", []).
text_node(S, opt(N))  :- !, format(S, "[ ", []), text_node(S, N), format(S, " ]", []).
text_node(S, zero_or_more(N)) :- !, format(S, "{ ", []), text_node(S, N), format(S, " }", []).
text_node(S, one_or_more(N, Sep)) :- !,
    text_node(S, N),
    ( Sep == none -> format(S, " { ", []), text_node(S, N), format(S, " }", [])
    ; format(S, " { ", []), text_node(S, Sep), format(S, " ", []), text_node(S, N), format(S, " }", [])
    ).
text_node(S, seq(L)) :- !, text_seq(S, L).
text_node(S, choice(L)) :- !, format(S, "( ", []), text_choice(S, L), format(S, " )", []).

text_seq(_, []).
text_seq(S, [X]) :- !, text_node_p(S, X).
text_seq(S, [X|Xs]) :- text_node_p(S, X), format(S, " ", []), text_seq(S, Xs).

text_choice(_, []).
text_choice(S, [X]) :- !, text_node(S, X).
text_choice(S, [X|Xs]) :- text_node(S, X), format(S, " | ", []), text_choice(S, Xs).

% Parenthesise a choice/seq inside a sequence for readability.
text_node_p(S, choice(L)) :- !, format(S, "( ", []), text_choice(S, L), format(S, " )", []).
text_node_p(S, N) :- text_node(S, N).
