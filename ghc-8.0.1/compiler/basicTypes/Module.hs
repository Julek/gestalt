{-
(c) The University of Glasgow, 2004-2006


Module
~~~~~~~~~~
Simply the name of a module, represented as a FastString.
These are Uniquable, hence we can build Maps with Modules as
the keys.
-}

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}

module Module
    (
        -- * The ModuleName type
        ModuleName,
        pprModuleName,
        moduleNameFS,
        moduleNameString,
        moduleNameSlashes, moduleNameColons,
        moduleStableString,
        mkModuleName,
        mkModuleNameFS,
        stableModuleNameCmp,

        -- * The UnitId type
        UnitId,
        fsToUnitId,
        unitIdFS,
        stringToUnitId,
        unitIdString,
        stableUnitIdCmp,

        -- * Wired-in UnitIds
        -- $wired_in_packages
        primUnitId,
        integerUnitId,
        baseUnitId,
        rtsUnitId,
        thUnitId,
        dphSeqUnitId,
        dphParUnitId,
        mainUnitId,
        thisGhcUnitId,
        holeUnitId, isHoleModule,
        interactiveUnitId, isInteractiveModule,
        wiredInUnitIds,

        -- * The Module type
        Module(Module),
        moduleUnitId, moduleName,
        pprModule,
        mkModule,
        stableModuleCmp,
        HasModule(..),
        ContainsModule(..),

        -- * The ModuleLocation type
        ModLocation(..),
        addBootSuffix, addBootSuffix_maybe, addBootSuffixLocn,

        -- * Module mappings
        ModuleEnv,
        elemModuleEnv, extendModuleEnv, extendModuleEnvList,
        extendModuleEnvList_C, plusModuleEnv_C,
        delModuleEnvList, delModuleEnv, plusModuleEnv, lookupModuleEnv,
        lookupWithDefaultModuleEnv, mapModuleEnv, mkModuleEnv, emptyModuleEnv,
        moduleEnvKeys, moduleEnvElts, moduleEnvToList,
        unitModuleEnv, isEmptyModuleEnv,
        foldModuleEnv, extendModuleEnvWith, filterModuleEnv,

        -- * ModuleName mappings
        ModuleNameEnv,

        -- * Sets of Modules
        ModuleSet,
        emptyModuleSet, mkModuleSet, moduleSetElts, extendModuleSet, elemModuleSet
    ) where

