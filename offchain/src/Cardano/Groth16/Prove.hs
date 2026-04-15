{-# LANGUAGE OverloadedStrings #-}

-- | Proof generation via snarkjs subprocess.
module Cardano.Groth16.Prove (
    generateProof,
    ProofInput (..),
    ProofOutput (..),
) where

import Cardano.Groth16.Types (SnarkjsProof)
import Data.Aeson (ToJSON (..), eitherDecodeFileStrict, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data ProofInput = ProofInput
    { piD :: Integer
    , piSOld :: Integer
    , piSNew :: Integer
    , piCap :: Integer
    , piROld :: Integer
    , piRNew :: Integer
    }

instance ToJSON ProofInput where
    toJSON i =
        object
            [ "d" .= show (piD i)
            , "S_old" .= show (piSOld i)
            , "S_new" .= show (piSNew i)
            , "C" .= show (piCap i)
            , "r_old" .= show (piROld i)
            , "r_new" .= show (piRNew i)
            ]

data ProofOutput = ProofOutput
    { poProof :: SnarkjsProof
    , poPublicSignals :: [Integer]
    }

{- | Generate a Groth16 proof by calling the snarkjs wrapper script.
The circuitsDir should point to the circuits/ directory containing
generate_proof.js and the build/ artifacts.
-}
generateProof :: FilePath -> ProofInput -> IO (Either String ProofOutput)
generateProof circuitsDir input = do
    let inputFile = circuitsDir <> "/build/input_params.json"
    LBS.writeFile inputFile (Aeson.encode input)
    (exitCode, _stdout, stderr) <-
        readProcessWithExitCode
            "node"
            [circuitsDir <> "/generate_proof.js", inputFile]
            ""
    case exitCode of
        ExitSuccess -> do
            proofE <- eitherDecodeFileStrict (circuitsDir <> "/build/proof.json")
            publicE <- eitherDecodeFileStrict (circuitsDir <> "/build/public.json")
            case (proofE, publicE) of
                (Right proof, Right signals) ->
                    pure (Right (ProofOutput proof (parseSignals signals)))
                (Left e, _) -> pure (Left ("proof parse: " <> e))
                (_, Left e) -> pure (Left ("public parse: " <> e))
        ExitFailure code ->
            pure (Left ("snarkjs failed (exit " <> show code <> "): " <> stderr))
  where
    parseSignals :: [String] -> [Integer]
    parseSignals = map read
