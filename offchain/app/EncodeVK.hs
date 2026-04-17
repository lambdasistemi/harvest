{- | Read a snarkjs verification_key.json, compress points, output
PlutusData CBOR as hex (for aiken blueprint apply).
-}
module Main (main) where

import Cardano.Groth16.Compress (compressVK)
import Cardano.Groth16.Serialize (vkToData)
import Cardano.Groth16.Types (SnarkjsVK)
import Cardano.PlutusData (encodePlutusData)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
    args <- getArgs
    path <- case args of
        [p] -> pure p
        _ -> die "Usage: encode-vk <verification_key.json>"
    bytes <- LBS.readFile path
    vk <- case Aeson.eitherDecode bytes :: Either String SnarkjsVK of
        Right v -> pure v
        Left e -> die ("Failed to parse VK: " <> e)
    cvk <- compressVK vk
    let pd = vkToData cvk
        cbor = encodePlutusData pd
    BS.putStr (Base16.encode cbor)
    putStrLn ""
