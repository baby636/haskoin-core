{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}
{-|
Module      : Haskoin.Network.Bloom
Copyright   : No rights reserved
License     : MIT
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Bloom filters are used to reduce data transfer when synchronizing thin cients.
When bloom filters are used a client will obtain filtered blocks that only
contain transactions that pass the bloom filter. Transactions announced via inv
messages also pass the filter.
-}
module Haskoin.Network.Bloom
    ( -- * Bloom Filters
      BloomFlags(..)
    , BloomFilter(..)
    , FilterLoad(..)
    , FilterAdd(..)
    , bloomCreate
    , bloomInsert
    , bloomContains
    , isBloomValid
    , isBloomEmpty
    , isBloomFull
    , acceptsFilters
    , bloomRelevantUpdate
    ) where

import           Control.DeepSeq
import           Control.Monad              (forM_, replicateM)
import           Data.Binary                (Binary (..))
import           Data.Bits
import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as BS
import           Data.Bytes.Get
import           Data.Bytes.Put
import           Data.Bytes.Serial
import qualified Data.Foldable              as F
import           Data.Hash.Murmur           (murmur3)
import           Data.List                  (foldl')
import qualified Data.Sequence              as S
import           Data.Serialize             (Serialize (..))
import           Data.Word
import           GHC.Generics               (Generic)
import           Haskoin.Network.Common
import           Haskoin.Script.Standard
import           Haskoin.Transaction.Common

-- | 20,000 items with fp rate < 0.1% or 10,000 items and <0.0001%
maxBloomSize :: Int
maxBloomSize = 36000

maxHashFuncs :: Word32
maxHashFuncs = 50

ln2Squared :: Double
ln2Squared = 0.4804530139182014246671025263266649717305529515945455

ln2 :: Double
ln2 = 0.6931471805599453094172321214581765680755001343602552

bitMask :: [Word8]
bitMask = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]

-- | The bloom flags are used to tell the remote peer how to auto-update
-- the provided bloom filter.
data BloomFlags
    = BloomUpdateNone -- ^ never update
    | BloomUpdateAll -- ^ auto-update on all outputs
    | BloomUpdateP2PubKeyOnly
    -- ^ auto-update on pay-to-pubkey or pay-to-multisig (default)
    deriving (Eq, Show, Read, Generic, NFData)

instance Serial BloomFlags where
    deserialize = go =<< getWord8
      where
        go 0 = return BloomUpdateNone
        go 1 = return BloomUpdateAll
        go 2 = return BloomUpdateP2PubKeyOnly
        go _ = fail "BloomFlags get: Invalid bloom flag"

    serialize f = putWord8 $ case f of
        BloomUpdateNone         -> 0
        BloomUpdateAll          -> 1
        BloomUpdateP2PubKeyOnly -> 2

instance Binary BloomFlags where
    get = deserialize
    put = serialize

instance Serialize BloomFlags where
    get = deserialize
    put = serialize

-- | A bloom filter is a probabilistic data structure that SPV clients send to
-- other peers to filter the set of transactions received from them. Bloom
-- filters can have false positives but not false negatives. Some transactions
-- that pass the filter may not be relevant to the receiving peer. By
-- controlling the false positive rate, SPV nodes can trade off bandwidth
-- versus privacy.
data BloomFilter = BloomFilter
    { bloomData      :: !(S.Seq Word8)
    -- ^ bloom filter data
    , bloomHashFuncs :: !Word32
    -- ^ number of hash functions for this filter
    , bloomTweak     :: !Word32
    -- ^ hash function random nonce
    , bloomFlags     :: !BloomFlags
    -- ^ bloom filter auto-update flags
    }
    deriving (Eq, Show, Read, Generic, NFData)

