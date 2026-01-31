# Indentation rules for Cangjie Tree-sitter grammar
(#set! indent-width 4)

; Increase indentation after opening delimiters
(["(" "[" "{"] @indent.begin)

; Decrease indentation before closing delimiters
([")" "]" "}"] @indent.end)

; Maintain indentation for block-like constructs
(block) @indent.always
(class_body) @indent.always
(enum_body) @indent.always
(property_body) @indent.always
(lambda_literal) @indent.always
(match_case) @indent.always
(statement_block) @indent.always

; Align branch keywords with their matching constructs
(["else" "catch" "finally"] @indent.branch)
