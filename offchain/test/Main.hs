module Main where

import qualified E2ESpec
import qualified Groth16Spec
import Test.Hspec

main :: IO ()
main = hspec $ do
    Groth16Spec.spec
    E2ESpec.spec
