; =========================
; Structural context nodes
; =========================

; 类：显示到类体开始前（避免把整个 body 展示出来）
(class_declaration
  body: (class_body) @context.end) @context

; 枚举：显示到枚举体开始前
(enum_declaration
  body: (enum_body) @context.end) @context

; 接口/结构体：显示到类体开始前
(interface_declaration
  body: (class_body) @context.end) @context
(struct_declaration
  body: (class_body) @context.end) @context

; extend：显示到 class body 开始前
(extend_declaration
  (class_body) @context.end) @context

; ====== 函数/方法/构造 ======
; 构造器 init：显示到函数体开始前
(init_declaration
  body: (function_body (block) @context.end)) @context

; 普通函数/方法：显示到函数体开始前
(function_declaration
  body: (function_body (block) @context.end)) @context

; main：显示到函数体开始前
(main_declaration
  body: (function_body (block) @context.end)) @context

; 类主构造：显示到函数体开始前
(class_primary_constructor
  body: (function_body (block) @context.end)) @context

; property：显示到 property body 开始前
(property_declaration
  body: (property_body) @context.end) @context

; get/set：显示到函数体开始前
(property_accessor
  (function_body (block) @context.end)) @context

(if_expression
  consequence: (block) @context.end) @context

(for_statement
  pattern: (pattern) @context.end) @context

(while_statement
  condition: (expression) @context.end) @context

(match_expression
  subject:(_) @context.end) @context

(do_statement
  (block) @context.end) @context

(try_statement
  (block) @context.end) @context

(catch_clause
  (block) @context.end) @context

(finally_clause
  (block) @context.end) @context

; 想要的话，还可以把包名作为最上层上下文（通常不需要）：
; (package_clause) @context
