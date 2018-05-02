{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ConstraintKinds, DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UndecidableInstances #-}

{-|
Module      : Data.Sum
Description : Open unions (type-indexed co-products) for extensible effects.
Copyright   : Allele Dev 2015
License     : BSD-3
Maintainer  : allele.dev@gmail.com
Stability   : experimental
Portability : POSIX

All operations are constant-time, and there is no Typeable constraint

This is a variation of OpenUnion5.hs, which relies on overlapping
instances instead of closed type families. Closed type families
have their problems: overlapping instances can resolve even
for unground types, but closed type families are subject to a
strict apartness condition.

This implementation is very similar to OpenUnion1.hs, but without
the annoying Typeable constraint. We sort of emulate it:

Our list r of open union components is a small Universe.
Therefore, we can use the Typeable-like evidence in that
universe.

The data constructors of Sum are not exported.
-}

module Data.Sum (
  Sum,
  decompose,
  weaken,
  inj,
  prj,
  type(:<),
  type(:<:),
  Element,
  Elements,
  Apply(..),
  apply',
  apply2,
  apply2'
) where

import Data.Functor.Classes (Eq1(..), eq1, Ord1(..), compare1, Show1(..), showsPrec1)
import Data.Maybe (fromMaybe)
import Data.Proxy
import Data.Sum.Templates
import GHC.Exts (Constraint)
import GHC.Prim (Proxy#, proxy#)
import GHC.TypeLits
import Unsafe.Coerce(unsafeCoerce)

pure [mkElemIndexTypeFamily 150]

infixr 5 :<

-- Strong Sum (Existential with the evidence) is an open union
-- t is can be a GADT and hence not necessarily a Functor.
-- Int is the index of t in the list r; that is, the index of t in the
-- universe r.
data Sum (r :: [ * -> * ]) (v :: *) where
  Sum :: {-# UNPACK #-} !Int -> t v -> Sum r v

{-# INLINE prj' #-}
{-# INLINE inj' #-}
inj' :: Int -> t v -> Sum r v
inj' = Sum

prj' :: Int -> Sum r v -> Maybe (t v)
prj' n (Sum n' x) | n == n'   = Just (unsafeCoerce x)
                    | otherwise = Nothing

newtype P (t :: * -> *) (r :: [* -> *]) = P { unP :: Int }

infixr 5 :<:
-- | Find a list of members 'ms' in an open union 'r'.
type family Elements ms r :: Constraint where
  Elements (t ': cs) r = (Element t r, Elements cs r)
  Elements '[] r = ()

type (ts :<: r) = Elements ts r

-- | Inject a functor into a type-aligned union.
inj :: forall e r v. (e :< r) => e v -> Sum r v
inj = inj' (unP (elemNo :: P e r))
{-# INLINE inj #-}

-- | Maybe project a functor out of a type-aligned union.
prj :: forall e r v. (e :< r) => Sum r v -> Maybe (e v)
prj = prj' (unP (elemNo :: P e r))
{-# INLINE prj #-}


decompose :: Sum (t ': r) v -> Either (Sum r v) (t v)
decompose (Sum 0 v) = Right $ unsafeCoerce v
decompose (Sum n v) = Left  $ Sum (n-1) v
{-# INLINE [2] decompose #-}


-- | Specialized version of 'decompose'.
decompose0 :: Sum '[t] v -> Either (Sum '[] v) (t v)
decompose0 (Sum _ v) = Right $ unsafeCoerce v
-- No other case is possible
{-# RULES "decompose/singleton"  decompose = decompose0 #-}
{-# INLINE decompose0 #-}

weaken :: Sum r w -> Sum (any ': r) w
weaken (Sum n v) = Sum (n+1) v

type (Element t r) = KnownNat (ElemIndex t r)
type (t :< r) = Element t r

-- Find an index of an element in an `r'.
-- The element must exist, so this is essentially a compile-time computation.
elemNo :: forall t r . (t :< r) => P t r
elemNo = P (fromIntegral (natVal' (proxy# :: Proxy# (ElemIndex t r))))

-- | Helper to apply a function to a functor of the nth type in a type list.
class Apply (c :: (* -> *) -> Constraint) (fs :: [* -> *]) where
  apply :: proxy c -> (forall g . c g => g a -> b) -> Sum fs a -> b

apply' :: Apply c fs => proxy c -> (forall g . c g => (forall x. g x -> Sum fs x) -> g a -> b) -> Sum fs a -> b
apply' proxy f u@(Sum n _) = apply proxy (f (Sum n)) u
{-# INLINABLE apply' #-}

apply2 :: Apply c fs => proxy c -> (forall g . c g => g a -> g b -> d) -> Sum fs a -> Sum fs b -> Maybe d
apply2 proxy f u@(Sum n1 _) (Sum n2 r2)
  | n1 == n2  = Just (apply proxy (\ r1 -> f r1 (unsafeCoerce r2)) u)
  | otherwise = Nothing
{-# INLINABLE apply2 #-}

apply2' :: Apply c fs => proxy c -> (forall g . c g => (forall x. g x -> Sum fs x) -> g a -> g b -> d) -> Sum fs a -> Sum fs b -> Maybe d
apply2' proxy f u@(Sum n1 _) (Sum n2 r2)
  | n1 == n2  = Just (apply' proxy (\ reinj r1 -> f reinj r1 (unsafeCoerce r2)) u)
  | otherwise = Nothing
{-# INLINABLE apply2' #-}

pure (mkApplyInstance <$> [1..150])


instance Apply Foldable fs => Foldable (Sum fs) where
  foldMap f = apply (Proxy :: Proxy Foldable) (foldMap f)
  {-# INLINABLE foldMap #-}

  foldr combine seed = apply (Proxy :: Proxy Foldable) (foldr combine seed)
  {-# INLINABLE foldr #-}

  foldl combine seed = apply (Proxy :: Proxy Foldable) (foldl combine seed)
  {-# INLINABLE foldl #-}

  null = apply (Proxy :: Proxy Foldable) null
  {-# INLINABLE null #-}

  length = apply (Proxy :: Proxy Foldable) length
  {-# INLINABLE length #-}

instance Apply Functor fs => Functor (Sum fs) where
  fmap f = apply' (Proxy :: Proxy Functor) (\ reinj a -> reinj (fmap f a))
  {-# INLINABLE fmap #-}

  (<$) v = apply' (Proxy :: Proxy Functor) (\ reinj a -> reinj (v <$ a))
  {-# INLINABLE (<$) #-}

instance (Apply Foldable fs, Apply Functor fs, Apply Traversable fs) => Traversable (Sum fs) where
  traverse f = apply' (Proxy :: Proxy Traversable) (\ reinj a -> reinj <$> traverse f a)
  {-# INLINABLE traverse #-}

  sequenceA = apply' (Proxy :: Proxy Traversable) (\ reinj a -> reinj <$> sequenceA a)
  {-# INLINABLE sequenceA #-}


instance Apply Eq1 fs => Eq1 (Sum fs) where
  liftEq eq u1 u2 = fromMaybe False (apply2 (Proxy :: Proxy Eq1) (liftEq eq) u1 u2)
  {-# INLINABLE liftEq #-}

instance (Apply Eq1 fs, Eq a) => Eq (Sum fs a) where
  (==) = eq1
  {-# INLINABLE (==) #-}


instance (Apply Eq1 fs, Apply Ord1 fs) => Ord1 (Sum fs) where
  liftCompare compareA u1@(Sum n1 _) u2@(Sum n2 _) = fromMaybe (compare n1 n2) (apply2 (Proxy :: Proxy Ord1) (liftCompare compareA) u1 u2)
  {-# INLINABLE liftCompare #-}

instance (Apply Eq1 fs, Apply Ord1 fs, Ord a) => Ord (Sum fs a) where
  compare = compare1
  {-# INLINABLE compare #-}


instance Apply Show1 fs => Show1 (Sum fs) where
  liftShowsPrec sp sl d = apply (Proxy :: Proxy Show1) (liftShowsPrec sp sl d)
  {-# INLINABLE liftShowsPrec #-}

instance (Apply Show1 fs, Show a) => Show (Sum fs a) where
  showsPrec = showsPrec1
  {-# INLINABLE showsPrec #-}
