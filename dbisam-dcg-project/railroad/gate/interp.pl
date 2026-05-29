% ============================================================
% interp.pl — the extracted-EBNF interpreter (tokenise + parse)
% ============================================================
%
% Decides whether a raw SQL string is in the language of the extracted
% EBNF (ebnf_rule/2 from grammar.ebnf.pl).
%
% Two stages:
%
%   1. TOKENISE (deterministic, maximal-munch). Whitespace and comments
%      are dropped; the remaining lexemes become tokens. The lexical
%      leaf recognisers are the DCG's OWN — identifier//1,
%      string_literal//1, integer_literal//1, decimal_literal//1 and
%      ws//0 are imported verbatim from grammar/dcg.pl and driven with
%      once/1 to take their greedy (longest) reading. So the tokeniser
%      shares the DCG's lexer rather than re-deriving it; only the
%      word/quoted distinction and the operator set are local.
%
%   2. PARSE the token list against the EBNF IR. Because tokenising
%      removes all lexical non-determinism (no half-consumed identifiers,
%      no 0-vs-1 whitespace choice points), the parser only ever explores
%      genuine grammar choices, which keeps it fast even on the large
%      production queries.
%
% Token shapes:
%   word(Upper)   bare word — may be a keyword OR an identifier
%   qident        "double-quoted" or [bracketed] identifier (never a keyword)
%   str           string literal
%   int           integer literal
%   dec           decimal literal
%   op(Atom)      operator / punctuation
%
% A keyword terminal term("FROM") matches word('FROM'); a leaf(identifier)
% matches word(_) or qident — exactly mirroring the DCG, where a bare
% word can serve as either a keyword or an identifier depending on
% position, while a quoted name can only be an identifier.

% NOTE: dcg is imported HERE ONLY. Scryer corrupts dcg's discontiguous
% generate_statement/2 if dcg is use_module'd by two modules at once, so
% interp is the single importer and re-exposes the DCG entry points the
% gate needs (dcg_accepts/1, dcg_generate/2). Callers import interp, not
% dcg.
:- module(interp, [ebnf_accepts/1, tokenize/2, dcg_accepts/1, dcg_generate/2]).

:- use_module('../../grammar/dcg').
:- use_module('../grammar.ebnf.pl').    % explicit .pl: Scryer mis-resolves the dotted name
:- use_module(library(lists)).

ebnf_accepts(Chars) :-
    tokenize(Chars, Tokens),
    once(phrase(ebnf(nt(statement)), Tokens)).   % must consume every token

% DCG entry points, re-exposed so callers never import dcg a second time.
dcg_accepts(Chars)        :- phrase(statement(_), Chars).
dcg_generate(Term, Chars) :- generate_statement(Term, Chars).

% ============================================================
% Stage 1 — tokeniser
% ============================================================

tokenize(Chars, Tokens) :-
    skip_ws(Chars, C1),
    tok_loop(C1, Tokens).

tok_loop([], []).
tok_loop(S0, [Tok|Ts]) :-
    S0 = [_|_],
    next_token(S0, Tok, S1),
    skip_ws(S1, S2),
    tok_loop(S2, Ts).

next_token(S0, Tok, S) :-
    ( S0 = ['\''|_]
    -> once(phrase(string_literal(_), S0, S)), Tok = str
    ; S0 = ['"'|_]
    -> once(phrase(identifier(_), S0, S)), Tok = qident
    ; S0 = ['['|_]
    -> once(phrase(identifier(_), S0, S)), Tok = qident
    ; starts_number(S0)
    -> ( once(phrase(decimal_literal(_), S0, S)) -> Tok = dec
       ; once(phrase(integer_literal(_), S0, S)), Tok = int )
    ; S0 = [C|_], ident_start_l(C)
    -> once(phrase(identifier(identifier(Atom)), S0, S)),
       tk_atom_upper(Atom, Up), Tok = word(Up)
    ; match_operator(S0, OpAtom, S)
    -> Tok = op(OpAtom)
    ; fail   % unlexable char (e.g. ODBC `{d '...'}`): not in the language,
    ).       % so tokenising fails and the string is rejected — as the DCG rejects it

starts_number([D|_])      :- digit_l(D).
starts_number(['.', D|_]) :- digit_l(D).

