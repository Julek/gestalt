{-
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[StgSyn]{Shared term graph (STG) syntax for spineless-tagless code generation}

This data type represents programs just before code generation (conversion to
@Cmm@): basically, what we have is a stylised form of @CoreSyntax@, the style
being one that happens to be ideally suited to spineless tagless code
generation.
-}

{-# LANGUAGE CPP #-}

module StgSyn (
        GenStgArg(..),
        GenStgLiveVars,

        GenStgBinding(..), GenStgExpr(..), GenStgRhs(..),
        GenStgAlt, AltType(..),

        UpdateFlag(..), isUpdatable,

        StgBinderInfo,
        noBinderInfo, stgSatOcc, stgUnsatOcc, satCallsOnly,
        combineStgBinderInfo,

        -- a set of synonyms for the most common (only :-) parameterisation
        StgArg, StgLiveVars,
        StgBinding, StgExpr, StgRhs, StgAlt,

        -- StgOp
        StgOp(..),

        -- SRTs
        SRT(..),

        -- utils
        stgBindHasCafRefs, stgArgHasCafRefs, stgRhsArity,
        isDllConApp,
        stgArgType,
        stripStgTicksTop,

        pprStgBinding, pprStgBindings,
        pprStgLVs
    ) where

#include "HsVersions.h"

import CoreSyn     ( AltCon, Tickish )
import CostCentre  ( CostCentreStack )
import Data.List   ( intersperse )
import DataCon
import DynFlags
import FastString
import ForeignCall ( ForeignCall )
import Id
import IdInfo      ( mayHaveCafRefs )
import Literal     ( Literal, literalType )
import Module      ( Module )
import Outputable
import Packages    ( isDllName )
import Platform
import PprCore     ( {- instances -} )
import PrimOp      ( PrimOp, PrimCall )
import TyCon       ( PrimRep(..) )
import TyCon       ( TyCon )
import Type        ( Type )
import Type        ( typePrimRep )
import UniqSet
import Unique      ( Unique )
import Util
import VarSet      ( IdSet, isEmptyVarSet )

{-
************************************************************************
*                                                                      *
\subsection{@GenStgBinding@}
*                                                                      *
************************************************************************

As usual, expressions are interesting; other things are boring. Here
are the boring things [except note the @GenStgRhs@], parameterised
with respect to binder and occurrence information (just as in
@CoreSyn@):

There is one SRT for each group of bindings.
-}

data GenStgBinding bndr occ
  = StgNonRec bndr (GenStgRhs bndr occ)
  | StgRec    [(bndr, GenStgRhs bndr occ)]

{-
************************************************************************
*                                                                      *
\subsection{@GenStgArg@}
*                                                                      *
************************************************************************
-}

data GenStgArg occ
  = StgVarArg  occ
  | StgLitArg  Literal

-- | Does this constructor application refer to
-- anything in a different *Windows* DLL?
-- If so, we can't allocate it statically
isDllConApp :: DynFlags -> Module -> DataCon -> [StgArg] -> Bool
isDllConApp dflags this_mod con args
 | platformOS (targetPlatform dflags) == OSMinGW32
    = isDllName dflags this_pkg this_mod (dataConName con) || any is_dll_arg args
 | otherwise = False
  where
    -- NB: typePrimRep is legit because any free variables won't have
    -- unlifted type (there are no unlifted things at top level)
    is_dll_arg :: StgArg -> Bool
    is_dll_arg (StgVarArg v) =  isAddrRep (typePrimRep (idType v))
                             && isDllName dflags this_pkg this_mod (idName v)
    is_dll_arg _             = False

    this_pkg = thisPackage dflags

-- True of machine addresses; these are the things that don't
-- work across DLLs. The key point here is that VoidRep comes
-- out False, so that a top level nullary GADT constructor is
-- False for isDllConApp
--    data T a where
--      T1 :: T Int
-- gives
--    T1 :: forall a. (a~Int) -> T a
-- and hence the top-level binding
--    $WT1 :: T Int
--    $WT1 = T1 Int (Coercion (Refl Int))
-- The coercion argument here gets VoidRep
isAddrRep :: PrimRep -> Bool
isAddrRep AddrRep = True
isAddrRep PtrRep  = True
isAddrRep _       = False

-- | Type of an @StgArg@
--
-- Very half baked becase we have lost the type arguments.
stgArgType :: StgArg -> Type
stgArgType (StgVarArg v)   = idType v
stgArgType (StgLitArg lit) = literalType lit


-- | Strip ticks of a given type from an STG expression
stripStgTicksTop :: (Tickish Id -> Bool) -> StgExpr -> ([Tickish Id], StgExpr)
stripStgTicksTop p = go []
   where go ts (StgTick t e) | p t = go (t:ts) e
         go ts other               = (reverse ts, other)


{-
************************************************************************
*                                                                      *
\subsection{STG expressions}
*                                                                      *
************************************************************************

The @GenStgExpr@ data type is parameterised on binder and occurrence
info, as before.

************************************************************************
*                                                                      *
\subsubsection{@GenStgExpr@ application}
*                                                                      *
************************************************************************

An application is of a function to a list of atoms [not expressions].
Operationally, we want to push the arguments on the stack and call the
function. (If the arguments were expressions, we would have to build
their closures first.)

There is no constructor for a lone variable; it would appear as
@StgApp var []@.
-}

type GenStgLiveVars occ = UniqSet occ

data GenStgExpr bndr occ
  = StgApp
        occ             -- function
        [GenStgArg occ] -- arguments; may be empty

{-
************************************************************************
*                                                                      *
\subsubsection{@StgConApp@ and @StgPrimApp@---saturated applications}
*                                                                      *
************************************************************************

There are specialised forms of application, for constructors,
primitives, and literals.
-}

  | StgLit      Literal

        -- StgConApp is vital for returning unboxed tuples
        -- which can't be let-bound first
  | StgConApp   DataCon
                [GenStgArg occ] -- Saturated

  | StgOpApp    StgOp           -- Primitive op or foreign call
                [GenStgArg occ] -- Saturated
                Type            -- Result type
                                -- We need to know this so that we can
                                -- assign result registers

{-
************************************************************************
*                                                                      *
\subsubsection{@StgLam@}
*                                                                      *
************************************************************************

StgLam is used *only* during CoreToStg's work. Before CoreToStg has
finished it encodes (\x -> e) as (let f = \x -> e in f)
-}

  | StgLam
        [bndr]
        StgExpr    -- Body of lambda

{-
************************************************************************
*                                                                      *
\subsubsection{@GenStgExpr@: case-expressions}
*                                                                      *
************************************************************************

This has the same boxed/unboxed business as Core case expressions.
-}

  | StgCase
        (GenStgExpr bndr occ)
                    -- the thing to examine

        (GenStgLiveVars occ)
                    -- Live vars of whole case expression,
                    -- plus everything that happens after the case
                    -- i.e., those which mustn't be overwritten

        (GenStgLiveVars occ)
                    -- Live vars of RHSs (plus what happens afterwards)
                    -- i.e., those which must be saved before eval.
                    --
                    -- note that an alt's constructor's
                    -- binder-variables are NOT counted in the
                    -- free vars for the alt's RHS

        bndr        -- binds the result of evaluating the scrutinee

        SRT         -- The SRT for the continuation

        AltType

        [GenStgAlt bndr occ]
                    -- The DEFAULT case is always *first*
                    -- if it is there at all

{-
************************************************************************
*                                                                      *
\subsubsection{@GenStgExpr@: @let(rec)@-expressions}
*                                                                      *
************************************************************************

The various forms of let(rec)-expression encode most of the
interesting things we want to do.
\begin{enumerate}
\item
\begin{verbatim}
let-closure x = [free-vars] [args] expr
in e
\end{verbatim}
is equivalent to
\begin{verbatim}
let x = (\free-vars -> \args -> expr) free-vars
\end{verbatim}
\tr{args} may be empty (and is for most closures).  It isn't under
circumstances like this:
\begin{verbatim}
let x = (\y -> y+z)
\end{verbatim}
This gets mangled to
\begin{verbatim}
let-closure x = [z] [y] (y+z)
\end{verbatim}
The idea is that we compile code for @(y+z)@ in an environment in which
@z@ is bound to an offset from \tr{Node}, and @y@ is bound to an
offset from the stack pointer.

(A let-closure is an @StgLet@ with a @StgRhsClosure@ RHS.)

\item
\begin{verbatim}
let-constructor x = Constructor [args]
in e
\end{verbatim}

(A let-constructor is an @StgLet@ with a @StgRhsCon@ RHS.)

\item
Letrec-expressions are essentially the same deal as
let-closure/let-constructor, so we use a common structure and
distinguish between them with an @is_recursive@ boolean flag.

\item
\begin{verbatim}
let-unboxed u = an arbitrary arithmetic expression in unboxed values
in e
\end{verbatim}
All the stuff on the RHS must be fully evaluated.
No function calls either!

(We've backed away from this toward case-expressions with
suitably-magical alts ...)

\item
~[Advanced stuff here! Not to start with, but makes pattern matching
generate more efficient code.]

\begin{verbatim}
let-escapes-not fail = expr
in e'
\end{verbatim}
Here the idea is that @e'@ guarantees not to put @fail@ in a data structure,
or pass it to another function. All @e'@ will ever do is tail-call @fail@.
Rather than build a closure for @fail@, all we need do is to record the stack
level at the moment of the @let-escapes-not@; then entering @fail@ is just
a matter of adjusting the stack pointer back down to that point and entering
the code for it.

Another example:
\begin{verbatim}
f x y = let z = huge-expression in
        if y==1 then z else
        if y==2 then z else
        1
\end{verbatim}

(A let-escapes-not is an @StgLetNoEscape@.)

\item
We may eventually want:
\begin{verbatim}
let-literal x = Literal
in e
\end{verbatim}
\end{enumerate}

And so the code for let(rec)-things:
-}

  | StgLet
        (GenStgBinding bndr occ)    -- right hand sides (see below)
        (GenStgExpr bndr occ)       -- body

  | StgLetNoEscape                  -- remember: ``advanced stuff''
        (GenStgLiveVars occ)        -- Live in the whole let-expression
                                    -- Mustn't overwrite these stack slots
                                    -- _Doesn't_ include binders of the let(rec).

        (GenStgLiveVars occ)        -- Live in the right hand sides (only)
                                    -- These are the ones which must be saved on
                                    -- the stack if they aren't there already
                                    -- _Does_ include binders of the let(rec) if recursive.

        (GenStgBinding bndr occ)    -- right hand sides (see below)
        (GenStgExpr bndr occ)       -- body

{-
%************************************************************************
%*                                                                      *
\subsubsection{@GenStgExpr@: @hpc@, @scc@ and other debug annotations}
%*                                                                      *
%************************************************************************

Finally for @hpc@ expressions we introduce a new STG construct.
-}

  | StgTick
    (Tickish bndr)
    (GenStgExpr bndr occ)       -- sub expression

-- END of GenStgExpr

{-
************************************************************************
*                                                                      *
\subsection{STG right-hand sides}
*                                                                      *
************************************************************************

Here's the rest of the interesting stuff for @StgLet@s; the first
flavour is for closures:
-}

data GenStgRhs bndr occ
  = StgRhsClosure
        CostCentreStack         -- CCS to be attached (default is CurrentCCS)
        StgBinderInfo           -- Info about how this binder is used (see below)
        [occ]                   -- non-global free vars; a list, rather than
                                -- a set, because order is important
        !UpdateFlag             -- ReEntrant | Updatable | SingleEntry
        SRT                     -- The SRT reference
        [bndr]                  -- arguments; if empty, then not a function;
                                -- as above, order is important.
        (GenStgExpr bndr occ)   -- body

{-
An example may be in order.  Consider:
\begin{verbatim}
let t = \x -> \y -> ... x ... y ... p ... q in e
\end{verbatim}
Pulling out the free vars and stylising somewhat, we get the equivalent:
\begin{verbatim}
let t = (\[p,q] -> \[x,y] -> ... x ... y ... p ...q) p q
\end{verbatim}
Stg-operationally, the @[x,y]@ are on the stack, the @[p,q]@ are
offsets from @Node@ into the closure, and the code ptr for the closure
will be exactly that in parentheses above.

The second flavour of right-hand-side is for constructors (simple but important):
-}

  | StgRhsCon
        CostCentreStack  -- CCS to be attached (default is CurrentCCS).
                         -- Top-level (static) ones will end up with
                         -- DontCareCCS, because we don't count static
                         -- data in heap profiles, and we don't set CCCS
                         -- from static closure.
        DataCon          -- constructor
        [GenStgArg occ]  -- args

stgRhsArity :: StgRhs -> Int
stgRhsArity (StgRhsClosure _ _ _ _ _ bndrs _)
  = ASSERT( all isId bndrs ) length bndrs
  -- The arity never includes type parameters, but they should have gone by now
stgRhsArity (StgRhsCon _ _ _) = 0

stgBindHasCafRefs :: GenStgBinding bndr Id -> Bool
stgBindHasCafRefs (StgNonRec _ rhs) = rhsHasCafRefs rhs
stgBindHasCafRefs (StgRec binds)    = any rhsHasCafRefs (map snd binds)

rhsHasCafRefs :: GenStgRhs bndr Id -> Bool
rhsHasCafRefs (StgRhsClosure _ _ _ upd srt _ _)
  = isUpdatable upd || nonEmptySRT srt
rhsHasCafRefs (StgRhsCon _ _ args)
  = any stgArgHasCafRefs args

stgArgHasCafRefs :: GenStgArg Id -> Bool
stgArgHasCafRefs (StgVarArg id) = mayHaveCafRefs (idCafInfo id)
stgArgHasCafRefs _ = False

-- Here's the @StgBinderInfo@ type, and its combining op:

data StgBinderInfo
  = NoStgBinderInfo
  | SatCallsOnly        -- All occurrences are *saturated* *function* calls
                        -- This means we don't need to build an info table and
                        -- slow entry code for the thing
                        -- Thunks never get this value

noBinderInfo, stgUnsatOcc, stgSatOcc :: StgBinderInfo
noBinderInfo = NoStgBinderInfo
stgUnsatOcc  = NoStgBinderInfo
stgSatOcc    = SatCallsOnly

satCallsOnly :: StgBinderInfo -> Bool
satCallsOnly SatCallsOnly    = True
satCallsOnly NoStgBinderInfo = False

combineStgBinderInfo :: StgBinderInfo -> StgBinderInfo -> StgBinderInfo
combineStgBinderInfo SatCallsOnly SatCallsOnly = SatCallsOnly
combineStgBinderInfo _            _            = NoStgBinderInfo

--------------
pp_binder_info :: StgBinderInfo -> SDoc
pp_binder_info NoStgBinderInfo = empty
pp_binder_info SatCallsOnly    = text "sat-only"

{-
************************************************************************
*                                                                      *
\subsection[Stg-case-alternatives]{STG case alternatives}
*                                                                      *
************************************************************************

Very like in @CoreSyntax@ (except no type-world stuff).

The type constructor is guaranteed not to be abstract; that is, we can
see its representation. This is important because the code generator
uses it to determine return conventions etc. But it's not trivial
where there's a moduule loop involved, because some versions of a type
constructor might not have all the constructors visible. So
mkStgAlgAlts (in CoreToStg) ensures that it gets the TyCon from the
constructors or literals (which are guaranteed to have the Real McCoy)
rather than from the scrutinee type.
-}

type GenStgAlt bndr occ
  = (AltCon,            -- alts: data constructor,
     [bndr],            -- constructor's parameters,
     [Bool],            -- "use mask", same length as
                        -- parameters; a True in a
                        -- param's position if it is
                        -- used in the ...
     GenStgExpr bndr occ)       -- ...right-hand side.

data AltType
  = PolyAlt             -- Polymorphic (a type variable)
  | UbxTupAlt Int       -- Unboxed tuple of this arity
  | AlgAlt    TyCon     -- Algebraic data type; the AltCons will be DataAlts
  | PrimAlt   TyCon     -- Primitive data type; the AltCons will be LitAlts

{-
************************************************************************
*                                                                      *
\subsection[Stg]{The Plain STG parameterisation}
*                                                                      *
************************************************************************

This happens to be the only one we use at the moment.
-}

type StgBinding  = GenStgBinding  Id Id
type StgArg      = GenStgArg      Id
type StgLiveVars = GenStgLiveVars Id
type StgExpr     = GenStgExpr     Id Id
type StgRhs      = GenStgRhs      Id Id
type StgAlt      = GenStgAlt      Id Id

{-
************************************************************************
*                                                                      *
\subsubsection[UpdateFlag-datatype]{@UpdateFlag@}
*                                                                      *
************************************************************************

This is also used in @LambdaFormInfo@ in the @ClosureInfo@ module.

A @ReEntrant@ closure may be entered multiple times, but should not be
updated or blackholed. An @Updatable@ closure should be updated after
evaluation (and may be blackholed during evaluation). A @SingleEntry@
closure will only be entered once, and so need not be updated but may
safely be blackholed.
-}

data UpdateFlag = ReEntrant | Updatable | SingleEntry

instance Outputable UpdateFlag where
    ppr u = char $ case u of
                       ReEntrant   -> 'r'
                       Updatable   -> 'u'
                       SingleEntry -> 's'

isUpdatable :: UpdateFlag -> Bool
isUpdatable ReEntrant   = False
isUpdatable SingleEntry = False
isUpdatable Updatable   = True

{-
************************************************************************
*                                                                      *
\subsubsection{StgOp}
*                                                                      *
************************************************************************

An StgOp allows us to group together PrimOps and ForeignCalls.
It's quite useful to move these around together, notably
in StgOpApp and COpStmt.
-}

data StgOp
  = StgPrimOp  PrimOp

  | StgPrimCallOp PrimCall

  | StgFCallOp ForeignCall Unique
        -- The Unique is occasionally needed by the C pretty-printer
        -- (which lacks a unique supply), notably when generating a
        -- typedef for foreign-export-dynamic

{-
************************************************************************
*                                                                      *
\subsubsection[Static Reference Tables]{@SRT@}
*                                                                      *
************************************************************************

There is one SRT per top-level function group. Each local binding and
case expression within this binding group has a subrange of the whole
SRT, expressed as an offset and length.

In CoreToStg we collect the list of CafRefs at each SRT site, which is later
converted into the length and offset form by the SRT pass.
-}

data SRT
  = NoSRT
  | SRTEntries IdSet
        -- generated by CoreToStg

nonEmptySRT :: SRT -> Bool
nonEmptySRT NoSRT           = False
nonEmptySRT (SRTEntries vs) = not (isEmptyVarSet vs)

pprSRT :: SRT -> SDoc
pprSRT (NoSRT)          = text "_no_srt_"
pprSRT (SRTEntries ids) = text "SRT:" <> ppr ids

{-
************************************************************************
*                                                                      *
\subsection[Stg-pretty-printing]{Pretty-printing}
*                                                                      *
************************************************************************

Robin Popplestone asked for semi-colon separators on STG binds; here's
hoping he likes terminators instead...  Ditto for case alternatives.
-}

pprGenStgBinding :: (OutputableBndr bndr, Outputable bdee, Ord bdee)
                 => GenStgBinding bndr bdee -> SDoc

pprGenStgBinding (StgNonRec bndr rhs)
  = hang (hsep [pprBndr LetBind bndr, equals])
        4 (ppr rhs <> semi)

pprGenStgBinding (StgRec pairs)
  = vcat $ ifPprDebug (text "{- StgRec (begin) -}") :
           map (ppr_bind) pairs ++ [ifPprDebug (text "{- StgRec (end) -}")]
  where
    ppr_bind (bndr, expr)
      = hang (hsep [pprBndr LetBind bndr, equals])
             4 (ppr expr <> semi)

pprStgBinding :: StgBinding -> SDoc
pprStgBinding  bind  = pprGenStgBinding bind

pprStgBindings :: [StgBinding] -> SDoc
pprStgBindings binds = vcat $ intersperse blankLine (map pprGenStgBinding binds)

instance (Outputable bdee) => Outputable (GenStgArg bdee) where
    ppr = pprStgArg

instance (OutputableBndr bndr, Outputable bdee, Ord bdee)
                => Outputable (GenStgBinding bndr bdee) where
    ppr = pprGenStgBinding

instance (OutputableBndr bndr, Outputable bdee, Ord bdee)
                => Outputable (GenStgExpr bndr bdee) where
    ppr = pprStgExpr

instance (OutputableBndr bndr, Outputable bdee, Ord bdee)
                => Outputable (GenStgRhs bndr bdee) where
    ppr rhs = pprStgRhs rhs

pprStgArg :: (Outputable bdee) => GenStgArg bdee -> SDoc
pprStgArg (StgVarArg var) = ppr var
pprStgArg (StgLitArg con) = ppr con

pprStgExpr :: (OutputableBndr bndr, Outputable bdee, Ord bdee)
           => GenStgExpr bndr bdee -> SDoc
-- special case
pprStgExpr (StgLit lit)     = ppr lit

-- general case
pprStgExpr (StgApp func args)
  = hang (ppr func) 4 (sep (map (ppr) args))

pprStgExpr (StgConApp con args)
  = hsep [ ppr con, brackets (interppSP args)]

pprStgExpr (StgOpApp op args _)
  = hsep [ pprStgOp op, brackets (interppSP args)]

pprStgExpr (StgLam bndrs body)
  = sep [ char '\\' <+> ppr_list (map (pprBndr LambdaBind) bndrs)
            <+> text "->",
         pprStgExpr body ]
  where ppr_list = brackets . fsep . punctuate comma

-- special case: let v = <very specific thing>
--               in
--               let ...
--               in
--               ...
--
-- Very special!  Suspicious! (SLPJ)

{-
pprStgExpr (StgLet srt (StgNonRec bndr (StgRhsClosure cc bi free_vars upd_flag args rhs))
                        expr@(StgLet _ _))
  = ($$)
      (hang (hcat [text "let { ", ppr bndr, ptext (sLit " = "),
                          ppr cc,
                          pp_binder_info bi,
                          text " [", ifPprDebug (interppSP free_vars), ptext (sLit "] \\"),
                          ppr upd_flag, text " [",
                          interppSP args, char ']'])
            8 (sep [hsep [ppr rhs, text "} in"]]))
      (ppr expr)
-}

-- special case: let ... in let ...

pprStgExpr (StgLet bind expr@(StgLet _ _))
  = ($$)
      (sep [hang (text "let {")
                2 (hsep [pprGenStgBinding bind, text "} in"])])
      (ppr expr)

-- general case
pprStgExpr (StgLet bind expr)
  = sep [hang (text "let {") 2 (pprGenStgBinding bind),
           hang (text "} in ") 2 (ppr expr)]

pprStgExpr (StgLetNoEscape lvs_whole lvs_rhss bind expr)
  = sep [hang (text "let-no-escape {")
                2 (pprGenStgBinding bind),
           hang (text "} in " <>
                   ifPprDebug (
                    nest 4 (
                      hcat [ptext  (sLit "-- lvs: ["), interppSP (uniqSetToList lvs_whole),
                             text "]; rhs lvs: [", interppSP (uniqSetToList lvs_rhss),
                             char ']'])))
                2 (ppr expr)]

pprStgExpr (StgTick tickish expr)
  = sdocWithDynFlags $ \dflags ->
    if gopt Opt_PprShowTicks dflags
    then sep [ ppr tickish, pprStgExpr expr ]
    else pprStgExpr expr


pprStgExpr (StgCase expr lvs_whole lvs_rhss bndr srt alt_type alts)
  = sep [sep [text "case",
           nest 4 (hsep [pprStgExpr expr,
             ifPprDebug (dcolon <+> ppr alt_type)]),
           text "of", pprBndr CaseBind bndr, char '{'],
           ifPprDebug (
           nest 4 (
             hcat [ptext  (sLit "-- lvs: ["), interppSP (uniqSetToList lvs_whole),
                    text "]; rhs lvs: [", interppSP (uniqSetToList lvs_rhss),
                    text "]; ",
                    pprMaybeSRT srt])),
           nest 2 (vcat (map pprStgAlt alts)),
           char '}']

pprStgAlt :: (OutputableBndr bndr, Outputable occ, Ord occ)
          => GenStgAlt bndr occ -> SDoc
pprStgAlt (con, params, _use_mask, expr)
  = hang (hsep [ppr con, sep (map (pprBndr CaseBind) params), text "->"])
         4 (ppr expr <> semi)

pprStgOp :: StgOp -> SDoc
pprStgOp (StgPrimOp  op)   = ppr op
pprStgOp (StgPrimCallOp op)= ppr op
pprStgOp (StgFCallOp op _) = ppr op

instance Outputable AltType where
  ppr PolyAlt        = text "Polymorphic"
  ppr (UbxTupAlt n)  = text "UbxTup" <+> ppr n
  ppr (AlgAlt tc)    = text "Alg"    <+> ppr tc
  ppr (PrimAlt tc)   = text "Prim"   <+> ppr tc

pprStgLVs :: Outputable occ => GenStgLiveVars occ -> SDoc
pprStgLVs lvs
  = getPprStyle $ \ sty ->
    if userStyle sty || isEmptyUniqSet lvs then
        empty
    else
        hcat [text "{-lvs:", interpp'SP (uniqSetToList lvs), text "-}"]

pprStgRhs :: (OutputableBndr bndr, Outputable bdee, Ord bdee)
          => GenStgRhs bndr bdee -> SDoc

-- special case
pprStgRhs (StgRhsClosure cc bi [free_var] upd_flag srt [{-no args-}] (StgApp func []))
  = hcat [ ppr cc,
           pp_binder_info bi,
           brackets (ifPprDebug (ppr free_var)),
           text " \\", ppr upd_flag, pprMaybeSRT srt, ptext (sLit " [] "), ppr func ]

-- general case
pprStgRhs (StgRhsClosure cc bi free_vars upd_flag srt args body)
  = sdocWithDynFlags $ \dflags ->
    hang (hsep [if gopt Opt_SccProfilingOn dflags then ppr cc else empty,
                pp_binder_info bi,
                ifPprDebug (brackets (interppSP free_vars)),
                char '\\' <> ppr upd_flag, pprMaybeSRT srt, brackets (interppSP args)])
         4 (ppr body)

pprStgRhs (StgRhsCon cc con args)
  = hcat [ ppr cc,
           space, ppr con, text "! ", brackets (interppSP args)]

pprMaybeSRT :: SRT -> SDoc
pprMaybeSRT (NoSRT) = empty
pprMaybeSRT srt     = text "srt:" <> pprSRT srt
