*----------------------------------------------------------------------*
* ZCL_JSEVAL - Minimal JavaScript evaluator in ABAP
* Port of pkg/jseval/jseval.go
* Supports: numbers, strings, variables, arithmetic, comparisons,
* if/else, while, for, functions, closures, objects, arrays, classes,
* switch, typeof, console.log
*----------------------------------------------------------------------*

*----------------------------------------------------------------------*
* Local class: lcl_obj — object property store
*----------------------------------------------------------------------*
CLASS lcl_obj DEFINITION.
  PUBLIC SECTION.
    TYPES:
      BEGIN OF ty_prop,
        key TYPE string,
        val TYPE REF TO data,  " REF TO ty_value
      END OF ty_prop,
      tt_props TYPE HASHED TABLE OF ty_prop WITH UNIQUE KEY key.

    DATA props TYPE tt_props.

    METHODS get
      IMPORTING iv_key         TYPE string
      RETURNING VALUE(rr_val)  TYPE REF TO data.
    METHODS set
      IMPORTING iv_key TYPE string
                ir_val TYPE REF TO data.
    METHODS has
      IMPORTING iv_key        TYPE string
      RETURNING VALUE(rv_yes) TYPE abap_bool.
    METHODS copy_from
      IMPORTING io_other TYPE REF TO lcl_obj.
ENDCLASS.

CLASS lcl_obj IMPLEMENTATION.
  METHOD get.
    READ TABLE props WITH TABLE KEY key = iv_key ASSIGNING FIELD-SYMBOL(<p>).
    IF sy-subrc = 0.
      rr_val = <p>-val.
    ENDIF.
  ENDMETHOD.

  METHOD set.
    DATA ls TYPE ty_prop.
    ls-key = iv_key.
    ls-val = ir_val.
    READ TABLE props WITH TABLE KEY key = iv_key ASSIGNING FIELD-SYMBOL(<p>).
    IF sy-subrc = 0.
      <p>-val = ir_val.
    ELSE.
      INSERT ls INTO TABLE props.
    ENDIF.
  ENDMETHOD.

  METHOD has.
    READ TABLE props WITH TABLE KEY key = iv_key TRANSPORTING NO FIELDS.
    rv_yes = boolc( sy-subrc = 0 ).
  ENDMETHOD.

  METHOD copy_from.
    LOOP AT io_other->props ASSIGNING FIELD-SYMBOL(<p>).
      set( iv_key = <p>-key ir_val = <p>-val ).
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.

*----------------------------------------------------------------------*
* Local class: lcl_arr — array (ordered list of values)
*----------------------------------------------------------------------*
CLASS lcl_arr DEFINITION.
  PUBLIC SECTION.
    DATA items TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY. " each REF TO ty_value
    METHODS push IMPORTING ir_val TYPE REF TO data.
    METHODS get_item
      IMPORTING iv_idx        TYPE i
      RETURNING VALUE(rr_val) TYPE REF TO data.
    METHODS length RETURNING VALUE(rv_len) TYPE i.
ENDCLASS.

CLASS lcl_arr IMPLEMENTATION.
  METHOD push.
    APPEND ir_val TO items.
  ENDMETHOD.
  METHOD get_item.
    DATA lv_idx TYPE i.
    lv_idx = iv_idx + 1. " ABAP 1-based
    IF lv_idx >= 1 AND lv_idx <= lines( items ).
      READ TABLE items INDEX lv_idx INTO rr_val.
    ENDIF.
  ENDMETHOD.
  METHOD length.
    rv_len = lines( items ).
  ENDMETHOD.
ENDCLASS.

*----------------------------------------------------------------------*
* Forward declarations
*----------------------------------------------------------------------*
CLASS lcl_env DEFINITION DEFERRED.
CLASS lcl_parser DEFINITION DEFERRED.

*----------------------------------------------------------------------*
* Types
*----------------------------------------------------------------------*
TYPES:
  " Value types: 0=undefined, 1=number, 2=string, 3=bool,
  "              4=function, 5=null, 6=object, 7=array
  BEGIN OF ty_value,
    type TYPE i,
    num  TYPE f,
    str  TYPE string,
    obj  TYPE REF TO lcl_obj,
    arr  TYPE REF TO lcl_arr,
    fn   TYPE REF TO data,  " REF TO ty_function (forward ref)
  END OF ty_value.

TYPES:
  " Token: 0=number, 1=string, 2=ident, 3=op, 4=punc, 5=eof
  BEGIN OF ty_token,
    kind TYPE i,
    val  TYPE string,
  END OF ty_token,
  tt_tokens TYPE STANDARD TABLE OF ty_token WITH DEFAULT KEY.

TYPES:
  " Switch case
  BEGIN OF ty_switch_case,
    expr TYPE REF TO data,  " REF TO ty_node
    body TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY,
  END OF ty_switch_case,
  tt_switch_cases TYPE STANDARD TABLE OF ty_switch_case WITH DEFAULT KEY.

TYPES:
  " Class method
  BEGIN OF ty_class_method,
    name   TYPE string,
    params TYPE STANDARD TABLE OF string WITH DEFAULT KEY,
    body   TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY,
    is_ctor TYPE abap_bool,
  END OF ty_class_method,
  tt_class_methods TYPE STANDARD TABLE OF ty_class_method WITH DEFAULT KEY.

" Node kinds
CONSTANTS:
  c_node_number        TYPE i VALUE 0,
  c_node_string        TYPE i VALUE 1,
  c_node_ident         TYPE i VALUE 2,
  c_node_binop         TYPE i VALUE 3,
  c_node_unaryop       TYPE i VALUE 4,
  c_node_assign        TYPE i VALUE 5,
  c_node_var           TYPE i VALUE 6,
  c_node_if            TYPE i VALUE 7,
  c_node_while         TYPE i VALUE 8,
  c_node_block         TYPE i VALUE 9,
  c_node_call          TYPE i VALUE 10,
  c_node_func_decl     TYPE i VALUE 11,
  c_node_return        TYPE i VALUE 12,
  c_node_object        TYPE i VALUE 13,
  c_node_array         TYPE i VALUE 14,
  c_node_member_access TYPE i VALUE 15,
  c_node_member_assign TYPE i VALUE 16,
  c_node_method_call   TYPE i VALUE 17,
  c_node_for           TYPE i VALUE 18,
  c_node_switch        TYPE i VALUE 19,
  c_node_typeof        TYPE i VALUE 20,
  c_node_new           TYPE i VALUE 21,
  c_node_class         TYPE i VALUE 22,
  c_node_break         TYPE i VALUE 23,
  c_node_continue      TYPE i VALUE 24.

TYPES:
  " AST Node
  BEGIN OF ty_node,
    kind     TYPE i,
    num      TYPE f,
    str      TYPE string,
    op       TYPE string,
    left     TYPE REF TO data,  " REF TO ty_node
    right    TYPE REF TO data,  " REF TO ty_node
    args     TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY,
    body     TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY,
    params   TYPE STANDARD TABLE OF string WITH DEFAULT KEY,
    cond     TYPE REF TO data,  " REF TO ty_node
    els      TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY,
    " For loop
    init     TYPE REF TO data,  " REF TO ty_node
    update   TYPE REF TO data,  " REF TO ty_node
    " Member access
    object   TYPE REF TO data,  " REF TO ty_node
    property TYPE string,
    prop_expr TYPE REF TO data, " REF TO ty_node
    " Switch
    cases    TYPE tt_switch_cases,
    " Class
    methods  TYPE tt_class_methods,
  END OF ty_node.

TYPES:
  " Function
  BEGIN OF ty_function,
    name    TYPE string,
    params  TYPE STANDARD TABLE OF string WITH DEFAULT KEY,
    body    TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY,
    closure TYPE REF TO lcl_env,
  END OF ty_function.

*----------------------------------------------------------------------*
* lcl_env — variable environment (scope)
*----------------------------------------------------------------------*
CLASS lcl_env DEFINITION.
  PUBLIC SECTION.
    TYPES:
      BEGIN OF ty_var_entry,
        name TYPE string,
        val  TYPE ty_value,
      END OF ty_var_entry,
      tt_vars TYPE HASHED TABLE OF ty_var_entry WITH UNIQUE KEY name.

    DATA vars       TYPE tt_vars.
    DATA parent     TYPE REF TO lcl_env.
    DATA output     TYPE REF TO data.  " REF TO string
    DATA returning  TYPE abap_bool.
    DATA ret_val    TYPE ty_value.
    DATA breaking   TYPE abap_bool.
    DATA continuing TYPE abap_bool.

    METHODS constructor
      IMPORTING io_parent TYPE REF TO lcl_env OPTIONAL.
    METHODS get
      IMPORTING iv_name       TYPE string
      RETURNING VALUE(rs_val) TYPE ty_value.
    METHODS set
      IMPORTING iv_name TYPE string
                is_val  TYPE ty_value.
    METHODS define
      IMPORTING iv_name TYPE string
                is_val  TYPE ty_value.
    METHODS append_output
      IMPORTING iv_text TYPE string.
    METHODS get_output
      RETURNING VALUE(rv_out) TYPE string.
ENDCLASS.

