-- | FFI bindings for BLS12-381 point compression via blst.
module Cardano.Groth16.FFI (
    compressG1,
    compressG2,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)

foreign import ccall unsafe "groth16_g1_compress"
    c_g1_compress ::
        Ptr Word8 ->
        CSize ->
        Ptr Word8 ->
        CSize ->
        Ptr Word8 ->
        CSize ->
        IO CInt

foreign import ccall unsafe "groth16_g2_compress"
    c_g2_compress ::
        Ptr Word8 ->
        CSize ->
        Ptr Word8 ->
        CSize ->
        Ptr Word8 ->
        CSize ->
        Ptr Word8 ->
        CSize ->
        Ptr Word8 ->
        CSize ->
        IO CInt

-- | Convert an arbitrary-precision integer to exactly 48 bytes big-endian.
integerToBE48 :: Integer -> ByteString
integerToBE48 n =
    let raw = intToBytes (abs n)
        padded = BS.replicate (48 - BS.length raw) 0 <> raw
     in BS.take 48 padded
  where
    intToBytes :: Integer -> ByteString
    intToBytes 0 = BS.empty
    intToBytes i =
        let (q, r) = i `divMod` 256
         in intToBytes q <> BS.singleton (fromIntegral r)

-- | Compress a G1 affine point (x, y as Integers) to 48 compressed bytes.
compressG1 :: Integer -> Integer -> IO ByteString
compressG1 x y = do
    let xBE = integerToBE48 x
        yBE = integerToBE48 y
    BU.unsafeUseAsCStringLen xBE $ \(xPtr, _) ->
        BU.unsafeUseAsCStringLen yBE $ \(yPtr, _) ->
            allocaBytes 48 $ \outPtr -> do
                rc <-
                    c_g1_compress
                        (castPtr xPtr)
                        48
                        (castPtr yPtr)
                        48
                        outPtr
                        48
                if rc == 0
                    then BS.packCStringLen (castPtr outPtr, 48)
                    else error "groth16_g1_compress failed"

-- | Compress a G2 affine point (x0, x1, y0, y1 as Integers) to 96 compressed bytes.
compressG2 :: Integer -> Integer -> Integer -> Integer -> IO ByteString
compressG2 x0 x1 y0 y1 = do
    let x0BE = integerToBE48 x0
        x1BE = integerToBE48 x1
        y0BE = integerToBE48 y0
        y1BE = integerToBE48 y1
    BU.unsafeUseAsCStringLen x0BE $ \(x0Ptr, _) ->
        BU.unsafeUseAsCStringLen x1BE $ \(x1Ptr, _) ->
            BU.unsafeUseAsCStringLen y0BE $ \(y0Ptr, _) ->
                BU.unsafeUseAsCStringLen y1BE $ \(y1Ptr, _) ->
                    allocaBytes 96 $ \outPtr -> do
                        rc <-
                            c_g2_compress
                                (castPtr x0Ptr)
                                48
                                (castPtr x1Ptr)
                                48
                                (castPtr y0Ptr)
                                48
                                (castPtr y1Ptr)
                                48
                                outPtr
                                96
                        if rc == 0
                            then BS.packCStringLen (castPtr outPtr, 96)
                            else error "groth16_g2_compress failed"
