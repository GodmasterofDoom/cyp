module Test.Info2.Cyp.Term
    ( IdxName
    , AbsTerm (..)
    , Term
    , RawTerm
    , AbsProp (..)
    , Prop
    , RawProp
    , collectFrees
    , collectSchematics
    , defaultConsts
    , defaultToFree
    , generalizeExcept
    , generalizeExceptProp
    , iparseTerm
    , iparseProp
    , isFree
    , isSchematic
    , listComb
    , mApp
    , match
    , propLhs
    , propRhs
    , matchProp
    , propMap
    , stripComb
    , subst
    , substFree
    , substFreeProp
    , substProp
    , symPropEq
    , symIf
    , symUMinus
    , translateExp
    , translateName
    , translatePat
    , unparseAbsTerm
    , unparseTerm
    , unparseRawTerm
    , unparseAbsProp
    , unparseProp
    , unparseRawProp
    , upModeIdx
    , upModeRaw
    )
where

import Control.Monad ((>=>), liftM2, when)
import Data.Functor (void)
import Data.List (find, nub)
import qualified Language.Haskell.Exts.Parser as P
import Language.Haskell.Exts.Fixity (Fixity (..), baseFixities)
import qualified Language.Haskell.Exts.Syntax as Exts
import Language.Haskell.Exts.Syntax (Assoc (..),  Boxed(..), Exp(..), Literal (..), QName (..), QOp (..), SpecialCon (..), Name (..), ModuleName (..))
import Text.PrettyPrint (parens, quotes, text, (<+>), Doc)

import Test.Info2.Cyp.Util

type IdxName = (String, Integer)

data AbsTerm a
    = Application (AbsTerm a) (AbsTerm a)
    | Const String
    | Free a
    | Schematic a
    | Literal (Literal ())
    deriving (Show, Eq)

type Term = AbsTerm IdxName
type RawTerm = AbsTerm String


data AbsProp a = Prop (AbsTerm a) (AbsTerm a)
    deriving (Eq, Show) -- lhs, rhs

type Prop = AbsProp IdxName
type RawProp = AbsProp String

instance Functor AbsTerm where
    fmap f (Application x y) = Application (fmap f x) (fmap f y)
    fmap _ (Const x) = Const x
    fmap f (Free x) = Free (f x)
    fmap f (Schematic x) = Schematic (f x)
    fmap _ (Literal x) = Literal x

stripComb :: AbsTerm a -> (AbsTerm a, [AbsTerm a])
stripComb term = work (term, [])
  where work (Application f a, xs) = work (f, a : xs)
        work x = x

listComb :: AbsTerm a -> [AbsTerm a] -> AbsTerm a
listComb = foldl Application

mApp :: Monad m => m (AbsTerm a) -> m (AbsTerm a) -> m (AbsTerm a)
mApp = liftM2 Application

infixl 1 `mApp`

match :: Eq a => AbsTerm a -> AbsTerm a -> [(a, AbsTerm a)] -> Maybe [(a, AbsTerm a)]
match (Application f a) (Application f' a') s = match f f' s >>= match a a'
match t (Schematic v) s = case lookup v s of
    Nothing -> Just $ (v,t) : s
    Just t' -> if t == t' then Just s else Nothing
match term pat s
    | term == pat = Just s
    | otherwise = Nothing

subst :: Eq a => AbsTerm a -> [(a, AbsTerm a)] -> AbsTerm a
subst (Application f a) s = Application (subst f s) (subst a s)
subst (Schematic v) s = case lookup v s of
      Nothing -> Schematic v
      Just t -> t
subst t _ = t

substFree :: Eq a => AbsTerm a -> [(a, AbsTerm a)] -> AbsTerm a
substFree (Application f a) s = Application (substFree f s) (substFree a s)
substFree (Free v) s = case lookup v s of
      Nothing -> Free v
      Just t -> t
substFree t _ = t

-- Generalizes a term by turning Frees into Schematics.
-- XXX: Result may not be as general as intended, as
-- generalizing may reuse names ...
generalizeExcept :: Eq a => [a] -> AbsTerm a -> AbsTerm a
generalizeExcept vs (Application s t) = Application (generalizeExcept vs s) (generalizeExcept vs t)
generalizeExcept vs (Free v)
    | v `elem` vs = Free v
    | otherwise = Schematic v
generalizeExcept _ t = t

collectFrees :: Eq a => AbsTerm a -> [a] -> [a]
collectFrees t xs = nub $ collect t xs
  where
    collect (Application f a) xs = collect f $ collect a xs
    collect (Const _) xs = xs
    collect (Free v) xs = v : xs
    collect (Literal _) xs = xs
    collect (Schematic _) xs = xs

