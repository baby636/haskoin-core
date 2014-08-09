{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Server where

import System.Directory 
    ( getAppUserDataDirectory
    , createDirectoryIfMissing
    , doesFileExist
    )

import Control.Monad 
import Control.Monad.Trans 
import Control.Monad.Trans.Resource
import Control.Monad.Logger
import Control.Concurrent.STM.TBMChan
import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Concurrent.Async
import Control.Exception

import Data.Aeson.Types (Value(Null))
import Data.Maybe
import Data.String (fromString)
import Data.Conduit (Sink, awaitForever, ($$), ($=))
import Data.Conduit.Network
import Data.Conduit.TMChan
import qualified Data.Text as T
import qualified Data.Conduit.List as CL

import Database.Persist
import Database.Persist.Sql
import Database.Persist.Sqlite
import Database.Sqlite (open)

import Network.JsonRpc

import Network.Haskoin.Util
import Network.Haskoin.Constants

import Network.Haskoin.Node.PeerManager
import Network.Haskoin.Node.Types

import Network.Haskoin.Wallet.Root
import Network.Haskoin.Wallet.Tx
import Network.Haskoin.Wallet.Account
import Network.Haskoin.Wallet.Address
import Network.Haskoin.Wallet.Model
import Network.Haskoin.Wallet.Types

import Network.Haskoin.Server.Types
import Network.Haskoin.Server.Config

runServer :: IO ()
runServer = do
    dir <- getWorkDir
    let walletFile = T.pack $ concat [dir, "/wallet"]
        configFile = concat [dir, "/config"]

    configExists <- doesFileExist configFile

    unless configExists $ encodeFile configFile defaultServerConfig

    configM <- decodeFile configFile
    unless (isJust configM) $ throwIO $ NodeException $ unwords
        [ "Could node parse config file"
        , configFile
        ]

    let bind    = fromString $ configBind $ fromJust configM
        port    = configPort $ fromJust configM
        hosts   = configHosts $ fromJust configM
        batch   = configBatch $ fromJust configM
        fp      = configFpRate $ fromJust configM
        offline = configOffline $ fromJust configM

    -- Create sqlite connection & initialization
    mvar <- newMVar =<< wrapConnection =<< open walletFile
    runDB mvar $ do
        _ <- runMigrationSilent migrateWallet 
        initWalletDB

    if offline || null hosts
      then
        -- Launch JSON-RPC server
        tcpServer V2 (serverSettings port bind) $ \(src, snk) -> src
            $= CL.mapM (processWalletRequest mvar Nothing fp offline)
            $$ snk
      else
        -- Launch SPV node
        withAsyncNode dir batch $ \eChan rChan _ -> do
        let eventPipe = sourceTBMChan eChan $$ 
                        processNodeEvents mvar rChan fp
        withAsync eventPipe $ \_ -> do
        bloom <- runDB mvar $ walletBloomFilter fp
        atomically $ do
            -- Bloom filter
            writeTBMChan rChan $ BloomFilterUpdate bloom
            -- Bitcoin hosts to connect to
            forM_ hosts $ \(h,p) -> writeTBMChan rChan $ ConnectNode h p

        -- Launch JSON-RPC server
        tcpServer V2 (serverSettings port bind) $ \(src, snk) -> src
            $= CL.mapM (processWalletRequest mvar (Just rChan) fp offline)
            $$ snk

processNodeEvents :: MVar Connection -> TBMChan NodeRequest -> Double
                  -> Sink NodeEvent IO ()
processNodeEvents mvar rChan fp = awaitForever $ \e -> do
    res <- lift $ tryJust f $ runDB mvar $ case e of
        MerkleBlockEvent xs -> void $ importBlocks xs
        TxEvent ts          -> do
            before <- count ([] :: [Filter (DbAddressGeneric b)])
            forM_ ts $ \tx -> importTx tx NetworkSource
            after <- count ([] :: [Filter (DbAddressGeneric b)])
            -- Update the bloom filter if new addresses were generated
            when (after > before) $ do
            bloom <- walletBloomFilter fp
            liftIO $ atomically $ do
            writeTBMChan rChan $ BloomFilterUpdate bloom
                
    when (isLeft res) $ liftIO $ print $ fromLeft res
  where
    -- TODO: What if we have other exceptions than WalletException ?
    f (SomeException e) = Just $ show e

processWalletRequest :: MVar Connection 
                     -> Maybe (TBMChan NodeRequest)
                     -> Double
                     -> Bool
                     -- -> (WalletRequest, Int) 
                     -> IncomingMsg () WalletRequest () ()
                     -- -> IO (Either String WalletResponse, Int)
                     -> IO (Message () () WalletResponse)
processWalletRequest mvar rChanM fp offline inmsg =
    handle f $ runDB mvar $ g inmsg
  where
    rChan = fromJust rChanM

    unlessOffline action
        | offline = liftIO $ throwIO $ WalletException 
            "This operation is not supported in offline mode"
        | otherwise = action

    f (SomeException e) =
        return $ MsgError (ErrorObj V2 (show e) (-32603) Null i)
      where
        i = case inmsg of
            IncomingMsg (MsgRequest rq) Nothing -> (getReqId rq)
            _ -> IdNull

    g (IncomingError e) = return $ MsgError e
    g (IncomingMsg (MsgRequest rq) Nothing) = do
        s <- go (getReqParams rq)
        return $ MsgResponse (Response (getReqVer rq) s (getReqId rq))
    g _ = undefined

    go (NewWallet n p m) = unlessOffline $
        liftM ResMnemonic $ newWalletMnemo n p m
    go (GetWallet n) = unlessOffline $ liftM ResWallet $ getWallet n
    go WalletList = unlessOffline $ liftM ResWalletList $ walletList
    go (NewAccount w n)  = do
        fstKeyBefore <- firstKeyTime
        a <- newAccount w n
        unless offline $ do
            setLookAhead n 30
            bloom      <- walletBloomFilter fp
            fstKeyTime <- liftM fromJust firstKeyTime
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ BloomFilterUpdate bloom
                when (isNothing fstKeyBefore) $
                    writeTBMChan rChan $ FastCatchupTime fstKeyTime
        return $ ResAccount a
    go (NewMSAccount w n r t ks) = do
        fstKeyBefore <- firstKeyTime
        a <- newMSAccount w n r t ks
        unless offline $ when (length (accountKeys a) == t) $ do
            setLookAhead n 30
            bloom      <- walletBloomFilter fp
            fstKeyTime <- liftM fromJust firstKeyTime
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ BloomFilterUpdate bloom
                when (isNothing fstKeyBefore) $
                    writeTBMChan rChan $ FastCatchupTime fstKeyTime
        return $ ResAccount a
    go (NewReadAccount n k) = do
        fstKeyBefore <- firstKeyTime
        a <- newReadAccount n k
        unless offline $ do
            setLookAhead n 30
            bloom      <- walletBloomFilter fp
            fstKeyTime <- liftM fromJust firstKeyTime
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ BloomFilterUpdate bloom
                when (isNothing fstKeyBefore) $
                    writeTBMChan rChan $ FastCatchupTime fstKeyTime
        return $ ResAccount a
    go (NewReadMSAccount n r t ks) = do
        fstKeyBefore <- firstKeyTime
        a <- newReadMSAccount n r t ks
        unless offline $ when (length (accountKeys a) == t) $ do
            setLookAhead n 30
            bloom      <- walletBloomFilter fp
            fstKeyTime <- liftM fromJust firstKeyTime
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ BloomFilterUpdate bloom
                when (isNothing fstKeyBefore) $
                    writeTBMChan rChan $ FastCatchupTime fstKeyTime
        return $ ResAccount a
    go (AddAccountKeys n ks) = do
        fstKeyBefore <- firstKeyTime
        a <- addAccountKeys n ks
        unless offline $ when (length (accountKeys a) == accountTotal a) $ do
            setLookAhead n 30
            bloom      <- walletBloomFilter fp
            fstKeyTime <- liftM fromJust firstKeyTime
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ BloomFilterUpdate bloom
                when (isNothing fstKeyBefore) $
                    writeTBMChan rChan $ FastCatchupTime fstKeyTime
        return $ ResAccount a
    go (GetAccount n)         = liftM ResAccount $ getAccount n
    go AccountList            = liftM ResAccountList $ accountList
    go (GenAddress n i')      = do
        fstKeyBefore <- firstKeyTime
        addrs      <- newAddrs n i'
        bloom      <- walletBloomFilter fp
        unless offline $ do
            fstKeyTime <- liftM fromJust firstKeyTime
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ BloomFilterUpdate bloom
                when (isNothing fstKeyBefore) $
                    writeTBMChan rChan $ FastCatchupTime fstKeyTime
        return $ ResAddressList addrs
    go (AddressLabel n i' l)  = liftM ResAddress $ setAddrLabel n i' l
    go (AddressList n)        = liftM ResAddressList $ addressList n
    go (AddressPage n p a)    = do
        (as, m) <- addressPage n p a
        return $ ResAddressPage as m
    go (TxList n)      = liftM ResAccTxList $ txList n
    go (TxPage n p t)  = do
        (l,m) <- txPage n p t
        return $ ResAccTxPage l m
    go (TxSend n xs s) = unlessOffline $ do
        (tid, complete) <- sendTx n xs s
        when complete $ do
            newTx <- getTx tid
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ PublishTx newTx
        return $ ResTxHashStatus tid complete
    go (TxSign n tx)   = unlessOffline $ do
        (tid, complete) <- signWalletTx n tx 
        when complete $ do
            newTx <- getTx tid
            when (isJust rChanM) $ liftIO $ atomically $ do
                writeTBMChan rChan $ PublishTx newTx
        return $ ResTxHashStatus tid complete
    go (GetSigBlob n tid) = unlessOffline $ do
        blob <- getSigBlob n tid 
        return $ ResSigBlob blob
    go (SignSigBlob n blob) = do
        (tx, c) <- signSigBlob n blob
        return $ ResTxStatus tx c
    go (TxGet h) = do
        tx <- getTx h
        return $ ResTx tx
    go (Balance n)     = liftM ResBalance $ balance n
    go (Rescan (Just t)) = unlessOffline $ do
        when (isJust rChanM) $ liftIO $ atomically $ do
            writeTBMChan rChan $ FastCatchupTime t
        return $ ResRescan t
    go (Rescan Nothing) = unlessOffline $ do
        fstKeyTimeM <- firstKeyTime
        if (isJust fstKeyTimeM)
            then do
                when (isJust rChanM) $ liftIO $ atomically $ do
                    writeTBMChan rChan $ FastCatchupTime $ fromJust fstKeyTimeM
                return $ ResRescan $ fromJust fstKeyTimeM
            else liftIO $ throwIO $ WalletException
                "No keys have been generated in the wallet"

runDB :: MVar Connection -> SqlPersistT (NoLoggingT (ResourceT IO)) a -> IO a
runDB mvar m = withMVar mvar $ \conn -> 
    runResourceT $ runNoLoggingT $ runSqlConn m conn

-- Create and return haskoin working directory
getWorkDir :: IO FilePath
getWorkDir = do
    haskoinDir <- getAppUserDataDirectory "haskoin"
    let dir = concat [ haskoinDir, "/", networkName ]
    createDirectoryIfMissing True dir
    return dir

