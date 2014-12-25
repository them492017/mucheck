{-# LANGUAGE ImpredicativeTypes #-}
-- Mutation happens here.

module MuCheck.Mutation where

import Language.Haskell.Exts(Literal(Int), Exp(App, Var, If), QName(UnQual),
        Stmt(Qualifier), Module(Module), ModuleName(..),
        Name(Ident, Symbol), Decl(FunBind, PatBind), Match,
        Pat(PVar), Match(Match), GuardedRhs(GuardedRhs), 
        prettyPrint, fromParseResult, parseFileContents)
import Data.Maybe (fromJust)
import Data.Generics (GenericQ, mkQ, Data, Typeable, mkMp)
import Data.List(nub, (\\), permutations)
import Control.Monad (liftM, zipWithM)

import MuCheck.MuOp
import MuCheck.Utils.Syb
import MuCheck.Utils.Common
import MuCheck.Operators
import MuCheck.StdArgs

-- entry point.
genMutants = genMutantsWith stdArgs

genMutantsWith :: StdArgs -> String -> FilePath -> IO Int
genMutantsWith args funcname filename  = liftM length $ do
    ast <- getASTFromFile filename
    let f = func funcname ast
    case ops f ++ swapOps f of
      [] -> return [] --  putStrLn "No applicable operator exists!"
      _  -> zipWithM writeFile (genFileNames filename) $ map prettyPrint (programMutants ast)
  where ops f = relevantOps f (muOps args ++ valOps f ++ ifElseNegOps f ++ guardedBoolNegOps f)

        valOps f = if doMutateValues args then selectIntOps f else []
        ifElseNegOps f = if doNegateIfElse args then selectIfElseBoolNegOps f else []
        guardedBoolNegOps f = if doNegateGuards args then selectGuardedBoolNegOps f else []
        swapOps f = if doMutatePatternMatches args then permMatches f ++ removeOnePMatch f else []

        fstOrder = 1 -- first order

        patternMatchMutants, ifElseNegMutants, guardedNegMutants, operatorMutants, allMutants :: Decl -> [Decl]
        patternMatchMutants f = mutatesN (swapOps f) f fstOrder
        ifElseNegMutants f = mutatesN (ifElseNegOps f) f fstOrder
        guardedNegMutants f = mutatesN (guardedBoolNegOps f) f fstOrder
        operatorMutants f = case genMode args of
            FirstOrderOnly -> mutatesN (ops f) f fstOrder
            _              -> mutates (ops f) f

        allMutants f = nub $ patternMatchMutants f ++ operatorMutants f

        func fname ast = fromJust $ selectOne (isFunctionD fname) ast
        programMutants ast =  map (putDecls ast) $ mylst ast
        mylst ast = [myfn ast x | x <- take (maxNumMutants args) $ allMutants (func funcname ast) ]
        myfn ast fn = replace (func funcname ast,fn) (getDecls ast)
        getASTFromFile filename = liftM parseModuleFromFile $ readFile filename

-- Mutating a function's code using a bunch of mutation operators
-- NOTE: In all the three mutate functions, we assume working
-- with functions declaration.
mutates :: [MuOp] -> Decl -> [Decl]
mutates ops m = filter (/= m) $ concatMap (mutatesN ops m) [1..]

-- the third argument specifies whether it's first order or higher order
mutatesN :: [MuOp] -> Decl -> Int -> [Decl]
mutatesN ops m 1 = concat [mutate op m | op <- ops ]
mutatesN ops m c =  concat [mutatesN ops m 1 | m <- mutatesN ops m (c-1)]

-- given a function, generate all mutants after applying applying 
-- op once (op might be applied at different places). E.g.:
-- op = "<" ==> ">" and there are two instances of "<"
mutate :: MuOp -> Decl -> [Decl]
mutate op m = once (mkMp' op) m \\ [m]

isFunction :: Name -> GenericQ Bool
isFunction (Ident n) = False `mkQ` isFunctionD n

isFunctionD :: String -> Decl -> Bool
isFunctionD n (FunBind (Match _ (Ident n') _ _ _ _ : _)) = n == n'
isFunctionD n (FunBind (Match _ (Symbol n') _ _ _ _ : _)) = n == n'
isFunctionD n (PatBind _ (PVar (Ident n')) _ _)          = n == n'
isFunctionD _ _                                  = False

-- generate all operators for permutating pattern matches in
-- a function. We don't deal with permutating guards and case for now.
permMatches :: Decl -> [MuOp]
permMatches d@(FunBind ms) = d ==>* map FunBind (permutations ms \\ [ms])
permMatches _  = []

removeOnePMatch :: Decl -> [MuOp]
removeOnePMatch d@(FunBind ms) = d ==>* map FunBind (removeOneElem ms \\ [ms])
removeOnePMatch _  = []

removeOneElem :: Eq t => [t] -> [[t]]
removeOneElem l = choose l (length l - 1)

-- AST/module-related operations
-- String is the content of the file
parseModuleFromFile :: String -> Module
parseModuleFromFile inp = fromParseResult $ parseFileContents inp

getDecls :: Module -> [Decl]
getDecls (Module _ _ _ _ _ _ decls) = decls

extractStrings :: [Match] -> [String] 
extractStrings [] = []
extractStrings (Match _ (Symbol name) _ _ _ _:xs) = name : extractStrings xs
extractStrings (Match _ (Ident name) _ _ _ _:xs) = name : extractStrings xs

getFuncNames :: [Decl] -> [String]
getFuncNames [] = []
getFuncNames (FunBind m:xs) = extractStrings m ++ getFuncNames xs
getFuncNames (_:xs) = getFuncNames xs
  
putDecls :: Module -> [Decl] -> Module
putDecls (Module a b c d e f _) decls = Module a b c d e f decls

getName :: Module -> String
getName (Module _ (ModuleName name) _ _ _ _ _) = name

-- Define all operations on a value
selectValOps :: (Data a, Eq a, Typeable b, Mutable b, Eq b) => (b -> Bool) -> [b -> b] -> a -> [MuOp]
selectValOps pred fs m = concatMap (\x -> x ==>* map (\f -> f x) fs) vals
  where vals = nub $ selectMany pred m

selectValOps' :: (Data a, Eq a, Typeable b, Mutable b) => (b -> Bool) -> (b -> [b]) -> a -> [MuOp]
selectValOps' pred f m = concatMap (\x -> x ==>* f x) vals
  where vals = selectMany pred m

selectIntOps :: (Data a, Eq a) => a -> [MuOp]
selectIntOps m = selectValOps isInt [
      \(Int i) -> Int (i + 1),
      \(Int i) -> Int (i - 1),
      \(Int i) -> if abs i /= 1 then Int 0 else Int i,
      \(Int i) -> if abs (i-1) /= 1 then Int 1 else Int i] m
  where isInt (Int _) = True
        isInt _       = False

-- negating boolean in if/else statements
selectIfElseBoolNegOps :: (Data a, Eq a) => a -> [MuOp]
selectIfElseBoolNegOps m = selectValOps isIf [\(If e1 e2 e3) -> If (App (Var (UnQual (Ident "not"))) e1) e2 e3] m
  where isIf If{} = True
        isIf _    = False

-- negating boolean in Guards
selectGuardedBoolNegOps :: (Data a, Eq a) => a -> [MuOp]
selectGuardedBoolNegOps m = selectValOps' isGuardedRhs negateGuardedRhs m
  where isGuardedRhs GuardedRhs{} = True
        boolNegate e@(Qualifier (Var (UnQual (Ident "otherwise")))) = [e]
        boolNegate (Qualifier exp) = [Qualifier (App (Var (UnQual (Ident "not"))) exp)]
        boolNegate x = [x]
        negateGuardedRhs (GuardedRhs srcLoc stmts exp) = [GuardedRhs srcLoc s exp | s <- once (mkMp boolNegate) stmts]

