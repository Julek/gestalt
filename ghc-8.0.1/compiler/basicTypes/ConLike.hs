{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1998

\section[ConLike]{@ConLike@: Constructor-like things}
-}

{-# LANGUAGE CPP, DeriveDataTypeable #-}

module ConLike (
          ConLike(..)
        , conLikeArity
        , conLikeFieldLabels
        , conLikeInstOrigArgTys
        , conLikeExTyVars
        , conLikeName
        , conLikeStupidTheta
        , conLikeWrapId_maybe
        , conLikeImplBangs
        , conLikeFullSig
        , conLikeResTy
        , conLikeFieldType
        , conLikesWithFields
    ) where

#include "HsVersions.h"

import DataCon
import PatSyn
import Outputable
import Unique
import Util
import Name
import BasicTypes
import TyCoRep (Type, ThetaType)
import Var
import Type (mkTyConApp)

import Data.Function (on)
import qualified Data.Data as Data
import qualified Data.Typeable
#if __GLASGOW_HASKELL__ <= 708
import Control.Applicative ((<$>))
#endif

{-
************************************************************************
*                                                                      *
\subsection{Constructor-like things}
*                                                                      *
************************************************************************
-}

-- | A constructor-like thing
data ConLike = RealDataCon DataCon
             | PatSynCon PatSyn
  deriving Data.Typeable.Typeable

{-
************************************************************************
*                                                                      *
\subsection{Instances}
*                                                                      *
************************************************************************
-}

instance Eq ConLike where
    (==) = (==) `on` getUnique
    (/=) = (/=) `on` getUnique

instance Ord ConLike where
    (<=) = (<=) `on` getUnique
    (<) = (<) `on` getUnique
    (>=) = (>=) `on` getUnique
    (>) = (>) `on` getUnique
    compare = compare `on` getUnique

instance Uniquable ConLike where
    getUnique (RealDataCon dc) = getUnique dc
    getUnique (PatSynCon ps)   = getUnique ps

instance NamedThing ConLike where
    getName (RealDataCon dc) = getName dc
    getName (PatSynCon ps)   = getName ps

instance Outputable ConLike where
    ppr (RealDataCon dc) = ppr dc
    ppr (PatSynCon ps) = ppr ps

instance OutputableBndr ConLike where
    pprInfixOcc (RealDataCon dc) = pprInfixOcc dc
    pprInfixOcc (PatSynCon ps) = pprInfixOcc ps
    pprPrefixOcc (RealDataCon dc) = pprPrefixOcc dc
    pprPrefixOcc (PatSynCon ps) = pprPrefixOcc ps

instance Data.Data ConLike where
    -- don't traverse?
    toConstr _   = abstractConstr "ConLike"
    gunfold _ _  = error "gunfold"
    dataTypeOf _ = mkNoRepType "ConLike"

-- | Number of arguments
conLikeArity :: ConLike -> Arity
conLikeArity (RealDataCon data_con) = dataConSourceArity data_con
conLikeArity (PatSynCon pat_syn)    = patSynArity pat_syn

-- | Names of fields used for selectors
conLikeFieldLabels :: ConLike -> [FieldLabel]
conLikeFieldLabels (RealDataCon data_con) = dataConFieldLabels data_con
conLikeFieldLabels (PatSynCon pat_syn)    = patSynFieldLabels pat_syn

-- | Returns just the instantiated /value/ argument types of a 'ConLike',
-- (excluding dictionary args)
conLikeInstOrigArgTys :: ConLike -> [Type] -> [Type]
conLikeInstOrigArgTys (RealDataCon data_con) tys =
    dataConInstOrigArgTys data_con tys
conLikeInstOrigArgTys (PatSynCon pat_syn) tys =
    patSynInstArgTys pat_syn tys

-- | Existentially quantified type variables
conLikeExTyVars :: ConLike -> [TyVar]
conLikeExTyVars (RealDataCon dcon1) = dataConExTyVars dcon1
conLikeExTyVars (PatSynCon psyn1)   = patSynExTyVars psyn1

conLikeName :: ConLike -> Name
conLikeName (RealDataCon data_con) = dataConName data_con
conLikeName (PatSynCon pat_syn)    = patSynName pat_syn

-- | The \"stupid theta\" of the 'ConLike', such as @data Eq a@ in:
--
-- > data Eq a => T a = ...
-- It is empty for `PatSynCon` as they do not allow such contexts.
conLikeStupidTheta :: ConLike -> ThetaType
conLikeStupidTheta (RealDataCon data_con) = dataConStupidTheta data_con
conLikeStupidTheta (PatSynCon {})         = []

-- | Returns the `Id` of the wrapper. This is also known as the builder in
-- some contexts. The value is Nothing only in the case of unidirectional
-- pattern synonyms.
conLikeWrapId_maybe :: ConLike -> Maybe Id
conLikeWrapId_maybe (RealDataCon data_con) = Just $ dataConWrapId data_con
conLikeWrapId_maybe (PatSynCon pat_syn)    = fst <$> patSynBuilder pat_syn

-- | Returns the strictness information for each constructor
conLikeImplBangs :: ConLike -> [HsImplBang]
conLikeImplBangs (RealDataCon data_con) = dataConImplBangs data_con
conLikeImplBangs (PatSynCon pat_syn)    =
    replicate (patSynArity pat_syn) HsLazy

-- | Returns the type of the whole pattern
conLikeResTy :: ConLike -> [Type] -> Type
conLikeResTy (RealDataCon con) tys = mkTyConApp (dataConTyCon con) tys
conLikeResTy (PatSynCon ps)    tys = patSynInstResTy ps tys

-- | The \"full signature\" of the 'ConLike' returns, in order:
--
-- 1) The universally quanitifed type variables
--
-- 2) The existentially quantified type variables
--
-- 3) The equality specification
--
-- 4) The provided theta (the constraints provided by a match)
--
-- 5) The required theta (the constraints required for a match)
--
-- 6) The original argument types (i.e. before
--    any change of the representation of the type)
--
-- 7) The original result type
conLikeFullSig :: ConLike
               -> ([TyVar], [TyVar], [EqSpec]
                  , ThetaType, ThetaType, [Type], Type)
conLikeFullSig (RealDataCon con) =
  let (univ_tvs, ex_tvs, eq_spec, theta, arg_tys, res_ty) = dataConFullSig con
  -- Required theta is empty as normal data cons require no additional
  -- constraints for a match
  in (univ_tvs, ex_tvs, eq_spec, theta, [], arg_tys, res_ty)
conLikeFullSig (PatSynCon pat_syn) =
 let (univ_tvs, req, ex_tvs, prov, arg_tys, res_ty) = patSynSig pat_syn
 -- eqSpec is empty
 in (univ_tvs, ex_tvs, [], prov, req, arg_tys, res_ty)

-- | Extract the type for any given labelled field of the 'ConLike'
conLikeFieldType :: ConLike -> FieldLabelString -> Type
conLikeFieldType (PatSynCon ps) label = patSynFieldType ps label
conLikeFieldType (RealDataCon dc) label = dataConFieldType dc label


-- | The ConLikes that have *all* the given fields
conLikesWithFields :: [ConLike] -> [FieldLabelString] -> [ConLike]
conLikesWithFields con_likes lbls = filter has_flds con_likes
  where has_flds dc = all (has_fld dc) lbls
        has_fld dc lbl = any (\ fl -> flLabel fl == lbl) (conLikeFieldLabels dc)