instance Serial BloomFilter where

    deserialize =
        BloomFilter
        <$> (S.fromList <$> (readDat =<< deserialize))
        <*> getWord32le
        <*> getWord32le
        <*> deserialize
      where
        readDat (VarInt len) = replicateM (fromIntegral len) getWord8

    serialize (BloomFilter dat hashFuncs tweak flags) = do
        putVarInt $ S.length dat
        forM_ (F.toList dat) putWord8
        putWord32le hashFuncs
        putWord32le tweak
        serialize flags

instance Binary BloomFilter where
    put = serialize
    get = deserialize

instance Serialize BloomFilter where
    put = serialize
    get = deserialize

-- | Set a new bloom filter on the peer connection.
newtype FilterLoad = FilterLoad { filterLoadBloomFilter :: BloomFilter }
    deriving (Eq, Show, Read, Generic, NFData)

instance Serial FilterLoad where
    deserialize = FilterLoad <$> deserialize
    serialize (FilterLoad f) = serialize f

instance Binary FilterLoad where
    put = serialize
    get = deserialize

instance Serialize FilterLoad where
    put = serialize
    get = deserialize

-- | Add the given data element to the connections current filter without
-- requiring a completely new one to be set.
newtype FilterAdd = FilterAdd { getFilterData :: ByteString }
    deriving (Eq, Show, Read, Generic, NFData)

instance Serial FilterAdd where
    deserialize = do
        (VarInt len) <- deserialize
        dat <- getByteString $ fromIntegral len
        return $ FilterAdd dat

    serialize (FilterAdd bs) = do
        putVarInt $ BS.length bs
        putByteString bs

instance Binary FilterAdd where
    put = serialize
    get = deserialize

instance Serialize FilterAdd where
    put = serialize
    get = deserialize


-- | Build a bloom filter that will provide the given false positive rate when
-- the given number of elements have been inserted.
bloomCreate :: Int          -- ^ number of elements
            -> Double       -- ^ false positive rate
            -> Word32       -- ^ random nonce (tweak) for the hash function
            -> BloomFlags   -- ^ bloom filter flags
            -> BloomFilter  -- ^ bloom filter
bloomCreate numElem fpRate =
    BloomFilter (S.replicate bloomSize 0) numHashF
  where
    -- Bloom filter size in bytes
    bloomSize = truncate $ min a b / 8
    -- Suggested size in bits
    a         = -1 / ln2Squared * fromIntegral numElem * log fpRate
    -- Maximum size in bits
    b         = fromIntegral $ maxBloomSize * 8
    numHashF  = truncate $ min c (fromIntegral maxHashFuncs)
    -- Suggested number of hash functions
    c         = fromIntegral bloomSize * 8 / fromIntegral numElem * ln2

bloomHash :: BloomFilter -> Word32 -> ByteString -> Word32
bloomHash bfilter hashNum bs =
    murmur3 seed bs `mod` (fromIntegral (S.length (bloomData bfilter)) * 8)
  where
    seed = hashNum * 0xfba4c795 + bloomTweak bfilter

-- | Insert arbitrary data into a bloom filter. Returns the new bloom filter
-- containing the new data.
bloomInsert :: BloomFilter    -- ^ Original bloom filter
            -> ByteString     -- ^ New data to insert
            -> BloomFilter    -- ^ Bloom filter containing the new data
bloomInsert bfilter bs
    | isBloomFull bfilter = bfilter
    | otherwise = bfilter { bloomData = newData }
  where
    idxs    = map (\i -> bloomHash bfilter i bs) [0..bloomHashFuncs bfilter - 1]
    upd s i = S.adjust (.|. bitMask !! fromIntegral (7 .&. i))
                       (fromIntegral $ i `shiftR` 3) s
    newData = foldl upd (bloomData bfilter) idxs

-- | Tests if some arbitrary data matches the filter. This can be either because
-- the data was inserted into the filter or because it is a false positive.
bloomContains :: BloomFilter    -- ^ Bloom filter
              -> ByteString
              -- ^ Data that will be checked against the given bloom filter
              -> Bool
              -- ^ Returns True if the data matches the filter
