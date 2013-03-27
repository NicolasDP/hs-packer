-- |
-- Module      : Data.Packer.IO
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Data.Packer.IO
    ( runPackingIO
    , runUnpackingIO
    ) where

import Data.Packer.Internal
import Data.Packer.Unsafe
import Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as B (ByteString(..), mallocByteString, toForeignPtr)
import Foreign.ForeignPtr

-- | Unpack a bytestring using a monadic unpack action in the IO monad.
runUnpackingIO :: ByteString -> Unpacking a -> IO a
runUnpackingIO bs action = runUnpackingAt fptr o len action
  where (fptr,o,len) = B.toForeignPtr bs

-- | Run packing with a buffer created internally with a monadic action and return the bytestring
runPackingIO :: Int -> Packing () -> IO ByteString
runPackingIO sz action = createUptoN sz $ \ptr -> runPackingAt ptr sz action
    where -- copy of bytestring createUptoN as it's only been added 2012-09
          createUptoN l f = do fp <- B.mallocByteString l
                               l' <- withForeignPtr fp $ \p -> f p
                               return $! B.PS fp 0 l'
