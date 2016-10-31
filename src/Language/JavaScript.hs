{-# LANGUAGE DataKinds #-}
module Language.JavaScript where

import Data.Record
import Info
import Prologue
import Source
import qualified Syntax as S
import Term

operators :: [Text]
operators = [ "op", "bool_op", "math_op", "delete_op", "type_op", "void_op", "rel_op", "bitwise_op" ]

functions :: [Text]
functions = [ "arrow_function", "generator_function", "function" ]

forStatements :: [Text]
forStatements = [ "for_statement", "for_of_statement", "for_in_statement" ]

termConstructor
  :: Source Char -- ^ The source that the term occurs within.
  -> IO SourceSpan -- ^ The span that the term occupies. This is passed in 'IO' to guarantee some access constraints & encourage its use only when needed (improving performance).
  -> Text -- ^ The name of the production for this node.
  -> Range -- ^ The character range that the term occupies.
  -> [Term (S.Syntax Text) (Record '[Range, Category, SourceSpan])] -- ^ The child nodes of the term.
  -> IO (Term (S.Syntax Text) (Record '[Range, Category, SourceSpan])) -- ^ The resulting term, in IO.
termConstructor source sourceSpan name range children
  | name == "ERROR" = withDefaultInfo (S.Error children)
  | otherwise = withDefaultInfo $ case (name, children) of
    ("return_statement", _) -> S.Return (listToMaybe children)
    ("assignment", [ identifier, value ]) -> S.Assignment identifier value
    ("assignment", _ ) -> S.Error children
    ("math_assignment", [ identifier, value ]) -> S.MathAssignment identifier value
    ("math_assignment", _ ) -> S.Error children
    ("member_access", [ base, property ]) -> S.MemberAccess base property
    ("member_access", _ ) -> S.Error children
    ("subscript_access", [ base, element ]) -> S.SubscriptAccess base element
    ("subscript_access", _ ) -> S.Error children
    ("comma_op", [ a, b ]) -> case unwrap b of
      S.Indexed rest -> S.Indexed $ a : rest
      _ -> S.Indexed children
    ("comma_op", _ ) -> S.Error children
    ("function_call", _) -> case runCofree <$> children of
      [ _ :< S.MemberAccess{..}, _ :< S.Args args ] -> S.MethodCall memberId property args
      [ _ :< S.MemberAccess{..} ] -> S.MethodCall memberId property []
      [ function, _ :< S.Args args ] -> S.FunctionCall (cofree function) args
      (x:xs) -> S.FunctionCall (cofree x) (cofree <$> xs)
      _ -> S.Error children
    ("ternary", condition : cases) -> S.Ternary condition cases
    ("ternary", _ ) -> S.Error children
    ("arguments", _) -> S.Args children
    ("var_assignment", [ x, y ]) -> S.VarAssignment x y
    ("var_assignment", _ ) -> S.Error children
    ("var_declaration", _) -> S.Indexed $ toVarDecl <$> children
    ("switch_statement", expr : rest) -> S.Switch expr rest
    ("switch_statement", _ ) -> S.Error children
    ("case", [ expr, body ]) -> S.Case expr body
    ("case", _ ) -> S.Error children
    ("object", _) -> S.Object $ foldMap toTuple children
    ("pair", _) -> S.Fixed children
    ("comment", _) -> S.Comment . toText $ slice range source
    ("if_statement", [ expr, thenClause, elseClause ]) -> toElseIf expr thenClause elseClause
    ("if_statement", [ expr, thenClause ]) -> S.If expr thenClause []
    ("if_statement", _ ) -> S.Error children
    ("while_statement", [ expr, body ]) -> S.While expr body
    ("while_statement", _ ) -> S.Error children
    ("do_statement", [ expr, body ]) -> S.DoWhile expr body
    ("do_statement", _ ) -> S.Error children
    ("throw_statement", [ expr ]) -> S.Throw expr
    ("throw_statment", _ ) -> S.Error children
    ("new_expression", [ expr ]) -> S.Constructor expr
    ("new_expression", _ ) -> S.Error children
    ("try_statement", [ body ]) -> S.Try body Nothing Nothing
    ("try_statement", [ body, catch ]) | Catch <- category (extract catch) -> S.Try body (Just catch) Nothing
    ("try_statement", [ body, finally ]) | Finally <- category (extract finally) -> S.Try body Nothing (Just finally)
    ("try_statement", [ body, catch, finally ])
      | Catch <- category (extract catch)
      , Finally <- category (extract finally) -> S.Try body (Just catch) (Just finally)
    ("try_statement", _ ) -> S.Error children
    ("array", _) -> S.Array children
    ("method_definition", [ identifier, params, exprs ]) -> S.Method identifier (toList (unwrap params)) (toList (unwrap exprs))
    ("method_definition", [ identifier, exprs ]) -> S.Method identifier [] (toList (unwrap exprs))
    ("method_definition", _ ) -> S.Error children
    ("class", [ identifier, superclass, definitions ]) -> S.Class identifier (Just superclass) (toList (unwrap definitions))
    ("class", [ identifier, definitions ]) -> S.Class identifier Nothing (toList (unwrap definitions))
    ("class", _ ) -> S.Error children
    ("import_statement", [ statements, identifier ] ) -> S.Import identifier (toList (unwrap statements))
    ("import_statement", [ identifier ] ) -> S.Import identifier []
    ("import_statement", _ ) -> S.Error children
    ("export_statement", [ statements, identifier] ) -> S.Export (Just identifier) (toList (unwrap statements))
    ("export_statement", [ statements ] ) -> case unwrap statements of
      S.Indexed _ -> S.Export Nothing (toList (unwrap statements))
      _ -> S.Export (Just statements) []
    ("export_statement", _ ) -> S.Error children
    _ | name `elem` forStatements, Just (exprs, body) <- unsnoc children -> S.For exprs body
    _ | name `elem` operators -> S.Operator children
    _ | name `elem` functions -> case children of
          [ body ] -> S.AnonymousFunction [] body
          [ params, body ] -> S.AnonymousFunction (toList (unwrap params)) body
          [ id, params, body ] -> S.Function id (toList (unwrap params)) body
          _ -> S.Error children
    (_, []) -> S.Leaf . toText $ slice range source
    _ -> S.Indexed children
  where
    withDefaultInfo syntax = do
      sourceSpan' <- sourceSpan
      pure $! case syntax of
        S.MethodCall{} -> cofree ((range .:  MethodCall .: sourceSpan' .: RNil) :< syntax)
        _ -> cofree ((range .: categoryForJavaScriptProductionName name .: sourceSpan' .: RNil) :< syntax)

categoryForJavaScriptProductionName :: Text -> Category
categoryForJavaScriptProductionName name = case name of
  "object" -> Object
  "expression_statement" -> ExpressionStatements
  "this_expression" -> Identifier
  "null" -> Identifier
  "undefined" -> Identifier
  "arrow_function" -> Function
  "generator_function" -> Function
  "math_op" -> MathOperator -- math operator, e.g. +, -, *, /.
  "bool_op" -> BooleanOperator -- boolean operator, e.g. ||, &&.
  "comma_op" -> CommaOperator -- comma operator, e.g. expr1, expr2.
  "delete_op" -> Operator -- delete operator, e.g. delete x[2].
  "type_op" -> Operator -- type operator, e.g. typeof Object.
  "void_op" -> Operator -- void operator, e.g. void 2.
  "for_in_statement" -> For
  "for_of_statement" -> For
  "new_expression" -> Constructor
  "class"  -> Class
  "catch" -> Catch
  "finally" -> Finally
  "if_statement" -> If
  "empty_statement" -> Empty
  "program" -> Program
  "ERROR" -> Error
  "function_call" -> FunctionCall
  "pair" -> Pair
  "string" -> StringLiteral
  "integer" -> IntegerLiteral
  "number" -> NumberLiteral
  "symbol" -> SymbolLiteral
  "array" -> ArrayLiteral
  "function" -> Function
  "identifier" -> Identifier
  "formal_parameters" -> Params
  "arguments" -> Args
  "statement_block" -> ExpressionStatements
  "assignment" -> Assignment
  "member_access" -> MemberAccess
  "op" -> Operator
  "subscript_access" -> SubscriptAccess
  "regex" -> Regex
  "template_string" -> TemplateString
  "var_assignment" -> VarAssignment
  "var_declaration" -> VarDecl
  "switch_statement" -> Switch
  "math_assignment" -> MathAssignment
  "case" -> Case
  "true" -> Boolean
  "false" -> Boolean
  "ternary" -> Ternary
  "for_statement" -> For
  "while_statement" -> While
  "do_statement" -> DoWhile
  "return_statement" -> Return
  "throw_statement" -> Throw
  "try_statement" -> Try
  "method_definition" -> Method
  "comment" -> Comment
  "bitwise_op" -> BitwiseOperator
  "rel_op" -> RelationalOperator
  "import_statement" -> Import
  "export_statement" -> Export
  _ -> Other name

toVarDecl :: (HasField fields Category) => Term (S.Syntax Text) (Record fields) -> Term (S.Syntax Text) (Record fields)
toVarDecl child = cofree $ setCategory (extract child) VarDecl :< S.VarDecl child

-- | Convert a If Term to If Syntax. This handles nested else-if clauses recursively,
-- | and satisfies arbitrarily long else-if clauses.
toElseIf :: Term (S.Syntax Text) (Record fields)
         -> Term (S.Syntax Text) (Record fields)
         -> Term (S.Syntax Text) (Record fields)
         -> S.Syntax Text (Term (S.Syntax Text) (Record fields))
toElseIf expr thenClause elseClause = S.If expr thenClause (elseClause' elseClause)
  where
    elseClause' term = case unwrap term of
      S.If _ _ [] -> [ term ]
      S.If then' else' children -> [ cofree (extract term :< S.If then' else' []) ] <> (elseClause' =<< children)
      _ -> [ term ]

toTuple :: Term (S.Syntax Text) (Record fields) -> [Term (S.Syntax Text) (Record fields)]
toTuple child | S.Indexed [key,value] <- unwrap child = [cofree (extract child :< S.Pair key value)]
toTuple child | S.Fixed [key,value] <- unwrap child = [cofree (extract child :< S.Pair key value)]
toTuple child | S.Leaf c <- unwrap child = [cofree (extract child :< S.Comment c)]
toTuple child = pure child