bloomContains bfilter bs
    | isBloomFull bfilter  = True
    | isBloomEmpty bfilter = False
    | otherwise            = all isSet idxs
  where
    s       = bloomData bfilter
    idxs    = map (\i -> bloomHash bfilter i bs) [0..bloomHashFuncs bfilter - 1]
    isSet i = S.index s (fromIntegral $ i `shiftR` 3)
          .&. (bitMask !! fromIntegral (7 .&. i)) /= 0

-- | Checks if any of the outputs of a tx is in the current bloom filter.
-- If it is, add the txid and vout as an outpoint (i.e. so that
-- a future tx that spends the output won't be missed).
bloomRelevantUpdate :: BloomFilter
                    -- ^ Bloom filter
                    -> Tx
                    -- ^ Tx that may (or may not) have relevant outputs
                    -> Maybe BloomFilter
                    -- ^ Returns an updated bloom filter adding relevant output
bloomRelevantUpdate bfilter tx
    | isBloomFull bfilter || isBloomEmpty bfilter = Nothing
    | bloomFlags bfilter == BloomUpdateNone = Nothing
    | not (null matchOuts) = Just $ foldl' addRelevant bfilter matchOuts
    | otherwise = Nothing
        -- TxHash if we end up inserting an outpoint
  where
    h = txHash tx
        -- Decode the scriptOutpus and add vOuts in case we make them outpoints
    decodedOutputScripts = traverse (decodeOutputBS . scriptOutput) $ txOut tx
    err = error "Error Decoding output script"
    idxOutputScripts = either (const err) (zip [0 ..]) decodedOutputScripts
        -- Check if any txOuts were contained in the bloom filter
    matchFilter =
        filter (\(_, op) -> bloomContains bfilter $ encodeScriptOut op)
    matchOuts = matchFilter idxOutputScripts
    addRelevant :: BloomFilter -> (Word32, ScriptOutput) -> BloomFilter
    addRelevant bf (id', scriptOut) =
        case (bloomFlags bfilter, scriptType)
            -- We filtered out BloomUpdateNone so we insert any PayPk or PayMulSig
              of
            (_, True) -> bloomInsert bf outpoint
            (BloomUpdateAll, _) -> bloomInsert bf outpoint
            _ -> error "Error Updating Bloom Filter with relevant outpoint"
      where
        outpoint = runPutS $ serialize $ OutPoint {outPointHash = h, outPointIndex = id'}
        scriptType = (\s -> isPayPK s || isPayMulSig s) scriptOut
        -- Encodes a scriptOutput so it can be checked agains the Bloom Filter
    encodeScriptOut :: ScriptOutput -> ByteString
    encodeScriptOut (PayMulSig outputMuSig _) = runPutS $ serialize outputMuSig
    encodeScriptOut (PayWitnessScriptHash scriptHash) = runPutS $ serialize scriptHash
    encodeScriptOut (DataCarrier getOutputDat) = runPutS $ serialize getOutputDat
    encodeScriptOut outputHash = (runPutS . serialize . getOutputHash) outputHash

-- | Returns True if the filter is empty (all bytes set to 0x00)
isBloomEmpty :: BloomFilter -> Bool
isBloomEmpty bfilter = all (== 0x00) $ F.toList $ bloomData bfilter

-- | Returns True if the filter is full (all bytes set to 0xff)
isBloomFull :: BloomFilter -> Bool
isBloomFull bfilter = all (== 0xff) $ F.toList $ bloomData bfilter

-- | Tests if a given bloom filter is valid.
isBloomValid :: BloomFilter -- ^ Bloom filter to test
             -> Bool        -- ^ True if the given filter is valid
isBloomValid bfilter =
    S.length (bloomData bfilter) <= maxBloomSize &&
    bloomHashFuncs bfilter <= maxHashFuncs

-- | Does the peer with these version services accept bloom filters?
acceptsFilters :: Word64 -> Bool
acceptsFilters srv = srv .&. (1 `shiftL` 2) /= 0
