{-
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[RnExpr]{Renaming of expressions}

Basically dependency analysis.

Handles @Match@, @GRHSs@, @HsExpr@, and @Qualifier@ datatypes.  In
general, all of these functions return a renamed thing, and a set of
free variables.
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf #-}

module RnExpr (
        rnLExpr, rnExpr, rnStmts
   ) where

#include "HsVersions.h"

import RnBinds   ( rnLocalBindsAndThen, rnLocalValBindsLHS, rnLocalValBindsRHS,
                   rnMatchGroup, rnGRHS, makeMiniFixityEnv)
import HsSyn
import TcRnMonad
import Module           ( getModule )
import RnEnv
import RnSplice         ( rnBracket, rnSpliceExpr, checkThLocalName )
import RnTypes
import RnPat
import DynFlags
import PrelNames

import BasicTypes
import Name
import NameSet
import RdrName
import UniqSet
import Data.List
import Util
import ListSetOps       ( removeDups )
import ErrUtils
import Outputable
import SrcLoc
import FastString
import Control.Monad
import TysWiredIn       ( nilDataConName )
import qualified GHC.LanguageExtensions as LangExt

{-
************************************************************************
*                                                                      *
\subsubsection{Expressions}
*                                                                      *
************************************************************************
-}

rnExprs :: [LHsExpr RdrName] -> RnM ([LHsExpr Name], FreeVars)
rnExprs ls = rnExprs' ls emptyUniqSet
 where
  rnExprs' [] acc = return ([], acc)
  rnExprs' (expr:exprs) acc =
   do { (expr', fvExpr) <- rnLExpr expr
        -- Now we do a "seq" on the free vars because typically it's small
        -- or empty, especially in very long lists of constants
      ; let  acc' = acc `plusFV` fvExpr
      ; (exprs', fvExprs) <- acc' `seq` rnExprs' exprs acc'
      ; return (expr':exprs', fvExprs) }

-- Variables. We look up the variable and return the resulting name.

rnLExpr :: LHsExpr RdrName -> RnM (LHsExpr Name, FreeVars)
rnLExpr = wrapLocFstM rnExpr

rnExpr :: HsExpr RdrName -> RnM (HsExpr Name, FreeVars)

finishHsVar :: Located Name -> RnM (HsExpr Name, FreeVars)
-- Separated from rnExpr because it's also used
-- when renaming infix expressions
finishHsVar (L l name)
 = do { this_mod <- getModule
      ; when (nameIsLocalOrFrom this_mod name) $
        checkThLocalName name
      ; return (HsVar (L l name), unitFV name) }

rnUnboundVar :: RdrName -> RnM (HsExpr Name, FreeVars)
rnUnboundVar v
 = do { if isUnqual v
        then -- Treat this as a "hole"
             -- Do not fail right now; instead, return HsUnboundVar
             -- and let the type checker report the error
             do { let occ = rdrNameOcc v
                ; uv <- if startsWithUnderscore occ
                        then return (TrueExprHole occ)
                        else OutOfScope occ <$> getGlobalRdrEnv
                ; return (HsUnboundVar uv, emptyFVs) }

        else -- Fail immediately (qualified name)
             do { n <- reportUnboundName v
                ; return (HsVar (noLoc n), emptyFVs) } }

rnExpr (HsVar (L l v))
  = do { opt_DuplicateRecordFields <- xoptM LangExt.DuplicateRecordFields
       ; mb_name <- lookupOccRn_overloaded opt_DuplicateRecordFields v
       ; case mb_name of {
           Nothing -> rnUnboundVar v ;
           Just (Left name)
              | name == nilDataConName -- Treat [] as an ExplicitList, so that
                                       -- OverloadedLists works correctly
              -> rnExpr (ExplicitList placeHolderType Nothing [])

              | otherwise
              -> finishHsVar (L l name) ;
            Just (Right [f@(FieldOcc (L _ fn) s)]) ->
                      return (HsRecFld (ambiguousFieldOcc (FieldOcc (L l fn) s))
                             , unitFV (selectorFieldOcc f)) ;
           Just (Right fs@(_:_:_)) -> return (HsRecFld (Ambiguous (L l v)
                                                        PlaceHolder)
                                             , mkFVs (map selectorFieldOcc fs));
           Just (Right [])         -> error "runExpr/HsVar" } }

rnExpr (HsIPVar v)
  = return (HsIPVar v, emptyFVs)

rnExpr (HsOverLabel v)
  = return (HsOverLabel v, emptyFVs)

rnExpr (HsLit lit@(HsString src s))
  = do { opt_OverloadedStrings <- xoptM LangExt.OverloadedStrings
       ; if opt_OverloadedStrings then
            rnExpr (HsOverLit (mkHsIsString src s placeHolderType))
         else do {
            ; rnLit lit
            ; return (HsLit lit, emptyFVs) } }

rnExpr (HsLit lit)
  = do { rnLit lit
       ; return (HsLit lit, emptyFVs) }

rnExpr (HsOverLit lit)
  = do { (lit', fvs) <- rnOverLit lit
       ; return (HsOverLit lit', fvs) }

rnExpr (HsApp fun arg)
  = do { (fun',fvFun) <- rnLExpr fun
       ; (arg',fvArg) <- rnLExpr arg
       ; return (HsApp fun' arg', fvFun `plusFV` fvArg) }

rnExpr (HsAppType fun arg)
  = do { (fun',fvFun) <- rnLExpr fun
       ; (arg',fvArg) <- rnHsWcType HsTypeCtx arg
       ; return (HsAppType fun' arg', fvFun `plusFV` fvArg) }

rnExpr (OpApp e1 op  _ e2)
  = do  { (e1', fv_e1) <- rnLExpr e1
        ; (e2', fv_e2) <- rnLExpr e2
        ; (op', fv_op) <- rnLExpr op

        -- Deal with fixity
        -- When renaming code synthesised from "deriving" declarations
        -- we used to avoid fixity stuff, but we can't easily tell any
        -- more, so I've removed the test.  Adding HsPars in TcGenDeriv
        -- should prevent bad things happening.
        ; fixity <- case op' of
              L _ (HsVar (L _ n)) -> lookupFixityRn n
              L _ (HsRecFld f)    -> lookupFieldFixityRn f
              _ -> return (Fixity (show minPrecedence) minPrecedence InfixL)
                   -- c.f. lookupFixity for unbound

        ; final_e <- mkOpAppRn e1' op' fixity e2'
        ; return (final_e, fv_e1 `plusFV` fv_op `plusFV` fv_e2) }

rnExpr (NegApp e _)
  = do { (e', fv_e)         <- rnLExpr e
       ; (neg_name, fv_neg) <- lookupSyntaxName negateName
       ; final_e            <- mkNegAppRn e' neg_name
       ; return (final_e, fv_e `plusFV` fv_neg) }

------------------------------------------
-- Template Haskell extensions
-- Don't ifdef-GHCI them because we want to fail gracefully
-- (not with an rnExpr crash) in a stage-1 compiler.
rnExpr e@(HsBracket br_body) = rnBracket e br_body

rnExpr (HsSpliceE splice) = rnSpliceExpr splice

---------------------------------------------
--      Sections
-- See Note [Parsing sections] in Parser.y
rnExpr (HsPar (L loc (section@(SectionL {}))))
  = do  { (section', fvs) <- rnSection section
        ; return (HsPar (L loc section'), fvs) }

rnExpr (HsPar (L loc (section@(SectionR {}))))
  = do  { (section', fvs) <- rnSection section
        ; return (HsPar (L loc section'), fvs) }

rnExpr (HsPar e)
  = do  { (e', fvs_e) <- rnLExpr e
        ; return (HsPar e', fvs_e) }

rnExpr expr@(SectionL {})
  = do  { addErr (sectionErr expr); rnSection expr }
rnExpr expr@(SectionR {})
  = do  { addErr (sectionErr expr); rnSection expr }

---------------------------------------------
rnExpr (HsCoreAnn src ann expr)
  = do { (expr', fvs_expr) <- rnLExpr expr
       ; return (HsCoreAnn src ann expr', fvs_expr) }

rnExpr (HsSCC src lbl expr)
  = do { (expr', fvs_expr) <- rnLExpr expr
       ; return (HsSCC src lbl expr', fvs_expr) }
rnExpr (HsTickPragma src info srcInfo expr)
  = do { (expr', fvs_expr) <- rnLExpr expr
       ; return (HsTickPragma src info srcInfo expr', fvs_expr) }

rnExpr (HsLam matches)
  = do { (matches', fvMatch) <- rnMatchGroup LambdaExpr rnLExpr matches
       ; return (HsLam matches', fvMatch) }

rnExpr (HsLamCase _arg matches)
  = do { (matches', fvs_ms) <- rnMatchGroup CaseAlt rnLExpr matches
       -- ; return (HsLamCase arg matches', fvs_ms) }
       ; return (HsLamCase placeHolderType matches', fvs_ms) }

rnExpr (HsCase expr matches)
  = do { (new_expr, e_fvs) <- rnLExpr expr
       ; (new_matches, ms_fvs) <- rnMatchGroup CaseAlt rnLExpr matches
       ; return (HsCase new_expr new_matches, e_fvs `plusFV` ms_fvs) }

rnExpr (HsLet (L l binds) expr)
  = rnLocalBindsAndThen binds $ \binds' _ -> do
      { (expr',fvExpr) <- rnLExpr expr
      ; return (HsLet (L l binds') expr', fvExpr) }

rnExpr (HsDo do_or_lc (L l stmts) _)
  = do  { ((stmts', _), fvs) <-
           rnStmtsWithPostProcessing do_or_lc rnLExpr
             postProcessStmtsForApplicativeDo stmts
             (\ _ -> return ((), emptyFVs))
        ; return ( HsDo do_or_lc (L l stmts') placeHolderType, fvs ) }

rnExpr (ExplicitList _ _  exps)
  = do  { opt_OverloadedLists <- xoptM LangExt.OverloadedLists
        ; (exps', fvs) <- rnExprs exps
        ; if opt_OverloadedLists
           then do {
            ; (from_list_n_name, fvs') <- lookupSyntaxName fromListNName
            ; return (ExplicitList placeHolderType (Just from_list_n_name) exps'
                     , fvs `plusFV` fvs') }
           else
            return  (ExplicitList placeHolderType Nothing exps', fvs) }

rnExpr (ExplicitPArr _ exps)
  = do { (exps', fvs) <- rnExprs exps
       ; return  (ExplicitPArr placeHolderType exps', fvs) }

rnExpr (ExplicitTuple tup_args boxity)
  = do { checkTupleSection tup_args
       ; checkTupSize (length tup_args)
       ; (tup_args', fvs) <- mapAndUnzipM rnTupArg tup_args
       ; return (ExplicitTuple tup_args' boxity, plusFVs fvs) }
  where
    rnTupArg (L l (Present e)) = do { (e',fvs) <- rnLExpr e
                                    ; return (L l (Present e'), fvs) }
    rnTupArg (L l (Missing _)) = return (L l (Missing placeHolderType)
                                        , emptyFVs)

rnExpr (RecordCon { rcon_con_name = con_id
                  , rcon_flds = rec_binds@(HsRecFields { rec_dotdot = dd }) })
  = do { con_lname@(L _ con_name) <- lookupLocatedOccRn con_id
       ; (flds, fvs)   <- rnHsRecFields (HsRecFieldCon con_name) mk_hs_var rec_binds
       ; (flds', fvss) <- mapAndUnzipM rn_field flds
       ; let rec_binds' = HsRecFields { rec_flds = flds', rec_dotdot = dd }
       ; return (RecordCon { rcon_con_name = con_lname, rcon_flds = rec_binds'
                           , rcon_con_expr = noPostTcExpr, rcon_con_like = PlaceHolder }
                , fvs `plusFV` plusFVs fvss `addOneFV` con_name) }
  where
    mk_hs_var l n = HsVar (L l n)
    rn_field (L l fld) = do { (arg', fvs) <- rnLExpr (hsRecFieldArg fld)
                            ; return (L l (fld { hsRecFieldArg = arg' }), fvs) }

rnExpr (RecordUpd { rupd_expr = expr, rupd_flds = rbinds })
  = do  { (expr', fvExpr) <- rnLExpr expr
        ; (rbinds', fvRbinds) <- rnHsRecUpdFields rbinds
        ; return (RecordUpd { rupd_expr = expr', rupd_flds = rbinds'
                            , rupd_cons    = PlaceHolder, rupd_in_tys = PlaceHolder
                            , rupd_out_tys = PlaceHolder, rupd_wrap   = PlaceHolder }
                 , fvExpr `plusFV` fvRbinds) }

rnExpr (ExprWithTySig expr pty)
  = do  { (pty', fvTy)    <- rnHsSigWcType ExprWithTySigCtx pty
        ; (expr', fvExpr) <- bindSigTyVarsFV (hsWcScopedTvs pty') $
                             rnLExpr expr
        ; return (ExprWithTySig expr' pty', fvExpr `plusFV` fvTy) }

rnExpr (HsIf _ p b1 b2)
  = do { (p', fvP) <- rnLExpr p
       ; (b1', fvB1) <- rnLExpr b1
       ; (b2', fvB2) <- rnLExpr b2
       ; (mb_ite, fvITE) <- lookupIfThenElse
       ; return (HsIf mb_ite p' b1' b2', plusFVs [fvITE, fvP, fvB1, fvB2]) }

rnExpr (HsMultiIf _ty alts)
  = do { (alts', fvs) <- mapFvRn (rnGRHS IfAlt rnLExpr) alts
       -- ; return (HsMultiIf ty alts', fvs) }
       ; return (HsMultiIf placeHolderType alts', fvs) }

rnExpr (ArithSeq _ _ seq)
  = do { opt_OverloadedLists <- xoptM LangExt.OverloadedLists
       ; (new_seq, fvs) <- rnArithSeq seq
       ; if opt_OverloadedLists
           then do {
            ; (from_list_name, fvs') <- lookupSyntaxName fromListName
            ; return (ArithSeq noPostTcExpr (Just from_list_name) new_seq, fvs `plusFV` fvs') }
           else
            return (ArithSeq noPostTcExpr Nothing new_seq, fvs) }

rnExpr (PArrSeq _ seq)
  = do { (new_seq, fvs) <- rnArithSeq seq
       ; return (PArrSeq noPostTcExpr new_seq, fvs) }

{-
These three are pattern syntax appearing in expressions.
Since all the symbols are reservedops we can simply reject them.
We return a (bogus) EWildPat in each case.
-}

rnExpr EWildPat        = return (hsHoleExpr, emptyFVs)   -- "_" is just a hole
rnExpr e@(EAsPat {})   = patSynErr e
rnExpr e@(EViewPat {}) = patSynErr e
rnExpr e@(ELazyPat {}) = patSynErr e

{-
************************************************************************
*                                                                      *
        Static values
*                                                                      *
************************************************************************

For the static form we check that the free variables are all top-level
value bindings. This is done by checking that the name is external or
wired-in. See the Notes about the NameSorts in Name.hs.
-}

rnExpr e@(HsStatic expr) = do
    target <- fmap hscTarget getDynFlags
    case target of
      -- SPT entries are expected to exist in object code so far, and this is
      -- not the case in interpreted mode. See bug #9878.
      HscInterpreted -> addErr $ sep
        [ text "The static form is not supported in interpreted mode."
        , text "Please use -fobject-code."
        ]
      _ -> return ()
    (expr',fvExpr) <- rnLExpr expr
    stage <- getStage
    case stage of
      Brack _ _ -> return () -- Don't check names if we are inside brackets.
                             -- We don't want to reject cases like:
                             -- \e -> [| static $(e) |]
                             -- if $(e) turns out to produce a legal expression.
      Splice _ -> addErr $ sep
             [ text "static forms cannot be used in splices:"
             , nest 2 $ ppr e
             ]
      _ -> do
       let isTopLevelName n = isExternalName n || isWiredInName n
       case nameSetElems $ filterNameSet
                             (\n -> not (isTopLevelName n || isUnboundName n))
                             fvExpr                                           of
         [] -> return ()
         fvNonGlobal -> addErr $ cat
             [ text $ "Only identifiers of top-level bindings can "
                      ++ "appear in the body of the static form:"
             , nest 2 $ ppr e
             , text "but the following identifiers were found instead:"
             , nest 2 $ vcat $ map ppr fvNonGlobal
             ]
    return (HsStatic expr', fvExpr)

{-
************************************************************************
*                                                                      *
        Arrow notation
*                                                                      *
************************************************************************
-}

rnExpr (HsProc pat body)
  = newArrowScope $
    rnPat ProcExpr pat $ \ pat' -> do
      { (body',fvBody) <- rnCmdTop body
      ; return (HsProc pat' body', fvBody) }

-- Ideally, these would be done in parsing, but to keep parsing simple, we do it here.
rnExpr e@(HsArrApp {})  = arrowFail e
rnExpr e@(HsArrForm {}) = arrowFail e

rnExpr other = pprPanic "rnExpr: unexpected expression" (ppr other)
        -- HsWrap

hsHoleExpr :: HsExpr id
hsHoleExpr = HsUnboundVar (TrueExprHole (mkVarOcc "_"))

arrowFail :: HsExpr RdrName -> RnM (HsExpr Name, FreeVars)
arrowFail e
  = do { addErr (vcat [ text "Arrow command found where an expression was expected:"
                      , nest 2 (ppr e) ])
         -- Return a place-holder hole, so that we can carry on
         -- to report other errors
       ; return (hsHoleExpr, emptyFVs) }

----------------------
-- See Note [Parsing sections] in Parser.y
rnSection :: HsExpr RdrName -> RnM (HsExpr Name, FreeVars)
rnSection section@(SectionR op expr)
  = do  { (op', fvs_op)     <- rnLExpr op
        ; (expr', fvs_expr) <- rnLExpr expr
        ; checkSectionPrec InfixR section op' expr'
        ; return (SectionR op' expr', fvs_op `plusFV` fvs_expr) }

rnSection section@(SectionL expr op)
  = do  { (expr', fvs_expr) <- rnLExpr expr
        ; (op', fvs_op)     <- rnLExpr op
        ; checkSectionPrec InfixL section op' expr'
        ; return (SectionL expr' op', fvs_op `plusFV` fvs_expr) }

rnSection other = pprPanic "rnSection" (ppr other)

{-
************************************************************************
*                                                                      *
        Arrow commands
*                                                                      *
************************************************************************
-}

rnCmdArgs :: [LHsCmdTop RdrName] -> RnM ([LHsCmdTop Name], FreeVars)
rnCmdArgs [] = return ([], emptyFVs)
rnCmdArgs (arg:args)
  = do { (arg',fvArg) <- rnCmdTop arg
       ; (args',fvArgs) <- rnCmdArgs args
       ; return (arg':args', fvArg `plusFV` fvArgs) }

rnCmdTop :: LHsCmdTop RdrName -> RnM (LHsCmdTop Name, FreeVars)
rnCmdTop = wrapLocFstM rnCmdTop'
 where
  rnCmdTop' (HsCmdTop cmd _ _ _)
   = do { (cmd', fvCmd) <- rnLCmd cmd
        ; let cmd_names = [arrAName, composeAName, firstAName] ++
                          nameSetElems (methodNamesCmd (unLoc cmd'))
        -- Generate the rebindable syntax for the monad
        ; (cmd_names', cmd_fvs) <- lookupSyntaxNames cmd_names

        ; return (HsCmdTop cmd' placeHolderType placeHolderType
                  (cmd_names `zip` cmd_names'),
                  fvCmd `plusFV` cmd_fvs) }

rnLCmd :: LHsCmd RdrName -> RnM (LHsCmd Name, FreeVars)
rnLCmd = wrapLocFstM rnCmd

rnCmd :: HsCmd RdrName -> RnM (HsCmd Name, FreeVars)

rnCmd (HsCmdArrApp arrow arg _ ho rtl)
  = do { (arrow',fvArrow) <- select_arrow_scope (rnLExpr arrow)
       ; (arg',fvArg) <- rnLExpr arg
       ; return (HsCmdArrApp arrow' arg' placeHolderType ho rtl,
                 fvArrow `plusFV` fvArg) }
  where
    select_arrow_scope tc = case ho of
        HsHigherOrderApp -> tc
        HsFirstOrderApp  -> escapeArrowScope tc
        -- See Note [Escaping the arrow scope] in TcRnTypes
        -- Before renaming 'arrow', use the environment of the enclosing
        -- proc for the (-<) case.
        -- Local bindings, inside the enclosing proc, are not in scope
        -- inside 'arrow'.  In the higher-order case (-<<), they are.

-- infix form
rnCmd (HsCmdArrForm op (Just _) [arg1, arg2])
  = do { (op',fv_op) <- escapeArrowScope (rnLExpr op)
       ; let L _ (HsVar (L _ op_name)) = op'
       ; (arg1',fv_arg1) <- rnCmdTop arg1
       ; (arg2',fv_arg2) <- rnCmdTop arg2
        -- Deal with fixity
       ; fixity <- lookupFixityRn op_name
       ; final_e <- mkOpFormRn arg1' op' fixity arg2'
       ; return (final_e, fv_arg1 `plusFV` fv_op `plusFV` fv_arg2) }

rnCmd (HsCmdArrForm op fixity cmds)
  = do { (op',fvOp) <- escapeArrowScope (rnLExpr op)
       ; (cmds',fvCmds) <- rnCmdArgs cmds
       ; return (HsCmdArrForm op' fixity cmds', fvOp `plusFV` fvCmds) }

rnCmd (HsCmdApp fun arg)
  = do { (fun',fvFun) <- rnLCmd  fun
       ; (arg',fvArg) <- rnLExpr arg
       ; return (HsCmdApp fun' arg', fvFun `plusFV` fvArg) }

rnCmd (HsCmdLam matches)
  = do { (matches', fvMatch) <- rnMatchGroup LambdaExpr rnLCmd matches
       ; return (HsCmdLam matches', fvMatch) }

rnCmd (HsCmdPar e)
  = do  { (e', fvs_e) <- rnLCmd e
        ; return (HsCmdPar e', fvs_e) }

rnCmd (HsCmdCase expr matches)
  = do { (new_expr, e_fvs) <- rnLExpr expr
       ; (new_matches, ms_fvs) <- rnMatchGroup CaseAlt rnLCmd matches
       ; return (HsCmdCase new_expr new_matches, e_fvs `plusFV` ms_fvs) }

rnCmd (HsCmdIf _ p b1 b2)
  = do { (p', fvP) <- rnLExpr p
       ; (b1', fvB1) <- rnLCmd b1
       ; (b2', fvB2) <- rnLCmd b2
       ; (mb_ite, fvITE) <- lookupIfThenElse
       ; return (HsCmdIf mb_ite p' b1' b2', plusFVs [fvITE, fvP, fvB1, fvB2]) }

rnCmd (HsCmdLet (L l binds) cmd)
  = rnLocalBindsAndThen binds $ \ binds' _ -> do
      { (cmd',fvExpr) <- rnLCmd cmd
      ; return (HsCmdLet (L l binds') cmd', fvExpr) }

rnCmd (HsCmdDo (L l stmts) _)
  = do  { ((stmts', _), fvs) <-
            rnStmts ArrowExpr rnLCmd stmts (\ _ -> return ((), emptyFVs))
        ; return ( HsCmdDo (L l stmts') placeHolderType, fvs ) }

rnCmd cmd@(HsCmdWrap {}) = pprPanic "rnCmd" (ppr cmd)

---------------------------------------------------
type CmdNeeds = FreeVars        -- Only inhabitants are
                                --      appAName, choiceAName, loopAName

-- find what methods the Cmd needs (loop, choice, apply)
methodNamesLCmd :: LHsCmd Name -> CmdNeeds
methodNamesLCmd = methodNamesCmd . unLoc

methodNamesCmd :: HsCmd Name -> CmdNeeds

methodNamesCmd (HsCmdArrApp _arrow _arg _ HsFirstOrderApp _rtl)
  = emptyFVs
methodNamesCmd (HsCmdArrApp _arrow _arg _ HsHigherOrderApp _rtl)
  = unitFV appAName
methodNamesCmd (HsCmdArrForm {}) = emptyFVs
methodNamesCmd (HsCmdWrap _ cmd) = methodNamesCmd cmd

methodNamesCmd (HsCmdPar c) = methodNamesLCmd c

methodNamesCmd (HsCmdIf _ _ c1 c2)
  = methodNamesLCmd c1 `plusFV` methodNamesLCmd c2 `addOneFV` choiceAName

methodNamesCmd (HsCmdLet _ c)          = methodNamesLCmd c
methodNamesCmd (HsCmdDo (L _ stmts) _) = methodNamesStmts stmts
methodNamesCmd (HsCmdApp c _)          = methodNamesLCmd c
methodNamesCmd (HsCmdLam match)        = methodNamesMatch match

methodNamesCmd (HsCmdCase _ matches)
  = methodNamesMatch matches `addOneFV` choiceAName

--methodNamesCmd _ = emptyFVs
   -- Other forms can't occur in commands, but it's not convenient
   -- to error here so we just do what's convenient.
   -- The type checker will complain later

---------------------------------------------------
methodNamesMatch :: MatchGroup Name (LHsCmd Name) -> FreeVars
methodNamesMatch (MG { mg_alts = L _ ms })
  = plusFVs (map do_one ms)
 where
    do_one (L _ (Match _ _ _ grhss)) = methodNamesGRHSs grhss

-------------------------------------------------
-- gaw 2004
methodNamesGRHSs :: GRHSs Name (LHsCmd Name) -> FreeVars
methodNamesGRHSs (GRHSs grhss _) = plusFVs (map methodNamesGRHS grhss)

-------------------------------------------------

methodNamesGRHS :: Located (GRHS Name (LHsCmd Name)) -> CmdNeeds
methodNamesGRHS (L _ (GRHS _ rhs)) = methodNamesLCmd rhs

---------------------------------------------------
methodNamesStmts :: [Located (StmtLR Name Name (LHsCmd Name))] -> FreeVars
methodNamesStmts stmts = plusFVs (map methodNamesLStmt stmts)

---------------------------------------------------
methodNamesLStmt :: Located (StmtLR Name Name (LHsCmd Name)) -> FreeVars
methodNamesLStmt = methodNamesStmt . unLoc

methodNamesStmt :: StmtLR Name Name (LHsCmd Name) -> FreeVars
methodNamesStmt (LastStmt cmd _ _)               = methodNamesLCmd cmd
methodNamesStmt (BodyStmt cmd _ _ _)             = methodNamesLCmd cmd
methodNamesStmt (BindStmt _ cmd _ _ _)           = methodNamesLCmd cmd
methodNamesStmt (RecStmt { recS_stmts = stmts }) =
  methodNamesStmts stmts `addOneFV` loopAName
methodNamesStmt (LetStmt {})                     = emptyFVs
methodNamesStmt (ParStmt {})                     = emptyFVs
methodNamesStmt (TransStmt {})                   = emptyFVs
methodNamesStmt ApplicativeStmt{}            = emptyFVs
   -- ParStmt and TransStmt can't occur in commands, but it's not
   -- convenient to error here so we just do what's convenient

{-
************************************************************************
*                                                                      *
        Arithmetic sequences
*                                                                      *
************************************************************************
-}

rnArithSeq :: ArithSeqInfo RdrName -> RnM (ArithSeqInfo Name, FreeVars)
rnArithSeq (From expr)
 = do { (expr', fvExpr) <- rnLExpr expr
      ; return (From expr', fvExpr) }

rnArithSeq (FromThen expr1 expr2)
 = do { (expr1', fvExpr1) <- rnLExpr expr1
      ; (expr2', fvExpr2) <- rnLExpr expr2
      ; return (FromThen expr1' expr2', fvExpr1 `plusFV` fvExpr2) }

rnArithSeq (FromTo expr1 expr2)
 = do { (expr1', fvExpr1) <- rnLExpr expr1
      ; (expr2', fvExpr2) <- rnLExpr expr2
      ; return (FromTo expr1' expr2', fvExpr1 `plusFV` fvExpr2) }

rnArithSeq (FromThenTo expr1 expr2 expr3)
 = do { (expr1', fvExpr1) <- rnLExpr expr1
      ; (expr2', fvExpr2) <- rnLExpr expr2
      ; (expr3', fvExpr3) <- rnLExpr expr3
      ; return (FromThenTo expr1' expr2' expr3',
                plusFVs [fvExpr1, fvExpr2, fvExpr3]) }

{-
************************************************************************
*                                                                      *
\subsubsection{@Stmt@s: in @do@ expressions}
*                                                                      *
************************************************************************
-}

-- | Rename some Stmts
rnStmts :: Outputable (body RdrName)
        => HsStmtContext Name
        -> (Located (body RdrName) -> RnM (Located (body Name), FreeVars))
           -- ^ How to rename the body of each statement (e.g. rnLExpr)
        -> [LStmt RdrName (Located (body RdrName))]
           -- ^ Statements
        -> ([Name] -> RnM (thing, FreeVars))
           -- ^ if these statements scope over something, this renames it
           -- and returns the result.
        -> RnM (([LStmt Name (Located (body Name))], thing), FreeVars)
rnStmts ctxt rnBody = rnStmtsWithPostProcessing ctxt rnBody noPostProcessStmts

-- | like 'rnStmts' but applies a post-processing step to the renamed Stmts
rnStmtsWithPostProcessing
        :: Outputable (body RdrName)
        => HsStmtContext Name
        -> (Located (body RdrName) -> RnM (Located (body Name), FreeVars))
           -- ^ How to rename the body of each statement (e.g. rnLExpr)
        -> (HsStmtContext Name
              -> [(LStmt Name (Located (body Name)), FreeVars)]
              -> RnM ([LStmt Name (Located (body Name))], FreeVars))
           -- ^ postprocess the statements
        -> [LStmt RdrName (Located (body RdrName))]
           -- ^ Statements
        -> ([Name] -> RnM (thing, FreeVars))
           -- ^ if these statements scope over something, this renames it
           -- and returns the result.
        -> RnM (([LStmt Name (Located (body Name))], thing), FreeVars)
rnStmtsWithPostProcessing ctxt rnBody ppStmts stmts thing_inside
 = do { ((stmts', thing), fvs) <-
          rnStmtsWithFreeVars ctxt rnBody stmts thing_inside
      ; (pp_stmts, fvs') <- ppStmts ctxt stmts'
      ; return ((pp_stmts, thing), fvs `plusFV` fvs')
      }

-- | maybe rearrange statements according to the ApplicativeDo transformation
postProcessStmtsForApplicativeDo
  :: HsStmtContext Name
  -> [(ExprLStmt Name, FreeVars)]
  -> RnM ([ExprLStmt Name], FreeVars)
postProcessStmtsForApplicativeDo ctxt stmts
  = do {
       -- rearrange the statements using ApplicativeStmt if
       -- -XApplicativeDo is on.  Also strip out the FreeVars attached
       -- to each Stmt body.
         ado_is_on <- xoptM LangExt.ApplicativeDo
       ; let is_do_expr | DoExpr <- ctxt = True
                        | otherwise = False
       ; if ado_is_on && is_do_expr
            then rearrangeForApplicativeDo ctxt stmts
            else noPostProcessStmts ctxt stmts }

-- | strip the FreeVars annotations from statements
noPostProcessStmts
  :: HsStmtContext Name
  -> [(LStmt Name (Located (body Name)), FreeVars)]
  -> RnM ([LStmt Name (Located (body Name))], FreeVars)
noPostProcessStmts _ stmts = return (map fst stmts, emptyNameSet)


rnStmtsWithFreeVars :: Outputable (body RdrName)
        => HsStmtContext Name
        -> (Located (body RdrName) -> RnM (Located (body Name), FreeVars))
        -> [LStmt RdrName (Located (body RdrName))]
        -> ([Name] -> RnM (thing, FreeVars))
        -> RnM ( ([(LStmt Name (Located (body Name)), FreeVars)], thing)
               , FreeVars)
-- Each Stmt body is annotated with its FreeVars, so that
-- we can rearrange statements for ApplicativeDo.
--
-- Variables bound by the Stmts, and mentioned in thing_inside,
-- do not appear in the result FreeVars

rnStmtsWithFreeVars ctxt _ [] thing_inside
  = do { checkEmptyStmts ctxt
       ; (thing, fvs) <- thing_inside []
       ; return (([], thing), fvs) }

rnStmtsWithFreeVars MDoExpr rnBody stmts thing_inside    -- Deal with mdo
  = -- Behave like do { rec { ...all but last... }; last }
    do { ((stmts1, (stmts2, thing)), fvs)
           <- rnStmt MDoExpr rnBody (noLoc $ mkRecStmt all_but_last) $ \ _ ->
              do { last_stmt' <- checkLastStmt MDoExpr last_stmt
                 ; rnStmt MDoExpr rnBody last_stmt' thing_inside }
        ; return (((stmts1 ++ stmts2), thing), fvs) }
  where
    Just (all_but_last, last_stmt) = snocView stmts

rnStmtsWithFreeVars ctxt rnBody (lstmt@(L loc _) : lstmts) thing_inside
  | null lstmts
  = setSrcSpan loc $
    do { lstmt' <- checkLastStmt ctxt lstmt
       ; rnStmt ctxt rnBody lstmt' thing_inside }

  | otherwise
  = do { ((stmts1, (stmts2, thing)), fvs)
            <- setSrcSpan loc                         $
               do { checkStmt ctxt lstmt
                  ; rnStmt ctxt rnBody lstmt    $ \ bndrs1 ->
                    rnStmtsWithFreeVars ctxt rnBody lstmts  $ \ bndrs2 ->
                    thing_inside (bndrs1 ++ bndrs2) }
        ; return (((stmts1 ++ stmts2), thing), fvs) }

----------------------
rnStmt :: Outputable (body RdrName)
       => HsStmtContext Name
       -> (Located (body RdrName) -> RnM (Located (body Name), FreeVars))
          -- ^ How to rename the body of the statement
       -> LStmt RdrName (Located (body RdrName))
          -- ^ The statement
       -> ([Name] -> RnM (thing, FreeVars))
          -- ^ Rename the stuff that this statement scopes over
       -> RnM ( ([(LStmt Name (Located (body Name)), FreeVars)], thing)
              , FreeVars)
-- Variables bound by the Stmt, and mentioned in thing_inside,
-- do not appear in the result FreeVars

rnStmt ctxt rnBody (L loc (LastStmt body noret _)) thing_inside
  = do  { (body', fv_expr) <- rnBody body
        ; (ret_op, fvs1)   <- lookupStmtName ctxt returnMName
        ; (thing,  fvs3)   <- thing_inside []
        ; return (([(L loc (LastStmt body' noret ret_op), fv_expr)], thing),
                  fv_expr `plusFV` fvs1 `plusFV` fvs3) }

rnStmt ctxt rnBody (L loc (BodyStmt body _ _ _)) thing_inside
  = do  { (body', fv_expr) <- rnBody body
        ; (then_op, fvs1)  <- lookupStmtName ctxt thenMName
        ; (guard_op, fvs2) <- if isListCompExpr ctxt
                              then lookupStmtName ctxt guardMName
                              else return (noSyntaxExpr, emptyFVs)
                              -- Only list/parr/monad comprehensions use 'guard'
                              -- Also for sub-stmts of same eg [ e | x<-xs, gd | blah ]
                              -- Here "gd" is a guard
        ; (thing, fvs3)    <- thing_inside []
        ; return (([(L loc (BodyStmt body'
                     then_op guard_op placeHolderType), fv_expr)], thing),
                  fv_expr `plusFV` fvs1 `plusFV` fvs2 `plusFV` fvs3) }

rnStmt ctxt rnBody (L loc (BindStmt pat body _ _ _)) thing_inside
  = do  { (body', fv_expr) <- rnBody body
                -- The binders do not scope over the expression
        ; (bind_op, fvs1) <- lookupStmtName ctxt bindMName

        ; xMonadFailEnabled <- fmap (xopt LangExt.MonadFailDesugaring) getDynFlags
        ; let failFunction | xMonadFailEnabled = failMName
                           | otherwise         = failMName_preMFP
        ; (fail_op, fvs2) <- lookupSyntaxName failFunction

        ; rnPat (StmtCtxt ctxt) pat $ \ pat' -> do
        { (thing, fvs3) <- thing_inside (collectPatBinders pat')
        ; return (( [( L loc (BindStmt pat' body' bind_op fail_op PlaceHolder)
                     , fv_expr )]
                  , thing),
                  fv_expr `plusFV` fvs1 `plusFV` fvs2 `plusFV` fvs3) }}
       -- fv_expr shouldn't really be filtered by the rnPatsAndThen
        -- but it does not matter because the names are unique

rnStmt _ _ (L loc (LetStmt (L l binds))) thing_inside
  = do  { rnLocalBindsAndThen binds $ \binds' bind_fvs -> do
        { (thing, fvs) <- thing_inside (collectLocalBinders binds')
        ; return (([(L loc (LetStmt (L l binds')), bind_fvs)], thing), fvs) }  }

rnStmt ctxt rnBody (L loc (RecStmt { recS_stmts = rec_stmts })) thing_inside
  = do  { (return_op, fvs1)  <- lookupStmtName ctxt returnMName
        ; (mfix_op,   fvs2)  <- lookupStmtName ctxt mfixName
        ; (bind_op,   fvs3)  <- lookupStmtName ctxt bindMName
        ; let empty_rec_stmt = emptyRecStmtName { recS_ret_fn  = return_op
                                                , recS_mfix_fn = mfix_op
                                                , recS_bind_fn = bind_op }

        -- Step1: Bring all the binders of the mdo into scope
        -- (Remember that this also removes the binders from the
        -- finally-returned free-vars.)
        -- And rename each individual stmt, making a
        -- singleton segment.  At this stage the FwdRefs field
        -- isn't finished: it's empty for all except a BindStmt
        -- for which it's the fwd refs within the bind itself
        -- (This set may not be empty, because we're in a recursive
        -- context.)
        ; rnRecStmtsAndThen rnBody rec_stmts   $ \ segs -> do
        { let bndrs = nameSetElems $ foldr (unionNameSet . (\(ds,_,_,_) -> ds))
                                            emptyNameSet segs
        ; (thing, fvs_later) <- thing_inside bndrs
        ; let (rec_stmts', fvs) = segmentRecStmts loc ctxt empty_rec_stmt segs fvs_later
        -- We aren't going to try to group RecStmts with
        -- ApplicativeDo, so attaching empty FVs is fine.
        ; return ( ((zip rec_stmts' (repeat emptyNameSet)), thing)
                 , fvs `plusFV` fvs1 `plusFV` fvs2 `plusFV` fvs3) } }

rnStmt ctxt _ (L loc (ParStmt segs _ _ _)) thing_inside
  = do  { (mzip_op, fvs1)   <- lookupStmtNamePoly ctxt mzipName
        ; (bind_op, fvs2)   <- lookupStmtName ctxt bindMName
        ; (return_op, fvs3) <- lookupStmtName ctxt returnMName
        ; ((segs', thing), fvs4) <- rnParallelStmts (ParStmtCtxt ctxt) return_op segs thing_inside
        ; return ( ([(L loc (ParStmt segs' mzip_op bind_op placeHolderType), fvs4)], thing)
                 , fvs1 `plusFV` fvs2 `plusFV` fvs3 `plusFV` fvs4) }

rnStmt ctxt _ (L loc (TransStmt { trS_stmts = stmts, trS_by = by, trS_form = form
                              , trS_using = using })) thing_inside
  = do { -- Rename the 'using' expression in the context before the transform is begun
         (using', fvs1) <- rnLExpr using

         -- Rename the stmts and the 'by' expression
         -- Keep track of the variables mentioned in the 'by' expression
       ; ((stmts', (by', used_bndrs, thing)), fvs2)
             <- rnStmts (TransStmtCtxt ctxt) rnLExpr stmts $ \ bndrs ->
                do { (by',   fvs_by) <- mapMaybeFvRn rnLExpr by
                   ; (thing, fvs_thing) <- thing_inside bndrs
                   ; let fvs = fvs_by `plusFV` fvs_thing
                         used_bndrs = filter (`elemNameSet` fvs) bndrs
                         -- The paper (Fig 5) has a bug here; we must treat any free variable
                         -- of the "thing inside", **or of the by-expression**, as used
                   ; return ((by', used_bndrs, thing), fvs) }

       -- Lookup `return`, `(>>=)` and `liftM` for monad comprehensions
       ; (return_op, fvs3) <- lookupStmtName ctxt returnMName
       ; (bind_op,   fvs4) <- lookupStmtName ctxt bindMName
       ; (fmap_op,   fvs5) <- case form of
                                ThenForm -> return (noExpr, emptyFVs)
                                _        -> lookupStmtNamePoly ctxt fmapName

       ; let all_fvs  = fvs1 `plusFV` fvs2 `plusFV` fvs3
                             `plusFV` fvs4 `plusFV` fvs5
             bndr_map = used_bndrs `zip` used_bndrs
             -- See Note [TransStmt binder map] in HsExpr

       ; traceRn (text "rnStmt: implicitly rebound these used binders:" <+> ppr bndr_map)
       ; return (([(L loc (TransStmt { trS_stmts = stmts', trS_bndrs = bndr_map
                                    , trS_by = by', trS_using = using', trS_form = form
                                    , trS_ret = return_op, trS_bind = bind_op
                                    , trS_bind_arg_ty = PlaceHolder
                                    , trS_fmap = fmap_op }), fvs2)], thing), all_fvs) }

rnStmt _ _ (L _ ApplicativeStmt{}) _ =
  panic "rnStmt: ApplicativeStmt"

rnParallelStmts :: forall thing. HsStmtContext Name
                -> SyntaxExpr Name
                -> [ParStmtBlock RdrName RdrName]
                -> ([Name] -> RnM (thing, FreeVars))
                -> RnM (([ParStmtBlock Name Name], thing), FreeVars)
-- Note [Renaming parallel Stmts]
rnParallelStmts ctxt return_op segs thing_inside
  = do { orig_lcl_env <- getLocalRdrEnv
       ; rn_segs orig_lcl_env [] segs }
  where
    rn_segs :: LocalRdrEnv
            -> [Name] -> [ParStmtBlock RdrName RdrName]
            -> RnM (([ParStmtBlock Name Name], thing), FreeVars)
    rn_segs _ bndrs_so_far []
      = do { let (bndrs', dups) = removeDups cmpByOcc bndrs_so_far
           ; mapM_ dupErr dups
           ; (thing, fvs) <- bindLocalNames bndrs' (thing_inside bndrs')
           ; return (([], thing), fvs) }

    rn_segs env bndrs_so_far (ParStmtBlock stmts _ _ : segs)
      = do { ((stmts', (used_bndrs, segs', thing)), fvs)
                    <- rnStmts ctxt rnLExpr stmts $ \ bndrs ->
                       setLocalRdrEnv env       $ do
                       { ((segs', thing), fvs) <- rn_segs env (bndrs ++ bndrs_so_far) segs
                       ; let used_bndrs = filter (`elemNameSet` fvs) bndrs
                       ; return ((used_bndrs, segs', thing), fvs) }

           ; let seg' = ParStmtBlock stmts' used_bndrs return_op
           ; return ((seg':segs', thing), fvs) }

    cmpByOcc n1 n2 = nameOccName n1 `compare` nameOccName n2
    dupErr vs = addErr (text "Duplicate binding in parallel list comprehension for:"
                    <+> quotes (ppr (head vs)))

lookupStmtName :: HsStmtContext Name -> Name -> RnM (SyntaxExpr Name, FreeVars)
-- Like lookupSyntaxName, but respects contexts
lookupStmtName ctxt n
  | rebindableContext ctxt
  = lookupSyntaxName n
  | otherwise
  = return (mkRnSyntaxExpr n, emptyFVs)

lookupStmtNamePoly :: HsStmtContext Name -> Name -> RnM (HsExpr Name, FreeVars)
lookupStmtNamePoly ctxt name
  | rebindableContext ctxt
  = do { rebindable_on <- xoptM LangExt.RebindableSyntax
       ; if rebindable_on
         then do { fm <- lookupOccRn (nameRdrName name)
                 ; return (HsVar (noLoc fm), unitFV fm) }
         else not_rebindable }
  | otherwise
  = not_rebindable
  where
    not_rebindable = return (HsVar (noLoc name), emptyFVs)

-- | Is this a context where we respect RebindableSyntax?
-- but ListComp/PArrComp are never rebindable
-- Neither is ArrowExpr, which has its own desugarer in DsArrows
rebindableContext :: HsStmtContext Name -> Bool
rebindableContext ctxt = case ctxt of
  ListComp        -> False
  PArrComp        -> False
  ArrowExpr       -> False
  PatGuard {}     -> False

  DoExpr          -> True
  MDoExpr         -> True
  MonadComp       -> True
  GhciStmtCtxt    -> True   -- I suppose?

  ParStmtCtxt   c -> rebindableContext c     -- Look inside to
  TransStmtCtxt c -> rebindableContext c     -- the parent context

{-
Note [Renaming parallel Stmts]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Renaming parallel statements is painful.  Given, say
     [ a+c | a <- as, bs <- bss
           | c <- bs, a <- ds ]
Note that
  (a) In order to report "Defined but not used" about 'bs', we must
      rename each group of Stmts with a thing_inside whose FreeVars
      include at least {a,c}

  (b) We want to report that 'a' is illegally bound in both branches

  (c) The 'bs' in the second group must obviously not be captured by
      the binding in the first group

To satisfy (a) we nest the segements.
To satisfy (b) we check for duplicates just before thing_inside.
To satisfy (c) we reset the LocalRdrEnv each time.

************************************************************************
*                                                                      *
\subsubsection{mdo expressions}
*                                                                      *
************************************************************************
-}

type FwdRefs = NameSet
type Segment stmts = (Defs,
                      Uses,     -- May include defs
                      FwdRefs,  -- A subset of uses that are
                                --   (a) used before they are bound in this segment, or
                                --   (b) used here, and bound in subsequent segments
                      stmts)    -- Either Stmt or [Stmt]


-- wrapper that does both the left- and right-hand sides
rnRecStmtsAndThen :: Outputable (body RdrName) =>
                     (Located (body RdrName)
                  -> RnM (Located (body Name), FreeVars))
                  -> [LStmt RdrName (Located (body RdrName))]
                         -- assumes that the FreeVars returned includes
                         -- the FreeVars of the Segments
                  -> ([Segment (LStmt Name (Located (body Name)))]
                      -> RnM (a, FreeVars))
                  -> RnM (a, FreeVars)
rnRecStmtsAndThen rnBody s cont
  = do  { -- (A) Make the mini fixity env for all of the stmts
          fix_env <- makeMiniFixityEnv (collectRecStmtsFixities s)

          -- (B) Do the LHSes
        ; new_lhs_and_fv <- rn_rec_stmts_lhs fix_env s

          --    ...bring them and their fixities into scope
        ; let bound_names = collectLStmtsBinders (map fst new_lhs_and_fv)
              -- Fake uses of variables introduced implicitly (warning suppression, see #4404)
              implicit_uses = lStmtsImplicits (map fst new_lhs_and_fv)
        ; bindLocalNamesFV bound_names $
          addLocalFixities fix_env bound_names $ do

          -- (C) do the right-hand-sides and thing-inside
        { segs <- rn_rec_stmts rnBody bound_names new_lhs_and_fv
        ; (res, fvs) <- cont segs
        ; warnUnusedLocalBinds bound_names (fvs `unionNameSet` implicit_uses)
        ; return (res, fvs) }}

-- get all the fixity decls in any Let stmt
collectRecStmtsFixities :: [LStmtLR RdrName RdrName body] -> [LFixitySig RdrName]
collectRecStmtsFixities l =
    foldr (\ s -> \acc -> case s of
            (L _ (LetStmt (L _ (HsValBinds (ValBindsIn _ sigs))))) ->
                foldr (\ sig -> \ acc -> case sig of
                                           (L loc (FixSig s)) -> (L loc s) : acc
                                           _ -> acc) acc sigs
            _ -> acc) [] l

-- left-hand sides

rn_rec_stmt_lhs :: Outputable body => MiniFixityEnv
                -> LStmt RdrName body
                   -- rename LHS, and return its FVs
                   -- Warning: we will only need the FreeVars below in the case of a BindStmt,
                   -- so we don't bother to compute it accurately in the other cases
                -> RnM [(LStmtLR Name RdrName body, FreeVars)]

rn_rec_stmt_lhs _ (L loc (BodyStmt body a b c))
  = return [(L loc (BodyStmt body a b c), emptyFVs)]

rn_rec_stmt_lhs _ (L loc (LastStmt body noret a))
  = return [(L loc (LastStmt body noret a), emptyFVs)]

rn_rec_stmt_lhs fix_env (L loc (BindStmt pat body a b t))
  = do
      -- should the ctxt be MDo instead?
      (pat', fv_pat) <- rnBindPat (localRecNameMaker fix_env) pat
      return [(L loc (BindStmt pat' body a b t),
               fv_pat)]

rn_rec_stmt_lhs _ (L _ (LetStmt (L _ binds@(HsIPBinds _))))
  = failWith (badIpBinds (text "an mdo expression") binds)

rn_rec_stmt_lhs fix_env (L loc (LetStmt (L l(HsValBinds binds))))
    = do (_bound_names, binds') <- rnLocalValBindsLHS fix_env binds
         return [(L loc (LetStmt (L l (HsValBinds binds'))),
                 -- Warning: this is bogus; see function invariant
                 emptyFVs
                 )]

-- XXX Do we need to do something with the return and mfix names?
rn_rec_stmt_lhs fix_env (L _ (RecStmt { recS_stmts = stmts }))  -- Flatten Rec inside Rec
    = rn_rec_stmts_lhs fix_env stmts

rn_rec_stmt_lhs _ stmt@(L _ (ParStmt {}))       -- Syntactically illegal in mdo
  = pprPanic "rn_rec_stmt" (ppr stmt)

rn_rec_stmt_lhs _ stmt@(L _ (TransStmt {}))     -- Syntactically illegal in mdo
  = pprPanic "rn_rec_stmt" (ppr stmt)

rn_rec_stmt_lhs _ stmt@(L _ (ApplicativeStmt {})) -- Shouldn't appear yet
  = pprPanic "rn_rec_stmt" (ppr stmt)

rn_rec_stmt_lhs _ (L _ (LetStmt (L _ EmptyLocalBinds)))
  = panic "rn_rec_stmt LetStmt EmptyLocalBinds"

rn_rec_stmts_lhs :: Outputable body => MiniFixityEnv
                 -> [LStmt RdrName body]
                 -> RnM [(LStmtLR Name RdrName body, FreeVars)]
rn_rec_stmts_lhs fix_env stmts
  = do { ls <- concatMapM (rn_rec_stmt_lhs fix_env) stmts
       ; let boundNames = collectLStmtsBinders (map fst ls)
            -- First do error checking: we need to check for dups here because we
            -- don't bind all of the variables from the Stmt at once
            -- with bindLocatedLocals.
       ; checkDupNames boundNames
       ; return ls }


-- right-hand-sides

rn_rec_stmt :: (Outputable (body RdrName)) =>
               (Located (body RdrName) -> RnM (Located (body Name), FreeVars))
            -> [Name]
            -> (LStmtLR Name RdrName (Located (body RdrName)), FreeVars)
            -> RnM [Segment (LStmt Name (Located (body Name)))]
        -- Rename a Stmt that is inside a RecStmt (or mdo)
        -- Assumes all binders are already in scope
        -- Turns each stmt into a singleton Stmt
rn_rec_stmt rnBody _ (L loc (LastStmt body noret _), _)
  = do  { (body', fv_expr) <- rnBody body
        ; (ret_op, fvs1)   <- lookupSyntaxName returnMName
        ; return [(emptyNameSet, fv_expr `plusFV` fvs1, emptyNameSet,
                   L loc (LastStmt body' noret ret_op))] }

rn_rec_stmt rnBody _ (L loc (BodyStmt body _ _ _), _)
  = do { (body', fvs) <- rnBody body
       ; (then_op, fvs1) <- lookupSyntaxName thenMName
       ; return [(emptyNameSet, fvs `plusFV` fvs1, emptyNameSet,
                 L loc (BodyStmt body' then_op noSyntaxExpr placeHolderType))] }

rn_rec_stmt rnBody _ (L loc (BindStmt pat' body _ _ _), fv_pat)
  = do { (body', fv_expr) <- rnBody body
       ; (bind_op, fvs1) <- lookupSyntaxName bindMName

       ; xMonadFailEnabled <- fmap (xopt LangExt.MonadFailDesugaring) getDynFlags
       ; let failFunction | xMonadFailEnabled = failMName
                          | otherwise         = failMName_preMFP
       ; (fail_op, fvs2) <- lookupSyntaxName failFunction

       ; let bndrs = mkNameSet (collectPatBinders pat')
             fvs   = fv_expr `plusFV` fv_pat `plusFV` fvs1 `plusFV` fvs2
       ; return [(bndrs, fvs, bndrs `intersectNameSet` fvs,
                  L loc (BindStmt pat' body' bind_op fail_op PlaceHolder))] }

rn_rec_stmt _ _ (L _ (LetStmt (L _ binds@(HsIPBinds _))), _)
  = failWith (badIpBinds (text "an mdo expression") binds)

rn_rec_stmt _ all_bndrs (L loc (LetStmt (L l (HsValBinds binds'))), _)
  = do { (binds', du_binds) <- rnLocalValBindsRHS (mkNameSet all_bndrs) binds'
           -- fixities and unused are handled above in rnRecStmtsAndThen
       ; let fvs = allUses du_binds
       ; return [(duDefs du_binds, fvs, emptyNameSet,
                 L loc (LetStmt (L l (HsValBinds binds'))))] }

-- no RecStmt case because they get flattened above when doing the LHSes
rn_rec_stmt _ _ stmt@(L _ (RecStmt {}), _)
  = pprPanic "rn_rec_stmt: RecStmt" (ppr stmt)

rn_rec_stmt _ _ stmt@(L _ (ParStmt {}), _)       -- Syntactically illegal in mdo
  = pprPanic "rn_rec_stmt: ParStmt" (ppr stmt)

rn_rec_stmt _ _ stmt@(L _ (TransStmt {}), _)     -- Syntactically illegal in mdo
  = pprPanic "rn_rec_stmt: TransStmt" (ppr stmt)

rn_rec_stmt _ _ (L _ (LetStmt (L _ EmptyLocalBinds)), _)
  = panic "rn_rec_stmt: LetStmt EmptyLocalBinds"

rn_rec_stmt _ _ stmt@(L _ (ApplicativeStmt {}), _)
  = pprPanic "rn_rec_stmt: ApplicativeStmt" (ppr stmt)

rn_rec_stmts :: Outputable (body RdrName) =>
                (Located (body RdrName) -> RnM (Located (body Name), FreeVars))
             -> [Name]
             -> [(LStmtLR Name RdrName (Located (body RdrName)), FreeVars)]
             -> RnM [Segment (LStmt Name (Located (body Name)))]
rn_rec_stmts rnBody bndrs stmts
  = do { segs_s <- mapM (rn_rec_stmt rnBody bndrs) stmts
       ; return (concat segs_s) }

---------------------------------------------
segmentRecStmts :: SrcSpan -> HsStmtContext Name
                -> Stmt Name body
                -> [Segment (LStmt Name body)] -> FreeVars
                -> ([LStmt Name body], FreeVars)

segmentRecStmts loc ctxt empty_rec_stmt segs fvs_later
  | null segs
  = ([], fvs_later)

  | MDoExpr <- ctxt
  = segsToStmts empty_rec_stmt grouped_segs fvs_later
               -- Step 4: Turn the segments into Stmts
                --         Use RecStmt when and only when there are fwd refs
                --         Also gather up the uses from the end towards the
                --         start, so we can tell the RecStmt which things are
                --         used 'after' the RecStmt

  | otherwise
  = ([ L loc $
       empty_rec_stmt { recS_stmts = ss
                      , recS_later_ids = nameSetElems (defs `intersectNameSet` fvs_later)
                      , recS_rec_ids   = nameSetElems (defs `intersectNameSet` uses) }]
    , uses `plusFV` fvs_later)

  where
    (defs_s, uses_s, _, ss) = unzip4 segs
    defs = plusFVs defs_s
    uses = plusFVs uses_s

                -- Step 2: Fill in the fwd refs.
                --         The segments are all singletons, but their fwd-ref
                --         field mentions all the things used by the segment
                --         that are bound after their use
    segs_w_fwd_refs = addFwdRefs segs

                -- Step 3: Group together the segments to make bigger segments
                --         Invariant: in the result, no segment uses a variable
                --                    bound in a later segment
    grouped_segs = glomSegments ctxt segs_w_fwd_refs

----------------------------
addFwdRefs :: [Segment a] -> [Segment a]
-- So far the segments only have forward refs *within* the Stmt
--      (which happens for bind:  x <- ...x...)
-- This function adds the cross-seg fwd ref info

addFwdRefs segs
  = fst (foldr mk_seg ([], emptyNameSet) segs)
  where
    mk_seg (defs, uses, fwds, stmts) (segs, later_defs)
        = (new_seg : segs, all_defs)
        where
          new_seg = (defs, uses, new_fwds, stmts)
          all_defs = later_defs `unionNameSet` defs
          new_fwds = fwds `unionNameSet` (uses `intersectNameSet` later_defs)
                -- Add the downstream fwd refs here

{-
Note [Segmenting mdo]
~~~~~~~~~~~~~~~~~~~~~
NB. June 7 2012: We only glom segments that appear in an explicit mdo;
and leave those found in "do rec"'s intact.  See
http://ghc.haskell.org/trac/ghc/ticket/4148 for the discussion
leading to this design choice.  Hence the test in segmentRecStmts.

Note [Glomming segments]
~~~~~~~~~~~~~~~~~~~~~~~~
Glomming the singleton segments of an mdo into minimal recursive groups.

At first I thought this was just strongly connected components, but
there's an important constraint: the order of the stmts must not change.

Consider
     mdo { x <- ...y...
           p <- z
           y <- ...x...
           q <- x
           z <- y
           r <- x }

Here, the first stmt mention 'y', which is bound in the third.
But that means that the innocent second stmt (p <- z) gets caught
up in the recursion.  And that in turn means that the binding for
'z' has to be included... and so on.

Start at the tail { r <- x }
Now add the next one { z <- y ; r <- x }
Now add one more     { q <- x ; z <- y ; r <- x }
Now one more... but this time we have to group a bunch into rec
     { rec { y <- ...x... ; q <- x ; z <- y } ; r <- x }
Now one more, which we can add on without a rec
     { p <- z ;
       rec { y <- ...x... ; q <- x ; z <- y } ;
       r <- x }
Finally we add the last one; since it mentions y we have to
glom it together with the first two groups
     { rec { x <- ...y...; p <- z ; y <- ...x... ;
             q <- x ; z <- y } ;
       r <- x }
-}

glomSegments :: HsStmtContext Name
             -> [Segment (LStmt Name body)]
             -> [Segment [LStmt Name body]]  -- Each segment has a non-empty list of Stmts
-- See Note [Glomming segments]

glomSegments _ [] = []
glomSegments ctxt ((defs,uses,fwds,stmt) : segs)
        -- Actually stmts will always be a singleton
  = (seg_defs, seg_uses, seg_fwds, seg_stmts)  : others
  where
    segs'            = glomSegments ctxt segs
    (extras, others) = grab uses segs'
    (ds, us, fs, ss) = unzip4 extras

    seg_defs  = plusFVs ds `plusFV` defs
    seg_uses  = plusFVs us `plusFV` uses
    seg_fwds  = plusFVs fs `plusFV` fwds
    seg_stmts = stmt : concat ss

    grab :: NameSet             -- The client
         -> [Segment a]
         -> ([Segment a],       -- Needed by the 'client'
             [Segment a])       -- Not needed by the client
        -- The result is simply a split of the input
    grab uses dus
        = (reverse yeses, reverse noes)
        where
          (noes, yeses)           = span not_needed (reverse dus)
          not_needed (defs,_,_,_) = not (intersectsNameSet defs uses)

----------------------------------------------------
segsToStmts :: Stmt Name body                   -- A RecStmt with the SyntaxOps filled in
            -> [Segment [LStmt Name body]]      -- Each Segment has a non-empty list of Stmts
            -> FreeVars                         -- Free vars used 'later'
            -> ([LStmt Name body], FreeVars)

segsToStmts _ [] fvs_later = ([], fvs_later)
segsToStmts empty_rec_stmt ((defs, uses, fwds, ss) : segs) fvs_later
  = ASSERT( not (null ss) )
    (new_stmt : later_stmts, later_uses `plusFV` uses)
  where
    (later_stmts, later_uses) = segsToStmts empty_rec_stmt segs fvs_later
    new_stmt | non_rec   = head ss
             | otherwise = L (getLoc (head ss)) rec_stmt
    rec_stmt = empty_rec_stmt { recS_stmts     = ss
                              , recS_later_ids = nameSetElems used_later
                              , recS_rec_ids   = nameSetElems fwds }
    non_rec    = isSingleton ss && isEmptyNameSet fwds
    used_later = defs `intersectNameSet` later_uses
                                -- The ones needed after the RecStmt

{-
************************************************************************
*                                                                      *
ApplicativeDo
*                                                                      *
************************************************************************

Note [ApplicativeDo]

= Example =

For a sequence of statements

 do
     x <- A
     y <- B x
     z <- C
     return (f x y z)

We want to transform this to

  (\(x,y) z -> f x y z) <$> (do x <- A; y <- B x; return (x,y)) <*> C

It would be easy to notice that "y <- B x" and "z <- C" are
independent and do something like this:

 do
     x <- A
     (y,z) <- (,) <$> B x <*> C
     return (f x y z)

But this isn't enough! A and C were also independent, and this
transformation loses the ability to do A and C in parallel.

The algorithm works by first splitting the sequence of statements into
independent "segments", and a separate "tail" (the final statement). In
our example above, the segements would be

     [ x <- A
     , y <- B x ]

     [ z <- C ]

and the tail is:

     return (f x y z)

Then we take these segments and make an Applicative expression from them:

     (\(x,y) z -> return (f x y z))
       <$> do { x <- A; y <- B x; return (x,y) }
       <*> C

Finally, we recursively apply the transformation to each segment, to
discover any nested parallelism.

= Syntax & spec =

  expr ::= ... | do {stmt_1; ..; stmt_n} expr | ...

  stmt ::= pat <- expr
         | (arg_1 | ... | arg_n)  -- applicative composition, n>=1
         | ...                    -- other kinds of statement (e.g. let)

  arg ::= pat <- expr
        | {stmt_1; ..; stmt_n} {var_1..var_n}

(note that in the actual implementation,the expr in a do statement is
represented by a LastStmt as the final stmt, this is just a
representational issue and may change later.)

== Transformation to introduce applicative stmts ==

ado {} tail = tail
ado {pat <- expr} {return expr'} = (mkArg(pat <- expr)); return expr'
ado {one} tail = one : tail
ado stmts tail
  | n == 1 = ado before (ado after tail)
    where (before,after) = split(stmts_1)
  | n > 1  = (mkArg(stmts_1) | ... | mkArg(stmts_n)); tail
  where
    {stmts_1 .. stmts_n} = segments(stmts)

segments(stmts) =
  -- divide stmts into segments with no interdependencies

mkArg({pat <- expr}) = (pat <- expr)
mkArg({stmt_1; ...; stmt_n}) =
  {stmt_1; ...; stmt_n} {vars(stmt_1) u .. u vars(stmt_n)}

split({stmt_1; ..; stmt_n) =
  ({stmt_1; ..; stmt_i}, {stmt_i+1; ..; stmt_n})
  -- 1 <= i <= n
  -- i is a good place to insert a bind

== Desugaring for do ==

dsDo {} expr = expr

dsDo {pat <- rhs; stmts} expr =
   rhs >>= \pat -> dsDo stmts expr

dsDo {(arg_1 | ... | arg_n)} (return expr) =
  (\argpat (arg_1) .. argpat(arg_n) -> expr)
     <$> argexpr(arg_1)
     <*> ...
     <*> argexpr(arg_n)

dsDo {(arg_1 | ... | arg_n); stmts} expr =
  join (\argpat (arg_1) .. argpat(arg_n) -> dsDo stmts expr)
     <$> argexpr(arg_1)
     <*> ...
     <*> argexpr(arg_n)

-}

-- | rearrange a list of statements using ApplicativeDoStmt.  See
-- Note [ApplicativeDo].
rearrangeForApplicativeDo
  :: HsStmtContext Name
  -> [(ExprLStmt Name, FreeVars)]
  -> RnM ([ExprLStmt Name], FreeVars)

rearrangeForApplicativeDo _ [] = return ([], emptyNameSet)
rearrangeForApplicativeDo ctxt stmts0 = do
  (stmts', fvs) <- ado ctxt stmts [last] last_fvs
  return (stmts', fvs)
  where (stmts,(last,last_fvs)) = findLast stmts0
        findLast [] = error "findLast"
        findLast [last] = ([],last)
        findLast (x:xs) = (x:rest,last) where (rest,last) = findLast xs

-- | The ApplicativeDo transformation.
ado
  :: HsStmtContext Name
  -> [(ExprLStmt Name, FreeVars)] -- ^ input statements
  -> [ExprLStmt Name]             -- ^ the "tail"
  -> FreeVars                                -- ^ free variables of the tail
  -> RnM ( [ExprLStmt Name]       -- ( output statements,
         , FreeVars )                        -- , things we needed
                                             --    e.g. <$>, <*>, join )

ado _ctxt []        tail _ = return (tail, emptyNameSet)

-- If we have a single bind, and we can do it without a join, transform
-- to an ApplicativeStmt.  This corresponds to the rule
--   dsBlock [pat <- rhs] (return expr) = expr <$> rhs
-- In the spec, but we do it here rather than in the desugarer,
-- because we need the typechecker to typecheck the <$> form rather than
-- the bind form, which would give rise to a Monad constraint.
ado ctxt [(L _ (BindStmt pat rhs _ _ _),_)] tail _
  | isIrrefutableHsPat pat, (False,tail') <- needJoin tail
    -- WARNING: isIrrefutableHsPat on (HsPat Name) doesn't have enough info
    --          to know which types have only one constructor.  So only
    --          tuples come out as irrefutable; other single-constructor
    --          types, and newtypes, will not.  See the code for
    --          isIrrefuatableHsPat
  = mkApplicativeStmt ctxt [ApplicativeArgOne pat rhs] False tail'

ado _ctxt [(one,_)] tail _ = return (one:tail, emptyNameSet)

ado ctxt stmts tail tail_fvs =
  case segments stmts of  -- chop into segments
    [] -> panic "ado"
    [one] ->
      -- one indivisible segment, divide it by adding a bind
      adoSegment ctxt one tail tail_fvs
    segs ->
      -- multiple segments; recursively transform the segments, and
      -- combine into an ApplicativeStmt
      do { pairs <- mapM (adoSegmentArg ctxt tail_fvs) segs
         ; let (stmts', fvss) = unzip pairs
         ; let (need_join, tail') = needJoin tail
         ; (stmts, fvs) <- mkApplicativeStmt ctxt stmts' need_join tail'
         ; return (stmts, unionNameSets (fvs:fvss)) }

-- | Deal with an indivisible segment.  We pick a place to insert a
-- bind (it will actually be a join), and recursively transform the
-- two halves.
adoSegment
  :: HsStmtContext Name
  -> [(ExprLStmt Name, FreeVars)]
  -> [ExprLStmt Name]
  -> FreeVars
  -> RnM ( [ExprLStmt Name], FreeVars )
adoSegment ctxt stmts tail tail_fvs
 = do {  -- choose somewhere to put a bind
        let (before,after) = splitSegment stmts
      ; (stmts1, fvs1) <- ado ctxt after tail tail_fvs
      ; let tail1_fvs = unionNameSets (tail_fvs : map snd after)
      ; (stmts2, fvs2) <- ado ctxt before stmts1 tail1_fvs
      ; return (stmts2, fvs1 `plusFV` fvs2) }

-- | Given a segment, make an ApplicativeArg.  Here we recursively
-- call adoSegment on the segment's contents to extract any further
-- available parallelism.
adoSegmentArg
  :: HsStmtContext Name
  -> FreeVars
  -> [(ExprLStmt Name, FreeVars)]
  -> RnM (ApplicativeArg Name Name, FreeVars)
adoSegmentArg _ _ [(L _ (BindStmt pat exp _ _ _),_)] =
  return (ApplicativeArgOne pat exp, emptyFVs)
adoSegmentArg ctxt tail_fvs stmts =
  do { let pvarset = mkNameSet (concatMap (collectStmtBinders.unLoc.fst) stmts)
                      `intersectNameSet` tail_fvs
           pvars = nameSetElems pvarset
           pat = mkBigLHsVarPatTup pvars
           tup = mkBigLHsVarTup pvars
     ; (stmts',fvs2) <- adoSegment ctxt stmts [] pvarset
     ; (mb_ret, fvs1) <-
          if | L _ ApplicativeStmt{} <- last stmts' ->
               return (unLoc tup, emptyNameSet)
             | otherwise -> do
               (ret,fvs) <- lookupStmtNamePoly ctxt returnMName
               return (HsApp (noLoc ret) tup, fvs)
     ; return ( ApplicativeArgMany stmts' mb_ret pat
              , fvs1 `plusFV` fvs2) }

-- | Divide a sequence of statements into segments, where no segment
-- depends on any variables defined by a statement in another segment.
segments
  :: [(ExprLStmt Name, FreeVars)]
  -> [[(ExprLStmt Name, FreeVars)]]
segments stmts = map fst $ merge $ reverse $ map reverse $ walk (reverse stmts)
  where
    allvars = mkNameSet (concatMap (collectStmtBinders.unLoc.fst) stmts)

    -- We would rather not have a segment that just has LetStmts in
    -- it, so combine those with an adjacent segment where possible.
    merge [] = []
    merge (seg : segs)
       = case rest of
          [] -> [(seg,all_lets)]
          ((s,s_lets):ss) | all_lets || s_lets
               -> (seg ++ s, all_lets && s_lets) : ss
          _otherwise -> (seg,all_lets) : rest
      where
        rest = merge segs
        all_lets = all (isLetStmt . fst) seg

    -- walk splits the statement sequence into segments, traversing
    -- the sequence from the back to the front, and keeping track of
    -- the set of free variables of the current segment.  Whenever
    -- this set of free variables is empty, we have a complete segment.
    walk :: [(ExprLStmt Name, FreeVars)] -> [[(ExprLStmt Name, FreeVars)]]
    walk [] = []
    walk ((stmt,fvs) : stmts) = ((stmt,fvs) : seg) : walk rest
      where (seg,rest) = chunter fvs' stmts
            (_, fvs') = stmtRefs stmt fvs

    chunter _ [] = ([], [])
    chunter vars ((stmt,fvs) : rest)
       | not (isEmptyNameSet vars)
       = ((stmt,fvs) : chunk, rest')
       where (chunk,rest') = chunter vars' rest
             (pvars, evars) = stmtRefs stmt fvs
             vars' = (vars `minusNameSet` pvars) `unionNameSet` evars
    chunter _ rest = ([], rest)

    stmtRefs stmt fvs
      | isLetStmt stmt = (pvars, fvs' `minusNameSet` pvars)
      | otherwise      = (pvars, fvs')
      where fvs' = fvs `intersectNameSet` allvars
            pvars = mkNameSet (collectStmtBinders (unLoc stmt))

isLetStmt :: LStmt a b -> Bool
isLetStmt (L _ LetStmt{}) = True
isLetStmt _ = False

-- | Find a "good" place to insert a bind in an indivisible segment.
-- This is the only place where we use heuristics.  The current
-- heuristic is to peel off the first group of independent statements
-- and put the bind after those.
splitSegment
  :: [(ExprLStmt Name, FreeVars)]
  -> ( [(ExprLStmt Name, FreeVars)]
     , [(ExprLStmt Name, FreeVars)] )
splitSegment [one,two] = ([one],[two])
  -- there is no choice when there are only two statements; this just saves
  -- some work in a common case.
splitSegment stmts
  | Just (lets,binds,rest) <- slurpIndependentStmts stmts
  =  if not (null lets)
       then (lets, binds++rest)
       else (lets++binds, rest)
  | otherwise
  = case stmts of
      (x:xs) -> ([x],xs)
      _other -> (stmts,[])

slurpIndependentStmts
   :: [(LStmt Name (Located (body Name)), FreeVars)]
   -> Maybe ( [(LStmt Name (Located (body Name)), FreeVars)] -- LetStmts
            , [(LStmt Name (Located (body Name)), FreeVars)] -- BindStmts
            , [(LStmt Name (Located (body Name)), FreeVars)] )
slurpIndependentStmts stmts = go [] [] emptyNameSet stmts
 where
  -- If we encounter a BindStmt that doesn't depend on a previous BindStmt
  -- in this group, then add it to the group.
  go lets indep bndrs ((L loc (BindStmt pat body bind_op fail_op ty), fvs) : rest)
    | isEmptyNameSet (bndrs `intersectNameSet` fvs)
    = go lets ((L loc (BindStmt pat body bind_op fail_op ty), fvs) : indep)
         bndrs' rest
    where bndrs' = bndrs `unionNameSet` mkNameSet (collectPatBinders pat)
  -- If we encounter a LetStmt that doesn't depend on a BindStmt in this
  -- group, then move it to the beginning, so that it doesn't interfere with
  -- grouping more BindStmts.
  -- TODO: perhaps we shouldn't do this if there are any strict bindings,
  -- because we might be moving evaluation earlier.
  go lets indep bndrs ((L loc (LetStmt binds), fvs) : rest)
    | isEmptyNameSet (bndrs `intersectNameSet` fvs)
    = go ((L loc (LetStmt binds), fvs) : lets) indep bndrs rest
  go _ []  _ _ = Nothing
  go _ [_] _ _ = Nothing
  go lets indep _ stmts = Just (reverse lets, reverse indep, stmts)

-- | Build an ApplicativeStmt, and strip the "return" from the tail
-- if necessary.
--
-- For example, if we start with
--   do x <- E1; y <- E2; return (f x y)
-- then we get
--   do (E1[x] | E2[y]); f x y
--
-- the LastStmt in this case has the return removed, but we set the
-- flag on the LastStmt to indicate this, so that we can print out the
-- original statement correctly in error messages.  It is easier to do
-- it this way rather than try to ignore the return later in both the
-- typechecker and the desugarer (I tried it that way first!).
mkApplicativeStmt
  :: HsStmtContext Name
  -> [ApplicativeArg Name Name]         -- ^ The args
  -> Bool                               -- ^ True <=> need a join
  -> [ExprLStmt Name]        -- ^ The body statements
  -> RnM ([ExprLStmt Name], FreeVars)
mkApplicativeStmt ctxt args need_join body_stmts
  = do { (fmap_op, fvs1) <- lookupStmtName ctxt fmapName
       ; (ap_op, fvs2) <- lookupStmtName ctxt apAName
       ; (mb_join, fvs3) <-
           if need_join then
             do { (join_op, fvs) <- lookupStmtName ctxt joinMName
                ; return (Just join_op, fvs) }
           else
             return (Nothing, emptyNameSet)
       ; let applicative_stmt = noLoc $ ApplicativeStmt
               (zip (fmap_op : repeat ap_op) args)
               mb_join
               placeHolderType
       ; return ( applicative_stmt : body_stmts
                , fvs1 `plusFV` fvs2 `plusFV` fvs3) }

-- | Given the statements following an ApplicativeStmt, determine whether
-- we need a @join@ or not, and remove the @return@ if necessary.
needJoin :: [ExprLStmt Name] -> (Bool, [ExprLStmt Name])
needJoin [] = (False, [])  -- we're in an ApplicativeArg
needJoin [L loc (LastStmt e _ t)]
 | Just arg <- isReturnApp e = (False, [L loc (LastStmt arg True t)])
needJoin stmts = (True, stmts)

-- | @Just e@, if the expression is @return e@, otherwise @Nothing@
isReturnApp :: LHsExpr Name -> Maybe (LHsExpr Name)
isReturnApp (L _ (HsPar expr)) = isReturnApp expr
isReturnApp (L _ (HsApp f arg))
  | is_return f = Just arg
  | otherwise = Nothing
 where
  is_return (L _ (HsPar e)) = is_return e
  is_return (L _ (HsAppType e _)) = is_return e
  is_return (L _ (HsVar (L _ r))) = r == returnMName || r == pureAName
       -- TODO: I don't know how to get this right for rebindable syntax
  is_return _ = False
isReturnApp _ = Nothing


{-
************************************************************************
*                                                                      *
\subsubsection{Errors}
*                                                                      *
************************************************************************
-}

checkEmptyStmts :: HsStmtContext Name -> RnM ()
-- We've seen an empty sequence of Stmts... is that ok?
checkEmptyStmts ctxt
  = unless (okEmpty ctxt) (addErr (emptyErr ctxt))

okEmpty :: HsStmtContext a -> Bool
okEmpty (PatGuard {}) = True
okEmpty _             = False

emptyErr :: HsStmtContext Name -> SDoc
emptyErr (ParStmtCtxt {})   = text "Empty statement group in parallel comprehension"
emptyErr (TransStmtCtxt {}) = text "Empty statement group preceding 'group' or 'then'"
emptyErr ctxt               = text "Empty" <+> pprStmtContext ctxt

----------------------
checkLastStmt :: Outputable (body RdrName) => HsStmtContext Name
              -> LStmt RdrName (Located (body RdrName))
              -> RnM (LStmt RdrName (Located (body RdrName)))
checkLastStmt ctxt lstmt@(L loc stmt)
  = case ctxt of
      ListComp  -> check_comp
      MonadComp -> check_comp
      PArrComp  -> check_comp
      ArrowExpr -> check_do
      DoExpr    -> check_do
      MDoExpr   -> check_do
      _         -> check_other
  where
    check_do    -- Expect BodyStmt, and change it to LastStmt
      = case stmt of
          BodyStmt e _ _ _ -> return (L loc (mkLastStmt e))
          LastStmt {}      -> return lstmt   -- "Deriving" clauses may generate a
                                             -- LastStmt directly (unlike the parser)
          _                -> do { addErr (hang last_error 2 (ppr stmt)); return lstmt }
    last_error = (text "The last statement in" <+> pprAStmtContext ctxt
                  <+> text "must be an expression")

    check_comp  -- Expect LastStmt; this should be enforced by the parser!
      = case stmt of
          LastStmt {} -> return lstmt
          _           -> pprPanic "checkLastStmt" (ppr lstmt)

    check_other -- Behave just as if this wasn't the last stmt
      = do { checkStmt ctxt lstmt; return lstmt }

-- Checking when a particular Stmt is ok
checkStmt :: HsStmtContext Name
          -> LStmt RdrName (Located (body RdrName))
          -> RnM ()
checkStmt ctxt (L _ stmt)
  = do { dflags <- getDynFlags
       ; case okStmt dflags ctxt stmt of
           IsValid        -> return ()
           NotValid extra -> addErr (msg $$ extra) }
  where
   msg = sep [ text "Unexpected" <+> pprStmtCat stmt <+> ptext (sLit "statement")
             , text "in" <+> pprAStmtContext ctxt ]

pprStmtCat :: Stmt a body -> SDoc
pprStmtCat (TransStmt {})     = text "transform"
pprStmtCat (LastStmt {})      = text "return expression"
pprStmtCat (BodyStmt {})      = text "body"
pprStmtCat (BindStmt {})      = text "binding"
pprStmtCat (LetStmt {})       = text "let"
pprStmtCat (RecStmt {})       = text "rec"
pprStmtCat (ParStmt {})       = text "parallel"
pprStmtCat (ApplicativeStmt {}) = panic "pprStmtCat: ApplicativeStmt"

------------
emptyInvalid :: Validity  -- Payload is the empty document
emptyInvalid = NotValid Outputable.empty

okStmt, okDoStmt, okCompStmt, okParStmt, okPArrStmt
   :: DynFlags -> HsStmtContext Name
   -> Stmt RdrName (Located (body RdrName)) -> Validity
-- Return Nothing if OK, (Just extra) if not ok
-- The "extra" is an SDoc that is appended to an generic error message

okStmt dflags ctxt stmt
  = case ctxt of
      PatGuard {}        -> okPatGuardStmt stmt
      ParStmtCtxt ctxt   -> okParStmt  dflags ctxt stmt
      DoExpr             -> okDoStmt   dflags ctxt stmt
      MDoExpr            -> okDoStmt   dflags ctxt stmt
      ArrowExpr          -> okDoStmt   dflags ctxt stmt
      GhciStmtCtxt       -> okDoStmt   dflags ctxt stmt
      ListComp           -> okCompStmt dflags ctxt stmt
      MonadComp          -> okCompStmt dflags ctxt stmt
      PArrComp           -> okPArrStmt dflags ctxt stmt
      TransStmtCtxt ctxt -> okStmt dflags ctxt stmt

-------------
okPatGuardStmt :: Stmt RdrName (Located (body RdrName)) -> Validity
okPatGuardStmt stmt
  = case stmt of
      BodyStmt {} -> IsValid
      BindStmt {} -> IsValid
      LetStmt {}  -> IsValid
      _           -> emptyInvalid

-------------
okParStmt dflags ctxt stmt
  = case stmt of
      LetStmt (L _ (HsIPBinds {})) -> emptyInvalid
      _                            -> okStmt dflags ctxt stmt

----------------
okDoStmt dflags ctxt stmt
  = case stmt of
       RecStmt {}
         | LangExt.RecursiveDo `xopt` dflags -> IsValid
         | ArrowExpr <- ctxt -> IsValid    -- Arrows allows 'rec'
         | otherwise         -> NotValid (text "Use RecursiveDo")
       BindStmt {} -> IsValid
       LetStmt {}  -> IsValid
       BodyStmt {} -> IsValid
       _           -> emptyInvalid

----------------
okCompStmt dflags _ stmt
  = case stmt of
       BindStmt {} -> IsValid
       LetStmt {}  -> IsValid
       BodyStmt {} -> IsValid
       ParStmt {}
         | LangExt.ParallelListComp `xopt` dflags -> IsValid
         | otherwise -> NotValid (text "Use ParallelListComp")
       TransStmt {}
         | LangExt.TransformListComp `xopt` dflags -> IsValid
         | otherwise -> NotValid (text "Use TransformListComp")
       RecStmt {}  -> emptyInvalid
       LastStmt {} -> emptyInvalid  -- Should not happen (dealt with by checkLastStmt)
       ApplicativeStmt {} -> emptyInvalid

----------------
okPArrStmt dflags _ stmt
  = case stmt of
       BindStmt {} -> IsValid
       LetStmt {}  -> IsValid
       BodyStmt {} -> IsValid
       ParStmt {}
         | LangExt.ParallelListComp `xopt` dflags -> IsValid
         | otherwise -> NotValid (text "Use ParallelListComp")
       TransStmt {} -> emptyInvalid
       RecStmt {}   -> emptyInvalid
       LastStmt {}  -> emptyInvalid  -- Should not happen (dealt with by checkLastStmt)
       ApplicativeStmt {} -> emptyInvalid

---------
checkTupleSection :: [LHsTupArg RdrName] -> RnM ()
checkTupleSection args
  = do  { tuple_section <- xoptM LangExt.TupleSections
        ; checkErr (all tupArgPresent args || tuple_section) msg }
  where
    msg = text "Illegal tuple section: use TupleSections"

---------
sectionErr :: HsExpr RdrName -> SDoc
sectionErr expr
  = hang (text "A section must be enclosed in parentheses")
       2 (text "thus:" <+> (parens (ppr expr)))

patSynErr :: HsExpr RdrName -> RnM (HsExpr Name, FreeVars)
patSynErr e = do { addErr (sep [text "Pattern syntax in expression context:",
                                nest 4 (ppr e)] $$
                           text "Did you mean to enable TypeApplications?")
                 ; return (EWildPat, emptyFVs) }

badIpBinds :: Outputable a => SDoc -> a -> SDoc
badIpBinds what binds
  = hang (text "Implicit-parameter bindings illegal in" <+> what)
         2 (ppr binds)
