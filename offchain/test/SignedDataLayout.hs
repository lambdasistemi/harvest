{- |
Module      : SignedDataLayout
Description : Canonical byte layout for the customer-signed redeemer payload.

This module is the single Haskell authority for the 106-byte @signed_data@
layout the customer's phone signs with Ed25519. It mirrors exactly what the
Aiken validator parses in @onchain/validators/voucher_spend.ak@ and what the
Node-side signer emits in @circuits/lib/customer_sig.js@.

The canonical layout (all multi-byte integers are big-endian, unsigned,
fixed-width, no padding between fields):

@
Offset  Length  Field
------  ------  ------------
   0      32    txid         (raw 32-byte Cardano transaction id)
  32       2    ix           (u16)
  34      32    acceptor_ax  (256-bit BE integer)
  66      32    acceptor_ay  (256-bit BE integer)
  98       8    d            (u64)
@

Total size: 106 bytes.

Authority: @specs/002-e2e-tests/contracts/signed-data-layout.md@.
-}
module SignedDataLayout (
    -- * Size
    signedDataSize,

    -- * Offsets
    offsetTxid,
    offsetIx,
    offsetAcceptorAx,
    offsetAcceptorAy,
    offsetD,
    lengthTxid,
    lengthIx,
    lengthAcceptorAx,
    lengthAcceptorAy,
    lengthD,

    -- * Parsing
    ParsedSignedData (..),
    parseSignedData,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS

-- | Total size in bytes.
signedDataSize :: Int
signedDataSize = 106

offsetTxid, offsetIx, offsetAcceptorAx, offsetAcceptorAy, offsetD :: Int
offsetTxid = 0
offsetIx = 32
offsetAcceptorAx = 34
offsetAcceptorAy = 66
offsetD = 98

lengthTxid, lengthIx, lengthAcceptorAx, lengthAcceptorAy, lengthD :: Int
lengthTxid = 32
lengthIx = 2
lengthAcceptorAx = 32
lengthAcceptorAy = 32
lengthD = 8

-- | Fields extracted from @signed_data@.
data ParsedSignedData = ParsedSignedData
    { psdTxid :: ByteString
    , psdIx :: Integer
    , psdAcceptorAx :: Integer
    , psdAcceptorAy :: Integer
    , psdD :: Integer
    }
    deriving (Eq, Show)

-- | Parse the canonical byte layout.
-- Fails if the input is not exactly 'signedDataSize' bytes.
parseSignedData :: ByteString -> Either String ParsedSignedData
parseSignedData bs
    | BS.length bs /= signedDataSize =
        Left
            ( "signed_data must be "
                <> show signedDataSize
                <> " bytes, got "
                <> show (BS.length bs)
            )
    | otherwise =
        Right
            ParsedSignedData
                { psdTxid = slice offsetTxid lengthTxid bs
                , psdIx = beInteger (slice offsetIx lengthIx bs)
                , psdAcceptorAx = beInteger (slice offsetAcceptorAx lengthAcceptorAx bs)
                , psdAcceptorAy = beInteger (slice offsetAcceptorAy lengthAcceptorAy bs)
                , psdD = beInteger (slice offsetD lengthD bs)
                }

slice :: Int -> Int -> ByteString -> ByteString
slice off len = BS.take len . BS.drop off

-- | Big-endian unsigned-integer decode. An empty input parses to 0.
beInteger :: ByteString -> Integer
beInteger = BS.foldl' (\acc b -> acc * 256 + fromIntegral b) 0
