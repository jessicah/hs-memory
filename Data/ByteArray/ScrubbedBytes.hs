-- |
-- Module      : Data.ByteArray.ScrubbedBytes
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : Stable
-- Portability : GHC
--
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE CPP #-}
module Data.ByteArray.ScrubbedBytes
    ( ScrubbedBytes
    ) where

import           GHC.Types
import           GHC.Prim
import           GHC.Ptr
import           Data.Monoid
import           Data.Memory.PtrMethods          (memCopy, memConstEqual)
import           Data.Memory.Internal.CompatPrim
import           Data.Memory.Internal.Compat     (unsafeDoIO)
import           Data.Memory.Internal.Imports
import           Data.Memory.Internal.Scrubber   (getScrubber)
import           Data.ByteArray.Types

-- | ScrubbedBytes is a memory chunk which have the properties of:
--
-- * Being scrubbed after its goes out of scope.
--
-- * A Show instance that doesn't actually show any content
--
-- * A Eq instance that is constant time
--
data ScrubbedBytes = ScrubbedBytes (MutableByteArray# RealWorld)

instance Show ScrubbedBytes where
    show _ = "<scrubbed-bytes>"

instance Eq ScrubbedBytes where
    (==) = scrubbedBytesEq
instance Ord ScrubbedBytes where
    compare = scrubbedBytesCompare
instance Monoid ScrubbedBytes where
    mempty        = unsafeDoIO (newScrubbedBytes 0)
    mappend b1 b2 = unsafeDoIO $ scrubbedBytesAppend b1 b2
    mconcat       = unsafeDoIO . scrubbedBytesConcat
instance NFData ScrubbedBytes where
    rnf b = b `seq` ()

instance ByteArrayAccess ScrubbedBytes where
    length        = sizeofScrubbedBytes
    withByteArray = withPtr

instance ByteArray ScrubbedBytes where
    allocRet = scrubbedBytesAllocRet

newScrubbedBytes :: Int -> IO ScrubbedBytes
newScrubbedBytes (I# sz)
    | booleanPrim (sz <# 0#)  = error "ScrubbedBytes: size must be >= 0"
    | booleanPrim (sz ==# 0#) = IO $ \s ->
        case newAlignedPinnedByteArray# 0# 8# s of
            (# s2, mba #) -> (# s2, ScrubbedBytes mba #)
    | otherwise               = IO $ \s ->
        case newAlignedPinnedByteArray# sz 8# s of
            (# s1, mbarr #) ->
                let !scrubber = getScrubber sz
                    !mba      = ScrubbedBytes mbarr
                 in case mkWeak# mbarr () (scrubber (byteArrayContents# (unsafeCoerce# mbarr)) >> touchScrubbedBytes mba) s1 of
                    (# s2, _ #) -> (# s2, mba #)

scrubbedBytesAllocRet :: Int -> (Ptr p -> IO a) -> IO (a, ScrubbedBytes)
scrubbedBytesAllocRet sz f = do
    ba <- newScrubbedBytes sz
    r  <- withPtr ba f
    return (r, ba)

scrubbedBytesAlloc :: Int -> (Ptr p -> IO ()) -> IO ScrubbedBytes
scrubbedBytesAlloc sz f = do
    ba <- newScrubbedBytes sz
    withPtr ba f
    return ba

scrubbedBytesConcat :: [ScrubbedBytes] -> IO ScrubbedBytes
scrubbedBytesConcat l = scrubbedBytesAlloc retLen (copy l)
  where
    retLen = sum $ map sizeofScrubbedBytes l

    copy []     _   = return ()
    copy (x:xs) dst = do
        withPtr x $ \src -> memCopy dst src chunkLen
        copy xs (dst `plusPtr` chunkLen)
      where
        chunkLen = sizeofScrubbedBytes x

scrubbedBytesAppend :: ScrubbedBytes -> ScrubbedBytes -> IO ScrubbedBytes
scrubbedBytesAppend b1 b2 = scrubbedBytesAlloc retLen $ \dst -> do
    withPtr b1 $ \s1 -> memCopy dst                  s1 len1
    withPtr b2 $ \s2 -> memCopy (dst `plusPtr` len1) s2 len2
  where
    len1   = sizeofScrubbedBytes b1
    len2   = sizeofScrubbedBytes b2
    retLen = len1 + len2


sizeofScrubbedBytes :: ScrubbedBytes -> Int
sizeofScrubbedBytes (ScrubbedBytes mba) = I# (sizeofMutableByteArray# mba)

withPtr :: ScrubbedBytes -> (Ptr p -> IO a) -> IO a
withPtr b@(ScrubbedBytes mba) f = do
    a <- f (Ptr (byteArrayContents# (unsafeCoerce# mba)))
    touchScrubbedBytes b
    return a

touchScrubbedBytes :: ScrubbedBytes -> IO ()
touchScrubbedBytes (ScrubbedBytes mba) = IO $ \s -> case touch# mba s of s' -> (# s', () #)

scrubbedBytesEq :: ScrubbedBytes -> ScrubbedBytes -> Bool
scrubbedBytesEq a b
    | l1 /= l2  = False
    | otherwise = unsafeDoIO $ withPtr a $ \p1 -> withPtr b $ \p2 -> memConstEqual p1 p2 l1
  where
        l1 = sizeofScrubbedBytes a
        l2 = sizeofScrubbedBytes b

scrubbedBytesCompare :: ScrubbedBytes -> ScrubbedBytes -> Ordering
scrubbedBytesCompare b1@(ScrubbedBytes m1) b2@(ScrubbedBytes m2) = unsafeDoIO $ IO $ \s -> loop 0# s
  where
    !l1       = sizeofScrubbedBytes b1
    !l2       = sizeofScrubbedBytes b2
    !(I# len) = min l1 l2

    loop i s1
        | booleanPrim (i ==# len) =
            if l1 == l2
                then (# s1, EQ #)
                else if l1 > l2 then (# s1, GT #)
                                else (# s1, LT #)
        | otherwise               =
            case readWord8Array# m1 i s1 of
                (# s2, e1 #) -> case readWord8Array# m2 i s2 of
                    (# s3, e2 #) ->
                        if booleanPrim (eqWord# e1 e2)
                            then loop (i +# 1#) s3
                            else if booleanPrim (ltWord# e1 e2) then (# s3, LT #)
                                                                else (# s3, GT #)