isFree :: AbsTerm a -> Bool
isFree (Free _) = True
isFree _ = False

collectSchematics :: Eq a => AbsTerm a -> [a] -> [a]
collectSchematics t xs = nub $ collect t xs
  where
    collect (Application f a) xs = collect f $ collect a xs
    collect (Const _) xs = xs
    collect (Free _) xs = xs
    collect (Literal _) xs = xs
    collect (Schematic v) xs = v : xs

isSchematic :: AbsTerm a -> Bool
isSchematic (Schematic _) = True
isSchematic _ = False

symPropEq :: String
symPropEq = ".=."

symUMinus :: String
symUMinus = "-"

symCons :: String
symCons = ":"

-- Choose an invalid symbol to represent an if
symIf :: String
symIf = ".if"


{- Prop operations --------------------------------------------------}

propLhs :: AbsProp a -> AbsTerm a
propLhs (Prop lhs _) = lhs

propRhs :: AbsProp a -> AbsTerm a
propRhs (Prop _ rhs) = rhs

propMap :: (AbsTerm a -> AbsTerm b) -> AbsProp a -> AbsProp b
propMap f (Prop l r) = Prop (f l) (f r)

matchProp :: Eq a => AbsProp a -> AbsProp a -> [(a, AbsTerm a)] -> Maybe [(a, AbsTerm a)]
matchProp (Prop l r) (Prop l' r') = match l l' >=> match r r'

substProp :: Eq a => AbsProp a -> [(a, AbsTerm a)] -> AbsProp a
substProp p s = propMap (`subst` s) p

substFreeProp :: Eq a => AbsProp a -> [(a, AbsTerm a)] -> AbsProp a
substFreeProp p s = propMap (`substFree` s) p

-- Generalizes a prop by turning Frees into Schematics.
-- XXX: Result may not be as general as intended, as
-- generalizing may reuse names ...
generalizeExceptProp :: Eq a => [a] -> AbsProp a -> AbsProp a
generalizeExceptProp vs = propMap (generalizeExcept vs)


{- Parsing ----------------------------------------------------------}

defaultConsts :: [String]
defaultConsts = symPropEq : map (\(Fixity _ _ qName) -> translateQName qName) baseFixities

iparseTermRaw :: (String -> Err (AbsTerm a)) -> String -> Err (AbsTerm a)
iparseTermRaw f s = errCtxt (text "Parsing term" <+> quotes (text s)) $
    case P.parseExpWithMode mode s of
        P.ParseOk p -> translateExp (withDefConsts f) p
        x@(P.ParseFailed _ _) -> err $ renderSrcExtsFail "expression" x
  where
    mode = P.defaultParseMode { P.fixities = Just $ Fixity (AssocNone ()) (-1) (UnQual () $ Symbol () symPropEq) : baseFixities }
    withDefConsts f x = if x `elem` defaultConsts then return (Const x) else f x

defaultToFree :: [String] -> String -> Err RawTerm
defaultToFree consts x = return $ if x `elem` consts then Const x else Free x

checkHasPropEq :: AbsTerm a -> Err ()
checkHasPropEq term = when (hasPropEq term) $
    errStr $ "A term may not include the equality symbol '" ++ symPropEq ++ "'."
  where
    hasPropEq (Application f a) = hasPropEq f || hasPropEq a
    hasPropEq (Const c) | c == symPropEq = True
    hasPropEq _ = False

iparseTerm :: (String -> Err (AbsTerm a))-> String -> Err (AbsTerm a)
iparseTerm f s = do
    term <- iparseTermRaw f s
    checkHasPropEq term
    return term


iparseProp :: (String -> Err (AbsTerm a)) -> String -> Err (AbsProp a)
iparseProp f s = do
    term <- iparseTermRaw f s
    (lhs, rhs) <- case term of
        Application (Application (Const c) lhs) rhs | c == symPropEq -> Right (lhs, rhs)
        _ -> errStr $ "Term '" ++ s ++ "' is not a proposition"
    checkHasPropEq lhs
    checkHasPropEq rhs
    return $ Prop lhs rhs


{- Transform Exp to Term ---------------------------------------------}

translateExp :: Show l => (String -> Err (AbsTerm a)) -> Exp l -> Err (AbsTerm a)
translateExp f (Var _ v) = f $ translateQName v
translateExp _ (Con _ c) = return . Const $ translateQName c
translateExp _ (Lit _ l) = return $ Literal $ void l
translateExp f (If _ b c1 c2) = Right (Const symIf)
    `mApp` translateExp f b `mApp` translateExp f c1 `mApp` translateExp f c2
