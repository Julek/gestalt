{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998


The @TyCon@ datatype
-}

{-# LANGUAGE CPP, DeriveDataTypeable #-}

module TyCon(
        -- * Main TyCon data types
        TyCon,

        AlgTyConRhs(..), visibleDataCons,
        AlgTyConFlav(..), isNoParent,
        FamTyConFlav(..), Role(..), Injectivity(..),
        RuntimeRepInfo(..),

        -- ** Field labels
        tyConFieldLabels, tyConFieldLabelEnv,

        -- ** Constructing TyCons
        mkAlgTyCon,
        mkClassTyCon,
        mkFunTyCon,
        mkPrimTyCon,
        mkKindTyCon,
        mkLiftedPrimTyCon,
        mkTupleTyCon,
        mkSynonymTyCon,
        mkFamilyTyCon,
        mkPromotedDataCon,
        mkTcTyCon,

        -- ** Predicates on TyCons
        isAlgTyCon, isVanillaAlgTyCon,
        isClassTyCon, isFamInstTyCon,
        isFunTyCon,
        isPrimTyCon,
        isTupleTyCon, isUnboxedTupleTyCon, isBoxedTupleTyCon,
        isTypeSynonymTyCon,
        mightBeUnsaturatedTyCon,
        isPromotedDataCon, isPromotedDataCon_maybe,
        isKindTyCon, isLiftedTypeKindTyConName,

        isDataTyCon, isProductTyCon, isDataProductTyCon_maybe,
        isEnumerationTyCon,
        isNewTyCon, isAbstractTyCon,
        isFamilyTyCon, isOpenFamilyTyCon,
        isTypeFamilyTyCon, isDataFamilyTyCon,
        isOpenTypeFamilyTyCon, isClosedSynFamilyTyConWithAxiom_maybe,
        familyTyConInjectivityInfo,
        isBuiltInSynFamTyCon_maybe,
        isUnliftedTyCon,
        isGadtSyntaxTyCon, isInjectiveTyCon, isGenerativeTyCon, isGenInjAlgRhs,
        isTyConAssoc, tyConAssoc_maybe,
        isRecursiveTyCon,
        isImplicitTyCon,
        isTyConWithSrcDataCons,
        isTcTyCon,

        -- ** Extracting information out of TyCons
        tyConName,
        tyConKind,
        tyConUnique,
        tyConTyVars,
        tyConCType, tyConCType_maybe,
        tyConDataCons, tyConDataCons_maybe,
        tyConSingleDataCon_maybe, tyConSingleDataCon,
        tyConSingleAlgDataCon_maybe,
        tyConFamilySize,
        tyConStupidTheta,
        tyConArity,
        tyConRoles,
        tyConFlavour,
        tyConTuple_maybe, tyConClass_maybe, tyConATs,
        tyConFamInst_maybe, tyConFamInstSig_maybe, tyConFamilyCoercion_maybe,
        tyConFamilyResVar_maybe,
        synTyConDefn_maybe, synTyConRhs_maybe,
        famTyConFlav_maybe, famTcResVar,
        algTyConRhs,
        newTyConRhs, newTyConEtadArity, newTyConEtadRhs,
        unwrapNewTyCon_maybe, unwrapNewTyConEtad_maybe,
        algTcFields,
        tyConRuntimeRepInfo,
        tyConBinders, tyConResKind,

        -- ** Manipulating TyCons
        expandSynTyCon_maybe,
        makeTyConAbstract,
        newTyConCo, newTyConCo_maybe,
        pprPromotionQuote,

        -- * Runtime type representation
        TyConRepName, tyConRepName_maybe,
        mkPrelTyConRepName,
        tyConRepModOcc,

        -- * Primitive representations of Types
        PrimRep(..), PrimElemRep(..),
        isVoidRep, isGcPtrRep,
        primRepSizeW, primElemRepSizeB,
        primRepIsFloat,

        -- * Recursion breaking
        RecTcChecker, initRecTc, checkRecTc

) where

#include "HsVersions.h"

import {-# SOURCE #-} TyCoRep ( Kind, Type, PredType, TyBinder, mkForAllTys )
import {-# SOURCE #-} TysWiredIn  ( runtimeRepTyCon, constraintKind
                                  , vecCountTyCon, vecElemTyCon, liftedTypeKind )
import {-# SOURCE #-} DataCon ( DataCon, dataConExTyVars, dataConFieldLabels )

import Binary
import Var
import Class
import BasicTypes
import DynFlags
import ForeignCall
import Name
import NameEnv
import CoAxiom
import PrelNames
import Maybes
import Outputable
import FastStringEnv
import FieldLabel
import Constants
import Util
import Unique( tyConRepNameUnique, dataConRepNameUnique )
import UniqSet
import Module

import qualified Data.Data as Data
import Data.Typeable (Typeable)

{-
-----------------------------------------------
        Notes about type families
-----------------------------------------------

Note [Type synonym families]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* Type synonym families, also known as "type functions", map directly
  onto the type functions in FC:

        type family F a :: *
        type instance F Int = Bool
        ..etc...

* Reply "yes" to isTypeFamilyTyCon, and isFamilyTyCon

* From the user's point of view (F Int) and Bool are simply
  equivalent types.

* A Haskell 98 type synonym is a degenerate form of a type synonym
  family.

* Type functions can't appear in the LHS of a type function:
        type instance F (F Int) = ...   -- BAD!

* Translation of type family decl:
        type family F a :: *
  translates to
    a FamilyTyCon 'F', whose FamTyConFlav is OpenSynFamilyTyCon

        type family G a :: * where
          G Int = Bool
          G Bool = Char
          G a = ()
  translates to
    a FamilyTyCon 'G', whose FamTyConFlav is ClosedSynFamilyTyCon, with the
    appropriate CoAxiom representing the equations

We also support injective type families -- see Note [Injective type families]

Note [Data type families]
~~~~~~~~~~~~~~~~~~~~~~~~~
See also Note [Wrappers for data instance tycons] in MkId.hs

* Data type families are declared thus
        data family T a :: *
        data instance T Int = T1 | T2 Bool

  Here T is the "family TyCon".

* Reply "yes" to isDataFamilyTyCon, and isFamilyTyCon

* The user does not see any "equivalent types" as he did with type
  synonym families.  He just sees constructors with types
        T1 :: T Int
        T2 :: Bool -> T Int

* Here's the FC version of the above declarations:

        data T a
        data R:TInt = T1 | T2 Bool
        axiom ax_ti : T Int ~R R:TInt

  Note that this is a *representational* coercion
  The R:TInt is the "representation TyCons".
  It has an AlgTyConFlav of
        DataFamInstTyCon T [Int] ax_ti

* The axiom ax_ti may be eta-reduced; see
  Note [Eta reduction for data family axioms] in TcInstDcls

* The data contructor T2 has a wrapper (which is what the
  source-level "T2" invokes):

        $WT2 :: Bool -> T Int
        $WT2 b = T2 b `cast` sym ax_ti

* A data instance can declare a fully-fledged GADT:

        data instance T (a,b) where
          X1 :: T (Int,Bool)
          X2 :: a -> b -> T (a,b)

  Here's the FC version of the above declaration:

        data R:TPair a where
          X1 :: R:TPair Int Bool
          X2 :: a -> b -> R:TPair a b
        axiom ax_pr :: T (a,b)  ~R  R:TPair a b

        $WX1 :: forall a b. a -> b -> T (a,b)
        $WX1 a b (x::a) (y::b) = X2 a b x y `cast` sym (ax_pr a b)

  The R:TPair are the "representation TyCons".
  We have a bit of work to do, to unpick the result types of the
  data instance declaration for T (a,b), to get the result type in the
  representation; e.g.  T (a,b) --> R:TPair a b

  The representation TyCon R:TList, has an AlgTyConFlav of

        DataFamInstTyCon T [(a,b)] ax_pr

* Notice that T is NOT translated to a FC type function; it just
  becomes a "data type" with no constructors, which can be coerced inot
  into R:TInt, R:TPair by the axioms.  These axioms
  axioms come into play when (and *only* when) you
        - use a data constructor
        - do pattern matching
  Rather like newtype, in fact

  As a result

  - T behaves just like a data type so far as decomposition is concerned

  - (T Int) is not implicitly converted to R:TInt during type inference.
    Indeed the latter type is unknown to the programmer.

  - There *is* an instance for (T Int) in the type-family instance
    environment, but it is only used for overlap checking

  - It's fine to have T in the LHS of a type function:
    type instance F (T a) = [a]

  It was this last point that confused me!  The big thing is that you
  should not think of a data family T as a *type function* at all, not
  even an injective one!  We can't allow even injective type functions
  on the LHS of a type function:
        type family injective G a :: *
        type instance F (G Int) = Bool
  is no good, even if G is injective, because consider
        type instance G Int = Bool
        type instance F Bool = Char

  So a data type family is not an injective type function. It's just a
  data type with some axioms that connect it to other data types.

* The tyConTyVars of the representation tycon are the tyvars that the
  user wrote in the patterns. This is important in TcDeriv, where we
  bring these tyvars into scope before type-checking the deriving
  clause. This fact is arranged for in TcInstDecls.tcDataFamInstDecl.

Note [Associated families and their parent class]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*Associated* families are just like *non-associated* families, except
that they have a famTcParent field of (Just cls), which identifies the
parent class.

However there is an important sharing relationship between
  * the tyConTyVars of the parent Class
  * the tyConTyvars of the associated TyCon

   class C a b where
     data T p a
     type F a q b

Here the 'a' and 'b' are shared with the 'Class'; that is, they have
the same Unique.

This is important. In an instance declaration we expect
  * all the shared variables to be instantiated the same way
  * the non-shared variables of the associated type should not
    be instantiated at all

  instance C [x] (Tree y) where
     data T p [x] = T1 x | T2 p
     type F [x] q (Tree y) = (x,y,q)

Note [TyCon Role signatures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Every tycon has a role signature, assigning a role to each of the tyConTyVars
(or of equal length to the tyConArity, if there are no tyConTyVars). An
example demonstrates these best: say we have a tycon T, with parameters a at
nominal, b at representational, and c at phantom. Then, to prove
representational equality between T a1 b1 c1 and T a2 b2 c2, we need to have
nominal equality between a1 and a2, representational equality between b1 and
b2, and nothing in particular (i.e., phantom equality) between c1 and c2. This
might happen, say, with the following declaration:

  data T a b c where
    MkT :: b -> T Int b c

Data and class tycons have their roles inferred (see inferRoles in TcTyDecls),
as do vanilla synonym tycons. Family tycons have all parameters at role N,
though it is conceivable that we could relax this restriction. (->)'s and
tuples' parameters are at role R. Each primitive tycon declares its roles;
it's worth noting that (~#)'s parameters are at role N. Promoted data
constructors' type arguments are at role R. All kind arguments are at role
N.

Note [Unboxed tuple RuntimeRep vars]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The contents of an unboxed tuple may have any representation. Accordingly,
the kind of the unboxed tuple constructor is runtime-representation
polymorphic. For example,

   (#,#) :: forall (q :: RuntimeRep) (r :: RuntimeRep). TYPE q -> TYPE r -> #

These extra tyvars (v and w) cause some delicate processing around tuples,
where we used to be able to assume that the tycon arity and the
datacon arity were the same.

Note [Injective type families]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We allow injectivity annotations for type families (both open and closed):

  type family F (a :: k) (b :: k) = r | r -> a
  type family G a b = res | res -> a b where ...

Injectivity information is stored in the `famTcInj` field of `FamilyTyCon`.
`famTcInj` maybe stores a list of Bools, where each entry corresponds to a
single element of `tyConTyVars` (both lists should have identical length). If no
injectivity annotation was provided `famTcInj` is Nothing. From this follows an
invariant that if `famTcInj` is a Just then at least one element in the list
must be True.

See also:
 * [Injectivity annotation] in HsDecls
 * [Renaming injectivity annotation] in RnSource
 * [Verifying injectivity annotation] in FamInstEnv
 * [Type inference for type families with injectivity] in TcInteract


************************************************************************
*                                                                      *
\subsection{The data type}
*                                                                      *
************************************************************************
-}

-- | TyCons represent type constructors. Type constructors are introduced by
-- things such as:
--
-- 1) Data declarations: @data Foo = ...@ creates the @Foo@ type constructor of
--    kind @*@
--
-- 2) Type synonyms: @type Foo = ...@ creates the @Foo@ type constructor
--
-- 3) Newtypes: @newtype Foo a = MkFoo ...@ creates the @Foo@ type constructor
--    of kind @* -> *@
--
-- 4) Class declarations: @class Foo where@ creates the @Foo@ type constructor
--    of kind @*@
--
-- This data type also encodes a number of primitive, built in type constructors
-- such as those for function and tuple types.

-- If you edit this type, you may need to update the GHC formalism
-- See Note [GHC Formalism] in coreSyn/CoreLint.hs
data TyCon
  = -- | The function type constructor, @(->)@
    FunTyCon {
        tyConUnique :: Unique,   -- ^ A Unique of this TyCon. Invariant:
                                 -- identical to Unique of Name stored in
                                 -- tyConName field.

        tyConName   :: Name,     -- ^ Name of the constructor

        tyConBinders :: [TyBinder], -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.

        tyConResKind :: Kind,       -- ^ Cached result kind

        tyConKind   :: Kind,     -- ^ Kind of this TyCon (full kind, not just
                                 -- the return kind)

        tyConArity  :: Arity,    -- ^ Number of arguments this TyCon must
                                 -- receive to be considered saturated
                                 -- (including implicit kind variables)

        tcRepName :: TyConRepName
    }

  -- | Algebraic data types, from
  --     - @data@ declararations
  --     - @newtype@ declarations
  --     - data instance declarations
  --     - type instance declarations
  --     - the TyCon generated by a class declaration
  --     - boxed tuples
  --     - unboxed tuples
  --     - constraint tuples
  -- All these constructors are lifted and boxed except unboxed tuples
  -- which should have an 'UnboxedAlgTyCon' parent.
  -- Data/newtype/type /families/ are handled by 'FamilyTyCon'.
  -- See 'AlgTyConRhs' for more information.
  | AlgTyCon {
        tyConUnique  :: Unique,  -- ^ A Unique of this TyCon. Invariant:
                                 -- identical to Unique of Name stored in
                                 -- tyConName field.

        tyConName    :: Name,    -- ^ Name of the constructor

        tyConBinders :: [TyBinder], -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.

        tyConResKind :: Kind,       -- ^ Cached result kind

        tyConKind    :: Kind,    -- ^ Kind of this TyCon (full kind, not just
                                 -- the return kind)

        tyConArity   :: Arity,   -- ^ Number of arguments this TyCon must
                                 -- receive to be considered saturated
                                 -- (including implicit kind variables)

        tyConTyVars  :: [TyVar], -- ^ The kind and type variables used in the
                                 -- type constructor.
                                 -- Invariant: length tyvars = arity
                                 -- Precisely, this list scopes over:
                                 --
                                 -- 1. The 'algTcStupidTheta'
                                 -- 2. The cached types in algTyConRhs.NewTyCon
                                 -- 3. The family instance types if present
                                 --
                                 -- Note that it does /not/ scope over the data
                                 -- constructors.

        tcRoles      :: [Role],  -- ^ The role for each type variable
                                 -- This list has the same length as tyConTyVars
                                 -- See also Note [TyCon Role signatures]

        tyConCType   :: Maybe CType,-- ^ The C type that should be used
                                    -- for this type when using the FFI
                                    -- and CAPI

        algTcGadtSyntax  :: Bool,   -- ^ Was the data type declared with GADT
                                    -- syntax?  If so, that doesn't mean it's a
                                    -- true GADT; only that the "where" form
                                    -- was used.  This field is used only to
                                    -- guide pretty-printing

        algTcStupidTheta :: [PredType], -- ^ The \"stupid theta\" for the data
                                        -- type (always empty for GADTs).  A
                                        -- \"stupid theta\" is the context to
                                        -- the left of an algebraic type
                                        -- declaration, e.g. @Eq a@ in the
                                        -- declaration @data Eq a => T a ...@.

        algTcRhs    :: AlgTyConRhs, -- ^ Contains information about the
                                    -- data constructors of the algebraic type

        algTcFields :: FieldLabelEnv, -- ^ Maps a label to information
                                      -- about the field

        algTcRec    :: RecFlag,     -- ^ Tells us whether the data type is part
                                    -- of a mutually-recursive group or not

        algTcParent :: AlgTyConFlav -- ^ Gives the class or family declaration
                                       -- 'TyCon' for derived 'TyCon's representing
                                       -- class or family instances, respectively.

    }

  -- | Represents type synonyms
  | SynonymTyCon {
        tyConUnique  :: Unique,  -- ^ A Unique of this TyCon. Invariant:
                                 -- identical to Unique of Name stored in
                                 -- tyConName field.

        tyConName    :: Name,    -- ^ Name of the constructor

        tyConBinders :: [TyBinder], -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.

        tyConResKind :: Kind,     -- ^ Cached result kind.

        tyConKind    :: Kind,    -- ^ Kind of this TyCon (full kind, not just
                                 -- the return kind)

        tyConArity   :: Arity,   -- ^ Number of arguments this TyCon must
                                 -- receive to be considered saturated
                                 -- (including implicit kind variables)

        tyConTyVars  :: [TyVar], -- ^ List of type and kind variables in this
                                 -- TyCon. Includes implicit kind variables.
                                 -- Invariant: length tyConTyVars = tyConArity

        tcRoles      :: [Role],  -- ^ The role for each type variable
                                 -- This list has the same length as tyConTyVars
                                 -- See also Note [TyCon Role signatures]

        synTcRhs     :: Type     -- ^ Contains information about the expansion
                                 -- of the synonym
    }

  -- | Represents families (both type and data)
  -- Argument roles are all Nominal
  | FamilyTyCon {
        tyConUnique  :: Unique,  -- ^ A Unique of this TyCon. Invariant:
                                 -- identical to Unique of Name stored in
                                 -- tyConName field.

        tyConName    :: Name,    -- ^ Name of the constructor

        tyConBinders :: [TyBinder], -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.

        tyConResKind :: Kind,     -- ^ Cached result kind

        tyConKind    :: Kind,    -- ^ Kind of this TyCon (full kind, not just
                                 -- the return kind)

        tyConArity   :: Arity,   -- ^ Number of arguments this TyCon must
                                 -- receive to be considered saturated
                                 -- (including implicit kind variables)

        tyConTyVars  :: [TyVar], -- ^ The kind and type variables used in the
                                 -- type constructor.
                                 -- Invariant: length tyvars = arity
                                 -- Precisely, this list scopes over:
                                 --
                                 -- 1. The 'algTcStupidTheta'
                                 -- 2. The cached types in 'algTyConRhs.NewTyCon'
                                 -- 3. The family instance types if present
                                 --
                                 -- Note that it does /not/ scope over the data
                                 -- constructors.

        famTcResVar  :: Maybe Name,   -- ^ Name of result type variable, used
                                      -- for pretty-printing with --show-iface
                                      -- and for reifying TyCon in Template
                                      -- Haskell

        famTcFlav    :: FamTyConFlav, -- ^ Type family flavour: open, closed,
                                      -- abstract, built-in. See comments for
                                      -- FamTyConFlav

        famTcParent  :: Maybe Class,  -- ^ For *associated* type/data families
                                      -- The class in whose declaration the family is declared
                                      -- See Note [Associated families and their parent class]

        famTcInj     :: Injectivity   -- ^ is this a type family injective in
                                      -- its type variables? Nothing if no
                                      -- injectivity annotation was given
    }

  -- | Primitive types; cannot be defined in Haskell. This includes
  -- the usual suspects (such as @Int#@) as well as foreign-imported
  -- types and kinds (@*@, @#@, and @?@)
  | PrimTyCon {
        tyConUnique   :: Unique, -- ^ A Unique of this TyCon. Invariant:
                                 -- identical to Unique of Name stored in
                                 -- tyConName field.

        tyConName     :: Name,   -- ^ Name of the constructor

        tyConBinders :: [TyBinder], -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.

        tyConResKind   :: Kind,      -- ^ Cached result kind

        tyConKind     :: Kind,   -- ^ Kind of this TyCon (full kind, not just
                                 -- the return kind)

        tyConArity    :: Arity,  -- ^ Number of arguments this TyCon must
                                 -- receive to be considered saturated
                                 -- (including implicit kind variables)

        tcRoles       :: [Role], -- ^ The role for each type variable
                                 -- This list has the same length as tyConTyVars
                                 -- See also Note [TyCon Role signatures]

        isUnlifted   :: Bool,    -- ^ Most primitive tycons are unlifted (may
                                 -- not contain bottom) but other are lifted,
                                 -- e.g. @RealWorld@
                                 -- Only relevant if tyConKind = *

        primRepName :: Maybe TyConRepName   -- Only relevant for kind TyCons
                                            -- i.e, *, #, ?
    }

  -- | Represents promoted data constructor.
  | PromotedDataCon {          -- See Note [Promoted data constructors]
        tyConUnique   :: Unique, -- ^ Same Unique as the data constructor
        tyConName     :: Name,   -- ^ Same Name as the data constructor
        tyConArity    :: Arity,
        tyConBinders :: [TyBinder], -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.
        tyConResKind   :: Kind,   -- ^ Cached result kind
        tyConKind     :: Kind,   -- ^ Type of the data constructor
        tcRoles       :: [Role], -- ^ Roles: N for kind vars, R for type vars
        dataCon       :: DataCon,-- ^ Corresponding data constructor
        tcRepName     :: TyConRepName,
        promDcRepInfo :: RuntimeRepInfo  -- ^ See comments with 'RuntimeRepInfo'
    }

  -- | These exist only during a recursive type/class type-checking knot.
  | TcTyCon {
      tyConUnique :: Unique,
      tyConName   :: Name,
      tyConUnsat  :: Bool,  -- ^ can this tycon be unsaturated?
      tyConArity  :: Arity,
      tyConBinders :: [TyBinder],   -- ^ The TyBinders for this TyCon's kind.
                                    -- length tyConBinders == tyConArity.
                                    -- This is a cached value and is redundant with
                                    -- the tyConKind.
      tyConResKind :: Kind,          -- ^ Cached result kind

      tyConKind   :: Kind
      }
  deriving Typeable


-- | Represents right-hand-sides of 'TyCon's for algebraic types
data AlgTyConRhs

    -- | Says that we know nothing about this data type, except that
    -- it's represented by a pointer.  Used when we export a data type
    -- abstractly into an .hi file.
  = AbstractTyCon
      Bool      -- True  <=> It's definitely a distinct data type,
                --           equal only to itself; ie not a newtype
                -- False <=> Not sure

    -- | Information about those 'TyCon's derived from a @data@
    -- declaration. This includes data types with no constructors at
    -- all.
  | DataTyCon {
        data_cons :: [DataCon],
                          -- ^ The data type constructors; can be empty if the
                          --   user declares the type to have no constructors
                          --
                          -- INVARIANT: Kept in order of increasing 'DataCon'
                          -- tag (see the tag assignment in DataCon.mkDataCon)

        is_enum :: Bool   -- ^ Cached value: is this an enumeration type?
                          --   See Note [Enumeration types]
    }

  | TupleTyCon {                   -- A boxed, unboxed, or constraint tuple
        data_con :: DataCon,       -- NB: it can be an *unboxed* tuple
        tup_sort :: TupleSort      -- ^ Is this a boxed, unboxed or constraint
                                   -- tuple?
    }

  -- | Information about those 'TyCon's derived from a @newtype@ declaration
  | NewTyCon {
        data_con :: DataCon,    -- ^ The unique constructor for the @newtype@.
                                --   It has no existentials

        nt_rhs :: Type,         -- ^ Cached value: the argument type of the
                                -- constructor, which is just the representation
                                -- type of the 'TyCon' (remember that @newtype@s
                                -- do not exist at runtime so need a different
                                -- representation type).
                                --
                                -- The free 'TyVar's of this type are the
                                -- 'tyConTyVars' from the corresponding 'TyCon'

        nt_etad_rhs :: ([TyVar], Type),
                        -- ^ Same as the 'nt_rhs', but this time eta-reduced.
                        -- Hence the list of 'TyVar's in this field may be
                        -- shorter than the declared arity of the 'TyCon'.

                        -- See Note [Newtype eta]
        nt_co :: CoAxiom Unbranched
                             -- The axiom coercion that creates the @newtype@
                             -- from the representation 'Type'.

                             -- See Note [Newtype coercions]
                             -- Invariant: arity = #tvs in nt_etad_rhs;
                             -- See Note [Newtype eta]
                             -- Watch out!  If any newtypes become transparent
                             -- again check Trac #1072.
    }

-- | Some promoted datacons signify extra info relevant to GHC. For example,
-- the @IntRep@ constructor of @RuntimeRep@ corresponds to the 'IntRep'
-- constructor of 'PrimRep'. This data structure allows us to store this
-- information right in the 'TyCon'. The other approach would be to look
-- up things like @RuntimeRep@'s @PrimRep@ by known-key every time.
data RuntimeRepInfo
  = NoRRI       -- ^ an ordinary promoted data con
  | RuntimeRep ([Type] -> PrimRep)
      -- ^ A constructor of @RuntimeRep@. The argument to the function should
      -- be the list of arguments to the promoted datacon.
  | VecCount Int         -- ^ A constructor of @VecCount@
  | VecElem PrimElemRep  -- ^ A constructor of @VecElem@

-- | Extract those 'DataCon's that we are able to learn about.  Note
-- that visibility in this sense does not correspond to visibility in
-- the context of any particular user program!
visibleDataCons :: AlgTyConRhs -> [DataCon]
visibleDataCons (AbstractTyCon {})            = []
visibleDataCons (DataTyCon{ data_cons = cs }) = cs
visibleDataCons (NewTyCon{ data_con = c })    = [c]
visibleDataCons (TupleTyCon{ data_con = c })  = [c]

-- ^ Both type classes as well as family instances imply implicit
-- type constructors.  These implicit type constructors refer to their parent
-- structure (ie, the class or family from which they derive) using a type of
-- the following form.
data AlgTyConFlav
  = -- | An ordinary type constructor has no parent.
    VanillaAlgTyCon
       TyConRepName

    -- | An unboxed type constructor. Note that this carries no TyConRepName
    -- as it is not representable.
  | UnboxedAlgTyCon

  -- | Type constructors representing a class dictionary.
  -- See Note [ATyCon for classes] in TyCoRep
  | ClassTyCon
        Class           -- INVARIANT: the classTyCon of this Class is the
                        -- current tycon
        TyConRepName

  -- | Type constructors representing an *instance* of a *data* family.
  -- Parameters:
  --
  --  1) The type family in question
  --
  --  2) Instance types; free variables are the 'tyConTyVars'
  --  of the current 'TyCon' (not the family one). INVARIANT:
  --  the number of types matches the arity of the family 'TyCon'
  --
  --  3) A 'CoTyCon' identifying the representation
  --  type with the type instance family
  | DataFamInstTyCon          -- See Note [Data type families]
        (CoAxiom Unbranched)  -- The coercion axiom.
               -- A *Representational* coercion,
               -- of kind   T ty1 ty2   ~R   R:T a b c
               -- where T is the family TyCon,
               -- and R:T is the representation TyCon (ie this one)
               -- and a,b,c are the tyConTyVars of this TyCon
               --
               -- BUT may be eta-reduced; see TcInstDcls
               --     Note [Eta reduction for data family axioms]

          -- Cached fields of the CoAxiom, but adjusted to
          -- use the tyConTyVars of this TyCon
        TyCon   -- The family TyCon
        [Type]  -- Argument types (mentions the tyConTyVars of this TyCon)
                -- Match in length the tyConTyVars of the family TyCon

        -- E.g.  data intance T [a] = ...
        -- gives a representation tycon:
        --      data R:TList a = ...
        --      axiom co a :: T [a] ~ R:TList a
        -- with R:TList's algTcParent = DataFamInstTyCon T [a] co

