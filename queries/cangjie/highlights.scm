; =========================
; Comments
; =========================
(line_comment) @comment
(block_comment) @comment

; =========================
; Literals
; =========================
(integer_literal) @number
(float_literal)   @number
(numeric_type_suffix) @type
(boolean_literal) @boolean
(char_literal)    @character
(string_literal)  @string
(multiline_string_literal) @string
(multiline_string_content) @string
(raw_string_literal) @string
(raw_hash_string_literal) @string
(byte_string_literal) @string
(string_content)  @string
(escape_sequence) @string.escape
(unit_literal)    @constant.builtin
["None" "Nothing" "Unit"]          @constant.builtin

(const_generic) @number

(this_expression)  @variable.builtin
(super_expression) @variable.builtin

; =========================
; String interpolation
; =========================
(string_interpolation
  "${" @punctuation.special
  (expression) @embedded
  "}"  @punctuation.special)

(string_dollar) @punctuation.special

; =========================
; Declarations & keywords
; =========================
(package_clause
  "package" @keyword)
(import_clause
  "import" @keyword)
(import_clause "as" @keyword)
(from_import_clause
  "from" @keyword
  "import" @keyword)
(from_import_clause "as" @keyword)
(import_clause
  alias: (identifier) @namespace)
(from_import_clause
  alias: (identifier) @namespace)

(class_declaration)    @keyword
(enum_declaration)     @keyword
(extend_declaration)   @keyword
(interface_declaration) @keyword
(struct_declaration)    @keyword
(type_declaration)      @keyword
(main_declaration)     @keyword
(function_declaration) @keyword
(init_declaration)     @keyword
(property_declaration) @keyword

; modifiers: abstract/final/…/inline
(modifier) @keyword.modifier

; property accessors: 用父节点内匹配字面量关键字
(property_accessor
  ["get" "set"] @keyword)

; 控制流（用节点名匹配，而非裸字面量）
(if_expression)      @keyword.conditional
(match_expression)   @keyword.conditional
(match_case "case" @keyword)
(for_statement)      @keyword.repeat
(while_statement)    @keyword.repeat
(do_statement "do" @keyword.repeat)
(return_statement)   @keyword.return
(throw_statement)    @keyword.exception
(throw_expression)   @keyword.exception
(break_statement)    @keyword
(continue_statement) @keyword
(spawn_expression "spawn" @keyword)
(quote_expression "quote" @keyword)
(is_expression
  "is" @keyword.operator)

; try/catch/finally/synchronized/unsafe
(try_statement)     @keyword.exception
(catch_clause)      @keyword.exception
(finally_clause)    @keyword.exception
(synchronized_statement) @keyword
(unsafe_block)          @keyword

; for (...) 里的 in / where，用父节点内字面量匹配
(for_statement
  "in"    @keyword
  "where" @keyword)

; let 条件绑定：匹配节点，必要时也可以点名 "let"
(let_condition) @keyword
(let_condition "let" @keyword)

; as / as?：只在强转表达式里标记
(as_expression
  ["as" "as?"] @keyword.operator)

; =========================
; Names: types / functions / properties / namespaces
; =========================
(class_declaration
  name: (identifier) @type)
(interface_declaration
  name: (identifier) @type)
(struct_declaration
  name: (identifier) @type)
(type_declaration
  name: (identifier) @type)
(enum_declaration
  name: (identifier) @type)
(class_primary_constructor
  name: (identifier) @constructor)

(type_reference
  name: (qualified_identifier) @type)
