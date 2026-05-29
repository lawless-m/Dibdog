:- use_module('../../grammar/dcg').
:- use_module(interp).
:- use_module(library(lists)).
:- use_module(library(format)).
:- initialization(main).
rd(P,Cs) :- open(P,read,S), rc(S,Cs), close(S).
rc(S,Cs) :- get_char(S,C), (C==end_of_file -> Cs=[] ; Cs=[C|R], rc(S,R)).
main :- loop, halt.
loop :- read_line(L),
  ( L == end_of_file -> true
  ; L == [] -> loop
  ; atom_chars(P, L),
    format("~s ... ", [L]), flush_output,
    rd(P, Cs),
    ( phrase(statement(_),Cs) -> D=acc ; D=rej ),
    ( ebnf_accepts(Cs) -> E=acc ; E=rej ),
    ( D==E -> format("~w~n",[D]) ; format("**MISMATCH dcg=~w ebnf=~w**~n",[D,E]) ),
    flush_output, loop ).
read_line(R) :- get_char(C),
  ( C==end_of_file -> R=end_of_file ; C=='\n' -> R=[] ; g([C],A), reverse(A,R) ).
g(A,R) :- get_char(C), ( C==end_of_file -> A=R ; C=='\n' -> A=R ; g([C|A],R) ).
