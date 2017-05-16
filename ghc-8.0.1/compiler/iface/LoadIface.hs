{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998


Loading interface files
-}

{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module LoadIface (
        -- Importing one thing
        tcLookupImported_maybe, importDecl,
        checkWiredInTyCon, ifCheckWiredInThing,

        -- RnM/TcM functions
        loadModuleInterface, loadModuleInterfaces,
        loadSrcInterface, loadSrcInterface_maybe,
        loadInterfaceForName, loadInterfaceForModule,

        -- IfM functions
        loadInterface, loadWiredInHomeIface,
        loadSysInterface, loadUserInterface, loadPluginInterface,
        findAndReadIface, readIface,    -- Used when reading the module's old interface
        loadDecls,      -- Should move to TcIface and be renamed
        initExternalPackageState,

        ifaceStats, pprModIface, showIface
   ) where

#include "HsVersions.h"

import {-# SOURCE #-}   TcIface( tcIfaceDecl, tcIfaceRules, tcIfaceInst,
                                 tcIfaceFamInst, tcIfaceVectInfo, tcIfaceAnnotations )

import DynFlags
import IfaceSyn
import IfaceEnv
import HscTypes

import BasicTypes hiding (SuccessFlag(..))
import TcRnMonad

import Constants
import PrelNames
import PrelInfo
import PrimOp   ( allThePrimOps, primOpFixity, primOpOcc )
import MkId     ( seqId )
import TysPrim  ( funTyConName )
import Rules
import TyCon
import Annotations
import InstEnv
import FamInstEnv
import Name
import NameEnv
import Avail
import Module
import Maybes
import ErrUtils
import Finder
import UniqFM
import SrcLoc
import Outputable
import BinIface
import Panic
import Util
import FastString
import Fingerprint
import Hooks
import FieldLabel

import Control.Monad
import Data.IORef
import System.FilePath

{-
************************************************************************
*                                                                      *
*      tcImportDecl is the key function for "faulting in"              *
*      imported things
*                                                                      *
************************************************************************

The main idea is this.  We are chugging along type-checking source code, and
find a reference to GHC.Base.map.  We call tcLookupGlobal, which doesn't find
it in the EPS type envt.  So it
        1 loads GHC.Base.hi
        2 gets the decl for GHC.Base.map
        3 typechecks it via tcIfaceDecl
        4 and adds it to the type env in the EPS

Note that DURING STEP 4, we may find that map's type mentions a type
constructor that also

Notice that for imported things we read the current version from the EPS
mutable variable.  This is important in situations like
        ...$(e1)...$(e2)...
where the code that e1 expands to might import some defns that
also turn out to be needed by the code that e2 expands to.
-}

tcLookupImported_maybe :: Name -> TcM (MaybeErr MsgDoc TyThing)
-- Returns (Failed err) if we can't find the interface file for the thing
tcLookupImported_maybe name
  = do  { hsc_env <- getTopEnv
        ; mb_thing <- liftIO (lookupTypeHscEnv hsc_env name)
        ; case mb_thing of
            Just thing -> return (Succeeded thing)
            Nothing    -> tcImportDecl_maybe name }

tcImportDecl_maybe :: Name -> TcM (MaybeErr MsgDoc TyThing)
-- Entry point for *source-code* uses of importDecl
tcImportDecl_maybe name
  | Just thing <- wiredInNameTyThing_maybe name
  = do  { when (needWiredInHomeIface thing)
               (initIfaceTcRn (loadWiredInHomeIface name))
                -- See Note [Loading instances for wired-in things]
        ; return (Succeeded thing) }
  | otherwise
  = initIfaceTcRn (importDecl name)

importDecl :: Name -> IfM lcl (MaybeErr MsgDoc TyThing)
-- Get the TyThing for this Name from an interface file
-- It's not a wired-in thing -- the caller caught that
importDecl name
  = ASSERT( not (isWiredInName name) )
    do  { traceIf nd_doc

        -- Load the interface, which should populate the PTE
        ; mb_iface <- ASSERT2( isExternalName name, ppr name )
                      loadInterface nd_doc (nameModule name) ImportBySystem
        ; case mb_iface of {
                Failed err_msg  -> return (Failed err_msg) ;
                Succeeded _ -> do

        -- Now look it up again; this time we should find it
        { eps <- getEps
        ; case lookupTypeEnv (eps_PTE eps) name of
            Just thing -> return (Succeeded thing)
            Nothing    -> return (Failed not_found_msg)
    }}}
  where
    nd_doc = text "Need decl for" <+> ppr name
    not_found_msg = hang (text "Can't find interface-file declaration for" <+>
                                pprNameSpace (occNameSpace (nameOccName name)) <+> ppr name)
                       2 (vcat [text "Probable cause: bug in .hi-boot file, or inconsistent .hi file",
                                text "Use -ddump-if-trace to get an idea of which file caused the error"])


{-
************************************************************************
*                                                                      *
           Checks for wired-in things
*                                                                      *
************************************************************************

Note [Loading instances for wired-in things]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We need to make sure that we have at least *read* the interface files
for any module with an instance decl or RULE that we might want.

* If the instance decl is an orphan, we have a whole separate mechanism
  (loadOrphanModules)

* If the instance decl is not an orphan, then the act of looking at the
  TyCon or Class will force in the defining module for the
  TyCon/Class, and hence the instance decl

* BUT, if the TyCon is a wired-in TyCon, we don't really need its interface;
  but we must make sure we read its interface in case it has instances or
  rules.  That is what LoadIface.loadWiredInHomeInterface does.  It's called
  from TcIface.{tcImportDecl, checkWiredInTyCon, ifCheckWiredInThing}

* HOWEVER, only do this for TyCons.  There are no wired-in Classes.  There
  are some wired-in Ids, but we don't want to load their interfaces. For
  example, Control.Exception.Base.recSelError is wired in, but that module
  is compiled late in the base library, and we don't want to force it to
  load before it's been compiled!

All of this is done by the type checker. The renamer plays no role.
(It used to, but no longer.)
-}

checkWiredInTyCon :: TyCon -> TcM ()
-- Ensure that the home module of the TyCon (and hence its instances)
-- are loaded. See Note [Loading instances for wired-in things]
-- It might not be a wired-in tycon (see the calls in TcUnify),
-- in which case this is a no-op.
checkWiredInTyCon tc
  | not (isWiredInName tc_name)
  = return ()
  | otherwise
  = do  { mod <- getModule
        ; traceIf (text "checkWiredInTyCon" <+> ppr tc_name $$ ppr mod)
        ; ASSERT( isExternalName tc_name )
          when (mod /= nameModule tc_name)
               (initIfaceTcRn (loadWiredInHomeIface tc_name))
                -- Don't look for (non-existent) Float.hi when
                -- compiling Float.hs, which mentions Float of course
                -- A bit yukky to call initIfaceTcRn here
        }
  where
    tc_name = tyConName tc

ifCheckWiredInThing :: TyThing -> IfL ()
-- Even though we are in an interface file, we want to make
-- sure the instances of a wired-in thing are loaded (imagine f :: Double -> Double)
-- Ditto want to ensure that RULES are loaded too
-- See Note [Loading instances for wired-in things]
ifCheckWiredInThing thing
  = do  { mod <- getIfModule
                -- Check whether we are typechecking the interface for this
                -- very module.  E.g when compiling the base library in --make mode
                -- we may typecheck GHC.Base.hi. At that point, GHC.Base is not in
                -- the HPT, so without the test we'll demand-load it into the PIT!
                -- C.f. the same test in checkWiredInTyCon above
        ; let name = getName thing
        ; ASSERT2( isExternalName name, ppr name )
          when (needWiredInHomeIface thing && mod /= nameModule name)
               (loadWiredInHomeIface name) }

needWiredInHomeIface :: TyThing -> Bool
-- Only for TyCons; see Note [Loading instances for wired-in things]
needWiredInHomeIface (ATyCon {}) = True
needWiredInHomeIface _           = False


{-
************************************************************************
*                                                                      *
        loadSrcInterface, loadOrphanModules, loadInterfaceForName

                These three are called from TcM-land
*                                                                      *
************************************************************************
-}

-- | Load the interface corresponding to an @import@ directive in
-- source code.  On a failure, fail in the monad with an error message.
loadSrcInterface :: SDoc
                 -> ModuleName
                 -> IsBootInterface     -- {-# SOURCE #-} ?
                 -> Maybe FastString    -- "package", if any
                 -> RnM ModIface

loadSrcInterface doc mod want_boot maybe_pkg
  = do { res <- loadSrcInterface_maybe doc mod want_boot maybe_pkg
       ; case res of
           Failed err      -> failWithTc err
           Succeeded iface -> return iface }

-- | Like 'loadSrcInterface', but returns a 'MaybeErr'.
loadSrcInterface_maybe :: SDoc
                       -> ModuleName
                       -> IsBootInterface     -- {-# SOURCE #-} ?
                       -> Maybe FastString    -- "package", if any
                       -> RnM (MaybeErr MsgDoc ModIface)

loadSrcInterface_maybe doc mod want_boot maybe_pkg
  -- We must first find which Module this import refers to.  This involves
  -- calling the Finder, which as a side effect will search the filesystem
  -- and create a ModLocation.  If successful, loadIface will read the
  -- interface; it will call the Finder again, but the ModLocation will be
  -- cached from the first search.
  = do { hsc_env <- getTopEnv
       ; res <- liftIO $ findImportedModule hsc_env mod maybe_pkg
       ; case res of
           Found _ mod -> initIfaceTcRn $ loadInterface doc mod (ImportByUser want_boot)
           err         -> return (Failed (cannotFindInterface (hsc_dflags hsc_env) mod err)) }

-- | Load interface directly for a fully qualified 'Module'.  (This is a fairly
-- rare operation, but in particular it is used to load orphan modules
-- in order to pull their instances into the global package table and to
-- handle some operations in GHCi).
loadModuleInterface :: SDoc -> Module -> TcM ModIface
loadModuleInterface doc mod = initIfaceTcRn (loadSysInterface doc mod)

-- | Load interfaces for a collection of modules.
loadModuleInterfaces :: SDoc -> [Module] -> TcM ()
loadModuleInterfaces doc mods
  | null mods = return ()
  | otherwise = initIfaceTcRn (mapM_ load mods)
  where
    load mod = loadSysInterface (doc <+> parens (ppr mod)) mod

-- | Loads the interface for a given Name.
-- Should only be called for an imported name;
-- otherwise loadSysInterface may not find the interface
loadInterfaceForName :: SDoc -> Name -> TcRn ModIface
loadInterfaceForName doc name
  = do { when debugIsOn $  -- Check pre-condition
         do { this_mod <- getModule
            ; MASSERT2( not (nameIsLocalOrFrom this_mod name), ppr name <+> parens doc ) }
      ; ASSERT2( isExternalName name, ppr name )
        initIfaceTcRn $ loadSysInterface doc (nameModule name) }

-- | Loads the interface for a given Module.
loadInterfaceForModule :: SDoc -> Module -> TcRn ModIface
loadInterfaceForModule doc m
  = do
    -- Should not be called with this module
    when debugIsOn $ do
      this_mod <- getModule
      MASSERT2( this_mod /= m, ppr m <+> parens doc )
    initIfaceTcRn $ loadSysInterface doc m

{-
*********************************************************
*                                                      *
                loadInterface

        The main function to load an interface
        for an imported module, and put it in
        the External Package State
*                                                      *
*********************************************************
-}

-- | An 'IfM' function to load the home interface for a wired-in thing,
-- so that we're sure that we see its instance declarations and rules
-- See Note [Loading instances for wired-in things]
loadWiredInHomeIface :: Name -> IfM lcl ()
loadWiredInHomeIface name
  = ASSERT( isWiredInName name )
    do _ <- loadSysInterface doc (nameModule name); return ()
  where
    doc = text "Need home interface for wired-in thing" <+> ppr name

------------------
-- | Loads a system interface and throws an exception if it fails
loadSysInterface :: SDoc -> Module -> IfM lcl ModIface
loadSysInterface doc mod_name = loadInterfaceWithException doc mod_name ImportBySystem

------------------
-- | Loads a user interface and throws an exception if it fails. The first parameter indicates
-- whether we should import the boot variant of the module
loadUserInterface :: Bool -> SDoc -> Module -> IfM lcl ModIface
loadUserInterface is_boot doc mod_name
  = loadInterfaceWithException doc mod_name (ImportByUser is_boot)

loadPluginInterface :: SDoc -> Module -> IfM lcl ModIface
loadPluginInterface doc mod_name
  = loadInterfaceWithException doc mod_name ImportByPlugin

------------------
-- | A wrapper for 'loadInterface' that throws an exception if it fails
loadInterfaceWithException :: SDoc -> Module -> WhereFrom -> IfM lcl ModIface
loadInterfaceWithException doc mod_name where_from
  = do  { mb_iface <- loadInterface doc mod_name where_from
        ; dflags <- getDynFlags
        ; case mb_iface of
            Failed err      -> liftIO $ throwGhcExceptionIO (ProgramError (showSDoc dflags err))
            Succeeded iface -> return iface }

------------------
loadInterface :: SDoc -> Module -> WhereFrom
              -> IfM lcl (MaybeErr MsgDoc ModIface)

-- loadInterface looks in both the HPT and PIT for the required interface
-- If not found, it loads it, and puts it in the PIT (always).

-- If it can't find a suitable interface file, we
--      a) modify the PackageIfaceTable to have an empty entry
--              (to avoid repeated complaints)
--      b) return (Left message)
--
-- It's not necessarily an error for there not to be an interface
-- file -- perhaps the module has changed, and that interface
-- is no longer used

loadInterface doc_str mod from
  = do  {       -- Read the state
          (eps,hpt) <- getEpsAndHpt
        ; gbl_env <- getGblEnv

        ; traceIf (text "Considering whether to load" <+> ppr mod <+> ppr from)

                -- Check whether we have the interface already
        ; dflags <- getDynFlags
        ; case lookupIfaceByModule dflags hpt (eps_PIT eps) mod of {
            Just iface
                -> return (Succeeded iface) ;   -- Already loaded
                        -- The (src_imp == mi_boot iface) test checks that the already-loaded
                        -- interface isn't a boot iface.  This can conceivably happen,
                        -- if an earlier import had a before we got to real imports.   I think.
            _ -> do {

        -- READ THE MODULE IN
        ; read_result <- case (wantHiBootFile dflags eps mod from) of
                           Failed err             -> return (Failed err)
                           Succeeded hi_boot_file ->
                            -- Stoutly warn against an EPS-updating import
                            -- of one's own boot file! (one-shot only)
                            --See Note [Do not update EPS with your own hi-boot]
                            -- in MkIface.
                            WARN( hi_boot_file &&
                                  fmap fst (if_rec_types gbl_env) == Just mod,
                                  ppr mod )
                            findAndReadIface doc_str mod hi_boot_file
        ; case read_result of {
            Failed err -> do
                { let fake_iface = emptyModIface mod

                ; updateEps_ $ \eps ->
                        eps { eps_PIT = extendModuleEnv (eps_PIT eps) (mi_module fake_iface) fake_iface }
                        -- Not found, so add an empty iface to
                        -- the EPS map so that we don't look again

                ; return (Failed err) } ;

        -- Found and parsed!
        -- We used to have a sanity check here that looked for:
        --  * System importing ..
        --  * a home package module ..
        --  * that we know nothing about (mb_dep == Nothing)!
        --
        -- But this is no longer valid because thNameToGhcName allows users to
        -- cause the system to load arbitrary interfaces (by supplying an appropriate
        -- Template Haskell original-name).
            Succeeded (iface, file_path) ->

        let
            loc_doc = text file_path
        in
        initIfaceLcl mod loc_doc $ do

        --      Load the new ModIface into the External Package State
        -- Even home-package interfaces loaded by loadInterface
        --      (which only happens in OneShot mode; in Batch/Interactive
        --      mode, home-package modules are loaded one by one into the HPT)
        -- are put in the EPS.
        --
        -- The main thing is to add the ModIface to the PIT, but
        -- we also take the
        --      IfaceDecls, IfaceClsInst, IfaceFamInst, IfaceRules, IfaceVectInfo
        -- out of the ModIface and put them into the big EPS pools

        -- NB: *first* we do loadDecl, so that the provenance of all the locally-defined
        ---    names is done correctly (notably, whether this is an .hi file or .hi-boot file).
        --     If we do loadExport first the wrong info gets into the cache (unless we
        --      explicitly tag each export which seems a bit of a bore)

        ; ignore_prags      <- goptM Opt_IgnoreInterfacePragmas
        ; new_eps_decls     <- loadDecls ignore_prags (mi_decls iface)
        ; new_eps_insts     <- mapM tcIfaceInst (mi_insts iface)
        ; new_eps_fam_insts <- mapM tcIfaceFamInst (mi_fam_insts iface)
        ; new_eps_rules     <- tcIfaceRules ignore_prags (mi_rules iface)
        ; new_eps_anns      <- tcIfaceAnnotations (mi_anns iface)
        ; new_eps_vect_info <- tcIfaceVectInfo mod (mkNameEnv new_eps_decls) (mi_vect_info iface)

        ; let { final_iface = iface {
                                mi_decls     = panic "No mi_decls in PIT",
                                mi_insts     = panic "No mi_insts in PIT",
                                mi_fam_insts = panic "No mi_fam_insts in PIT",
                                mi_rules     = panic "No mi_rules in PIT",
                                mi_anns      = panic "No mi_anns in PIT"
                              }
               }

        ; updateEps_  $ \ eps ->
           if elemModuleEnv mod (eps_PIT eps) then eps else
                eps {
                  eps_PIT          = extendModuleEnv (eps_PIT eps) mod final_iface,
                  eps_PTE          = addDeclsToPTE   (eps_PTE eps) new_eps_decls,
                  eps_rule_base    = extendRuleBaseList (eps_rule_base eps)
                                                        new_eps_rules,
                  eps_inst_env     = extendInstEnvList (eps_inst_env eps)
                                                       new_eps_insts,
                  eps_fam_inst_env = extendFamInstEnvList (eps_fam_inst_env eps)
                                                          new_eps_fam_insts,
                  eps_vect_info    = plusVectInfo (eps_vect_info eps)
                                                  new_eps_vect_info,
                  eps_ann_env      = extendAnnEnvList (eps_ann_env eps)
                                                      new_eps_anns,
                  eps_mod_fam_inst_env
                                   = let
                                       fam_inst_env =
                                         extendFamInstEnvList emptyFamInstEnv
                                                              new_eps_fam_insts
                                     in
                                     extendModuleEnv (eps_mod_fam_inst_env eps)
                                                     mod
                                                     fam_inst_env,
                  eps_stats        = addEpsInStats (eps_stats eps)
                                                   (length new_eps_decls)
                                                   (length new_eps_insts)
                                                   (length new_eps_rules) }

        ; return (Succeeded final_iface)
    }}}}

wantHiBootFile :: DynFlags -> ExternalPackageState -> Module -> WhereFrom
               -> MaybeErr MsgDoc IsBootInterface
-- Figure out whether we want Foo.hi or Foo.hi-boot
wantHiBootFile dflags eps mod from
  = case from of
       ImportByUser usr_boot
          | usr_boot && not this_package
          -> Failed (badSourceImport mod)
          | otherwise -> Succeeded usr_boot

       ImportByPlugin
          -> Succeeded False

       ImportBySystem
          | not this_package   -- If the module to be imported is not from this package
          -> Succeeded False   -- don't look it up in eps_is_boot, because that is keyed
                               -- on the ModuleName of *home-package* modules only.
                               -- We never import boot modules from other packages!

          | otherwise
          -> case lookupUFM (eps_is_boot eps) (moduleName mod) of
                Just (_, is_boot) -> Succeeded is_boot
                Nothing           -> Succeeded False
                     -- The boot-ness of the requested interface,
                     -- based on the dependencies in directly-imported modules
  where
    this_package = thisPackage dflags == moduleUnitId mod

badSourceImport :: Module -> SDoc
badSourceImport mod
  = hang (text "You cannot {-# SOURCE #-} import a module from another package")
       2 (text "but" <+> quotes (ppr mod) <+> ptext (sLit "is from package")
          <+> quotes (ppr (moduleUnitId mod)))

-----------------------------------------------------
--      Loading type/class/value decls
-- We pass the full Module name here, replete with
-- its package info, so that we can build a Name for
-- each binder with the right package info in it
-- All subsequent lookups, including crucially lookups during typechecking
-- the declaration itself, will find the fully-glorious Name
--
-- We handle ATs specially.  They are not main declarations, but also not
-- implicit things (in particular, adding them to `implicitTyThings' would mess
-- things up in the renaming/type checking of source programs).
-----------------------------------------------------

addDeclsToPTE :: PackageTypeEnv -> [(Name,TyThing)] -> PackageTypeEnv
addDeclsToPTE pte things = extendNameEnvList pte things

loadDecls :: Bool
          -> [(Fingerprint, IfaceDecl)]
          -> IfL [(Name,TyThing)]
loadDecls ignore_prags ver_decls
   = do { thingss <- mapM (loadDecl ignore_prags) ver_decls
        ; return (concat thingss)
        }

loadDecl :: Bool                    -- Don't load pragmas into the decl pool
          -> (Fingerprint, IfaceDecl)
          -> IfL [(Name,TyThing)]   -- The list can be poked eagerly, but the
                                    -- TyThings are forkM'd thunks
loadDecl ignore_prags (_version, decl)
  = do  {       -- Populate the name cache with final versions of all
                -- the names associated with the decl
          main_name      <- lookupIfaceTop (ifName decl)

        -- Typecheck the thing, lazily
        -- NB. Firstly, the laziness is there in case we never need the
        -- declaration (in one-shot mode), and secondly it is there so that
        -- we don't look up the occurrence of a name before calling mk_new_bndr
        -- on the binder.  This is important because we must get the right name
        -- which includes its nameParent.

        ; thing <- forkM doc $ do { bumpDeclStats main_name
                                  ; tcIfaceDecl ignore_prags decl }

        -- Populate the type environment with the implicitTyThings too.
        --
        -- Note [Tricky iface loop]
        -- ~~~~~~~~~~~~~~~~~~~~~~~~
        -- Summary: The delicate point here is that 'mini-env' must be
        -- buildable from 'thing' without demanding any of the things
        -- 'forkM'd by tcIfaceDecl.
        --
        -- In more detail: Consider the example
        --      data T a = MkT { x :: T a }
        -- The implicitTyThings of T are:  [ <datacon MkT>, <selector x>]
        -- (plus their workers, wrappers, coercions etc etc)
        --
        -- We want to return an environment
        --      [ "MkT" -> <datacon MkT>, "x" -> <selector x>, ... ]
        -- (where the "MkT" is the *Name* associated with MkT, etc.)
        --
        -- We do this by mapping the implicit_names to the associated
        -- TyThings.  By the invariant on ifaceDeclImplicitBndrs and
        -- implicitTyThings, we can use getOccName on the implicit
        -- TyThings to make this association: each Name's OccName should
        -- be the OccName of exactly one implicitTyThing.  So the key is
        -- to define a "mini-env"
        --
        -- [ 'MkT' -> <datacon MkT>, 'x' -> <selector x>, ... ]
        -- where the 'MkT' here is the *OccName* associated with MkT.
        --
        -- However, there is a subtlety: due to how type checking needs
        -- to be staged, we can't poke on the forkM'd thunks inside the
        -- implicitTyThings while building this mini-env.
        -- If we poke these thunks too early, two problems could happen:
        --    (1) When processing mutually recursive modules across
        --        hs-boot boundaries, poking too early will do the
        --        type-checking before the recursive knot has been tied,
        --        so things will be type-checked in the wrong
        --        environment, and necessary variables won't be in
        --        scope.
        --
        --    (2) Looking up one OccName in the mini_env will cause
        --        others to be looked up, which might cause that
        --        original one to be looked up again, and hence loop.
        --
        -- The code below works because of the following invariant:
        -- getOccName on a TyThing does not force the suspended type
        -- checks in order to extract the name. For example, we don't
        -- poke on the "T a" type of <selector x> on the way to
        -- extracting <selector x>'s OccName. Of course, there is no
        -- reason in principle why getting the OccName should force the
        -- thunks, but this means we need to be careful in
        -- implicitTyThings and its helper functions.
        --
        -- All a bit too finely-balanced for my liking.

        -- This mini-env and lookup function mediates between the
        --'Name's n and the map from 'OccName's to the implicit TyThings
        ; let mini_env = mkOccEnv [(getOccName t, t) | t <- implicitTyThings thing]
              lookup n = case lookupOccEnv mini_env (getOccName n) of
                           Just thing -> thing
                           Nothing    ->
                             pprPanic "loadDecl" (ppr main_name <+> ppr n $$ ppr (decl))

        ; implicit_names <- mapM lookupIfaceTop (ifaceDeclImplicitBndrs decl)

--         ; traceIf (text "Loading decl for " <> ppr main_name $$ ppr implicit_names)
        ; return $ (main_name, thing) :
                      -- uses the invariant that implicit_names and
                      -- implicitTyThings are bijective
                      [(n, lookup n) | n <- implicit_names]
        }
  where
    doc = text "Declaration for" <+> ppr (ifName decl)

bumpDeclStats :: Name -> IfL ()         -- Record that one more declaration has actually been used
bumpDeclStats name
  = do  { traceIf (text "Loading decl for" <+> ppr name)
        ; updateEps_ (\eps -> let stats = eps_stats eps
                              in eps { eps_stats = stats { n_decls_out = n_decls_out stats + 1 } })
        }

{-
*********************************************************
*                                                      *
\subsection{Reading an interface file}
*                                                      *
*********************************************************

Note [Home module load error]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If the sought-for interface is in the current package (as determined
by -package-name flag) then it jolly well should already be in the HPT
because we process home-package modules in dependency order.  (Except
in one-shot mode; see notes with hsc_HPT decl in HscTypes).

It is possible (though hard) to get this error through user behaviour.
  * Suppose package P (modules P1, P2) depends on package Q (modules Q1,
    Q2, with Q2 importing Q1)
  * We compile both packages.
  * Now we edit package Q so that it somehow depends on P
  * Now recompile Q with --make (without recompiling P).
  * Then Q1 imports, say, P1, which in turn depends on Q2. So Q2
    is a home-package module which is not yet in the HPT!  Disaster.

This actually happened with P=base, Q=ghc-prim, via the AMP warnings.
See Trac #8320.
-}

findAndReadIface :: SDoc -> Module
                 -> IsBootInterface     -- True  <=> Look for a .hi-boot file
                                        -- False <=> Look for .hi file
                 -> TcRnIf gbl lcl (MaybeErr MsgDoc (ModIface, FilePath))
        -- Nothing <=> file not found, or unreadable, or illegible
        -- Just x  <=> successfully found and parsed

        -- It *doesn't* add an error to the monad, because
        -- sometimes it's ok to fail... see notes with loadInterface

findAndReadIface doc_str mod hi_boot_file
  = do traceIf (sep [hsep [text "Reading",
                           if hi_boot_file
                             then text "[boot]"
                             else Outputable.empty,
                           text "interface for",
                           ppr mod <> semi],
                     nest 4 (text "reason:" <+> doc_str)])

       -- Check for GHC.Prim, and return its static interface
       if mod == gHC_PRIM
           then do
               iface <- getHooked ghcPrimIfaceHook ghcPrimIface
               return (Succeeded (iface,
                                   "<built in interface for GHC.Prim>"))
           else do
               dflags <- getDynFlags
               -- Look for the file
               hsc_env <- getTopEnv
               mb_found <- liftIO (findExactModule hsc_env mod)
               case mb_found of
                   Found loc mod -> do

                       -- Found file, so read it
                       let file_path = addBootSuffix_maybe hi_boot_file
                                                           (ml_hi_file loc)

                       -- See Note [Home module load error]
                       if thisPackage dflags == moduleUnitId mod &&
                          not (isOneShot (ghcMode dflags))
                           then return (Failed (homeModError mod loc))
                           else do r <- read_file file_path
                                   checkBuildDynamicToo r
                                   return r
                   err -> do
                       traceIf (text "...not found")
                       dflags <- getDynFlags
                       return (Failed (cannotFindInterface dflags
                                           (moduleName mod) err))
    where read_file file_path = do
              traceIf (text "readIFace" <+> text file_path)
              read_result <- readIface mod file_path
              case read_result of
                Failed err -> return (Failed (badIfaceFile file_path err))
                Succeeded iface
                    | mi_module iface /= mod ->
                      return (Failed (wrongIfaceModErr iface mod file_path))
                    | otherwise ->
                      return (Succeeded (iface, file_path))
                            -- Don't forget to fill in the package name...
          checkBuildDynamicToo (Succeeded (iface, filePath)) = do
              dflags <- getDynFlags
              whenGeneratingDynamicToo dflags $ withDoDynamicToo $ do
                  let ref = canGenerateDynamicToo dflags
                      dynFilePath = addBootSuffix_maybe hi_boot_file
                                  $ replaceExtension filePath (dynHiSuf dflags)
                  r <- read_file dynFilePath
                  case r of
                      Succeeded (dynIface, _)
                       | mi_mod_hash iface == mi_mod_hash dynIface ->
                          return ()
                       | otherwise ->
                          do traceIf (text "Dynamic hash doesn't match")
                             liftIO $ writeIORef ref False
                      Failed err ->
                          do traceIf (text "Failed to load dynamic interface file:" $$ err)
                             liftIO $ writeIORef ref False
          checkBuildDynamicToo _ = return ()

-- @readIface@ tries just the one file.

readIface :: Module -> FilePath
          -> TcRnIf gbl lcl (MaybeErr MsgDoc ModIface)
        -- Failed err    <=> file not found, or unreadable, or illegible
        -- Succeeded iface <=> successfully found and parsed

readIface wanted_mod file_path
  = do  { res <- tryMostM $
                 readBinIface CheckHiWay QuietBinIFaceReading file_path
        ; case res of
            Right iface
                | wanted_mod == actual_mod -> return (Succeeded iface)
                | otherwise                -> return (Failed err)
                where
                  actual_mod = mi_module iface
                  err = hiModuleNameMismatchWarn wanted_mod actual_mod

            Left exn    -> return (Failed (text (showException exn)))
    }

{-
*********************************************************
*                                                       *
        Wired-in interface for GHC.Prim
*                                                       *
*********************************************************
-}

initExternalPackageState :: ExternalPackageState
initExternalPackageState
  = EPS {
      eps_is_boot      = emptyUFM,
      eps_PIT          = emptyPackageIfaceTable,
      eps_PTE          = emptyTypeEnv,
      eps_inst_env     = emptyInstEnv,
      eps_fam_inst_env = emptyFamInstEnv,
      eps_rule_base    = mkRuleBase builtinRules,
        -- Initialise the EPS rule pool with the built-in rules
      eps_mod_fam_inst_env
                       = emptyModuleEnv,
      eps_vect_info    = noVectInfo,
      eps_ann_env      = emptyAnnEnv,
      eps_stats = EpsStats { n_ifaces_in = 0, n_decls_in = 0, n_decls_out = 0
                           , n_insts_in = 0, n_insts_out = 0
                           , n_rules_in = length builtinRules, n_rules_out = 0 }
    }

{-
*********************************************************
*                                                       *
        Wired-in interface for GHC.Prim
*                                                       *
*********************************************************
-}

ghcPrimIface :: ModIface
ghcPrimIface
  = (emptyModIface gHC_PRIM) {
        mi_exports  = ghcPrimExports,
        mi_decls    = [],
        mi_fixities = fixities,
        mi_fix_fn  = mkIfaceFixCache fixities
    }
  where
    fixities = (getOccName seqId, Fixity "0" 0 InfixR)  -- seq is infixr 0
             : (occName funTyConName, funTyFixity)  -- trac #10145
             : mapMaybe mkFixity allThePrimOps
    mkFixity op = (,) (primOpOcc op) <$> primOpFixity op

{-
*********************************************************
*                                                      *
\subsection{Statistics}
*                                                      *
*********************************************************
-}

ifaceStats :: ExternalPackageState -> SDoc
ifaceStats eps
  = hcat [text "Renamer stats: ", msg]
  where
    stats = eps_stats eps
    msg = vcat
        [int (n_ifaces_in stats) <+> text "interfaces read",
         hsep [ int (n_decls_out stats), text "type/class/variable imported, out of",
                int (n_decls_in stats), text "read"],
         hsep [ int (n_insts_out stats), text "instance decls imported, out of",
                int (n_insts_in stats), text "read"],
         hsep [ int (n_rules_out stats), text "rule decls imported, out of",
                int (n_rules_in stats), text "read"]
        ]

{-
************************************************************************
*                                                                      *
                Printing interfaces
*                                                                      *
************************************************************************
-}

-- | Read binary interface, and print it out
showIface :: HscEnv -> FilePath -> IO ()
showIface hsc_env filename = do
   -- skip the hi way check; we don't want to worry about profiled vs.
   -- non-profiled interfaces, for example.
   iface <- initTcRnIf 's' hsc_env () () $
       readBinIface IgnoreHiWay TraceBinIFaceReading filename
   let dflags = hsc_dflags hsc_env
   log_action dflags dflags NoReason SevDump noSrcSpan defaultDumpStyle (pprModIface iface)

pprModIface :: ModIface -> SDoc
-- Show a ModIface
pprModIface iface
 = vcat [ text "interface"
                <+> ppr (mi_module iface) <+> pp_hsc_src (mi_hsc_src iface)
                <+> (if mi_orphan iface then text "[orphan module]" else Outputable.empty)
                <+> (if mi_finsts iface then text "[family instance module]" else Outputable.empty)
                <+> (if mi_hpc    iface then text "[hpc]" else Outputable.empty)
                <+> integer hiVersion
        , nest 2 (text "interface hash:" <+> ppr (mi_iface_hash iface))
        , nest 2 (text "ABI hash:" <+> ppr (mi_mod_hash iface))
        , nest 2 (text "export-list hash:" <+> ppr (mi_exp_hash iface))
        , nest 2 (text "orphan hash:" <+> ppr (mi_orphan_hash iface))
        , nest 2 (text "flag hash:" <+> ppr (mi_flag_hash iface))
        , nest 2 (text "sig of:" <+> ppr (mi_sig_of iface))
        , nest 2 (text "used TH splices:" <+> ppr (mi_used_th iface))
        , nest 2 (text "where")
        , text "exports:"
        , nest 2 (vcat (map pprExport (mi_exports iface)))
        , pprDeps (mi_deps iface)
        , vcat (map pprUsage (mi_usages iface))
        , vcat (map pprIfaceAnnotation (mi_anns iface))
        , pprFixities (mi_fixities iface)
        , vcat [ppr ver $$ nest 2 (ppr decl) | (ver,decl) <- mi_decls iface]
        , vcat (map ppr (mi_insts iface))
        , vcat (map ppr (mi_fam_insts iface))
        , vcat (map ppr (mi_rules iface))
        , pprVectInfo (mi_vect_info iface)
        , ppr (mi_warns iface)
        , pprTrustInfo (mi_trust iface)
        , pprTrustPkg (mi_trust_pkg iface)
        ]
  where
    pp_hsc_src HsBootFile = text "[boot]"
    pp_hsc_src HsigFile = text "[hsig]"
    pp_hsc_src HsSrcFile = Outputable.empty

{-
When printing export lists, we print like this:
        Avail   f               f
        AvailTC C [C, x, y]     C(x,y)
        AvailTC C [x, y]        C!(x,y)         -- Exporting x, y but not C
-}

pprExport :: IfaceExport -> SDoc
pprExport (Avail _ n)         = ppr n
pprExport (AvailTC _ [] []) = Outputable.empty
pprExport (AvailTC n ns0 fs)
  = case ns0 of
      (n':ns) | n==n' -> ppr n <> pp_export ns fs
      _               -> ppr n <> vbar <> pp_export ns0 fs
  where
    pp_export []    [] = Outputable.empty
    pp_export names fs = braces (hsep (map ppr names ++ map (ppr . flLabel) fs))

pprUsage :: Usage -> SDoc
pprUsage usage@UsagePackageModule{}
  = pprUsageImport usage usg_mod
pprUsage usage@UsageHomeModule{}
  = pprUsageImport usage usg_mod_name $$
    nest 2 (
        maybe Outputable.empty (\v -> text "exports: " <> ppr v) (usg_exports usage) $$
        vcat [ ppr n <+> ppr v | (n,v) <- usg_entities usage ]
        )
pprUsage usage@UsageFile{}
  = hsep [text "addDependentFile",
          doubleQuotes (text (usg_file_path usage))]

pprUsageImport :: Outputable a => Usage -> (Usage -> a) -> SDoc
pprUsageImport usage usg_mod'
  = hsep [text "import", safe, ppr (usg_mod' usage),
                       ppr (usg_mod_hash usage)]
    where
        safe | usg_safe usage = text "safe"
             | otherwise      = text " -/ "

pprDeps :: Dependencies -> SDoc
pprDeps (Deps { dep_mods = mods, dep_pkgs = pkgs, dep_orphs = orphs,
                dep_finsts = finsts })
  = vcat [text "module dependencies:" <+> fsep (map ppr_mod mods),
          text "package dependencies:" <+> fsep (map ppr_pkg pkgs),
          text "orphans:" <+> fsep (map ppr orphs),
          text "family instance modules:" <+> fsep (map ppr finsts)
        ]
  where
    ppr_mod (mod_name, boot) = ppr mod_name <+> ppr_boot boot
    ppr_pkg (pkg,trust_req)  = ppr pkg <>
                               (if trust_req then text "*" else Outputable.empty)
    ppr_boot True  = text "[boot]"
    ppr_boot False = Outputable.empty

pprFixities :: [(OccName, Fixity)] -> SDoc
pprFixities []    = Outputable.empty
pprFixities fixes = text "fixities" <+> pprWithCommas pprFix fixes
                  where
                    pprFix (occ,fix) = ppr fix <+> ppr occ

pprVectInfo :: IfaceVectInfo -> SDoc
pprVectInfo (IfaceVectInfo { ifaceVectInfoVar            = vars
                           , ifaceVectInfoTyCon          = tycons
                           , ifaceVectInfoTyConReuse     = tyconsReuse
                           , ifaceVectInfoParallelVars   = parallelVars
                           , ifaceVectInfoParallelTyCons = parallelTyCons
                           }) =
  vcat
  [ text "vectorised variables:" <+> hsep (map ppr vars)
  , text "vectorised tycons:" <+> hsep (map ppr tycons)
  , text "vectorised reused tycons:" <+> hsep (map ppr tyconsReuse)
  , text "parallel variables:" <+> hsep (map ppr parallelVars)
  , text "parallel tycons:" <+> hsep (map ppr parallelTyCons)
  ]

pprTrustInfo :: IfaceTrustInfo -> SDoc
pprTrustInfo trust = text "trusted:" <+> ppr trust

pprTrustPkg :: Bool -> SDoc
pprTrustPkg tpkg = text "require own pkg trusted:" <+> ppr tpkg

instance Outputable Warnings where
    ppr = pprWarns

pprWarns :: Warnings -> SDoc
pprWarns NoWarnings         = Outputable.empty
pprWarns (WarnAll txt)  = text "Warn all" <+> ppr txt
pprWarns (WarnSome prs) = text "Warnings"
                        <+> vcat (map pprWarning prs)
    where pprWarning (name, txt) = ppr name <+> ppr txt

pprIfaceAnnotation :: IfaceAnnotation -> SDoc
pprIfaceAnnotation (IfaceAnnotation { ifAnnotatedTarget = target, ifAnnotatedValue = serialized })
  = ppr target <+> text "annotated by" <+> ppr serialized

{-
*********************************************************
*                                                       *
\subsection{Errors}
*                                                       *
*********************************************************
-}

badIfaceFile :: String -> SDoc -> SDoc
badIfaceFile file err
  = vcat [text "Bad interface file:" <+> text file,
          nest 4 err]

hiModuleNameMismatchWarn :: Module -> Module -> MsgDoc
hiModuleNameMismatchWarn requested_mod read_mod =
  -- ToDo: This will fail to have enough qualification when the package IDs
  -- are the same
  withPprStyle (mkUserStyle alwaysQualify AllTheWay) $
    -- we want the Modules below to be qualified with package names,
    -- so reset the PrintUnqualified setting.
    hsep [ text "Something is amiss; requested module "
         , ppr requested_mod
         , text "differs from name found in the interface file"
         , ppr read_mod
         ]

wrongIfaceModErr :: ModIface -> Module -> String -> SDoc
wrongIfaceModErr iface mod_name file_path
  = sep [text "Interface file" <+> iface_file,
         text "contains module" <+> quotes (ppr (mi_module iface)) <> comma,
         text "but we were expecting module" <+> quotes (ppr mod_name),
         sep [text "Probable cause: the source code which generated",
             nest 2 iface_file,
             text "has an incompatible module name"
            ]
        ]
  where iface_file = doubleQuotes (text file_path)

homeModError :: Module -> ModLocation -> SDoc
-- See Note [Home module load error]
homeModError mod location
  = text "attempting to use module " <> quotes (ppr mod)
    <> (case ml_hs_file location of
           Just file -> space <> parens (text file)
           Nothing   -> Outputable.empty)
    <+> text "which is not loaded"
