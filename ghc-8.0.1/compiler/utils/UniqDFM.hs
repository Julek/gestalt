{-
(c) Bartosz Nitka, Facebook, 2015

UniqDFM: Specialised deterministic finite maps, for things with @Uniques@.

Basically, the things need to be in class @Uniquable@, and we use the
@getUnique@ method to grab their @Uniques@.

This is very similar to @UniqFM@, the major difference being that the order of
folding is not dependent on @Unique@ ordering, giving determinism.
Currently the ordering is determined by insertion order.

See Note [Unique Determinism] in Unique for explanation why @Unique@ ordering
is not deterministic.
-}

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -Wall #-}

module UniqDFM (
        -- * Unique-keyed deterministic mappings
        UniqDFM,       -- abstract type

        -- ** Manipulating those mappings
        emptyUDFM,
        unitUDFM,
        addToUDFM,
        delFromUDFM,
        delListFromUDFM,
        adjustUDFM,
        alterUDFM,
        mapUDFM,
        plusUDFM,
        lookupUDFM,
        elemUDFM,
        foldUDFM,
        eltsUDFM,
        filterUDFM,
        isNullUDFM,
        sizeUDFM,
        intersectUDFM,
        intersectsUDFM,
        disjointUDFM,
        minusUDFM,
        partitionUDFM,

        udfmToList,
        udfmToUfm,
        alwaysUnsafeUfmToUdfm,
    ) where

import Unique           ( Uniquable(..), Unique, getKey )
import Outputable

import qualified Data.IntMap as M
import Data.Typeable
import Data.Data
import Data.List (sortBy)
import Data.Function (on)
import UniqFM (UniqFM, listToUFM_Directly, ufmToList)

-- Note [Deterministic UniqFM]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A @UniqDFM@ is just like @UniqFM@ with the following additional
-- property: the function `udfmToList` returns the elements in some
-- deterministic order not depending on the Unique key for those elements.
--
-- If the client of the map performs operations on the map in deterministic
-- order then `udfmToList` returns them in deterministic order.
--
-- There is an implementation cost: each element is given a serial number
-- as it is added, and `udfmToList` sorts it's result by this serial
-- number. So you should only use `UniqDFM` if you need the deterministic
-- property.
--
-- `foldUDFM` also preserves determinism.
--
-- Normal @UniqFM@ when you turn it into a list will use
-- Data.IntMap.toList function that returns the elements in the order of
-- the keys. The keys in @UniqFM@ are always @Uniques@, so you end up with
-- with a list ordered by @Uniques@.
-- The order of @Uniques@ is known to be not stable across rebuilds.
-- See Note [Unique Determinism] in Unique.
--
--
-- There's more than one way to implement this. The implementation here tags
-- every value with the insertion time that can later be used to sort the
-- values when asked to convert to a list.
--
-- An alternative would be to have
--
--   data UniqDFM ele = UDFM (M.IntMap ele) [ele]
--
-- where the list determines the order. This makes deletion tricky as we'd
-- only accumulate elements in that list, but makes merging easier as you
-- can just merge both structures independently.
-- Deletion can probably be done in amortized fashion when the size of the
-- list is twice the size of the set.

