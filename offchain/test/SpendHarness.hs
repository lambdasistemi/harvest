{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : SpendHarness
Description : Runtime helpers for the devnet-backed spend test.

Small, focused helpers that the 'DevnetSpendSpec' scenarios share.
Kept separate from the narrative in 'DevnetSpendSpec' so byte-level
plumbing does not get in the way of the documentation-first reading
order.

The only non-trivial helper is 'resignedData': the Node-produced
fixture binds a zero @txid@ placeholder, but a real devnet-submitted
tx consumes a real 'OutputReference' chosen by the harness at test
time. 'resignedData' rewrites the @(txid, ix)@ prefix of
@signed_data@ and re-signs the result with the customer's Ed25519
key, using primitives re-exported from
"Cardano.Node.Client.E2E.Setup" (cardano-node-clients PRs #65, #66,
and the raw-serialise follow-up).
-}
module SpendHarness (
    -- * Re-signing
    resignedData,
    replaceTxOutRef,

    -- * Serialisation helpers (exported for tests)
    u16BigEndian,
) where

import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SigDSIGN,
    SignKeyDSIGN,
    rawDeserialiseSignKeyDSIGN,
    rawSerialiseSigDSIGN,
    signDSIGN,
 )
import qualified Data.ByteString as BS
import Data.Word (Word16, Word8)

import SignedDataLayout (
    lengthIx,
    lengthTxid,
    offsetIx,
    signedDataSize,
 )

{- | Replace the @(txid, ix)@ prefix of a @signed_data@ blob with fresh
values and re-sign the result with the customer's Ed25519 key.

Returns @(signed_data', signature')@. The remaining fields
(@acceptor_ax@, @acceptor_ay@, @d@) are preserved bit-for-bit, so the
proof's public-input binding of 'd' and the validator's reificator-trie
check on 'acceptor_pk' both remain consistent with the untouched
fixture.

Returns 'Nothing' if @sk_c@ is the wrong length (should always be 32
bytes).
-}
resignedData ::
    -- | sk_c (32-byte Ed25519 seed, from customer.json)
    BS.ByteString ->
    -- | original signed_data from the fixture
    BS.ByteString ->
    -- | new txid (32 bytes)
    BS.ByteString ->
    -- | new ix
    Word16 ->
    -- | @(signed_data', signature')@
    Maybe (BS.ByteString, BS.ByteString)
resignedData skcBytes original txid ix = do
    sk :: SignKeyDSIGN Ed25519DSIGN <- rawDeserialiseSignKeyDSIGN skcBytes
    let signedData' = replaceTxOutRef original txid ix
        sig :: SigDSIGN Ed25519DSIGN
        sig = signDSIGN () signedData' sk
    pure (signedData', rawSerialiseSigDSIGN sig)

{- | Rewrite the @(txid, ix)@ prefix of a @signed_data@ blob without
touching the signature. Used for negative tests that want to corrupt
the signed payload (e.g. flip a byte) while proving the validator
notices.
-}
replaceTxOutRef ::
    -- | original signed_data
    BS.ByteString ->
    -- | new txid (must be 32 bytes)
    BS.ByteString ->
    -- | new ix
    Word16 ->
    BS.ByteString
replaceTxOutRef original txid ix
    | BS.length original /= signedDataSize =
        error "replaceTxOutRef: signed_data wrong size"
    | BS.length txid /= lengthTxid =
        error "replaceTxOutRef: txid wrong size"
    | otherwise =
        let ixBytes = u16BigEndian ix
            -- Everything after the ix slot stays untouched.
            rest = BS.drop (offsetIx + lengthIx) original
         in BS.concat [txid, ixBytes, rest]

-- | Big-endian u16 as a 2-byte 'BS.ByteString'.
u16BigEndian :: Word16 -> BS.ByteString
u16BigEndian n =
    BS.pack
        [ fromIntegral ((n `div` 256) `mod` 256) :: Word8
        , fromIntegral (n `mod` 256) :: Word8
        ]
