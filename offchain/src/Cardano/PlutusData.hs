{-# LANGUAGE LambdaCase #-}

-- | PlutusData CBOR encoding/decoding, matching Aiken's on-chain format.
module Cardano.PlutusData (
    PlutusData (..),
    encodePlutusData,
    decodePlutusData,
) where

import Codec.CBOR.Decoding (
    Decoder,
    TokenType (
        TypeBytes,
        TypeInteger,
        TypeListLen,
        TypeListLen64,
        TypeMapLen,
        TypeMapLen64,
        TypeNInt,
        TypeNInt64,
        TypeTag,
        TypeUInt,
        TypeUInt64
    ),
    decodeBytes,
    decodeInteger,
    decodeListLen,
    decodeMapLen,
    decodeTag,
    peekTokenType,
 )
import Codec.CBOR.Encoding (
    Encoding,
    encodeBytes,
    encodeInteger,
    encodeListLen,
    encodeMapLen,
    encodeTag,
 )
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Write (toStrictByteString)
import Control.Monad (replicateM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS

data PlutusData
    = Constr Integer [PlutusData]
    | Map [(PlutusData, PlutusData)]
    | List [PlutusData]
    | Integer Integer
    | Bytes ByteString
    deriving (Eq, Show)

encodePlutusData :: PlutusData -> ByteString
encodePlutusData = toStrictByteString . encodeData

decodePlutusData :: ByteString -> Either String PlutusData
decodePlutusData bytes = do
    (_, value) <- firstShow $ deserialiseFromBytes decodeData (LBS.fromStrict bytes)
    pure value

encodeData :: PlutusData -> Encoding
encodeData = \case
    Constr tag fields ->
        encodeConstr tag <> encodeList fields
    Map entries ->
        encodeMapLen (fromIntegral (length entries))
            <> foldMap (\(k, v) -> encodeData k <> encodeData v) entries
    List values ->
        encodeList values
    Integer n ->
        encodeInteger n
    Bytes bytes ->
        encodeBytes bytes

encodeList :: [PlutusData] -> Encoding
encodeList values =
    encodeListLen (fromIntegral (length values))
        <> foldMap encodeData values

encodeConstr :: Integer -> Encoding
encodeConstr tag
    | 0 <= tag && tag <= 6 = encodeTag (121 + fromIntegral tag)
    | 7 <= tag && tag <= 127 = encodeTag (1280 + fromIntegral (tag - 7))
    | otherwise = encodeTag 102 <> encodeListLen 2 <> encodeInteger tag

decodeData :: Decoder s PlutusData
decodeData =
    peekTokenType >>= \case
        TypeTag -> decodeTagOrBigInt
        TypeMapLen -> decodeMap
        TypeMapLen64 -> decodeMap
        TypeListLen -> decodeList
        TypeListLen64 -> decodeList
        TypeBytes -> Bytes <$> decodeBytes
        TypeUInt -> Integer <$> decodeInteger
        TypeUInt64 -> Integer <$> decodeInteger
        TypeNInt -> Integer <$> decodeInteger
        TypeNInt64 -> Integer <$> decodeInteger
        TypeInteger -> Integer <$> decodeInteger
        other -> fail ("unsupported CBOR token for plutus data: " <> show other)

decodeTagOrBigInt :: Decoder s PlutusData
decodeTagOrBigInt = do
    tag <- decodeTag
    case tag of
        2 -> Integer . bytesToPosInteger <$> decodeBytes
        3 -> Integer . (\n -> -1 - n) . bytesToPosInteger <$> decodeBytes
        _ -> decodeConstrWithTag tag

bytesToPosInteger :: ByteString -> Integer
bytesToPosInteger = BS.foldl' (\acc b -> acc * 256 + fromIntegral b) 0

decodeConstrWithTag :: Word -> Decoder s PlutusData
decodeConstrWithTag tag =
    case tag of
        n
            | 121 <= n && n <= 127 ->
                Constr (fromIntegral (n - 121)) <$> decodeListPayload
        n
            | 1280 <= n && n <= 1400 ->
                Constr (fromIntegral (n - 1280 + 7)) <$> decodeListPayload
        102 -> do
            len <- decodeListLen
            if len /= 2
                then fail "constructor tag 102 must be followed by a 2-element list"
                else do
                    ix <- decodeInteger
                    fields <-
                        decodeData >>= \case
                            List xs -> pure xs
                            _ -> fail "constructor tag 102 payload must contain a list of fields"
                    pure $ Constr ix fields
        _ -> fail ("unsupported constructor tag: " <> show tag)

decodeMap :: Decoder s PlutusData
decodeMap = do
    len <- decodeMapLen
    entries <- replicateM len ((,) <$> decodeData <*> decodeData)
    pure $ Map entries

decodeList :: Decoder s PlutusData
decodeList = List <$> decodeListPayload

decodeListPayload :: Decoder s [PlutusData]
decodeListPayload = do
    len <- decodeListLen
    replicateM len decodeData

firstShow :: (Show a) => Either a b -> Either String b
firstShow = either (Left . show) Right
