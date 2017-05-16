{-# LANGUAGE CPP, FlexibleInstances, UnboxedTuples, MagicHash #-}
{-# OPTIONS_GHC -fno-cse -fno-warn-orphans #-}
-- -fno-cse is needed for GLOBAL_VAR's to behave properly

-----------------------------------------------------------------------------
--
-- Monadery code used in InteractiveUI
--
-- (c) The GHC Team 2005-2006
--
-----------------------------------------------------------------------------

module GHCi.UI.Monad (
        GHCi(..), startGHCi,
        GHCiState(..), setGHCiState, getGHCiState, modifyGHCiState,
        GHCiOption(..), isOptionSet, setOption, unsetOption,
        Command(..),
        BreakLocation(..),
        TickArray,
        getDynFlags,

        runStmt, runDecls, resume, timeIt, recordBreak, revertCAFs,

        printForUserNeverQualify, printForUserModInfo,
        printForUser, printForUserPartWay, prettyLocations,
        initInterpBuffering,
        turnOffBuffering, turnOffBuffering_,
        flushInterpBuffers,
        mkEvalWrapper
    ) where

#include "HsVersions.h"

import GHCi.UI.Info (ModInfo)
import qualified GHC
import GhcMonad         hiding (liftIO)
import Outputable       hiding (printForUser, printForUserPartWay)
import qualified Outputable
import DynFlags
import FastString
import HscTypes
import SrcLoc
import Module
import GHCi
import GHCi.RemoteTypes

import Exception
import Numeric
import Data.Array
import Data.IORef
import System.CPUTime
import System.Environment
import System.IO
import Control.Monad

import System.Console.Haskeline (CompletionFunc, InputT)
import qualified System.Console.Haskeline as Haskeline
import Control.Monad.Trans.Class
import Control.Monad.IO.Class
import Data.Map.Strict (Map)

-----------------------------------------------------------------------------
-- GHCi monad

data GHCiState = GHCiState
     {
        progname       :: String,
        args           :: [String],
        evalWrapper    :: ForeignHValue, -- ^ of type @IO a -> IO a@
        prompt         :: String,
        prompt2        :: String,
        editor         :: String,
        stop           :: String,
        options        :: [GHCiOption],
        line_number    :: !Int,         -- ^ input line
        break_ctr      :: !Int,
        breaks         :: ![(Int, BreakLocation)],
        tickarrays     :: ModuleEnv TickArray,
            -- ^ 'tickarrays' caches the 'TickArray' for loaded modules,
            -- so that we don't rebuild it each time the user sets
            -- a breakpoint.
        ghci_commands  :: [Command],
            -- ^ available ghci commands
        ghci_macros    :: [Command],
            -- ^ user-defined macros
        last_command   :: Maybe Command,
            -- ^ @:@ at the GHCi prompt repeats the last command, so we
            -- remember it here
        cmdqueue       :: [String],

        remembered_ctx :: [InteractiveImport],
            -- ^ The imports that the user has asked for, via import
            -- declarations and :module commands.  This list is
            -- persistent over :reloads (but any imports for modules
            -- that are not loaded are temporarily ignored).  After a
            -- :load, all the home-package imports are stripped from
            -- this list.
            --
            -- See bugs #2049, #1873, #1360

        transient_ctx  :: [InteractiveImport],
            -- ^ An import added automatically after a :load, usually of
            -- the most recently compiled module.  May be empty if
            -- there are no modules loaded.  This list is replaced by
            -- :load, :reload, and :add.  In between it may be modified
            -- by :module.

        ghc_e :: Bool, -- ^ True if this is 'ghc -e' (or runghc)

        short_help :: String,
            -- ^ help text to display to a user
        long_help  :: String,
        lastErrorLocations :: IORef [(FastString, Int)],

        mod_infos  :: !(Map ModuleName ModInfo),

        flushStdHandles :: ForeignHValue,
            -- ^ @hFlush stdout; hFlush stderr@ in the interpreter
        noBuffering :: ForeignHValue
            -- ^ @hSetBuffering NoBuffering@ for stdin/stdout/stderr
     }

type TickArray = Array Int [(GHC.BreakIndex,RealSrcSpan)]

-- | A GHCi command
data Command
   = Command
   { cmdName           :: String
     -- ^ Name of GHCi command (e.g. "exit")
   , cmdAction         :: String -> InputT GHCi Bool
     -- ^ The 'Bool' value denotes whether to exit GHCi
   , cmdHidden         :: Bool
     -- ^ Commands which are excluded from default completion
     -- and @:help@ summary. This is usually set for commands not
     -- useful for interactive use but rather for IDEs.
   , cmdCompletionFunc :: CompletionFunc GHCi
     -- ^ 'CompletionFunc' for arguments
   }

data GHCiOption
        = ShowTiming            -- show time/allocs after evaluation
        | ShowType              -- show the type of expressions
        | RevertCAFs            -- revert CAFs after every evaluation
        | Multiline             -- use multiline commands
        | CollectInfo           -- collect and cache information about
                                -- modules after load
        deriving Eq

data BreakLocation
   = BreakLocation
   { breakModule :: !GHC.Module
   , breakLoc    :: !SrcSpan
   , breakTick   :: {-# UNPACK #-} !Int
   , onBreakCmd  :: String
   }

instance Eq BreakLocation where
  loc1 == loc2 = breakModule loc1 == breakModule loc2 &&
                 breakTick loc1   == breakTick loc2

prettyLocations :: [(Int, BreakLocation)] -> SDoc
prettyLocations []   = text "No active breakpoints."
prettyLocations locs = vcat $ map (\(i, loc) -> brackets (int i) <+> ppr loc) $ reverse $ locs

instance Outputable BreakLocation where
   ppr loc = (ppr $ breakModule loc) <+> ppr (breakLoc loc) <+>
                if null (onBreakCmd loc)
                   then Outputable.empty
                   else doubleQuotes (text (onBreakCmd loc))

recordBreak :: BreakLocation -> GHCi (Bool{- was already present -}, Int)
recordBreak brkLoc = do
   st <- getGHCiState
   let oldActiveBreaks = breaks st
   -- don't store the same break point twice
   case [ nm | (nm, loc) <- oldActiveBreaks, loc == brkLoc ] of
     (nm:_) -> return (True, nm)
     [] -> do
      let oldCounter = break_ctr st
          newCounter = oldCounter + 1
      setGHCiState $ st { break_ctr = newCounter,
                          breaks = (oldCounter, brkLoc) : oldActiveBreaks
                        }
      return (False, oldCounter)

newtype GHCi a = GHCi { unGHCi :: IORef GHCiState -> Ghc a }

reflectGHCi :: (Session, IORef GHCiState) -> GHCi a -> IO a
reflectGHCi (s, gs) m = unGhc (unGHCi m gs) s

reifyGHCi :: ((Session, IORef GHCiState) -> IO a) -> GHCi a
reifyGHCi f = GHCi f'
  where
    -- f' :: IORef GHCiState -> Ghc a
    f' gs = reifyGhc (f'' gs)
    -- f'' :: IORef GHCiState -> Session -> IO a
    f'' gs s = f (s, gs)

startGHCi :: GHCi a -> GHCiState -> Ghc a
startGHCi g state = do ref <- liftIO $ newIORef state; unGHCi g ref

instance Functor GHCi where
    fmap = liftM

instance Applicative GHCi where
    pure a = GHCi $ \_ -> pure a
    (<*>) = ap

instance Monad GHCi where
  (GHCi m) >>= k  =  GHCi $ \s -> m s >>= \a -> unGHCi (k a) s

class HasGhciState m where
    getGHCiState    :: m GHCiState
    setGHCiState    :: GHCiState -> m ()
    modifyGHCiState :: (GHCiState -> GHCiState) -> m ()

instance HasGhciState GHCi where
    getGHCiState      = GHCi $ \r -> liftIO $ readIORef r
    setGHCiState s    = GHCi $ \r -> liftIO $ writeIORef r s
    modifyGHCiState f = GHCi $ \r -> liftIO $ modifyIORef r f

instance (MonadTrans t, Monad m, HasGhciState m) => HasGhciState (t m) where
    getGHCiState    = lift getGHCiState
    setGHCiState    = lift . setGHCiState
    modifyGHCiState = lift . modifyGHCiState

liftGhc :: Ghc a -> GHCi a
liftGhc m = GHCi $ \_ -> m

instance MonadIO GHCi where
  liftIO = liftGhc . liftIO

instance HasDynFlags GHCi where
  getDynFlags = getSessionDynFlags

instance GhcMonad GHCi where
  setSession s' = liftGhc $ setSession s'
  getSession    = liftGhc $ getSession

instance HasDynFlags (InputT GHCi) where
  getDynFlags = lift getDynFlags

instance GhcMonad (InputT GHCi) where
  setSession = lift . setSession
  getSession = lift getSession

instance ExceptionMonad GHCi where
  gcatch m h = GHCi $ \r -> unGHCi m r `gcatch` (\e -> unGHCi (h e) r)
  gmask f =
      GHCi $ \s -> gmask $ \io_restore ->
                             let
                                g_restore (GHCi m) = GHCi $ \s' -> io_restore (m s')
                             in
                                unGHCi (f g_restore) s

instance Haskeline.MonadException Ghc where
  controlIO f = Ghc $ \s -> Haskeline.controlIO $ \(Haskeline.RunIO run) -> let
                    run' = Haskeline.RunIO (fmap (Ghc . const) . run . flip unGhc s)
                    in fmap (flip unGhc s) $ f run'

instance Haskeline.MonadException GHCi where
  controlIO f = GHCi $ \s -> Haskeline.controlIO $ \(Haskeline.RunIO run) -> let
                    run' = Haskeline.RunIO (fmap (GHCi . const) . run . flip unGHCi s)
                    in fmap (flip unGHCi s) $ f run'

instance ExceptionMonad (InputT GHCi) where
  gcatch = Haskeline.catch
  gmask f = Haskeline.liftIOOp gmask (f . Haskeline.liftIOOp_)

isOptionSet :: GHCiOption -> GHCi Bool
isOptionSet opt
 = do st <- getGHCiState
      return (opt `elem` options st)

setOption :: GHCiOption -> GHCi ()
setOption opt
 = do st <- getGHCiState
      setGHCiState (st{ options = opt : filter (/= opt) (options st) })

unsetOption :: GHCiOption -> GHCi ()
unsetOption opt
 = do st <- getGHCiState
      setGHCiState (st{ options = filter (/= opt) (options st) })

printForUserNeverQualify :: GhcMonad m => SDoc -> m ()
printForUserNeverQualify doc = do
  dflags <- getDynFlags
  liftIO $ Outputable.printForUser dflags stdout neverQualify doc

printForUserModInfo :: GhcMonad m => GHC.ModuleInfo -> SDoc -> m ()
printForUserModInfo info doc = do
  dflags <- getDynFlags
  mUnqual <- GHC.mkPrintUnqualifiedForModule info
  unqual <- maybe GHC.getPrintUnqual return mUnqual
  liftIO $ Outputable.printForUser dflags stdout unqual doc

printForUser :: GhcMonad m => SDoc -> m ()
printForUser doc = do
  unqual <- GHC.getPrintUnqual
  dflags <- getDynFlags
  liftIO $ Outputable.printForUser dflags stdout unqual doc

printForUserPartWay :: SDoc -> GHCi ()
printForUserPartWay doc = do
  unqual <- GHC.getPrintUnqual
  dflags <- getDynFlags
  liftIO $ Outputable.printForUserPartWay dflags stdout (pprUserLength dflags) unqual doc

-- | Run a single Haskell expression
runStmt :: String -> GHC.SingleStep -> GHCi (Maybe GHC.ExecResult)
runStmt expr step = do
  st <- getGHCiState
  GHC.handleSourceError (\e -> do GHC.printException e; return Nothing) $ do
    let opts = GHC.execOptions
                  { GHC.execSourceFile = progname st
                  , GHC.execLineNumber = line_number st
                  , GHC.execSingleStep = step
                  , GHC.execWrap = \fhv -> EvalApp (EvalThis (evalWrapper st))
                                                   (EvalThis fhv) }
    Just <$> GHC.execStmt expr opts

runDecls :: String -> GHCi (Maybe [GHC.Name])
runDecls decls = do
  st <- getGHCiState
  reifyGHCi $ \x ->
    withProgName (progname st) $
    withArgs (args st) $
      reflectGHCi x $ do
        GHC.handleSourceError (\e -> do GHC.printException e;
                                        return Nothing) $ do
          r <- GHC.runDeclsWithLocation (progname st) (line_number st) decls
          return (Just r)

resume :: (SrcSpan -> Bool) -> GHC.SingleStep -> GHCi GHC.ExecResult
resume canLogSpan step = do
  st <- getGHCiState
  reifyGHCi $ \x ->
    withProgName (progname st) $
    withArgs (args st) $
      reflectGHCi x $ do
        GHC.resumeExec canLogSpan step

-- --------------------------------------------------------------------------
-- timing & statistics

timeIt :: (a -> Maybe Integer) -> InputT GHCi a -> InputT GHCi a
timeIt getAllocs action
  = do b <- lift $ isOptionSet ShowTiming
       if not b
          then action
          else do time1   <- liftIO $ getCPUTime
                  a <- action
                  let allocs = getAllocs a
                  time2   <- liftIO $ getCPUTime
                  dflags  <- getDynFlags
                  liftIO $ printTimes dflags allocs (time2 - time1)
                  return a

printTimes :: DynFlags -> Maybe Integer -> Integer -> IO ()
printTimes dflags mallocs psecs
   = do let secs = (fromIntegral psecs / (10^(12::Integer))) :: Float
            secs_str = showFFloat (Just 2) secs
        putStrLn (showSDoc dflags (
                 parens (text (secs_str "") <+> text "secs" <> comma <+>
                         case mallocs of
                           Nothing -> empty
                           Just allocs ->
                             text (separateThousands allocs) <+> text "bytes")))
  where
    separateThousands n = reverse . sep . reverse . show $ n
      where sep n'
              | length n' <= 3 = n'
              | otherwise = take 3 n' ++ "," ++ sep (drop 3 n')

-----------------------------------------------------------------------------
-- reverting CAFs

revertCAFs :: GHCi ()
revertCAFs = do
  liftIO rts_revertCAFs
  s <- getGHCiState
  when (not (ghc_e s)) turnOffBuffering
     -- Have to turn off buffering again, because we just
     -- reverted stdout, stderr & stdin to their defaults.

foreign import ccall "revertCAFs" rts_revertCAFs  :: IO ()
        -- Make it "safe", just in case

-----------------------------------------------------------------------------
-- To flush buffers for the *interpreted* computation we need
-- to refer to *its* stdout/stderr handles

-- | Compile "hFlush stdout; hFlush stderr" once, so we can use it repeatedly
initInterpBuffering :: Ghc (ForeignHValue, ForeignHValue)
initInterpBuffering = do
  nobuf <- GHC.compileExprRemote $
   "do { System.IO.hSetBuffering System.IO.stdin System.IO.NoBuffering; " ++
       " System.IO.hSetBuffering System.IO.stdout System.IO.NoBuffering; " ++
       " System.IO.hSetBuffering System.IO.stderr System.IO.NoBuffering }"
  flush <- GHC.compileExprRemote $
   "do { System.IO.hFlush System.IO.stdout; " ++
       " System.IO.hFlush System.IO.stderr }"
  return (nobuf, flush)

-- | Invoke "hFlush stdout; hFlush stderr" in the interpreter
flushInterpBuffers :: GHCi ()
flushInterpBuffers = do
  st <- getGHCiState
  hsc_env <- GHC.getSession
  liftIO $ evalIO hsc_env (flushStdHandles st)

-- | Turn off buffering for stdin, stdout, and stderr in the interpreter
turnOffBuffering :: GHCi ()
turnOffBuffering = do
  st <- getGHCiState
  turnOffBuffering_ (noBuffering st)

turnOffBuffering_ :: GhcMonad m => ForeignHValue -> m ()
turnOffBuffering_ fhv = do
  hsc_env <- getSession
  liftIO $ evalIO hsc_env fhv

mkEvalWrapper :: GhcMonad m => String -> [String] ->  m ForeignHValue
mkEvalWrapper progname args =
  GHC.compileExprRemote $
    "\\m -> System.Environment.withProgName " ++ show progname ++
    "(System.Environment.withArgs " ++ show args ++ " m)"