import Config
import Outputable
import Unique
import UniqFM
import FastString
import Binary
import Util
import {-# SOURCE #-} Packages
import GHC.PackageDb (BinaryStringRep(..))

import Data.Data
import Data.Map (Map)
import qualified Data.Map as Map
import qualified FiniteMap as Map
import System.FilePath

-- Note [The identifier lexicon]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Package keys, installed package IDs, ABI hashes, package names,
-- versions, there are a *lot* of different identifiers for closely
-- related things.  What do they all mean? Here's what.  (See also
-- https://ghc.haskell.org/trac/ghc/wiki/Commentary/Packages/Concepts )
--
-- THE IMPORTANT ONES
--
-- ComponentId: An opaque identifier provided by Cabal, which should
-- uniquely identify such things as the package name, the package
-- version, the name of the component, the hash of the source code
-- tarball, the selected Cabal flags, GHC flags, direct dependencies of
-- the component.  These are very similar to InstalledPackageId, but
-- an 'InstalledPackageId' implies that it identifies a package, while
-- a package may install multiple components with different
-- 'ComponentId's.
--      - Same as Distribution.Package.ComponentId
--
-- UnitId: A ComponentId + a mapping from hole names (ModuleName) to
-- Modules.  This is how the compiler identifies instantatiated
-- components, and also is the main identifier by which GHC identifies
-- things.
--      - When Backpack is not being used, UnitId = ComponentId.
--        this means a useful fiction for end-users is that there are
--        only ever ComponentIds, and some ComponentIds happen to have
--        more information (UnitIds).
--      - Same as Language.Haskell.TH.Syntax:PkgName, see
--          https://ghc.haskell.org/trac/ghc/ticket/10279
--      - The same as PackageKey in GHC 7.10 (we renamed it because
--        they don't necessarily identify packages anymore.)
--      - Same as -this-package-key/-package-name flags
--
-- Module: A UnitId + ModuleName. This is how the compiler identifies
-- modules (e.g. a Name is a Module + OccName)
--      - Same as Language.Haskell.TH.Syntax:Module
--
-- THE LESS IMPORTANT ONES
--
-- PackageName: The "name" field in a Cabal file, something like "lens".
--      - Same as Distribution.Package.PackageName
--      - DIFFERENT FROM Language.Haskell.TH.Syntax:PkgName, see
--          https://ghc.haskell.org/trac/ghc/ticket/10279
--      - DIFFERENT FROM -package-name flag
--      - DIFFERENT FROM the 'name' field in an installed package
--        information.  This field could more accurately be described
--        as a munged package name: when it's for the main library
--        it is the same as the package name, but if it's an internal
--        library it's a munged combination of the package name and
--        the component name.
--
-- LEGACY ONES
--
-- InstalledPackageId: This is what we used to call ComponentId.
-- It's a still pretty useful concept for packages that have only
-- one library; in that case the logical InstalledPackageId =
-- ComponentId.  Also, the Cabal nix-local-build continues to
-- compute an InstalledPackageId which is then forcibly used
-- for all components in a package.  This means that if a dependency
-- from one component in a package changes, the InstalledPackageId
-- changes: you don't get as fine-grained dependency tracking,
-- but it means your builds are hermetic.  Eventually, Cabal will
-- deal completely in components and we can get rid of this.
--
-- PackageKey: This is what we used to call UnitId.  We ditched
-- "Package" from the name when we realized that you might want to
-- assign different "PackageKeys" to components from the same package.
-- (For a brief, non-released period of time, we also called these
-- UnitKeys).

{-
************************************************************************
*                                                                      *
\subsection{Module locations}
*                                                                      *
************************************************************************
-}

-- | Where a module lives on the file system: the actual locations
-- of the .hs, .hi and .o files, if we have them
data ModLocation
   = ModLocation {
        ml_hs_file   :: Maybe FilePath,
                -- The source file, if we have one.  Package modules
                -- probably don't have source files.

        ml_hi_file   :: FilePath,
                -- Where the .hi file is, whether or not it exists
                -- yet.  Always of form foo.hi, even if there is an
                -- hi-boot file (we add the -boot suffix later)

        ml_obj_file  :: FilePath
                -- Where the .o file is, whether or not it exists yet.
                -- (might not exist either because the module hasn't
                -- been compiled yet, or because it is part of a
                -- package with a .a file)
  } deriving Show

instance Outputable ModLocation where
   ppr = text . show

{-
For a module in another package, the hs_file and obj_file
components of ModLocation are undefined.

The locations specified by a ModLocation may or may not
correspond to actual files yet: for example, even if the object
file doesn't exist, the ModLocation still contains the path to
where the object file will reside if/when it is created.
-}

addBootSuffix :: FilePath -> FilePath
-- ^ Add the @-boot@ suffix to .hs, .hi and .o files
addBootSuffix path = path ++ "-boot"

addBootSuffix_maybe :: Bool -> FilePath -> FilePath
-- ^ Add the @-boot@ suffix if the @Bool@ argument is @True@
addBootSuffix_maybe is_boot path
 | is_boot   = addBootSuffix path
 | otherwise = path

addBootSuffixLocn :: ModLocation -> ModLocation
-- ^ Add the @-boot@ suffix to all file paths associated with the module
addBootSuffixLocn locn
  = locn { ml_hs_file  = fmap addBootSuffix (ml_hs_file locn)
         , ml_hi_file  = addBootSuffix (ml_hi_file locn)
         , ml_obj_file = addBootSuffix (ml_obj_file locn) }

{-
************************************************************************
*                                                                      *
\subsection{The name of a module}
*                                                                      *
************************************************************************
-}

-- | A ModuleName is essentially a simple string, e.g. @Data.List@.
newtype ModuleName = ModuleName FastString
    deriving Typeable

instance Uniquable ModuleName where
  getUnique (ModuleName nm) = getUnique nm

instance Eq ModuleName where
  nm1 == nm2 = getUnique nm1 == getUnique nm2

-- Warning: gives an ordering relation based on the uniques of the
-- FastStrings which are the (encoded) module names.  This is _not_
-- a lexicographical ordering.
instance Ord ModuleName where
  nm1 `compare` nm2 = getUnique nm1 `compare` getUnique nm2

instance Outputable ModuleName where
  ppr = pprModuleName

instance Binary ModuleName where
  put_ bh (ModuleName fs) = put_ bh fs
  get bh = do fs <- get bh; return (ModuleName fs)

instance BinaryStringRep ModuleName where
  fromStringRep = mkModuleNameFS . mkFastStringByteString
  toStringRep   = fastStringToByteString . moduleNameFS

instance Data ModuleName where
  -- don't traverse?
  toConstr _   = abstractConstr "ModuleName"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "ModuleName"

stableModuleNameCmp :: ModuleName -> ModuleName -> Ordering
-- ^ Compares module names lexically, rather than by their 'Unique's
stableModuleNameCmp n1 n2 = moduleNameFS n1 `compare` moduleNameFS n2

pprModuleName :: ModuleName -> SDoc
pprModuleName (ModuleName nm) =
    getPprStyle $ \ sty ->
    if codeStyle sty
        then ztext (zEncodeFS nm)
        else ftext nm

moduleNameFS :: ModuleName -> FastString
moduleNameFS (ModuleName mod) = mod

moduleNameString :: ModuleName -> String
moduleNameString (ModuleName mod) = unpackFS mod

-- | Get a string representation of a 'Module' that's unique and stable
-- across recompilations.
-- eg. "$aeson_70dylHtv1FFGeai1IoxcQr$Data.Aeson.Types.Internal"
moduleStableString :: Module -> String
moduleStableString Module{..} =
  "$" ++ unitIdString moduleUnitId ++ "$" ++ moduleNameString moduleName

mkModuleName :: String -> ModuleName
mkModuleName s = ModuleName (mkFastString s)

mkModuleNameFS :: FastString -> ModuleName
mkModuleNameFS s = ModuleName s

-- |Returns the string version of the module name, with dots replaced by slashes.
--
moduleNameSlashes :: ModuleName -> String
moduleNameSlashes = dots_to_slashes . moduleNameString
  where dots_to_slashes = map (\c -> if c == '.' then pathSeparator else c)

-- |Returns the string version of the module name, with dots replaced by underscores.
--
moduleNameColons :: ModuleName -> String
moduleNameColons = dots_to_colons . moduleNameString
  where dots_to_colons = map (\c -> if c == '.' then ':' else c)

{-
************************************************************************
*                                                                      *
\subsection{A fully qualified module}
*                                                                      *
************************************************************************
-}

-- | A Module is a pair of a 'UnitId' and a 'ModuleName'.
data Module = Module {
   moduleUnitId :: !UnitId,  -- pkg-1.0
   moduleName      :: !ModuleName  -- A.B.C
  }
  deriving (Eq, Ord, Typeable)

instance Uniquable Module where
  getUnique (Module p n) = getUnique (unitIdFS p `appendFS` moduleNameFS n)

instance Outputable Module where
  ppr = pprModule

instance Binary Module where
  put_ bh (Module p n) = put_ bh p >> put_ bh n
  get bh = do p <- get bh; n <- get bh; return (Module p n)

instance Data Module where
  -- don't traverse?
  toConstr _   = abstractConstr "Module"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "Module"

-- | This gives a stable ordering, as opposed to the Ord instance which
-- gives an ordering based on the 'Unique's of the components, which may
-- not be stable from run to run of the compiler.
stableModuleCmp :: Module -> Module -> Ordering
stableModuleCmp (Module p1 n1) (Module p2 n2)
   = (p1 `stableUnitIdCmp`  p2) `thenCmp`
     (n1 `stableModuleNameCmp` n2)

mkModule :: UnitId -> ModuleName -> Module
mkModule = Module

pprModule :: Module -> SDoc
pprModule mod@(Module p n)  =
  pprPackagePrefix p mod <> pprModuleName n

pprPackagePrefix :: UnitId -> Module -> SDoc
pprPackagePrefix p mod = getPprStyle doc
 where
   doc sty
       | codeStyle sty =
          if p == mainUnitId
                then empty -- never qualify the main package in code
                else ztext (zEncodeFS (unitIdFS p)) <> char '_'
       | qualModule sty mod = ppr (moduleUnitId mod) <> char ':'
                -- the PrintUnqualified tells us which modules have to
                -- be qualified with package names
       | otherwise = empty

class ContainsModule t where
    extractModule :: t -> Module

class HasModule m where
    getModule :: m Module

{-
************************************************************************
*                                                                      *
\subsection{UnitId}
*                                                                      *
************************************************************************
-}

-- | A string which uniquely identifies a package.  For wired-in packages,
-- it is just the package name, but for user compiled packages, it is a hash.
-- ToDo: when the key is a hash, we can do more clever things than store
-- the hex representation and hash-cons those strings.
newtype UnitId = PId FastString deriving( Eq, Typeable )
    -- here to avoid module loops with PackageConfig

instance Uniquable UnitId where
 getUnique pid = getUnique (unitIdFS pid)

-- Note: *not* a stable lexicographic ordering, a faster unique-based
-- ordering.
instance Ord UnitId where
  nm1 `compare` nm2 = getUnique nm1 `compare` getUnique nm2

instance Data UnitId where
  -- don't traverse?
  toConstr _   = abstractConstr "UnitId"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "UnitId"

stableUnitIdCmp :: UnitId -> UnitId -> Ordering
-- ^ Compares package ids lexically, rather than by their 'Unique's
stableUnitIdCmp p1 p2 = unitIdFS p1 `compare` unitIdFS p2

instance Outputable UnitId where
   ppr pk = getPprStyle $ \sty -> sdocWithDynFlags $ \dflags ->
    case unitIdPackageIdString dflags pk of
      Nothing -> ftext (unitIdFS pk)
      Just pkg -> text pkg
           -- Don't bother qualifying if it's wired in!
           <> (if qualPackage sty pk && not (pk `elem` wiredInUnitIds)
                then char '@' <> ftext (unitIdFS pk)
                else empty)

instance Binary UnitId where
  put_ bh pid = put_ bh (unitIdFS pid)
  get bh = do { fs <- get bh; return (fsToUnitId fs) }

instance BinaryStringRep UnitId where
  fromStringRep = fsToUnitId . mkFastStringByteString
  toStringRep   = fastStringToByteString . unitIdFS

fsToUnitId :: FastString -> UnitId
fsToUnitId = PId

unitIdFS :: UnitId -> FastString
unitIdFS (PId fs) = fs

stringToUnitId :: String -> UnitId
stringToUnitId = fsToUnitId . mkFastString

unitIdString :: UnitId -> String
unitIdString = unpackFS . unitIdFS


-- -----------------------------------------------------------------------------
-- $wired_in_packages
-- Certain packages are known to the compiler, in that we know about certain
-- entities that reside in these packages, and the compiler needs to
-- declare static Modules and Names that refer to these packages.  Hence
-- the wired-in packages can't include version numbers, since we don't want
-- to bake the version numbers of these packages into GHC.
--
-- So here's the plan.  Wired-in packages are still versioned as
-- normal in the packages database, and you can still have multiple
-- versions of them installed.  However, for each invocation of GHC,
-- only a single instance of each wired-in package will be recognised
-- (the desired one is selected via @-package@\/@-hide-package@), and GHC
-- will use the unversioned 'UnitId' below when referring to it,
-- including in .hi files and object file symbols.  Unselected
-- versions of wired-in packages will be ignored, as will any other
-- package that depends directly or indirectly on it (much as if you
-- had used @-ignore-package@).

-- Make sure you change 'Packages.findWiredInPackages' if you add an entry here

integerUnitId, primUnitId,
  baseUnitId, rtsUnitId,
  thUnitId, dphSeqUnitId, dphParUnitId,
  mainUnitId, thisGhcUnitId, interactiveUnitId  :: UnitId
primUnitId        = fsToUnitId (fsLit "ghc-prim")
integerUnitId     = fsToUnitId (fsLit n)
  where
    n = case cIntegerLibraryType of
        IntegerGMP    -> "integer-gmp"
        IntegerSimple -> "integer-simple"
baseUnitId        = fsToUnitId (fsLit "base")
rtsUnitId         = fsToUnitId (fsLit "rts")
thUnitId          = fsToUnitId (fsLit "template-haskell")
dphSeqUnitId      = fsToUnitId (fsLit "dph-seq")
dphParUnitId      = fsToUnitId (fsLit "dph-par")
thisGhcUnitId     = fsToUnitId (fsLit "ghc")
interactiveUnitId = fsToUnitId (fsLit "interactive")

-- | This is the package Id for the current program.  It is the default
-- package Id if you don't specify a package name.  We don't add this prefix
-- to symbol names, since there can be only one main package per program.
mainUnitId      = fsToUnitId (fsLit "main")

-- | This is a fake package id used to provide identities to any un-implemented
-- signatures.  The set of hole identities is global over an entire compilation.
holeUnitId :: UnitId
holeUnitId      = fsToUnitId (fsLit "hole")

isInteractiveModule :: Module -> Bool
isInteractiveModule mod = moduleUnitId mod == interactiveUnitId

isHoleModule :: Module -> Bool
isHoleModule mod = moduleUnitId mod == holeUnitId

wiredInUnitIds :: [UnitId]
wiredInUnitIds = [ primUnitId,
                       integerUnitId,
                       baseUnitId,
                       rtsUnitId,
                       thUnitId,
                       thisGhcUnitId,
                       dphSeqUnitId,
                       dphParUnitId ]

{-
************************************************************************
*                                                                      *
\subsection{@ModuleEnv@s}
*                                                                      *
************************************************************************
-}

-- | A map keyed off of 'Module's
newtype ModuleEnv elt = ModuleEnv (Map Module elt)

filterModuleEnv :: (Module -> a -> Bool) -> ModuleEnv a -> ModuleEnv a
filterModuleEnv f (ModuleEnv e) = ModuleEnv (Map.filterWithKey f e)

elemModuleEnv :: Module -> ModuleEnv a -> Bool
elemModuleEnv m (ModuleEnv e) = Map.member m e

extendModuleEnv :: ModuleEnv a -> Module -> a -> ModuleEnv a
extendModuleEnv (ModuleEnv e) m x = ModuleEnv (Map.insert m x e)

extendModuleEnvWith :: (a -> a -> a) -> ModuleEnv a -> Module -> a -> ModuleEnv a
extendModuleEnvWith f (ModuleEnv e) m x = ModuleEnv (Map.insertWith f m x e)

extendModuleEnvList :: ModuleEnv a -> [(Module, a)] -> ModuleEnv a
extendModuleEnvList (ModuleEnv e) xs = ModuleEnv (Map.insertList xs e)

extendModuleEnvList_C :: (a -> a -> a) -> ModuleEnv a -> [(Module, a)]
                      -> ModuleEnv a
extendModuleEnvList_C f (ModuleEnv e) xs = ModuleEnv (Map.insertListWith f xs e)

plusModuleEnv_C :: (a -> a -> a) -> ModuleEnv a -> ModuleEnv a -> ModuleEnv a
plusModuleEnv_C f (ModuleEnv e1) (ModuleEnv e2) = ModuleEnv (Map.unionWith f e1 e2)

delModuleEnvList :: ModuleEnv a -> [Module] -> ModuleEnv a
delModuleEnvList (ModuleEnv e) ms = ModuleEnv (Map.deleteList ms e)

delModuleEnv :: ModuleEnv a -> Module -> ModuleEnv a
delModuleEnv (ModuleEnv e) m = ModuleEnv (Map.delete m e)

plusModuleEnv :: ModuleEnv a -> ModuleEnv a -> ModuleEnv a
plusModuleEnv (ModuleEnv e1) (ModuleEnv e2) = ModuleEnv (Map.union e1 e2)

lookupModuleEnv :: ModuleEnv a -> Module -> Maybe a
lookupModuleEnv (ModuleEnv e) m = Map.lookup m e

lookupWithDefaultModuleEnv :: ModuleEnv a -> a -> Module -> a
lookupWithDefaultModuleEnv (ModuleEnv e) x m = Map.findWithDefault x m e

mapModuleEnv :: (a -> b) -> ModuleEnv a -> ModuleEnv b
mapModuleEnv f (ModuleEnv e) = ModuleEnv (Map.mapWithKey (\_ v -> f v) e)

mkModuleEnv :: [(Module, a)] -> ModuleEnv a
mkModuleEnv xs = ModuleEnv (Map.fromList xs)

emptyModuleEnv :: ModuleEnv a
emptyModuleEnv = ModuleEnv Map.empty

moduleEnvKeys :: ModuleEnv a -> [Module]
moduleEnvKeys (ModuleEnv e) = Map.keys e

moduleEnvElts :: ModuleEnv a -> [a]
moduleEnvElts (ModuleEnv e) = Map.elems e

moduleEnvToList :: ModuleEnv a -> [(Module, a)]
moduleEnvToList (ModuleEnv e) = Map.toList e

unitModuleEnv :: Module -> a -> ModuleEnv a
unitModuleEnv m x = ModuleEnv (Map.singleton m x)

isEmptyModuleEnv :: ModuleEnv a -> Bool
isEmptyModuleEnv (ModuleEnv e) = Map.null e

foldModuleEnv :: (a -> b -> b) -> b -> ModuleEnv a -> b
foldModuleEnv f x (ModuleEnv e) = Map.foldRightWithKey (\_ v -> f v) x e

-- | A set of 'Module's
type ModuleSet = Map Module ()

mkModuleSet     :: [Module] -> ModuleSet
extendModuleSet :: ModuleSet -> Module -> ModuleSet
emptyModuleSet  :: ModuleSet
moduleSetElts   :: ModuleSet -> [Module]
elemModuleSet   :: Module -> ModuleSet -> Bool

emptyModuleSet    = Map.empty
mkModuleSet ms    = Map.fromList [(m,()) | m <- ms ]
extendModuleSet s m = Map.insert m () s
moduleSetElts     = Map.keys
elemModuleSet     = Map.member

{-
A ModuleName has a Unique, so we can build mappings of these using
UniqFM.
-}

-- | A map keyed off of 'ModuleName's (actually, their 'Unique's)
type ModuleNameEnv elt = UniqFM elt
