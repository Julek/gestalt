{-# LANGUAGE MagicHash #-}

import GHC.Exts hiding (fromList)
import Unsafe.Coerce
import Data.Map.Strict

newtype Age = Age Int

fooAge :: Map Int Int -> Map Int Age
fooAge = fmap Age
fooCoerce :: Map Int Int -> Map Int Age
fooCoerce = fmap coerce
fooUnsafeCoerce :: Map Int Int -> Map Int Age
fooUnsafeCoerce = fmap unsafeCoerce

same :: a -> b -> IO ()
same x y = case reallyUnsafePtrEquality# (unsafeCoerce x) y of
    1# -> putStrLn "yes"
    _  -> putStrLn "no"

main = do
    let l = fromList [(1,1),(2,2),(3,3)]
    same (fooAge l) l
    same (fooCoerce l) l
    same (fooUnsafeCoerce l) l
