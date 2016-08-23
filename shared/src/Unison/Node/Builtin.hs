{-# LANGUAGE OverloadedStrings #-}
module Unison.Node.Builtin where

import Data.List
import Data.Text (Text)
import Unison.Metadata (Metadata(..))
import Unison.Parsers (unsafeParseType)
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import Unison.Type (Type)
import Unison.Typechecker.Context (remoteSignatureOf)
import qualified Data.Vector as Vector
import qualified Data.Text as Text
import qualified Unison.ABT as ABT
import qualified Unison.Eval.Interpreter as I
import qualified Unison.Metadata as Metadata
import qualified Unison.Note as N
import qualified Unison.Reference as R
import qualified Unison.Remote as Remote
import qualified Unison.Symbol as Symbol
import qualified Unison.Term as Term
import qualified Unison.Type as Type
import qualified Unison.Var as Var
import qualified Unison.View as View

type DFO = View.DFO
type V = Symbol DFO
type WHNFEval = Term V -> N.Noted IO (ABT.Term (Term.F V) V ())

data Builtin = Builtin
               { reference :: R.Reference
               , op :: Maybe (I.Primop (N.Noted IO) V)
               , bType :: Type V
               , metadata :: Metadata V R.Reference
               }

unitRef :: Ord v => Term v
unitRef = Term.ref (R.Builtin "()")
true, false :: Ord v => Term v
true = Term.builtin "True"
false = Term.builtin "False"
pair :: Ord v => Term v
pair = Term.builtin "Pair"
pair' :: Ord v => Term v -> Term v -> Term v
pair' t1 t2 = pair `Term.app` t1 `Term.app` (pair `Term.app` t2 `Term.app` unitRef)

makeBuiltins :: WHNFEval -> [Builtin]
makeBuiltins whnf =
  let
    numeric2 :: Term V -> (Double -> Double -> Double) -> I.Primop (N.Noted IO) V
    numeric2 sym f = I.Primop 2 $ \xs -> case xs of
      [x,y] -> g <$> whnf x <*> whnf y
        where g (Term.Number' x) (Term.Number' y) = Term.lit (Term.Number (f x y))
              g x y = sym `Term.app` x `Term.app` y
      _ -> error "unpossible"
    numericCompare :: Term V -> (Double -> Double -> Bool) -> I.Primop (N.Noted IO) V
    numericCompare sym f = I.Primop 2 $ \xs -> case xs of
      [x,y] -> g <$> whnf x <*> whnf y
        where g (Term.Number' x) (Term.Number' y) = case f x y of
                False -> false
                True -> true
              g x y = sym `Term.app` x `Term.app` y
      _ -> error "unpossible"
    strict r n = Just (I.Primop n f)
      where f args = reapply <$> traverse whnf (take n args)
                      where reapply args' = Term.ref r `apps` args' `apps` drop n args
            apps f args = foldl Term.app f args
    string2 :: Term V -> (Text -> Text -> Text) -> I.Primop (N.Noted IO) V
    string2 sym f = I.Primop 2 $ \xs -> case xs of
      [x,y] -> g <$> whnf x <*> whnf y
        where g (Term.Text' x) (Term.Text' y) = Term.lit (Term.Text (f x y))
              g x y = sym `Term.app` x `Term.app` y
      _ -> error "unpossible"
    string2' :: Term V -> (Text -> Text -> Bool) -> I.Primop (N.Noted IO) V
    string2' sym f = I.Primop 2 $ \xs -> case xs of
      [x,y] -> g <$> whnf x <*> whnf y
        where g (Term.Text' x) (Term.Text' y) = if f x y then true else false
              g x y = sym `Term.app` x `Term.app` y
      _ -> error "unpossible"
  in map (\(r, o, t, m) -> Builtin r o t m)
     [ let r = R.Builtin "()"
       in (r, Nothing, unitT, prefix "()")

     , let r = R.Builtin "Color.rgba"
       in (r, strict r 4, unsafeParseType "Number -> Number -> Number -> Number -> Color", prefix "rgba")

     -- Boolean
     , let r = R.Builtin "True"
       in (r, Nothing, Type.builtin "Boolean", prefix "True")
     , let r = R.Builtin "False";
       in (r, Nothing, Type.builtin "Boolean", prefix "False")
     , let r = R.Builtin "Boolean.if";
           op [cond,t,f] = do
             cond <- whnf cond
             case cond of
               Term.Builtin' tf -> case Text.head tf of
                 'T' -> whnf t
                 'F' -> whnf f
                 _ -> error "unpossible"
               _ -> error "unpossible"
           op _ = error "unpossible"
           typ = "forall a . Boolean -> a -> a -> a"
       in (r, Just (I.Primop 3 op), unsafeParseType typ, prefix "if")

     -- Number
     , let r = R.Builtin "Number.plus"
       in (r, Just (numeric2 (Term.ref r) (+)), numOpTyp, assoc 4 "+")
     , let r = R.Builtin "Number.minus"
       in (r, Just (numeric2 (Term.ref r) (-)), numOpTyp, opl 4 "-")
     , let r = R.Builtin "Number.times"
       in (r, Just (numeric2 (Term.ref r) (*)), numOpTyp, assoc 5 "*")
     , let r = R.Builtin "Number.divide"
       in (r, Just (numeric2 (Term.ref r) (/)), numOpTyp, opl 5 "/")
     , let r = R.Builtin "Number.greaterThan"
       in (r, Just (numericCompare (Term.ref r) (>)), numCompareTyp, opl 3 ">")
     , let r = R.Builtin "Number.lessThan"
       in (r, Just (numericCompare (Term.ref r) (<)), numCompareTyp, opl 3 "<")
     , let r = R.Builtin "Number.greaterThanOrEqual"
       in (r, Just (numericCompare (Term.ref r) (>=)), numCompareTyp, opl 3 ">=")
     , let r = R.Builtin "Number.lessThanOrEqual"
       in (r, Just (numericCompare (Term.ref r) (<=)), numCompareTyp, opl 3 "<=")
     , let r = R.Builtin "Number.equal"
       in (r, Just (numericCompare (Term.ref r) (==)), numCompareTyp, opl 3 "==")
     , let r = R.Builtin "Number.Order"
       in (r, Nothing, unsafeParseType "Order Number", prefix "Number.Order")

     -- Remote
     , let r = R.Builtin "Remote.at"
           op [node,term] = do
             Term.Distributed' (Term.Node node) <- whnf node
             pure $ Term.remote (Remote.Step (Remote.At node term))
           op _ = fail "Remote.at unpossible"
       in (r, Just (I.Primop 2 op), remoteSignatureOf "Remote.at", prefix "at")
     , let r = R.Builtin "Remote.here"
           op [] = pure $ Term.remote (Remote.Step (Remote.Local (Remote.Here)))
           op _ = fail "Remote.here unpossible"
       in (r, Just (I.Primop 0 op), remoteSignatureOf "Remote.here", prefix "here")
     , let r = R.Builtin "Remote.spawn"
           op [] = pure $ Term.remote (Remote.Step (Remote.Local Remote.Spawn))
           op _ = fail "Remote.spawn unpossible"
       in (r, Just (I.Primop 0 op), remoteSignatureOf "Remote.spawn", prefix "spawn")
     , let r = R.Builtin "Remote.send"
           op [c, v] = do
             Term.Distributed' (Term.Channel c) <- whnf c
             pure $ Term.remote (Remote.Step (Remote.Local (Remote.Send c v)))
           op _ = fail "Remote.send unpossible"
       in (r, Just (I.Primop 2 op), remoteSignatureOf "Remote.send", prefix "send")
     , let r = R.Builtin "Remote.channel"
           op [] = pure $ Term.remote (Remote.Step (Remote.Local Remote.CreateChannel))
           op _ = fail "Remote.channel unpossible"
       in (r, Just (I.Primop 0 op), remoteSignatureOf "Remote.channel", prefix "channel")
    , let r = R.Builtin "Remote.bind"
          op [g, r] = do
            r <- whnf r
            -- right associate the binds so that there is always a Step on the outside
            let kcomp f g = Term.lam' ["x"] $ Term.builtin "Remote.bind" `Term.apps` [g, f `Term.app` Term.var' "x"]
            case r of
              Term.Distributed' (Term.Remote (Remote.Step s)) -> pure $ Term.remote (Remote.Bind s g)
              Term.Distributed' (Term.Remote (Remote.Bind s f)) -> pure $ Term.remote (Remote.Bind s (kcomp f g))
              _ -> fail $ "Remote.bind given a value that was not a Remote: " ++ show r
          op _ = fail "Remote.bind unpossible"
       in (r, Just (I.Primop 2 op), remoteSignatureOf "Remote.bind", prefix "bind")
     , let r = R.Builtin "Remote.pure"
           op [a] = pure $ Term.remote (Remote.Step (Remote.Local (Remote.Pure a)))
           op _ = fail "unpossible"
       in (r, Just (I.Primop 1 op), remoteSignatureOf "Remote.pure", prefix "pure")
     , let r = R.Builtin "Remote.map"
           op [f, r] = pure $ Term.builtin "Remote.bind" `Term.app`
             (Term.lam' ["x"] $ Term.remote
               (Remote.Step . Remote.Local . Remote.Pure $ f `Term.app` Term.var' "x"))
             `Term.app` r
           op _ = fail "unpossible"
       in (r, Just (I.Primop 2 op), remoteSignatureOf "Remote.map", prefix "map")
     , let r = R.Builtin "Remote.receiveAsync"
           op [chan, timeout] = do
             Term.Number' seconds <- whnf timeout
             Term.Distributed' (Term.Channel chan) <- whnf chan
             pure $ Term.remote (Remote.Step (Remote.Local (Remote.ReceiveAsync chan (Remote.Seconds seconds))))
           op _ = fail "unpossible"
       in (r, Just (I.Primop 2 op), remoteSignatureOf "Remote.receiveAsync", prefix "receiveAsync")
     , let r = R.Builtin "Remote.receive"
           op [chan] = do
             Term.Distributed' (Term.Channel chan) <- whnf chan
             pure $ Term.remote (Remote.Step (Remote.Local (Remote.Receive chan)))
           op _ = fail "unpossible"
       in (r, Just (I.Primop 1 op), remoteSignatureOf "Remote.receive", prefix "receive")
     , let r = R.Builtin "Remote.fork"
           op [r] = do
             Term.Distributed' (Term.Remote r) <- whnf r
             pure $ Term.remote (Remote.Step (Remote.Local (Remote.Fork r)))
           op _ = fail "unpossible"
       in (r, Just (I.Primop 1 op), remoteSignatureOf "Remote.fork", prefix "fork")

     , let r = R.Builtin "Symbol.Symbol"
       in (r, Nothing, unsafeParseType "Text -> Fixity -> Number -> Symbol", prefix "Symbol")

     -- Text
     , let r = R.Builtin "Text.concatenate"
       in (r, Just (string2 (Term.ref r) mappend), strOpTyp, prefixes ["concatenate", "Text"])
     , let r = R.Builtin "Text.equal"
       in (r, Just (string2' (Term.ref r) (==)), textCompareTyp, prefix "Text.equal")
     , let r = R.Builtin "Text.lessThan"
       in (r, Just (string2' (Term.ref r) (<)), textCompareTyp, prefix "Text.lessThan")
     , let r = R.Builtin "Text.lessThanOrEqual"
       in (r, Just (string2' (Term.ref r) (<=)), textCompareTyp, prefix "Text.lessThanOrEqual")
     , let r = R.Builtin "Text.greaterThan"
       in (r, Just (string2' (Term.ref r) (>)), textCompareTyp, prefix "Text.greaterThan")
     , let r = R.Builtin "Text.greaterThanOrEqual"
       in (r, Just (string2' (Term.ref r) (>=)), textCompareTyp, prefix "Text.greaterThanOrEqual")
     , let r = R.Builtin "Text.Order"
       in (r, Nothing, unsafeParseType "Order Text", prefix "Text.Order")

     , let r = R.Builtin "Text.left"
       in (r, Nothing, alignmentT, prefixes ["left", "Text"])
     , let r = R.Builtin "Text.right"
       in (r, Nothing, alignmentT, prefixes ["right", "Text"])
     , let r = R.Builtin "Text.center"
       in (r, Nothing, alignmentT, prefixes ["center", "Text"])
     , let r = R.Builtin "Text.justify"
       in (r, Nothing, alignmentT, prefixes ["justify", "Text"])

     -- Pair
     , let r = R.Builtin "Pair"
       in (r, Nothing, unsafeParseType "forall a b . a -> b -> Pair a b", prefix "Pair")
     , let r = R.Builtin "Pair.fold"
           op [f,p] = do
             p <- whnf p
             case p of
               Term.Apps' (Term.Builtin' "Pair") [a,b] -> whnf (f `Term.apps` [a,b])
               p -> fail $ "expected pair, got: " ++ show p
           op _ = error "Pair.fold unpossible"
       in (r, Just (I.Primop 2 op), unsafeParseType "forall a b c . (a -> b -> c) -> Pair a b -> c", prefix "fold")

     -- Either
     , let r = R.Builtin "Either.Left"
       in (r, Nothing, unsafeParseType "forall a b . a -> Either a b", prefix "Left")
     , let r = R.Builtin "Either.Right"
       in (r, Nothing, unsafeParseType "forall a b . b -> Either a b", prefix "Right")
     , let r = R.Builtin "Either.fold"
           op [fa,fb,e] = do
             Term.App' (Term.Builtin' tag) aOrB <- whnf e
             case tag of
               _ | tag == "Either.Left" -> whnf (fa `Term.app` aOrB)
                 | tag == "Either.Right" -> whnf (fb `Term.app` aOrB)
                 | otherwise -> error "type errror"
           op _ = error "Either.fold unpossible"
       in (r, Just (I.Primop 3 op), unsafeParseType "forall a b r . (a -> r) -> (b -> r) -> Either a b -> r", prefix "fold")

     -- Optional
     , let r = R.Builtin "Optional.None"
       in (r, Nothing, unsafeParseType "forall a . Optional a", prefix "None")
     , let r = R.Builtin "Optional.Some"
       in (r, Nothing, unsafeParseType "forall a . a -> Optional a", prefix "Some")
     , let r = R.Builtin "Optional.fold"
           op [fz,f,o] = whnf o >>= \o -> case o of
             Term.Builtin' tag | tag == "Optional.None" -> whnf fz
             Term.App' (Term.Builtin' tag) a | tag == "Optional.Some" -> whnf (f `Term.app` a)
             _ -> error "Optional.fold unpossible"
           op _ = error "Optional.fold unpossible"
       in (r, Just (I.Primop 3 op), unsafeParseType "forall a r . r -> (a -> r) -> Optional a -> r", prefix "Optional.fold")

     -- Vector
     , let r = R.Builtin "Vector.append"
           op [last,init] = do
             initr <- whnf init
             pure $ case initr of
               Term.Vector' init -> Term.vector' (Vector.snoc init last)
               init -> Term.ref r `Term.app` last `Term.app` init
           op _ = fail "Vector.append unpossible"
       in (r, Just (I.Primop 2 op), unsafeParseType "forall a. a -> Vector a -> Vector a", prefix "append")
     , let r = R.Builtin "Vector.concatenate"
           op [a,b] = do
             ar <- whnf a
             br <- whnf b
             pure $ case (ar,br) of
               (Term.Vector' a, Term.Vector' b) -> Term.vector' (a `mappend` b)
               (a,b) -> Term.ref r `Term.app` a `Term.app` b
           op _ = fail "Vector.concatenate unpossible"
       in (r, Just (I.Primop 2 op), unsafeParseType "forall a. Vector a -> Vector a -> Vector a", prefix "concatenate")
     , let r = R.Builtin "Vector.empty"
           op [] = pure $ Term.vector mempty
           op _ = fail "Vector.empty unpossible"
       in (r, Just (I.Primop 0 op), unsafeParseType "forall a. Vector a", prefix "empty")
     , let r = R.Builtin "Vector.range"
           op [start,stop] = do
             Term.Number' start <- whnf start
             Term.Number' stop <- whnf stop
             let num = Term.num . fromIntegral
             pure $ Term.vector' (Vector.fromList . map num $ [floor start .. floor stop-1])
           op _ = fail "Vector.range unpossible"
           typ = unsafeParseType "Number -> Number -> Vector Number"
       in (r, Just (I.Primop 2 op), typ, prefix "Vector.range")
     , let r = R.Builtin "Vector.empty?"
           op [v] = do
             Term.Vector' vs <- whnf v
             pure $ if Vector.null vs then true else false
           op _ = fail "Vector.empty? unpossible"
       in (r, Just (I.Primop 1 op), unsafeParseType "forall a. Vector a -> Boolean", prefix "empty?")
     , let r = R.Builtin "Vector.sort"
           op [ord,f,v] = do
             Term.Vector' vs <- whnf v
             ks <- traverse (whnf . Term.app f) vs
             Term.Builtin' ord <- whnf ord
             let
               sortableVs = Vector.zip ks vs
               f' (Term.Text' x, _) (Term.Text' y, _) = x `compare` y
               f' (Term.Number' x, _) (Term.Number' y, _) = x `compare` y
               f' (Term.App' (Term.Builtin' "Hash") (Term.Ref' r1), _)
                  (Term.App' (Term.Builtin' "Hash") (Term.Ref' r2), _) = r1 `compare` r2
               f' x y = error $ "don't know how to compare: " ++ show x ++ " " ++ show y
             pure . Term.vector . fmap snd $ sortBy f' (Vector.toList sortableVs)
           op _ = fail "Vector.sort unpossible"
           typ = "∀ a k . Order k -> (a -> k) -> Vector a -> Vector a"
       in (r, Just (I.Primop 3 op), unsafeParseType typ, prefix "Vector.sort")
     , let r = R.Builtin "Vector.size"
           op [v] = do
             Term.Vector' vs <- whnf v
             pure $ Term.num (fromIntegral $ Vector.length vs)
           op _ = fail "Vector.size unpossible"
       in (r, Just (I.Primop 1 op), unsafeParseType "forall a. Vector a -> Number", prefix "Vector.size")
     , let r = R.Builtin "Vector.reverse"
           op [v] = do
             Term.Vector' vs <- whnf v
             pure $ Term.vector' (Vector.reverse vs)
           op _ = fail "Vector.reverse unpossible"
       in (r, Just (I.Primop 1 op), unsafeParseType "forall a. Vector a -> Vector a", prefix "Vector.reverse")
     , let r = R.Builtin "Vector.split"
           op [v] = do
             Term.Vector' vs <- whnf v
             pure $ case Vector.null vs of
               True -> pair' (Term.vector []) (Term.vector [])
               False -> case Vector.splitAt (Vector.length vs `div` 2) vs of
                 (x,y) -> pair' (Term.vector' x) (Term.vector' y)
           op _ = fail "Vector.split unpossible"
           typ = "forall a. Vector a -> (Vector a, Vector a)"
       in (r, Just (I.Primop 1 op), unsafeParseType typ, prefix "Vector.split")
     , let r = R.Builtin "Vector.fold-left"
           op [f,z,vec] = whnf vec >>= \vec -> case vec of
             Term.Vector' vs -> Vector.foldM (\acc a -> whnf (f `Term.apps` [acc, a])) z vs
             _ -> pure $ Term.ref r `Term.app` vec
           op _ = fail "Vector.fold-left unpossible"
       in (r, Just (I.Primop 3 op), unsafeParseType "forall a b. (b -> a -> b) -> b -> Vector a -> b", prefix "fold-left")
     , let r = R.Builtin "Vector.map"
           op [f,vec] = do
             vecr <- whnf vec
             pure $ case vecr of
               Term.Vector' vs -> Term.vector' (fmap (Term.app f) vs)
               _ -> Term.ref r `Term.app` vecr
           op _ = fail "Vector.map unpossible"
       in (r, Just (I.Primop 2 op), unsafeParseType "forall a b. (a -> b) -> Vector a -> Vector b", prefix "map")
     , let r = R.Builtin "Vector.prepend"
           op [hd,tl] = do
             tlr <- whnf tl
             pure $ case tlr of
               Term.Vector' tl -> Term.vector' (Vector.cons hd tl)
               tl -> Term.ref r `Term.app` hd `Term.app` tl
           op _ = fail "Vector.prepend unpossible"
       in (r, Just (I.Primop 2 op), unsafeParseType "forall a. a -> Vector a -> Vector a", prefix "prepend")
     , let r = R.Builtin "Vector.single"
           op [hd] = pure $ Term.vector (pure hd)
           op _ = fail "Vector.single unpossible"
       in (r, Just (I.Primop 1 op), unsafeParseType "forall a. a -> Vector a", prefix "Vector.single")
     ]

-- type helpers
alignmentT :: Ord v => Type v
alignmentT = Type.ref (R.Builtin "Alignment")
numOpTyp :: Type V
numOpTyp = unsafeParseType "Number -> Number -> Number"
numCompareTyp :: Type V
numCompareTyp = unsafeParseType "Number -> Number -> Boolean"
textCompareTyp = unsafeParseType "Text -> Text -> Boolean"
strOpTyp :: Type V
strOpTyp = unsafeParseType "Text -> Text -> Text"
unitT :: Ord v => Type v
unitT = Type.ref (R.Builtin "Unit")

infixr 7 -->
(-->) :: Ord v => Type v -> Type v -> Type v
(-->) = Type.arrow

-- term helpers
none :: Term V
none = Term.ref $ R.Builtin "Optional.None"
some :: Term V -> Term V
some t = Term.ref (R.Builtin "Optional.Some") `Term.app` t
left :: Term V -> Term V
left t = Term.ref (R.Builtin "Either.Left") `Term.app` t
right :: Term V -> Term V
right t = Term.ref (R.Builtin "Either.Right") `Term.app` t


-- metadata helpers
opl :: Int -> Text -> Metadata V h
opl p s =
  let
    sym :: Symbol DFO
    sym = Var.named s
    s' = Symbol.annotate (View.binary View.AssociateL (View.Precedence p)) sym
  in
    Metadata Metadata.Term (Metadata.Names [s']) Nothing

assoc :: Int -> Text -> Metadata V h
assoc p s =
  let
    sym :: Symbol DFO
    sym = Var.named s
    s' = Symbol.annotate (View.binary View.Associative (View.Precedence p)) sym
  in
    Metadata Metadata.Term (Metadata.Names [s']) Nothing

prefix :: Text -> Metadata V h
prefix s = prefixes [s]

prefixes :: [Text] -> Metadata V h
prefixes s = Metadata Metadata.Term
                      (Metadata.Names (map Var.named s))
                      Nothing