CLASS lcl_env IMPLEMENTATION.
  METHOD constructor.
    parent = io_parent.
    IF io_parent IS BOUND.
      output = io_parent->output.
    ELSE.
      DATA lv_str TYPE string.
      CREATE DATA output LIKE lv_str.
    ENDIF.
  ENDMETHOD.

  METHOD get.
    READ TABLE vars WITH TABLE KEY name = iv_name ASSIGNING FIELD-SYMBOL(<v>).
    IF sy-subrc = 0.
      rs_val = <v>-val.
      RETURN.
    ENDIF.
    IF parent IS BOUND.
      rs_val = parent->get( iv_name ).
      RETURN.
    ENDIF.
    " Return undefined
    rs_val-type = 0.
  ENDMETHOD.

  METHOD set.
    " Walk up to find existing variable
    DATA lo_cur TYPE REF TO lcl_env.
    lo_cur = me.
    WHILE lo_cur IS BOUND.
      READ TABLE lo_cur->vars WITH TABLE KEY name = iv_name ASSIGNING FIELD-SYMBOL(<v>).
      IF sy-subrc = 0.
        <v>-val = is_val.
        RETURN.
      ENDIF.
      lo_cur = lo_cur->parent.
    ENDWHILE.
    " Not found — define in current scope
    DATA ls_entry TYPE ty_var_entry.
    ls_entry-name = iv_name.
    ls_entry-val  = is_val.
    INSERT ls_entry INTO TABLE vars.
  ENDMETHOD.

  METHOD define.
    DATA ls_entry TYPE ty_var_entry.
    ls_entry-name = iv_name.
    ls_entry-val  = is_val.
    READ TABLE vars WITH TABLE KEY name = iv_name ASSIGNING FIELD-SYMBOL(<v>).
    IF sy-subrc = 0.
      <v>-val = is_val.
    ELSE.
      INSERT ls_entry INTO TABLE vars.
    ENDIF.
  ENDMETHOD.

  METHOD append_output.
    FIELD-SYMBOLS <str> TYPE string.
    ASSIGN output->* TO <str>.
    <str> = <str> && iv_text.
  ENDMETHOD.

  METHOD get_output.
    FIELD-SYMBOLS <str> TYPE string.
    ASSIGN output->* TO <str>.
    rv_out = <str>.
  ENDMETHOD.
ENDCLASS.

*----------------------------------------------------------------------*
* lcl_parser — tokenizer + recursive descent parser
*----------------------------------------------------------------------*
CLASS lcl_parser DEFINITION.
  PUBLIC SECTION.
    DATA tokens TYPE tt_tokens.
    DATA pos    TYPE i.

    METHODS constructor
      IMPORTING it_tokens TYPE tt_tokens.
    METHODS peek
      RETURNING VALUE(rs_tok) TYPE ty_token.
    METHODS next
      RETURNING VALUE(rs_tok) TYPE ty_token.
    METHODS expect
      IMPORTING iv_val TYPE string.
    METHODS parse_program
      RETURNING VALUE(rt_stmts) TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    METHODS parse_statement
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_var
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_if
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_while
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_for
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_switch
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_class
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_func
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_return
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_block
      RETURNING VALUE(rt_stmts) TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    METHODS parse_body
      RETURNING VALUE(rt_stmts) TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    METHODS parse_expr
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_assign
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_or
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_and
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_equality
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_comparison
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_add_sub
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_mul_div
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_unary
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_postfix
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_primary
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_array_literal
      RETURNING VALUE(rr_node) TYPE REF TO data.
    METHODS parse_object_literal
      RETURNING VALUE(rr_node) TYPE REF TO data.
ENDCLASS.

