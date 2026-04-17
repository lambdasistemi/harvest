{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | Load the voucher spend validator from Aiken blueprint output.
module Harvest.Script (
    loadScript,
    scriptAddr,
) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (
    AlonzoScript,
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
    Plutus (..),
    PlutusBinary (..),
 )
import qualified Data.ByteString.Short as SBS

{- | Load a PlutusV3 script from flat-encoded bytes.

The bytes should be the double-CBOR-encoded compiledCode from
an Aiken blueprint after parameter application via
@aiken blueprint apply@.
-}
loadScript ::
    -- | CBOR-wrapped flat-encoded PlutusV3 script bytes
    SBS.ShortByteString ->
    AlonzoScript ConwayEra
loadScript sbs =
    let plutus = Plutus @PlutusV3 (PlutusBinary sbs)
     in case mkPlutusScript @ConwayEra plutus of
            Just ps -> fromPlutusScript ps
            Nothing -> error "loadScript: invalid PlutusV3 script"

-- | Compute the script address for a given network.
scriptAddr :: Network -> AlonzoScript ConwayEra -> Addr
scriptAddr network script =
    let sh = hashScript @ConwayEra script
     in Addr network (ScriptHashObj sh) StakeRefNull
