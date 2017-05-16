{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[TcMovectle]{Typechecking a whole module}

https://ghc.haskell.org/trac/ghc/wiki/Commentary/Compiler/TypeChecker
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NondecreasingIndentation #-}

module TcRnDriver (
#ifdef GHCI
        tcRnStmt, tcRnExpr, tcRnType,
        tcRnImportDecls,
        tcRnLookupRdrName,
        getModuleInterface,
        tcRnDeclsi,
        isGHCiMonad,
        runTcInteractive,    -- Used by GHC API clients (Trac #8878)
#endif
        tcRnLookupName,
        tcRnGetInfo,
        tcRnModule, tcRnModuleTcRnM,
        tcTopSrcDecls,
    ) where

#ifdef GHCI
import {-# SOURCE #-} TcSplice ( finishTH )
import RnSplice ( rnTopSpliceDecls, traceSplice, SpliceInfo(..) )
import IfaceEnv( externaliseName )
import TcHsType
import TcMatches
import Inst( deeplyInstantiate )
import RnTypes
import RnExpr
import MkId
import TidyPgm    ( globaliseAndTidyId )
import TysWiredIn ( unitTy, mkListTy )
import DynamicLoading ( loadPlugins )
import Plugins ( tcPlugin )
#endif

import DynFlags
import StaticFlags
import HsSyn
import PrelNames
import RdrName
import TcHsSyn
import TcExpr
import TcRnMonad
import TcEvidence
import PprTyThing( pprTyThing )
import Coercion( pprCoAxiom )
import CoreFVs( orphNamesOfFamInst )
import FamInst
import InstEnv
import FamInstEnv
import TcAnnotations
import TcBinds
import HeaderInfo       ( mkPrelImports )
import TcDefaults
import TcEnv
import TcRules
import TcForeign
import TcInstDcls
import TcIface
import TcMType
import TcType
import MkIface
import TcSimplify
import TcTyClsDecls
import TcTypeable ( mkTypeableBinds )
import LoadIface
import TidyPgm    ( mkBootModDetailsTc )
import RnNames
import RnEnv
import RnSource
import ErrUtils
import Id
import IdInfo
import VarEnv
import Module
import UniqFM
import Name
import NameEnv
import NameSet
import Avail
import TyCon
import SrcLoc
import HscTypes
import ListSetOps
import Outputable
import ConLike
import DataCon
import PatSyn
import Type
import Class
import BasicTypes hiding( SuccessFlag(..) )
import CoAxiom
import Annotations
import Data.List ( sortBy )
import Data.Ord
import FastString
import Maybes
import Util
import Bag
import Inst (tcGetInsts)
import qualified GHC.LanguageExtensions as LangExt

import Control.Monad

#include "HsVersions.h"

{-
************************************************************************
*                                                                      *
        Typecheck and rename a module
*                                                                      *
************************************************************************
-}

-- | Top level entry point for typechecker and renamer
tcRnModule :: HscEnv
           -> HscSource
           -> Bool              -- True <=> save renamed syntax
           -> HsParsedModule
           -> IO (Messages, Maybe TcGblEnv)

tcRnModule hsc_env hsc_src save_rn_syntax
   parsedModule@HsParsedModule {hpm_module=L loc this_module}
 | RealSrcSpan real_loc <- loc
 = withTiming (pure dflags)
              (text "Renamer/typechecker"<+>brackets (ppr this_mod))
              (const ()) $
   initTc hsc_env hsc_src save_rn_syntax this_mod real_loc $
          withTcPlugins hsc_env $
          tcRnModuleTcRnM hsc_env hsc_src parsedModule pair

  | otherwise
  = return ((emptyBag, unitBag err_msg), Nothing)

  where
    dflags = hsc_dflags hsc_env
    err_msg = mkPlainErrMsg (hsc_dflags hsc_env) loc $
              text "Module does not have a RealSrcSpan:" <+> ppr this_mod

    this_pkg = thisPackage (hsc_dflags hsc_env)

    pair :: (Module, SrcSpan)
    pair@(this_mod,_)
      | Just (L mod_loc mod) <- hsmodName this_module
      = (mkModule this_pkg mod, mod_loc)

      | otherwise   -- 'module M where' is omitted
      = (mAIN, srcLocSpan (srcSpanStart loc))


-- To be called at the beginning of renaming hsig files.
-- If we're processing a signature, load up the RdrEnv
-- specified by sig-of so that
-- when we process top-level bindings, we pull in the right
-- original names.  We also need to add in dependencies from
-- the implementation (orphans, family instances, packages),
-- similar to how rnImportDecl handles things.
-- ToDo: Handle SafeHaskell
tcRnSignature :: DynFlags -> HscSource -> TcRn TcGblEnv
tcRnSignature dflags hsc_src
 = do { tcg_env <- getGblEnv ;
        case tcg_sig_of tcg_env of {
          Just sof
           | hsc_src /= HsigFile -> do
                { addErr (text "Illegal -sig-of specified for non hsig")
                ; return tcg_env
                }
           | otherwise -> do
            { sig_iface <- initIfaceTcRn $ loadSysInterface (text "sig-of") sof
            ; let { gr = mkGlobalRdrEnv
                              (gresFromAvails Nothing (mi_exports sig_iface))
                  ; avails = calculateAvails dflags
                                    sig_iface False{- safe -} False{- boot -} }
            ; return (tcg_env
                { tcg_impl_rdr_env = Just gr
                , tcg_imports = tcg_imports tcg_env `plusImportAvails` avails
                })
            } ;
          Nothing
             | HsigFile <- hsc_src
             , HscNothing <- hscTarget dflags -> do
                { return tcg_env
                }
             | HsigFile <- hsc_src -> do
                { addErr (text "Missing -sig-of for hsig")
                ; failM }
             | otherwise -> return tcg_env
        }
      }

checkHsigIface :: HscEnv -> TcGblEnv -> TcRn ()
checkHsigIface hsc_env tcg_env
  = case tcg_impl_rdr_env tcg_env of
      Just gr -> do { sig_details <- liftIO $ mkBootModDetailsTc hsc_env tcg_env
                    ; checkHsigIface' gr sig_details
                    }
      Nothing -> return ()

checkHsigIface' :: GlobalRdrEnv -> ModDetails -> TcRn ()
checkHsigIface' gr
  ModDetails { md_insts = sig_insts, md_fam_insts = sig_fam_insts,
               md_types = sig_type_env, md_exports = sig_exports}
  = do { traceTc "checkHsigIface" $ vcat
           [ ppr sig_type_env, ppr sig_insts, ppr sig_exports ]
       ; mapM_ check_export sig_exports
       ; unless (null sig_fam_insts) $
           panic ("TcRnDriver.checkHsigIface: Cannot handle family " ++
                  "instances in hsig files yet...")
       ; mapM_ check_inst sig_insts
       ; failIfErrsM
       }
  where
    check_export sig_avail
      -- Skip instances, we'll check them later
      | name `elem` dfun_names = return ()
      | otherwise = do
        { -- Lookup local environment only (don't want to accidentally pick
          -- up the backing copy.)  We consult tcg_type_env because we want
          -- to pick up wired in names too (which get dropped by the iface
          -- creation process); it's OK for a signature file to mention
          -- a wired in name.
          env <- getGblEnv
        ; case lookupNameEnv (tcg_type_env env) name of
            Nothing
                -- All this means is no local definition is available: but we
                -- could have created the export this way:
                --
                -- module ASig(f) where
                --      import B(f)
                --
                -- In this case, we have to just lookup the identifier in
                -- the backing implementation and make sure it matches.
                | [GRE { gre_name = name' }]
                    <- lookupGlobalRdrEnv gr (nameOccName name)
                , name == name' -> return ()
                -- TODO: Possibly give a different error if the identifier
                -- is exported, but it's a different original name
                | otherwise -> addErrAt (nameSrcSpan name)
                                (missingBootThing False name "exported by")
            Just sig_thing -> do {
          -- We use tcLookupImported_maybe because we want to EXCLUDE
          -- tcg_env.
        ; r <- tcLookupImported_maybe name
        ; case r of
            Failed err -> addErr err
            Succeeded real_thing -> checkBootDeclM False sig_thing real_thing
        }}
      where
        name          = availName sig_avail

    dfun_names = map getName sig_insts

    -- In general, for hsig files we can't assume that the implementing
    -- file actually implemented the instances (they may be reexported
    -- from elsewhere).  Where should we look for the instances?  We do
    -- the same as we would otherwise: consult the EPS.  This isn't
    -- perfect (we might conclude the module exports an instance
    -- when it doesn't, see #9422), but we will never refuse to compile
    -- something
    check_inst :: ClsInst -> TcM ()
    check_inst sig_inst
        = do eps <- getEps
             when (not (memberInstEnv (eps_inst_env eps) sig_inst)) $
               addErrTc (instMisMatch False sig_inst)

tcRnModuleTcRnM :: HscEnv
                -> HscSource
                -> HsParsedModule
                -> (Module, SrcSpan)
                -> TcRn TcGblEnv
-- Factored out separately from tcRnModule so that a Core plugin can
-- call the type checker directly
tcRnModuleTcRnM hsc_env hsc_src
                (HsParsedModule {
                   hpm_module =
                      (L loc (HsModule maybe_mod export_ies
                                       import_decls local_decls mod_deprec
                                       maybe_doc_hdr)),
                   hpm_src_files = src_files
                })
                (this_mod, prel_imp_loc)
 = setSrcSpan loc $
   do { let { dflags = hsc_dflags hsc_env
            ; explicit_mod_hdr = isJust maybe_mod } ;

        tcg_env <- tcRnSignature dflags hsc_src ;
        setGblEnv tcg_env $ do {

                -- Load the hi-boot interface for this module, if any
                -- We do this now so that the boot_names can be passed
                -- to tcTyAndClassDecls, because the boot_names are
                -- automatically considered to be loop breakers
                --
                -- Do this *after* tcRnImports, so that we know whether
                -- a module that we import imports us; and hence whether to
                -- look for a hi-boot file
        boot_info <- tcHiBootIface hsc_src this_mod ;
        setGblEnv (tcg_env { tcg_self_boot = boot_info }) $ do {

        -- Deal with imports; first add implicit prelude
        implicit_prelude <- xoptM LangExt.ImplicitPrelude;
        let { prel_imports = mkPrelImports (moduleName this_mod) prel_imp_loc
                                         implicit_prelude import_decls } ;

        whenWOptM Opt_WarnImplicitPrelude $
             when (notNull prel_imports) $
                  addWarn (Reason Opt_WarnImplicitPrelude) (implicitPreludeWarn) ;

        tcg_env <- {-# SCC "tcRnImports" #-}
                   tcRnImports hsc_env (prel_imports ++ import_decls) ;

          -- If the whole module is warned about or deprecated
          -- (via mod_deprec) record that in tcg_warns. If we do thereby add
          -- a WarnAll, it will override any subseqent depracations added to tcg_warns
        let { tcg_env1 = case mod_deprec of
                         Just (L _ txt) -> tcg_env { tcg_warns = WarnAll txt }
                         Nothing        -> tcg_env
            } ;

        setGblEnv tcg_env1 $ do {

                -- Rename and type check the declarations
        traceRn (text "rn1a") ;
        tcg_env <- if isHsBootOrSig hsc_src then
                        tcRnHsBootDecls hsc_src local_decls
                   else
                        {-# SCC "tcRnSrcDecls" #-}
                        tcRnSrcDecls explicit_mod_hdr local_decls ;
        setGblEnv tcg_env               $ do {

                -- Process the export list
        traceRn (text "rn4a: before exports");
        (rn_exports, tcg_env) <- rnExports explicit_mod_hdr export_ies tcg_env ;
        tcExports rn_exports ;
        traceRn (text "rn4b: after exports") ;

                -- Check that main is exported (must be after rnExports)
        checkMainExported tcg_env ;

        -- Compare the hi-boot iface (if any) with the real thing
        -- Must be done after processing the exports
        tcg_env <- checkHiBootIface tcg_env boot_info ;

        -- Compare the hsig tcg_env with the real thing
        checkHsigIface hsc_env tcg_env ;

        -- Nub out type class instances now that we've checked them,
        -- if we're compiling an hsig with sig-of.
        -- See Note [Signature files and type class instances]
        tcg_env <- (case tcg_sig_of tcg_env of
            Just _ -> return tcg_env {
                        tcg_inst_env = emptyInstEnv,
                        tcg_fam_inst_env = emptyFamInstEnv,
                        tcg_insts = [],
                        tcg_fam_insts = []
                        }
            Nothing -> return tcg_env) ;

        -- The new type env is already available to stuff slurped from
        -- interface files, via TcEnv.updateGlobalTypeEnv
        -- It's important that this includes the stuff in checkHiBootIface,
        -- because the latter might add new bindings for boot_dfuns,
        -- which may be mentioned in imported unfoldings

                -- Don't need to rename the Haddock documentation,
                -- it's not parsed by GHC anymore.
        tcg_env <- return (tcg_env { tcg_doc_hdr = maybe_doc_hdr }) ;

                -- Report unused names
        reportUnusedNames export_ies tcg_env ;

                -- add extra source files to tcg_dependent_files
        addDependentFiles src_files ;

                -- Dump output and return
        tcDump tcg_env ;
        return tcg_env
    }}}}}

implicitPreludeWarn :: SDoc
implicitPreludeWarn
  = text "Module `Prelude' implicitly imported"

{-
************************************************************************
*                                                                      *
                Import declarations
*                                                                      *
************************************************************************
-}

tcRnImports :: HscEnv -> [LImportDecl RdrName] -> TcM TcGblEnv
tcRnImports hsc_env import_decls
  = do  { (rn_imports, rdr_env, imports, hpc_info) <- rnImports import_decls ;

        ; this_mod <- getModule
        ; let { dep_mods :: ModuleNameEnv (ModuleName, IsBootInterface)
              ; dep_mods = imp_dep_mods imports

                -- We want instance declarations from all home-package
                -- modules below this one, including boot modules, except
                -- ourselves.  The 'except ourselves' is so that we don't
                -- get the instances from this module's hs-boot file.  This
                -- filtering also ensures that we don't see instances from
                -- modules batch (@--make@) compiled before this one, but
                -- which are not below this one.
              ; want_instances :: ModuleName -> Bool
              ; want_instances mod = mod `elemUFM` dep_mods
                                   && mod /= moduleName this_mod
              ; (home_insts, home_fam_insts) = hptInstances hsc_env
                                                            want_instances
              } ;

                -- Record boot-file info in the EPS, so that it's
                -- visible to loadHiBootInterface in tcRnSrcDecls,
                -- and any other incrementally-performed imports
        ; updateEps_ (\eps -> eps { eps_is_boot = dep_mods }) ;

                -- Update the gbl env
        ; updGblEnv ( \ gbl ->
            gbl {
              tcg_rdr_env      = tcg_rdr_env gbl `plusGlobalRdrEnv` rdr_env,
              tcg_imports      = tcg_imports gbl `plusImportAvails` imports,
              tcg_rn_imports   = rn_imports,
              tcg_inst_env     = extendInstEnvList (tcg_inst_env gbl) home_insts,
              tcg_fam_inst_env = extendFamInstEnvList (tcg_fam_inst_env gbl)
                                                      home_fam_insts,
              tcg_hpc          = hpc_info
            }) $ do {

        ; traceRn (text "rn1" <+> ppr (imp_dep_mods imports))
                -- Fail if there are any errors so far
                -- The error printing (if needed) takes advantage
                -- of the tcg_env we have now set
--      ; traceIf (text "rdr_env: " <+> ppr rdr_env)
        ; failIfErrsM

                -- Load any orphan-module and family instance-module
                -- interfaces, so that their rules and instance decls will be
                -- found.  But filter out a self hs-boot: these instances
                -- will be checked when we define them locally.
        ; loadModuleInterfaces (text "Loading orphan modules")
                               (filter (/= this_mod) (imp_orphs imports))

                -- Check type-family consistency
        ; traceRn (text "rn1: checking family instance consistency")
        ; let { dir_imp_mods = moduleEnvKeys
                             . imp_mods
                             $ imports }
        ; checkFamInstConsistency (imp_finsts imports) dir_imp_mods ;

        ; getGblEnv } }

{-
************************************************************************
*                                                                      *
        Type-checking the top level of a module
*                                                                      *
************************************************************************
-}

tcRnSrcDecls :: Bool  -- False => no 'module M(..) where' header at all
             -> [LHsDecl RdrName]               -- Declarations
             -> TcM TcGblEnv
        -- Returns the variables free in the decls
        -- Reason: solely to report unused imports and bindings
tcRnSrcDecls explicit_mod_hdr decls
 = do { -- Do all the declarations
      ; ((tcg_env, tcl_env), lie) <- captureConstraints $
              do { (tcg_env, tcl_env) <- tc_rn_src_decls decls ;
                 ; tcg_env <- setEnvs (tcg_env, tcl_env) $
                              checkMain explicit_mod_hdr
                 ; return (tcg_env, tcl_env) }
      ; setEnvs (tcg_env, tcl_env) $ do {

        -- Emit Typeable bindings
      ; tcg_env <- setGblEnv tcg_env mkTypeableBinds

      ; setGblEnv tcg_env $ do {

#ifdef GHCI
      ; finishTH
#endif /* GHCI */

        -- wanted constraints from static forms
      ; stWC <- tcg_static_wc <$> getGblEnv >>= readTcRef

             --         Finish simplifying class constraints
             --
             -- simplifyTop deals with constant or ambiguous InstIds.
             -- How could there be ambiguous ones?  They can only arise if a
             -- top-level decl falls under the monomorphism restriction
             -- and no subsequent decl instantiates its type.
             --
             -- We do this after checkMain, so that we use the type info
             -- that checkMain adds
             --
             -- We do it with both global and local env in scope:
             --  * the global env exposes the instances to simplifyTop
             --  * the local env exposes the local Ids to simplifyTop,
             --    so that we get better error messages (monomorphism restriction)
      ; new_ev_binds <- {-# SCC "simplifyTop" #-}
                        simplifyTop (andWC stWC lie)
      ; traceTc "Tc9" empty

      ; failIfErrsM     -- Don't zonk if there have been errors
                        -- It's a waste of time; and we may get debug warnings
                        -- about strangely-typed TyCons!
      ; traceTc "Tc10" empty

        -- Zonk the final code.  This must be done last.
        -- Even simplifyTop may do some unification.
        -- This pass also warns about missing type signatures
      ; let { TcGblEnv { tcg_type_env  = type_env,
                         tcg_binds     = binds,
                         tcg_ev_binds  = cur_ev_binds,
                         tcg_imp_specs = imp_specs,
                         tcg_rules     = rules,
                         tcg_vects     = vects,
                         tcg_fords     = fords } = tcg_env
            ; all_ev_binds = cur_ev_binds `unionBags` new_ev_binds } ;

      ; (bind_ids, ev_binds', binds', fords', imp_specs', rules', vects')
            <- {-# SCC "zonkTopDecls" #-}
               zonkTopDecls all_ev_binds binds rules vects
                            imp_specs fords ;
      ; traceTc "Tc11" empty

      ; let { final_type_env = extendTypeEnvWithIds type_env bind_ids
            ; tcg_env' = tcg_env { tcg_binds    = binds',
                                   tcg_ev_binds = ev_binds',
                                   tcg_imp_specs = imp_specs',
                                   tcg_rules    = rules',
                                   tcg_vects    = vects',
                                   tcg_fords    = fords' } } ;

      ; setGlobalTypeEnv tcg_env' final_type_env

   } } }

tc_rn_src_decls :: [LHsDecl RdrName]
                -> TcM (TcGblEnv, TcLclEnv)
-- Loops around dealing with each top level inter-splice group
-- in turn, until it's dealt with the entire module
tc_rn_src_decls ds
 = {-# SCC "tc_rn_src_decls" #-}
   do { (first_group, group_tail) <- findSplice ds
                -- If ds is [] we get ([], Nothing)

        -- Deal with decls up to, but not including, the first splice
      ; (tcg_env, rn_decls) <- rnTopSrcDecls first_group
                -- rnTopSrcDecls fails if there are any errors

#ifdef GHCI
        -- Get TH-generated top-level declarations and make sure they don't
        -- contain any splices since we don't handle that at the moment
      ; th_topdecls_var <- fmap tcg_th_topdecls getGblEnv
      ; th_ds <- readTcRef th_topdecls_var
      ; writeTcRef th_topdecls_var []

      ; (tcg_env, rn_decls) <-
            if null th_ds
            then return (tcg_env, rn_decls)
            else do { (th_group, th_group_tail) <- findSplice th_ds
                    ; case th_group_tail of
                        { Nothing -> return () ;
                        ; Just (SpliceDecl (L loc _) _, _)
                            -> setSrcSpan loc $
                               addErr (text "Declaration splices are not permitted inside top-level declarations added with addTopDecls")
                        } ;

                    -- Rename TH-generated top-level declarations
                    ; (tcg_env, th_rn_decls) <- setGblEnv tcg_env $
                      rnTopSrcDecls th_group

                    -- Dump generated top-level declarations
                    ; let msg = "top-level declarations added with addTopDecls"
                    ; traceSplice $ SpliceInfo { spliceDescription = msg
                                               , spliceIsDecl    = True
                                               , spliceSource    = Nothing
                                               , spliceGenerated = ppr th_rn_decls }

                    ; return (tcg_env, appendGroups rn_decls th_rn_decls)
                    }
#endif /* GHCI */

      -- Type check all declarations
      ; (tcg_env, tcl_env) <- setGblEnv tcg_env $
                              tcTopSrcDecls rn_decls

        -- If there is no splice, we're nearly done
      ; setEnvs (tcg_env, tcl_env) $
        case group_tail of
          { Nothing -> return (tcg_env, tcl_env)

#ifndef GHCI
            -- There shouldn't be a splice
          ; Just (SpliceDecl {}, _) ->
            failWithTc (text "Can't do a top-level splice; need a bootstrapped compiler")
          }
#else
            -- If there's a splice, we must carry on
          ; Just (SpliceDecl (L loc splice) _, rest_ds) ->
            do { recordTopLevelSpliceLoc loc

                 -- Rename the splice expression, and get its supporting decls
               ; (spliced_decls, splice_fvs) <- checkNoErrs (rnTopSpliceDecls
                                                             splice)

                 -- Glue them on the front of the remaining decls and loop
               ; setGblEnv (tcg_env `addTcgDUs` usesOnly splice_fvs) $
                 tc_rn_src_decls (spliced_decls ++ rest_ds)
               }
          }
#endif /* GHCI */
      }

{-
************************************************************************
*                                                                      *
        Compiling hs-boot source files, and
        comparing the hi-boot interface with the real thing
*                                                                      *
************************************************************************
-}

tcRnHsBootDecls :: HscSource -> [LHsDecl RdrName] -> TcM TcGblEnv
tcRnHsBootDecls hsc_src decls
   = do { (first_group, group_tail) <- findSplice decls

                -- Rename the declarations
        ; (tcg_env, HsGroup { hs_tyclds = tycl_decls
                            , hs_instds = inst_decls
                            , hs_derivds = deriv_decls
                            , hs_fords  = for_decls
                            , hs_defds  = def_decls
                            , hs_ruleds = rule_decls
                            , hs_vects  = vect_decls
                            , hs_annds  = _
                            , hs_valds  = ValBindsOut val_binds val_sigs })
              <- rnTopSrcDecls first_group
        -- The empty list is for extra dependencies coming from .hs-boot files
        -- See Note [Extra dependencies from .hs-boot files] in RnSource
        ; (gbl_env, lie) <- captureConstraints $ setGblEnv tcg_env $ do {

                -- Check for illegal declarations
        ; case group_tail of
             Just (SpliceDecl d _, _) -> badBootDecl hsc_src "splice" d
             Nothing                  -> return ()
        ; mapM_ (badBootDecl hsc_src "foreign") for_decls
        ; mapM_ (badBootDecl hsc_src "default") def_decls
        ; mapM_ (badBootDecl hsc_src "rule")    rule_decls
        ; mapM_ (badBootDecl hsc_src "vect")    vect_decls

                -- Typecheck type/class/instance decls
        ; traceTc "Tc2 (boot)" empty
        ; (tcg_env, inst_infos, _deriv_binds)
             <- tcTyClsInstDecls tycl_decls inst_decls deriv_decls val_binds
        ; setGblEnv tcg_env     $ do {

                -- Emit Typeable declarations
        ; tcg_env <- setGblEnv tcg_env mkTypeableBinds
        ; setGblEnv tcg_env $ do {

                -- Typecheck value declarations
        ; traceTc "Tc5" empty
        ; val_ids <- tcHsBootSigs val_binds val_sigs

                -- Wrap up
                -- No simplification or zonking to do
        ; traceTc "Tc7a" empty
        ; gbl_env <- getGblEnv

                -- Make the final type-env
                -- Include the dfun_ids so that their type sigs
                -- are written into the interface file.
        ; let { type_env0 = tcg_type_env gbl_env
              ; type_env1 = extendTypeEnvWithIds type_env0 val_ids
              -- Don't add the dictionaries for hsig, we don't actually want
              -- to /define/ the instance
              ; type_env2 | HsigFile <- hsc_src = type_env1
                          | otherwise = extendTypeEnvWithIds type_env1 dfun_ids
              ; dfun_ids = map iDFunId inst_infos
              }

        ; setGlobalTypeEnv gbl_env type_env2
   }}}
   ; traceTc "boot" (ppr lie); return gbl_env }

badBootDecl :: HscSource -> String -> Located decl -> TcM ()
badBootDecl hsc_src what (L loc _)
  = addErrAt loc (char 'A' <+> text what
      <+> text "declaration is not (currently) allowed in a"
      <+> (case hsc_src of
            HsBootFile -> text "hs-boot"
            HsigFile -> text "hsig"
            _ -> panic "badBootDecl: should be an hsig or hs-boot file")
      <+> text "file")

{-
Once we've typechecked the body of the module, we want to compare what
we've found (gathered in a TypeEnv) with the hi-boot details (if any).
-}

checkHiBootIface :: TcGblEnv -> SelfBootInfo -> TcM TcGblEnv
-- Compare the hi-boot file for this module (if there is one)
-- with the type environment we've just come up with
-- In the common case where there is no hi-boot file, the list
-- of boot_names is empty.

checkHiBootIface tcg_env boot_info
  | NoSelfBoot <- boot_info  -- Common case
  = return tcg_env

  | HsBootFile <- tcg_src tcg_env   -- Current module is already a hs-boot file!
  = return tcg_env

  | SelfBoot { sb_mds = boot_details } <- boot_info
  , TcGblEnv { tcg_binds    = binds
             , tcg_insts    = local_insts
             , tcg_type_env = local_type_env
             , tcg_exports  = local_exports } <- tcg_env
  = do  { dfun_prs <- checkHiBootIface' local_insts local_type_env
                                        local_exports boot_details
        ; let boot_dfuns = map fst dfun_prs
              dfun_binds = listToBag [ mkVarBind boot_dfun (nlHsVar dfun)
                                     | (boot_dfun, dfun) <- dfun_prs ]
              type_env'  = extendTypeEnvWithIds local_type_env boot_dfuns
              tcg_env'   = tcg_env { tcg_binds = binds `unionBags` dfun_binds }

        ; setGlobalTypeEnv tcg_env' type_env' }
             -- Update the global type env *including* the knot-tied one
             -- so that if the source module reads in an interface unfolding
             -- mentioning one of the dfuns from the boot module, then it
             -- can "see" that boot dfun.   See Trac #4003

  | otherwise = panic "checkHiBootIface: unreachable code"

checkHiBootIface' :: [ClsInst] -> TypeEnv -> [AvailInfo]
                  -> ModDetails -> TcM [(Id, Id)]
-- Variant which doesn't require a full TcGblEnv; you could get the
-- local components from another ModDetails.
--
-- We return a list of "impedance-matching" bindings for the dfuns
-- defined in the hs-boot file, such as
--           $fxEqT = $fEqT
-- We need these because the module and hi-boot file might differ in
-- the name it chose for the dfun.

checkHiBootIface'
        local_insts local_type_env local_exports
        (ModDetails { md_insts = boot_insts, md_fam_insts = boot_fam_insts,
                      md_types = boot_type_env, md_exports = boot_exports })
  = do  { traceTc "checkHiBootIface" $ vcat
             [ ppr boot_type_env, ppr boot_insts, ppr boot_exports]

                -- Check the exports of the boot module, one by one
        ; mapM_ check_export boot_exports

                -- Check for no family instances
        ; unless (null boot_fam_insts) $
            panic ("TcRnDriver.checkHiBootIface: Cannot handle family " ++
                   "instances in boot files yet...")
            -- FIXME: Why?  The actual comparison is not hard, but what would
            --        be the equivalent to the dfun bindings returned for class
            --        instances?  We can't easily equate tycons...

                -- Check instance declarations
                -- and generate an impedance-matching binding
        ; mb_dfun_prs <- mapM check_inst boot_insts

        ; failIfErrsM

        ; return (catMaybes mb_dfun_prs) }

  where
    check_export boot_avail     -- boot_avail is exported by the boot iface
      | name `elem` dfun_names = return ()
      | isWiredInName name     = return ()      -- No checking for wired-in names.  In particular,
                                                -- 'error' is handled by a rather gross hack
                                                -- (see comments in GHC.Err.hs-boot)

        -- Check that the actual module exports the same thing
      | not (null missing_names)
      = addErrAt (nameSrcSpan (head missing_names))
                 (missingBootThing True (head missing_names) "exported by")

        -- If the boot module does not *define* the thing, we are done
        -- (it simply re-exports it, and names match, so nothing further to do)
      | isNothing mb_boot_thing = return ()

        -- Check that the actual module also defines the thing, and
        -- then compare the definitions
      | Just real_thing <- lookupTypeEnv local_type_env name,
        Just boot_thing <- mb_boot_thing
      = checkBootDeclM True boot_thing real_thing

      | otherwise
      = addErrTc (missingBootThing True name "defined in")
      where
        name          = availName boot_avail
        mb_boot_thing = lookupTypeEnv boot_type_env name
        missing_names = case lookupNameEnv local_export_env name of
                          Nothing    -> [name]
                          Just avail -> availNames boot_avail `minusList` availNames avail

    dfun_names = map getName boot_insts

    local_export_env :: NameEnv AvailInfo
    local_export_env = availsToNameEnv local_exports

    check_inst :: ClsInst -> TcM (Maybe (Id, Id))
        -- Returns a pair of the boot dfun in terms of the equivalent
        -- real dfun. Delicate (like checkBootDecl) because it depends
        -- on the types lining up precisely even to the ordering of
        -- the type variables in the foralls.
    check_inst boot_inst
        = case [dfun | inst <- local_insts,
                       let dfun = instanceDFunId inst,
                       idType dfun `eqType` boot_dfun_ty ] of
            [] -> do { traceTc "check_inst" $ vcat
                          [ text "local_insts"  <+> vcat (map (ppr . idType . instanceDFunId) local_insts)
                          , text "boot_inst"    <+> ppr boot_inst
                          , text "boot_dfun_ty" <+> ppr boot_dfun_ty
                          ]
                     ; addErrTc (instMisMatch True boot_inst)
                     ; return Nothing }
            (dfun:_) -> return (Just (local_boot_dfun, dfun))
                     where
                        local_boot_dfun = Id.mkExportedVanillaId boot_dfun_name (idType dfun)
                           -- Name from the /boot-file/ ClsInst, but type from the dfun
                           -- defined in /this module/.  That ensures that the TyCon etc
                           -- inside the type are the ones defined in this module, not
                           -- the ones gotten from the hi-boot file, which may have
                           -- a lot less info (Trac #T8743, comment:10).
        where
          boot_dfun      = instanceDFunId boot_inst
          boot_dfun_ty   = idType boot_dfun
          boot_dfun_name = idName boot_dfun

-- This has to compare the TyThing from the .hi-boot file to the TyThing
-- in the current source file.  We must be careful to allow alpha-renaming
-- where appropriate, and also the boot declaration is allowed to omit
-- constructors and class methods.
--
-- See rnfail055 for a good test of this stuff.

-- | Compares two things for equivalence between boot-file and normal code,
-- reporting an error if they don't match up.
checkBootDeclM :: Bool  -- ^ True <=> an hs-boot file (could also be a sig)
               -> TyThing -> TyThing -> TcM ()
checkBootDeclM is_boot boot_thing real_thing
  = whenIsJust (checkBootDecl boot_thing real_thing) $ \ err ->
       addErrAt (nameSrcSpan (getName boot_thing))
                (bootMisMatch is_boot err real_thing boot_thing)

-- | Compares the two things for equivalence between boot-file and normal
-- code. Returns @Nothing@ on success or @Just "some helpful info for user"@
-- failure. If the difference will be apparent to the user, @Just empty@ is
-- perfectly suitable.
checkBootDecl :: TyThing -> TyThing -> Maybe SDoc

checkBootDecl (AnId id1) (AnId id2)
  = ASSERT(id1 == id2)
    check (idType id1 `eqType` idType id2)
          (text "The two types are different")

checkBootDecl (ATyCon tc1) (ATyCon tc2)
  = checkBootTyCon tc1 tc2

checkBootDecl (AConLike (RealDataCon dc1)) (AConLike (RealDataCon _))
  = pprPanic "checkBootDecl" (ppr dc1)

checkBootDecl _ _ = Just empty -- probably shouldn't happen

-- | Combines two potential error messages
andThenCheck :: Maybe SDoc -> Maybe SDoc -> Maybe SDoc
Nothing `andThenCheck` msg     = msg
msg     `andThenCheck` Nothing = msg
Just d1 `andThenCheck` Just d2 = Just (d1 $$ d2)
infixr 0 `andThenCheck`

-- | If the test in the first parameter is True, succeed with @Nothing@;
-- otherwise, return the provided check
checkUnless :: Bool -> Maybe SDoc -> Maybe SDoc
checkUnless True  _ = Nothing
checkUnless False k = k

-- | Run the check provided for every pair of elements in the lists.
-- The provided SDoc should name the element type, in the plural.
checkListBy :: (a -> a -> Maybe SDoc) -> [a] -> [a] -> SDoc
            -> Maybe SDoc
checkListBy check_fun as bs whats = go [] as bs
  where
    herald = text "The" <+> whats <+> text "do not match"

    go []   [] [] = Nothing
    go docs [] [] = Just (hang (herald <> colon) 2 (vcat $ reverse docs))
    go docs (x:xs) (y:ys) = case check_fun x y of
      Just doc -> go (doc:docs) xs ys
      Nothing  -> go docs       xs ys
    go _    _  _ = Just (hang (herald <> colon)
                            2 (text "There are different numbers of" <+> whats))

-- | If the test in the first parameter is True, succeed with @Nothing@;
-- otherwise, fail with the given SDoc.
check :: Bool -> SDoc -> Maybe SDoc
check True  _   = Nothing
check False doc = Just doc

-- | A more perspicuous name for @Nothing@, for @checkBootDecl@ and friends.
checkSuccess :: Maybe SDoc
checkSuccess = Nothing

----------------
checkBootTyCon :: TyCon -> TyCon -> Maybe SDoc
checkBootTyCon tc1 tc2
  | not (eqType (tyConKind tc1) (tyConKind tc2))
  = Just $ text "The types have different kinds"    -- First off, check the kind

  | Just c1 <- tyConClass_maybe tc1
  , Just c2 <- tyConClass_maybe tc2
  , let (clas_tvs1, clas_fds1, sc_theta1, _, ats1, op_stuff1)
          = classExtraBigSig c1
        (clas_tvs2, clas_fds2, sc_theta2, _, ats2, op_stuff2)
          = classExtraBigSig c2
  , Just env <- eqVarBndrs emptyRnEnv2 clas_tvs1 clas_tvs2
  = let
       eqSig (id1, def_meth1) (id2, def_meth2)
         = check (name1 == name2)
                 (text "The names" <+> pname1 <+> text "and" <+> pname2 <+>
                  text "are different") `andThenCheck`
           check (eqTypeX env op_ty1 op_ty2)
                 (text "The types of" <+> pname1 <+>
                  text "are different") `andThenCheck`
           check (eqMaybeBy eqDM def_meth1 def_meth2)
                 (text "The default methods associated with" <+> pname1 <+>
                  text "are different")
         where
          name1 = idName id1
          name2 = idName id2
          pname1 = quotes (ppr name1)
          pname2 = quotes (ppr name2)
          (_, rho_ty1) = splitForAllTys (idType id1)
          op_ty1 = funResultTy rho_ty1
          (_, rho_ty2) = splitForAllTys (idType id2)
          op_ty2 = funResultTy rho_ty2

       eqAT (ATI tc1 def_ats1) (ATI tc2 def_ats2)
         = checkBootTyCon tc1 tc2 `andThenCheck`
           check (eqATDef def_ats1 def_ats2)
                 (text "The associated type defaults differ")

       eqDM (_, VanillaDM)    (_, VanillaDM)    = True
       eqDM (_, GenericDM t1) (_, GenericDM t2) = eqTypeX env t1 t2
       eqDM _ _ = False

       -- Ignore the location of the defaults
       eqATDef Nothing             Nothing             = True
       eqATDef (Just (ty1, _loc1)) (Just (ty2, _loc2)) = eqTypeX env ty1 ty2
       eqATDef _ _ = False

       eqFD (as1,bs1) (as2,bs2) =
         eqListBy (eqTypeX env) (mkTyVarTys as1) (mkTyVarTys as2) &&
         eqListBy (eqTypeX env) (mkTyVarTys bs1) (mkTyVarTys bs2)
    in
    check (roles1 == roles2) roles_msg `andThenCheck`
          -- Checks kind of class
    check (eqListBy eqFD clas_fds1 clas_fds2)
          (text "The functional dependencies do not match") `andThenCheck`
    checkUnless (null sc_theta1 && null op_stuff1 && null ats1) $
                     -- Above tests for an "abstract" class
    check (eqListBy (eqTypeX env) sc_theta1 sc_theta2)
          (text "The class constraints do not match") `andThenCheck`
    checkListBy eqSig op_stuff1 op_stuff2 (text "methods") `andThenCheck`
    checkListBy eqAT ats1 ats2 (text "associated types")

  | Just syn_rhs1 <- synTyConRhs_maybe tc1
  , Just syn_rhs2 <- synTyConRhs_maybe tc2
  , Just env <- eqVarBndrs emptyRnEnv2 (tyConTyVars tc1) (tyConTyVars tc2)
  = ASSERT(tc1 == tc2)
    check (roles1 == roles2) roles_msg `andThenCheck`
    check (eqTypeX env syn_rhs1 syn_rhs2) empty   -- nothing interesting to say

  | Just fam_flav1 <- famTyConFlav_maybe tc1
  , Just fam_flav2 <- famTyConFlav_maybe tc2
  = ASSERT(tc1 == tc2)
    let eqFamFlav OpenSynFamilyTyCon   OpenSynFamilyTyCon = True
        eqFamFlav (DataFamilyTyCon {}) (DataFamilyTyCon {}) = True
        eqFamFlav AbstractClosedSynFamilyTyCon (ClosedSynFamilyTyCon {}) = True
        eqFamFlav (ClosedSynFamilyTyCon {}) AbstractClosedSynFamilyTyCon = True
        eqFamFlav (ClosedSynFamilyTyCon ax1) (ClosedSynFamilyTyCon ax2)
            = eqClosedFamilyAx ax1 ax2
        eqFamFlav (BuiltInSynFamTyCon {}) (BuiltInSynFamTyCon {}) = tc1 == tc2
        eqFamFlav _ _ = False
        injInfo1 = familyTyConInjectivityInfo tc1
        injInfo2 = familyTyConInjectivityInfo tc2
    in
    -- check equality of roles, family flavours and injectivity annotations
    check (roles1 == roles2) roles_msg `andThenCheck`
    check (eqFamFlav fam_flav1 fam_flav2) empty `andThenCheck`
    check (injInfo1 == injInfo2) empty

  | isAlgTyCon tc1 && isAlgTyCon tc2
  , Just env <- eqVarBndrs emptyRnEnv2 (tyConTyVars tc1) (tyConTyVars tc2)
  = ASSERT(tc1 == tc2)
    check (roles1 == roles2) roles_msg `andThenCheck`
    check (eqListBy (eqTypeX env)
                     (tyConStupidTheta tc1) (tyConStupidTheta tc2))
          (text "The datatype contexts do not match") `andThenCheck`
    eqAlgRhs tc1 (algTyConRhs tc1) (algTyConRhs tc2)

  | otherwise = Just empty   -- two very different types -- should be obvious
  where
    roles1 = tyConRoles tc1
    roles2 = tyConRoles tc2
    roles_msg = text "The roles do not match." $$
                (text "Roles on abstract types default to" <+>
                 quotes (text "representational") <+> text "in boot files.")

    eqAlgRhs tc (AbstractTyCon dis1) rhs2
      | dis1      = check (isGenInjAlgRhs rhs2)   --Check compatibility
                          (text "The natures of the declarations for" <+>
                           quotes (ppr tc) <+> text "are different")
      | otherwise = checkSuccess
    eqAlgRhs _  tc1@DataTyCon{} tc2@DataTyCon{} =
        checkListBy eqCon (data_cons tc1) (data_cons tc2) (text "constructors")
    eqAlgRhs _  tc1@NewTyCon{} tc2@NewTyCon{} =
        eqCon (data_con tc1) (data_con tc2)
    eqAlgRhs _ _ _ = Just (text "Cannot match a" <+> quotes (text "data") <+>
                           text "definition with a" <+> quotes (text "newtype") <+>
                           text "definition")

    eqCon c1 c2
      =  check (name1 == name2)
               (text "The names" <+> pname1 <+> text "and" <+> pname2 <+>
                text "differ") `andThenCheck`
         check (dataConIsInfix c1 == dataConIsInfix c2)
               (text "The fixities of" <+> pname1 <+>
                text "differ") `andThenCheck`
         check (eqListBy eqHsBang (dataConImplBangs c1) (dataConImplBangs c2))
               (text "The strictness annotations for" <+> pname1 <+>
                text "differ") `andThenCheck`
         check (map flSelector (dataConFieldLabels c1) == map flSelector (dataConFieldLabels c2))
               (text "The record label lists for" <+> pname1 <+>
                text "differ") `andThenCheck`
         check (eqType (dataConUserType c1) (dataConUserType c2))
               (text "The types for" <+> pname1 <+> text "differ")
      where
        name1 = dataConName c1
        name2 = dataConName c2
        pname1 = quotes (ppr name1)
        pname2 = quotes (ppr name2)

    eqClosedFamilyAx Nothing Nothing  = True
    eqClosedFamilyAx Nothing (Just _) = False
    eqClosedFamilyAx (Just _) Nothing = False
    eqClosedFamilyAx (Just (CoAxiom { co_ax_branches = branches1 }))
                     (Just (CoAxiom { co_ax_branches = branches2 }))
      =  numBranches branches1 == numBranches branches2
      && (and $ zipWith eqClosedFamilyBranch branch_list1 branch_list2)
      where
        branch_list1 = fromBranches branches1
        branch_list2 = fromBranches branches2

    eqClosedFamilyBranch (CoAxBranch { cab_tvs = tvs1, cab_cvs = cvs1
                                     , cab_lhs = lhs1, cab_rhs = rhs1 })
                         (CoAxBranch { cab_tvs = tvs2, cab_cvs = cvs2
                                     , cab_lhs = lhs2, cab_rhs = rhs2 })
      | Just env1 <- eqVarBndrs emptyRnEnv2 tvs1 tvs2
      , Just env  <- eqVarBndrs env1        cvs1 cvs2
      = eqListBy (eqTypeX env) lhs1 lhs2 &&
        eqTypeX env rhs1 rhs2

      | otherwise = False

emptyRnEnv2 :: RnEnv2
emptyRnEnv2 = mkRnEnv2 emptyInScopeSet

----------------
missingBootThing :: Bool -> Name -> String -> SDoc
missingBootThing is_boot name what
  = quotes (ppr name) <+> text "is exported by the"
    <+> (if is_boot then text "hs-boot" else text "hsig")
    <+> text "file, but not"
    <+> text what <+> text "the module"

bootMisMatch :: Bool -> SDoc -> TyThing -> TyThing -> SDoc
bootMisMatch is_boot extra_info real_thing boot_thing
  = vcat [ppr real_thing <+>
          text "has conflicting definitions in the module",
          text "and its" <+>
            (if is_boot then text "hs-boot file"
                       else text "hsig file"),
          text "Main module:" <+> PprTyThing.pprTyThing real_thing,
          (if is_boot
            then text "Boot file:  "
            else text "Hsig file: ")
            <+> PprTyThing.pprTyThing boot_thing,
          extra_info]

instMisMatch :: Bool -> ClsInst -> SDoc
instMisMatch is_boot inst
  = hang (ppr inst)
       2 (text "is defined in the" <+>
        (if is_boot then text "hs-boot" else text "hsig")
       <+> text "file, but not in the module itself")

{-
************************************************************************
*                                                                      *
        Type-checking the top level of a module (continued)
*                                                                      *
************************************************************************
-}

rnTopSrcDecls :: HsGroup RdrName -> TcM (TcGblEnv, HsGroup Name)
-- Fails if there are any errors
rnTopSrcDecls group
 = do { -- Rename the source decls
        traceRn (text "rn12") ;
        (tcg_env, rn_decls) <- checkNoErrs $ rnSrcDecls group ;
        traceRn (text "rn13") ;

        -- save the renamed syntax, if we want it
        let { tcg_env'
                | Just grp <- tcg_rn_decls tcg_env
                  = tcg_env{ tcg_rn_decls = Just (appendGroups grp rn_decls) }
                | otherwise
                   = tcg_env };

                -- Dump trace of renaming part
        rnDump (ppr rn_decls) ;
        return (tcg_env', rn_decls)
   }

tcTopSrcDecls :: HsGroup Name -> TcM (TcGblEnv, TcLclEnv)
tcTopSrcDecls (HsGroup { hs_tyclds = tycl_decls,
                         hs_instds = inst_decls,
                         hs_derivds = deriv_decls,
                         hs_fords  = foreign_decls,
                         hs_defds  = default_decls,
                         hs_annds  = annotation_decls,
                         hs_ruleds = rule_decls,
                         hs_vects  = vect_decls,
                         hs_valds  = hs_val_binds@(ValBindsOut val_binds val_sigs) })
 = do {         -- Type-check the type and class decls, and all imported decls
                -- The latter come in via tycl_decls
        traceTc "Tc2 (src)" empty ;

                -- Source-language instances, including derivings,
                -- and import the supporting declarations
        traceTc "Tc3" empty ;
        (tcg_env, inst_infos, ValBindsOut deriv_binds deriv_sigs)
            <- tcTyClsInstDecls tycl_decls inst_decls deriv_decls val_binds ;
        setGblEnv tcg_env       $ do {

                -- Generate Applicative/Monad proposal (AMP) warnings
        traceTc "Tc3b" empty ;

                -- Generate Semigroup/Monoid warnings
        traceTc "Tc3c" empty ;
        tcSemigroupWarnings ;

                -- Foreign import declarations next.
        traceTc "Tc4" empty ;
        (fi_ids, fi_decls, fi_gres) <- tcForeignImports foreign_decls ;
        tcExtendGlobalValEnv fi_ids     $ do {

                -- Default declarations
        traceTc "Tc4a" empty ;
        default_tys <- tcDefaults default_decls ;
        updGblEnv (\gbl -> gbl { tcg_default = default_tys }) $ do {

                -- Now GHC-generated derived bindings, generics, and selectors
                -- Do not generate warnings from compiler-generated code;
                -- hence the use of discardWarnings
        tc_envs <- discardWarnings (tcTopBinds deriv_binds deriv_sigs) ;
        setEnvs tc_envs $ do {

                -- Value declarations next
        traceTc "Tc5" empty ;
        tc_envs@(tcg_env, tcl_env) <- tcTopBinds val_binds val_sigs;
        setEnvs tc_envs $ do {  -- Environment doesn't change now

                -- Second pass over class and instance declarations,
                -- now using the kind-checked decls
        traceTc "Tc6" empty ;
        inst_binds <- tcInstDecls2 (tyClGroupConcat tycl_decls) inst_infos ;

                -- Foreign exports
        traceTc "Tc7" empty ;
        (foe_binds, foe_decls, foe_gres) <- tcForeignExports foreign_decls ;

                -- Annotations
        annotations <- tcAnnotations annotation_decls ;

                -- Rules
        rules <- tcRules rule_decls ;

                -- Vectorisation declarations
        vects <- tcVectDecls vect_decls ;

                -- Wrap up
        traceTc "Tc7a" empty ;
        let { all_binds = inst_binds     `unionBags`
                          foe_binds

            ; fo_gres = fi_gres `unionBags` foe_gres
            ; fo_fvs = foldrBag (\gre fvs -> fvs `addOneFV` gre_name gre)
                                emptyFVs fo_gres

            ; sig_names = mkNameSet (collectHsValBinders hs_val_binds)
                          `minusNameSet` getTypeSigNames val_sigs

                -- Extend the GblEnv with the (as yet un-zonked)
                -- bindings, rules, foreign decls
            ; tcg_env' = tcg_env { tcg_binds   = tcg_binds tcg_env `unionBags` all_binds
                                 , tcg_sigs    = tcg_sigs tcg_env `unionNameSet` sig_names
                                 , tcg_rules   = tcg_rules tcg_env
                                                      ++ flattenRuleDecls rules
                                 , tcg_vects   = tcg_vects tcg_env ++ vects
                                 , tcg_anns    = tcg_anns tcg_env ++ annotations
                                 , tcg_ann_env = extendAnnEnvList (tcg_ann_env tcg_env) annotations
                                 , tcg_fords   = tcg_fords tcg_env ++ foe_decls ++ fi_decls
                                 , tcg_dus     = tcg_dus tcg_env `plusDU` usesOnly fo_fvs } } ;
                                 -- tcg_dus: see Note [Newtype constructor usage in foreign declarations]

        -- See Note [Newtype constructor usage in foreign declarations]
        addUsedGREs (bagToList fo_gres) ;

        return (tcg_env', tcl_env)
    }}}}}}

tcTopSrcDecls _ = panic "tcTopSrcDecls: ValBindsIn"


tcSemigroupWarnings :: TcM ()
tcSemigroupWarnings = do
    traceTc "tcSemigroupWarnings" empty
    let warnFlag = Opt_WarnSemigroup
    tcPreludeClashWarn warnFlag sappendName
    tcMissingParentClassWarn warnFlag monoidClassName semigroupClassName


-- | Warn on local definitions of names that would clash with future Prelude
-- elements.
--
--   A name clashes if the following criteria are met:
--       1. It would is imported (unqualified) from Prelude
--       2. It is locally defined in the current module
--       3. It has the same literal name as the reference function
--       4. It is not identical to the reference function
tcPreludeClashWarn :: WarningFlag
                   -> Name
                   -> TcM ()
tcPreludeClashWarn warnFlag name = do
    { warn <- woptM warnFlag
    ; when warn $ do
    { traceTc "tcPreludeClashWarn/wouldBeImported" empty
    -- Is the name imported (unqualified) from Prelude? (Point 4 above)
    ; rnImports <- fmap (map unLoc . tcg_rn_imports) getGblEnv
    -- (Note that this automatically handles -XNoImplicitPrelude, as Prelude
    -- will not appear in rnImports automatically if it is set.)

    -- Continue only the name is imported from Prelude
    ; when (importedViaPrelude name rnImports) $ do
      -- Handle 2.-4.
    { rdrElts <- fmap (concat . occEnvElts . tcg_rdr_env) getGblEnv

    ; let clashes :: GlobalRdrElt -> Bool
          clashes x = isLocalDef && nameClashes && isNotInProperModule
            where
              isLocalDef = gre_lcl x == True
              -- Names are identical ...
              nameClashes = nameOccName (gre_name x) == nameOccName name
              -- ... but not the actual definitions, because we don't want to
              -- warn about a bad definition of e.g. <> in Data.Semigroup, which
              -- is the (only) proper place where this should be defined
              isNotInProperModule = gre_name x /= name

          -- List of all offending definitions
          clashingElts :: [GlobalRdrElt]
          clashingElts = filter clashes rdrElts

    ; traceTc "tcPreludeClashWarn/prelude_functions"
                (hang (ppr name) 4 (sep [ppr clashingElts]))

    ; let warn_msg x = addWarnAt (Reason warnFlag) (nameSrcSpan (gre_name x)) (hsep
              [ text "Local definition of"
              , (quotes . ppr . nameOccName . gre_name) x
              , text "clashes with a future Prelude name." ]
              $$
              text "This will become an error in a future release." )
    ; mapM_ warn_msg clashingElts
    }}}

  where

    -- Is the given name imported via Prelude?
    --
    -- Possible scenarios:
    --   a) Prelude is imported implicitly, issue warnings.
    --   b) Prelude is imported explicitly, but without mentioning the name in
    --      question. Issue no warnings.
    --   c) Prelude is imported hiding the name in question. Issue no warnings.
    --   d) Qualified import of Prelude, no warnings.
    importedViaPrelude :: Name
                       -> [ImportDecl Name]
                       -> Bool
    importedViaPrelude name = any importViaPrelude
      where
        isPrelude :: ImportDecl Name -> Bool
        isPrelude imp = unLoc (ideclName imp) == pRELUDE_NAME

        -- Implicit (Prelude) import?
        isImplicit :: ImportDecl Name -> Bool
        isImplicit = ideclImplicit

        -- Unqualified import?
        isUnqualified :: ImportDecl Name -> Bool
        isUnqualified = not . ideclQualified

        -- List of explicitly imported (or hidden) Names from a single import.
        --   Nothing -> No explicit imports
        --   Just (False, <names>) -> Explicit import list of <names>
        --   Just (True , <names>) -> Explicit hiding of <names>
        importListOf :: ImportDecl Name -> Maybe (Bool, [Name])
        importListOf = fmap toImportList . ideclHiding
          where
            toImportList (h, loc) = (h, map (ieName . unLoc) (unLoc loc))

        isExplicit :: ImportDecl Name -> Bool
        isExplicit x = case importListOf x of
            Nothing -> False
            Just (False, explicit)
                -> nameOccName name `elem`    map nameOccName explicit
            Just (True, hidden)
                -> nameOccName name `notElem` map nameOccName hidden

        -- Check whether the given name would be imported (unqualified) from
        -- an import declaration.
        importViaPrelude :: ImportDecl Name -> Bool
        importViaPrelude x = isPrelude x
                          && isUnqualified x
                          && (isImplicit x || isExplicit x)


-- Notation: is* is for classes the type is an instance of, should* for those
--           that it should also be an instance of based on the corresponding
--           is*.
tcMissingParentClassWarn :: WarningFlag
                         -> Name -- ^ Instances of this ...
                         -> Name -- ^ should also be instances of this
                         -> TcM ()
tcMissingParentClassWarn warnFlag isName shouldName
  = do { warn <- woptM warnFlag
       ; when warn $ do
       { traceTc "tcMissingParentClassWarn" empty
       ; isClass'     <- tcLookupClass_maybe isName
       ; shouldClass' <- tcLookupClass_maybe shouldName
       ; case (isClass', shouldClass') of
              (Just isClass, Just shouldClass) -> do
                  { localInstances <- tcGetInsts
                  ; let isInstance m = is_cls m == isClass
                        isInsts = filter isInstance localInstances
                  ; traceTc "tcMissingParentClassWarn/isInsts" (ppr isInsts)
                  ; forM_ isInsts (checkShouldInst isClass shouldClass)
                  }
              (is',should') ->
                  traceTc "tcMissingParentClassWarn/notIsShould"
                          (hang (ppr isName <> text "/" <> ppr shouldName) 2 (
                            (hsep [ quotes (text "Is"), text "lookup for"
                                  , ppr isName
                                  , text "resulted in", ppr is' ])
                            $$
                            (hsep [ quotes (text "Should"), text "lookup for"
                                  , ppr shouldName
                                  , text "resulted in", ppr should' ])))
       }}
  where
    -- Check whether the desired superclass exists in a given environment.
    checkShouldInst :: Class   -- ^ Class of existing instance
                    -> Class   -- ^ Class there should be an instance of
                    -> ClsInst -- ^ Existing instance
                    -> TcM ()
    checkShouldInst isClass shouldClass isInst
      = do { instEnv <- tcGetInstEnvs
           ; let (instanceMatches, shouldInsts, _)
                    = lookupInstEnv False instEnv shouldClass (is_tys isInst)

           ; traceTc "tcMissingParentClassWarn/checkShouldInst"
                     (hang (ppr isInst) 4
                         (sep [ppr instanceMatches, ppr shouldInsts]))

           -- "<location>: Warning: <type> is an instance of <is> but not
           -- <should>" e.g. "Foo is an instance of Monad but not Applicative"
           ; let instLoc = srcLocSpan . nameSrcLoc $ getName isInst
                 warnMsg (Just name:_) =
                      addWarnAt (Reason warnFlag) instLoc $
                           hsep [ (quotes . ppr . nameOccName) name
                                , text "is an instance of"
                                , (ppr . nameOccName . className) isClass
                                , text "but not"
                                , (ppr . nameOccName . className) shouldClass ]
                                <> text "."
                           $$
                           hsep [ text "This will become an error in"
                                , text "a future release." ]
                 warnMsg _ = pure ()
           ; when (null shouldInsts && null instanceMatches) $
                  warnMsg (is_tcs isInst)
           }

    tcLookupClass_maybe :: Name -> TcM (Maybe Class)
    tcLookupClass_maybe name = tcLookupImported_maybe name >>= \case
        Succeeded (ATyCon tc) | cls@(Just _) <- tyConClass_maybe tc -> pure cls
        _else -> pure Nothing


---------------------------
tcTyClsInstDecls :: [TyClGroup Name]
                 -> [LInstDecl Name]
                 -> [LDerivDecl Name]
                 -> [(RecFlag, LHsBinds Name)]
                 -> TcM (TcGblEnv,            -- The full inst env
                         [InstInfo Name],     -- Source-code instance decls to process;
                                              -- contains all dfuns for this module
                          HsValBinds Name)    -- Supporting bindings for derived instances

tcTyClsInstDecls tycl_decls inst_decls deriv_decls binds
 = tcAddDataFamConPlaceholders inst_decls           $
   tcAddPatSynPlaceholders (getPatSynBinds binds) $
   do { tcg_env <- tcTyAndClassDecls tycl_decls ;
      ; setGblEnv tcg_env $
        tcInstDecls1 tycl_decls inst_decls deriv_decls }


{- *********************************************************************
*                                                                      *
        Checking for 'main'
*                                                                      *
************************************************************************
-}

checkMain :: Bool  -- False => no 'module M(..) where' header at all
          -> TcM TcGblEnv
-- If we are in module Main, check that 'main' is defined.
checkMain explicit_mod_hdr
 = do   { dflags  <- getDynFlags
        ; tcg_env <- getGblEnv
        ; check_main dflags tcg_env explicit_mod_hdr }

check_main :: DynFlags -> TcGblEnv -> Bool -> TcM TcGblEnv
check_main dflags tcg_env explicit_mod_hdr
 | mod /= main_mod
 = traceTc "checkMain not" (ppr main_mod <+> ppr mod) >>
   return tcg_env

 | otherwise
 = do   { mb_main <- lookupGlobalOccRn_maybe main_fn
                -- Check that 'main' is in scope
                -- It might be imported from another module!
        ; case mb_main of {
             Nothing -> do { traceTc "checkMain fail" (ppr main_mod <+> ppr main_fn)
                           ; complain_no_main
                           ; return tcg_env } ;
             Just main_name -> do

        { traceTc "checkMain found" (ppr main_mod <+> ppr main_fn)
        ; let loc = srcLocSpan (getSrcLoc main_name)
        ; ioTyCon <- tcLookupTyCon ioTyConName
        ; res_ty <- newFlexiTyVarTy liftedTypeKind
        ; main_expr
                <- addErrCtxt mainCtxt    $
                   tcMonoExpr (L loc (HsVar (L loc main_name)))
                                            (mkCheckExpType $
                                             mkTyConApp ioTyCon [res_ty])

                -- See Note [Root-main Id]
                -- Construct the binding
                --      :Main.main :: IO res_ty = runMainIO res_ty main
        ; run_main_id <- tcLookupId runMainIOName
        ; let { root_main_name =  mkExternalName rootMainKey rOOT_MAIN
                                   (mkVarOccFS (fsLit "main"))
                                   (getSrcSpan main_name)
              ; root_main_id = Id.mkExportedVanillaId root_main_name
                                                      (mkTyConApp ioTyCon [res_ty])
              ; co  = mkWpTyApps [res_ty]
              ; rhs = nlHsApp (mkLHsWrap co (nlHsVar run_main_id)) main_expr
              ; main_bind = mkVarBind root_main_id rhs }

        ; return (tcg_env { tcg_main  = Just main_name,
                            tcg_binds = tcg_binds tcg_env
                                        `snocBag` main_bind,
                            tcg_dus   = tcg_dus tcg_env
                                        `plusDU` usesOnly (unitFV main_name)
                        -- Record the use of 'main', so that we don't
                        -- complain about it being defined but not used
                 })
    }}}
  where
    mod         = tcg_mod tcg_env
    main_mod    = mainModIs dflags
    main_fn     = getMainFun dflags
    interactive = ghcLink dflags == LinkInMemory

    complain_no_main = checkTc (interactive && not explicit_mod_hdr) noMainMsg
        -- In interactive mode, without an explicit module header, don't
        -- worry about the absence of 'main'.
        -- In other modes, fail altogether, so that we don't go on
        -- and complain a second time when processing the export list.

    mainCtxt  = text "When checking the type of the" <+> pp_main_fn
    noMainMsg = text "The" <+> pp_main_fn
                <+> text "is not defined in module" <+> quotes (ppr main_mod)
    pp_main_fn = ppMainFn main_fn

-- | Get the unqualified name of the function to use as the \"main\" for the main module.
-- Either returns the default name or the one configured on the command line with -main-is
getMainFun :: DynFlags -> RdrName
getMainFun dflags = case mainFunIs dflags of
                      Just fn -> mkRdrUnqual (mkVarOccFS (mkFastString fn))
                      Nothing -> main_RDR_Unqual

-- If we are in module Main, check that 'main' is exported.
checkMainExported :: TcGblEnv -> TcM ()
checkMainExported tcg_env
  = case tcg_main tcg_env of
      Nothing -> return () -- not the main module
      Just main_name ->
         do { dflags <- getDynFlags
            ; let main_mod = mainModIs dflags
            ; checkTc (main_name `elem` concatMap availNames (tcg_exports tcg_env)) $
                text "The" <+> ppMainFn (nameRdrName main_name) <+>
                text "is not exported by module" <+> quotes (ppr main_mod) }

ppMainFn :: RdrName -> SDoc
ppMainFn main_fn
  | rdrNameOcc main_fn == mainOcc
  = text "IO action" <+> quotes (ppr main_fn)
  | otherwise
  = text "main IO action" <+> quotes (ppr main_fn)

mainOcc :: OccName
mainOcc = mkVarOccFS (fsLit "main")

{-
Note [Root-main Id]
~~~~~~~~~~~~~~~~~~~
The function that the RTS invokes is always :Main.main, which we call
root_main_id.  (Because GHC allows the user to have a module not
called Main as the main module, we can't rely on the main function
being called "Main.main".  That's why root_main_id has a fixed module
":Main".)

This is unusual: it's a LocalId whose Name has a Module from another
module.  Tiresomely, we must filter it out again in MkIface, les we
get two defns for 'main' in the interface file!


*********************************************************
*                                                       *
                GHCi stuff
*                                                       *
*********************************************************
-}

runTcInteractive :: HscEnv -> TcRn a -> IO (Messages, Maybe a)
-- Initialise the tcg_inst_env with instances from all home modules.
-- This mimics the more selective call to hptInstances in tcRnImports
runTcInteractive hsc_env thing_inside
  = initTcInteractive hsc_env $ withTcPlugins hsc_env $
    do { traceTc "setInteractiveContext" $
            vcat [ text "ic_tythings:" <+> vcat (map ppr (ic_tythings icxt))
                 , text "ic_insts:" <+> vcat (map (pprBndr LetBind . instanceDFunId) ic_insts)
                 , text "ic_rn_gbl_env (LocalDef)" <+>
                      vcat (map ppr [ local_gres | gres <- occEnvElts (ic_rn_gbl_env icxt)
                                                 , let local_gres = filter isLocalGRE gres
                                                 , not (null local_gres) ]) ]
       ; let getOrphans m = fmap (\iface -> mi_module iface
                                          : dep_orphs (mi_deps iface))
                                 (loadSrcInterface (text "runTcInteractive") m
                                                   False Nothing)
       ; orphs <- fmap concat . forM (ic_imports icxt) $ \i ->
            case i of
                IIModule n -> getOrphans n
                IIDecl i -> getOrphans (unLoc (ideclName i))
       ; let imports = emptyImportAvails {
                            imp_orphs = orphs
                        }
       ; (gbl_env, lcl_env) <- getEnvs
       ; let gbl_env' = gbl_env {
                           tcg_rdr_env      = ic_rn_gbl_env icxt
                         , tcg_type_env     = type_env
                         , tcg_inst_env     = extendInstEnvList
                                               (extendInstEnvList (tcg_inst_env gbl_env) ic_insts)
                                               home_insts
                         , tcg_fam_inst_env = extendFamInstEnvList
                                               (extendFamInstEnvList (tcg_fam_inst_env gbl_env)
                                                                     ic_finsts)
                                               home_fam_insts
                         , tcg_field_env    = mkNameEnv con_fields
                              -- setting tcg_field_env is necessary
                              -- to make RecordWildCards work (test: ghci049)
                         , tcg_fix_env      = ic_fix_env icxt
                         , tcg_default      = ic_default icxt
                              -- must calculate imp_orphs of the ImportAvails
                              -- so that instance visibility is done correctly
                         , tcg_imports      = imports
                         }

       ; lcl_env' <- tcExtendLocalTypeEnv lcl_env lcl_ids
       ; setEnvs (gbl_env', lcl_env') thing_inside }
  where
    (home_insts, home_fam_insts) = hptInstances hsc_env (\_ -> True)

    icxt                     = hsc_IC hsc_env
    (ic_insts, ic_finsts)    = ic_instances icxt
    (lcl_ids, top_ty_things) = partitionWith is_closed (ic_tythings icxt)

    is_closed :: TyThing -> Either (Name, TcTyThing) TyThing
    -- Put Ids with free type variables (always RuntimeUnks)
    -- in the *local* type environment
    -- See Note [Initialising the type environment for GHCi]
    is_closed thing
      | AnId id <- thing
      , NotTopLevel <- isClosedLetBndr id
      = Left (idName id, ATcId { tct_id = id, tct_closed = NotTopLevel })
      | otherwise
      = Right thing

    type_env1 = mkTypeEnvWithImplicits top_ty_things
    type_env  = extendTypeEnvWithIds type_env1 (map instanceDFunId ic_insts)
                -- Putting the dfuns in the type_env
                -- is just to keep Core Lint happy

    con_fields = [ (dataConName c, dataConFieldLabels c)
                 | ATyCon t <- top_ty_things
                 , c <- tyConDataCons t ]


{- Note [Initialising the type environment for GHCi]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Most of the the Ids in ic_things, defined by the user in 'let' stmts,
have closed types. E.g.
   ghci> let foo x y = x && not y

However the GHCi debugger creates top-level bindings for Ids whose
types have free RuntimeUnk skolem variables, standing for unknown
types.  If we don't register these free TyVars as global TyVars then
the typechecker will try to quantify over them and fall over in
zonkQuantifiedTyVar. so we must add any free TyVars to the
typechecker's global TyVar set.  That is most conveniently by using
tcExtendLocalTypeEnv, which automatically extends the global TyVar
set.

We do this by splitting out the Ids with open types, using 'is_closed'
to do the partition.  The top-level things go in the global TypeEnv;
the open, NotTopLevel, Ids, with free RuntimeUnk tyvars, go in the
local TypeEnv.

Note that we don't extend the local RdrEnv (tcl_rdr); all the in-scope
things are already in the interactive context's GlobalRdrEnv.
Extending the local RdrEnv isn't terrible, but it means there is an
entry for the same Name in both global and local RdrEnvs, and that
lead to duplicate "perhaps you meant..." suggestions (e.g. T5564).

We don't bother with the tcl_th_bndrs environment either.
-}

#ifdef GHCI
-- | The returned [Id] is the list of new Ids bound by this statement. It can
-- be used to extend the InteractiveContext via extendInteractiveContext.
--
-- The returned TypecheckedHsExpr is of type IO [ () ], a list of the bound
-- values, coerced to ().
tcRnStmt :: HscEnv -> GhciLStmt RdrName
         -> IO (Messages, Maybe ([Id], LHsExpr Id, FixityEnv))
tcRnStmt hsc_env rdr_stmt
  = runTcInteractive hsc_env $ do {

    -- The real work is done here
    ((bound_ids, tc_expr), fix_env) <- tcUserStmt rdr_stmt ;
    zonked_expr <- zonkTopLExpr tc_expr ;
    zonked_ids  <- zonkTopBndrs bound_ids ;

        -- None of the Ids should be of unboxed type, because we
        -- cast them all to HValues in the end!
    mapM_ bad_unboxed (filter (isUnliftedType . idType) zonked_ids) ;

    traceTc "tcs 1" empty ;
    this_mod <- getModule ;
    global_ids <- mapM (externaliseAndTidyId this_mod) zonked_ids ;
        -- Note [Interactively-bound Ids in GHCi] in HscTypes

{- ---------------------------------------------
   At one stage I removed any shadowed bindings from the type_env;
   they are inaccessible but might, I suppose, cause a space leak if we leave them there.
   However, with Template Haskell they aren't necessarily inaccessible.  Consider this
   GHCi session
         Prelude> let f n = n * 2 :: Int
         Prelude> fName <- runQ [| f |]
         Prelude> $(return $ AppE fName (LitE (IntegerL 7)))
         14
         Prelude> let f n = n * 3 :: Int
         Prelude> $(return $ AppE fName (LitE (IntegerL 7)))
   In the last line we use 'fName', which resolves to the *first* 'f'
   in scope. If we delete it from the type env, GHCi crashes because
   it doesn't expect that.

   Hence this code is commented out

-------------------------------------------------- -}

    traceOptTcRn Opt_D_dump_tc
        (vcat [text "Bound Ids" <+> pprWithCommas ppr global_ids,
               text "Typechecked expr" <+> ppr zonked_expr]) ;

    return (global_ids, zonked_expr, fix_env)
    }
  where
    bad_unboxed id = addErr (sep [text "GHCi can't bind a variable of unlifted type:",
                                  nest 2 (ppr id <+> dcolon <+> ppr (idType id))])

{-
--------------------------------------------------------------------------
                Typechecking Stmts in GHCi

Here is the grand plan, implemented in tcUserStmt

        What you type                   The IO [HValue] that hscStmt returns
        -------------                   ------------------------------------
        let pat = expr          ==>     let pat = expr in return [coerce HVal x, coerce HVal y, ...]
                                        bindings: [x,y,...]

        pat <- expr             ==>     expr >>= \ pat -> return [coerce HVal x, coerce HVal y, ...]
                                        bindings: [x,y,...]

        expr (of IO type)       ==>     expr >>= \ it -> return [coerce HVal it]
          [NB: result not printed]      bindings: [it]

        expr (of non-IO type,   ==>     let it = expr in print it >> return [coerce HVal it]
          result showable)              bindings: [it]

        expr (of non-IO type,
          result not showable)  ==>     error
-}

-- | A plan is an attempt to lift some code into the IO monad.
type PlanResult = ([Id], LHsExpr Id)
type Plan = TcM PlanResult

-- | Try the plans in order. If one fails (by raising an exn), try the next.
-- If one succeeds, take it.
runPlans :: [Plan] -> TcM PlanResult
runPlans []     = panic "runPlans"
runPlans [p]    = p
runPlans (p:ps) = tryTcLIE_ (runPlans ps) p

-- | Typecheck (and 'lift') a stmt entered by the user in GHCi into the
-- GHCi 'environment'.
--
-- By 'lift' and 'environment we mean that the code is changed to
-- execute properly in an IO monad. See Note [Interactively-bound Ids
-- in GHCi] in HscTypes for more details. We do this lifting by trying
-- different ways ('plans') of lifting the code into the IO monad and
-- type checking each plan until one succeeds.
tcUserStmt :: GhciLStmt RdrName -> TcM (PlanResult, FixityEnv)

-- An expression typed at the prompt is treated very specially
tcUserStmt (L loc (BodyStmt expr _ _ _))
  = do  { (rn_expr, fvs) <- checkNoErrs (rnLExpr expr)
               -- Don't try to typecheck if the renamer fails!
        ; ghciStep <- getGhciStepIO
        ; uniq <- newUnique
        ; interPrintName <- getInteractivePrintName
        ; let fresh_it  = itName uniq loc
              matches   = [mkMatch [] rn_expr (noLoc emptyLocalBinds)]
              -- [it = expr]
              the_bind  = L loc $ (mkTopFunBind FromSource (L loc fresh_it) matches) { bind_fvs = fvs }
                          -- Care here!  In GHCi the expression might have
                          -- free variables, and they in turn may have free type variables
                          -- (if we are at a breakpoint, say).  We must put those free vars

              -- [let it = expr]
              let_stmt  = L loc $ LetStmt $ noLoc $ HsValBinds $
                          ValBindsOut [(NonRecursive,unitBag the_bind)] []

              -- [it <- e]
              bind_stmt = L loc $ BindStmt (L loc (VarPat (L loc fresh_it)))
                                           (nlHsApp ghciStep rn_expr)
                                           (mkRnSyntaxExpr bindIOName)
                                           noSyntaxExpr
                                           PlaceHolder

              -- [; print it]
              print_it  = L loc $ BodyStmt (nlHsApp (nlHsVar interPrintName) (nlHsVar fresh_it))
                                           (mkRnSyntaxExpr thenIOName)
                                                  noSyntaxExpr placeHolderType

        -- The plans are:
        --   A. [it <- e; print it]     but not if it::()
        --   B. [it <- e]
        --   C. [let it = e; print it]
        --
        -- Ensure that type errors don't get deferred when type checking the
        -- naked expression. Deferring type errors here is unhelpful because the
        -- expression gets evaluated right away anyway. It also would potentially
        -- emit two redundant type-error warnings, one from each plan.
        ; plan <- unsetGOptM Opt_DeferTypeErrors $
                  unsetGOptM Opt_DeferTypedHoles $ runPlans [
                    -- Plan A
                    do { stuff@([it_id], _) <- tcGhciStmts [bind_stmt, print_it]
                       ; it_ty <- zonkTcType (idType it_id)
                       ; when (isUnitTy $ it_ty) failM
                       ; return stuff },

                        -- Plan B; a naked bind statment
                    tcGhciStmts [bind_stmt],

                        -- Plan C; check that the let-binding is typeable all by itself.
                        -- If not, fail; if so, try to print it.
                        -- The two-step process avoids getting two errors: one from
                        -- the expression itself, and one from the 'print it' part
                        -- This two-step story is very clunky, alas
                    do { _ <- checkNoErrs (tcGhciStmts [let_stmt])
                                --- checkNoErrs defeats the error recovery of let-bindings
                       ; tcGhciStmts [let_stmt, print_it] } ]

        ; fix_env <- getFixityEnv
        ; return (plan, fix_env) }

tcUserStmt rdr_stmt@(L loc _)
  = do { (([rn_stmt], fix_env), fvs) <- checkNoErrs $
           rnStmts GhciStmtCtxt rnLExpr [rdr_stmt] $ \_ -> do
             fix_env <- getFixityEnv
             return (fix_env, emptyFVs)
            -- Don't try to typecheck if the renamer fails!
       ; traceRn (text "tcRnStmt" <+> vcat [ppr rdr_stmt, ppr rn_stmt, ppr fvs])
       ; rnDump (ppr rn_stmt) ;

       ; ghciStep <- getGhciStepIO
       ; let gi_stmt
               | (L loc (BindStmt pat expr op1 op2 ty)) <- rn_stmt
                           = L loc $ BindStmt pat (nlHsApp ghciStep expr) op1 op2 ty
               | otherwise = rn_stmt

       ; opt_pr_flag <- goptM Opt_PrintBindResult
       ; let print_result_plan
               | opt_pr_flag                         -- The flag says "print result"
               , [v] <- collectLStmtBinders gi_stmt  -- One binder
                           =  [mk_print_result_plan gi_stmt v]
               | otherwise = []

        -- The plans are:
        --      [stmt; print v]         if one binder and not v::()
        --      [stmt]                  otherwise
       ; plan <- runPlans (print_result_plan ++ [tcGhciStmts [gi_stmt]])
       ; return (plan, fix_env) }
  where
    mk_print_result_plan stmt v
      = do { stuff@([v_id], _) <- tcGhciStmts [stmt, print_v]
           ; v_ty <- zonkTcType (idType v_id)
           ; when (isUnitTy v_ty || not (isTauTy v_ty)) failM
           ; return stuff }
      where
        print_v  = L loc $ BodyStmt (nlHsApp (nlHsVar printName) (nlHsVar v))
                                    (mkRnSyntaxExpr thenIOName) noSyntaxExpr
                                    placeHolderType

-- | Typecheck the statements given and then return the results of the
-- statement in the form 'IO [()]'.
tcGhciStmts :: [GhciLStmt Name] -> TcM PlanResult
tcGhciStmts stmts
 = do { ioTyCon <- tcLookupTyCon ioTyConName ;
        ret_id  <- tcLookupId returnIOName ;            -- return @ IO
        let {
            ret_ty      = mkListTy unitTy ;
            io_ret_ty   = mkTyConApp ioTyCon [ret_ty] ;
            tc_io_stmts = tcStmtsAndThen GhciStmtCtxt tcDoStmt stmts
                                         (mkCheckExpType io_ret_ty) ;
            names = collectLStmtsBinders stmts ;
         } ;

        -- OK, we're ready to typecheck the stmts
        traceTc "TcRnDriver.tcGhciStmts: tc stmts" empty ;
        ((tc_stmts, ids), lie) <- captureConstraints $
                                  tc_io_stmts $ \ _ ->
                                  mapM tcLookupId names  ;
                        -- Look up the names right in the middle,
                        -- where they will all be in scope

        -- wanted constraints from static forms
        stWC <- tcg_static_wc <$> getGblEnv >>= readTcRef ;

        -- Simplify the context
        traceTc "TcRnDriver.tcGhciStmts: simplify ctxt" empty ;
        const_binds <- checkNoErrs (simplifyInteractive (andWC stWC lie)) ;
                -- checkNoErrs ensures that the plan fails if context redn fails

        traceTc "TcRnDriver.tcGhciStmts: done" empty ;
        let {   -- mk_return builds the expression
                --      returnIO @ [()] [coerce () x, ..,  coerce () z]
                --
                -- Despite the inconvenience of building the type applications etc,
                -- this *has* to be done in type-annotated post-typecheck form
                -- because we are going to return a list of *polymorphic* values
                -- coerced to type (). If we built a *source* stmt
                --      return [coerce x, ..., coerce z]
                -- then the type checker would instantiate x..z, and we wouldn't
                -- get their *polymorphic* values.  (And we'd get ambiguity errs
                -- if they were overloaded, since they aren't applied to anything.)
            ret_expr = nlHsApp (nlHsTyApp ret_id [ret_ty])
                       (noLoc $ ExplicitList unitTy Nothing (map mk_item ids)) ;
            mk_item id = let ty_args = [idType id, unitTy] in
                         nlHsApp (nlHsTyApp unsafeCoerceId
                                   (map (getRuntimeRep "tcGhciStmts") ty_args ++ ty_args))
                                 (nlHsVar id) ;
            stmts = tc_stmts ++ [noLoc (mkLastStmt ret_expr)]
        } ;
        return (ids, mkHsDictLet (EvBinds const_binds) $
                     noLoc (HsDo GhciStmtCtxt (noLoc stmts) io_ret_ty))
    }

-- | Generate a typed ghciStepIO expression (ghciStep :: Ty a -> IO a)
getGhciStepIO :: TcM (LHsExpr Name)
getGhciStepIO = do
    ghciTy <- getGHCiMonad
    fresh_a <- newUnique
    loc     <- getSrcSpanM
    let a_tv    = mkInternalName fresh_a (mkTyVarOccFS (fsLit "a")) loc
        ghciM   = nlHsAppTy (nlHsTyVar ghciTy) (nlHsTyVar a_tv)
        ioM     = nlHsAppTy (nlHsTyVar ioTyConName) (nlHsTyVar a_tv)

        step_ty = noLoc $ HsForAllTy { hst_bndrs = [noLoc $ UserTyVar (noLoc a_tv)]
                                     , hst_body  = nlHsFunTy ghciM ioM }

        stepTy :: LHsSigWcType Name
        stepTy = mkEmptyImplicitBndrs (mkEmptyWildCardBndrs step_ty)

    return (noLoc $ ExprWithTySig (nlHsVar ghciStepIoMName) stepTy)

isGHCiMonad :: HscEnv -> String -> IO (Messages, Maybe Name)
isGHCiMonad hsc_env ty
  = runTcInteractive hsc_env $ do
        rdrEnv <- getGlobalRdrEnv
        let occIO = lookupOccEnv rdrEnv (mkOccName tcName ty)
        case occIO of
            Just [n] -> do
                let name = gre_name n
                ghciClass <- tcLookupClass ghciIoClassName
                userTyCon <- tcLookupTyCon name
                let userTy = mkTyConApp userTyCon []
                _ <- tcLookupInstance ghciClass [userTy]
                return name

            Just _  -> failWithTc $ text "Ambiguous type!"
            Nothing -> failWithTc $ text ("Can't find type:" ++ ty)

-- tcRnExpr just finds the type of an expression

tcRnExpr :: HscEnv
         -> LHsExpr RdrName
         -> IO (Messages, Maybe Type)
-- Type checks the expression and returns its most general type
tcRnExpr hsc_env rdr_expr
  = runTcInteractive hsc_env $
    do {

    (rn_expr, _fvs) <- rnLExpr rdr_expr ;
    failIfErrsM ;

        -- Now typecheck the expression, and generalise its type
        -- it might have a rank-2 type (e.g. :t runST)
    uniq <- newUnique ;
    let { fresh_it  = itName uniq (getLoc rdr_expr)
        ; orig = OccurrenceOf fresh_it } ;  -- Not a very satisfactory origin
    (tclvl, lie, res_ty)
          <- pushLevelAndCaptureConstraints $
             do { (_tc_expr, expr_ty) <- tcInferSigma rn_expr
                ; (_wrap, res_ty)   <- deeplyInstantiate orig expr_ty
                     -- See [Note Deeply instantiate in :type]
                ; return res_ty } ;

    -- Generalise
    ((qtvs, dicts, _), lie_top) <- captureConstraints $
                                   {-# SCC "simplifyInfer" #-}
                                   simplifyInfer tclvl
                                                 False {- No MR for now -}
                                                 []    {- No sig vars -}
                                                 [(fresh_it, res_ty)]
                                                 lie ;
    -- Wanted constraints from static forms
    stWC <- tcg_static_wc <$> getGblEnv >>= readTcRef ;

    -- Ignore the dictionary bindings
    _ <- simplifyInteractive (andWC stWC lie_top) ;

    let { all_expr_ty = mkInvForAllTys qtvs (mkPiTypes dicts res_ty) } ;
    ty <- zonkTcType all_expr_ty ;

    -- We normalise type families, so that the type of an expression is the
    -- same as of a bound expression (TcBinds.mkInferredPolyId). See Trac
    -- #10321 for further discussion.
    fam_envs <- tcGetFamInstEnvs ;
    -- normaliseType returns a coercion which we discard, so the Role is
    -- irrelevant
    return (snd (normaliseType fam_envs Nominal ty))
    }

--------------------------
tcRnImportDecls :: HscEnv
                -> [LImportDecl RdrName]
                -> IO (Messages, Maybe GlobalRdrEnv)
-- Find the new chunk of GlobalRdrEnv created by this list of import
-- decls.  In contract tcRnImports *extends* the TcGblEnv.
tcRnImportDecls hsc_env import_decls
 =  runTcInteractive hsc_env $
    do { gbl_env <- updGblEnv zap_rdr_env $
                    tcRnImports hsc_env import_decls
       ; return (tcg_rdr_env gbl_env) }
  where
    zap_rdr_env gbl_env = gbl_env { tcg_rdr_env = emptyGlobalRdrEnv }

-- tcRnType just finds the kind of a type

tcRnType :: HscEnv
         -> Bool        -- Normalise the returned type
         -> LHsType RdrName
         -> IO (Messages, Maybe (Type, Kind))
tcRnType hsc_env normalise rdr_type
  = runTcInteractive hsc_env $
    setXOptM LangExt.PolyKinds $   -- See Note [Kind-generalise in tcRnType]
    do { (HsWC { hswc_wcs = wcs, hswc_body = rn_type }, _fvs)
               <- rnHsWcType GHCiCtx (mkHsWildCardBndrs rdr_type)
                  -- The type can have wild cards, but no implicit
                  -- generalisation; e.g.   :kind (T _)
       ; failIfErrsM

        -- Now kind-check the type
        -- It can have any rank or kind
        -- First bring into scope any wildcards
       ; traceTc "tcRnType" (vcat [ppr wcs, ppr rn_type])
       ; (ty, kind) <- solveEqualities $
                       tcWildCardBinders wcs  $ \ _ ->
                       tcLHsType rn_type

       -- Do kind generalisation; see Note [Kind-generalise in tcRnType]
       ; kvs <- kindGeneralize kind
       ; ty  <- zonkTcTypeToType emptyZonkEnv ty

       ; ty' <- if normalise
                then do { fam_envs <- tcGetFamInstEnvs
                        ; let (_, ty')
                                = normaliseType fam_envs Nominal ty
                        ; return ty' }
                else return ty ;

       ; return (ty', mkInvForAllTys kvs (typeKind ty')) }

{- Note [Deeply instantiate in :type]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose (Trac #11376)
  bar :: forall a b. Show a => a -> b -> a
What should `:t bar @Int` show?

 1. forall b. Show Int => Int -> b -> Int
 2. forall b. Int -> b -> Int
 3. forall {b}. Int -> b -> Int
 4. Int -> b -> Int

We choose (3), which is the effect of deeply instantiating and
re-generalising.  All the others seem deeply confusing.  That is
why we deeply instantiate here.

Note [Kind-generalise in tcRnType]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We switch on PolyKinds when kind-checking a user type, so that we will
kind-generalise the type, even when PolyKinds is not otherwise on.
This gives the right default behaviour at the GHCi prompt, where if
you say ":k T", and T has a polymorphic kind, you'd like to see that
polymorphism. Of course.  If T isn't kind-polymorphic you won't get
anything unexpected, but the apparent *loss* of polymorphism, for
types that you know are polymorphic, is quite surprising.  See Trac
#7688 for a discussion.

Note that the goal is to generalise the *kind of the type*, not
the type itself! Example:
  ghci> data T m a = MkT (m a)  -- T :: forall . (k -> *) -> k -> *
  ghci> :k T
We instantiate T to get (T kappa).  We do not want to kind-generalise
that to forall k. T k!  Rather we want to take its kind
   T kappa :: (kappa -> *) -> kappa -> *
and now kind-generalise that kind, to forall k. (k->*) -> k -> *
(It was Trac #10122 that made me realise how wrong the previous
approach was.) -}


{-
************************************************************************
*                                                                      *
                 tcRnDeclsi
*                                                                      *
************************************************************************

tcRnDeclsi exists to allow class, data, and other declarations in GHCi.
-}

tcRnDeclsi :: HscEnv
           -> [LHsDecl RdrName]
           -> IO (Messages, Maybe TcGblEnv)
tcRnDeclsi hsc_env local_decls
  = runTcInteractive hsc_env $
    tcRnSrcDecls False local_decls

externaliseAndTidyId :: Module -> Id -> TcM Id
externaliseAndTidyId this_mod id
  = do { name' <- externaliseName this_mod (idName id)
       ; return (globaliseAndTidyId (setIdName id name')) }

#endif /* GHCi */

{-
************************************************************************
*                                                                      *
        More GHCi stuff, to do with browsing and getting info
*                                                                      *
************************************************************************
-}

#ifdef GHCI
-- | ASSUMES that the module is either in the 'HomePackageTable' or is
-- a package module with an interface on disk.  If neither of these is
-- true, then the result will be an error indicating the interface
-- could not be found.
getModuleInterface :: HscEnv -> Module -> IO (Messages, Maybe ModIface)
getModuleInterface hsc_env mod
  = runTcInteractive hsc_env $
    loadModuleInterface (text "getModuleInterface") mod

tcRnLookupRdrName :: HscEnv -> Located RdrName
                  -> IO (Messages, Maybe [Name])
-- ^ Find all the Names that this RdrName could mean, in GHCi
tcRnLookupRdrName hsc_env (L loc rdr_name)
  = runTcInteractive hsc_env $
    setSrcSpan loc           $
    do {   -- If the identifier is a constructor (begins with an
           -- upper-case letter), then we need to consider both
           -- constructor and type class identifiers.
         let rdr_names = dataTcOccs rdr_name
       ; names_s <- mapM lookupInfoOccRn rdr_names
       ; let names = concat names_s
       ; when (null names) (addErrTc (text "Not in scope:" <+> quotes (ppr rdr_name)))
       ; return names }
#endif

tcRnLookupName :: HscEnv -> Name -> IO (Messages, Maybe TyThing)
tcRnLookupName hsc_env name
  = runTcInteractive hsc_env $
    tcRnLookupName' name

-- To look up a name we have to look in the local environment (tcl_lcl)
-- as well as the global environment, which is what tcLookup does.
-- But we also want a TyThing, so we have to convert:

tcRnLookupName' :: Name -> TcRn TyThing
tcRnLookupName' name = do
   tcthing <- tcLookup name
   case tcthing of
     AGlobal thing    -> return thing
     ATcId{tct_id=id} -> return (AnId id)
     _ -> panic "tcRnLookupName'"

tcRnGetInfo :: HscEnv
            -> Name
            -> IO (Messages, Maybe (TyThing, Fixity, [ClsInst], [FamInst]))

-- Used to implement :info in GHCi
--
-- Look up a RdrName and return all the TyThings it might be
-- A capitalised RdrName is given to us in the DataName namespace,
-- but we want to treat it as *both* a data constructor
--  *and* as a type or class constructor;
-- hence the call to dataTcOccs, and we return up to two results
tcRnGetInfo hsc_env name
  = runTcInteractive hsc_env $
    do { loadUnqualIfaces hsc_env (hsc_IC hsc_env)
           -- Load the interface for all unqualified types and classes
           -- That way we will find all the instance declarations
           -- (Packages have not orphan modules, and we assume that
           --  in the home package all relevant modules are loaded.)

       ; thing  <- tcRnLookupName' name
       ; fixity <- lookupFixityRn name
       ; (cls_insts, fam_insts) <- lookupInsts thing
       ; return (thing, fixity, cls_insts, fam_insts) }

lookupInsts :: TyThing -> TcM ([ClsInst],[FamInst])
lookupInsts (ATyCon tc)
  = do  { InstEnvs { ie_global = pkg_ie, ie_local = home_ie, ie_visible = vis_mods } <- tcGetInstEnvs
        ; (pkg_fie, home_fie) <- tcGetFamInstEnvs
                -- Load all instances for all classes that are
                -- in the type environment (which are all the ones
                -- we've seen in any interface file so far)

          -- Return only the instances relevant to the given thing, i.e.
          -- the instances whose head contains the thing's name.
        ; let cls_insts =
                 [ ispec        -- Search all
                 | ispec <- instEnvElts home_ie ++ instEnvElts pkg_ie
                 , instIsVisible vis_mods ispec
                 , tc_name `elemNameSet` orphNamesOfClsInst ispec ]
        ; let fam_insts =
                 [ fispec
                 | fispec <- famInstEnvElts home_fie ++ famInstEnvElts pkg_fie
                 , tc_name `elemNameSet` orphNamesOfFamInst fispec ]
        ; return (cls_insts, fam_insts) }
  where
    tc_name     = tyConName tc

lookupInsts _ = return ([],[])

loadUnqualIfaces :: HscEnv -> InteractiveContext -> TcM ()
-- Load the interface for everything that is in scope unqualified
-- This is so that we can accurately report the instances for
-- something
loadUnqualIfaces hsc_env ictxt
  = initIfaceTcRn $ do
    mapM_ (loadSysInterface doc) (moduleSetElts (mkModuleSet unqual_mods))
  where
    this_pkg = thisPackage (hsc_dflags hsc_env)

    unqual_mods = [ nameModule name
                  | gre <- globalRdrEnvElts (ic_rn_gbl_env ictxt)
                  , let name = gre_name gre
                  , nameIsFromExternalPackage this_pkg name
                  , isTcOcc (nameOccName name)   -- Types and classes only
                  , unQualOK gre ]               -- In scope unqualified
    doc = text "Need interface for module whose export(s) are in scope unqualified"

{-
******************************************************************************
** Typechecking module exports
The renamer makes sure that only the correct pieces of a type or class can be
bundled with the type or class in the export list.

When it comes to pattern synonyms, in the renamer we have no way to check that
whether a pattern synonym should be allowed to be bundled or not so we allow
them to be bundled with any type or class. Here we then check that

1) Pattern synonyms are only bundled with types which are able to
   have data constructors. Datatypes, newtypes and data families.
2) Are the correct type, for example if P is a synonym
   then if we export Foo(P) then P should be an instance of Foo.

******************************************************************************
-}

tcExports :: Maybe [LIE Name]
          -> TcM ()
tcExports Nothing = return ()
tcExports (Just ies) = checkNoErrs $ mapM_ tc_export ies

tc_export :: LIE Name -> TcM ()
tc_export ie@(L _ (IEThingWith name _ names sels)) =
  addExportErrCtxt ie
    $ tc_export_with (unLoc name) (map unLoc names
                                    ++ map (flSelector . unLoc) sels)
tc_export _ = return ()

addExportErrCtxt :: LIE Name -> TcM a -> TcM a
addExportErrCtxt (L l ie) = setSrcSpan l . addErrCtxt exportCtxt
  where
    exportCtxt = text "In the export:" <+> ppr ie


-- Note: [Types of TyCon]
--
-- This check appears to be overlly complicated, Richard asked why it
-- is not simply just `isAlgTyCon`. The answer for this is that
-- a classTyCon is also an `AlgTyCon` which we explicitly want to disallow.
-- (It is either a newtype or data depending on the number of methods)
--
--
-- Note: [Typing Pattern Synonym Exports]
-- It proved quite a challenge to precisely specify which pattern synonyms
-- should be allowed to be bundled with which type constructors.
-- In the end it was decided to be quite liberal in what we allow. Below is
-- how Simon described the implementation.
--
-- "Personally I think we should Keep It Simple.  All this talk of
--  satisfiability makes me shiver.  I suggest this: allow T( P ) in all
--   situations except where `P`'s type is ''visibly incompatible'' with
--   `T`.
--
--    What does "visibly incompatible" mean?  `P` is visibly incompatible
--    with
--     `T` if
--       * `P`'s type is of form `... -> S t1 t2`
--       * `S` is a data/newtype constructor distinct from `T`
--
--  Nothing harmful happens if we allow `P` to be exported with
--  a type it can't possibly be useful for, but specifying a tighter
--  relationship is very awkward as you have discovered."
--
-- Note that this allows *any* pattern synonym to be bundled with any
-- datatype type constructor. For example, the following pattern `P` can be
-- bundled with any type.
--
-- ```
-- pattern P :: (A ~ f) => f
-- ```
--
-- So we provide basic type checking in order to help the user out, most
-- pattern synonyms are defined with definite type constructors, but don't
-- actually prevent a library author completely confusing their users if
-- they want to.

exportErrCtxt :: Outputable o => String -> o -> SDoc
exportErrCtxt herald exp =
  text "In the" <+> text (herald ++ ":") <+> ppr exp

tc_export_with :: Name  -- ^ Type constructor
               -> [Name] -- ^ A mixture of data constructors, pattern syonyms
                         -- , class methods and record selectors.
               -> TcM ()
tc_export_with n ns = do
  ty_con <- tcLookupTyCon n
  things <- mapM tcLookupGlobal ns
  let psErr = exportErrCtxt "pattern synonym"
      selErr = exportErrCtxt "pattern synonym record selector"
      ps       = [(psErr p,p) | AConLike (PatSynCon p) <- things]
      sels     = [(selErr i,p) | AnId i <- things
                        , isId i
                        , RecSelId {sel_tycon = RecSelPatSyn p} <- [idDetails i]]
      pat_syns = ps ++ sels


  -- See note [Types of TyCon]
  checkTc ( null pat_syns || isTyConWithSrcDataCons ty_con) assocClassErr

  let actual_res_ty =
          mkTyConApp ty_con (mkTyVarTys (tyConTyVars ty_con))
  mapM_ (tc_one_export_with actual_res_ty ty_con ) pat_syns

  where
    assocClassErr :: SDoc
    assocClassErr =
      text "Pattern synonyms can be bundled only with datatypes."


    tc_one_export_with :: TcTauType -- ^ TyCon type
                       -> TyCon       -- ^ Parent TyCon
                       -> (SDoc, PatSyn)   -- ^ Corresponding bundled PatSyn
                                           -- and pretty printed origin
                       -> TcM ()
    tc_one_export_with actual_res_ty ty_con (errCtxt, pat_syn)
      = addErrCtxt errCtxt $
      let (_, _, _, _, _, res_ty) = patSynSig pat_syn
          mtycon = tcSplitTyConApp_maybe res_ty
          typeMismatchError :: SDoc
          typeMismatchError =
            text "Pattern synonyms can only be bundled with matching type constructors"
                $$ text "Couldn't match expected type of"
                <+> quotes (ppr actual_res_ty)
                <+> text "with actual type of"
                <+> quotes (ppr res_ty)
      in case mtycon of
            Nothing -> return ()
            Just (p_ty_con, _) ->
              -- See note [Typing Pattern Synonym Exports]
              unless (p_ty_con == ty_con)
                (addErrTc typeMismatchError)



{-
************************************************************************
*                                                                      *
                Degugging output
*                                                                      *
************************************************************************
-}

rnDump :: SDoc -> TcRn ()
-- Dump, with a banner, if -ddump-rn
rnDump doc = do { traceOptTcRn Opt_D_dump_rn (mkDumpDoc "Renamer" doc) }

tcDump :: TcGblEnv -> TcRn ()
tcDump env
 = do { dflags <- getDynFlags ;

        -- Dump short output if -ddump-types or -ddump-tc
        when (dopt Opt_D_dump_types dflags || dopt Opt_D_dump_tc dflags)
             (printForUserTcRn short_dump) ;

        -- Dump bindings if -ddump-tc
        traceOptTcRn Opt_D_dump_tc (mkDumpDoc "Typechecker" full_dump)
   }
  where
    short_dump = pprTcGblEnv env
    full_dump  = pprLHsBinds (tcg_binds env)
        -- NB: foreign x-d's have undefined's in their types;
        --     hence can't show the tc_fords

-- It's unpleasant having both pprModGuts and pprModDetails here
pprTcGblEnv :: TcGblEnv -> SDoc
pprTcGblEnv (TcGblEnv { tcg_type_env  = type_env,
                        tcg_insts     = insts,
                        tcg_fam_insts = fam_insts,
                        tcg_rules     = rules,
                        tcg_vects     = vects,
                        tcg_imports   = imports })
  = vcat [ ppr_types type_env
         , ppr_tycons fam_insts type_env
         , ppr_insts insts
         , ppr_fam_insts fam_insts
         , vcat (map ppr rules)
         , vcat (map ppr vects)
         , text "Dependent modules:" <+>
                ppr (sortBy cmp_mp $ eltsUFM (imp_dep_mods imports))
         , text "Dependent packages:" <+>
                ppr (sortBy stableUnitIdCmp $ imp_dep_pkgs imports)]
  where         -- The two uses of sortBy are just to reduce unnecessary
                -- wobbling in testsuite output
    cmp_mp (mod_name1, is_boot1) (mod_name2, is_boot2)
        = (mod_name1 `stableModuleNameCmp` mod_name2)
                  `thenCmp`
          (is_boot1 `compare` is_boot2)

ppr_types :: TypeEnv -> SDoc
ppr_types type_env
  = text "TYPE SIGNATURES" $$ nest 2 (ppr_sigs ids)
  where
    ids = [id | id <- typeEnvIds type_env, want_sig id]
    want_sig id | opt_PprStyle_Debug
                = True
                | otherwise
                = isExternalName (idName id) &&
                  (not (isDerivedOccName (getOccName id)))
        -- Top-level user-defined things have External names.
        -- Suppress internally-generated things unless -dppr-debug

ppr_tycons :: [FamInst] -> TypeEnv -> SDoc
ppr_tycons fam_insts type_env
  = vcat [ text "TYPE CONSTRUCTORS"
         ,   nest 2 (ppr_tydecls tycons)
         , text "COERCION AXIOMS"
         ,   nest 2 (vcat (map pprCoAxiom (typeEnvCoAxioms type_env))) ]
  where
    fi_tycons = famInstsRepTyCons fam_insts
    tycons = [tycon | tycon <- typeEnvTyCons type_env, want_tycon tycon]
    want_tycon tycon | opt_PprStyle_Debug = True
                     | otherwise          = not (isImplicitTyCon tycon) &&
                                            isExternalName (tyConName tycon) &&
                                            not (tycon `elem` fi_tycons)

ppr_insts :: [ClsInst] -> SDoc
ppr_insts []     = empty
ppr_insts ispecs = text "INSTANCES" $$ nest 2 (pprInstances ispecs)

ppr_fam_insts :: [FamInst] -> SDoc
ppr_fam_insts []        = empty
ppr_fam_insts fam_insts =
  text "FAMILY INSTANCES" $$ nest 2 (pprFamInsts fam_insts)

ppr_sigs :: [Var] -> SDoc
ppr_sigs ids
        -- Print type signatures; sort by OccName
  = vcat (map ppr_sig (sortBy (comparing getOccName) ids))
  where
    ppr_sig id = hang (ppr id <+> dcolon) 2 (ppr (tidyTopType (idType id)))

ppr_tydecls :: [TyCon] -> SDoc
ppr_tydecls tycons
        -- Print type constructor info; sort by OccName
  = vcat (map ppr_tycon (sortBy (comparing getOccName) tycons))
  where
    ppr_tycon tycon = vcat [ ppr (tyThingToIfaceDecl (ATyCon tycon)) ]

{-
********************************************************************************

Type Checker Plugins

********************************************************************************
-}

withTcPlugins :: HscEnv -> TcM a -> TcM a
withTcPlugins hsc_env m =
  do plugins <- liftIO (loadTcPlugins hsc_env)
     case plugins of
       [] -> m  -- Common fast case
       _  -> do (solvers,stops) <- unzip `fmap` mapM startPlugin plugins
                -- This ensures that tcPluginStop is called even if a type
                -- error occurs during compilation (Fix of #10078)
                eitherRes <- tryM $ do
                  updGblEnv (\e -> e { tcg_tc_plugins = solvers }) m
                mapM_ (flip runTcPluginM Nothing) stops
                case eitherRes of
                  Left _ -> failM
                  Right res -> return res
  where
  startPlugin (TcPlugin start solve stop) =
    do s <- runTcPluginM start Nothing
       return (solve s, stop s)

loadTcPlugins :: HscEnv -> IO [TcPlugin]
#ifndef GHCI
loadTcPlugins _ = return []
#else
loadTcPlugins hsc_env =
 do named_plugins <- loadPlugins hsc_env
    return $ catMaybes $ map load_plugin named_plugins
  where
    load_plugin (_, plug, opts) = tcPlugin plug opts
#endif