translateExp f (InfixApp _ e1 op e2) =
    translateQOp f op `mApp` translateExp f e1 `mApp` translateExp f e2
translateExp f (App _ e1 e2) = translateExp f e1 `mApp` translateExp f e2
translateExp f (NegApp _ e) = return (Const symUMinus) `mApp` translateExp f e
translateExp f (LeftSection _ e op) = translateQOp f op `mApp` translateExp f e
translateExp f (Paren _ e) = translateExp f e
translateExp f (List _ l) = foldr (\e es -> Right (Const symCons) `mApp` translateExp f e `mApp` es) (Right $ Const "[]") l
translateExp _ e = errStr $ "Unsupported expression syntax used: " ++ show e

translatePat :: Show l => Exts.Pat l -> Err RawTerm
translatePat (Exts.PVar _ v) = Right $ Schematic $ translateName v
translatePat (Exts.PLit _ (Exts.Signless _) l) = Right $ Literal $ void l
translatePat Exts.PNPlusK{} = errStr "n+k patterns are not supported"
translatePat (Exts.PInfixApp _ p1 qn p2) =
    (return . Const $ translateQName qn) `mApp` translatePat p1 `mApp` translatePat p2
translatePat (Exts.PApp _ qn ps) = do
    cs <- traverse translatePat ps
    return $ listComb (Const $ translateQName qn) cs
translatePat Exts.PTuple{} = errStr "tuple patterns are not supported"
translatePat (Exts.PList _ ps) = foldr (\p cs -> Right (Const ":") `mApp` translatePat p `mApp` cs) (Right $ Const "[]") ps
translatePat (Exts.PParen _ p) = translatePat p
translatePat Exts.PAsPat{} = errStr "as patterns are not supported"
translatePat (Exts.PWildCard _) = errStr "wildcard patterns are not supported"
translatePat f = errStr $ "unsupported pattern type: " ++ show f

translateQOp :: (String -> Err (AbsTerm a)) -> QOp l -> Err (AbsTerm a)
translateQOp _ (QConOp _ op) = return . Const $ translateQName op
translateQOp f (QVarOp _ op) = f $ translateQName op

translateQName :: QName l -> String
translateQName (Qual _ (ModuleName _ m) (Ident _ n)) = m ++ "." ++ n
translateQName (Qual _ (ModuleName _ m) (Symbol _ n)) = m ++ "." ++ n
translateQName (UnQual _ (Ident _ n)) = n
translateQName (UnQual _ (Symbol _ n)) = n
translateQName (Special _ (UnitCon _)) = "()"
translateQName (Special _ (ListCon _)) = "[]"
translateQName (Special _ (FunCon _)) = "->"
translateQName (Special _ (Cons _)) = ":"
translateQName (Special _ (TupleCon _ b n)) = case b of
    Boxed -> "(#" ++ replicate n ',' ++ "#)"
    Unboxed -> "(" ++ replicate n ',' ++ ")"
translateQName (Special _ (UnboxedSingleCon _)) = "(# #)"
translateQName (Special _ (ExprHole _)) = "_"

translateName :: Name l -> String
translateName (Ident _ s) = s
translateName (Symbol _ s) = s



{- Pretty printing --------------------------------------------------}

data Prio = IntPrio Int | AppPrio | AtomPrio deriving (Eq, Show)
data CypFixity = CypFixity (Assoc ()) Prio String deriving Show
data CypApplied = Applied0 | Applied1 | AppliedFull deriving (Eq, Show)

instance Ord Prio where
    compare (IntPrio i) (IntPrio j) = compare i j
    compare (IntPrio _) _ = LT
    compare _ (IntPrio _) = GT
    compare AppPrio AppPrio = EQ
    compare AppPrio AtomPrio = LT
    compare AtomPrio AppPrio = GT
    compare AtomPrio AtomPrio = EQ

data UnparseMode a = UnparseMode { unparseFree :: a -> String, unparseSchematic :: a -> String }

upModeRaw :: UnparseMode String
upModeRaw = UnparseMode { unparseFree = id, unparseSchematic = ("?" ++) }

upModeIdx :: UnparseMode IdxName
upModeIdx = UnparseMode
    { unparseFree = \(x,n) -> x ++ "~" ++ show n
    , unparseSchematic = \(x,n) -> "?" ++ x ++ "~" ++ show n }

data Unparse = Unparse Doc (Assoc (), Prio, CypApplied)