CLASS lcl_parser IMPLEMENTATION.
  METHOD constructor.
    tokens = it_tokens.
    pos = 0.
  ENDMETHOD.

  METHOD peek.
    IF pos >= lines( tokens ).
      rs_tok-kind = 5.
      rs_tok-val = ``.
    ELSE.
      READ TABLE tokens INDEX pos + 1 INTO rs_tok.
    ENDIF.
  ENDMETHOD.

  METHOD next.
    rs_tok = peek( ).
    pos = pos + 1.
  ENDMETHOD.

  METHOD expect.
    next( ).
  ENDMETHOD.

  METHOD parse_program.
    WHILE peek( )-kind <> 5.
      DATA(lr_s) = parse_statement( ).
      IF lr_s IS BOUND.
        APPEND lr_s TO rt_stmts.
      ENDIF.
    ENDWHILE.
  ENDMETHOD.

  METHOD parse_statement.
    DATA(ls_t) = peek( ).

    CASE ls_t-val.
      WHEN `let` OR `var` OR `const`.
        rr_node = parse_var( ).
        RETURN.
      WHEN `if`.
        rr_node = parse_if( ).
        RETURN.
      WHEN `while`.
        rr_node = parse_while( ).
        RETURN.
      WHEN `for`.
        rr_node = parse_for( ).
        RETURN.
      WHEN `function`.
        rr_node = parse_func( ).
        RETURN.
      WHEN `return`.
        rr_node = parse_return( ).
        RETURN.
      WHEN `break`.
        next( ).
        IF peek( )-val = `;`.
          next( ).
        ENDIF.
        DATA lr_brk TYPE REF TO ty_node.
        CREATE DATA lr_brk.
        lr_brk->kind = c_node_break.
        rr_node = lr_brk.
        RETURN.
      WHEN `continue`.
        next( ).
        IF peek( )-val = `;`.
          next( ).
        ENDIF.
        DATA lr_cont TYPE REF TO ty_node.
        CREATE DATA lr_cont.
        lr_cont->kind = c_node_continue.
        rr_node = lr_cont.
        RETURN.
      WHEN `switch`.
        rr_node = parse_switch( ).
        RETURN.
      WHEN `class`.
        rr_node = parse_class( ).
        RETURN.
      WHEN `{`.
        DATA lt_blk TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
        lt_blk = parse_block( ).
        DATA lr_blk TYPE REF TO ty_node.
        CREATE DATA lr_blk.
        lr_blk->kind = c_node_block.
        lr_blk->body = lt_blk.
        rr_node = lr_blk.
        RETURN.
      WHEN `;`.
        next( ).
        RETURN.
    ENDCASE.

    " Expression statement
    rr_node = parse_expr( ).
    IF peek( )-val = `;`.
      next( ).
    ENDIF.
  ENDMETHOD.

  METHOD parse_var.
    next( ). " skip let/var/const
    DATA(lv_name) = next( )-val.
    DATA lr_init TYPE REF TO data.
    IF peek( )-val = `=`.
      next( ).
      lr_init = parse_expr( ).
    ENDIF.
    IF peek( )-val = `;`.
      next( ).
    ENDIF.
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind = c_node_var.
    lr_n->str  = lv_name.
    lr_n->right = lr_init.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_if.
    next( ). " skip if
    expect( `(` ).
    DATA(lr_cond) = parse_expr( ).
    expect( `)` ).
    DATA(lt_body) = parse_body( ).
    DATA lt_else TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    IF peek( )-val = `else`.
      next( ).
      IF peek( )-val = `if`.
        DATA(lr_elif) = parse_if( ).
        APPEND lr_elif TO lt_else.
      ELSE.
        lt_else = parse_body( ).
      ENDIF.
    ENDIF.
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind = c_node_if.
    lr_n->cond = lr_cond.
    lr_n->body = lt_body.
    lr_n->els  = lt_else.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_while.
    next( ). " skip while
    expect( `(` ).
    DATA(lr_cond) = parse_expr( ).
    expect( `)` ).
    DATA(lt_body) = parse_body( ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind = c_node_while.
    lr_n->cond = lr_cond.
    lr_n->body = lt_body.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_for.
    next( ). " skip for
    expect( `(` ).
    " Init
    DATA lr_init TYPE REF TO data.
    DATA(lv_pv) = peek( )-val.
    IF lv_pv = `let` OR lv_pv = `var` OR lv_pv = `const`.
      lr_init = parse_var( ). " parseVar consumes trailing ;
    ELSEIF lv_pv <> `;`.
      lr_init = parse_expr( ).
      IF peek( )-val = `;`.
        next( ).
      ENDIF.
    ELSE.
      next( ). " skip ;
    ENDIF.
    " Condition
    DATA lr_cond TYPE REF TO data.
    IF peek( )-val <> `;`.
      lr_cond = parse_expr( ).
    ENDIF.
    IF peek( )-val = `;`.
      next( ).
    ENDIF.
    " Update
    DATA lr_update TYPE REF TO data.
    IF peek( )-val <> `)`.
      lr_update = parse_expr( ).
    ENDIF.
    expect( `)` ).
    DATA(lt_body) = parse_body( ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind   = c_node_for.
    lr_n->init   = lr_init.
    lr_n->cond   = lr_cond.
    lr_n->update = lr_update.
    lr_n->body   = lt_body.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_switch.
    next( ). " skip switch
    expect( `(` ).
    DATA(lr_expr) = parse_expr( ).
    expect( `)` ).
    expect( `{` ).
    DATA lt_cases TYPE tt_switch_cases.
    WHILE peek( )-val <> `}` AND peek( )-kind <> 5.
      IF peek( )-val = `case`.
        next( ).
        DATA(lr_ce) = parse_expr( ).
        expect( `:` ).
        DATA lt_cb TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
        CLEAR lt_cb.
        WHILE peek( )-val <> `case` AND peek( )-val <> `default` AND peek( )-val <> `}` AND peek( )-kind <> 5.
          DATA(lr_cs) = parse_statement( ).
          IF lr_cs IS BOUND.
            APPEND lr_cs TO lt_cb.
          ENDIF.
        ENDWHILE.
        DATA ls_case TYPE ty_switch_case.
        ls_case-expr = lr_ce.
        ls_case-body = lt_cb.
        APPEND ls_case TO lt_cases.
      ELSEIF peek( )-val = `default`.
        next( ).
        expect( `:` ).
        DATA lt_db TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
        CLEAR lt_db.
        WHILE peek( )-val <> `case` AND peek( )-val <> `}` AND peek( )-kind <> 5.
          DATA(lr_ds) = parse_statement( ).
          IF lr_ds IS BOUND.
            APPEND lr_ds TO lt_db.
          ENDIF.
        ENDWHILE.
        DATA ls_def TYPE ty_switch_case.
        CLEAR ls_def.
        ls_def-body = lt_db.
        APPEND ls_def TO lt_cases.
      ELSE.
        next( ). " skip unknown
      ENDIF.
    ENDWHILE.
    expect( `}` ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind  = c_node_switch.
    lr_n->cond  = lr_expr.
    lr_n->cases = lt_cases.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_class.
    next( ). " skip class
    DATA(lv_name) = next( )-val.
    expect( `{` ).
    DATA lt_methods TYPE tt_class_methods.
    WHILE peek( )-val <> `}` AND peek( )-kind <> 5.
      DATA(lv_mname) = next( )-val.
      expect( `(` ).
      DATA lt_params TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
      CLEAR lt_params.
      WHILE peek( )-val <> `)` AND peek( )-kind <> 5.
        APPEND next( )-val TO lt_params.
        IF peek( )-val = `,`.
          next( ).
        ENDIF.
      ENDWHILE.
      expect( `)` ).
      DATA(lt_mbody) = parse_block( ).
      DATA ls_m TYPE ty_class_method.
      ls_m-name   = lv_mname.
      ls_m-params = lt_params.
      ls_m-body   = lt_mbody.
      ls_m-is_ctor = boolc( lv_mname = `constructor` ).
      APPEND ls_m TO lt_methods.
    ENDWHILE.
    expect( `}` ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind    = c_node_class.
    lr_n->str     = lv_name.
    lr_n->methods = lt_methods.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_func.
    next( ). " skip function
    DATA(lv_name) = next( )-val.
    expect( `(` ).
    DATA lt_params TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    WHILE peek( )-val <> `)` AND peek( )-kind <> 5.
      APPEND next( )-val TO lt_params.
      IF peek( )-val = `,`.
        next( ).
      ENDIF.
    ENDWHILE.
    expect( `)` ).
    DATA(lt_body) = parse_body( ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind   = c_node_func_decl.
    lr_n->str    = lv_name.
    lr_n->params = lt_params.
    lr_n->body   = lt_body.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_return.
    next( ). " skip return
    DATA lr_val TYPE REF TO data.
    IF peek( )-val <> `;` AND peek( )-val <> `}` AND peek( )-kind <> 5.
      lr_val = parse_expr( ).
    ENDIF.
    IF peek( )-val = `;`.
      next( ).
    ENDIF.
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind = c_node_return.
    lr_n->left = lr_val.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_block.
    expect( `{` ).
    WHILE peek( )-val <> `}` AND peek( )-kind <> 5.
      DATA(lr_s) = parse_statement( ).
      IF lr_s IS BOUND.
        APPEND lr_s TO rt_stmts.
      ENDIF.
    ENDWHILE.
    expect( `}` ).
  ENDMETHOD.

  METHOD parse_body.
    IF peek( )-val = `{`.
      rt_stmts = parse_block( ).
    ELSE.
      DATA(lr_s) = parse_statement( ).
      IF lr_s IS BOUND.
        APPEND lr_s TO rt_stmts.
      ENDIF.
    ENDIF.
  ENDMETHOD.

  METHOD parse_expr.
    rr_node = parse_assign( ).
  ENDMETHOD.

  METHOD parse_assign.
    DATA(lr_left) = parse_or( ).
    IF peek( )-val = `=`.
      IF lr_left IS BOUND.
        DATA lr_ln TYPE REF TO ty_node.
        ASSIGN lr_left->* TO FIELD-SYMBOL(<ln>).
        lr_ln ?= lr_left.
        FIELD-SYMBOLS <left_node> TYPE ty_node.
        ASSIGN lr_left->* TO <left_node>.
        IF <left_node>-kind = c_node_ident.
          next( ).
          DATA(lr_right) = parse_expr( ).
          DATA lr_n TYPE REF TO ty_node.
          CREATE DATA lr_n.
          lr_n->kind  = c_node_assign.
          lr_n->str   = <left_node>-str.
          lr_n->right = lr_right.
          rr_node = lr_n.
          RETURN.
        ENDIF.
        IF <left_node>-kind = c_node_member_access.
          next( ).
          DATA(lr_right2) = parse_expr( ).
          DATA lr_ma TYPE REF TO ty_node.
          CREATE DATA lr_ma.
          lr_ma->kind      = c_node_member_assign.
          lr_ma->object    = <left_node>-object.
          lr_ma->property  = <left_node>-property.
          lr_ma->prop_expr = <left_node>-prop_expr.
          lr_ma->right     = lr_right2.
          rr_node = lr_ma.
          RETURN.
        ENDIF.
      ENDIF.
    ENDIF.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_or.
    DATA(lr_left) = parse_and( ).
    WHILE peek( )-val = `||`.
      DATA(lv_op) = next( )-val.
      DATA(lr_right) = parse_and( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind  = c_node_binop.
      lr_n->op    = lv_op.
      lr_n->left  = lr_left.
      lr_n->right = lr_right.
      lr_left = lr_n.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_and.
    DATA(lr_left) = parse_equality( ).
    WHILE peek( )-val = `&&`.
      DATA(lv_op) = next( )-val.
      DATA(lr_right) = parse_equality( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind  = c_node_binop.
      lr_n->op    = lv_op.
      lr_n->left  = lr_left.
      lr_n->right = lr_right.
      lr_left = lr_n.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_equality.
    DATA(lr_left) = parse_comparison( ).
    WHILE peek( )-val = `==` OR peek( )-val = `!=`
       OR peek( )-val = `===` OR peek( )-val = `!==`.
      DATA(lv_op) = next( )-val.
      DATA(lr_right) = parse_comparison( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind  = c_node_binop.
      lr_n->op    = lv_op.
      lr_n->left  = lr_left.
      lr_n->right = lr_right.
      lr_left = lr_n.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_comparison.
    DATA(lr_left) = parse_add_sub( ).
    WHILE peek( )-val = `<` OR peek( )-val = `>`
       OR peek( )-val = `<=` OR peek( )-val = `>=`.
      DATA(lv_op) = next( )-val.
      DATA(lr_right) = parse_add_sub( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind  = c_node_binop.
      lr_n->op    = lv_op.
      lr_n->left  = lr_left.
      lr_n->right = lr_right.
      lr_left = lr_n.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_add_sub.
    DATA(lr_left) = parse_mul_div( ).
    WHILE peek( )-val = `+` OR peek( )-val = `-`.
      DATA(lv_op) = next( )-val.
      DATA(lr_right) = parse_mul_div( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind  = c_node_binop.
      lr_n->op    = lv_op.
      lr_n->left  = lr_left.
      lr_n->right = lr_right.
      lr_left = lr_n.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_mul_div.
    DATA(lr_left) = parse_unary( ).
    WHILE peek( )-val = `*` OR peek( )-val = `/` OR peek( )-val = `%`.
      DATA(lv_op) = next( )-val.
      DATA(lr_right) = parse_unary( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind  = c_node_binop.
      lr_n->op    = lv_op.
      lr_n->left  = lr_left.
      lr_n->right = lr_right.
      lr_left = lr_n.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_unary.
    IF peek( )-val = `-` OR peek( )-val = `!`.
      DATA(lv_op) = next( )-val.
      DATA(lr_operand) = parse_unary( ).
      DATA lr_n TYPE REF TO ty_node.
      CREATE DATA lr_n.
      lr_n->kind = c_node_unaryop.
      lr_n->op   = lv_op.
      lr_n->left = lr_operand.
      rr_node = lr_n.
      RETURN.
    ENDIF.
    IF peek( )-val = `typeof`.
      next( ).
      DATA(lr_op2) = parse_unary( ).
      DATA lr_to TYPE REF TO ty_node.
      CREATE DATA lr_to.
      lr_to->kind = c_node_typeof.
      lr_to->left = lr_op2.
      rr_node = lr_to.
      RETURN.
    ENDIF.
    IF peek( )-val = `new`.
      next( ).
      DATA(lv_name) = next( )-val.
      expect( `(` ).
      DATA lt_args TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
      WHILE peek( )-val <> `)` AND peek( )-kind <> 5.
        APPEND parse_expr( ) TO lt_args.
        IF peek( )-val = `,`.
          next( ).
        ENDIF.
      ENDWHILE.
      expect( `)` ).
      DATA lr_new TYPE REF TO ty_node.
      CREATE DATA lr_new.
      lr_new->kind = c_node_new.
      lr_new->str  = lv_name.
      lr_new->args = lt_args.
      rr_node = lr_new.
      RETURN.
    ENDIF.
    rr_node = parse_postfix( ).
  ENDMETHOD.

  METHOD parse_postfix.
    DATA(lr_left) = parse_primary( ).
    DATA lv_continue TYPE abap_bool.
    lv_continue = abap_true.
    WHILE lv_continue = abap_true.
      IF peek( )-val = `.`.
        next( ). " consume .
        DATA(lv_prop) = next( )-val.
        " Check if method call: obj.method(...)
        IF peek( )-val = `(`.
          next( ). " consume (
          DATA lt_margs TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
          CLEAR lt_margs.
          WHILE peek( )-val <> `)` AND peek( )-kind <> 5.
            APPEND parse_expr( ) TO lt_margs.
            IF peek( )-val = `,`.
              next( ).
            ENDIF.
          ENDWHILE.
          expect( `)` ).
          DATA lr_mc TYPE REF TO ty_node.
          CREATE DATA lr_mc.
          lr_mc->kind     = c_node_method_call.
          lr_mc->object   = lr_left.
          lr_mc->property = lv_prop.
          lr_mc->args     = lt_margs.
          lr_left = lr_mc.
        ELSE.
          DATA lr_ma TYPE REF TO ty_node.
          CREATE DATA lr_ma.
          lr_ma->kind     = c_node_member_access.
          lr_ma->object   = lr_left.
          lr_ma->property = lv_prop.
          lr_left = lr_ma.
        ENDIF.
      ELSEIF peek( )-val = `[`.
        next( ). " consume [
        DATA(lr_idx) = parse_expr( ).
        expect( `]` ).
        DATA lr_ba TYPE REF TO ty_node.
        CREATE DATA lr_ba.
        lr_ba->kind      = c_node_member_access.
        lr_ba->object    = lr_left.
        lr_ba->prop_expr = lr_idx.
        lr_left = lr_ba.
      ELSEIF peek( )-val = `(` AND lr_left IS BOUND.
        FIELD-SYMBOLS <ln> TYPE ty_node.
        ASSIGN lr_left->* TO <ln>.
        IF <ln>-kind = c_node_ident.
          next( ).
          DATA lt_fargs TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
          CLEAR lt_fargs.
          WHILE peek( )-val <> `)` AND peek( )-kind <> 5.
            APPEND parse_expr( ) TO lt_fargs.
            IF peek( )-val = `,`.
              next( ).
            ENDIF.
          ENDWHILE.
          expect( `)` ).
          DATA lr_call TYPE REF TO ty_node.
          CREATE DATA lr_call.
          lr_call->kind = c_node_call.
          lr_call->str  = <ln>-str.
          lr_call->args = lt_fargs.
          lr_left = lr_call.
        ELSE.
          lv_continue = abap_false.
        ENDIF.
      ELSE.
        lv_continue = abap_false.
      ENDIF.
    ENDWHILE.
    rr_node = lr_left.
  ENDMETHOD.

  METHOD parse_primary.
    DATA ls_t TYPE ty_token.
    ls_t = peek( ).

    IF ls_t-kind = 0. " number
      next( ).
      DATA lr_num TYPE REF TO ty_node.
      CREATE DATA lr_num.
      lr_num->kind = c_node_number.
      DATA lv_f TYPE f.
      lv_f = ls_t-val.
      lr_num->num  = lv_f.
      rr_node = lr_num.
      RETURN.
    ENDIF.

    IF ls_t-kind = 1. " string
      next( ).
      DATA lr_str TYPE REF TO ty_node.
      CREATE DATA lr_str.
      lr_str->kind = c_node_string.
      lr_str->str  = ls_t-val.
      rr_node = lr_str.
      RETURN.
    ENDIF.

    IF ls_t-val = `(`.
      next( ).
      DATA(lr_expr) = parse_expr( ).
      expect( `)` ).
      rr_node = lr_expr.
      RETURN.
    ENDIF.

    IF ls_t-val = `[`.
      rr_node = parse_array_literal( ).
      RETURN.
    ENDIF.

    IF ls_t-val = `{`.
      rr_node = parse_object_literal( ).
      RETURN.
    ENDIF.

    IF ls_t-val = `true`.
      next( ).
      DATA lr_true TYPE REF TO ty_node.
      CREATE DATA lr_true.
      lr_true->kind = c_node_number.
      lr_true->num  = 1.
      rr_node = lr_true.
      RETURN.
    ENDIF.

    IF ls_t-val = `false`.
      next( ).
      DATA lr_false TYPE REF TO ty_node.
      CREATE DATA lr_false.
      lr_false->kind = c_node_number.
      lr_false->num  = 0.
      rr_node = lr_false.
      RETURN.
    ENDIF.

    IF ls_t-kind = 2. " identifier
      next( ).
      DATA lv_name TYPE string.
      lv_name = ls_t-val.
      " console.log handled specially
      IF lv_name = `console` AND peek( )-val = `.`.
        next( ). " consume .
        DATA(lv_sub) = next( )-val.
        DATA(lv_full) = |{ lv_name }.{ lv_sub }|.
        IF peek( )-val = `(`.
          next( ).
          DATA lt_args TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
          WHILE peek( )-val <> `)` AND peek( )-kind <> 5.
            APPEND parse_expr( ) TO lt_args.
            IF peek( )-val = `,`.
              next( ).
            ENDIF.
          ENDWHILE.
          expect( `)` ).
          DATA lr_cl TYPE REF TO ty_node.
          CREATE DATA lr_cl.
          lr_cl->kind = c_node_call.
          lr_cl->str  = lv_full.
          lr_cl->args = lt_args.
          rr_node = lr_cl.
          RETURN.
        ENDIF.
        DATA lr_cid TYPE REF TO ty_node.
        CREATE DATA lr_cid.
        lr_cid->kind = c_node_ident.
        lr_cid->str  = lv_full.
        rr_node = lr_cid.
        RETURN.
      ENDIF.
      DATA lr_id TYPE REF TO ty_node.
      CREATE DATA lr_id.
      lr_id->kind = c_node_ident.
      lr_id->str  = lv_name.
      rr_node = lr_id.
      RETURN.
    ENDIF.

    next( ). " skip unknown
  ENDMETHOD.

  METHOD parse_array_literal.
    expect( `[` ).
    DATA lt_elems TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    WHILE peek( )-val <> `]` AND peek( )-kind <> 5.
      APPEND parse_expr( ) TO lt_elems.
      IF peek( )-val = `,`.
        next( ).
      ENDIF.
    ENDWHILE.
    expect( `]` ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind = c_node_array.
    lr_n->args = lt_elems.
    rr_node = lr_n.
  ENDMETHOD.

  METHOD parse_object_literal.
    expect( `{` ).
    DATA lt_pairs TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    WHILE peek( )-val <> `}` AND peek( )-kind <> 5.
      DATA(lv_key) = next( )-val.
      expect( `:` ).
      DATA(lr_val) = parse_expr( ).
      DATA lr_k TYPE REF TO ty_node.
      CREATE DATA lr_k.
      lr_k->kind = c_node_string.
      lr_k->str  = lv_key.
      APPEND lr_k TO lt_pairs.
      APPEND lr_val TO lt_pairs.
      IF peek( )-val = `,`.
        next( ).
      ENDIF.
    ENDWHILE.
    expect( `}` ).
    DATA lr_n TYPE REF TO ty_node.
    CREATE DATA lr_n.
    lr_n->kind = c_node_object.
    lr_n->args = lt_pairs.
    rr_node = lr_n.
  ENDMETHOD.
ENDCLASS.


*----------------------------------------------------------------------*
* ZCL_JSEVAL — main class
*----------------------------------------------------------------------*
CLASS zcl_jseval DEFINITION PUBLIC.
  PUBLIC SECTION.
    CLASS-METHODS eval
      IMPORTING iv_source        TYPE string
      RETURNING VALUE(rv_output) TYPE string.

  PRIVATE SECTION.
    " Tokenizer
    CLASS-METHODS tokenize
      IMPORTING iv_src           TYPE string
      RETURNING VALUE(rt_tokens) TYPE tt_tokens.

    " Value helpers
    CLASS-METHODS number_val
      IMPORTING iv_num        TYPE f
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS string_val
      IMPORTING iv_str        TYPE string
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS bool_val
      IMPORTING iv_bool       TYPE abap_bool
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS object_val
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS array_val
      IMPORTING it_elems      TYPE STANDARD TABLE
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS undefined_val
      RETURNING VALUE(rs_val) TYPE ty_value.

    CLASS-METHODS is_true
      IMPORTING is_val        TYPE ty_value
      RETURNING VALUE(rv_yes) TYPE abap_bool.
    CLASS-METHODS to_number
      IMPORTING is_val        TYPE ty_value
      RETURNING VALUE(rv_num) TYPE f.
    CLASS-METHODS to_string
      IMPORTING is_val        TYPE ty_value
      RETURNING VALUE(rv_str) TYPE string.

    " Evaluator
    CLASS-METHODS eval_node
      IMPORTING ir_node       TYPE REF TO data
                io_env        TYPE REF TO lcl_env
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS eval_bin_op
      IMPORTING iv_op         TYPE string
                is_left       TYPE ty_value
                is_right      TYPE ty_value
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS eval_property_access
      IMPORTING is_obj        TYPE ty_value
                iv_prop       TYPE string
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS eval_method_call
      IMPORTING is_obj        TYPE ty_value
                iv_method     TYPE string
                it_args       TYPE STANDARD TABLE
                io_env        TYPE REF TO lcl_env
                ir_obj_node   TYPE REF TO data
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS call_function
      IMPORTING is_fn         TYPE ty_function
                it_args       TYPE STANDARD TABLE
                io_env        TYPE REF TO lcl_env
                ir_this       TYPE REF TO data OPTIONAL
      RETURNING VALUE(rs_val) TYPE ty_value.
    CLASS-METHODS box_value
      IMPORTING is_val        TYPE ty_value
      RETURNING VALUE(rr_ref) TYPE REF TO data.
    CLASS-METHODS unbox_value
      IMPORTING ir_ref        TYPE REF TO data
      RETURNING VALUE(rs_val) TYPE ty_value.
ENDCLASS.


CLASS zcl_jseval IMPLEMENTATION.

  METHOD eval.
    DATA lt_tokens TYPE tt_tokens.
    lt_tokens = tokenize( iv_source ).

    DATA lo_parser TYPE REF TO lcl_parser.
    CREATE OBJECT lo_parser
      EXPORTING it_tokens = lt_tokens.

    DATA lt_stmts TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
    lt_stmts = lo_parser->parse_program( ).

    DATA lo_env TYPE REF TO lcl_env.
    CREATE OBJECT lo_env.
    " placeholder for console
    lo_env->define( iv_name = `console` is_val = number_val( 0 ) ).

    LOOP AT lt_stmts INTO DATA(lr_stmt).
      eval_node( ir_node = lr_stmt io_env = lo_env ).
    ENDLOOP.

    rv_output = lo_env->get_output( ).
  ENDMETHOD.

  METHOD tokenize.
    DATA lv_i   TYPE i VALUE 0.
    DATA lv_len TYPE i.
    DATA lv_ch  TYPE c LENGTH 1.
    DATA lv_ch2 TYPE c LENGTH 1.
    DATA lv_j   TYPE i.
    DATA ls_tok TYPE ty_token.

    lv_len = strlen( iv_src ).

    WHILE lv_i < lv_len.
      lv_ch = iv_src+lv_i(1).

      " Skip whitespace
      IF lv_ch = ` ` OR lv_ch = cl_abap_char_utilities=>horizontal_tab
         OR lv_ch = cl_abap_char_utilities=>newline
         OR lv_ch = cl_abap_char_utilities=>cr_lf(1).
        lv_i = lv_i + 1.
        CONTINUE.
      ENDIF.

      " Skip // comments
      IF lv_i + 1 < lv_len.
        IF lv_ch = `/` AND iv_src+lv_i(2) = `//`.
          WHILE lv_i < lv_len.
            IF iv_src+lv_i(1) = cl_abap_char_utilities=>newline.
              EXIT.
            ENDIF.
            lv_i = lv_i + 1.
          ENDWHILE.
          CONTINUE.
        ENDIF.
      ENDIF.

      " Number
      IF lv_ch >= `0` AND lv_ch <= `9`.
        lv_j = lv_i.
        WHILE lv_j < lv_len.
          DATA lv_d TYPE c LENGTH 1.
          lv_d = iv_src+lv_j(1).
          IF ( lv_d >= `0` AND lv_d <= `9` ) OR lv_d = `.`.
            lv_j = lv_j + 1.
          ELSE.
            EXIT.
          ENDIF.
        ENDWHILE.
        DATA lv_numlen TYPE i.
        lv_numlen = lv_j - lv_i.
        CLEAR ls_tok.
        ls_tok-kind = 0.
        ls_tok-val  = iv_src+lv_i(lv_numlen).
        APPEND ls_tok TO rt_tokens.
        lv_i = lv_j.
        CONTINUE.
      ENDIF.

      " String
      IF lv_ch = `'` OR lv_ch = `"`.
        DATA lv_quote TYPE c LENGTH 1.
        lv_quote = lv_ch.
        lv_j = lv_i + 1.
        DATA lv_sbuf TYPE string.
        CLEAR lv_sbuf.
        WHILE lv_j < lv_len.
          DATA lv_sc TYPE c LENGTH 1.
          lv_sc = iv_src+lv_j(1).
          IF lv_sc = lv_quote.
            EXIT.
          ENDIF.
          IF lv_sc = `\` AND lv_j + 1 < lv_len.
            lv_j = lv_j + 1.
            DATA lv_esc TYPE c LENGTH 1.
            lv_esc = iv_src+lv_j(1).
            CASE lv_esc.
              WHEN `n`.
                lv_sbuf = lv_sbuf && cl_abap_char_utilities=>newline.
              WHEN `t`.
                lv_sbuf = lv_sbuf && cl_abap_char_utilities=>horizontal_tab.
              WHEN `\`.
                lv_sbuf = lv_sbuf && `\`.
              WHEN `'`.
                lv_sbuf = lv_sbuf && `'`.
              WHEN `"`.
                lv_sbuf = lv_sbuf && `"`.
              WHEN OTHERS.
                lv_sbuf = lv_sbuf && lv_esc.
            ENDCASE.
          ELSE.
            lv_sbuf = lv_sbuf && lv_sc.
          ENDIF.
          lv_j = lv_j + 1.
        ENDWHILE.
        CLEAR ls_tok.
        ls_tok-kind = 1.
        ls_tok-val  = lv_sbuf.
        APPEND ls_tok TO rt_tokens.
        lv_i = lv_j + 1.
        CONTINUE.
      ENDIF.

      " Identifier / keyword
      IF lv_ch = `_` OR ( lv_ch >= `a` AND lv_ch <= `z` )
                      OR ( lv_ch >= `A` AND lv_ch <= `Z` ).
        lv_j = lv_i.
        WHILE lv_j < lv_len.
          DATA lv_ic TYPE c LENGTH 1.
          lv_ic = iv_src+lv_j(1).
          IF lv_ic = `_` OR ( lv_ic >= `a` AND lv_ic <= `z` )
                         OR ( lv_ic >= `A` AND lv_ic <= `Z` )
                         OR ( lv_ic >= `0` AND lv_ic <= `9` ).
            lv_j = lv_j + 1.
          ELSE.
            EXIT.
          ENDIF.
        ENDWHILE.
        DATA lv_idlen TYPE i.
        lv_idlen = lv_j - lv_i.
        CLEAR ls_tok.
        ls_tok-kind = 2.
        ls_tok-val  = iv_src+lv_i(lv_idlen).
        APPEND ls_tok TO rt_tokens.
        lv_i = lv_j.
        CONTINUE.
      ENDIF.

      " Multi-char operators
      IF lv_i + 1 < lv_len.
        DATA lv_two TYPE string.
        lv_two = iv_src+lv_i(2).
        IF lv_two = `==` OR lv_two = `!=` OR lv_two = `<=`
           OR lv_two = `>=` OR lv_two = `&&` OR lv_two = `||`.
          IF lv_i + 2 < lv_len AND iv_src+lv_i(3) CS `=` AND
             ( lv_two = `==` OR lv_two = `!=` ).
            " Check for === or !==
            DATA lv_three TYPE string.
            lv_three = iv_src+lv_i(3).
            IF lv_three = `===` OR lv_three = `!==`.
              CLEAR ls_tok.
              ls_tok-kind = 3.
              ls_tok-val  = lv_three.
              APPEND ls_tok TO rt_tokens.
              lv_i = lv_i + 3.
              CONTINUE.
            ENDIF.
          ENDIF.
          CLEAR ls_tok.
          ls_tok-kind = 3.
          ls_tok-val  = lv_two.
          APPEND ls_tok TO rt_tokens.
          lv_i = lv_i + 2.
          CONTINUE.
        ENDIF.
      ENDIF.

      " Single char op/punc
      IF lv_ch = `+` OR lv_ch = `-` OR lv_ch = `*` OR lv_ch = `/`
         OR lv_ch = `%` OR lv_ch = `=` OR lv_ch = `<` OR lv_ch = `>`
         OR lv_ch = `!` OR lv_ch = `(` OR lv_ch = `)` OR lv_ch = `,`
         OR lv_ch = `{` OR lv_ch = `}` OR lv_ch = `;` OR lv_ch = `:`
         OR lv_ch = `.` OR lv_ch = `[` OR lv_ch = `]`.
        CLEAR ls_tok.
        ls_tok-kind = 3.
        ls_tok-val  = lv_ch.
        APPEND ls_tok TO rt_tokens.
        lv_i = lv_i + 1.
        CONTINUE.
      ENDIF.

      lv_i = lv_i + 1. " skip unknown
    ENDWHILE.

    " EOF token
    CLEAR ls_tok.
    ls_tok-kind = 5.
    ls_tok-val  = ``.
    APPEND ls_tok TO rt_tokens.
  ENDMETHOD.

  METHOD number_val.
    rs_val-type = 1.
    rs_val-num  = iv_num.
  ENDMETHOD.

  METHOD string_val.
    rs_val-type = 2.
    rs_val-str  = iv_str.
  ENDMETHOD.

  METHOD bool_val.
    rs_val-type = 3.
    IF iv_bool = abap_true.
      rs_val-num = 1.
    ELSE.
      rs_val-num = 0.
    ENDIF.
  ENDMETHOD.

  METHOD object_val.
    rs_val-type = 6.
    CREATE OBJECT rs_val-obj.
  ENDMETHOD.

  METHOD array_val.
    rs_val-type = 7.
    CREATE OBJECT rs_val-arr.
    FIELD-SYMBOLS <ref> TYPE REF TO data.
    LOOP AT it_elems ASSIGNING <ref>.
      rs_val-arr->push( <ref> ).
    ENDLOOP.
  ENDMETHOD.

  METHOD undefined_val.
    rs_val-type = 0.
  ENDMETHOD.

  METHOD is_true.
    CASE is_val-type.
      WHEN 0 OR 5.
        rv_yes = abap_false.
      WHEN 1.
        rv_yes = boolc( is_val-num <> 0 ).
      WHEN 2.
        rv_yes = boolc( is_val-str IS NOT INITIAL ).
      WHEN 3.
        rv_yes = boolc( is_val-num <> 0 ).
      WHEN OTHERS.
        rv_yes = abap_true.
    ENDCASE.
  ENDMETHOD.

  METHOD to_number.
    CASE is_val-type.
      WHEN 1.
        rv_num = is_val-num.
      WHEN 2.
        TRY.
            rv_num = is_val-str.
          CATCH cx_root.
            rv_num = 0.
        ENDTRY.
      WHEN 3.
        rv_num = is_val-num.
      WHEN OTHERS.
        rv_num = 0.
    ENDCASE.
  ENDMETHOD.

  METHOD to_string.
    CASE is_val-type.
      WHEN 0.
        rv_str = `undefined`.
      WHEN 1.
        DATA lv_int TYPE i.
        DATA lv_fcheck TYPE f.
        lv_int = is_val-num.
        lv_fcheck = lv_int.
        IF lv_fcheck = is_val-num.
          rv_str = |{ lv_int }|.
        ELSE.
          rv_str = |{ is_val-num }|.
          " Remove trailing spaces if any
          CONDENSE rv_str.
        ENDIF.
      WHEN 2.
        rv_str = is_val-str.
      WHEN 3.
        IF is_val-num <> 0.
          rv_str = `true`.
        ELSE.
          rv_str = `false`.
        ENDIF.
      WHEN 5.
        rv_str = `null`.
      WHEN 6.
        rv_str = `[object Object]`.
      WHEN 7.
        rv_str = |[array { is_val-arr->length( ) }]|.
      WHEN OTHERS.
        rv_str = `undefined`.
    ENDCASE.
  ENDMETHOD.

  METHOD box_value.
    CREATE DATA rr_ref TYPE ty_value.
    FIELD-SYMBOLS <val> TYPE ty_value.
    ASSIGN rr_ref->* TO <val>.
    <val> = is_val.
  ENDMETHOD.

  METHOD unbox_value.
    IF ir_ref IS NOT BOUND.
      rs_val-type = 0.
      RETURN.
    ENDIF.
    FIELD-SYMBOLS <val> TYPE ty_value.
    ASSIGN ir_ref->* TO <val>.
    rs_val = <val>.
  ENDMETHOD.

  METHOD call_function.
    " Use closure environment if available, otherwise caller env
    DATA lo_parent TYPE REF TO lcl_env.
    IF is_fn-closure IS BOUND.
      lo_parent = is_fn-closure.
    ELSE.
      lo_parent = io_env.
    ENDIF.
    DATA lo_call_env TYPE REF TO lcl_env.
    CREATE OBJECT lo_call_env
      EXPORTING io_parent = lo_parent.
    " Propagate output from caller
    lo_call_env->output = io_env->output.
    " Set this if provided
    IF ir_this IS BOUND.
      FIELD-SYMBOLS <this> TYPE ty_value.
      ASSIGN ir_this->* TO <this>.
      lo_call_env->define( iv_name = `this` is_val = <this> ).
    ENDIF.
    " Bind parameters
    DATA lv_idx TYPE i VALUE 0.
    LOOP AT is_fn-params INTO DATA(lv_param).
      DATA(lr_arg) = VALUE REF TO data( ).
      READ TABLE it_args INDEX lv_idx + 1 INTO lr_arg.
      IF sy-subrc = 0.
        lo_call_env->define( iv_name = lv_param is_val = unbox_value( lr_arg ) ).
      ENDIF.
      lv_idx = lv_idx + 1.
    ENDLOOP.
    " Execute body
    LOOP AT is_fn-body INTO DATA(lr_stmt).
      rs_val = eval_node( ir_node = lr_stmt io_env = lo_call_env ).
      IF lo_call_env->returning = abap_true.
        rs_val = lo_call_env->ret_val.
        EXIT.
      ENDIF.
    ENDLOOP.
    " Write back this if it was an object (for mutation)
    IF ir_this IS BOUND.
      ASSIGN ir_this->* TO <this>.
      IF <this>-type = 6.
        DATA(ls_updated) = lo_call_env->get( `this` ).
        IF ls_updated-type = 6.
          " Copy properties back
          <this>-obj->copy_from( ls_updated-obj ).
        ENDIF.
      ENDIF.
    ENDIF.
  ENDMETHOD.

  METHOD eval_node.
    IF ir_node IS NOT BOUND.
      rs_val = undefined_val( ).
      RETURN.
    ENDIF.
    IF io_env->returning = abap_true OR io_env->breaking = abap_true.
      rs_val = undefined_val( ).
      RETURN.
    ENDIF.

    FIELD-SYMBOLS <n> TYPE ty_node.
    ASSIGN ir_node->* TO <n>.

    CASE <n>-kind.

      WHEN c_node_number.
        rs_val = number_val( <n>-num ).

      WHEN c_node_string.
        rs_val = string_val( <n>-str ).

      WHEN c_node_ident.
        rs_val = io_env->get( <n>-str ).

      WHEN c_node_binop.
        DATA(ls_bl) = eval_node( ir_node = <n>-left io_env = io_env ).
        DATA(ls_br) = eval_node( ir_node = <n>-right io_env = io_env ).
        rs_val = eval_bin_op( iv_op = <n>-op is_left = ls_bl is_right = ls_br ).

      WHEN c_node_unaryop.
        DATA(ls_uval) = eval_node( ir_node = <n>-left io_env = io_env ).
        CASE <n>-op.
          WHEN `-`.
            rs_val = number_val( - to_number( ls_uval ) ).
          WHEN `!`.
            rs_val = bool_val( boolc( is_true( ls_uval ) = abap_false ) ).
        ENDCASE.

      WHEN c_node_assign.
        DATA(ls_aval) = eval_node( ir_node = <n>-right io_env = io_env ).
        io_env->set( iv_name = <n>-str is_val = ls_aval ).
        rs_val = ls_aval.

      WHEN c_node_member_assign.
        DATA(ls_maobj) = eval_node( ir_node = <n>-object io_env = io_env ).
        DATA(ls_maval) = eval_node( ir_node = <n>-right io_env = io_env ).
        DATA lv_maprop TYPE string.
        lv_maprop = <n>-property.
        IF <n>-prop_expr IS BOUND.
          lv_maprop = to_string( eval_node( ir_node = <n>-prop_expr io_env = io_env ) ).
        ENDIF.
        IF ls_maobj-type = 6.
          ls_maobj-obj->set( iv_key = lv_maprop ir_val = box_value( ls_maval ) ).
        ENDIF.
        rs_val = ls_maval.

      WHEN c_node_var.
        DATA ls_vval TYPE ty_value.
        ls_vval = undefined_val( ).
        IF <n>-right IS BOUND.
          ls_vval = eval_node( ir_node = <n>-right io_env = io_env ).
        ENDIF.
        io_env->define( iv_name = <n>-str is_val = ls_vval ).
        rs_val = ls_vval.

      WHEN c_node_if.
        DATA(ls_icond) = eval_node( ir_node = <n>-cond io_env = io_env ).
        IF is_true( ls_icond ) = abap_true.
          LOOP AT <n>-body INTO DATA(lr_ib).
            eval_node( ir_node = lr_ib io_env = io_env ).
            IF io_env->returning = abap_true OR io_env->breaking = abap_true.
              EXIT.
            ENDIF.
          ENDLOOP.
        ELSEIF lines( <n>-els ) > 0.
          LOOP AT <n>-els INTO DATA(lr_ie).
            eval_node( ir_node = lr_ie io_env = io_env ).
            IF io_env->returning = abap_true OR io_env->breaking = abap_true.
              EXIT.
            ENDIF.
          ENDLOOP.
        ENDIF.

      WHEN c_node_while.
        DO.
          DATA(ls_wcond) = eval_node( ir_node = <n>-cond io_env = io_env ).
          IF is_true( ls_wcond ) = abap_false OR io_env->returning = abap_true
             OR io_env->breaking = abap_true.
            EXIT.
          ENDIF.
          LOOP AT <n>-body INTO DATA(lr_wb).
            eval_node( ir_node = lr_wb io_env = io_env ).
            IF io_env->returning = abap_true OR io_env->breaking = abap_true
               OR io_env->continuing = abap_true.
              EXIT.
            ENDIF.
          ENDLOOP.
          IF io_env->continuing = abap_true.
            io_env->continuing = abap_false.
            CONTINUE.
          ENDIF.
        ENDDO.
        IF io_env->breaking = abap_true.
          io_env->breaking = abap_false.
        ENDIF.

      WHEN c_node_for.
        DATA lo_for_env TYPE REF TO lcl_env.
        CREATE OBJECT lo_for_env
          EXPORTING io_parent = io_env.
        lo_for_env->output = io_env->output.
        IF <n>-init IS BOUND.
          eval_node( ir_node = <n>-init io_env = lo_for_env ).
        ENDIF.
        DO.
          IF lo_for_env->returning = abap_true OR lo_for_env->breaking = abap_true.
            EXIT.
          ENDIF.
          DATA(ls_fcond) = eval_node( ir_node = <n>-cond io_env = lo_for_env ).
          IF is_true( ls_fcond ) = abap_false.
            EXIT.
          ENDIF.
          LOOP AT <n>-body INTO DATA(lr_fb).
            eval_node( ir_node = lr_fb io_env = lo_for_env ).
            IF lo_for_env->returning = abap_true OR lo_for_env->breaking = abap_true
               OR lo_for_env->continuing = abap_true.
              EXIT.
            ENDIF.
          ENDLOOP.
          IF lo_for_env->continuing = abap_true.
            lo_for_env->continuing = abap_false.
          ENDIF.
          IF lo_for_env->returning = abap_true OR lo_for_env->breaking = abap_true.
            EXIT.
          ENDIF.
          IF <n>-update IS BOUND.
            eval_node( ir_node = <n>-update io_env = lo_for_env ).
          ENDIF.
        ENDDO.
        IF lo_for_env->returning = abap_true.
          io_env->returning = abap_true.
          io_env->ret_val   = lo_for_env->ret_val.
        ENDIF.

      WHEN c_node_block.
        LOOP AT <n>-body INTO DATA(lr_bs).
          rs_val = eval_node( ir_node = lr_bs io_env = io_env ).
          IF io_env->returning = abap_true OR io_env->breaking = abap_true.
            EXIT.
          ENDIF.
        ENDLOOP.

      WHEN c_node_call.
        " console.log special case
        IF <n>-str = `console.log`.
          DATA lv_parts TYPE string.
          CLEAR lv_parts.
          DATA lv_first TYPE abap_bool VALUE abap_true.
          LOOP AT <n>-args INTO DATA(lr_ca).
            DATA(ls_cav) = eval_node( ir_node = lr_ca io_env = io_env ).
            IF lv_first = abap_false.
              lv_parts = lv_parts && ` `.
            ENDIF.
            lv_parts = lv_parts && to_string( ls_cav ).
            lv_first = abap_false.
          ENDLOOP.
          io_env->append_output( lv_parts && cl_abap_char_utilities=>newline ).
          rs_val = undefined_val( ).
          RETURN.
        ENDIF.
        " User function
        DATA(ls_fn) = io_env->get( <n>-str ).
        IF ls_fn-type = 4 AND ls_fn-fn IS BOUND.
          FIELD-SYMBOLS <fn> TYPE ty_function.
          ASSIGN ls_fn-fn->* TO <fn>.
          DATA lt_call_args TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
          CLEAR lt_call_args.
          LOOP AT <n>-args INTO DATA(lr_fa).
            APPEND box_value( eval_node( ir_node = lr_fa io_env = io_env ) ) TO lt_call_args.
          ENDLOOP.
          rs_val = call_function( is_fn = <fn> it_args = lt_call_args io_env = io_env ).
        ENDIF.

      WHEN c_node_method_call.
        DATA(ls_mcobj) = eval_node( ir_node = <n>-object io_env = io_env ).
        DATA lv_method TYPE string.
        lv_method = <n>-property.
        DATA lt_mc_args TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
        CLEAR lt_mc_args.
        LOOP AT <n>-args INTO DATA(lr_ma2).
          APPEND box_value( eval_node( ir_node = lr_ma2 io_env = io_env ) ) TO lt_mc_args.
        ENDLOOP.
        rs_val = eval_method_call(
          is_obj      = ls_mcobj
          iv_method   = lv_method
          it_args     = lt_mc_args
          io_env      = io_env
          ir_obj_node = <n>-object ).

      WHEN c_node_func_decl.
        DATA lr_fn_data TYPE REF TO data.
        CREATE DATA lr_fn_data TYPE ty_function.
        FIELD-SYMBOLS <fn_data> TYPE ty_function.
        ASSIGN lr_fn_data->* TO <fn_data>.
        <fn_data>-name    = <n>-str.
        <fn_data>-params  = <n>-params.
        <fn_data>-body    = <n>-body.
        <fn_data>-closure = io_env.
        DATA ls_fnval TYPE ty_value.
        ls_fnval-type = 4.
        ls_fnval-fn   = lr_fn_data.
        io_env->define( iv_name = <n>-str is_val = ls_fnval ).

      WHEN c_node_return.
        DATA(ls_retv) = eval_node( ir_node = <n>-left io_env = io_env ).
        io_env->returning = abap_true.
        io_env->ret_val   = ls_retv.
        rs_val = ls_retv.

      WHEN c_node_break.
        io_env->breaking = abap_true.
        rs_val = undefined_val( ).

      WHEN c_node_continue.
        io_env->continuing = abap_true.
        rs_val = undefined_val( ).

      WHEN c_node_object.
        DATA ls_obj TYPE ty_value.
        ls_obj = object_val( ).
        DATA lv_oi TYPE i VALUE 1.
        WHILE lv_oi <= lines( <n>-args ).
          DATA lr_okey TYPE REF TO data.
          READ TABLE <n>-args INDEX lv_oi INTO lr_okey.
          FIELD-SYMBOLS <okey> TYPE ty_node.
          ASSIGN lr_okey->* TO <okey>.
          DATA(lv_okey_str) = <okey>-str.
          DATA lr_oval TYPE REF TO data.
          READ TABLE <n>-args INDEX lv_oi + 1 INTO lr_oval.
          DATA(ls_oval) = eval_node( ir_node = lr_oval io_env = io_env ).
          ls_obj-obj->set( iv_key = lv_okey_str ir_val = box_value( ls_oval ) ).
          lv_oi = lv_oi + 2.
        ENDWHILE.
        rs_val = ls_obj.

      WHEN c_node_array.
        DATA lt_arr_refs TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
        CLEAR lt_arr_refs.
        LOOP AT <n>-args INTO DATA(lr_ae).
          APPEND box_value( eval_node( ir_node = lr_ae io_env = io_env ) ) TO lt_arr_refs.
        ENDLOOP.
        rs_val = array_val( lt_arr_refs ).

      WHEN c_node_member_access.
        DATA(ls_paobj) = eval_node( ir_node = <n>-object io_env = io_env ).
        DATA lv_paprop TYPE string.
        lv_paprop = <n>-property.
        IF <n>-prop_expr IS BOUND.
          lv_paprop = to_string( eval_node( ir_node = <n>-prop_expr io_env = io_env ) ).
        ENDIF.
        rs_val = eval_property_access( is_obj = ls_paobj iv_prop = lv_paprop ).

      WHEN c_node_typeof.
        DATA(ls_toval) = eval_node( ir_node = <n>-left io_env = io_env ).
        CASE ls_toval-type.
          WHEN 0.
            rs_val = string_val( `undefined` ).
          WHEN 1.
            rs_val = string_val( `number` ).
          WHEN 2.
            rs_val = string_val( `string` ).
          WHEN 3.
            rs_val = string_val( `boolean` ).
          WHEN 4.
            rs_val = string_val( `function` ).
          WHEN OTHERS.
            rs_val = string_val( `object` ).
        ENDCASE.

      WHEN c_node_new.
        DATA(ls_cls) = io_env->get( <n>-str ).
        IF ls_cls-type = 6 AND ls_cls-obj IS BOUND.
          DATA ls_instance TYPE ty_value.
          ls_instance = object_val( ).
          DATA lt_new_args TYPE STANDARD TABLE OF REF TO data WITH DEFAULT KEY.
          CLEAR lt_new_args.
          LOOP AT <n>-args INTO DATA(lr_na).
            APPEND box_value( eval_node( ir_node = lr_na io_env = io_env ) ) TO lt_new_args.
          ENDLOOP.
          " Call constructor if exists
          DATA lr_ctor TYPE REF TO data.
          lr_ctor = ls_cls-obj->get( `constructor` ).
          IF lr_ctor IS BOUND.
            DATA(ls_ctor_val) = unbox_value( lr_ctor ).
            IF ls_ctor_val-type = 4 AND ls_ctor_val-fn IS BOUND.
              FIELD-SYMBOLS <ctor_fn> TYPE ty_function.
              ASSIGN ls_ctor_val-fn->* TO <ctor_fn>.
              DATA lr_inst_ref TYPE REF TO data.
              lr_inst_ref = box_value( ls_instance ).
              call_function( is_fn = <ctor_fn> it_args = lt_new_args io_env = io_env
                             ir_this = lr_inst_ref ).
              " Get updated instance back
              ls_instance = unbox_value( lr_inst_ref ).
            ENDIF.
          ENDIF.
          " Copy methods to instance
          LOOP AT ls_cls-obj->props ASSIGNING FIELD-SYMBOL(<cp>).
            IF <cp>-key <> `constructor`.
              ls_instance-obj->set( iv_key = <cp>-key ir_val = <cp>-val ).
            ENDIF.
          ENDLOOP.
          rs_val = ls_instance.
        ENDIF.

      WHEN c_node_class.
        DATA ls_clsobj TYPE ty_value.
        ls_clsobj = object_val( ).
        LOOP AT <n>-methods INTO DATA(ls_cm).
          DATA lr_mfn TYPE REF TO data.
          CREATE DATA lr_mfn TYPE ty_function.
          FIELD-SYMBOLS <mfn> TYPE ty_function.
          ASSIGN lr_mfn->* TO <mfn>.
          <mfn>-name    = ls_cm-name.
          <mfn>-params  = ls_cm-params.
          <mfn>-body    = ls_cm-body.
          <mfn>-closure = io_env.
          DATA ls_mfnval TYPE ty_value.
          ls_mfnval-type = 4.
          ls_mfnval-fn   = lr_mfn.
          ls_clsobj-obj->set( iv_key = ls_cm-name ir_val = box_value( ls_mfnval ) ).
        ENDLOOP.
        io_env->define( iv_name = <n>-str is_val = ls_clsobj ).

      WHEN c_node_switch.
        DATA(ls_swval) = eval_node( ir_node = <n>-cond io_env = io_env ).
        DATA lv_matched TYPE abap_bool VALUE abap_false.
        LOOP AT <n>-cases INTO DATA(ls_sc).
          IF lv_matched = abap_false AND ls_sc-expr IS BOUND.
            DATA(ls_caseval) = eval_node( ir_node = ls_sc-expr io_env = io_env ).
            IF to_number( ls_swval ) = to_number( ls_caseval )
               AND ls_swval-type = ls_caseval-type.
              lv_matched = abap_true.
            ENDIF.
          ENDIF.
          IF lv_matched = abap_false AND ls_sc-expr IS NOT BOUND.
            lv_matched = abap_true. " default
          ENDIF.
          IF lv_matched = abap_true.
            LOOP AT ls_sc-body INTO DATA(lr_sb).
              eval_node( ir_node = lr_sb io_env = io_env ).
              IF io_env->breaking = abap_true OR io_env->returning = abap_true.
                EXIT.
              ENDIF.
            ENDLOOP.
            IF io_env->breaking = abap_true.
              io_env->breaking = abap_false.
              EXIT.
            ENDIF.
            IF io_env->returning = abap_true.
              EXIT.
            ENDIF.
          ENDIF.
        ENDLOOP.

      WHEN OTHERS.
        rs_val = undefined_val( ).
    ENDCASE.
  ENDMETHOD.

  METHOD eval_property_access.
    CASE is_obj-type.
      WHEN 6. " object
        DATA lr_pv TYPE REF TO data.
        lr_pv = is_obj-obj->get( iv_prop ).
        IF lr_pv IS BOUND.
          rs_val = unbox_value( lr_pv ).
        ELSE.
          rs_val = undefined_val( ).
        ENDIF.
      WHEN 7. " array
        IF iv_prop = `length`.
          rs_val = number_val( CONV f( is_obj-arr->length( ) ) ).
        ELSE.
          TRY.
              DATA lv_aidx TYPE i.
              lv_aidx = iv_prop.
              DATA lr_aelem TYPE REF TO data.
              lr_aelem = is_obj-arr->get_item( lv_aidx ).
              IF lr_aelem IS BOUND.
                rs_val = unbox_value( lr_aelem ).
              ELSE.
                rs_val = undefined_val( ).
              ENDIF.
            CATCH cx_root.
              rs_val = undefined_val( ).
          ENDTRY.
        ENDIF.
      WHEN 2. " string
        IF iv_prop = `length`.
          rs_val = number_val( CONV f( strlen( is_obj-str ) ) ).
        ELSE.
          rs_val = undefined_val( ).
        ENDIF.
      WHEN OTHERS.
        rs_val = undefined_val( ).
    ENDCASE.
  ENDMETHOD.

  METHOD eval_method_call.
    CASE is_obj-type.
      WHEN 6. " object — look up method
        DATA lr_meth TYPE REF TO data.
        lr_meth = is_obj-obj->get( iv_method ).
        IF lr_meth IS BOUND.
          DATA(ls_mval) = unbox_value( lr_meth ).
          IF ls_mval-type = 4 AND ls_mval-fn IS BOUND.
            FIELD-SYMBOLS <fn> TYPE ty_function.
            ASSIGN ls_mval-fn->* TO <fn>.
            DATA lr_this TYPE REF TO data.
            lr_this = box_value( is_obj ).
            rs_val = call_function( is_fn = <fn> it_args = it_args io_env = io_env
                                    ir_this = lr_this ).
            " Write back mutations to original object variable
            " (update the variable in the env that holds this object)
            IF ir_obj_node IS BOUND.
              FIELD-SYMBOLS <on> TYPE ty_node.
              ASSIGN ir_obj_node->* TO <on>.
              IF <on>-kind = c_node_ident.
                DATA(ls_updated) = unbox_value( lr_this ).
                io_env->set( iv_name = <on>-str is_val = ls_updated ).
              ENDIF.
            ENDIF.
          ENDIF.
        ENDIF.
      WHEN 7. " array
        CASE iv_method.
          WHEN `push`.
            IF lines( it_args ) > 0.
              DATA lr_push_arg TYPE REF TO data.
              READ TABLE it_args INDEX 1 INTO lr_push_arg.
              is_obj-arr->push( box_value( unbox_value( lr_push_arg ) ) ).
              rs_val = number_val( CONV f( is_obj-arr->length( ) ) ).
            ENDIF.
        ENDCASE.
      WHEN 2. " string
        CASE iv_method.
          WHEN `charAt`.
            IF lines( it_args ) > 0.
              DATA lr_cha TYPE REF TO data.
              READ TABLE it_args INDEX 1 INTO lr_cha.
              DATA lv_cidx TYPE i.
              lv_cidx = to_number( unbox_value( lr_cha ) ).
              IF lv_cidx >= 0 AND lv_cidx < strlen( is_obj-str ).
                rs_val = string_val( is_obj-str+lv_cidx(1) ).
              ELSE.
                rs_val = string_val( `` ).
              ENDIF.
            ELSE.
              rs_val = string_val( `` ).
            ENDIF.
          WHEN `indexOf`.
            IF lines( it_args ) > 0.
              DATA lr_ioa TYPE REF TO data.
              READ TABLE it_args INDEX 1 INTO lr_ioa.
              DATA(lv_search) = to_string( unbox_value( lr_ioa ) ).
              FIND lv_search IN is_obj-str MATCH OFFSET DATA(lv_offset).
              IF sy-subrc = 0.
                rs_val = number_val( CONV f( lv_offset ) ).
              ELSE.
                rs_val = number_val( -1 ).
              ENDIF.
            ELSE.
              rs_val = number_val( -1 ).
            ENDIF.
          WHEN `substring`.
            IF lines( it_args ) >= 2.
              DATA lr_ss1 TYPE REF TO data.
              DATA lr_ss2 TYPE REF TO data.
              READ TABLE it_args INDEX 1 INTO lr_ss1.
              READ TABLE it_args INDEX 2 INTO lr_ss2.
              DATA lv_start TYPE i.
              DATA lv_end   TYPE i.
              lv_start = to_number( unbox_value( lr_ss1 ) ).
              lv_end   = to_number( unbox_value( lr_ss2 ) ).
              DATA lv_slen TYPE i.
              lv_slen = strlen( is_obj-str ).
              IF lv_start < 0. lv_start = 0. ENDIF.
              IF lv_start > lv_slen. lv_start = lv_slen. ENDIF.
              IF lv_end < 0. lv_end = 0. ENDIF.
              IF lv_end > lv_slen. lv_end = lv_slen. ENDIF.
              IF lv_start > lv_end.
                DATA lv_tmp TYPE i.
                lv_tmp = lv_start.
                lv_start = lv_end.
                lv_end = lv_tmp.
              ENDIF.
              DATA lv_sublen TYPE i.
              lv_sublen = lv_end - lv_start.
              IF lv_sublen > 0.
                rs_val = string_val( is_obj-str+lv_start(lv_sublen) ).
              ELSE.
                rs_val = string_val( `` ).
              ENDIF.
            ENDIF.
          WHEN `charCodeAt`.
            IF lines( it_args ) > 0.
              DATA lr_cca TYPE REF TO data.
              READ TABLE it_args INDEX 1 INTO lr_cca.
              DATA lv_ccidx TYPE i.
              lv_ccidx = to_number( unbox_value( lr_cca ) ).
              IF lv_ccidx >= 0 AND lv_ccidx < strlen( is_obj-str ).
                DATA lv_char TYPE c LENGTH 1.
                lv_char = is_obj-str+lv_ccidx(1).
                DATA lv_hex TYPE x LENGTH 2.
                lv_hex = cl_abap_conv_out_ce=>uccp( lv_char ).
                DATA lv_code TYPE i.
                lv_code = lv_hex.
                rs_val = number_val( CONV f( lv_code ) ).
              ELSE.
                rs_val = number_val( 0 ).
              ENDIF.
            ELSE.
              rs_val = number_val( 0 ).
            ENDIF.
        ENDCASE.
    ENDCASE.
  ENDMETHOD.

  METHOD eval_bin_op.
    " String concatenation
    IF iv_op = `+` AND ( is_left-type = 2 OR is_right-type = 2 ).
      rs_val = string_val( to_string( is_left ) && to_string( is_right ) ).
      RETURN.
    ENDIF.
    " Equality
    CASE iv_op.
      WHEN `==` OR `===`.
        IF is_left-type <> is_right-type.
          rs_val = bool_val( abap_false ).
          RETURN.
        ENDIF.
        IF is_left-type = 2.
          rs_val = bool_val( boolc( is_left-str = is_right-str ) ).
          RETURN.
        ENDIF.
        rs_val = bool_val( boolc( to_number( is_left ) = to_number( is_right ) ) ).
        RETURN.
      WHEN `!=` OR `!==`.
        IF is_left-type <> is_right-type.
          rs_val = bool_val( abap_true ).
          RETURN.
        ENDIF.
        IF is_left-type = 2.
          rs_val = bool_val( boolc( is_left-str <> is_right-str ) ).
          RETURN.
        ENDIF.
        rs_val = bool_val( boolc( to_number( is_left ) <> to_number( is_right ) ) ).
        RETURN.
    ENDCASE.
    DATA lv_a TYPE f.
    DATA lv_b TYPE f.
    lv_a = to_number( is_left ).
    lv_b = to_number( is_right ).
    CASE iv_op.
      WHEN `+`.
        rs_val = number_val( lv_a + lv_b ).
      WHEN `-`.
        rs_val = number_val( lv_a - lv_b ).
      WHEN `*`.
        rs_val = number_val( lv_a * lv_b ).
      WHEN `/`.
        IF lv_b <> 0.
          rs_val = number_val( lv_a / lv_b ).
        ELSE.
          rs_val = number_val( 0 ).
        ENDIF.
      WHEN `%`.
        IF lv_b <> 0.
          DATA lv_ia TYPE i.
          DATA lv_ib TYPE i.
          lv_ia = lv_a.
          lv_ib = lv_b.
          rs_val = number_val( CONV f( lv_ia MOD lv_ib ) ).
        ELSE.
          rs_val = number_val( 0 ).
        ENDIF.
      WHEN `<`.
        rs_val = bool_val( boolc( lv_a < lv_b ) ).
      WHEN `>`.
        rs_val = bool_val( boolc( lv_a > lv_b ) ).
      WHEN `<=`.
        rs_val = bool_val( boolc( lv_a <= lv_b ) ).
      WHEN `>=`.
        rs_val = bool_val( boolc( lv_a >= lv_b ) ).
      WHEN `&&`.
        rs_val = bool_val( boolc( is_true( is_left ) = abap_true
                                  AND is_true( is_right ) = abap_true ) ).
      WHEN `||`.
        rs_val = bool_val( boolc( is_true( is_left ) = abap_true
                                  OR is_true( is_right ) = abap_true ) ).
      WHEN OTHERS.
        rs_val = undefined_val( ).
    ENDCASE.
  ENDMETHOD.

ENDCLASS.
