{-# LANGUAGE CPP #-}
module RemoveDirectoryRecursive001 where
#include "util.inl"
import System.Directory
import Data.List (sort)
import System.FilePath ((</>), normalise)
import System.IO.Error (catchIOError)
import TestUtils

main :: TestEnv -> IO ()
main _t = do

  ------------------------------------------------------------
  -- clean up junk from previous invocations

  modifyPermissions (tmp "c") (\ p -> p { writable = True })
    `catchIOError` \ _ -> return ()
  removeDirectoryRecursive tmpD
    `catchIOError` \ _ -> return ()

  ------------------------------------------------------------
  -- set up

  createDirectoryIfMissing True (tmp "a/x/w")
  createDirectoryIfMissing True (tmp "a/y")
  createDirectoryIfMissing True (tmp "a/z")
  createDirectoryIfMissing True (tmp "b")
  createDirectoryIfMissing True (tmp "c")
  writeFile (tmp "a/x/w/u") "foo"
  writeFile (tmp "a/t")     "bar"
  tryCreateSymbolicLink (normalise "../a") (tmp "b/g")
  tryCreateSymbolicLink (normalise "../b") (tmp "c/h")
  tryCreateSymbolicLink (normalise "a")    (tmp "d")
  modifyPermissions (tmp "c") (\ p -> p { writable = False })

  ------------------------------------------------------------
  -- tests

  T(expectEq) () [".", "..", "a", "b", "c", "d"] . sort =<<
    getDirectoryContents  tmpD
  T(expectEq) () [".", "..", "t", "x", "y", "z"] . sort =<<
    getDirectoryContents (tmp "a")
  T(expectEq) () [".", "..", "g"] . sort =<<
    getDirectoryContents (tmp "b")
  T(expectEq) () [".", "..", "h"] . sort =<<
    getDirectoryContents (tmp "c")
  T(expectEq) () [".", "..", "t", "x", "y", "z"] . sort =<<
    getDirectoryContents (tmp "d")

  removeDirectoryRecursive (tmp "d")
    `catchIOError` \ _ -> removeFile      (tmp "d")
#ifdef mingw32_HOST_OS
    `catchIOError` \ _ -> removeDirectory (tmp "d")
#endif

  T(expectEq) () [".", "..", "a", "b", "c"] . sort =<<
    getDirectoryContents  tmpD
  T(expectEq) () [".", "..", "t", "x", "y", "z"] . sort =<<
    getDirectoryContents (tmp "a")
  T(expectEq) () [".", "..", "g"] . sort =<<
    getDirectoryContents (tmp "b")
  T(expectEq) () [".", "..", "h"] . sort =<<
    getDirectoryContents (tmp "c")

  removeDirectoryRecursive (tmp "c")
    `catchIOError` \ _ -> do
      modifyPermissions (tmp "c") (\ p -> p { writable = True })
      removeDirectoryRecursive (tmp "c")

  T(expectEq) () [".", "..", "a", "b"] . sort =<<
    getDirectoryContents  tmpD
  T(expectEq) () [".", "..", "t", "x", "y", "z"] . sort =<<
   getDirectoryContents (tmp "a")
  T(expectEq) () [".", "..", "g"] . sort =<<
    getDirectoryContents (tmp "b")

  removeDirectoryRecursive (tmp "b")

  T(expectEq) () [".", "..", "a"] . sort =<<
    getDirectoryContents  tmpD
  T(expectEq) () [".", "..", "t", "x", "y", "z"] . sort =<<
    getDirectoryContents (tmp "a")

  removeDirectoryRecursive (tmp "a")

  T(expectEq) () [".", ".."] . sort =<<
    getDirectoryContents  tmpD

  where testName = "removeDirectoryRecursive001"
        tmpD  = testName ++ ".tmp"
        tmp s = tmpD </> normalise s