% Operators, longest first (mirrors the DCG's cmp_op / arith / punctuation).
match_operator(S0, Op, S) :- two_char_op(A, B, Op), S0 = [A, B|S].
match_operator([C|S], Op, S) :- one_char_op(C, Op).

two_char_op('<','=','<=').
two_char_op('>','=','>=').
two_char_op('<','>','<>').
two_char_op('!','=','!=').
two_char_op('|','|','||').

one_char_op('(','(').
one_char_op(')',')').
one_char_op(',',',').
one_char_op('.','.').
one_char_op('=','=').
one_char_op('<','<').
one_char_op('>','>').
one_char_op('+','+').
one_char_op('-','-').
one_char_op('*','*').
one_char_op('/','/').
one_char_op('?','?').
one_char_op(';',';').
one_char_op('\\','\\').

% Deterministic, greedy whitespace + comment skip (whitespace is elided,
% so committing to the maximal munch can never change the parse).
skip_ws(S0, S) :- ws_one(S0, S1), !, skip_ws(S1, S).
skip_ws(S, S).

ws_one([C|S], S)            :- ws_char_l(C).
ws_one(['-','-'|S0], S)     :- tk_line_comment_tail(S0, S).
ws_one(['/','*'|S0], S)     :- tk_block_comment_tail(S0, S).

tk_line_comment_tail(['\n'|S], S) :- !.
tk_line_comment_tail(['\r'|S], S) :- !.
tk_line_comment_tail([], []).
tk_line_comment_tail([_|S0], S)   :- tk_line_comment_tail(S0, S).

tk_block_comment_tail(['*','/'|S], S) :- !.
tk_block_comment_tail([_|S0], S)      :- tk_block_comment_tail(S0, S).

% --- char classes (local) ---
ws_char_l(' '). ws_char_l('\t'). ws_char_l('\n'). ws_char_l('\r').
ident_start_l(C) :- alpha_l(C).
ident_start_l('_').
alpha_l(C) :- char_code(C, X), ( X >= 0'a, X =< 0'z ; X >= 0'A, X =< 0'Z ).
digit_l(C) :- char_code(C, X), X >= 0'0, X =< 0'9.

tk_atom_upper(A, U) :- atom_chars(A, Cs), maplist(up_c, Cs, Us), atom_chars(U, Us).
up_c(C, U) :- ( char_code(C, X), X >= 0'a, X =< 0'z -> Y is X - 32, char_code(U, Y) ; U = C ).

% ============================================================
% Stage 2 — the IR interpreter over the token list
% ============================================================
%
% A straight recursive-descent DCG over the token list, with once/1 at
% the top (we only need to know whether SOME derivation consumes every
% token). Full backtracking is preserved — it is necessary because the
% DCG resolves the elided alias guards by backtracking (trying a keyword
% as an implicit alias, failing, retreating). Tokenising first removed
% all lexical non-determinism, so the only backtracking left is genuine
% grammar choice, which stays bounded.
%
% (A packrat / all-solutions memo was tried and rejected: PEG-style
% first-match memo breaks the alias backtracking, and an all-solutions
% memo enumerates the product of ambiguous sub-parses — exponential
% blow-up. once/1 over plain backtracking is correct and bounded here.)

ebnf(eps) --> [].
ebnf(term(T)) --> term_tok(T).
ebnf(leaf(L)) --> leaf_tok(L).
ebnf(nt(R)) --> { ebnf_rule(R, Node) }, ebnf(Node).
ebnf(seq([])) --> [].
ebnf(seq([N|Ns])) --> ebnf(N), ebnf(seq(Ns)).
ebnf(choice([N|_])) --> ebnf(N).
ebnf(choice([_|Ns])) --> { Ns = [_|_] }, ebnf(choice(Ns)).
ebnf(opt(N)) --> ebnf(N).
ebnf(opt(_)) --> [].
ebnf(zero_or_more(N)) --> ebnf(N), ebnf(zero_or_more(N)).
ebnf(zero_or_more(_)) --> [].
ebnf(one_or_more(N, none)) --> !, ebnf(N), ebnf(zero_or_more(N)).
ebnf(one_or_more(N, Sep)) --> ebnf(N), ebnf(zero_or_more(seq([Sep, N]))).

% A word terminal (keyword) matches a bare-word token, case-insensitively
% (the token text is already upper-cased). A symbol terminal matches an
% operator token exactly.
term_tok(T) --> { atom_chars(T, [C0|_]), word_char_l(C0) }, !, [word(T)].
term_tok(T) --> [op(T)].

leaf_tok(identifier)      --> [word(_)].
leaf_tok(identifier)      --> [qident].
leaf_tok(string_literal)  --> [str].
leaf_tok(integer_literal) --> [int].
leaf_tok(decimal_literal) --> [dec].

word_char_l(C) :- alpha_l(C).
word_char_l('_').
