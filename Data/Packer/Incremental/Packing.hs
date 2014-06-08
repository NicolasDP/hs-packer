-- |
-- Module      : Data.Packer.Incremental.Packing
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- Incremental Packing module
--
{-# LANGUAGE CPP #-}
module Data.Packer.Incremental.Packing
    ( PackingIncremental
    , runPackingIncremental
    ) where

import Data.Packer.Family
import Data.Packer.Internal
import Control.Applicative
import Control.Monad.Trans
import Control.Monad (void)

import Foreign.Ptr
import Foreign.ForeignPtr
import Data.Data
import Data.Word
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Internal as L

-- | run packing
runPackingIncremental :: PackingPusher d         -- ^ method to push a chunk packed data
                      -> d
                      -> Int                     -- ^ maximum size of the chunk
                      -> PackingIncremental d () -- ^ packingIncremental
                      -> IO d
runPackingIncremental pusher d size pi = do
    fptr <- B.mallocByteString size
    withForeignPtr fptr $ \ptr -> do
        (_, PackedBuffer _ nFptr, Memory _ mLeft) <- (runPI_ pi) (PackedBuffer size fptr) pusher (Memory ptr size)
        pusher (B.PS nFptr 0 (size - mLeft)) $ do return d

runPackingLazy :: Int -> PackingIncremental L.ByteString () -> L.ByteString
runPackingLazy size pi = unsafeDoIO $ do
        runPackingIncremental accumulator L.empty size pi
    where accumulator :: B.ByteString -> IO (L.ByteString) -> IO (L.ByteString)
          accumulator b f = return $ L.chunk b $ unsafeDoIO f

type PackingPusher a = B.ByteString -> IO a -> IO a

data PackedBuffer = PackedBuffer Int (ForeignPtr Word8)

-- | Incremental packager
data PackingIncremental d a = PackingIncremental
    { runPI_ :: PackedBuffer
             -> PackingPusher d
             -> Memory
             -> IO (a, PackedBuffer, Memory) }

instance Functor (PackingIncremental d) where
    fmap = fmapPackingIncremental

instance Applicative (PackingIncremental d) where
    pure  = returnPackingIncremental
    (<*>) = apPackingIncremental

instance Monad (PackingIncremental d) where
    return = returnPackingIncremental
    (>>=)  = bindPackingIncremental

instance MonadIO (PackingIncremental d) where
    liftIO f = PackingIncremental $ \pb _ st -> f >>= \a -> return (a, pb, st)

fmapPackingIncremental :: (a -> b) -> PackingIncremental d a -> PackingIncremental d b
fmapPackingIncremental f piA = PackingIncremental $ \pb p st ->
    (runPI_ piA) pb p st >>= \(a, npb, nSt) -> return (f a, npb, nSt)
{-# INLINE [0] fmapPackingIncremental #-}

returnPackingIncremental :: a -> PackingIncremental d a
returnPackingIncremental a = PackingIncremental $ \pb _ st -> return (a, pb, st)
{-# INLINE [0] returnPackingIncremental #-}

bindPackingIncremental :: PackingIncremental d a -> (a -> PackingIncremental d b) -> PackingIncremental d b
bindPackingIncremental m1 m2 = PackingIncremental $ \pb p st -> do
    (a, pb2, st2) <- (runPI_ m1) pb p st
    (runPI_ (m2 a)) pb2 p st2
{-# INLINE bindPackingIncremental #-}

apPackingIncremental :: PackingIncremental d (a -> b) -> PackingIncremental d a -> PackingIncremental d b
apPackingIncremental fm m = fm >>= \p -> m >>= \r2 -> return (p r2)
{-# INLINE [0] apPackingIncremental #-}

instance Packing (PackingIncremental d) where
    packCheckAct = packIncrementalCheckAct

packIncrementalCheckAct :: Int -> (Ptr Word8 -> IO a) -> PackingIncremental d a
packIncrementalCheckAct n act = PackingIncremental exPackIncr
    where exPackIncr (PackedBuffer size fPtr) pusher (Memory ptr sz)
              | sz < n = do
                  -- In the case there is not enough size in the buffer we
                  -- create temporary buffer in order to execute the action
                  tFptr <- B.mallocByteString n
                  -- Execute the action with the temporary pointer
                  r <- withForeignPtr tFptr act

                  -- push all the temporary buffer and return the new buffer
                  -- (if any) and the new Memory state
                  withForeignPtr tFptr $ \tptr ->
                      pushAll (PackedBuffer size fPtr) pusher (Memory ptr sz) tptr n r
              | otherwise = do
                  r <- act ptr
                  return (r, PackedBuffer size fPtr, Memory (ptr `plusPtr` n) (n - sz))

          pushAll :: PackedBuffer -> PackingPusher d -> Memory -> Ptr Word8 -> Int -> a -> PackingIncremental d a
          pushAll (PackedBuffer pbSize pbFptr) pusher (Memory ptr mLeft) tmpPtr size r =
              case compare size mLeft of
                  LT -> do B.memcpy ptr tmpPtr size
                           return (r, PackedBuffer pbSize pbFptr, Memory (ptr `plusPtr` size) (mLeft - size))
                  EQ -> do B.memcpy ptr tmpPtr size
                           pusher (B.PS pbFptr 0 pbSize) $ do
                               nFptr <- B.mallocByteString pbSize
                               withForeignPtr nFptr $ \nptr -> return (r, PackedBuffer pbSize nFptr, Memory nptr pbSize)
                  GT -> do B.memcpy ptr tmpPtr mLeft
                           pusher (B.PS pbFptr 0 pbSize) $ do
                               nFptr <- B.mallocByteString pbSize
                               withForeignPtr nFptr $ \nptr ->
                                   pushAll (PackedBuffer pbSize nFptr) pusher (Memory nptr pbSize) tmpPtr (size - mLeft) r
