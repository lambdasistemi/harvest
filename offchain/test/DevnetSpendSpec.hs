module DevnetSpendSpec (spec) where

import Test.Hspec (Spec, describe, it, pendingWith)

-- | Placeholder; the golden-path acceptance and four negative scenarios
-- land in T020–T033.
spec :: Spec
spec = describe "Devnet spend end-to-end (FR-001, FR-002)" $ do
    it "golden-path accepts" $ pendingWith "T021 pending"
    it "tampered signed_data rejects" $ pendingWith "T030 pending"
    it "d cross-check rejects" $ pendingWith "T031 pending"
    it "pk split mismatch rejects" $ pendingWith "T032 pending"
    it "TxOutRef absent rejects" $ pendingWith "T033 pending"
