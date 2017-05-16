{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[TcBinds]{TcBinds}
-}

{-# LANGUAGE CPP, RankNTypes, ScopedTypeVariables #-}

module TcBinds ( tcLocalBinds, tcTopBinds, tcRecSelBinds,
                 tcValBinds, tcHsBootSigs, tcPolyCheck,
                 tcSpecPrags, tcSpecWrapper,
                 tcVectDecls, addTypecheckedBinds,
                 TcSigInfo(..), TcSigFun,
                 TcPragEnv, mkPragEnv,
                 tcUserTypeSig, instTcTySig, chooseInferredQuantifiers,
                 instTcTySigFromId, tcExtendTyVarEnvFromSig,
                 badBootDeclErr ) where

import {-# SOURCE #-} TcMatches ( tcGRHSsPat, tcMatchesFun )
import {-# SOURCE #-} TcExpr  ( tcMonoExpr )
import {-# SOURCE #-} TcPatSyn ( tcInferPatSynDecl, tcCheckPatSynDecl
                               , tcPatSynBuilderBind, tcPatSynSig )
import DynFlags
import HsSyn
import HscTypes( isHsBootOrSig )
import TcRnMonad
import TcEnv
import TcUnify
import TcSimplify
import TcEvidence
import TcHsType
import TcPat
import TcMType
import Inst( topInstantiate, deeplyInstantiate )
import FamInstEnv( normaliseType )
import FamInst( tcGetFamInstEnvs )
import TyCon
import TcType
import TysPrim
import Id
import Var
import VarSet
import VarEnv( TidyEnv )
import Module
import Name
import NameSet
import NameEnv
import SrcLoc
import Bag
import ListSetOps
import ErrUtils
import Digraph
import Maybes
import Util
import BasicTypes
import Outputable
import Type(mkStrLitTy, tidyOpenType)
import PrelNames( mkUnboundName, gHC_PRIM, ipClassName )
import TcValidity (checkValidType)
import qualified GHC.LanguageExtensions as LangExt

import Control.Monad

#include "HsVersions.h"

{- *********************************************************************
*                                                                      *
               A useful helper function
*                                                                      *
********************************************************************* -}

addTypecheckedBinds :: TcGblEnv -> [LHsBinds Id] -> TcGblEnv
addTypecheckedBinds tcg_env binds
  | isHsBootOrSig (tcg_src tcg_env) = tcg_env
    -- Do not add the code for record-selector bindings
    -- when compiling hs-boot files
  | otherwise = tcg_env { tcg_binds = foldr unionBags
                                            (tcg_binds tcg_env)
                                            binds }

{-
************************************************************************
*                                                                      *
\subsection{Type-checking bindings}
*                                                                      *
************************************************************************

@tcBindsAndThen@ typechecks a @HsBinds@.  The "and then" part is because
it needs to know something about the {\em usage} of the things bound,
so that it can create specialisations of them.  So @tcBindsAndThen@
takes a function which, given an extended environment, E, typechecks
the scope of the bindings returning a typechecked thing and (most
important) an LIE.  It is this LIE which is then used as the basis for
specialising the things bound.

@tcBindsAndThen@ also takes a "combiner" which glues together the
bindings and the "thing" to make a new "thing".

The real work is done by @tcBindWithSigsAndThen@.

Recursive and non-recursive binds are handled in essentially the same
way: because of uniques there are no scoping issues left.  The only
difference is that non-recursive bindings can bind primitive values.

Even for non-recursive binding groups we add typings for each binder
to the LVE for the following reason.  When each individual binding is
checked the type of its LHS is unified with that of its RHS; and
type-checking the LHS of course requires that the binder is in scope.

At the top-level the LIE is sure to contain nothing but constant
dictionaries, which we resolve at the module level.

Note [Polymorphic recursion]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The game plan for polymorphic recursion in the code above is

        * Bind any variable for which we have a type signature
          to an Id with a polymorphic type.  Then when type-checking
          the RHSs we'll make a full polymorphic call.

This fine, but if you aren't a bit careful you end up with a horrendous
amount of partial application and (worse) a huge space leak. For example:

        f :: Eq a => [a] -> [a]
        f xs = ...f...

If we don't take care, after typechecking we get

        f = /\a -> \d::Eq a -> let f' = f a d
                               in
                               \ys:[a] -> ...f'...

Notice the the stupid construction of (f a d), which is of course
identical to the function we're executing.  In this case, the
polymorphic recursion isn't being used (but that's a very common case).
This can lead to a massive space leak, from the following top-level defn
(post-typechecking)

        ff :: [Int] -> [Int]
        ff = f Int dEqInt

Now (f dEqInt) evaluates to a lambda that has f' as a free variable; but
f' is another thunk which evaluates to the same thing... and you end
up with a chain of identical values all hung onto by the CAF ff.

        ff = f Int dEqInt

           = let f' = f Int dEqInt in \ys. ...f'...

           = let f' = let f' = f Int dEqInt in \ys. ...f'...
                      in \ys. ...f'...

Etc.

NOTE: a bit of arity anaysis would push the (f a d) inside the (\ys...),
which would make the space leak go away in this case

Solution: when typechecking the RHSs we always have in hand the
*monomorphic* Ids for each binding.  So we just need to make sure that
if (Method f a d) shows up in the constraints emerging from (...f...)
we just use the monomorphic Id.  We achieve this by adding monomorphic Ids
to the "givens" when simplifying constraints.  That's what the "lies_avail"
is doing.

Then we get

        f = /\a -> \d::Eq a -> letrec
                                 fm = \ys:[a] -> ...fm...
                               in
                               fm
-}

tcTopBinds :: [(RecFlag, LHsBinds Name)] -> [LSig Name] -> TcM (TcGblEnv, TcLclEnv)
-- The TcGblEnv contains the new tcg_binds and tcg_spects
-- The TcLclEnv has an extended type envt for the new bindings
tcTopBinds binds sigs
  = do  { -- Pattern synonym bindings populate the global environment
          (binds', (tcg_env, tcl_env)) <- tcValBinds TopLevel binds sigs $
            do { gbl <- getGblEnv
               ; lcl <- getLclEnv
               ; return (gbl, lcl) }
        ; specs <- tcImpPrags sigs   -- SPECIALISE prags for imported Ids

        ; let { tcg_env' = tcg_env { tcg_imp_specs = specs ++ tcg_imp_specs tcg_env }
                           `addTypecheckedBinds` map snd binds' }

        ; return (tcg_env', tcl_env) }
        -- The top level bindings are flattened into a giant
        -- implicitly-mutually-recursive LHsBinds

tcRecSelBinds :: HsValBinds Name -> TcM TcGblEnv
tcRecSelBinds (ValBindsOut binds sigs)
  = tcExtendGlobalValEnv [sel_id | L _ (IdSig sel_id) <- sigs] $
    do { (rec_sel_binds, tcg_env) <- discardWarnings $
                                     tcValBinds TopLevel binds sigs getGblEnv
       ; let tcg_env' = tcg_env `addTypecheckedBinds` map snd rec_sel_binds
       ; return tcg_env' }
tcRecSelBinds (ValBindsIn {}) = panic "tcRecSelBinds"

tcHsBootSigs :: [(RecFlag, LHsBinds Name)] -> [LSig Name] -> TcM [Id]
-- A hs-boot file has only one BindGroup, and it only has type
-- signatures in it.  The renamer checked all this
tcHsBootSigs binds sigs
  = do  { checkTc (null binds) badBootDeclErr
        ; concat <$> mapM (addLocM tc_boot_sig) (filter isTypeLSig sigs) }
  where
    tc_boot_sig (TypeSig lnames hs_ty) = mapM f lnames
      where
        f (L _ name)
          = do { sigma_ty <- solveEqualities $
                             tcHsSigWcType (FunSigCtxt name False) hs_ty
               ; return (mkVanillaGlobal name sigma_ty) }
        -- Notice that we make GlobalIds, not LocalIds
    tc_boot_sig s = pprPanic "tcHsBootSigs/tc_boot_sig" (ppr s)

badBootDeclErr :: MsgDoc
badBootDeclErr = text "Illegal declarations in an hs-boot file"

------------------------
tcLocalBinds :: HsLocalBinds Name -> TcM thing
             -> TcM (HsLocalBinds TcId, thing)

tcLocalBinds EmptyLocalBinds thing_inside
  = do  { thing <- thing_inside
        ; return (EmptyLocalBinds, thing) }

tcLocalBinds (HsValBinds (ValBindsOut binds sigs)) thing_inside
  = do  { (binds', thing) <- tcValBinds NotTopLevel binds sigs thing_inside
        ; return (HsValBinds (ValBindsOut binds' sigs), thing) }
tcLocalBinds (HsValBinds (ValBindsIn {})) _ = panic "tcLocalBinds"

tcLocalBinds (HsIPBinds (IPBinds ip_binds _)) thing_inside
  = do  { ipClass <- tcLookupClass ipClassName
        ; (given_ips, ip_binds') <-
            mapAndUnzipM (wrapLocSndM (tc_ip_bind ipClass)) ip_binds

        -- If the binding binds ?x = E, we  must now
        -- discharge any ?x constraints in expr_lie
        -- See Note [Implicit parameter untouchables]
        ; (ev_binds, result) <- checkConstraints (IPSkol ips)
                                  [] given_ips thing_inside

        ; return (HsIPBinds (IPBinds ip_binds' ev_binds), result) }
  where
    ips = [ip | L _ (IPBind (Left (L _ ip)) _) <- ip_binds]

        -- I wonder if we should do these one at at time
        -- Consider     ?x = 4
        --              ?y = ?x + 1
    tc_ip_bind ipClass (IPBind (Left (L _ ip)) expr)
       = do { ty <- newOpenFlexiTyVarTy
            ; let p = mkStrLitTy $ hsIPNameFS ip
            ; ip_id <- newDict ipClass [ p, ty ]
            ; expr' <- tcMonoExpr expr (mkCheckExpType ty)
            ; let d = toDict ipClass p ty `fmap` expr'
            ; return (ip_id, (IPBind (Right ip_id) d)) }
    tc_ip_bind _ (IPBind (Right {}) _) = panic "tc_ip_bind"

    -- Coerces a `t` into a dictionry for `IP "x" t`.
    -- co : t -> IP "x" t
    toDict ipClass x ty = HsWrap $ mkWpCastR $
                          wrapIP $ mkClassPred ipClass [x,ty]

{- Note [Implicit parameter untouchables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We add the type variables in the types of the implicit parameters
as untouchables, not so much because we really must not unify them,
but rather because we otherwise end up with constraints like this
    Num alpha, Implic { wanted = alpha ~ Int }
The constraint solver solves alpha~Int by unification, but then
doesn't float that solved constraint out (it's not an unsolved
wanted).  Result disaster: the (Num alpha) is again solved, this
time by defaulting.  No no no.

However [Oct 10] this is all handled automatically by the
untouchable-range idea.

Note [Inlining and hs-boot files]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this example (Trac #10083):

    ---------- RSR.hs-boot ------------
    module RSR where
      data RSR
      eqRSR :: RSR -> RSR -> Bool

    ---------- SR.hs ------------
    module SR where
      import {-# SOURCE #-} RSR
      data SR = MkSR RSR
      eqSR (MkSR r1) (MkSR r2) = eqRSR r1 r2

    ---------- RSR.hs ------------
    module RSR where
      import SR
      data RSR = MkRSR SR -- deriving( Eq )
      eqRSR (MkRSR s1) (MkRSR s2) = (eqSR s1 s2)
      foo x y = not (eqRSR x y)

When compiling RSR we get this code

    RSR.eqRSR :: RSR -> RSR -> Bool
    RSR.eqRSR = \ (ds1 :: RSR.RSR) (ds2 :: RSR.RSR) ->
                case ds1 of _ { RSR.MkRSR s1 ->
                case ds2 of _ { RSR.MkRSR s2 ->
                SR.eqSR s1 s2 }}

    RSR.foo :: RSR -> RSR -> Bool
    RSR.foo = \ (x :: RSR) (y :: RSR) -> not (RSR.eqRSR x y)

Now, when optimising foo:
    Inline eqRSR (small, non-rec)
    Inline eqSR  (small, non-rec)
but the result of inlining eqSR from SR is another call to eqRSR, so
everything repeats.  Neither eqSR nor eqRSR are (apparently) loop
breakers.

Solution: when compiling RSR, add a NOINLINE pragma to every function
exported by the boot-file for RSR (if it exists).

ALAS: doing so makes the boostrappted GHC itself slower by 8% overall
      (on Trac #9872a-d, and T1969.  So I un-did this change, and
      parked it for now.  Sigh.
-}

tcValBinds :: TopLevelFlag
           -> [(RecFlag, LHsBinds Name)] -> [LSig Name]
           -> TcM thing
           -> TcM ([(RecFlag, LHsBinds TcId)], thing)

tcValBinds top_lvl binds sigs thing_inside
  = do  { let patsyns = getPatSynBinds binds

            -- Typecheck the signature
        ; (poly_ids, sig_fn) <- tcAddPatSynPlaceholders patsyns $
                                tcTySigs sigs

        ; _self_boot <- tcSelfBootInfo
        ; let prag_fn = mkPragEnv sigs (foldr (unionBags . snd) emptyBag binds)

-- -------  See Note [Inlining and hs-boot files] (change parked) --------
--              prag_fn | isTopLevel top_lvl   -- See Note [Inlining and hs-boot files]
--                      , SelfBoot { sb_ids = boot_id_names } <- self_boot
--                      = foldNameSet add_no_inl prag_fn1 boot_id_names
--                      | otherwise
--                      = prag_fn1
--              add_no_inl boot_id_name prag_fn
--                = extendPragEnv prag_fn (boot_id_name, no_inl_sig boot_id_name)
--              no_inl_sig name = L boot_loc (InlineSig (L boot_loc name) neverInlinePragma)
--              boot_loc = mkGeneralSrcSpan (fsLit "The hs-boot file for this module")

                -- Extend the envt right away with all the Ids
                -- declared with complete type signatures
                -- Do not extend the TcIdBinderStack; instead
                -- we extend it on a per-rhs basis in tcExtendForRhs
        ; tcExtendLetEnvIds top_lvl [(idName id, id) | id <- poly_ids] $ do
            { (binds', (extra_binds', thing)) <- tcBindGroups top_lvl sig_fn prag_fn binds $ do
                   { thing <- thing_inside
                     -- See Note [Pattern synonym builders don't yield dependencies]
                   ; patsyn_builders <- mapM (tcPatSynBuilderBind sig_fn) patsyns
                   ; let extra_binds = [ (NonRecursive, builder) | builder <- patsyn_builders ]
                   ; return (extra_binds, thing) }
            ; return (binds' ++ extra_binds', thing) }}

------------------------
tcBindGroups :: TopLevelFlag -> TcSigFun -> TcPragEnv
             -> [(RecFlag, LHsBinds Name)] -> TcM thing
             -> TcM ([(RecFlag, LHsBinds TcId)], thing)
-- Typecheck a whole lot of value bindings,
-- one strongly-connected component at a time
-- Here a "strongly connected component" has the strightforward
-- meaning of a group of bindings that mention each other,
-- ignoring type signatures (that part comes later)

tcBindGroups _ _ _ [] thing_inside
  = do  { thing <- thing_inside
        ; return ([], thing) }

tcBindGroups top_lvl sig_fn prag_fn (group : groups) thing_inside
  = do  { (group', (groups', thing))
                <- tc_group top_lvl sig_fn prag_fn group $
                   tcBindGroups top_lvl sig_fn prag_fn groups thing_inside
        ; return (group' ++ groups', thing) }

------------------------
tc_group :: forall thing.
            TopLevelFlag -> TcSigFun -> TcPragEnv
         -> (RecFlag, LHsBinds Name) -> TcM thing
         -> TcM ([(RecFlag, LHsBinds TcId)], thing)

-- Typecheck one strongly-connected component of the original program.
-- We get a list of groups back, because there may
-- be specialisations etc as well

tc_group top_lvl sig_fn prag_fn (NonRecursive, binds) thing_inside
        -- A single non-recursive binding
        -- We want to keep non-recursive things non-recursive
        -- so that we desugar unlifted bindings correctly
  = do { let bind = case bagToList binds of
                 [bind] -> bind
                 []     -> panic "tc_group: empty list of binds"
                 _      -> panic "tc_group: NonRecursive binds is not a singleton bag"
       ; (bind', thing) <- tc_single top_lvl sig_fn prag_fn bind thing_inside
       ; return ( [(NonRecursive, bind')], thing) }

tc_group top_lvl sig_fn prag_fn (Recursive, binds) thing_inside
  =     -- To maximise polymorphism, we do a new
        -- strongly-connected-component analysis, this time omitting
        -- any references to variables with type signatures.
        -- (This used to be optional, but isn't now.)
        -- See Note [Polymorphic recursion] in HsBinds.
    do  { traceTc "tc_group rec" (pprLHsBinds binds)
        ; when hasPatSyn $ recursivePatSynErr binds
        ; (binds1, thing) <- go sccs
        ; return ([(Recursive, binds1)], thing) }
                -- Rec them all together
  where
    hasPatSyn = anyBag (isPatSyn . unLoc) binds
    isPatSyn PatSynBind{} = True
    isPatSyn _ = False

    sccs :: [SCC (LHsBind Name)]
    sccs = stronglyConnCompFromEdgedVertices (mkEdges sig_fn binds)

    go :: [SCC (LHsBind Name)] -> TcM (LHsBinds TcId, thing)
    go (scc:sccs) = do  { (binds1, ids1) <- tc_scc scc
                        ; (binds2, thing) <- tcExtendLetEnv top_lvl ids1 $
                                             go sccs
                        ; return (binds1 `unionBags` binds2, thing) }
    go []         = do  { thing <- thing_inside; return (emptyBag, thing) }

    tc_scc (AcyclicSCC bind) = tc_sub_group NonRecursive [bind]
    tc_scc (CyclicSCC binds) = tc_sub_group Recursive    binds

    tc_sub_group = tcPolyBinds top_lvl sig_fn prag_fn Recursive

recursivePatSynErr :: OutputableBndr name => LHsBinds name -> TcM a
recursivePatSynErr binds
  = failWithTc $
    hang (text "Recursive pattern synonym definition with following bindings:")
       2 (vcat $ map pprLBind . bagToList $ binds)
  where
    pprLoc loc  = parens (text "defined at" <+> ppr loc)
    pprLBind (L loc bind) = pprWithCommas ppr (collectHsBindBinders bind) <+>
                            pprLoc loc

tc_single :: forall thing.
            TopLevelFlag -> TcSigFun -> TcPragEnv
          -> LHsBind Name -> TcM thing
          -> TcM (LHsBinds TcId, thing)
tc_single _top_lvl sig_fn _prag_fn (L _ (PatSynBind psb@PSB{ psb_id = L _ name })) thing_inside
  = do { (aux_binds, tcg_env) <- tc_pat_syn_decl
       ; thing <- setGblEnv tcg_env thing_inside
       ; return (aux_binds, thing)
       }
  where
    tc_pat_syn_decl :: TcM (LHsBinds TcId, TcGblEnv)
    tc_pat_syn_decl = case sig_fn name of
        Nothing                 -> tcInferPatSynDecl psb
        Just (TcPatSynSig tpsi) -> tcCheckPatSynDecl psb tpsi
        Just                 _  -> panic "tc_single"

tc_single top_lvl sig_fn prag_fn lbind thing_inside
  = do { (binds1, ids) <- tcPolyBinds top_lvl sig_fn prag_fn
                                      NonRecursive NonRecursive
                                      [lbind]
       ; thing <- tcExtendLetEnv top_lvl ids thing_inside
       ; return (binds1, thing) }

------------------------
type BKey = Int -- Just number off the bindings

mkEdges :: TcSigFun -> LHsBinds Name -> [Node BKey (LHsBind Name)]
-- See Note [Polymorphic recursion] in HsBinds.
mkEdges sig_fn binds
  = [ (bind, key, [key | n <- nameSetElems (bind_fvs (unLoc bind)),
                         Just key <- [lookupNameEnv key_map n], no_sig n ])
    | (bind, key) <- keyd_binds
    ]
  where
    no_sig :: Name -> Bool
    no_sig n = noCompleteSig (sig_fn n)

    keyd_binds = bagToList binds `zip` [0::BKey ..]

    key_map :: NameEnv BKey     -- Which binding it comes from
    key_map = mkNameEnv [(bndr, key) | (L _ bind, key) <- keyd_binds
                                     , bndr <- collectHsBindBinders bind ]

------------------------
tcPolyBinds :: TopLevelFlag -> TcSigFun -> TcPragEnv
            -> RecFlag         -- Whether the group is really recursive
            -> RecFlag         -- Whether it's recursive after breaking
                               -- dependencies based on type signatures
            -> [LHsBind Name]  -- None are PatSynBind
            -> TcM (LHsBinds TcId, [TcId])

-- Typechecks a single bunch of values bindings all together,
-- and generalises them.  The bunch may be only part of a recursive
-- group, because we use type signatures to maximise polymorphism
--
-- Returns a list because the input may be a single non-recursive binding,
-- in which case the dependency order of the resulting bindings is
-- important.
--
-- Knows nothing about the scope of the bindings
-- None of the bindings are pattern synonyms

tcPolyBinds top_lvl sig_fn prag_fn rec_group rec_tc bind_list
  = setSrcSpan loc                              $
    recoverM (recoveryCode binder_names sig_fn) $ do
        -- Set up main recover; take advantage of any type sigs

    { traceTc "------------------------------------------------" Outputable.empty
    ; traceTc "Bindings for {" (ppr binder_names)
    ; dflags   <- getDynFlags
    ; type_env <- getLclTypeEnv
    ; let plan = decideGeneralisationPlan dflags type_env
                         binder_names bind_list sig_fn
    ; traceTc "Generalisation plan" (ppr plan)
    ; result@(tc_binds, poly_ids) <- case plan of
         NoGen              -> tcPolyNoGen rec_tc prag_fn sig_fn bind_list
         InferGen mn        -> tcPolyInfer rec_tc prag_fn sig_fn mn bind_list
         CheckGen lbind sig -> tcPolyCheck rec_tc prag_fn sig lbind

        -- Check whether strict bindings are ok
        -- These must be non-recursive etc, and are not generalised
        -- They desugar to a case expression in the end
    ; checkStrictBinds top_lvl rec_group bind_list tc_binds poly_ids
    ; traceTc "} End of bindings for" (vcat [ ppr binder_names, ppr rec_group
                                            , vcat [ppr id <+> ppr (idType id) | id <- poly_ids]
                                          ])

    ; return result }
  where
    binder_names = collectHsBindListBinders bind_list
    loc = foldr1 combineSrcSpans (map getLoc bind_list)
         -- The mbinds have been dependency analysed and
         -- may no longer be adjacent; so find the narrowest
         -- span that includes them all

------------------
tcPolyNoGen     -- No generalisation whatsoever
  :: RecFlag       -- Whether it's recursive after breaking
                   -- dependencies based on type signatures
  -> TcPragEnv -> TcSigFun
  -> [LHsBind Name]
  -> TcM (LHsBinds TcId, [TcId])

tcPolyNoGen rec_tc prag_fn tc_sig_fn bind_list
  = do { (binds', mono_infos) <- tcMonoBinds rec_tc tc_sig_fn
                                             (LetGblBndr prag_fn)
                                             bind_list
       ; mono_ids' <- mapM tc_mono_info mono_infos
       ; return (binds', mono_ids') }
  where
    tc_mono_info (MBI { mbi_poly_name = name, mbi_mono_id = mono_id })
      = do { mono_ty' <- zonkTcType (idType mono_id)
             -- Zonk, mainly to expose unboxed types to checkStrictBinds
           ; let mono_id' = setIdType mono_id mono_ty'
           ; _specs <- tcSpecPrags mono_id' (lookupPragEnv prag_fn name)
           ; return mono_id' }
           -- NB: tcPrags generates error messages for
           --     specialisation pragmas for non-overloaded sigs
           -- Indeed that is why we call it here!
           -- So we can safely ignore _specs

------------------
tcPolyCheck :: RecFlag       -- Whether it's recursive after breaking
                             -- dependencies based on type signatures
            -> TcPragEnv
            -> TcIdSigInfo
            -> LHsBind Name
            -> TcM (LHsBinds TcId, [TcId])
-- There is just one binding,
--   it binds a single variable,
--   it has a complete type signature,
tcPolyCheck rec_tc prag_fn
            sig@(TISI { sig_bndr  = CompleteSig poly_id
                      , sig_skols = skol_prs
                      , sig_theta = theta
                      , sig_tau   = tau
                      , sig_ctxt  = ctxt
                      , sig_loc   = loc })
            bind
  = do { ev_vars <- newEvVars theta
       ; let skol_info = SigSkol ctxt (mkCheckExpType $ mkPhiTy theta tau)
             prag_sigs = lookupPragEnv prag_fn name
             skol_tvs  = map snd skol_prs
                 -- Find the location of the original source type sig, if
                 -- there is was one.  This will appear in messages like
                 -- "type variable x is bound by .. at <loc>"
             name = idName poly_id
       ; (ev_binds, (binds', _))
            <- setSrcSpan loc $
               checkConstraints skol_info skol_tvs ev_vars $
               tcMonoBinds rec_tc (\_ -> Just (TcIdSig sig)) LetLclBndr [bind]

       ; spec_prags <- tcSpecPrags poly_id prag_sigs
       ; poly_id    <- addInlinePrags poly_id prag_sigs

       ; let bind' = case bagToList binds' of
                       [b] -> b
                       _   -> pprPanic "tcPolyCheck" (ppr binds')
             abs_bind = L loc $ AbsBindsSig
                        { abs_tvs = skol_tvs
                        , abs_ev_vars = ev_vars
                        , abs_sig_export = poly_id
                        , abs_sig_prags = SpecPrags spec_prags
                        , abs_sig_ev_bind = ev_binds
                        , abs_sig_bind    = bind' }

       ; return (unitBag abs_bind, [poly_id]) }

tcPolyCheck _rec_tc _prag_fn sig _bind
  = pprPanic "tcPolyCheck" (ppr sig)

------------------
tcPolyInfer
  :: RecFlag       -- Whether it's recursive after breaking
                   -- dependencies based on type signatures
  -> TcPragEnv -> TcSigFun
  -> Bool         -- True <=> apply the monomorphism restriction
  -> [LHsBind Name]
  -> TcM (LHsBinds TcId, [TcId])
tcPolyInfer rec_tc prag_fn tc_sig_fn mono bind_list
  = do { (tclvl, wanted, (binds', mono_infos))
             <- pushLevelAndCaptureConstraints  $
                tcMonoBinds rec_tc tc_sig_fn LetLclBndr bind_list

       ; let name_taus = [ (mbi_poly_name info, idType (mbi_mono_id info))
                         | info <- mono_infos ]
             sigs      = [ sig | MBI { mbi_sig = Just sig } <- mono_infos ]

       ; traceTc "simplifyInfer call" (ppr tclvl $$ ppr name_taus $$ ppr wanted)
       ; (qtvs, givens, ev_binds)
                 <- simplifyInfer tclvl mono sigs name_taus wanted

       ; let inferred_theta = map evVarPred givens
       ; exports <- checkNoErrs $
                    mapM (mkExport prag_fn qtvs inferred_theta) mono_infos

       ; loc <- getSrcSpanM
       ; let poly_ids = map abe_poly exports
             abs_bind = L loc $
                        AbsBinds { abs_tvs = qtvs
                                 , abs_ev_vars = givens, abs_ev_binds = [ev_binds]
                                 , abs_exports = exports, abs_binds = binds' }

       ; traceTc "Binding:" (ppr (poly_ids `zip` map idType poly_ids))
       ; return (unitBag abs_bind, poly_ids) }
         -- poly_ids are guaranteed zonked by mkExport

--------------
mkExport :: TcPragEnv
         -> [TyVar] -> TcThetaType      -- Both already zonked
         -> MonoBindInfo
         -> TcM (ABExport Id)
-- Only called for generalisation plan InferGen, not by CheckGen or NoGen
--
-- mkExport generates exports with
--      zonked type variables,
--      zonked poly_ids
-- The former is just because no further unifications will change
-- the quantified type variables, so we can fix their final form
-- right now.
-- The latter is needed because the poly_ids are used to extend the
-- type environment; see the invariant on TcEnv.tcExtendIdEnv

-- Pre-condition: the qtvs and theta are already zonked

mkExport prag_fn qtvs theta
         mono_info@(MBI { mbi_poly_name = poly_name
                        , mbi_sig       = mb_sig
                        , mbi_mono_id   = mono_id })
  = do  { mono_ty <- zonkTcType (idType mono_id)
        ; poly_id <- case mb_sig of
              Just sig | Just poly_id <- completeIdSigPolyId_maybe sig
                       -> return poly_id
              _other   -> checkNoErrs $
                          mkInferredPolyId qtvs theta
                                           poly_name mb_sig mono_ty
              -- The checkNoErrs ensures that if the type is ambiguous
              -- we don't carry on to the impedence matching, and generate
              -- a duplicate ambiguity error.  There is a similar
              -- checkNoErrs for complete type signatures too.

        -- NB: poly_id has a zonked type
        ; poly_id <- addInlinePrags poly_id prag_sigs
        ; spec_prags <- tcSpecPrags poly_id prag_sigs
                -- tcPrags requires a zonked poly_id

        -- See Note [Impedence matching]
        -- NB: we have already done checkValidType, including an ambiguity check,
        --     on the type; either when we checked the sig or in mkInferredPolyId
        ; let sel_poly_ty = mkInvSigmaTy qtvs theta mono_ty
                -- this type is just going into tcSubType, so Inv vs. Spec doesn't
                -- matter

              poly_ty     = idType poly_id
        ; wrap <- if sel_poly_ty `eqType` poly_ty  -- NB: eqType ignores visibility
                  then return idHsWrapper  -- Fast path; also avoids complaint when we infer
                                           -- an ambiguouse type and have AllowAmbiguousType
                                           -- e..g infer  x :: forall a. F a -> Int
                  else addErrCtxtM (mk_impedence_match_msg mono_info sel_poly_ty poly_ty) $
                       tcSubType_NC sig_ctxt sel_poly_ty (mkCheckExpType poly_ty)

        ; warn_missing_sigs <- woptM Opt_WarnMissingLocalSignatures
        ; when warn_missing_sigs $
              localSigWarn Opt_WarnMissingLocalSignatures poly_id mb_sig

        ; return (ABE { abe_wrap = wrap
                        -- abe_wrap :: idType poly_id ~ (forall qtvs. theta => mono_ty)
                      , abe_poly = poly_id
                      , abe_mono = mono_id
                      , abe_prags = SpecPrags spec_prags}) }
  where
    prag_sigs = lookupPragEnv prag_fn poly_name
    sig_ctxt  = InfSigCtxt poly_name

mkInferredPolyId :: [TyVar] -> TcThetaType
                 -> Name -> Maybe TcIdSigInfo -> TcType
                 -> TcM TcId
mkInferredPolyId qtvs inferred_theta poly_name mb_sig mono_ty
  = do { fam_envs <- tcGetFamInstEnvs
       ; let (_co, mono_ty') = normaliseType fam_envs Nominal mono_ty
               -- Unification may not have normalised the type,
               -- (see Note [Lazy flattening] in TcFlatten) so do it
               -- here to make it as uncomplicated as possible.
               -- Example: f :: [F Int] -> Bool
               -- should be rewritten to f :: [Char] -> Bool, if possible
               --
               -- We can discard the coercion _co, because we'll reconstruct
               -- it in the call to tcSubType below

       ; (binders, theta') <- chooseInferredQuantifiers inferred_theta
                                (tyCoVarsOfType mono_ty') qtvs mb_sig

       ; let inferred_poly_ty = mkForAllTys binders (mkPhiTy theta' mono_ty')

       ; traceTc "mkInferredPolyId" (vcat [ppr poly_name, ppr qtvs, ppr theta'
                                          , ppr inferred_poly_ty])
       ; addErrCtxtM (mk_inf_msg poly_name inferred_poly_ty) $
         checkValidType (InfSigCtxt poly_name) inferred_poly_ty
         -- See Note [Validity of inferred types]

       ; return (mkLocalIdOrCoVar poly_name inferred_poly_ty) }


chooseInferredQuantifiers :: TcThetaType   -- inferred
                          -> TcTyVarSet    -- tvs free in tau type
                          -> [TcTyVar]     -- inferred quantified tvs
                          -> Maybe TcIdSigInfo
                          -> TcM ([TcTyBinder], TcThetaType)
chooseInferredQuantifiers inferred_theta tau_tvs qtvs Nothing
  = do { let free_tvs = closeOverKinds (growThetaTyVars inferred_theta tau_tvs)
                        -- Include kind variables!  Trac #7916
             my_theta = pickQuantifiablePreds free_tvs [] inferred_theta
             binders  = [ mkNamedBinder Invisible tv
                        | tv <- qtvs
                        , tv `elemVarSet` free_tvs ]
       ; return (binders, my_theta) }

chooseInferredQuantifiers inferred_theta tau_tvs qtvs
                          (Just (TISI { sig_bndr = bndr_info
                                      , sig_ctxt = ctxt
                                      , sig_theta = annotated_theta
                                      , sig_skols = annotated_tvs }))
  | PartialSig { sig_cts = extra } <- bndr_info
  , Nothing <- extra
  = do { annotated_theta <- zonkTcTypes annotated_theta
       ; let free_tvs = closeOverKinds (tyCoVarsOfTypes annotated_theta
                                        `unionVarSet` tau_tvs)
       ; traceTc "ciq" (vcat [ ppr bndr_info, ppr annotated_theta, ppr free_tvs])
       ; return (mk_binders free_tvs, annotated_theta) }

  | PartialSig { sig_cts = extra } <- bndr_info
  , Just loc <- extra
  = do { annotated_theta <- zonkTcTypes annotated_theta
       ; let free_tvs = closeOverKinds (tyCoVarsOfTypes annotated_theta
                                        `unionVarSet` tau_tvs)
             my_theta = pickQuantifiablePreds free_tvs annotated_theta inferred_theta

       -- Report the inferred constraints for an extra-constraints wildcard/hole as
       -- an error message, unless the PartialTypeSignatures flag is enabled. In this
       -- case, the extra inferred constraints are accepted without complaining.
       -- Returns the annotated constraints combined with the inferred constraints.
             inferred_diff = [ pred
                             | pred <- my_theta
                             , all (not . (`eqType` pred)) annotated_theta ]
             final_theta   = annotated_theta ++ inferred_diff
       ; partial_sigs      <- xoptM LangExt.PartialTypeSignatures
       ; warn_partial_sigs <- woptM Opt_WarnPartialTypeSignatures
       ; msg <- mkLongErrAt loc (mk_msg inferred_diff partial_sigs) empty
       ; traceTc "completeTheta" $
            vcat [ ppr bndr_info
                 , ppr annotated_theta, ppr inferred_theta
                 , ppr inferred_diff ]
       ; case partial_sigs of
           True | warn_partial_sigs ->
                      reportWarning (Reason Opt_WarnPartialTypeSignatures) msg
                | otherwise         -> return ()
           False                    -> reportError msg

       ; return (mk_binders free_tvs, final_theta) }

  | otherwise = pprPanic "chooseInferredQuantifiers" (ppr bndr_info)

  where
    pts_hint = text "To use the inferred type, enable PartialTypeSignatures"
    mk_msg inferred_diff suppress_hint
       = vcat [ hang ((text "Found constraint wildcard") <+> quotes (char '_'))
                   2 (text "standing for") <+> quotes (pprTheta inferred_diff)
              , if suppress_hint then empty else pts_hint
              , typeSigCtxt ctxt bndr_info ]

    spec_tv_set = mkVarSet $ map snd annotated_tvs
    mk_binders free_tvs
      = [ mkNamedBinder vis tv
        | tv <- qtvs
        , tv `elemVarSet` free_tvs
        , let vis | tv `elemVarSet` spec_tv_set = Specified
                  | otherwise                   = Invisible ]
                          -- Pulling from qtvs maintains original order

mk_impedence_match_msg :: MonoBindInfo
                       -> TcType -> TcType
                       -> TidyEnv -> TcM (TidyEnv, SDoc)
-- This is a rare but rather awkward error messages
mk_impedence_match_msg (MBI { mbi_poly_name = name, mbi_sig = mb_sig })
                       inf_ty sig_ty tidy_env
 = do { (tidy_env1, inf_ty) <- zonkTidyTcType tidy_env  inf_ty
      ; (tidy_env2, sig_ty) <- zonkTidyTcType tidy_env1 sig_ty
      ; let msg = vcat [ text "When checking that the inferred type"
                       , nest 2 $ ppr name <+> dcolon <+> ppr inf_ty
                       , text "is as general as its" <+> what <+> text "signature"
                       , nest 2 $ ppr name <+> dcolon <+> ppr sig_ty ]
      ; return (tidy_env2, msg) }
  where
    what = case mb_sig of
             Nothing                     -> text "inferred"
             Just sig | isPartialSig sig -> text "(partial)"
                      | otherwise        -> empty


mk_inf_msg :: Name -> TcType -> TidyEnv -> TcM (TidyEnv, SDoc)
mk_inf_msg poly_name poly_ty tidy_env
 = do { (tidy_env1, poly_ty) <- zonkTidyTcType tidy_env poly_ty
      ; let msg = vcat [ text "When checking the inferred type"
                       , nest 2 $ ppr poly_name <+> dcolon <+> ppr poly_ty ]
      ; return (tidy_env1, msg) }


-- | Warn the user about polymorphic local binders that lack type signatures.
localSigWarn :: WarningFlag -> Id -> Maybe TcIdSigInfo -> TcM ()
localSigWarn flag id mb_sig
  | Just _ <- mb_sig               = return ()
  | not (isSigmaTy (idType id))    = return ()
  | otherwise                      = warnMissingSignatures flag msg id
  where
    msg = text "Polymorphic local binding with no type signature:"

warnMissingSignatures :: WarningFlag -> SDoc -> Id -> TcM ()
warnMissingSignatures flag msg id
  = do  { env0 <- tcInitTidyEnv
        ; let (env1, tidy_ty) = tidyOpenType env0 (idType id)
        ; addWarnTcM (Reason flag) (env1, mk_msg tidy_ty) }
  where
    mk_msg ty = sep [ msg, nest 2 $ pprPrefixName (idName id) <+> dcolon <+> ppr ty ]

{-
Note [Partial type signatures and generalisation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we have a partial type signature, like
   f :: _ -> Int
then we *always* use the InferGen plan, and hence tcPolyInfer.
We do this even for a local binding with -XMonoLocalBinds.
Reasons:
  * The TcSigInfo for 'f' has a unification variable for the '_',
    whose TcLevel is one level deeper than the current level.
    (See pushTcLevelM in tcTySig.)  But NoGen doesn't increase
    the TcLevel like InferGen, so we lose the level invariant.

  * The signature might be   f :: forall a. _ -> a
    so it really is polymorphic.  It's not clear what it would
    mean to use NoGen on this, and indeed the ASSERT in tcLhs,
    in the (Just sig) case, checks that if there is a signature
    then we are using LetLclBndr, and hence a nested AbsBinds with
    increased TcLevel

It might be possible to fix these difficulties somehow, but there
doesn't seem much point.  Indeed, adding a partial type signature is a
way to get per-binding inferred generalisation.

Note [Validity of inferred types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We need to check inferred type for validity, in case it uses language
extensions that are not turned on.  The principle is that if the user
simply adds the inferred type to the program source, it'll compile fine.
See #8883.

Examples that might fail:
 - the type might be ambiguous

 - an inferred theta that requires type equalities e.g. (F a ~ G b)
                                or multi-parameter type classes
 - an inferred type that includes unboxed tuples


Note [Impedence matching]
~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   f 0 x = x
   f n x = g [] (not x)

   g [] y = f 10 y
   g _  y = f 9  y

After typechecking we'll get
  f_mono_ty :: a -> Bool -> Bool
  g_mono_ty :: [b] -> Bool -> Bool
with constraints
  (Eq a, Num a)

Note that f is polymorphic in 'a' and g in 'b'; and these are not linked.
The types we really want for f and g are
   f :: forall a. (Eq a, Num a) => a -> Bool -> Bool
   g :: forall b. [b] -> Bool -> Bool

We can get these by "impedance matching":
   tuple :: forall a b. (Eq a, Num a) => (a -> Bool -> Bool, [b] -> Bool -> Bool)
   tuple a b d1 d1 = let ...bind f_mono, g_mono in (f_mono, g_mono)

   f a d1 d2 = case tuple a Any d1 d2 of (f, g) -> f
   g b = case tuple Integer b dEqInteger dNumInteger of (f,g) -> g

Suppose the shared quantified tyvars are qtvs and constraints theta.
Then we want to check that
     forall qtvs. theta => f_mono_ty   is more polymorphic than   f's polytype
and the proof is the impedance matcher.

Notice that the impedance matcher may do defaulting.  See Trac #7173.

It also cleverly does an ambiguity check; for example, rejecting
   f :: F a -> F a
where F is a non-injective type function.
-}

--------------
-- If typechecking the binds fails, then return with each
-- signature-less binder given type (forall a.a), to minimise
-- subsequent error messages
recoveryCode :: [Name] -> TcSigFun -> TcM (LHsBinds TcId, [Id])
recoveryCode binder_names sig_fn
  = do  { traceTc "tcBindsWithSigs: error recovery" (ppr binder_names)
        ; let poly_ids = map mk_dummy binder_names
        ; return (emptyBag, poly_ids) }
  where
    mk_dummy name
      | Just sig <- sig_fn name
      , Just poly_id <- completeSigPolyId_maybe sig
      = poly_id
      | otherwise
      = mkLocalId name forall_a_a

forall_a_a :: TcType
forall_a_a = mkSpecForAllTys [runtimeRep1TyVar, openAlphaTyVar] openAlphaTy

{- *********************************************************************
*                                                                      *
                   Pragmas, including SPECIALISE
*                                                                      *
************************************************************************

Note [Handling SPECIALISE pragmas]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The basic idea is this:

   foo :: Num a => a -> b -> a
   {-# SPECIALISE foo :: Int -> b -> Int #-}

We check that
   (forall a b. Num a => a -> b -> a)
      is more polymorphic than
   forall b. Int -> b -> Int
(for which we could use tcSubType, but see below), generating a HsWrapper
to connect the two, something like
      wrap = /\b. <hole> Int b dNumInt
This wrapper is put in the TcSpecPrag, in the ABExport record of
the AbsBinds.


        f :: (Eq a, Ix b) => a -> b -> Bool
        {-# SPECIALISE f :: (Ix p, Ix q) => Int -> (p,q) -> Bool #-}
        f = <poly_rhs>

From this the typechecker generates

    AbsBinds [ab] [d1,d2] [([ab], f, f_mono, prags)] binds

    SpecPrag (wrap_fn :: forall a b. (Eq a, Ix b) => XXX
                      -> forall p q. (Ix p, Ix q) => XXX[ Int/a, (p,q)/b ])

From these we generate:

    Rule:       forall p, q, (dp:Ix p), (dq:Ix q).
                    f Int (p,q) dInt ($dfInPair dp dq) = f_spec p q dp dq

    Spec bind:  f_spec = wrap_fn <poly_rhs>

Note that

  * The LHS of the rule may mention dictionary *expressions* (eg
    $dfIxPair dp dq), and that is essential because the dp, dq are
    needed on the RHS.

  * The RHS of f_spec, <poly_rhs> has a *copy* of 'binds', so that it
    can fully specialise it.



From the TcSpecPrag, in DsBinds we generate a binding for f_spec and a RULE:

   f_spec :: Int -> b -> Int
   f_spec = wrap<f rhs>

   RULE: forall b (d:Num b). f b d = f_spec b

The RULE is generated by taking apart the HsWrapper, which is a little
delicate, but works.

Some wrinkles

1. We don't use full-on tcSubType, because that does co and contra
   variance and that in turn will generate too complex a LHS for the
   RULE.  So we use a single invocation of skolemise /
   topInstantiate in tcSpecWrapper.  (Actually I think that even
   the "deeply" stuff may be too much, because it introduces lambdas,
   though I think it can be made to work without too much trouble.)

2. We need to take care with type families (Trac #5821).  Consider
      type instance F Int = Bool
      f :: Num a => a -> F a
      {-# SPECIALISE foo :: Int -> Bool #-}

  We *could* try to generate an f_spec with precisely the declared type:
      f_spec :: Int -> Bool
      f_spec = <f rhs> Int dNumInt |> co

      RULE: forall d. f Int d = f_spec |> sym co

  but the 'co' and 'sym co' are (a) playing no useful role, and (b) are
  hard to generate.  At all costs we must avoid this:
      RULE: forall d. f Int d |> co = f_spec
  because the LHS will never match (indeed it's rejected in
  decomposeRuleLhs).

  So we simply do this:
    - Generate a constraint to check that the specialised type (after
      skolemiseation) is equal to the instantiated function type.
    - But *discard* the evidence (coercion) for that constraint,
      so that we ultimately generate the simpler code
          f_spec :: Int -> F Int
          f_spec = <f rhs> Int dNumInt

          RULE: forall d. f Int d = f_spec
      You can see this discarding happening in

3. Note that the HsWrapper can transform *any* function with the right
   type prefix
       forall ab. (Eq a, Ix b) => XXX
   regardless of XXX.  It's sort of polymorphic in XXX.  This is
   useful: we use the same wrapper to transform each of the class ops, as
   well as the dict.  That's what goes on in TcInstDcls.mk_meth_spec_prags
-}

mkPragEnv :: [LSig Name] -> LHsBinds Name -> TcPragEnv
mkPragEnv sigs binds
  = foldl extendPragEnv emptyNameEnv prs
  where
    prs = mapMaybe get_sig sigs

    get_sig :: LSig Name -> Maybe (Name, LSig Name)
    get_sig (L l (SpecSig lnm@(L _ nm) ty inl)) = Just (nm, L l $ SpecSig   lnm ty (add_arity nm inl))
    get_sig (L l (InlineSig lnm@(L _ nm) inl))  = Just (nm, L l $ InlineSig lnm    (add_arity nm inl))
    get_sig _                                   = Nothing

    add_arity n inl_prag   -- Adjust inl_sat field to match visible arity of function
      | Inline <- inl_inline inl_prag
        -- add arity only for real INLINE pragmas, not INLINABLE
      = case lookupNameEnv ar_env n of
          Just ar -> inl_prag { inl_sat = Just ar }
          Nothing -> WARN( True, text "mkPragEnv no arity" <+> ppr n )
                     -- There really should be a binding for every INLINE pragma
                     inl_prag
      | otherwise
      = inl_prag

    -- ar_env maps a local to the arity of its definition
    ar_env :: NameEnv Arity
    ar_env = foldrBag lhsBindArity emptyNameEnv binds

extendPragEnv :: TcPragEnv -> (Name, LSig Name) -> TcPragEnv
extendPragEnv prag_fn (n, sig) = extendNameEnv_Acc (:) singleton prag_fn n sig

lhsBindArity :: LHsBind Name -> NameEnv Arity -> NameEnv Arity
lhsBindArity (L _ (FunBind { fun_id = id, fun_matches = ms })) env
  = extendNameEnv env (unLoc id) (matchGroupArity ms)
lhsBindArity _ env = env        -- PatBind/VarBind

------------------
tcSpecPrags :: Id -> [LSig Name]
            -> TcM [LTcSpecPrag]
-- Add INLINE and SPECIALSE pragmas
--    INLINE prags are added to the (polymorphic) Id directly
--    SPECIALISE prags are passed to the desugarer via TcSpecPrags
-- Pre-condition: the poly_id is zonked
-- Reason: required by tcSubExp
tcSpecPrags poly_id prag_sigs
  = do { traceTc "tcSpecPrags" (ppr poly_id <+> ppr spec_sigs)
       ; unless (null bad_sigs) warn_discarded_sigs
       ; pss <- mapAndRecoverM (wrapLocM (tcSpecPrag poly_id)) spec_sigs
       ; return $ concatMap (\(L l ps) -> map (L l) ps) pss }
  where
    spec_sigs = filter isSpecLSig prag_sigs
    bad_sigs  = filter is_bad_sig prag_sigs
    is_bad_sig s = not (isSpecLSig s || isInlineLSig s)

    warn_discarded_sigs
      = addWarnTc NoReason
                  (hang (text "Discarding unexpected pragmas for" <+> ppr poly_id)
                      2 (vcat (map (ppr . getLoc) bad_sigs)))

--------------
tcSpecPrag :: TcId -> Sig Name -> TcM [TcSpecPrag]
tcSpecPrag poly_id prag@(SpecSig fun_name hs_tys inl)
-- See Note [Handling SPECIALISE pragmas]
--
-- The Name fun_name in the SpecSig may not be the same as that of the poly_id
-- Example: SPECIALISE for a class method: the Name in the SpecSig is
--          for the selector Id, but the poly_id is something like $cop
-- However we want to use fun_name in the error message, since that is
-- what the user wrote (Trac #8537)
  = addErrCtxt (spec_ctxt prag) $
    do  { warnIf NoReason (not (isOverloadedTy poly_ty || isInlinePragma inl))
                 (text "SPECIALISE pragma for non-overloaded function"
                  <+> quotes (ppr fun_name))
                  -- Note [SPECIALISE pragmas]
        ; spec_prags <- mapM tc_one hs_tys
        ; traceTc "tcSpecPrag" (ppr poly_id $$ nest 2 (vcat (map ppr spec_prags)))
        ; return spec_prags }
  where
    name      = idName poly_id
    poly_ty   = idType poly_id
    spec_ctxt prag = hang (text "In the SPECIALISE pragma") 2 (ppr prag)

    tc_one hs_ty
      = do { spec_ty <- tcHsSigType   (FunSigCtxt name False) hs_ty
           ; wrap    <- tcSpecWrapper (FunSigCtxt name True)  poly_ty spec_ty
           ; return (SpecPrag poly_id wrap inl) }

tcSpecPrag _ prag = pprPanic "tcSpecPrag" (ppr prag)

--------------
tcSpecWrapper :: UserTypeCtxt -> TcType -> TcType -> TcM HsWrapper
-- A simpler variant of tcSubType, used for SPECIALISE pragmas
-- See Note [Handling SPECIALISE pragmas], wrinkle 1
tcSpecWrapper ctxt poly_ty spec_ty
  = do { (sk_wrap, inst_wrap)
               <- tcSkolemise ctxt spec_ty $ \ _ spec_tau ->
                  do { (inst_wrap, tau) <- topInstantiate orig poly_ty
                     ; _ <- unifyType noThing spec_tau tau
                            -- Deliberately ignore the evidence
                            -- See Note [Handling SPECIALISE pragmas],
                            --   wrinkle (2)
                     ; return inst_wrap }
       ; return (sk_wrap <.> inst_wrap) }
  where
    orig = SpecPragOrigin ctxt

--------------
tcImpPrags :: [LSig Name] -> TcM [LTcSpecPrag]
-- SPECIALISE pragmas for imported things
tcImpPrags prags
  = do { this_mod <- getModule
       ; dflags <- getDynFlags
       ; if (not_specialising dflags) then
            return []
         else do
            { pss <- mapAndRecoverM (wrapLocM tcImpSpec)
                     [L loc (name,prag)
                               | (L loc prag@(SpecSig (L _ name) _ _)) <- prags
                               , not (nameIsLocalOrFrom this_mod name) ]
            ; return $ concatMap (\(L l ps) -> map (L l) ps) pss } }
  where
    -- Ignore SPECIALISE pragmas for imported things
    -- when we aren't specialising, or when we aren't generating
    -- code.  The latter happens when Haddocking the base library;
    -- we don't wnat complaints about lack of INLINABLE pragmas
    not_specialising dflags
      | not (gopt Opt_Specialise dflags) = True
      | otherwise = case hscTarget dflags of
                      HscNothing -> True
                      HscInterpreted -> True
                      _other         -> False

tcImpSpec :: (Name, Sig Name) -> TcM [TcSpecPrag]
tcImpSpec (name, prag)
 = do { id <- tcLookupId name
      ; unless (isAnyInlinePragma (idInlinePragma id))
               (addWarnTc NoReason (impSpecErr name))
      ; tcSpecPrag id prag }

impSpecErr :: Name -> SDoc
impSpecErr name
  = hang (text "You cannot SPECIALISE" <+> quotes (ppr name))
       2 (vcat [ text "because its definition has no INLINE/INLINABLE pragma"
               , parens $ sep
                   [ text "or its defining module" <+> quotes (ppr mod)
                   , text "was compiled without -O"]])
  where
    mod = nameModule name


{- *********************************************************************
*                                                                      *
                         Vectorisation
*                                                                      *
********************************************************************* -}

tcVectDecls :: [LVectDecl Name] -> TcM ([LVectDecl TcId])
tcVectDecls decls
  = do { decls' <- mapM (wrapLocM tcVect) decls
       ; let ids  = [lvectDeclName decl | decl <- decls', not $ lvectInstDecl decl]
             dups = findDupsEq (==) ids
       ; mapM_ reportVectDups dups
       ; traceTcConstraints "End of tcVectDecls"
       ; return decls'
       }
  where
    reportVectDups (first:_second:_more)
      = addErrAt (getSrcSpan first) $
          text "Duplicate vectorisation declarations for" <+> ppr first
    reportVectDups _ = return ()

--------------
tcVect :: VectDecl Name -> TcM (VectDecl TcId)
-- FIXME: We can't typecheck the expression of a vectorisation declaration against the vectorised
--   type of the original definition as this requires internals of the vectoriser not available
--   during type checking.  Instead, constrain the rhs of a vectorisation declaration to be a single
--   identifier (this is checked in 'rnHsVectDecl').  Fix this by enabling the use of 'vectType'
--   from the vectoriser here.
tcVect (HsVect s name rhs)
  = addErrCtxt (vectCtxt name) $
    do { var <- wrapLocM tcLookupId name
       ; let L rhs_loc (HsVar (L lv rhs_var_name)) = rhs
       ; rhs_id <- tcLookupId rhs_var_name
       ; return $ HsVect s var (L rhs_loc (HsVar (L lv rhs_id)))
       }

{- OLD CODE:
         -- turn the vectorisation declaration into a single non-recursive binding
       ; let bind    = L loc $ mkTopFunBind name [mkSimpleMatch [] rhs]
             sigFun  = const Nothing
             pragFun = emptyPragEnv

         -- perform type inference (including generalisation)
       ; (binds, [id'], _) <- tcPolyInfer False True sigFun pragFun NonRecursive [bind]

       ; traceTc "tcVect inferred type" $ ppr (varType id')
       ; traceTc "tcVect bindings"      $ ppr binds

         -- add all bindings, including the type variable and dictionary bindings produced by type
         -- generalisation to the right-hand side of the vectorisation declaration
       ; let [AbsBinds tvs evs _ evBinds actualBinds] = (map unLoc . bagToList) binds
       ; let [bind']                                  = bagToList actualBinds
             MatchGroup
               [L _ (Match _ _ (GRHSs [L _ (GRHS _ rhs')] _))]
               _                                      = (fun_matches . unLoc) bind'
             rhsWrapped                               = mkHsLams tvs evs (mkHsDictLet evBinds rhs')

        -- We return the type-checked 'Id', to propagate the inferred signature
        -- to the vectoriser - see "Note [Typechecked vectorisation pragmas]" in HsDecls
       ; return $ HsVect (L loc id') (Just rhsWrapped)
       }
 -}
tcVect (HsNoVect s name)
  = addErrCtxt (vectCtxt name) $
    do { var <- wrapLocM tcLookupId name
       ; return $ HsNoVect s var
       }
tcVect (HsVectTypeIn _ isScalar lname rhs_name)
  = addErrCtxt (vectCtxt lname) $
    do { tycon <- tcLookupLocatedTyCon lname
       ; checkTc (   not isScalar             -- either    we have a non-SCALAR declaration
                 || isJust rhs_name           -- or        we explicitly provide a vectorised type
                 || tyConArity tycon == 0     -- otherwise the type constructor must be nullary
                 )
                 scalarTyConMustBeNullary

       ; rhs_tycon <- fmapMaybeM (tcLookupTyCon . unLoc) rhs_name
       ; return $ HsVectTypeOut isScalar tycon rhs_tycon
       }
tcVect (HsVectTypeOut _ _ _)
  = panic "TcBinds.tcVect: Unexpected 'HsVectTypeOut'"
tcVect (HsVectClassIn _ lname)
  = addErrCtxt (vectCtxt lname) $
    do { cls <- tcLookupLocatedClass lname
       ; return $ HsVectClassOut cls
       }
tcVect (HsVectClassOut _)
  = panic "TcBinds.tcVect: Unexpected 'HsVectClassOut'"
tcVect (HsVectInstIn linstTy)
  = addErrCtxt (vectCtxt linstTy) $
    do { (cls, tys) <- tcHsVectInst linstTy
       ; inst       <- tcLookupInstance cls tys
       ; return $ HsVectInstOut inst
       }
tcVect (HsVectInstOut _)
  = panic "TcBinds.tcVect: Unexpected 'HsVectInstOut'"

vectCtxt :: Outputable thing => thing -> SDoc
vectCtxt thing = text "When checking the vectorisation declaration for" <+> ppr thing

scalarTyConMustBeNullary :: MsgDoc
scalarTyConMustBeNullary = text "VECTORISE SCALAR type constructor must be nullary"

{-
Note [SPECIALISE pragmas]
~~~~~~~~~~~~~~~~~~~~~~~~~
There is no point in a SPECIALISE pragma for a non-overloaded function:
   reverse :: [a] -> [a]
   {-# SPECIALISE reverse :: [Int] -> [Int] #-}

But SPECIALISE INLINE *can* make sense for GADTS:
   data Arr e where
     ArrInt :: !Int -> ByteArray# -> Arr Int
     ArrPair :: !Int -> Arr e1 -> Arr e2 -> Arr (e1, e2)

   (!:) :: Arr e -> Int -> e
   {-# SPECIALISE INLINE (!:) :: Arr Int -> Int -> Int #-}
   {-# SPECIALISE INLINE (!:) :: Arr (a, b) -> Int -> (a, b) #-}
   (ArrInt _ ba)     !: (I# i) = I# (indexIntArray# ba i)
   (ArrPair _ a1 a2) !: i      = (a1 !: i, a2 !: i)

When (!:) is specialised it becomes non-recursive, and can usefully
be inlined.  Scary!  So we only warn for SPECIALISE *without* INLINE
for a non-overloaded function.

************************************************************************
*                                                                      *
                         tcMonoBinds
*                                                                      *
************************************************************************

@tcMonoBinds@ deals with a perhaps-recursive group of HsBinds.
The signatures have been dealt with already.

Note [Pattern bindings]
~~~~~~~~~~~~~~~~~~~~~~~
The rule for typing pattern bindings is this:

    ..sigs..
    p = e

where 'p' binds v1..vn, and 'e' may mention v1..vn,
typechecks exactly like

    ..sigs..
    x = e       -- Inferred type
    v1 = case x of p -> v1
    ..
    vn = case x of p -> vn

Note that
    (f :: forall a. a -> a) = id
should not typecheck because
       case id of { (f :: forall a. a->a) -> f }
will not typecheck.

Note [Instantiate when inferring a type]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
  f = (*)
As there is no incentive to instantiate the RHS, tcMonoBinds will
produce a type of forall a. Num a => a -> a -> a for `f`. This will then go
through simplifyInfer and such, remaining unchanged.

There are two problems with this:
 1) If the definition were `g _ = (*)`, we get a very unusual type of
    `forall {a}. a -> forall b. Num b => b -> b -> b` for `g`. This is
    surely confusing for users.

 2) The monomorphism restriction can't work. The MR is dealt with in
    simplifyInfer, and simplifyInfer has no way of instantiating. This
    could perhaps be worked around, but it may be hard to know even
    when instantiation should happen.

There is an easy solution to both problems: instantiate (deeply) when
inferring a type. So that's what we do. Note that this decision is
user-facing.

We do this deep instantiation in tcMonoBinds, in the FunBind case
only, and only when we do not have a type signature.  Conveniently,
the fun_co_fn field of FunBind gives a place to record the coercion.

We do not need to do this
 * for PatBinds, because we don't have a function type
 * for FunBinds where we have a signature, bucause we aren't doing inference
-}

tcMonoBinds :: RecFlag  -- Whether the binding is recursive for typechecking purposes
                        -- i.e. the binders are mentioned in their RHSs, and
                        --      we are not rescued by a type signature
            -> TcSigFun -> LetBndrSpec
            -> [LHsBind Name]
            -> TcM (LHsBinds TcId, [MonoBindInfo])
tcMonoBinds is_rec sig_fn no_gen
           [ L b_loc (FunBind { fun_id = L nm_loc name,
                                fun_matches = matches, bind_fvs = fvs })]
                             -- Single function binding,
  | NonRecursive <- is_rec   -- ...binder isn't mentioned in RHS
  , Nothing <- sig_fn name   -- ...with no type signature
  =     -- In this very special case we infer the type of the
        -- right hand side first (it may have a higher-rank type)
        -- and *then* make the monomorphic Id for the LHS
        -- e.g.         f = \(x::forall a. a->a) -> <body>
        --      We want to infer a higher-rank type for f
    setSrcSpan b_loc    $
    do  { rhs_ty <- newOpenInferExpType
        ; (co_fn, matches')
            <- tcExtendIdBndrs [TcIdBndr_ExpType name rhs_ty NotTopLevel] $
                  -- We extend the error context even for a non-recursive
                  -- function so that in type error messages we show the
                  -- type of the thing whose rhs we are type checking
               tcMatchesFun name matches rhs_ty
        ; rhs_ty  <- readExpType rhs_ty

        -- Deeply instantiate the inferred type
        -- See Note [Instantiate when inferring a type]
        ; let orig = matchesCtOrigin matches
        ; rhs_ty <- zonkTcType rhs_ty -- NB: zonk to uncover any foralls
        ; (inst_wrap, rhs_ty) <- addErrCtxtM (instErrCtxt name rhs_ty) $
                                 deeplyInstantiate orig rhs_ty

        ; mono_id <- newNoSigLetBndr no_gen name rhs_ty
        ; return (unitBag $ L b_loc $
                     FunBind { fun_id = L nm_loc mono_id,
                               fun_matches = matches', bind_fvs = fvs,
                               fun_co_fn = inst_wrap <.> co_fn, fun_tick = [] },
                  [MBI { mbi_poly_name = name
                       , mbi_sig       = Nothing
                       , mbi_mono_id   = mono_id }]) }

tcMonoBinds _ sig_fn no_gen binds
  = do  { tc_binds <- mapM (wrapLocM (tcLhs sig_fn no_gen)) binds

        -- Bring the monomorphic Ids, into scope for the RHSs
        ; let mono_infos = getMonoBindInfo tc_binds
              rhs_id_env = [(name, mono_id) | MBI { mbi_poly_name = name
                                                  , mbi_sig       = mb_sig
                                                  , mbi_mono_id   = mono_id }
                                                    <- mono_infos
                                            , case mb_sig of
                                                Just sig -> isPartialSig sig
                                                Nothing  -> True ]
                    -- A monomorphic binding for each term variable that lacks
                    -- a type sig.  (Ones with a sig are already in scope.)

        ; traceTc "tcMonoBinds" $ vcat [ ppr n <+> ppr id <+> ppr (idType id)
                                       | (n,id) <- rhs_id_env]
        ; binds' <- tcExtendLetEnvIds NotTopLevel rhs_id_env $
                    mapM (wrapLocM tcRhs) tc_binds
        ; return (listToBag binds', mono_infos) }

------------------------
-- tcLhs typechecks the LHS of the bindings, to construct the environment in which
-- we typecheck the RHSs.  Basically what we are doing is this: for each binder:
--      if there's a signature for it, use the instantiated signature type
--      otherwise invent a type variable
-- You see that quite directly in the FunBind case.
--
-- But there's a complication for pattern bindings:
--      data T = MkT (forall a. a->a)
--      MkT f = e
-- Here we can guess a type variable for the entire LHS (which will be refined to T)
-- but we want to get (f::forall a. a->a) as the RHS environment.
-- The simplest way to do this is to typecheck the pattern, and then look up the
-- bound mono-ids.  Then we want to retain the typechecked pattern to avoid re-doing
-- it; hence the TcMonoBind data type in which the LHS is done but the RHS isn't

data TcMonoBind         -- Half completed; LHS done, RHS not done
  = TcFunBind  MonoBindInfo  SrcSpan (MatchGroup Name (LHsExpr Name))
  | TcPatBind [MonoBindInfo] (LPat TcId) (GRHSs Name (LHsExpr Name)) TcSigmaType

data MonoBindInfo = MBI { mbi_poly_name :: Name
                        , mbi_sig       :: Maybe TcIdSigInfo
                        , mbi_mono_id   :: TcId }

tcLhs :: TcSigFun -> LetBndrSpec -> HsBind Name -> TcM TcMonoBind
tcLhs sig_fn no_gen (FunBind { fun_id = L nm_loc name, fun_matches = matches })
  | Just (TcIdSig sig) <- sig_fn name
  , TISI { sig_tau = tau } <- sig
  = ASSERT2( case no_gen of { LetLclBndr -> True; LetGblBndr {} -> False }
           , ppr name )
       -- { f :: ty; f x = e } is always done via CheckGen (full signature)
       --                                      or InferGen (partial signature)
       --               see Note [Partial type signatures and generalisation]
       -- Both InferGen and CheckGen gives rise to LetLclBndr
    do  { mono_name <- newLocalName name
        ; let mono_id = mkLocalIdOrCoVar mono_name tau
        ; return (TcFunBind (MBI { mbi_poly_name = name
                                 , mbi_sig       = Just sig
                                 , mbi_mono_id   = mono_id })
                            nm_loc matches) }

  | otherwise
  = do  { mono_ty <- newOpenFlexiTyVarTy
        ; mono_id <- newNoSigLetBndr no_gen name mono_ty
        ; return (TcFunBind (MBI { mbi_poly_name = name
                                 , mbi_sig       = Nothing
                                 , mbi_mono_id   = mono_id })
                            nm_loc matches) }

tcLhs sig_fn no_gen (PatBind { pat_lhs = pat, pat_rhs = grhss })
  = do  { let tc_pat exp_ty = tcLetPat sig_fn no_gen pat exp_ty $
                              mapM lookup_info (collectPatBinders pat)

                -- After typechecking the pattern, look up the binder
                -- names, which the pattern has brought into scope.
              lookup_info :: Name -> TcM MonoBindInfo
              lookup_info name
                = do { mono_id <- tcLookupId name
                     ; let mb_sig = case sig_fn name of
                                      Just (TcIdSig sig) -> Just sig
                                      _                  -> Nothing
                     ; return (MBI { mbi_poly_name = name
                                   , mbi_sig       = mb_sig
                                   , mbi_mono_id   = mono_id }) }

        ; ((pat', infos), pat_ty) <- addErrCtxt (patMonoBindsCtxt pat grhss) $
                                     tcInfer tc_pat

        ; return (TcPatBind infos pat' grhss pat_ty) }

tcLhs _ _ other_bind = pprPanic "tcLhs" (ppr other_bind)
        -- AbsBind, VarBind impossible

-------------------
tcRhs :: TcMonoBind -> TcM (HsBind TcId)
tcRhs (TcFunBind info@(MBI { mbi_sig = mb_sig, mbi_mono_id = mono_id })
                 loc matches)
  = tcExtendIdBinderStackForRhs [info]  $
    tcExtendTyVarEnvForRhs mb_sig       $
    do  { traceTc "tcRhs: fun bind" (ppr mono_id $$ ppr (idType mono_id))
        ; (co_fn, matches') <- tcMatchesFun (idName mono_id)
                                 matches (mkCheckExpType $ idType mono_id)
        ; return ( FunBind { fun_id = L loc mono_id
                           , fun_matches = matches'
                           , fun_co_fn = co_fn
                           , bind_fvs = placeHolderNamesTc
                           , fun_tick = [] } ) }

-- TODO: emit Hole Constraints for wildcards
tcRhs (TcPatBind infos pat' grhss pat_ty)
  = -- When we are doing pattern bindings we *don't* bring any scoped
    -- type variables into scope unlike function bindings
    -- Wny not?  They are not completely rigid.
    -- That's why we have the special case for a single FunBind in tcMonoBinds
    tcExtendIdBinderStackForRhs infos        $
    do  { traceTc "tcRhs: pat bind" (ppr pat' $$ ppr pat_ty)
        ; grhss' <- addErrCtxt (patMonoBindsCtxt pat' grhss) $
                    tcGRHSsPat grhss pat_ty
        ; return ( PatBind { pat_lhs = pat', pat_rhs = grhss'
                           , pat_rhs_ty = pat_ty
                           , bind_fvs = placeHolderNamesTc
                           , pat_ticks = ([],[]) } )}

tcExtendTyVarEnvForRhs :: Maybe TcIdSigInfo -> TcM a -> TcM a
tcExtendTyVarEnvForRhs Nothing thing_inside
  = thing_inside
tcExtendTyVarEnvForRhs (Just sig) thing_inside
  = tcExtendTyVarEnvFromSig sig thing_inside

tcExtendTyVarEnvFromSig :: TcIdSigInfo -> TcM a -> TcM a
tcExtendTyVarEnvFromSig sig thing_inside
  | TISI { sig_bndr = s_bndr, sig_skols = skol_prs, sig_ctxt = ctxt } <- sig
  = tcExtendTyVarEnv2 skol_prs $
    case s_bndr of
      CompleteSig {}  -> thing_inside
      PartialSig { sig_wcs = wc_prs }  -- Extend the env ad emit the holes
                      -> tcExtendTyVarEnv2 wc_prs $
                         do { addErrCtxt (typeSigCtxt ctxt s_bndr) $
                              emitWildCardHoleConstraints wc_prs
                            ; thing_inside }

tcExtendIdBinderStackForRhs :: [MonoBindInfo] -> TcM a -> TcM a
-- Extend the TcIdBinderStack for the RHS of the binding, with
-- the monomorphic Id.  That way, if we have, say
--     f = \x -> blah
-- and something goes wrong in 'blah', we get a "relevant binding"
-- looking like  f :: alpha -> beta
-- This applies if 'f' has a type signature too:
--    f :: forall a. [a] -> [a]
--    f x = True
-- We can't unify True with [a], and a relevant binding is f :: [a] -> [a]
-- If we had the *polymorphic* version of f in the TcIdBinderStack, it
-- would not be reported as relevant, because its type is closed
tcExtendIdBinderStackForRhs infos thing_inside
  = tcExtendIdBndrs [ TcIdBndr mono_id NotTopLevel
                    | MBI { mbi_mono_id = mono_id } <- infos ]
                    thing_inside
    -- NotTopLevel: it's a monomorphic binding

---------------------
getMonoBindInfo :: [Located TcMonoBind] -> [MonoBindInfo]
getMonoBindInfo tc_binds
  = foldr (get_info . unLoc) [] tc_binds
  where
    get_info (TcFunBind info _ _)  rest = info : rest
    get_info (TcPatBind infos _ _ _) rest = infos ++ rest

{-
************************************************************************
*                                                                      *
                Signatures
*                                                                      *
************************************************************************

Type signatures are tricky.  See Note [Signature skolems] in TcType

@tcSigs@ checks the signatures for validity, and returns a list of
{\em freshly-instantiated} signatures.  That is, the types are already
split up, and have fresh type variables installed.  All non-type-signature
"RenamedSigs" are ignored.

The @TcSigInfo@ contains @TcTypes@ because they are unified with
the variable's type, and after that checked to see whether they've
been instantiated.

Note [Scoped tyvars]
~~~~~~~~~~~~~~~~~~~~
The -XScopedTypeVariables flag brings lexically-scoped type variables
into scope for any explicitly forall-quantified type variables:
        f :: forall a. a -> a
        f x = e
Then 'a' is in scope inside 'e'.

However, we do *not* support this
  - For pattern bindings e.g
        f :: forall a. a->a
        (f,g) = e

Note [Signature skolems]
~~~~~~~~~~~~~~~~~~~~~~~~
When instantiating a type signature, we do so with either skolems or
SigTv meta-type variables depending on the use_skols boolean.  This
variable is set True when we are typechecking a single function
binding; and False for pattern bindings and a group of several
function bindings.

Reason: in the latter cases, the "skolems" can be unified together,
        so they aren't properly rigid in the type-refinement sense.
NB: unless we are doing H98, each function with a sig will be done
    separately, even if it's mutually recursive, so use_skols will be True


Note [Only scoped tyvars are in the TyVarEnv]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We are careful to keep only the *lexically scoped* type variables in
the type environment.  Why?  After all, the renamer has ensured
that only legal occurrences occur, so we could put all type variables
into the type env.

But we want to check that two distinct lexically scoped type variables
do not map to the same internal type variable.  So we need to know which
the lexically-scoped ones are... and at the moment we do that by putting
only the lexically scoped ones into the environment.

Note [Instantiate sig with fresh variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's vital to instantiate a type signature with fresh variables.
For example:
      type T = forall a. [a] -> [a]
      f :: T;
      f = g where { g :: T; g = <rhs> }

 We must not use the same 'a' from the defn of T at both places!!
(Instantiation is only necessary because of type synonyms.  Otherwise,
it's all cool; each signature has distinct type variables from the renamer.)

Note [Fail eagerly on bad signatures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If a type signaure is wrong, fail immediately:

 * the type sigs may bind type variables, so proceeding without them
   can lead to a cascade of errors

 * the type signature might be ambiguous, in which case checking
   the code against the signature will give a very similar error
   to the ambiguity error.

ToDo: this means we fall over if any type sig
is wrong (eg at the top level of the module),
which is over-conservative
-}

tcTySigs :: [LSig Name] -> TcM ([TcId], TcSigFun)
tcTySigs hs_sigs
  = checkNoErrs $   -- See Note [Fail eagerly on bad signatures]
    do { ty_sigs_s <- mapAndRecoverM tcTySig hs_sigs
       ; let ty_sigs  = concat ty_sigs_s
             poly_ids = mapMaybe completeSigPolyId_maybe ty_sigs
                        -- The returned [TcId] are the ones for which we have
                        -- a complete type signature.
                        -- See Note [Complete and partial type signatures]
             env = mkNameEnv [(tcSigInfoName sig, sig) | sig <- ty_sigs]
       ; return (poly_ids, lookupNameEnv env) }

tcTySig :: LSig Name -> TcM [TcSigInfo]
tcTySig (L _ (IdSig id))
  = do { sig <- instTcTySigFromId id
       ; return [TcIdSig sig] }

tcTySig (L loc (TypeSig names sig_ty))
  = setSrcSpan loc $
    do { sigs <- sequence [ tcUserTypeSig sig_ty (Just name)
                          | L _ name <- names ]
       ; return (map TcIdSig sigs) }

tcTySig (L loc (PatSynSig (L _ name) sig_ty))
  = setSrcSpan loc $
    do { tpsi <- tcPatSynSig name sig_ty
       ; return [TcPatSynSig tpsi] }

tcTySig _ = return []

isCompleteHsSig :: LHsSigWcType Name -> Bool
-- ^ If there are no wildcards, return a LHsSigType
isCompleteHsSig sig_ty
  | HsWC { hswc_wcs = wcs, hswc_ctx = extra } <- hsib_body sig_ty
  , null wcs
  , Nothing <- extra
  = True
  | otherwise
  = False

tcUserTypeSig :: LHsSigWcType Name -> Maybe Name -> TcM TcIdSigInfo
-- Just n  => Function type signatre        name :: type
-- Nothing => Expression type signature   <expr> :: type
tcUserTypeSig hs_sig_ty mb_name
  | isCompleteHsSig hs_sig_ty
  = pushTcLevelM_  $  -- When instantiating the signature, do so "one level in"
                      -- so that they can be unified under the forall
    do { sigma_ty <- tcHsSigWcType ctxt_F hs_sig_ty
       ; (inst_tvs, theta, tau) <- tcInstType tcInstSigTyVars sigma_ty
       ; loc <- getSrcSpanM
       ; return $
         TISI { sig_bndr  = CompleteSig (mkLocalId name sigma_ty)
              , sig_skols = findScopedTyVars sigma_ty inst_tvs
              , sig_theta = theta
              , sig_tau   = tau
              , sig_ctxt  = ctxt_T
              , sig_loc   = loc } }

  -- Partial sig with wildcards
  | HsIB { hsib_vars = vars, hsib_body = wc_ty } <- hs_sig_ty
  , HsWC { hswc_wcs = wcs, hswc_ctx = extra, hswc_body = hs_ty } <- wc_ty
  , (hs_tvs, L _ hs_ctxt, hs_tau) <- splitLHsSigmaTy hs_ty
  = do { (vars1, (wcs, tvs2, theta, tau))
           <- pushTcLevelM_  $
                  -- When instantiating the signature, do so "one level in"
                  -- so that they can be unified under the forall
              tcImplicitTKBndrs vars $
              tcWildCardBinders wcs  $ \ wcs ->
              tcExplicitTKBndrs hs_tvs  $ \ tvs2 ->
         do { -- Instantiate the type-class context; but if there
              -- is an extra-constraints wildcard, just discard it here
              traceTc "tcPartial" (ppr name $$ ppr vars $$ ppr wcs)
            ; theta <- mapM tcLHsPredType $
                       case extra of
                         Nothing -> hs_ctxt
                         Just _  -> dropTail 1 hs_ctxt

            ; tau <- tcHsOpenType hs_tau

                -- zonking is necessary to establish type representation
                -- invariants
            ; theta <- zonkTcTypes theta
            ; tau   <- zonkTcType tau

              -- Check for validity (eg rankN etc)
              -- The ambiguity check will happen (from checkValidType),
              -- but unnecessarily; it will always succeed because there
              -- is no quantification
            ; checkValidType ctxt_F (mkPhiTy theta tau)
                -- NB: Do this in the context of the pushTcLevel so that
                -- the TcLevel invariant is respected

            ; let bound_tvs
                    = unionVarSets [ allBoundVariabless theta
                                   , allBoundVariables tau
                                   , mkVarSet (map snd wcs) ]
            ; return ((wcs, tvs2, theta, tau), bound_tvs) }

       ; loc <- getSrcSpanM
       ; return $
         TISI { sig_bndr  = PartialSig { sig_name = name, sig_hs_ty = hs_ty
                                       , sig_cts = extra, sig_wcs = wcs }
              , sig_skols = [ (tyVarName tv, tv) | tv <- vars1 ++ tvs2 ]
              , sig_theta = theta
              , sig_tau   = tau
              , sig_ctxt  = ctxt_F
              , sig_loc   = loc } }
  where
    name   = case mb_name of
               Just n  -> n
               Nothing -> mkUnboundName (mkVarOcc "<expression>")
    ctxt_F = case mb_name of
               Just n  -> FunSigCtxt n False
               Nothing -> ExprSigCtxt
    ctxt_T = case mb_name of
               Just n  -> FunSigCtxt n True
               Nothing -> ExprSigCtxt

instTcTySigFromId :: Id -> TcM TcIdSigInfo
-- Used for instance methods and record selectors
instTcTySigFromId id
  = do { let name = idName id
             loc  = getSrcSpan name
       ; (tvs, theta, tau) <- tcInstType (tcInstSigTyVarsLoc loc)
                                         (idType id)
       ; return $ TISI { sig_bndr  = CompleteSig id
                       , sig_skols = [(tyVarName tv, tv) | tv <- tvs]
                          -- These are freshly instantiated, so although
                          -- we put them in the type envt, doing so has
                          -- no effect
                       , sig_theta = theta
                       , sig_tau   = tau
                       , sig_ctxt  = FunSigCtxt name False
                          -- False: do not report redundant constraints
                          -- The user has no control over the signature!
                       , sig_loc   = loc } }

instTcTySig :: UserTypeCtxt
            -> LHsSigType Name         -- Used to get the scoped type variables
            -> TcType
            -> Name                      -- Name of the function
            -> TcM TcIdSigInfo
instTcTySig ctxt hs_ty sigma_ty name
  = do { (inst_tvs, theta, tau) <- tcInstType tcInstSigTyVars sigma_ty
       ; return (TISI { sig_bndr  = CompleteSig (mkLocalIdOrCoVar name sigma_ty)
                      , sig_skols = findScopedTyVars sigma_ty inst_tvs
                      , sig_theta = theta
                      , sig_tau   = tau
                      , sig_ctxt  = ctxt
                      , sig_loc   = getLoc (hsSigType hs_ty)
                                    -- SrcSpan from the signature
               }) }

-------------------------------
data GeneralisationPlan
  = NoGen               -- No generalisation, no AbsBinds

  | InferGen            -- Implicit generalisation; there is an AbsBinds
       Bool             --   True <=> apply the MR; generalise only unconstrained type vars

  | CheckGen (LHsBind Name) TcIdSigInfo
                        -- One FunBind with a signature
                        -- Explicit generalisation; there is an AbsBindsSig

-- A consequence of the no-AbsBinds choice (NoGen) is that there is
-- no "polymorphic Id" and "monmomorphic Id"; there is just the one

instance Outputable GeneralisationPlan where
  ppr NoGen          = text "NoGen"
  ppr (InferGen b)   = text "InferGen" <+> ppr b
  ppr (CheckGen _ s) = text "CheckGen" <+> ppr s

decideGeneralisationPlan
   :: DynFlags -> TcTypeEnv -> [Name]
   -> [LHsBind Name] -> TcSigFun -> GeneralisationPlan
decideGeneralisationPlan dflags type_env bndr_names lbinds sig_fn
  | unlifted_pat_binds                    = NoGen
  | Just bind_sig <- one_funbind_with_sig = sig_plan bind_sig
  | mono_local_binds                      = NoGen
  | otherwise                             = InferGen mono_restriction
  where
    bndr_set = mkNameSet bndr_names
    binds = map unLoc lbinds

    sig_plan :: (LHsBind Name, TcIdSigInfo) -> GeneralisationPlan
    -- See Note [Partial type signatures and generalisation]
    -- We use InferGen False to say "do inference, but do not apply
    -- the MR".  It's stupid to apply the MR when we are given a
    -- signature!  C.f Trac #11016, function f2
    sig_plan (lbind, sig@(TISI { sig_bndr = s_bndr, sig_theta = theta }))
      = case s_bndr of
          CompleteSig {} -> CheckGen lbind sig
          PartialSig { sig_cts = extra_constraints }
             | Nothing <- extra_constraints
             , []      <- theta
             -> InferGen True   -- No signature constraints: apply the MR
             | otherwise
             -> InferGen False  -- Don't apply the MR

    unlifted_pat_binds = any isUnliftedHsBind binds
       -- Unlifted patterns (unboxed tuple) must not
       -- be polymorphic, because we are going to force them
       -- See Trac #4498, #8762

    mono_restriction  = xopt LangExt.MonomorphismRestriction dflags
                     && any restricted binds

    is_closed_ns :: NameSet -> Bool -> Bool
    is_closed_ns ns b = foldNameSet ((&&) . is_closed_id) b ns
        -- ns are the Names referred to from the RHS of this bind

    is_closed_id :: Name -> Bool
    -- See Note [Bindings with closed types] in TcRnTypes
    is_closed_id name
      | name `elemNameSet` bndr_set
      = True              -- Ignore binders in this groups, of course
      | Just thing <- lookupNameEnv type_env name
      = case thing of
          ATcId { tct_closed = cl } -> isTopLevel cl  -- This is the key line
          ATyVar {}                 -> False          -- In-scope type variables
          AGlobal {}                -> True           --    are not closed!
          _                         -> pprPanic "is_closed_id" (ppr name)
      | otherwise
      = WARN( isInternalName name, ppr name ) True
        -- The free-var set for a top level binding mentions
        -- imported things too, so that we can report unused imports
        -- These won't be in the local type env.
        -- Ditto class method etc from the current module

    mono_local_binds = xopt LangExt.MonoLocalBinds dflags
                    && not closed_flag

    closed_flag = foldr (is_closed_ns . bind_fvs) True binds

    no_sig n = noCompleteSig (sig_fn n)

    -- With OutsideIn, all nested bindings are monomorphic
    -- except a single function binding with a signature
    one_funbind_with_sig
      | [lbind@(L _ (FunBind { fun_id = v }))] <- lbinds
      , Just (TcIdSig sig) <- sig_fn (unLoc v)
      = Just (lbind, sig)
      | otherwise
      = Nothing

    -- The Haskell 98 monomorphism resetriction
    restricted (PatBind {})                              = True
    restricted (VarBind { var_id = v })                  = no_sig v
    restricted (FunBind { fun_id = v, fun_matches = m }) = restricted_match m
                                                           && no_sig (unLoc v)
    restricted (PatSynBind {}) = panic "isRestrictedGroup/unrestricted PatSynBind"
    restricted (AbsBinds {}) = panic "isRestrictedGroup/unrestricted AbsBinds"
    restricted (AbsBindsSig {}) = panic "isRestrictedGroup/unrestricted AbsBindsSig"

    restricted_match (MG { mg_alts = L _ (L _ (Match _ [] _ _) : _ )}) = True
    restricted_match _                                                 = False
        -- No args => like a pattern binding
        -- Some args => a function binding

-------------------
checkStrictBinds :: TopLevelFlag -> RecFlag
                 -> [LHsBind Name]
                 -> LHsBinds TcId -> [Id]
                 -> TcM ()
-- Check that non-overloaded unlifted bindings are
--      a) non-recursive,
--      b) not top level,
--      c) not a multiple-binding group (more or less implied by (a))

checkStrictBinds top_lvl rec_group orig_binds tc_binds poly_ids
  | any_unlifted_bndr || any_strict_pat   -- This binding group must be matched strictly
  = do  { check (isNotTopLevel top_lvl)
                (strictBindErr "Top-level" any_unlifted_bndr orig_binds)
        ; check (isNonRec rec_group)
                (strictBindErr "Recursive" any_unlifted_bndr orig_binds)

        ; check (all is_monomorphic (bagToList tc_binds))
                  (polyBindErr orig_binds)
            -- data Ptr a = Ptr Addr#
            -- f x = let p@(Ptr y) = ... in ...
            -- Here the binding for 'p' is polymorphic, but does
            -- not mix with an unlifted binding for 'y'.  You should
            -- use a bang pattern.  Trac #6078.

        ; check (isSingleton orig_binds)
                (strictBindErr "Multiple" any_unlifted_bndr orig_binds)

        -- Complain about a binding that looks lazy
        --    e.g.    let I# y = x in ...
        -- Remember, in checkStrictBinds we are going to do strict
        -- matching, so (for software engineering reasons) we insist
        -- that the strictness is manifest on each binding
        -- However, lone (unboxed) variables are ok
        ; check (not any_pat_looks_lazy)
                  (unliftedMustBeBang orig_binds) }
  | otherwise
  = traceTc "csb2" (ppr [(id, idType id) | id <- poly_ids]) >>
    return ()
  where
    any_unlifted_bndr  = any is_unlifted poly_ids
    any_strict_pat     = any (isUnliftedHsBind . unLoc) orig_binds
    any_pat_looks_lazy = any (looksLazyPatBind . unLoc) orig_binds

    is_unlifted id = case tcSplitSigmaTy (idType id) of
                       (_, _, rho) -> isUnliftedType rho
          -- For the is_unlifted check, we need to look inside polymorphism
          -- and overloading.  E.g.  x = (# 1, True #)
          -- would get type forall a. Num a => (# a, Bool #)
          -- and we want to reject that.  See Trac #9140

    is_monomorphic (L _ (AbsBinds { abs_tvs = tvs, abs_ev_vars = evs }))
                     = null tvs && null evs
    is_monomorphic (L _ (AbsBindsSig { abs_tvs = tvs, abs_ev_vars = evs }))
                     = null tvs && null evs
    is_monomorphic _ = True

    check :: Bool -> MsgDoc -> TcM ()
    -- Just like checkTc, but with a special case for module GHC.Prim:
    --      see Note [Compiling GHC.Prim]
    check True  _   = return ()
    check False err = do { mod <- getModule
                         ; checkTc (mod == gHC_PRIM) err }

unliftedMustBeBang :: [LHsBind Name] -> SDoc
unliftedMustBeBang binds
  = hang (text "Pattern bindings containing unlifted types should use an outermost bang pattern:")
       2 (vcat (map ppr binds))

polyBindErr :: [LHsBind Name] -> SDoc
polyBindErr binds
  = hang (text "You can't mix polymorphic and unlifted bindings")
       2 (vcat [vcat (map ppr binds),
                text "Probable fix: add a type signature"])

strictBindErr :: String -> Bool -> [LHsBind Name] -> SDoc
strictBindErr flavour any_unlifted_bndr binds
  = hang (text flavour <+> msg <+> text "aren't allowed:")
       2 (vcat (map ppr binds))
  where
    msg | any_unlifted_bndr = text "bindings for unlifted types"
        | otherwise         = text "bang-pattern or unboxed-tuple bindings"


{- Note [Compiling GHC.Prim]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Module GHC.Prim has no source code: it is the host module for
primitive, built-in functions and types.  However, for Haddock-ing
purposes we generate (via utils/genprimopcode) a fake source file
GHC/Prim.hs, and give it to Haddock, so that it can generate
documentation.  It contains definitions like
    nullAddr# :: NullAddr#
which would normally be rejected as a top-level unlifted binding. But
we don't want to complain, because we are only "compiling" this fake
mdule for documentation purposes.  Hence this hacky test for gHC_PRIM
in checkStrictBinds.

(We only make the test if things look wrong, so there is no cost in
the common case.) -}


{- *********************************************************************
*                                                                      *
               Error contexts and messages
*                                                                      *
********************************************************************* -}

-- This one is called on LHS, when pat and grhss are both Name
-- and on RHS, when pat is TcId and grhss is still Name
patMonoBindsCtxt :: (OutputableBndr id, Outputable body) => LPat id -> GRHSs Name body -> SDoc
patMonoBindsCtxt pat grhss
  = hang (text "In a pattern binding:") 2 (pprPatBind pat grhss)

typeSigCtxt :: UserTypeCtxt -> TcIdSigBndr -> SDoc
typeSigCtxt ctxt (PartialSig { sig_hs_ty = hs_ty })
  = pprSigCtxt ctxt empty (ppr hs_ty)
typeSigCtxt ctxt (CompleteSig id)
  = pprSigCtxt ctxt empty (ppr (idType id))

instErrCtxt :: Name -> TcType -> TidyEnv -> TcM (TidyEnv, SDoc)
instErrCtxt name ty env
  = do { let (env', ty') = tidyOpenType env ty
       ; return (env', hang (text "When instantiating" <+> quotes (ppr name) <>
                             text ", initially inferred to have" $$
                             text "this overly-general type:")
                          2 (ppr ty') $$
                       extra) }
  where
    extra = sdocWithDynFlags $ \dflags ->
            ppWhen (xopt LangExt.MonomorphismRestriction dflags) $
            text "NB: This instantiation can be caused by the" <+>
            text "monomorphism restriction."
