module Main where

import qualified Groth16Spec
import Test.Hspec

main :: IO ()
main = hspec $ do
    Groth16Spec.spec