instance Outputable AlgTyConFlav where
    ppr (VanillaAlgTyCon {})        = text "Vanilla ADT"
    ppr (UnboxedAlgTyCon {})        = text "Unboxed ADT"
    ppr (ClassTyCon cls _)          = text "Class parent" <+> ppr cls
    ppr (DataFamInstTyCon _ tc tys) =
        text "Family parent (family instance)" <+> ppr tc <+> sep (map ppr tys)

-- | Checks the invariants of a 'AlgTyConFlav' given the appropriate type class
-- name, if any
okParent :: Name -> AlgTyConFlav -> Bool
okParent _       (VanillaAlgTyCon {})            = True
okParent _       (UnboxedAlgTyCon)               = True
okParent tc_name (ClassTyCon cls _)              = tc_name == tyConName (classTyCon cls)
okParent _       (DataFamInstTyCon _ fam_tc tys) = tyConArity fam_tc == length tys

isNoParent :: AlgTyConFlav -> Bool
isNoParent (VanillaAlgTyCon {}) = True
isNoParent _                   = False

--------------------

data Injectivity
  = NotInjective
  | Injective [Bool]   -- 1-1 with tyConTyVars (incl kind vars)
  deriving( Eq )

-- | Information pertaining to the expansion of a type synonym (@type@)
data FamTyConFlav
  = -- | Represents an open type family without a fixed right hand
    -- side.  Additional instances can appear at any time.
    --
    -- These are introduced by either a top level declaration:
    --
    -- > data family T a :: *
    --
    -- Or an associated data type declaration, within a class declaration:
    --
    -- > class C a b where
    -- >   data T b :: *
     DataFamilyTyCon
       TyConRepName

     -- | An open type synonym family  e.g. @type family F x y :: * -> *@
   | OpenSynFamilyTyCon

   -- | A closed type synonym family  e.g.
   -- @type family F x where { F Int = Bool }@
   | ClosedSynFamilyTyCon (Maybe (CoAxiom Branched))
     -- See Note [Closed type families]

   -- | A closed type synonym family declared in an hs-boot file with
   -- type family F a where ..
   | AbstractClosedSynFamilyTyCon

   -- | Built-in type family used by the TypeNats solver
   | BuiltInSynFamTyCon BuiltInSynFamily