-- | A type of values tagged with insertion time
data TaggedVal val =
  TaggedVal
    val
    {-# UNPACK #-} !Int -- ^ insertion time
  deriving (Data, Typeable)

taggedFst :: TaggedVal val -> val
taggedFst (TaggedVal v _) = v

taggedSnd :: TaggedVal val -> Int
taggedSnd (TaggedVal _ i) = i

instance Eq val => Eq (TaggedVal val) where
  (TaggedVal v1 _) == (TaggedVal v2 _) = v1 == v2

instance Functor TaggedVal where
  fmap f (TaggedVal val i) = TaggedVal (f val) i

-- | Type of unique deterministic finite maps
data UniqDFM ele =
  UDFM
    !(M.IntMap (TaggedVal ele)) -- A map where keys are Unique's values and
                                -- values are tagged with insertion time.
                                -- The invariant is that all the tags will
                                -- be distinct within a single map
    {-# UNPACK #-} !Int         -- Upper bound on the values' insertion
                                -- time. See Note [Overflow on plusUDFM]
  deriving (Data, Typeable, Functor)

emptyUDFM :: UniqDFM elt
emptyUDFM = UDFM M.empty 0

unitUDFM :: Uniquable key => key -> elt -> UniqDFM elt
unitUDFM k v = UDFM (M.singleton (getKey $ getUnique k) (TaggedVal v 0)) 1

addToUDFM :: Uniquable key => UniqDFM elt -> key -> elt  -> UniqDFM elt
addToUDFM (UDFM m i) k v =
  UDFM (M.insert (getKey $ getUnique k) (TaggedVal v i) m) (i + 1)

addToUDFM_Directly :: UniqDFM elt -> Unique -> elt -> UniqDFM elt
addToUDFM_Directly (UDFM m i) u v =
  UDFM (M.insert (getKey u) (TaggedVal v i) m) (i + 1)

addListToUDFM_Directly :: UniqDFM elt -> [(Unique,elt)] -> UniqDFM elt
addListToUDFM_Directly = foldl (\m (k, v) -> addToUDFM_Directly m k v)

delFromUDFM :: Uniquable key => UniqDFM elt -> key -> UniqDFM elt
delFromUDFM (UDFM m i) k = UDFM (M.delete (getKey $ getUnique k) m) i

-- Note [Overflow on plusUDFM]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- There are multiple ways of implementing plusUDFM.
-- The main problem that needs to be solved is overlap on times of
-- insertion between different keys in two maps.
-- Consider:
--
-- A = fromList [(a, (x, 1))]
-- B = fromList [(b, (y, 1))]
--
-- If you merge them naively you end up with:
--
-- C = fromList [(a, (x, 1)), (b, (y, 1))]
--
-- Which loses information about ordering and brings us back into
-- non-deterministic world.
--
-- The solution I considered before would increment the tags on one of the
-- sets by the upper bound of the other set. The problem with this approach
-- is that you'll run out of tags for some merge patterns.
-- Say you start with A with upper bound 1, you merge A with A to get A' and
-- the upper bound becomes 2. You merge A' with A' and the upper bound
-- doubles again. After 64 merges you overflow.
-- This solution would have the same time complexity as plusUFM, namely O(n+m).
--
-- The solution I ended up with has time complexity of
-- O(m log m + m * min (n+m, W)) where m is the smaller set.
-- It simply inserts the elements of the smaller set into the larger
-- set in the order that they were inserted into the smaller set. That's
-- O(m log m) for extracting the elements from the smaller set in the
-- insertion order and O(m * min(n+m, W)) to insert them into the bigger
-- set.

plusUDFM :: UniqDFM elt -> UniqDFM elt -> UniqDFM elt
plusUDFM udfml@(UDFM _ i) udfmr@(UDFM _ j)
  -- we will use the upper bound on the tag as a proxy for the set size,
  -- to insert the smaller one into the bigger one
  | i > j = insertUDFMIntoLeft udfml udfmr
  | otherwise = insertUDFMIntoLeft udfmr udfml

insertUDFMIntoLeft :: UniqDFM elt -> UniqDFM elt -> UniqDFM elt
insertUDFMIntoLeft udfml udfmr = addListToUDFM_Directly udfml $ udfmToList udfmr

lookupUDFM :: Uniquable key => UniqDFM elt -> key -> Maybe elt
lookupUDFM (UDFM m _i) k = taggedFst `fmap` M.lookup (getKey $ getUnique k) m

elemUDFM :: Uniquable key => key -> UniqDFM elt -> Bool
elemUDFM k (UDFM m _i) = M.member (getKey $ getUnique k) m

-- | Performs a deterministic fold over the UniqDFM.
-- It's O(n log n) while the corresponding function on `UniqFM` is O(n).
foldUDFM :: (elt -> a -> a) -> a -> UniqDFM elt -> a
foldUDFM k z m = foldr k z (eltsUDFM m)

eltsUDFM :: UniqDFM elt -> [elt]
eltsUDFM (UDFM m _i) =
  map taggedFst $ sortBy (compare `on` taggedSnd) $ M.elems m

filterUDFM :: (elt -> Bool) -> UniqDFM elt -> UniqDFM elt
filterUDFM p (UDFM m i) = UDFM (M.filter (\(TaggedVal v _) -> p v) m) i

-- | Converts `UniqDFM` to a list, with elements in deterministic order.
-- It's O(n log n) while the corresponding function on `UniqFM` is O(n).
udfmToList :: UniqDFM elt -> [(Unique, elt)]
udfmToList (UDFM m _i) =
  [ (getUnique k, taggedFst v)
  | (k, v) <- sortBy (compare `on` (taggedSnd . snd)) $ M.toList m ]

isNullUDFM :: UniqDFM elt -> Bool
isNullUDFM (UDFM m _) = M.null m

sizeUDFM :: UniqDFM elt -> Int
sizeUDFM (UDFM m _i) = M.size m

intersectUDFM :: UniqDFM elt -> UniqDFM elt -> UniqDFM elt
intersectUDFM (UDFM x i) (UDFM y _j) = UDFM (M.intersection x y) i
  -- M.intersection is left biased, that means the result will only have
  -- a subset of elements from the left set, so `i` is a good upper bound.

intersectsUDFM :: UniqDFM elt -> UniqDFM elt -> Bool
intersectsUDFM x y = isNullUDFM (x `intersectUDFM` y)

disjointUDFM :: UniqDFM elt -> UniqDFM elt -> Bool
disjointUDFM (UDFM x _i) (UDFM y _j) = M.null (M.intersection x y)

minusUDFM :: UniqDFM elt1 -> UniqDFM elt2 -> UniqDFM elt1
minusUDFM (UDFM x i) (UDFM y _j) = UDFM (M.difference x y) i
  -- M.difference returns a subset of a left set, so `i` is a good upper
  -- bound.

-- | Partition UniqDFM into two UniqDFMs according to the predicate
partitionUDFM :: (elt -> Bool) -> UniqDFM elt -> (UniqDFM elt, UniqDFM elt)
partitionUDFM p (UDFM m i) =
  case M.partition (p . taggedFst) m of
    (left, right) -> (UDFM left i, UDFM right i)

-- | Delete a list of elements from a UniqDFM
delListFromUDFM  :: Uniquable key => UniqDFM elt -> [key] -> UniqDFM elt
delListFromUDFM = foldl delFromUDFM

-- | This allows for lossy conversion from UniqDFM to UniqFM
udfmToUfm :: UniqDFM elt -> UniqFM elt
udfmToUfm (UDFM m _i) =
  listToUFM_Directly [(getUnique k, taggedFst tv) | (k, tv) <- M.toList m]

listToUDFM_Directly :: [(Unique, elt)] -> UniqDFM elt
listToUDFM_Directly = foldl (\m (u, v) -> addToUDFM_Directly m u v) emptyUDFM

-- | Apply a function to a particular element
adjustUDFM :: Uniquable key => (elt -> elt) -> UniqDFM elt -> key -> UniqDFM elt
adjustUDFM f (UDFM m i) k = UDFM (M.adjust (fmap f) (getKey $ getUnique k) m) i

-- | The expression (alterUDFM f k map) alters value x at k, or absence
-- thereof. alterUDFM can be used to insert, delete, or update a value in
-- UniqDFM. Use addToUDFM, delFromUDFM or adjustUDFM when possible, they are
-- more efficient.
alterUDFM
  :: Uniquable key
  => (Maybe elt -> Maybe elt)  -- How to adjust
  -> UniqDFM elt               -- old
  -> key                       -- new
  -> UniqDFM elt               -- result
alterUDFM f (UDFM m i) k =
  UDFM (M.alter alterf (getKey $ getUnique k) m) (i + 1)
  where
  alterf Nothing = inject $ f Nothing
  alterf (Just (TaggedVal v _)) = inject $ f (Just v)
  inject Nothing = Nothing
  inject (Just v) = Just $ TaggedVal v i

-- | Map a function over every value in a UniqDFM
mapUDFM :: (elt1 -> elt2) -> UniqDFM elt1 -> UniqDFM elt2
mapUDFM f (UDFM m i) = UDFM (M.map (fmap f) m) i

-- This should not be used in commited code, provided for convenience to
-- make ad-hoc conversions when developing
alwaysUnsafeUfmToUdfm :: UniqFM elt -> UniqDFM elt
alwaysUnsafeUfmToUdfm = listToUDFM_Directly . ufmToList

-- Output-ery

instance Outputable a => Outputable (UniqDFM a) where
    ppr ufm = pprUniqDFM ppr ufm

pprUniqDFM :: (a -> SDoc) -> UniqDFM a -> SDoc
pprUniqDFM ppr_elt ufm
  = brackets $ fsep $ punctuate comma $
    [ ppr uq <+> text ":->" <+> ppr_elt elt
    | (uq, elt) <- udfmToList ufm ]