upDoc :: Unparse -> Doc
upDoc (Unparse d _) = d

upAssoc :: Unparse -> Assoc ()
upAssoc (Unparse _ (a, _, _)) = a

upPrio :: Unparse -> Prio
upPrio (Unparse _ (_, p, _)) = p

upApplied :: Unparse -> CypApplied
upApplied (Unparse _ (_, _, x)) = x


unparseFixities :: [CypFixity]
unparseFixities = map (\(Fixity assoc prio name) -> CypFixity assoc (IntPrio prio) $ translateQName name) baseFixities

atomFixity :: (Assoc (), Prio, CypApplied)
atomFixity = (AssocNone (), AtomPrio, AppliedFull)

finalizePartialApp :: Unparse -> Unparse
finalizePartialApp up
    | upApplied up == AppliedFull = up
    | otherwise = Unparse (upDoc up) atomFixity

unparseAbsTerm :: UnparseMode a -> AbsTerm a -> Doc
unparseAbsTerm mode = upDoc . finalizePartialApp . unparseAbsTermRaw mode

unparseTerm = unparseAbsTerm upModeIdx
unparseRawTerm = unparseAbsTerm upModeRaw

unparseAbsProp :: UnparseMode a -> AbsProp a -> Doc
unparseAbsProp mode (Prop l r) = unparseAbsTerm mode l <+> text symPropEq <+> unparseAbsTerm mode r

unparseProp = unparseAbsProp upModeIdx
unparseRawProp = unparseAbsProp upModeRaw

unparseAbsTermRaw :: UnparseMode a -> AbsTerm a -> Unparse
unparseAbsTermRaw mode (Application (Application (Application (Const cnst) tb) tcThen) tcElse)
    | cnst == symIf = Unparse doc' atomFixity
  where
    up = upDoc . finalizePartialApp . unparseAbsTermRaw mode
    b = up tb
    cThen = up tcThen
    cElse = up tcElse
    doc' = parens $ text "if" <+> b <+> text "then" <+> cThen <+> text "else" <+> cElse

unparseAbsTermRaw mode (Application tl tr) = Unparse doc' fixity'
  where
    l = unparseAbsTermRaw mode tl
    r = finalizePartialApp $ unparseAbsTermRaw mode tr

    doc' = case upApplied l of
        Applied0
            | upPrio r > upPrio l -> upDoc r <+> upDoc l
            | upPrio l == upPrio r && assocsTo (AssocLeft ()) l r -> upDoc r <+> upDoc l
            | otherwise -> close r <+> upDoc l
        Applied1
            | upPrio r > upPrio l -> upDoc l <+> upDoc r
            | upPrio l == upPrio r && assocsTo (AssocRight ()) l r -> upDoc l <+> upDoc r
            | otherwise -> upDoc l <+> close r
        AppliedFull
            | upPrio l < AppPrio -> close l <+> close r
            | otherwise -> upDoc l <+> close r

    fixity' = case upApplied l of
        Applied0 -> (upAssoc l, upPrio l, Applied1)
        Applied1 -> (upAssoc l, upPrio l, AppliedFull)
        AppliedFull -> (AssocLeft (), AppPrio, AppliedFull)

    close u = case upPrio u of
        AtomPrio -> upDoc u
        _ -> parens (upDoc u)

    assocsTo a l r = upPrio l == upPrio r && upAssoc l == a && upAssoc r == a

unparseAbsTermRaw _ (Literal l) = Unparse (text $ unparseLiteral l) atomFixity
unparseAbsTermRaw _ (Const c) =
    case find (\(CypFixity _ _ n) -> n == c) unparseFixities of
        Nothing -> Unparse (text c) atomFixity
        Just (CypFixity assoc prio _) -> Unparse (text c) (assoc, prio, Applied0)
unparseAbsTermRaw mode (Free v) = Unparse (text $ unparseFree mode v) atomFixity
unparseAbsTermRaw mode (Schematic v) = Unparse (text $ unparseSchematic mode v) atomFixity

unparseLiteral :: Literal l -> String
unparseLiteral (Char _ c _) = show c
unparseLiteral (String _ s _) = show s
unparseLiteral (Int _ c _) = show c
unparseLiteral (Frac _ c _) = show c
unparseLiteral (PrimInt _ c _) = show c
unparseLiteral (PrimWord _ c _) = show c
unparseLiteral (PrimFloat _ c _) = show c
unparseLiteral (PrimDouble _ c _) = show c
unparseLiteral (PrimChar _ c _) = show c
unparseLiteral (PrimString _ c _) = show c
