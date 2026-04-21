module Main where

import qualified DevnetFullFlowSpec
import qualified DevnetRedeemSpec
import qualified DevnetSpendSpec
import qualified E2ESpec
import qualified Ed25519Spec
import qualified Groth16Spec
import qualified SignedDataLayoutSpec
import qualified SpendHarnessSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
    Groth16Spec.spec
    E2ESpec.spec
    SignedDataLayoutSpec.spec
    Ed25519Spec.spec
    SpendHarnessSpec.spec
    DevnetSpendSpec.spec
    DevnetFullFlowSpec.spec
    DevnetRedeemSpec.spec