((identifier) @type.builtin
  (#match? @type.builtin "^(Bool|Rune|Float16|Float32|Float64|Int8|Int16|Int32|Int64|IntNative|UInt8|UInt16|UInt32|UInt64|UIntNative|VArray|This)$"))

(type_parameter
  name: (identifier) @type.parameter)

(function_declaration
  name: (identifier) @function)
(function_declaration
  name: (operator_symbol) @function)

(property_declaration
  name: (identifier) @property)

(member_expression
  property: (identifier) @property)

(package_clause
  name: (qualified_identifier) @namespace)

(import_clause
  path: (import_path) @namespace)
(import_clause
  (import_path) @namespace)
(from_import_clause
  source: (import_path) @namespace)
(from_import_clause
  (import_path) @namespace)
(import_items
  (import_path) @namespace)

(constructor_pattern
  name: (qualified_identifier) @constructor)
(constructor_pattern
  name: (qualified_identifier_with_dots) @constructor)
(constructor
  constructorName: (identifier) @constructor)

; typed pattern: x : T
(typed_pattern
  value: (identifier) @variable
  type:  (type)       @type)

; =========================
; Variables & parameters & bindings
; =========================
(parameter
  name: (identifier) @variable.parameter)
(constructor_parameter
  name: (identifier) @variable.parameter)
(parameter_decl
  name: (identifier) @variable.parameter)

(property_accessor
  (parameter_list
    (parameter
      name: (identifier) @variable.parameter)))


(variable_declaration
  pattern: (binding_pattern
              (identifier) @variable))

(variable_declaration
  pattern: (binding_pattern
              (binding_tuple_pattern
                (binding_pattern (identifier) @variable))))

(variable_declaration
  ["let" "var" "const"] @keyword)
(parameter_decl
  ["let" "var" "const"] @keyword)

(variable_declaration
  "=" @operator)

(assignment_expression
  left: (assignable_expression
          (identifier) @variable))

(assignment_expression
  left: (assignable_expression
          (member_expression
            property: (identifier) @property)))

(assignment_expression
  left: (assignable_expression
          (index_expression
            object: (expression)
            "]" @punctuation.delimiter)))

(assignment_expression
  operator: (assignment_operator) @operator)

; 参数名高亮（保留）
(parameter
  name: (identifier) @variable.parameter)

; match/case 中的通配符 _
(wildcard_pattern) @constant.builtin

; =========================
; Calls
; =========================
; 1) 直接以标识符作为被调用目标： foo(...)
(call_expression
  function: (expression
              (primary_expression
                (identifier) @function.call)))

; 2) 成员调用： obj.foo(...)
(call_expression
  function: (expression 
              (member_expression
    object: (expression (primary_expression (identifier)))
    property: (identifier) @function.method)))


; =========================
; Operators
; =========================
(operator_symbol)     @operator
(assignment_operator) @operator
(class_supertype_list "<:" @operator)
(class_supertype_list "&" @operator)

; unary / postfix
(unary_expression  ["+" "-" "!" "~" "++" "--"] @operator)
(postfix_unary_expression ["++" "--"] @operator)

; binary operators（在父节点里匹配匿名操作符 token）
(binary_expression "??"  @operator)
(binary_expression "||"  @operator)
(binary_expression "&&"  @operator)
(binary_expression "|"   @operator)
(binary_expression "^"   @operator)
(binary_expression "&"   @operator)
(binary_expression "=="  @operator)
(binary_expression "!="  @operator)
(binary_expression "<"   @operator)
(binary_expression "<="  @operator)
(binary_expression ">"   @operator)
(binary_expression ">="  @operator)
(binary_expression "<<"  @operator)
(binary_expression ">>"  @operator)
(binary_expression ".."  @operator)
(binary_expression "..=" @operator)
(binary_expression "..." @operator)
(binary_expression "+"   @operator)
(binary_expression "-"   @operator)
(binary_expression "*"   @operator)
(binary_expression "/"   @operator)
(binary_expression "%"   @operator)
(binary_expression "**"  @operator)

; lambda/case arrows
(lambda_literal "=>" @operator)
(match_case     "=>" @operator)

; =========================
; Punctuation & delimiters
; =========================
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," "." ":" ";"]         @punctuation.delimiter
(enum_body "|" @punctuation.delimiter)
(type_parameters "<" @punctuation.bracket)
(type_parameters ">" @punctuation.bracket)
(type_arguments "<" @punctuation.bracket)
(type_arguments ">" @punctuation.bracket)

(member_expression "."   @punctuation.delimiter)
(qualified_identifier "." @punctuation.delimiter)
(qualified_identifier_with_dots "." @punctuation.delimiter)

(parameter_list
  (parameter name: (identifier)))

(argument_list (argument))
(argument
  name: (identifier) @variable.parameter)

(lambda_parameters (identifier) @variable.parameter)

(tuple_expression (expression))

(tuple_type (type))

(index_expression object: (expression))

(block
  "{" @punctuation.bracket
  "}" @punctuation.bracket)

(annotation
  "@" @punctuation.special
  name: (identifier) @attribute)
(annotation_arguments (annotation_argument))

(annotation_argument
  name: (identifier) @attribute
  value: (expression))

; =========================
; Type annotations & labels
; =========================
(type_annotation ":" @punctuation.delimiter)

; =========================
; Casts
; =========================
(as_expression
  (type) @type)