{-
Note [Closed type families]
~~~~~~~~~~~~~~~~~~~~~~~~~
* In an open type family you can add new instances later.  This is the
  usual case.

* In a closed type family you can only put equations where the family
  is defined.

A non-empty closed type family has a single axiom with multiple
branches, stored in the 'ClosedSynFamilyTyCon' constructor.  A closed
type family with no equations does not have an axiom, because there is
nothing for the axiom to prove!


Note [Promoted data constructors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
All data constructors can be promoted to become a type constructor,
via the PromotedDataCon alternative in TyCon.

* The TyCon promoted from a DataCon has the *same* Name and Unique as
  the DataCon.  Eg. If the data constructor Data.Maybe.Just(unique 78,
  say) is promoted to a TyCon whose name is Data.Maybe.Just(unique 78)

* Small note: We promote the *user* type of the DataCon.  Eg
     data T = MkT {-# UNPACK #-} !(Bool, Bool)
  The promoted kind is
     MkT :: (Bool,Bool) -> T
  *not*
     MkT :: Bool -> Bool -> T

Note [Enumeration types]
~~~~~~~~~~~~~~~~~~~~~~~~
We define datatypes with no constructors to *not* be
enumerations; this fixes trac #2578,  Otherwise we
end up generating an empty table for
  <mod>_<type>_closure_tbl
which is used by tagToEnum# to map Int# to constructors
in an enumeration. The empty table apparently upset
the linker.

Moreover, all the data constructor must be enumerations, meaning
they have type  (forall abc. T a b c).  GADTs are not enumerations.
For example consider
    data T a where
      T1 :: T Int
      T2 :: T Bool
      T3 :: T a
What would [T1 ..] be?  [T1,T3] :: T Int? Easiest thing is to exclude them.
See Trac #4528.

Note [Newtype coercions]
~~~~~~~~~~~~~~~~~~~~~~~~
The NewTyCon field nt_co is a CoAxiom which is used for coercing from
the representation type of the newtype, to the newtype itself. For
example,

   newtype T a = MkT (a -> a)

the NewTyCon for T will contain nt_co = CoT where CoT t : T t ~ t -> t.

In the case that the right hand side is a type application
ending with the same type variables as the left hand side, we
"eta-contract" the coercion.  So if we had

   newtype S a = MkT [a]

then we would generate the arity 0 axiom CoS : S ~ [].  The
primary reason we do this is to make newtype deriving cleaner.

In the paper we'd write
        axiom CoT : (forall t. T t) ~ (forall t. [t])
and then when we used CoT at a particular type, s, we'd say
        CoT @ s
which encodes as (TyConApp instCoercionTyCon [TyConApp CoT [], s])

Note [Newtype eta]
~~~~~~~~~~~~~~~~~~
Consider
        newtype Parser a = MkParser (IO a) deriving Monad
Are these two types equal (to Core)?
        Monad Parser
        Monad IO
which we need to make the derived instance for Monad Parser.

Well, yes.  But to see that easily we eta-reduce the RHS type of
Parser, in this case to ([], Froogle), so that even unsaturated applications
of Parser will work right.  This eta reduction is done when the type
constructor is built, and cached in NewTyCon.

Here's an example that I think showed up in practice
Source code:
        newtype T a = MkT [a]
        newtype Foo m = MkFoo (forall a. m a -> Int)

        w1 :: Foo []
        w1 = ...

        w2 :: Foo T
        w2 = MkFoo (\(MkT x) -> case w1 of MkFoo f -> f x)

After desugaring, and discarding the data constructors for the newtypes,
we get:
        w2 = w1 `cast` Foo CoT
so the coercion tycon CoT must have
        kind:    T ~ []
 and    arity:   0

************************************************************************
*                                                                      *
                 TyConRepName
*                                                                      *
********************************************************************* -}

type TyConRepName = Name -- The Name of the top-level declaration
                         --    $tcMaybe :: Data.Typeable.Internal.TyCon
                         --    $tcMaybe = TyCon { tyConName = "Maybe", ... }

tyConRepName_maybe :: TyCon -> Maybe TyConRepName
tyConRepName_maybe (FunTyCon   { tcRepName = rep_nm })
  = Just rep_nm
tyConRepName_maybe (PrimTyCon  { primRepName = mb_rep_nm })
  = mb_rep_nm
tyConRepName_maybe (AlgTyCon { algTcParent = parent })
  | VanillaAlgTyCon rep_nm <- parent = Just rep_nm
  | ClassTyCon _ rep_nm    <- parent = Just rep_nm
tyConRepName_maybe (FamilyTyCon { famTcFlav = DataFamilyTyCon rep_nm })
  = Just rep_nm
tyConRepName_maybe (PromotedDataCon { tcRepName = rep_nm })
  = Just rep_nm
tyConRepName_maybe _ = Nothing

-- | Make a 'Name' for the 'Typeable' representation of the given wired-in type
mkPrelTyConRepName :: Name -> TyConRepName
-- See Note [Grand plan for Typeable] in 'TcTypeable' in TcTypeable.
mkPrelTyConRepName tc_name  -- Prelude tc_name is always External,
                            -- so nameModule will work
  = mkExternalName rep_uniq rep_mod rep_occ (nameSrcSpan tc_name)
  where
    name_occ  = nameOccName tc_name
    name_mod  = nameModule  tc_name
    name_uniq = nameUnique  tc_name
    rep_uniq | isTcOcc name_occ = tyConRepNameUnique   name_uniq
             | otherwise        = dataConRepNameUnique name_uniq
    (rep_mod, rep_occ) = tyConRepModOcc name_mod name_occ

-- | The name (and defining module) for the Typeable representation (TyCon) of a
-- type constructor.
--
-- See Note [Grand plan for Typeable] in 'TcTypeable' in TcTypeable.
tyConRepModOcc :: Module -> OccName -> (Module, OccName)
tyConRepModOcc tc_module tc_occ = (rep_module, mkTyConRepOcc tc_occ)
  where
    rep_module
      | tc_module == gHC_PRIM = gHC_TYPES
      | otherwise             = tc_module


{- *********************************************************************
*                                                                      *
                 PrimRep
*                                                                      *
************************************************************************

Note [rep swamp]

GHC has a rich selection of types that represent "primitive types" of
one kind or another.  Each of them makes a different set of
distinctions, and mostly the differences are for good reasons,
although it's probably true that we could merge some of these.

Roughly in order of "includes more information":

 - A Width (cmm/CmmType) is simply a binary value with the specified
   number of bits.  It may represent a signed or unsigned integer, a
   floating-point value, or an address.

    data Width = W8 | W16 | W32 | W64 | W80 | W128

 - Size, which is used in the native code generator, is Width +
   floating point information.

   data Size = II8 | II16 | II32 | II64 | FF32 | FF64 | FF80

   it is necessary because e.g. the instruction to move a 64-bit float
   on x86 (movsd) is different from the instruction to move a 64-bit
   integer (movq), so the mov instruction is parameterised by Size.

 - CmmType wraps Width with more information: GC ptr, float, or
   other value.

    data CmmType = CmmType CmmCat Width

    data CmmCat     -- "Category" (not exported)
       = GcPtrCat   -- GC pointer
       | BitsCat    -- Non-pointer
       | FloatCat   -- Float

   It is important to have GcPtr information in Cmm, since we generate
   info tables containing pointerhood for the GC from this.  As for
   why we have float (and not signed/unsigned) here, see Note [Signed
   vs unsigned].

 - ArgRep makes only the distinctions necessary for the call and
   return conventions of the STG machine.  It is essentially CmmType
   + void.

 - PrimRep makes a few more distinctions than ArgRep: it divides
   non-GC-pointers into signed/unsigned and addresses, information
   that is necessary for passing these values to foreign functions.

There's another tension here: whether the type encodes its size in
bytes, or whether its size depends on the machine word size.  Width
and CmmType have the size built-in, whereas ArgRep and PrimRep do not.

This means to turn an ArgRep/PrimRep into a CmmType requires DynFlags.

On the other hand, CmmType includes some "nonsense" values, such as
CmmType GcPtrCat W32 on a 64-bit machine.
-}

-- | A 'PrimRep' is an abstraction of a type.  It contains information that
-- the code generator needs in order to pass arguments, return results,
-- and store values of this type.
data PrimRep
  = VoidRep
  | PtrRep
  | IntRep        -- ^ Signed, word-sized value
  | WordRep       -- ^ Unsigned, word-sized value
  | Int64Rep      -- ^ Signed, 64 bit value (with 32-bit words only)
  | Word64Rep     -- ^ Unsigned, 64 bit value (with 32-bit words only)
  | AddrRep       -- ^ A pointer, but /not/ to a Haskell value (use 'PtrRep')
  | FloatRep
  | DoubleRep
  | VecRep Int PrimElemRep  -- ^ A vector
  deriving( Eq, Show )

data PrimElemRep
  = Int8ElemRep
  | Int16ElemRep
  | Int32ElemRep
  | Int64ElemRep
  | Word8ElemRep
  | Word16ElemRep
  | Word32ElemRep
  | Word64ElemRep
  | FloatElemRep
  | DoubleElemRep
   deriving( Eq, Show )

instance Outputable PrimRep where
  ppr r = text (show r)

instance Outputable PrimElemRep where
  ppr r = text (show r)

isVoidRep :: PrimRep -> Bool
isVoidRep VoidRep = True
isVoidRep _other  = False

isGcPtrRep :: PrimRep -> Bool
isGcPtrRep PtrRep = True
isGcPtrRep _      = False

-- | Find the size of a 'PrimRep', in words
primRepSizeW :: DynFlags -> PrimRep -> Int
primRepSizeW _      IntRep           = 1
primRepSizeW _      WordRep          = 1
primRepSizeW dflags Int64Rep         = wORD64_SIZE `quot` wORD_SIZE dflags
primRepSizeW dflags Word64Rep        = wORD64_SIZE `quot` wORD_SIZE dflags
primRepSizeW _      FloatRep         = 1    -- NB. might not take a full word
primRepSizeW dflags DoubleRep        = dOUBLE_SIZE dflags `quot` wORD_SIZE dflags
primRepSizeW _      AddrRep          = 1
primRepSizeW _      PtrRep           = 1
primRepSizeW _      VoidRep          = 0
primRepSizeW dflags (VecRep len rep) = len * primElemRepSizeB rep `quot` wORD_SIZE dflags

primElemRepSizeB :: PrimElemRep -> Int
primElemRepSizeB Int8ElemRep   = 1
primElemRepSizeB Int16ElemRep  = 2
primElemRepSizeB Int32ElemRep  = 4
primElemRepSizeB Int64ElemRep  = 8
primElemRepSizeB Word8ElemRep  = 1
primElemRepSizeB Word16ElemRep = 2
primElemRepSizeB Word32ElemRep = 4
primElemRepSizeB Word64ElemRep = 8
primElemRepSizeB FloatElemRep  = 4
primElemRepSizeB DoubleElemRep = 8

-- | Return if Rep stands for floating type,
-- returns Nothing for vector types.
primRepIsFloat :: PrimRep -> Maybe Bool
primRepIsFloat  FloatRep     = Just True
primRepIsFloat  DoubleRep    = Just True
primRepIsFloat  (VecRep _ _) = Nothing
primRepIsFloat  _            = Just False


{-
************************************************************************
*                                                                      *
                             Field labels
*                                                                      *
************************************************************************
-}

-- | The labels for the fields of this particular 'TyCon'
tyConFieldLabels :: TyCon -> [FieldLabel]
tyConFieldLabels tc = fsEnvElts $ tyConFieldLabelEnv tc

-- | The labels for the fields of this particular 'TyCon'
tyConFieldLabelEnv :: TyCon -> FieldLabelEnv
tyConFieldLabelEnv tc
  | isAlgTyCon tc = algTcFields tc
  | otherwise     = emptyFsEnv


-- | Make a map from strings to FieldLabels from all the data
-- constructors of this algebraic tycon
fieldsOfAlgTcRhs :: AlgTyConRhs -> FieldLabelEnv
fieldsOfAlgTcRhs rhs = mkFsEnv [ (flLabel fl, fl)
                               | fl <- dataConsFields (visibleDataCons rhs) ]
  where
    -- Duplicates in this list will be removed by 'mkFsEnv'
    dataConsFields dcs = concatMap dataConFieldLabels dcs


{-
************************************************************************
*                                                                      *
\subsection{TyCon Construction}
*                                                                      *
************************************************************************

Note: the TyCon constructors all take a Kind as one argument, even though
they could, in principle, work out their Kind from their other arguments.
But to do so they need functions from Types, and that makes a nasty
module mutual-recursion.  And they aren't called from many places.
So we compromise, and move their Kind calculation to the call site.
-}

-- | Given the name of the function type constructor and it's kind, create the
-- corresponding 'TyCon'. It is reccomended to use 'TyCoRep.funTyCon' if you want
-- this functionality
mkFunTyCon :: Name -> [TyBinder] -> Name -> TyCon
mkFunTyCon name binders rep_nm
  = FunTyCon {
        tyConUnique  = nameUnique name,
        tyConName    = name,
        tyConBinders = binders,
        tyConResKind = liftedTypeKind,
        tyConKind    = mkForAllTys binders liftedTypeKind,
        tyConArity   = 2,
        tcRepName    = rep_nm
    }

-- | This is the making of an algebraic 'TyCon'. Notably, you have to
-- pass in the generic (in the -XGenerics sense) information about the
-- type constructor - you can get hold of it easily (see Generics
-- module)
mkAlgTyCon :: Name
           -> [TyBinder]        -- ^ Binders of the resulting 'TyCon'
           -> Kind              -- ^ Result kind
           -> [TyVar]           -- ^ 'TyVar's scoped over: see 'tyConTyVars'.
                                --   Arity is inferred from the length of this
                                --   list
           -> [Role]            -- ^ The roles for each TyVar
           -> Maybe CType       -- ^ The C type this type corresponds to
                                --   when using the CAPI FFI
           -> [PredType]        -- ^ Stupid theta: see 'algTcStupidTheta'
           -> AlgTyConRhs       -- ^ Information about data constructors
           -> AlgTyConFlav      -- ^ What flavour is it?
                                -- (e.g. vanilla, type family)
           -> RecFlag           -- ^ Is the 'TyCon' recursive?
           -> Bool              -- ^ Was the 'TyCon' declared with GADT syntax?
           -> TyCon
mkAlgTyCon name binders res_kind tyvars roles cType stupid rhs parent is_rec gadt_syn
  = AlgTyCon {
        tyConName        = name,
        tyConUnique      = nameUnique name,
        tyConBinders     = binders,
        tyConResKind     = res_kind,
        tyConKind        = mkForAllTys binders res_kind,
        tyConArity       = length tyvars,
        tyConTyVars      = tyvars,
        tcRoles          = roles,
        tyConCType       = cType,
        algTcStupidTheta = stupid,
        algTcRhs         = rhs,
        algTcFields      = fieldsOfAlgTcRhs rhs,
        algTcParent      = ASSERT2( okParent name parent, ppr name $$ ppr parent ) parent,
        algTcRec         = is_rec,
        algTcGadtSyntax  = gadt_syn
    }

-- | Simpler specialization of 'mkAlgTyCon' for classes
mkClassTyCon :: Name -> [TyBinder]
             -> [TyVar] -> [Role] -> AlgTyConRhs -> Class
             -> RecFlag -> Name -> TyCon
mkClassTyCon name binders tyvars roles rhs clas is_rec tc_rep_name
  = mkAlgTyCon name binders constraintKind tyvars roles Nothing [] rhs
               (ClassTyCon clas tc_rep_name)
               is_rec False

mkTupleTyCon :: Name
             -> [TyBinder]
             -> Kind    -- ^ Result kind of the 'TyCon'
             -> Arity   -- ^ Arity of the tuple
             -> [TyVar] -- ^ 'TyVar's scoped over: see 'tyConTyVars'
             -> DataCon
             -> TupleSort    -- ^ Whether the tuple is boxed or unboxed
             -> AlgTyConFlav
             -> TyCon
mkTupleTyCon name binders res_kind arity tyvars con sort parent
  = AlgTyCon {
        tyConName        = name,
        tyConUnique      = nameUnique name,
        tyConBinders     = binders,
        tyConResKind     = res_kind,
        tyConKind        = mkForAllTys binders res_kind,
        tyConArity       = arity,
        tyConTyVars      = tyvars,
        tcRoles          = replicate arity Representational,
        tyConCType       = Nothing,
        algTcStupidTheta = [],
        algTcRhs         = TupleTyCon { data_con = con,
                                        tup_sort = sort },
        algTcFields      = emptyFsEnv,
        algTcParent      = parent,
        algTcRec         = NonRecursive,
        algTcGadtSyntax  = False
    }

-- | Makes a tycon suitable for use during type-checking.
-- The only real need for this is for printing error messages during
-- a recursive type/class type-checking knot. It has a kind because
-- TcErrors sometimes calls typeKind.
-- See also Note [Kind checking recursive type and class declarations]
-- in TcTyClsDecls.
mkTcTyCon :: Name -> [TyBinder] -> Kind  -- ^ /result/ kind only
          -> Bool  -- ^ Can this be unsaturated?
          -> TyCon
mkTcTyCon name binders res_kind unsat
  = TcTyCon { tyConUnique  = getUnique name
            , tyConName    = name
            , tyConBinders = binders
            , tyConResKind = res_kind
            , tyConKind    = mkForAllTys binders res_kind
            , tyConUnsat   = unsat
            , tyConArity   = length binders }

-- | Create an unlifted primitive 'TyCon', such as @Int#@
mkPrimTyCon :: Name -> [TyBinder]
            -> Kind   -- ^ /result/ kind
            -> [Role] -> TyCon
mkPrimTyCon name binders res_kind roles
  = mkPrimTyCon' name binders res_kind roles True (Just $ mkPrelTyConRepName name)

-- | Kind constructors
mkKindTyCon :: Name -> [TyBinder]
            -> Kind  -- ^ /result/ kind
            -> [Role] -> Name -> TyCon
mkKindTyCon name binders res_kind roles rep_nm
  = tc
  where
    tc = mkPrimTyCon' name binders res_kind roles False (Just rep_nm)

-- | Create a lifted primitive 'TyCon' such as @RealWorld@
mkLiftedPrimTyCon :: Name -> [TyBinder]
                  -> Kind   -- ^ /result/ kind
                  -> [Role] -> TyCon
mkLiftedPrimTyCon name binders res_kind roles
  = mkPrimTyCon' name binders res_kind roles False Nothing

mkPrimTyCon' :: Name -> [TyBinder]
             -> Kind    -- ^ /result/ kind
             -> [Role]
             -> Bool -> Maybe TyConRepName -> TyCon
mkPrimTyCon' name binders res_kind roles is_unlifted rep_nm
  = PrimTyCon {
        tyConName    = name,
        tyConUnique  = nameUnique name,
        tyConBinders = binders,
        tyConResKind = res_kind,
        tyConKind    = mkForAllTys binders res_kind,
        tyConArity   = length roles,
        tcRoles      = roles,
        isUnlifted   = is_unlifted,
        primRepName  = rep_nm
    }

-- | Create a type synonym 'TyCon'
mkSynonymTyCon :: Name -> [TyBinder] -> Kind   -- ^ /result/ kind
               -> [TyVar] -> [Role] -> Type -> TyCon
mkSynonymTyCon name binders res_kind tyvars roles rhs
  = SynonymTyCon {
        tyConName    = name,
        tyConUnique  = nameUnique name,
        tyConBinders = binders,
        tyConResKind = res_kind,
        tyConKind    = mkForAllTys binders res_kind,
        tyConArity   = length tyvars,
        tyConTyVars  = tyvars,
        tcRoles      = roles,
        synTcRhs     = rhs
    }

-- | Create a type family 'TyCon'
mkFamilyTyCon :: Name -> [TyBinder] -> Kind  -- ^ /result/ kind
              -> [TyVar] -> Maybe Name -> FamTyConFlav
              -> Maybe Class -> Injectivity -> TyCon
mkFamilyTyCon name binders res_kind tyvars resVar flav parent inj
  = FamilyTyCon
      { tyConUnique  = nameUnique name
      , tyConName    = name
      , tyConBinders = binders
      , tyConResKind = res_kind
      , tyConKind    = mkForAllTys binders res_kind
      , tyConArity   = length tyvars
      , tyConTyVars  = tyvars
      , famTcResVar  = resVar
      , famTcFlav    = flav
      , famTcParent  = parent
      , famTcInj     = inj
      }


-- | Create a promoted data constructor 'TyCon'
-- Somewhat dodgily, we give it the same Name
-- as the data constructor itself; when we pretty-print
-- the TyCon we add a quote; see the Outputable TyCon instance
mkPromotedDataCon :: DataCon -> Name -> TyConRepName -> [TyBinder] -> Kind -> [Role]
                  -> RuntimeRepInfo -> TyCon
mkPromotedDataCon con name rep_name binders res_kind roles rep_info
  = PromotedDataCon {
        tyConUnique   = nameUnique name,
        tyConName     = name,
        tyConArity    = arity,
        tcRoles       = roles,
        tyConBinders  = binders,
        tyConResKind  = res_kind,
        tyConKind     = mkForAllTys binders res_kind,
        dataCon       = con,
        tcRepName     = rep_name,
        promDcRepInfo = rep_info
  }
  where
    arity = length roles

isFunTyCon :: TyCon -> Bool
isFunTyCon (FunTyCon {}) = True
isFunTyCon _             = False

-- | Test if the 'TyCon' is algebraic but abstract (invisible data constructors)
isAbstractTyCon :: TyCon -> Bool
isAbstractTyCon (AlgTyCon { algTcRhs = AbstractTyCon {} }) = True
isAbstractTyCon _ = False

-- | Make an fake, abstract 'TyCon' from an existing one.
-- Used when recovering from errors
makeTyConAbstract :: TyCon -> TyCon
makeTyConAbstract tc
  = mkTcTyCon (tyConName tc) (tyConBinders tc) (tyConResKind tc)
              (mightBeUnsaturatedTyCon tc)

-- | Does this 'TyCon' represent something that cannot be defined in Haskell?
isPrimTyCon :: TyCon -> Bool
isPrimTyCon (PrimTyCon {}) = True
isPrimTyCon _              = False

-- | Is this 'TyCon' unlifted (i.e. cannot contain bottom)? Note that this can
-- only be true for primitive and unboxed-tuple 'TyCon's
isUnliftedTyCon :: TyCon -> Bool
isUnliftedTyCon (PrimTyCon  {isUnlifted = is_unlifted})
  = is_unlifted
isUnliftedTyCon (AlgTyCon { algTcRhs = rhs } )
  | TupleTyCon { tup_sort = sort } <- rhs
  = not (isBoxed (tupleSortBoxity sort))
isUnliftedTyCon _ = False

-- | Returns @True@ if the supplied 'TyCon' resulted from either a
-- @data@ or @newtype@ declaration
isAlgTyCon :: TyCon -> Bool
isAlgTyCon (AlgTyCon {})   = True
isAlgTyCon _               = False

-- | Returns @True@ for vanilla AlgTyCons -- that is, those created
-- with a @data@ or @newtype@ declaration.
isVanillaAlgTyCon :: TyCon -> Bool
isVanillaAlgTyCon (AlgTyCon { algTcParent = VanillaAlgTyCon _ }) = True
isVanillaAlgTyCon _                                              = False

isDataTyCon :: TyCon -> Bool
-- ^ Returns @True@ for data types that are /definitely/ represented by
-- heap-allocated constructors.  These are scrutinised by Core-level
-- @case@ expressions, and they get info tables allocated for them.
--
-- Generally, the function will be true for all @data@ types and false
-- for @newtype@s, unboxed tuples and type family 'TyCon's. But it is
-- not guaranteed to return @True@ in all cases that it could.
--
-- NB: for a data type family, only the /instance/ 'TyCon's
--     get an info table.  The family declaration 'TyCon' does not
isDataTyCon (AlgTyCon {algTcRhs = rhs})
  = case rhs of
        TupleTyCon { tup_sort = sort }
                           -> isBoxed (tupleSortBoxity sort)
        DataTyCon {}       -> True
        NewTyCon {}        -> False
        AbstractTyCon {}   -> False      -- We don't know, so return False
isDataTyCon _ = False

-- | 'isInjectiveTyCon' is true of 'TyCon's for which this property holds
-- (where X is the role passed in):
--   If (T a1 b1 c1) ~X (T a2 b2 c2), then (a1 ~X1 a2), (b1 ~X2 b2), and (c1 ~X3 c2)
-- (where X1, X2, and X3, are the roles given by tyConRolesX tc X)
-- See also Note [Decomposing equalities] in TcCanonical
isInjectiveTyCon :: TyCon -> Role -> Bool
isInjectiveTyCon _                             Phantom          = False
isInjectiveTyCon (FunTyCon {})                 _                = True
isInjectiveTyCon (AlgTyCon {})                 Nominal          = True
isInjectiveTyCon (AlgTyCon {algTcRhs = rhs})   Representational
  = isGenInjAlgRhs rhs
isInjectiveTyCon (SynonymTyCon {})             _                = False
isInjectiveTyCon (FamilyTyCon { famTcFlav = DataFamilyTyCon _ })
                                               Nominal          = True
isInjectiveTyCon (FamilyTyCon { famTcInj = Injective inj }) _   = and inj
isInjectiveTyCon (FamilyTyCon {})              _                = False
isInjectiveTyCon (PrimTyCon {})                _                = True
isInjectiveTyCon (PromotedDataCon {})          _                = True
isInjectiveTyCon tc@(TcTyCon {})               _
  = pprPanic "isInjectiveTyCon sees a TcTyCon" (ppr tc)

-- | 'isGenerativeTyCon' is true of 'TyCon's for which this property holds
-- (where X is the role passed in):
--   If (T tys ~X t), then (t's head ~X T).
-- See also Note [Decomposing equalities] in TcCanonical
isGenerativeTyCon :: TyCon -> Role -> Bool
isGenerativeTyCon (FamilyTyCon { famTcFlav = DataFamilyTyCon _ }) Nominal = True
isGenerativeTyCon (FamilyTyCon {}) _ = False
  -- in all other cases, injectivity implies generativitiy
isGenerativeTyCon tc               r = isInjectiveTyCon tc r

-- | Is this an 'AlgTyConRhs' of a 'TyCon' that is generative and injective
-- with respect to representational equality?
isGenInjAlgRhs :: AlgTyConRhs -> Bool
isGenInjAlgRhs (TupleTyCon {})          = True
isGenInjAlgRhs (DataTyCon {})           = True
isGenInjAlgRhs (AbstractTyCon distinct) = distinct
isGenInjAlgRhs (NewTyCon {})            = False

-- | Is this 'TyCon' that for a @newtype@
isNewTyCon :: TyCon -> Bool
isNewTyCon (AlgTyCon {algTcRhs = NewTyCon {}}) = True
isNewTyCon _                                   = False

-- | Take a 'TyCon' apart into the 'TyVar's it scopes over, the 'Type' it expands
-- into, and (possibly) a coercion from the representation type to the @newtype@.
-- Returns @Nothing@ if this is not possible.
unwrapNewTyCon_maybe :: TyCon -> Maybe ([TyVar], Type, CoAxiom Unbranched)
unwrapNewTyCon_maybe (AlgTyCon { tyConTyVars = tvs,
                                 algTcRhs = NewTyCon { nt_co = co,
                                                       nt_rhs = rhs }})
                           = Just (tvs, rhs, co)
unwrapNewTyCon_maybe _     = Nothing

unwrapNewTyConEtad_maybe :: TyCon -> Maybe ([TyVar], Type, CoAxiom Unbranched)
unwrapNewTyConEtad_maybe (AlgTyCon { algTcRhs = NewTyCon { nt_co = co,
                                                           nt_etad_rhs = (tvs,rhs) }})
                           = Just (tvs, rhs, co)
unwrapNewTyConEtad_maybe _ = Nothing

isProductTyCon :: TyCon -> Bool
-- True of datatypes or newtypes that have
--   one, non-existential, data constructor
-- See Note [Product types]
isProductTyCon tc@(AlgTyCon {})
  = case algTcRhs tc of
      TupleTyCon {} -> True
      DataTyCon{ data_cons = [data_con] }
                    -> null (dataConExTyVars data_con)
      NewTyCon {}   -> True
      _             -> False
isProductTyCon _ = False

isDataProductTyCon_maybe :: TyCon -> Maybe DataCon
-- True of datatypes (not newtypes) with
--   one, vanilla, data constructor
-- See Note [Product types]
isDataProductTyCon_maybe (AlgTyCon { algTcRhs = rhs })
  = case rhs of
       DataTyCon { data_cons = [con] }
         | null (dataConExTyVars con)  -- non-existential
         -> Just con
       TupleTyCon { data_con = con }
         -> Just con
       _ -> Nothing
isDataProductTyCon_maybe _ = Nothing

{- Note [Product types]
~~~~~~~~~~~~~~~~~~~~~~~
A product type is
 * A data type (not a newtype)
 * With one, boxed data constructor
 * That binds no existential type variables

The main point is that product types are amenable to unboxing for
  * Strict function calls; we can transform
        f (D a b) = e
    to
        fw a b = e
    via the worker/wrapper transformation.  (Question: couldn't this
    work for existentials too?)

  * CPR for function results; we can transform
        f x y = let ... in D a b
    to
        fw x y = let ... in (# a, b #)

Note that the data constructor /can/ have evidence arguments: equality
constraints, type classes etc.  So it can be GADT.  These evidence
arguments are simply value arguments, and should not get in the way.
-}


-- | Is this a 'TyCon' representing a regular H98 type synonym (@type@)?
isTypeSynonymTyCon :: TyCon -> Bool
isTypeSynonymTyCon (SynonymTyCon {}) = True
isTypeSynonymTyCon _                 = False


-- As for newtypes, it is in some contexts important to distinguish between
-- closed synonyms and synonym families, as synonym families have no unique
-- right hand side to which a synonym family application can expand.
--

-- | True iff we can decompose (T a b c) into ((T a b) c)
--   I.e. is it injective and generative w.r.t nominal equality?
--   That is, if (T a b) ~N d e f, is it always the case that
--            (T ~N d), (a ~N e) and (b ~N f)?
-- Specifically NOT true of synonyms (open and otherwise)
--
-- It'd be unusual to call mightBeUnsaturatedTyCon on a regular H98
-- type synonym, because you should probably have expanded it first
-- But regardless, it's not decomposable
mightBeUnsaturatedTyCon :: TyCon -> Bool
mightBeUnsaturatedTyCon (SynonymTyCon {}) = False
mightBeUnsaturatedTyCon (FamilyTyCon  { famTcFlav = flav}) = isDataFamFlav flav
mightBeUnsaturatedTyCon (TcTyCon { tyConUnsat = unsat })   = unsat
mightBeUnsaturatedTyCon _other            = True

-- | Is this an algebraic 'TyCon' declared with the GADT syntax?
isGadtSyntaxTyCon :: TyCon -> Bool
isGadtSyntaxTyCon (AlgTyCon { algTcGadtSyntax = res }) = res
isGadtSyntaxTyCon _                                    = False

-- | Is this an algebraic 'TyCon' which is just an enumeration of values?
isEnumerationTyCon :: TyCon -> Bool
-- See Note [Enumeration types] in TyCon
isEnumerationTyCon (AlgTyCon { tyConArity = arity, algTcRhs = rhs })
  = case rhs of
       DataTyCon { is_enum = res } -> res
       TupleTyCon {}               -> arity == 0
       _                           -> False
isEnumerationTyCon _ = False

-- | Is this a 'TyCon', synonym or otherwise, that defines a family?
isFamilyTyCon :: TyCon -> Bool
isFamilyTyCon (FamilyTyCon {}) = True
isFamilyTyCon _                = False

-- | Is this a 'TyCon', synonym or otherwise, that defines a family with
-- instances?
isOpenFamilyTyCon :: TyCon -> Bool
isOpenFamilyTyCon (FamilyTyCon {famTcFlav = flav })
  | OpenSynFamilyTyCon <- flav = True
  | DataFamilyTyCon {} <- flav = True
isOpenFamilyTyCon _            = False

-- | Is this a synonym 'TyCon' that can have may have further instances appear?
isTypeFamilyTyCon :: TyCon -> Bool
isTypeFamilyTyCon (FamilyTyCon { famTcFlav = flav }) = not (isDataFamFlav flav)
isTypeFamilyTyCon _                                  = False

-- | Is this a synonym 'TyCon' that can have may have further instances appear?
isDataFamilyTyCon :: TyCon -> Bool
isDataFamilyTyCon (FamilyTyCon { famTcFlav = flav }) = isDataFamFlav flav
isDataFamilyTyCon _                                  = False

-- | Is this an open type family TyCon?
isOpenTypeFamilyTyCon :: TyCon -> Bool
isOpenTypeFamilyTyCon (FamilyTyCon {famTcFlav = OpenSynFamilyTyCon }) = True
isOpenTypeFamilyTyCon _                                               = False

-- | Is this a non-empty closed type family? Returns 'Nothing' for
-- abstract or empty closed families.
isClosedSynFamilyTyConWithAxiom_maybe :: TyCon -> Maybe (CoAxiom Branched)
isClosedSynFamilyTyConWithAxiom_maybe
  (FamilyTyCon {famTcFlav = ClosedSynFamilyTyCon mb}) = mb
isClosedSynFamilyTyConWithAxiom_maybe _               = Nothing

-- | Try to read the injectivity information from a FamilyTyCon.
-- For every other TyCon this function panics.
familyTyConInjectivityInfo :: TyCon -> Injectivity
familyTyConInjectivityInfo (FamilyTyCon { famTcInj = inj }) = inj
familyTyConInjectivityInfo _ = panic "familyTyConInjectivityInfo"

isBuiltInSynFamTyCon_maybe :: TyCon -> Maybe BuiltInSynFamily
isBuiltInSynFamTyCon_maybe
  (FamilyTyCon {famTcFlav = BuiltInSynFamTyCon ops }) = Just ops
isBuiltInSynFamTyCon_maybe _                          = Nothing

isDataFamFlav :: FamTyConFlav -> Bool
isDataFamFlav (DataFamilyTyCon {}) = True   -- Data family
isDataFamFlav _                    = False  -- Type synonym family

-- | Are we able to extract information 'TyVar' to class argument list
-- mapping from a given 'TyCon'?
isTyConAssoc :: TyCon -> Bool
isTyConAssoc tc = isJust (tyConAssoc_maybe tc)

tyConAssoc_maybe :: TyCon -> Maybe Class
tyConAssoc_maybe (FamilyTyCon { famTcParent = mb_cls }) = mb_cls
tyConAssoc_maybe _                                      = Nothing

-- The unit tycon didn't used to be classed as a tuple tycon
-- but I thought that was silly so I've undone it
-- If it can't be for some reason, it should be a AlgTyCon
isTupleTyCon :: TyCon -> Bool
-- ^ Does this 'TyCon' represent a tuple?
--
-- NB: when compiling @Data.Tuple@, the tycons won't reply @True@ to
-- 'isTupleTyCon', because they are built as 'AlgTyCons'.  However they
-- get spat into the interface file as tuple tycons, so I don't think
-- it matters.
isTupleTyCon (AlgTyCon { algTcRhs = TupleTyCon {} }) = True
isTupleTyCon _ = False

tyConTuple_maybe :: TyCon -> Maybe TupleSort
tyConTuple_maybe (AlgTyCon { algTcRhs = rhs })
  | TupleTyCon { tup_sort = sort} <- rhs = Just sort
tyConTuple_maybe _                       = Nothing

-- | Is this the 'TyCon' for an unboxed tuple?
isUnboxedTupleTyCon :: TyCon -> Bool
isUnboxedTupleTyCon (AlgTyCon { algTcRhs = rhs })
  | TupleTyCon { tup_sort = sort } <- rhs
  = not (isBoxed (tupleSortBoxity sort))
isUnboxedTupleTyCon _ = False

-- | Is this the 'TyCon' for a boxed tuple?
isBoxedTupleTyCon :: TyCon -> Bool
isBoxedTupleTyCon (AlgTyCon { algTcRhs = rhs })
  | TupleTyCon { tup_sort = sort } <- rhs
  = isBoxed (tupleSortBoxity sort)
isBoxedTupleTyCon _ = False

-- | Is this a recursive 'TyCon'?
isRecursiveTyCon :: TyCon -> Bool
isRecursiveTyCon (AlgTyCon {algTcRec = Recursive}) = True
isRecursiveTyCon _                                 = False

-- | Is this a PromotedDataCon?
isPromotedDataCon :: TyCon -> Bool
isPromotedDataCon (PromotedDataCon {}) = True
isPromotedDataCon _                    = False

-- | Retrieves the promoted DataCon if this is a PromotedDataCon;
isPromotedDataCon_maybe :: TyCon -> Maybe DataCon
isPromotedDataCon_maybe (PromotedDataCon { dataCon = dc }) = Just dc
isPromotedDataCon_maybe _ = Nothing

-- | Is this tycon really meant for use at the kind level? That is,
-- should it be permitted without -XDataKinds?
isKindTyCon :: TyCon -> Bool
isKindTyCon tc = getUnique tc `elementOfUniqSet` kindTyConKeys

-- | These TyCons should be allowed at the kind level, even without
-- -XDataKinds.
kindTyConKeys :: UniqSet Unique
kindTyConKeys = unionManyUniqSets
  ( mkUniqSet [ liftedTypeKindTyConKey, starKindTyConKey, unicodeStarKindTyConKey
              , constraintKindTyConKey, tYPETyConKey ]
  : map (mkUniqSet . tycon_with_datacons) [ runtimeRepTyCon
                                          , vecCountTyCon, vecElemTyCon ] )
  where
    tycon_with_datacons tc = getUnique tc : map getUnique (tyConDataCons tc)

isLiftedTypeKindTyConName :: Name -> Bool
isLiftedTypeKindTyConName
  = (`hasKey` liftedTypeKindTyConKey) <||>
    (`hasKey` starKindTyConKey) <||>
    (`hasKey` unicodeStarKindTyConKey)

-- | Identifies implicit tycons that, in particular, do not go into interface
-- files (because they are implicitly reconstructed when the interface is
-- read).
--
-- Note that:
--
-- * Associated families are implicit, as they are re-constructed from
--   the class declaration in which they reside, and
--
-- * Family instances are /not/ implicit as they represent the instance body
--   (similar to a @dfun@ does that for a class instance).
--
-- * Tuples are implicit iff they have a wired-in name
--   (namely: boxed and unboxed tupeles are wired-in and implicit,
--            but constraint tuples are not)
isImplicitTyCon :: TyCon -> Bool
isImplicitTyCon (FunTyCon {})        = True
isImplicitTyCon (PrimTyCon {})       = True
isImplicitTyCon (PromotedDataCon {}) = True
isImplicitTyCon (AlgTyCon { algTcRhs = rhs, tyConName = name })
  | TupleTyCon {} <- rhs             = isWiredInName name
  | otherwise                        = False
isImplicitTyCon (FamilyTyCon { famTcParent = parent }) = isJust parent
isImplicitTyCon (SynonymTyCon {})    = False
isImplicitTyCon tc@(TcTyCon {})
  = pprPanic "isImplicitTyCon sees a TcTyCon" (ppr tc)

tyConCType_maybe :: TyCon -> Maybe CType
tyConCType_maybe tc@(AlgTyCon {}) = tyConCType tc
tyConCType_maybe _ = Nothing

-- | Is this a TcTyCon? (That is, one only used during type-checking?)
isTcTyCon :: TyCon -> Bool
isTcTyCon (TcTyCon {}) = True
isTcTyCon _            = False

{-
-----------------------------------------------
--      Expand type-constructor applications
-----------------------------------------------
-}

expandSynTyCon_maybe
        :: TyCon
        -> [tyco]                 -- ^ Arguments to 'TyCon'
        -> Maybe ([(TyVar,tyco)],
                  Type,
                  [tyco])         -- ^ Returns a 'TyVar' substitution, the body
                                  -- type of the synonym (not yet substituted)
                                  -- and any arguments remaining from the
                                  -- application

-- ^ Expand a type synonym application, if any
expandSynTyCon_maybe tc tys
  | SynonymTyCon { tyConTyVars = tvs, synTcRhs = rhs } <- tc
  , let n_tvs = length tvs
  = case n_tvs `compare` length tys of
        LT -> Just (tvs `zip` tys, rhs, drop n_tvs tys)
        EQ -> Just (tvs `zip` tys, rhs, [])
        GT -> Nothing
   | otherwise
   = Nothing

----------------

-- | Check if the tycon actually refers to a proper `data` or `newtype`
--  with user defined constructors rather than one from a class or other
--  construction.
isTyConWithSrcDataCons :: TyCon -> Bool
isTyConWithSrcDataCons (AlgTyCon { algTcRhs = rhs, algTcParent = parent }) =
  case rhs of
    DataTyCon {}  -> isSrcParent
    NewTyCon {}   -> isSrcParent
    TupleTyCon {} -> isSrcParent
    _ -> False
  where
    isSrcParent = isNoParent parent
isTyConWithSrcDataCons _ = False


-- | As 'tyConDataCons_maybe', but returns the empty list of constructors if no
-- constructors could be found
tyConDataCons :: TyCon -> [DataCon]
-- It's convenient for tyConDataCons to return the
-- empty list for type synonyms etc
tyConDataCons tycon = tyConDataCons_maybe tycon `orElse` []

-- | Determine the 'DataCon's originating from the given 'TyCon', if the 'TyCon'
-- is the sort that can have any constructors (note: this does not include
-- abstract algebraic types)
tyConDataCons_maybe :: TyCon -> Maybe [DataCon]
tyConDataCons_maybe (AlgTyCon {algTcRhs = rhs})
  = case rhs of
       DataTyCon { data_cons = cons } -> Just cons
       NewTyCon { data_con = con }    -> Just [con]
       TupleTyCon { data_con = con }  -> Just [con]
       _                              -> Nothing
tyConDataCons_maybe _ = Nothing

-- | If the given 'TyCon' has a /single/ data constructor, i.e. it is a @data@
-- type with one alternative, a tuple type or a @newtype@ then that constructor
-- is returned. If the 'TyCon' has more than one constructor, or represents a
-- primitive or function type constructor then @Nothing@ is returned. In any
-- other case, the function panics
tyConSingleDataCon_maybe :: TyCon -> Maybe DataCon
tyConSingleDataCon_maybe (AlgTyCon { algTcRhs = rhs })
  = case rhs of
      DataTyCon { data_cons = [c] } -> Just c
      TupleTyCon { data_con = c }   -> Just c
      NewTyCon { data_con = c }     -> Just c
      _                             -> Nothing
tyConSingleDataCon_maybe _           = Nothing

tyConSingleDataCon :: TyCon -> DataCon
tyConSingleDataCon tc
  = case tyConSingleDataCon_maybe tc of
      Just c  -> c
      Nothing -> pprPanic "tyConDataCon" (ppr tc)

tyConSingleAlgDataCon_maybe :: TyCon -> Maybe DataCon
-- Returns (Just con) for single-constructor
-- *algebraic* data types *not* newtypes
tyConSingleAlgDataCon_maybe (AlgTyCon { algTcRhs = rhs })
  = case rhs of
      DataTyCon { data_cons = [c] } -> Just c
      TupleTyCon { data_con = c }   -> Just c
      _                             -> Nothing
tyConSingleAlgDataCon_maybe _        = Nothing

-- | Determine the number of value constructors a 'TyCon' has. Panics if the
-- 'TyCon' is not algebraic or a tuple
tyConFamilySize  :: TyCon -> Int
tyConFamilySize tc@(AlgTyCon { algTcRhs = rhs })
  = case rhs of
      DataTyCon { data_cons = cons } -> length cons
      NewTyCon {}                    -> 1
      TupleTyCon {}                  -> 1
      _                              -> pprPanic "tyConFamilySize 1" (ppr tc)
tyConFamilySize tc = pprPanic "tyConFamilySize 2" (ppr tc)

-- | Extract an 'AlgTyConRhs' with information about data constructors from an
-- algebraic or tuple 'TyCon'. Panics for any other sort of 'TyCon'
algTyConRhs :: TyCon -> AlgTyConRhs
algTyConRhs (AlgTyCon {algTcRhs = rhs}) = rhs
algTyConRhs other = pprPanic "algTyConRhs" (ppr other)

-- | Extract type variable naming the result of injective type family
tyConFamilyResVar_maybe :: TyCon -> Maybe Name
tyConFamilyResVar_maybe (FamilyTyCon {famTcResVar = res}) = res
tyConFamilyResVar_maybe _                                 = Nothing

-- | Get the list of roles for the type parameters of a TyCon
tyConRoles :: TyCon -> [Role]
-- See also Note [TyCon Role signatures]
tyConRoles tc
  = case tc of
    { FunTyCon {}                         -> const_role Representational
    ; AlgTyCon { tcRoles = roles }        -> roles
    ; SynonymTyCon { tcRoles = roles }    -> roles
    ; FamilyTyCon {}                      -> const_role Nominal
    ; PrimTyCon { tcRoles = roles }       -> roles
    ; PromotedDataCon { tcRoles = roles } -> roles
    ; TcTyCon {} -> pprPanic "tyConRoles sees a TcTyCon" (ppr tc)
    }
  where
    const_role r = replicate (tyConArity tc) r

-- | Extract the bound type variables and type expansion of a type synonym
-- 'TyCon'. Panics if the 'TyCon' is not a synonym
newTyConRhs :: TyCon -> ([TyVar], Type)
newTyConRhs (AlgTyCon {tyConTyVars = tvs, algTcRhs = NewTyCon { nt_rhs = rhs }})
    = (tvs, rhs)
newTyConRhs tycon = pprPanic "newTyConRhs" (ppr tycon)

-- | The number of type parameters that need to be passed to a newtype to
-- resolve it. May be less than in the definition if it can be eta-contracted.
newTyConEtadArity :: TyCon -> Int
newTyConEtadArity (AlgTyCon {algTcRhs = NewTyCon { nt_etad_rhs = tvs_rhs }})
        = length (fst tvs_rhs)
newTyConEtadArity tycon = pprPanic "newTyConEtadArity" (ppr tycon)

-- | Extract the bound type variables and type expansion of an eta-contracted
-- type synonym 'TyCon'.  Panics if the 'TyCon' is not a synonym
newTyConEtadRhs :: TyCon -> ([TyVar], Type)
newTyConEtadRhs (AlgTyCon {algTcRhs = NewTyCon { nt_etad_rhs = tvs_rhs }}) = tvs_rhs
newTyConEtadRhs tycon = pprPanic "newTyConEtadRhs" (ppr tycon)

-- | Extracts the @newtype@ coercion from such a 'TyCon', which can be used to
-- construct something with the @newtype@s type from its representation type
-- (right hand side). If the supplied 'TyCon' is not a @newtype@, returns
-- @Nothing@
newTyConCo_maybe :: TyCon -> Maybe (CoAxiom Unbranched)
newTyConCo_maybe (AlgTyCon {algTcRhs = NewTyCon { nt_co = co }}) = Just co
newTyConCo_maybe _                                               = Nothing

newTyConCo :: TyCon -> CoAxiom Unbranched
newTyConCo tc = case newTyConCo_maybe tc of
                 Just co -> co
                 Nothing -> pprPanic "newTyConCo" (ppr tc)

-- | Find the \"stupid theta\" of the 'TyCon'. A \"stupid theta\" is the context
-- to the left of an algebraic type declaration, e.g. @Eq a@ in the declaration
-- @data Eq a => T a ...@
tyConStupidTheta :: TyCon -> [PredType]
tyConStupidTheta (AlgTyCon {algTcStupidTheta = stupid}) = stupid
tyConStupidTheta tycon = pprPanic "tyConStupidTheta" (ppr tycon)

-- | Extract the 'TyVar's bound by a vanilla type synonym
-- and the corresponding (unsubstituted) right hand side.
synTyConDefn_maybe :: TyCon -> Maybe ([TyVar], Type)
synTyConDefn_maybe (SynonymTyCon {tyConTyVars = tyvars, synTcRhs = ty})
  = Just (tyvars, ty)
synTyConDefn_maybe _ = Nothing

-- | Extract the information pertaining to the right hand side of a type synonym
-- (@type@) declaration.
synTyConRhs_maybe :: TyCon -> Maybe Type
synTyConRhs_maybe (SynonymTyCon {synTcRhs = rhs}) = Just rhs
synTyConRhs_maybe _                               = Nothing

-- | Extract the flavour of a type family (with all the extra information that
-- it carries)
famTyConFlav_maybe :: TyCon -> Maybe FamTyConFlav
famTyConFlav_maybe (FamilyTyCon {famTcFlav = flav}) = Just flav
famTyConFlav_maybe _                                = Nothing

-- | Is this 'TyCon' that for a class instance?
isClassTyCon :: TyCon -> Bool
isClassTyCon (AlgTyCon {algTcParent = ClassTyCon {}}) = True
isClassTyCon _                                        = False

-- | If this 'TyCon' is that for a class instance, return the class it is for.
-- Otherwise returns @Nothing@
tyConClass_maybe :: TyCon -> Maybe Class
tyConClass_maybe (AlgTyCon {algTcParent = ClassTyCon clas _}) = Just clas
tyConClass_maybe _                                            = Nothing

-- | Return the associated types of the 'TyCon', if any
tyConATs :: TyCon -> [TyCon]
tyConATs (AlgTyCon {algTcParent = ClassTyCon clas _}) = classATs clas
tyConATs _                                            = []

----------------------------------------------------------------------------
-- | Is this 'TyCon' that for a data family instance?
isFamInstTyCon :: TyCon -> Bool
isFamInstTyCon (AlgTyCon {algTcParent = DataFamInstTyCon {} })
  = True
isFamInstTyCon _ = False

tyConFamInstSig_maybe :: TyCon -> Maybe (TyCon, [Type], CoAxiom Unbranched)
tyConFamInstSig_maybe (AlgTyCon {algTcParent = DataFamInstTyCon ax f ts })
  = Just (f, ts, ax)
tyConFamInstSig_maybe _ = Nothing

-- | If this 'TyCon' is that of a data family instance, return the family in question
-- and the instance types. Otherwise, return @Nothing@
tyConFamInst_maybe :: TyCon -> Maybe (TyCon, [Type])
tyConFamInst_maybe (AlgTyCon {algTcParent = DataFamInstTyCon _ f ts })
  = Just (f, ts)
tyConFamInst_maybe _ = Nothing

-- | If this 'TyCon' is that of a data family instance, return a 'TyCon' which
-- represents a coercion identifying the representation type with the type
-- instance family.  Otherwise, return @Nothing@
tyConFamilyCoercion_maybe :: TyCon -> Maybe (CoAxiom Unbranched)
tyConFamilyCoercion_maybe (AlgTyCon {algTcParent = DataFamInstTyCon ax _ _ })
  = Just ax
tyConFamilyCoercion_maybe _ = Nothing

-- | Extract any 'RuntimeRepInfo' from this TyCon
tyConRuntimeRepInfo :: TyCon -> RuntimeRepInfo
tyConRuntimeRepInfo (PromotedDataCon { promDcRepInfo = rri }) = rri
tyConRuntimeRepInfo _                                         = NoRRI
  -- could panic in that second case. But Douglas Adams told me not to.

{-
************************************************************************
*                                                                      *
\subsection[TyCon-instances]{Instance declarations for @TyCon@}
*                                                                      *
************************************************************************

@TyCon@s are compared by comparing their @Unique@s.
-}

instance Eq TyCon where
    a == b = case (a `compare` b) of { EQ -> True;   _ -> False }
    a /= b = case (a `compare` b) of { EQ -> False;  _ -> True  }

instance Ord TyCon where
    a <= b = case (a `compare` b) of { LT -> True;  EQ -> True;  GT -> False }
    a <  b = case (a `compare` b) of { LT -> True;  EQ -> False; GT -> False }
    a >= b = case (a `compare` b) of { LT -> False; EQ -> True;  GT -> True  }
    a >  b = case (a `compare` b) of { LT -> False; EQ -> False; GT -> True  }
    compare a b = getUnique a `compare` getUnique b

instance Uniquable TyCon where
    getUnique tc = tyConUnique tc

instance Outputable TyCon where
  -- At the moment a promoted TyCon has the same Name as its
  -- corresponding TyCon, so we add the quote to distinguish it here
  ppr tc = pprPromotionQuote tc <> ppr (tyConName tc)

tyConFlavour :: TyCon -> String
tyConFlavour (AlgTyCon { algTcParent = parent, algTcRhs = rhs })
  | ClassTyCon _ _ <- parent = "class"
  | otherwise = case rhs of
                  TupleTyCon { tup_sort = sort }
                     | isBoxed (tupleSortBoxity sort) -> "tuple"
                     | otherwise                      -> "unboxed tuple"
                  DataTyCon {}       -> "data type"
                  NewTyCon {}        -> "newtype"
                  AbstractTyCon {}   -> "abstract type"
tyConFlavour (FamilyTyCon { famTcFlav = flav })
  | isDataFamFlav flav            = "data family"
  | otherwise                     = "type family"
tyConFlavour (SynonymTyCon {})    = "type synonym"
tyConFlavour (FunTyCon {})        = "built-in type"
tyConFlavour (PrimTyCon {})       = "built-in type"
tyConFlavour (PromotedDataCon {}) = "promoted data constructor"
tyConFlavour tc@(TcTyCon {})
  = pprPanic "tyConFlavour sees a TcTyCon" (ppr tc)

pprPromotionQuote :: TyCon -> SDoc
-- Promoted data constructors already have a tick in their OccName
pprPromotionQuote tc
  = case tc of
      PromotedDataCon {} -> char '\'' -- Always quote promoted DataCons in types
      _                  -> empty

instance NamedThing TyCon where
    getName = tyConName

instance Data.Data TyCon where
    -- don't traverse?
    toConstr _   = abstractConstr "TyCon"
    gunfold _ _  = error "gunfold"
    dataTypeOf _ = mkNoRepType "TyCon"

instance Binary Injectivity where
    put_ bh NotInjective   = putByte bh 0
    put_ bh (Injective xs) = putByte bh 1 >> put_ bh xs

    get bh = do { h <- getByte bh
                ; case h of
                    0 -> return NotInjective
                    _ -> do { xs <- get bh
                            ; return (Injective xs) } }

{-
************************************************************************
*                                                                      *
           Walking over recursive TyCons
*                                                                      *
************************************************************************

Note [Expanding newtypes and products]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When expanding a type to expose a data-type constructor, we need to be
careful about newtypes, lest we fall into an infinite loop. Here are
the key examples:

  newtype Id  x = MkId x
  newtype Fix f = MkFix (f (Fix f))
  newtype T     = MkT (T -> T)

  Type           Expansion
 --------------------------
  T              T -> T
  Fix Maybe      Maybe (Fix Maybe)
  Id (Id Int)    Int
  Fix Id         NO NO NO

Notice that
 * We can expand T, even though it's recursive.
 * We can expand Id (Id Int), even though the Id shows up
   twice at the outer level, because Id is non-recursive

So, when expanding, we keep track of when we've seen a recursive
newtype at outermost level; and bale out if we see it again.

We sometimes want to do the same for product types, so that the
strictness analyser doesn't unbox infinitely deeply.

More precisely, we keep a *count* of how many times we've seen it.
This is to account for
   data instance T (a,b) = MkT (T a) (T b)
Then (Trac #10482) if we have a type like
        T (Int,(Int,(Int,(Int,Int))))
we can still unbox deeply enough during strictness analysis.
We have to treat T as potentially recursive, but it's still
good to be able to unwrap multiple layers.

The function that manages all this is checkRecTc.
-}

data RecTcChecker = RC !Int (NameEnv Int)
  -- The upper bound, and the number of times
  -- we have encountered each TyCon

initRecTc :: RecTcChecker
-- Intialise with a fixed max bound of 100
-- We should probably have a flag for this
initRecTc = RC 100 emptyNameEnv

checkRecTc :: RecTcChecker -> TyCon -> Maybe RecTcChecker
-- Nothing      => Recursion detected
-- Just rec_tcs => Keep going
checkRecTc rc@(RC bound rec_nts) tc
  | not (isRecursiveTyCon tc)
  = Just rc  -- Tuples are a common example here
  | otherwise
  = case lookupNameEnv rec_nts tc_name of
      Just n | n >= bound -> Nothing
             | otherwise  -> Just (RC bound (extendNameEnv rec_nts tc_name (n+1)))
      Nothing             -> Just (RC bound (extendNameEnv rec_nts tc_name 1))
  where
    tc_name = tyConName tc
