{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

-----------------------------------------------------------------------------
-- | This module provides access to internal garbage collection and
-- memory usage statistics.  These statistics are not available unless
-- a program is run with the @-T@ RTS flag.
--
-- This module is GHC-only and should not be considered portable.
--
-- @since 4.5.0.0
-----------------------------------------------------------------------------
module GHC.Stats
    ( GCStats(..)
    , getGCStats
    , getGCStatsEnabled
) where

import Control.Monad
import Data.Int
import GHC.Base
import GHC.Read ( Read )
import GHC.Show ( Show )
import GHC.IO.Exception
import Foreign.Marshal.Alloc
import Foreign.Storable
import Foreign.Ptr

#include "Rts.h"

foreign import ccall "getGCStats"        getGCStats_       :: Ptr () -> IO ()

-- | Returns whether GC stats have been enabled (with @+RTS -T@, for example).
--
-- @since 4.6.0.0
foreign import ccall "getGCStatsEnabled" getGCStatsEnabled :: IO Bool

-- I'm probably violating a bucket of constraints here... oops.

-- | Statistics about memory usage and the garbage collector. Apart from
-- 'currentBytesUsed' and 'currentBytesSlop' all are cumulative values since
-- the program started.
--
-- @since 4.5.0.0
data GCStats = GCStats
    { -- | Total number of bytes allocated
    bytesAllocated :: !Int64
    -- | Number of garbage collections performed (any generation, major and
    -- minor)
    , numGcs :: !Int64
    -- | Maximum number of live bytes seen so far
    , maxBytesUsed :: !Int64
    -- | Number of byte usage samples taken, or equivalently
    -- the number of major GCs performed.
    , numByteUsageSamples :: !Int64
    -- | Sum of all byte usage samples, can be used with
    -- 'numByteUsageSamples' to calculate averages with
    -- arbitrary weighting (if you are sampling this record multiple
    -- times).
    , cumulativeBytesUsed :: !Int64
    -- | Number of bytes copied during GC
    , bytesCopied :: !Int64
    -- | Number of live bytes at the end of the last major GC
    , currentBytesUsed :: !Int64
    -- | Current number of bytes lost to slop
    , currentBytesSlop :: !Int64
    -- | Maximum number of bytes lost to slop at any one time so far
    , maxBytesSlop :: !Int64
    -- | Maximum number of megabytes allocated
    , peakMegabytesAllocated :: !Int64
    -- | CPU time spent running mutator threads.  This does not include
    -- any profiling overhead or initialization.
    , mutatorCpuSeconds :: !Double

    -- | Wall clock time spent running mutator threads.  This does not
    -- include initialization.
    , mutatorWallSeconds :: !Double
    -- | CPU time spent running GC
    , gcCpuSeconds :: !Double
    -- | Wall clock time spent running GC
    , gcWallSeconds :: !Double
    -- | Total CPU time elapsed since program start
    , cpuSeconds :: !Double
    -- | Total wall clock time elapsed since start
    , wallSeconds :: !Double
    -- | Number of bytes copied during GC, minus space held by mutable
    -- lists held by the capabilities.  Can be used with
    -- 'parMaxBytesCopied' to determine how well parallel GC utilized
    -- all cores.
    , parTotBytesCopied :: !Int64

    -- | Sum of number of bytes copied each GC by the most active GC
    -- thread each GC.  The ratio of 'parTotBytesCopied' divided by
    -- 'parMaxBytesCopied' approaches 1 for a maximally sequential
    -- run and approaches the number of threads (set by the RTS flag
    -- @-N@) for a maximally parallel run.
    , parMaxBytesCopied :: !Int64
    } deriving (Show, Read)

    {-
    , initCpuSeconds :: !Double
    , initWallSeconds :: !Double
    -}

-- | Retrieves garbage collection and memory statistics as of the last
-- garbage collection.  If you would like your statistics as recent as
-- possible, first run a 'System.Mem.performGC'.
--
-- @since 4.5.0.0
getGCStats :: IO GCStats
getGCStats = do
  statsEnabled <- getGCStatsEnabled
  unless statsEnabled .  ioError $ IOError
    Nothing
    UnsupportedOperation
    ""
    "getGCStats: GC stats not enabled. Use `+RTS -T -RTS' to enable them."
    Nothing
    Nothing
  allocaBytes (#size GCStats) $ \p -> do
    getGCStats_ p
    bytesAllocated <- (# peek GCStats, bytes_allocated) p
    numGcs <- (# peek GCStats, num_gcs ) p
    numByteUsageSamples <- (# peek GCStats, num_byte_usage_samples ) p
    maxBytesUsed <- (# peek GCStats, max_bytes_used ) p
    cumulativeBytesUsed <- (# peek GCStats, cumulative_bytes_used ) p
    bytesCopied <- (# peek GCStats, bytes_copied ) p
    currentBytesUsed <- (# peek GCStats, current_bytes_used ) p
    currentBytesSlop <- (# peek GCStats, current_bytes_slop) p
    maxBytesSlop <- (# peek GCStats, max_bytes_slop) p
    peakMegabytesAllocated <- (# peek GCStats, peak_megabytes_allocated ) p
    {-
    initCpuSeconds <- (# peek GCStats, init_cpu_seconds) p
    initWallSeconds <- (# peek GCStats, init_wall_seconds) p
    -}
    mutatorCpuSeconds <- (# peek GCStats, mutator_cpu_seconds) p
    mutatorWallSeconds <- (# peek GCStats, mutator_wall_seconds) p
    gcCpuSeconds <- (# peek GCStats, gc_cpu_seconds) p
    gcWallSeconds <- (# peek GCStats, gc_wall_seconds) p
    cpuSeconds <- (# peek GCStats, cpu_seconds) p
    wallSeconds <- (# peek GCStats, wall_seconds) p
    parTotBytesCopied <- (# peek GCStats, par_tot_bytes_copied) p
    parMaxBytesCopied <- (# peek GCStats, par_max_bytes_copied) p
    return GCStats { .. }

{-

-- Nontrivial to implement: TaskStats needs arbitrarily large
-- amounts of memory, spark stats wants to use SparkCounters
-- but that needs a new rts/ header.

data TaskStats = TaskStats
    { taskMutCpuSeconds :: Int64
    , taskMutWallSeconds :: Int64
    , taskGcCpuSeconds :: Int64
    , taskGcWallSeconds :: Int64
    } deriving (Show, Read)

data SparkStats = SparkStats
    { sparksCreated :: Int64
    , sparksDud :: Int64
    , sparksOverflowed :: Int64
    , sparksConverted :: Int64
    , sparksGcd :: Int64
    , sparksFizzled :: Int64
    } deriving (Show, Read)

-- We also could get per-generation stats, which requires a
-- non-constant but at runtime known about of memory.

-}
