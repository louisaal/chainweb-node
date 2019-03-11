{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- |
-- Module: Chainweb.CutDB
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.CutDB
(
-- * CutConfig
  CutDbConfig(..)
, cutDbConfigInitialCut
, cutDbConfigInitialCutFile
, cutDbConfigBufferSize
, cutDbConfigLogLevel
, cutDbConfigTelemetryLevel
, defaultCutDbConfig

-- * CutDb
, CutDb
, cutDbWebBlockHeaderDb
, cutDbPayloadCas
, member
, cut
, _cut
, _cutStm
, cutStm
, cutStream
, addCutHashes
, withCutDb
, startCutDb
, stopCutDb

-- * Some CutDb
, CutDbT(..)
, SomeCutDb(..)
, someCutDbVal
) where

import Control.Applicative
import Control.Concurrent.Async
import Control.Concurrent.STM.TVar
import Control.Exception
import Control.Lens hiding ((:>))
import Control.Monad hiding (join)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class
import Control.Monad.STM

import Data.Foldable
import Data.Function
import Data.Functor.Of
import qualified Data.HashMap.Strict as HM
import Data.LogMessage
import Data.Maybe
import Data.Monoid
import Data.Ord
import Data.Reflection hiding (int)
import qualified Data.Text as T

import GHC.Generics hiding (to)

import Numeric.Natural

import Prelude hiding (lookup)

import qualified Streaming.Prelude as S

import System.LogLevel

-- internal modules

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Cut
import Chainweb.Cut.CutHashes
import Chainweb.Graph
import Chainweb.Payload.PayloadStore
import Chainweb.Sync.WebBlockHeaderStore
import Chainweb.TreeDB
import Chainweb.Utils hiding (check)
import Chainweb.Version
import Chainweb.WebBlockHeaderDB

import Data.PQueue
import Data.Singletons

import P2P.TaskQueue

-- -------------------------------------------------------------------------- --
-- Cut DB Configuration

data CutDbConfig = CutDbConfig
    { _cutDbConfigInitialCut :: !Cut
    , _cutDbConfigInitialCutFile :: !(Maybe FilePath)
    , _cutDbConfigBufferSize :: !Natural
    , _cutDbConfigLogLevel :: !LogLevel
    , _cutDbConfigTelemetryLevel :: !LogLevel
    }
    deriving (Show, Eq, Ord, Generic)

makeLenses ''CutDbConfig

defaultCutDbConfig :: ChainwebVersion -> CutDbConfig
defaultCutDbConfig v = CutDbConfig
    { _cutDbConfigInitialCut = genesisCut v
    , _cutDbConfigInitialCutFile = Nothing
    , _cutDbConfigBufferSize = 20
        -- FIXME this should probably depend on the diameter of the graph
        -- It shouldn't be too big.
    , _cutDbConfigLogLevel = Warn
    , _cutDbConfigTelemetryLevel = Warn
    }

-- -------------------------------------------------------------------------- --
-- Cut DB

-- | This is a singleton DB that contains the latest chainweb cut as only
-- entry.
--
data CutDb cas = CutDb
    { _cutDbCut :: !(TVar Cut)
    , _cutDbQueue :: !(PQueue (Down CutHashes))
        -- FIXME: TBQueue is a poor choice in applications that require low
        -- latencies (internally, it uses the classic function queue
        -- implementation with two stacks that has a performance distribution
        -- with a very long tail.)
        --
        -- TODO use a priority queue, that prioritizes heavier cuts and newer
        -- cuts. It should also be non-blocking but instead discard older
        -- entries. We may use the streaming-concurrency package for that.
        --
        -- For now we treat all peers equal. A local miner is just another peer
        -- that provides new cuts.

    , _cutDbAsync :: !(Async ())
    , _cutDbLogFunction :: !LogFunction
    , _cutDbHeaderStore :: !WebBlockHeaderStore
    , _cutDbPayloadStore :: !(WebBlockPayloadStore cas)
    }

instance HasChainGraph (CutDb cas) where
    _chainGraph = _chainGraph . _cutDbHeaderStore
    {-# INLINE _chainGraph #-}

instance HasChainwebVersion (CutDb cas) where
    _chainwebVersion = _chainwebVersion . _cutDbHeaderStore
    {-# INLINE _chainwebVersion #-}

cutDbPayloadCas :: Getter (CutDb cas) (PayloadDb cas)
cutDbPayloadCas = to $ _webBlockPayloadStoreCas . _cutDbPayloadStore

-- We export the 'WebBlockHeaderDb' read-only
--
cutDbWebBlockHeaderDb :: Getter (CutDb cas) WebBlockHeaderDb
cutDbWebBlockHeaderDb = to $ _webBlockHeaderStoreCas . _cutDbHeaderStore

-- | Get the current 'Cut', which represent the latest chainweb state.
--
-- This the main API method of chainweb-consensus.
--
_cut :: CutDb cas -> IO Cut
_cut = readTVarIO . _cutDbCut

-- | Get the current 'Cut', which represent the latest chainweb state.
--
-- This the main API method of chainweb-consensus.
--
cut :: Getter (CutDb cas) (IO Cut)
cut = to _cut

addCutHashes :: CutDb cas -> CutHashes -> IO ()
addCutHashes db = pQueueInsert (_cutDbQueue db) . Down

-- | An 'STM' version of '_cut'.
--
-- @_cut db@ is generally more efficient than as @atomically (_cut db)@.
--
_cutStm :: CutDb cas -> STM Cut
_cutStm = readTVar . _cutDbCut

-- | An 'STM' version of 'cut'.
--
-- @_cut db@ is generally more efficient than as @atomically (_cut db)@.
--
cutStm :: Getter (CutDb cas) (STM Cut)
cutStm = to _cutStm

member :: CutDb cas -> ChainId -> BlockHash -> IO Bool
member db cid h = do
    th <- maxHeader chainDb
    lookup chainDb h >>= \case
        Nothing -> return False
        Just lh -> do
            fh <- forkEntry chainDb th lh
            return $ fh == lh
  where
    chainDb = db ^?! cutDbWebBlockHeaderDb . ixg cid

withCutDb
    :: PayloadCas cas
    => CutDbConfig
    -> LogFunction
    -> WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> (CutDb cas -> IO a)
    -> IO a
withCutDb config logfun headerStore payloadStore
    = bracket (startCutDb config logfun headerStore payloadStore) stopCutDb

startCutDb
    :: PayloadCas cas
    => CutDbConfig
    -> LogFunction
    -> WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> IO (CutDb cas)
startCutDb config logfun headerStore payloadStore = mask_ $ do
    cutVar <- newTVarIO (_cutDbConfigInitialCut config)
    -- queue <- newEmptyPQueue (int $ _cutDbConfigBufferSize config)
    queue <- newEmptyPQueue
    cutAsync <- asyncWithUnmask $ \u -> u $ processor queue cutVar
    logfun @T.Text Info "CutDB started"
    return $ CutDb cutVar queue cutAsync logfun headerStore payloadStore
  where
    processor :: PQueue (Down CutHashes) -> TVar Cut -> IO ()
    processor queue cutVar = do
        processCuts logfun headerStore payloadStore queue cutVar `catches`
            [ Handler $ \(e :: SomeAsyncException) -> throwM e
            , Handler $ \(e :: SomeException) ->
                logfun @T.Text Error $ "CutDB failed: " <> sshow e
            ]
        processor queue cutVar

stopCutDb :: CutDb cas -> IO ()
stopCutDb db = cancel (_cutDbAsync db)

-- | This is at the heart of 'Chainweb' POW: Deciding the current "longest" cut
-- among the incoming candiates.
--
-- Going forward this should probably be the main scheduler for most operations,
-- in particular it should drive (or least preempt) synchronzations of block
-- headers on indiviual chains.
--
processCuts
    :: PayloadCas cas
    => LogFunction
    -> WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> PQueue (Down CutHashes)
    -> TVar Cut
    -> IO ()
processCuts logFun headerStore payloadStore queue cutVar = queueToStream
    & S.filterM (fmap not . isCurrent)
    & S.mapM (cutHashesToBlockHeaderMap headerStore payloadStore)
    & S.concat
        -- ignore left values for now
    & S.scanM
        (\a b -> give (_webBlockHeaderStoreCas headerStore) $ joinIntoHeavier_ (_cutMap a) b)
        (readTVarIO cutVar)
        (\c -> atomically (writeTVar cutVar c) >> logFun @T.Text Debug "write new cut")
    & S.effects
  where
    queueToStream =
        liftIO (pQueueRemove queue) >>= \(Down a) -> S.yield a >> queueToStream

    isCurrent x = do
        curHashes <- fmap _blockHash . _cutMap <$> readTVarIO cutVar
        let r = curHashes == _cutHashes x
        when r $ logFun @T.Text Debug "skip current cut"
        return r

-- | Stream of most recent cuts. This stream does not generally include the full
-- history of cuts. When no cuts are demanded from the stream or new cuts are
-- produced faster than they are consumed from the stream, the stream skips over
-- cuts and always returns the latest cut in the db.
--
cutStream :: MonadIO m => CutDb cas -> S.Stream (Of Cut) m r
cutStream db = liftIO (_cut db) >>= \c -> S.yield c >> go c
  where
    go cur = do
        new <- liftIO $ atomically $ do
            c' <- _cutStm db
            check (c' /= cur)
            return c'
        S.yield new
        go new

cutHashesToBlockHeaderMap
    :: PayloadCas cas
    => WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> CutHashes
    -> IO (Either (HM.HashMap ChainId BlockHash) (HM.HashMap ChainId BlockHeader))
        -- ^ The 'Left' value holds missing hashes, the 'Right' value holds
        -- a 'Cut'.
cutHashesToBlockHeaderMap headerStore payloadStore hs = do
    (headers :> missing) <- S.each (HM.toList $ _cutHashes hs)
        & S.mapM tryGetBlockHeader
        & S.partitionEithers
        & S.fold_ (\x (cid, h) -> HM.insert cid h x) mempty id
        & S.fold (\x (cid, h) -> HM.insert cid h x) mempty id
    if null missing
        then return $ Right headers
        else return $ Left missing
  where
    origin = _cutOrigin hs
    priority = Priority (- int (_cutHashesHeight hs))

    tryGetBlockHeader cv@(cid, _) =
        (Right <$> mapM (getBlockHeader headerStore payloadStore cid priority origin) cv)
            `catch` \case
                (TreeDbKeyNotFound{} :: TreeDbException BlockHeaderDb) ->
                    return $ Left cv
                e -> throwM e

-- -------------------------------------------------------------------------- --
-- Some CutDB

-- | 'CutDb' with type level 'ChainwebVersion'
--
newtype CutDbT cas (v :: ChainwebVersionT) = CutDbT (CutDb cas)
    deriving (Generic)

data SomeCutDb cas = forall v . KnownChainwebVersionSymbol v => SomeCutDb (CutDbT cas v)

someCutDbVal :: ChainwebVersion -> CutDb cas -> SomeCutDb cas
someCutDbVal (FromSing (SChainwebVersion :: Sing v)) db = SomeCutDb $ CutDbT @_ @v db

