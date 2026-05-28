% fuzz-roundtrip.pl
%
% Round-trip stress test for the DBISAM DCG. Constructs a curated
% set of AST terms representing the breadth of grammar features,
% runs each through `generate_statement → parse_statement` and
% asserts the resulting AST equals the original.
%
% Failures usually mean a parser-generator asymmetry: e.g., the
% generator emits something the parser can't re-consume, or the
% parser produces a different AST shape than the generator
% started from. Both are real bugs worth fixing.
%
% Usage:
%   scryer-prolog -g main tools/fuzz-roundtrip.pl
%
% Exit codes:
%   0 — all tests passed
%   1 — at least one round-trip mismatch

:- use_module(library(lists)).
:- use_module('../grammar/dcg').
:- initialization(main).

main :-
    test_cases(Tests),
    length(Tests, N),
    format("running ~w round-trip tests~n", [N]),
    run_tests(Tests, 0, Pass, 0, Fail),
    format("~nfuzz-roundtrip complete: ~w passed, ~w failed~n", [Pass, Fail]),
    ( Fail =:= 0 -> halt(0) ; halt(1) ).

run_tests([], P, P, F, F).
run_tests([T|Ts], Pi, Po, Fi, Fo) :-
    ( roundtrip_ok(T)
    -> P1 is Pi+1, F1 = Fi
    ;  P1 = Pi, F1 is Fi+1,
       format("FAIL: ~q~n", [T]),
       describe_failure(T)
    ),
    run_tests(Ts, P1, Po, F1, Fo).

roundtrip_ok(AST) :-
    catch(
        ( generate_statement(AST, Chars),
          parse_statement(Chars, AST2),
          AST == AST2 ),
        _, false).

describe_failure(AST) :-
    ( catch(generate_statement(AST, Chars), _, fail)
    -> ( format("  generated:  ~s~n", [Chars]),
         ( catch(parse_statement(Chars, AST2), _, fail)
         -> format("  reparsed:   ~q~n", [AST2])
         ;  format("  reparse:    FAILED~n", [])
         )
       )
    ;  format("  generate:   FAILED~n", [])
    ).

% Curated test cases — each is a (description, ast) shape.
% Designed to exercise every grammar feature at least once.
test_cases(Tests) :-
    Tests = [
        % --- Simple SELECT ---
        select_statement(all_rows, [identifier(code)], [table(identifier('CUSTOMER'), no_alias)], []),
        select_statement(all_rows, [star], [table(identifier(t), no_alias)], []),
        select_statement(distinct, [identifier(code)], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [identifier(a), identifier(b), identifier(c)], [table(identifier(t), no_alias)], []),

        % --- Qualified columns ---
        select_statement(all_rows,
            [qualified(identifier(t), identifier(a))],
            [table(identifier(t), no_alias)], []),

        % --- Aliased projections ---
        select_statement(all_rows,
            [aliased(identifier(a), identifier(b))],
            [table(identifier(t), no_alias)], []),

        % --- Literals ---
        select_statement(all_rows, [integer_literal(42)], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [decimal_literal('3.14')], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [string_literal('hello')], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [string_literal('O\'Brien')], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [boolean_literal(true)], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [boolean_literal(false)], [table(identifier(t), no_alias)], []),
        select_statement(all_rows, [parameter(positional)], [table(identifier(t), no_alias)], []),

        % --- Arithmetic ---
        select_statement(all_rows,
            [arith(add, integer_literal(1), integer_literal(2))],
            [table(identifier(t), no_alias)], []),
        select_statement(all_rows,
            [arith(mul, identifier(a), identifier(b))],
            [table(identifier(t), no_alias)], []),
        select_statement(all_rows,
            [arith(add, integer_literal(1), arith(mul, integer_literal(2), integer_literal(3)))],
            [table(identifier(t), no_alias)], []),
        select_statement(all_rows,
            [neg(identifier(x))],
            [table(identifier(t), no_alias)], []),

        % --- Function calls ---
        select_statement(all_rows,
            [function_call('ABS', [integer_literal(1)])],
            [table(identifier(t), no_alias)], []),
        select_statement(all_rows,
            [function_call('COUNT', [star])],
            [table(identifier(t), no_alias)], []),
        select_statement(all_rows,
            [function_call('CONCAT', [string_literal(a), string_literal(b)])],
            [table(identifier(t), no_alias)], []),

        % --- CAST ---
        select_statement(all_rows,
            [cast(identifier(x), type('INTEGER', []))],
            [table(identifier(t), no_alias)], []),
        select_statement(all_rows,
            [cast(identifier(x), type('VARCHAR', [50]))],
            [table(identifier(t), no_alias)], []),

        % --- CASE ---
        select_statement(all_rows,
            [case_when([when(eq(identifier(a), integer_literal(1)), string_literal(y))], else(string_literal(n)))],
            [table(identifier(t), no_alias)], []),

        % --- JOIN ---
        select_statement(all_rows, [star],
            [joined(inner, table(identifier(a), no_alias), table(identifier(b), no_alias),
                eq(qualified(identifier(a), identifier(id)), qualified(identifier(b), identifier(id))))],
            []),
        select_statement(all_rows, [star],
            [joined(left, table(identifier(a), no_alias), table(identifier(b), no_alias),
                eq(qualified(identifier(a), identifier(id)), qualified(identifier(b), identifier(id))))],
            []),

        % --- WHERE / GROUP BY / HAVING / ORDER BY ---
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(eq(identifier(a), integer_literal(1)))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(and(eq(identifier(a), integer_literal(1)), eq(identifier(b), integer_literal(2))))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(not(eq(identifier(a), integer_literal(1))))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(in(identifier(a), [integer_literal(1), integer_literal(2)]))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(between(identifier(a), integer_literal(1), integer_literal(10)))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(like(identifier(a), string_literal('X%')))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(not_like(identifier(a), string_literal('X%')))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(is_null(identifier(a)))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [group_by([identifier(code)])]),
        select_statement(all_rows, [identifier(code), function_call('SUM', [identifier(price)])],
            [table(identifier(t), no_alias)],
            [group_by([identifier(code)]),
             having(cmp(gt, function_call('SUM', [identifier(price)]), integer_literal(100)))]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [order_by([ord(identifier(code), asc)])]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [order_by([ord(identifier(a), desc), ord(identifier(b), asc)])]),
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)], [top(5)]),

        % --- UNION ---
        union(
            select_statement(all_rows, [identifier(a)], [table(identifier(t), no_alias)], []),
            select_statement(all_rows, [identifier(b)], [table(identifier(u), no_alias)], [])),
        union_all(
            select_statement(all_rows, [identifier(a)], [table(identifier(t), no_alias)], []),
            select_statement(all_rows, [identifier(b)], [table(identifier(u), no_alias)], [])),

        % --- IN with subselect ---
        select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)],
            [where(in(identifier(a),
                subselect(select_statement(all_rows, [identifier(id)],
                    [table(identifier(u), no_alias)], []))))]),

        % --- SELECT INTO ---
        select_into(identifier(tmp),
            select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)], [])),

        % --- DML ---
        update_statement(identifier(t),
            [set(identifier(a), integer_literal(1))],
            where(eq(identifier(b), string_literal(x)))),
        delete_statement(identifier(t),
            where(eq(identifier(a), integer_literal(1)))),
        delete_statement(identifier(t), no_where),
        insert_statement(identifier(t), no_cols, values([integer_literal(1), string_literal(a)])),
        insert_statement(identifier(t), cols([identifier(a), identifier(b)]),
            values([integer_literal(1), string_literal(x)])),
        insert_statement(identifier(t), no_cols,
            from_select(select_statement(all_rows, [identifier(code)],
                [table(identifier(u), no_alias)], []))),

        % --- DDL ---
        drop_table(identifier(t), no_if_exists),
        drop_table(identifier(t), if_exists),
        alter_table(identifier(t), add_column(identifier(c), type('INTEGER', []))),
        create_index(identifier(idx), identifier(t),
            [index_col(identifier(a), default)], plain),
        create_index(identifier(idx), identifier(t),
            [index_col(identifier(a), desc), index_col(identifier(b), asc)], unique),
        drop_index(identifier(idx)),
        drop_index(qualified(identifier(t), identifier(idx))),
        rename_table(identifier(a), identifier(b)),

        % --- Maintenance ---
        maint(empty, identifier(t)),
        maint(optimize, identifier(t)),
        maint(verify, identifier(t)),
        maint(repair, identifier(t)),
        maint(upgrade, identifier(t)),

        % --- EXPORT/IMPORT ---
        export_table(identifier(t), identifier(f)),
        import_table(identifier(t), identifier(f)),

        % --- Transaction control ---
        start_transaction,
        commit(no_work),
        commit(work),
        rollback(no_work),
        rollback(work)
    ].
