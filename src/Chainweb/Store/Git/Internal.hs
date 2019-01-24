{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Store.Git.Internal
-- Copyright: Copyright © 2018 - 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Gregory Collins <greg@kadena.io>, Colin Woodbury <colin@kadena.io>
-- Stability: experimental
--
-- Internal machineary for "Chainweb.Store.Git".

module Chainweb.Store.Git.Internal
  ( -- * Types
    -- ** Data
    GitStore(..)
  , GitStoreBlockHeader(..)
  , GitStoreData(..)
  , TreeEntry(..)
  , LeafTreeData(..)
  , BlobEntry(..)
  , GitHash(..)
    -- ** Errors
  , GitFailure(..)
    -- ** Utilities
  , NullTerminated
  , terminate

    -- * Queries
  , readLeafTree
  , readHeader
  , readHeader'
  , leaves
  , leaves'
  , allFromHeight
  , lookupByBlockHash
  , lookupTreeEntryByHash
  , readParent

    -- * Traversal
  , walk'

    -- * Insertion
  , InsertResult(..)
  , insertBlock
  , insertBlockHeaderIntoOdb
  , addSelfEntry
  , createBlockHeaderTag
  , tagAsLeaf

    -- * Brackets
  , lockGitStore
  , withOid
  , withObject
  , withTreeBuilder

    -- * Failure
    -- | Convenience functions for handling error codes returned from @libgit2@
    -- functions.
  , throwOnGitError
  , throwGitStoreFailure
  , maybeTGitError

    -- * Utils
  , getSpectrum
  , parseLeafTreeFileName
  , oidToByteString
  , getBlockHashBytes
  , mkTreeEntryNameWith
  , mkTagName
  ) where

import qualified Bindings.Libgit2 as G

import Control.Concurrent.MVar (MVar, withMVar)
import Control.DeepSeq (NFData)
import Control.Error.Util (hoistMaybe, hush, nothing)
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Maybe (MaybeT(..))

import Data.Bits (complement, unsafeShiftL, (.&.))
import Data.ByteArray.Encoding (Base(..), convertFromBase, convertToBase)
import Data.Bytes.Get (runGetS)
import Data.Bytes.Put (runPutS)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.FastBuilder as FB
import qualified Data.ByteString.Unsafe as B
import Data.Char (digitToInt)
import Data.Coerce (coerce)
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.Hashable (Hashable)
import Data.Int (Int64)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Semigroup (Max(..), Min(..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Tuple.Strict (T2(..))
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Algorithms.Intro as V
import Data.Witherable (wither)
import Data.Word (Word64)

import Foreign.C.String (CString)
import Foreign.C.Types (CInt, CSize)
import Foreign.Marshal.Alloc (alloca, free)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)

import GHC.Generics (Generic)


import Streaming (Of, Stream)
import qualified Streaming.Prelude as S

import UnliftIO.Exception (Exception, bracket, bracket_, mask, throwIO)

-- internal modules

import Chainweb.BlockHash (BlockHash(..), BlockHashBytes(..))
import Chainweb.BlockHeader
    (BlockHeader(..), BlockHeight(..), IsBlockHeader(..), decodeBlockHeader,
    encodeBlockHeader)
import Chainweb.TreeDB
    (Eos(..), MaxRank(..), MinRank(..), TreeDb(..), TreeDbEntry(..))
import Chainweb.Utils (int)
import Chainweb.Utils.Paging (Limit(..))

---

--------
-- TYPES
--------

newtype GitStoreBlockHeader = GitStoreBlockHeader BlockHeader
    deriving (Eq, Ord, Show, Generic, Hashable)

instance TreeDbEntry GitStoreBlockHeader where
    type Key GitStoreBlockHeader = T2 BlockHeight BlockHash

    key (GitStoreBlockHeader bh) = T2 (_blockHeight bh) (_blockHash bh)

    rank (GitStoreBlockHeader bh) = int $ _blockHeight bh

    parent e@(GitStoreBlockHeader bh)
        | p == key e = Nothing
        | otherwise = Just p
      where
        p = T2 (_blockHeight bh - 1) (_blockParent bh)

instance IsBlockHeader GitStoreBlockHeader where
    fromBH = coerce
    toBH = coerce

-- | The fundamental git-based storage type. Can be initialized via
-- `Chainweb.Store.Git.withGitStore` and then queried as needed.
--
newtype GitStore = GitStore (MVar GitStoreData)

instance TreeDb GitStore where
    type DbEntry GitStore = GitStoreBlockHeader

    lookup gs (T2 hgt hsh) = coerce $ lookupByBlockHash gs hgt hsh

    -- TODO Handle `next`
    entries gs next limit minr0 maxr = do
        counter <- liftIO $ newIORef 0
        countItems counter . postprocess $ f minr
        total <- liftIO $ readIORef counter
        pure (int total, Eos True)
      where
        minr :: BlockHeight
        minr = maybe 0 (\(MinRank (Min mh)) -> int mh) minr0

        postprocess :: Stream (Of GitStoreBlockHeader) IO () -> Stream (Of GitStoreBlockHeader) IO ()
        postprocess = maybe id filterItems limit . maybe id maxItems maxr

        f :: BlockHeight -> Stream (Of GitStoreBlockHeader) IO ()
        f !bh = do
            bs <- liftIO $ allFromHeight gs bh
            let !len = length bs
            unless (len == 0) $ do
                S.map GitStoreBlockHeader $ S.each bs
                f (bh + 1)

    -- TODO Handle `next`
    leafEntries gs next limit minr maxr = do
        ls <- fmap sort . liftIO $ leaves gs
        counter <- liftIO $ newIORef 0
        countItems counter . postprocess . S.map GitStoreBlockHeader $ S.each ls
        total <- liftIO $ readIORef counter
        pure (int total, Eos True)
      where
        postprocess :: Stream (Of GitStoreBlockHeader) IO () -> Stream (Of GitStoreBlockHeader) IO ()
        postprocess = maybe id filterItems limit . maybe id maxItems maxr . maybe id g minr

        g :: MinRank -> Stream (Of (DbEntry GitStore)) IO () -> Stream (Of (DbEntry GitStore)) IO ()
        g (MinRank (Min n)) =
            S.dropWhile (\(GitStoreBlockHeader bh) -> int (_blockHeight bh) < n)

    insert gs (GitStoreBlockHeader bh) = void $ insertBlock gs bh

filterItems :: Limit -> Stream (Of (DbEntry GitStore)) IO () -> Stream (Of (DbEntry GitStore)) IO ()
filterItems = S.take . int . _getLimit

maxItems :: MaxRank -> Stream (Of GitStoreBlockHeader) IO r -> Stream (Of GitStoreBlockHeader) IO ()
maxItems (MaxRank (Max n)) =
    S.takeWhile (\(GitStoreBlockHeader bh) -> int (_blockHeight bh) <= n)

countItems :: IORef Int -> Stream (Of b) IO r -> Stream (Of b) IO r
countItems counter = S.mapM j
  where
    j i = i <$ atomicModifyIORef' counter (\n -> (n+1, ()))

-- | Many of the functions in this module require this type. The easiest and
-- safest way to get it is via `lockGitStore`. Don't try and manipulate the
-- pointers yourself.
--
data GitStoreData = GitStoreData {
    _gitStore :: {-# UNPACK #-} !(Ptr G.C'git_repository)
  , _gitOdb :: {-# UNPACK #-} !(Ptr G.C'git_odb)
}

-- TODO It's almost certainly possible to give this an instance of `Storable`.
-- Then, the `_ltd_spectrum` field of `LeafTreeData` can become a Storable
-- Vector, from which the rest of the code can benefit.
--
-- See: https://github.com/fosskers/vectortiles/blob/ea1236a84a973e4b0517afeae903986736394a4b/lib/Geography/VectorTile/Geometry.hs#L44-L48
-- | A Haskell-friendly distillation of the `G.C'git_tree_entry` type.
--
data TreeEntry = TreeEntry {
    _te_blockHeight :: {-# UNPACK #-} !BlockHeight
  , _te_blockHash :: {-# UNPACK #-} !BlockHashBytes
  , _te_gitHash :: {-# UNPACK #-} !GitHash
} deriving (Show, Eq, Ord, Generic, NFData)

-- | While `TreeEntry` represents a kind of "pointer" to a stored `BlockHeader`,
-- `LeafTreeData` contains its "spectrum" (points to ancestors in the chain to
-- allow for fast traversal) and a further point to the actual blob data
-- containing the encoded `BlockHeader`.
--
data LeafTreeData = LeafTreeData {
    _ltd_blobEntry :: !BlobEntry
    -- ^ Pointer to the blob data associated with this `TreeEntry`. A
    -- `BlockHeader`.
  , _ltd_spectrum :: Vector TreeEntry
} deriving (Show)

newtype BlobEntry = BlobEntry { _blobEntry :: TreeEntry } deriving (Show)

-- | A reference to a particular git object, corresponding to the type
-- `G.C'git_oid`.
--
newtype GitHash = GitHash ByteString deriving (Eq, Ord, Show, Generic, NFData)

-- | See here for all possible libgit2 errors:
-- https://github.com/libgit2/libgit2/blob/99afd41f1c43c856d39e3b9572d7a2103875a771/include/git2/errors.h#L21
--
data GitFailure = GitFailure {
    gitFailureHFun :: Text  -- ^ The Haskell function the error was thrown from.
  , gitFailureCFun :: Text  -- ^ The C function that originated the error.
  , gitFailureErrorCode :: CInt
} deriving (Show)

instance Exception GitFailure

newtype GitStoreFailure = GitStoreFailure { gitStoreFailureReason :: Text }
  deriving (Show)

instance Exception GitStoreFailure

-- | A `ByteString` whose final byte is a @\\0@. Don't try to be too clever with
-- this.
--
newtype NullTerminated = NullTerminated { _unterminated :: [ByteString] }

nappend :: ByteString -> NullTerminated -> NullTerminated
nappend b (NullTerminated b') = NullTerminated $ b : b'
{-# INLINE nappend #-}

terminate :: NullTerminated -> ByteString
terminate = B.concat . _unterminated
{-# INLINE terminate #-}

----------
-- QUERIES
----------

-- | Follow a (hopefully) established object id (`GitHash`) of a `TreeEntry` to
-- its data, yielding its "spectrum" and a further pointer to its blob data.
--
readLeafTree :: GitStoreData -> GitHash -> IO LeafTreeData
readLeafTree store treeGitHash = withTreeObject store treeGitHash readTree
  where
    readTree :: Ptr G.C'git_tree -> IO LeafTreeData
    readTree pTree = do
        numEntries <- G.c'git_tree_entrycount pTree
        elist <- traverse (readTreeEntry pTree) [0..(numEntries-1)]
        spectrum <- sortSpectrum elist
        when (V.null spectrum) $ throwGitStoreFailure "impossible: empty tree"
        let lastEntry = V.unsafeLast spectrum
        pure $! LeafTreeData (BlobEntry lastEntry) (V.init spectrum)

    readTreeEntry :: Ptr G.C'git_tree -> CSize -> IO TreeEntry
    readTreeEntry pTree idx = G.c'git_tree_entry_byindex pTree idx >>= fromTreeEntryP

    fromTreeEntryP :: Ptr G.C'git_tree_entry -> IO TreeEntry
    fromTreeEntryP entryP = do
        name <- G.c'git_tree_entry_name entryP >>= B.packCString
        oid  <- GitHash <$> (G.c'git_tree_entry_id entryP >>= oidToByteString)
        (h, bh) <- maybe (throwGitStoreFailure "Tree object with incorrect naming scheme!") pure
                         (parseLeafTreeFileName name)
        pure $! TreeEntry h bh oid

    sortSpectrum :: [TreeEntry] -> IO (Vector TreeEntry)
    sortSpectrum l = do
        mv <- V.unsafeThaw (V.fromList l)
        V.sort mv
        V.unsafeFreeze mv

-- TODO Avoid calling the entire `readLeafTree` - use `withTreeObject` and
-- `unsafeReadTree` to fetch the blob hash directly.
-- | Fetch the `BlockHeader` that corresponds to some `TreeEntry`.
--
readHeader :: GitStoreData -> TreeEntry -> IO BlockHeader
readHeader store (TreeEntry _ _ gh) = readLeafTree store gh >>= readHeader' store . _ltd_blobEntry

-- | A short-cut, for when you already have your hands on the inner
-- `BlobEntry`.
--
readHeader' :: GitStoreData -> BlobEntry -> IO BlockHeader
readHeader' store blob = do
    let blobHash = _te_gitHash $ _blobEntry blob
    bs <- getBlob store blobHash
    either (throwGitStoreFailure . T.pack) pure $
        runGetS decodeBlockHeader bs

-- | Fetch the raw byte data of some object in the Git Store.
--
getBlob :: GitStoreData -> GitHash -> IO ByteString
getBlob (GitStoreData repo _) gh = bracket lookupBlob destroy readBlob
  where
    lookupBlob :: IO (Ptr G.C'git_blob)
    lookupBlob = mask $ \restore -> alloca $ \pBlob -> withOid gh $ \oid -> do
        throwOnGitError "getBlob" "git_blob_lookup" $
            restore $ G.c'git_blob_lookup pBlob repo oid
        peek pBlob

    destroy :: Ptr G.C'git_blob -> IO ()
    destroy = G.c'git_blob_free

    readBlob :: Ptr G.C'git_blob -> IO ByteString
    readBlob blob = do
        content <- G.c'git_blob_rawcontent blob
        size <- G.c'git_blob_rawsize blob
        B.packCStringLen (castPtr content, fromIntegral size)

-- | The "leaves" - the tips of all branches.
--
leaves :: GitStore -> IO [BlockHeader]
leaves gs = lockGitStore gs $ \gsd -> leaves' gsd >>= traverse (readHeader gsd)

-- | All leaf nodes in their light "pointer" form.
--
-- If we are pruning properly, there should only ever be a few of these, hence a
-- list is appropriate.
--
leaves' :: GitStoreData -> IO [TreeEntry]
leaves' gsd = matchTags gsd (NullTerminated [ "leaf/*\0" ]) 5

matchTags :: GitStoreData -> NullTerminated -> Int -> IO [TreeEntry]
matchTags (GitStoreData repo _) nt chop =
    B.unsafeUseAsCString (terminate nt)
        $ \patt -> alloca
        $ \namesP -> do
            throwOnGitError "matchTags" "git_tag_list_match" $
                G.c'git_tag_list_match namesP patt repo
            a <- peek namesP
            names <- peekArray (fromIntegral $ G.c'git_strarray'count a) (G.c'git_strarray'strings a)
            wither getEntry names  -- TODO Report malformed tag names instead of ignoring?
 where
   -- TODO Update this example once a proper fixed-length encoding for `BlockHeight` is chosen.
   -- | Expected argument format:
   --
   -- @
   -- leaf/AAAAAAAAAAA=.7C1XaR2bLUAYKsVlAyBUt9eEupaxi8tb4LtOcOP7BB4=
   -- @
   --
   getEntry :: CString -> IO (Maybe TreeEntry)
   getEntry name = do
       name' <- B.packCString name
       let tagName = B.drop chop name'  -- Slice off "leaf/", etc.
           fullTagPath = B.concat [ "refs/tags/", name', "\0" ]
       B.unsafeUseAsCString fullTagPath
           $ \fullTagPath' -> alloca
           $ \oidP -> runMaybeT $ do
               (bh, bs) <- hoistMaybe $ parseLeafTreeFileName tagName
               maybeTGitError $ G.c'git_reference_name_to_id oidP repo fullTagPath'
               hash <- liftIO $ GitHash <$> oidToByteString oidP
               pure $! TreeEntry bh bs hash

lookupByBlockHash :: GitStore -> BlockHeight -> BlockHash -> IO (Maybe BlockHeader)
lookupByBlockHash gs height bh = lockGitStore gs $ \store -> do
    m <- lookupTreeEntryByHash store (getBlockHashBytes bh) (fromIntegral height)
    traverse (readHeader store) m

-- | Shouldn't throw, in theory.
--
lookupTreeEntryByHash
    :: GitStoreData
    -> BlockHashBytes
    -> BlockHeight
    -> IO (Maybe TreeEntry)
lookupTreeEntryByHash gs bh height =
    fmap (TreeEntry height bh) <$> lookupRefTarget gs tagRef
  where
    tagRef :: NullTerminated
    tagRef = mkTagRef height bh

-- | Shouldn't throw, in theory.
--
lookupRefTarget
    :: GitStoreData
    -> NullTerminated      -- ^ ref path, e.g. tags/foo
    -> IO (Maybe GitHash)
lookupRefTarget (GitStoreData repo _) path0 =
    B.unsafeUseAsCString (terminate path)
        $ \cpath -> alloca
        $ \pOid -> runMaybeT $ do
            maybeTGitError $ G.c'git_reference_name_to_id pOid repo cpath
            GitHash <$> liftIO (oidToByteString pOid)
  where
    path :: NullTerminated
    path = nappend "refs/" path0

lookupTreeEntryByHeight
    :: GitStoreData
    -> GitHash         -- ^ starting from this leaf tree
    -> BlockHeight     -- ^ desired blockheight
    -> IO TreeEntry
lookupTreeEntryByHeight gs leafTreeHash height =
    readLeafTree gs leafTreeHash >>=
    lookupTreeEntryByHeight' gs leafTreeHash height

lookupTreeEntryByHeight'
    :: GitStoreData
    -> GitHash
    -> BlockHeight     -- ^ desired blockheight
    -> LeafTreeData
    -> IO TreeEntry
lookupTreeEntryByHeight' gs leafTreeHash height (LeafTreeData (BlobEntry (TreeEntry leafHeight leafBH _)) spectrum)
    | height == leafHeight = pure $! TreeEntry height leafBH leafTreeHash
    | V.null spec' = throwGitStoreFailure "lookup failure"
    | otherwise = search
  where
    spec' :: Vector TreeEntry
    spec' = V.filter (\t -> _te_blockHeight t >= height) spectrum

    search :: IO TreeEntry
    search = do
        let frst = V.unsafeHead spec'
            gh = _te_gitHash frst
        if | _te_blockHeight frst == height -> pure frst
           | otherwise -> lookupTreeEntryByHeight gs gh height

-- | All `BlockHeader` found in @refs\/tags\/bh\/@ at a given height.
--
allFromHeight :: GitStore -> BlockHeight -> IO [BlockHeader]
allFromHeight gs bh = do
    ts <- allFromHeight' gs bh
    lockGitStore gs $ \gsd ->
        traverse (readHeader gsd) ts

-- | All `TreeEntry` found in @refs\/tags\/bh\/@ at a given height.
--
allFromHeight' :: GitStore -> BlockHeight -> IO [TreeEntry]
allFromHeight' gs (BlockHeight bh) = lockGitStore gs $ \gsd -> matchTags gsd bhPath 3
  where
    bhPath :: NullTerminated
    bhPath = NullTerminated [ "bh/", FB.toStrictByteString (FB.word64HexFixed bh), "*\0" ]

readParent :: GitStoreData -> GitHash -> IO TreeEntry
readParent store treeGitHash = withTreeObject store treeGitHash (unsafeReadTree 1)

-- | Given a `G.C'git_tree` that you've hopefully gotten via the
-- `withTreeObject` bracket, read some @git_tree_entry@ marshalled into a usable
-- Haskell type (`TreeEntry`).
--
-- The offset value (the `CSize`) counts from the /end/ of the array of entries!
-- Therefore, an argument of @0@ will return the /last/ entry.
--
-- *NOTE:* It is up to you to pass a legal `CSize` value. For instance, an
-- out-of-bounds value will result in exceptions thrown from within C code,
-- crashing your program.
--
unsafeReadTree :: CSize -> Ptr G.C'git_tree -> IO TreeEntry
unsafeReadTree offset pTree = do
    numEntries <- G.c'git_tree_entrycount pTree
    let !index = numEntries - (offset + 1)
    gte <- G.c'git_tree_entry_byindex pTree index  -- TODO check for NULL here?
    fromTreeEntryP gte
  where
    fromTreeEntryP :: Ptr G.C'git_tree_entry -> IO TreeEntry
    fromTreeEntryP entryP = do
        name <- G.c'git_tree_entry_name entryP >>= B.packCString
        oid  <- GitHash <$> (G.c'git_tree_entry_id entryP >>= oidToByteString)
        (h, bh) <- maybe (throwGitStoreFailure "Tree object with incorrect naming scheme!") pure
                         (parseLeafTreeFileName name)
        pure $! TreeEntry h bh oid

------------
-- TRAVERSAL
------------

-- | Traverse the tree, as in `Chainweb.Store.Git.walk`. This version is faster, as it does not
-- spend time decoding each `TreeEntry` into a `BlockHeader` (unless you tell it
-- to, of course, say via `readHeader'`).
--
-- Internal usage only (since neither `TreeEntry` nor `LeafTreeData` are
-- exposed).
--
walk'
    :: GitStoreData
    -> BlockHeight
    -> BlockHashBytes
    -> (TreeEntry -> IO ())
    -> (BlobEntry -> IO ())
    -> IO ()
walk' gsd !height !hash f g =
    lookupTreeEntryByHash gsd hash height >>= \case
        Nothing -> throwGitStoreFailure $ "Lookup failure for block at given height " <> (bhText height)
        Just te -> do
            f te
            withTreeObject gsd (_te_gitHash te) $ \gt -> do
                blob <- BlobEntry <$> unsafeReadTree 0 gt
                g blob
                unless (height == 0) $ do
                    prnt <- unsafeReadTree 1 gt
                    walk' gsd (_te_blockHeight prnt) (_te_blockHash prnt) f g

------------
-- INSERTION
------------

data InsertResult = Inserted | AlreadyExists deriving (Eq, Show)

insertBlock :: GitStore -> BlockHeader -> IO InsertResult
insertBlock gs bh = lockGitStore gs $ \store -> do
    let hash = getBlockHashBytes $ _blockHash bh
        height = fromIntegral $ _blockHeight bh
    m <- lookupTreeEntryByHash store hash height
    maybe (go store) (const $ pure AlreadyExists) m
  where
    go :: GitStoreData -> IO InsertResult
    go store = createLeafTree store bh $> Inserted

-- | Given a block header: lookup its parent leaf tree entry, write the block
-- header into the object database, compute a spectrum for the new tree entry,
-- write the @git_tree@ to the repository, tag it under @tags/bh/foo@, and
-- returns the git hash of the new @git_tree@ object.
createLeafTree :: GitStoreData -> BlockHeader -> IO GitHash
createLeafTree store@(GitStoreData repo _) bh = withTreeBuilder $ \treeB -> do
    when (height <= 0) $ throwGitStoreFailure "cannot insert genesis block"
    parentTreeEntry <- lookupTreeEntryByHash store parentHash (height - 1) >>=
                       maybe (throwGitStoreFailure "parent hash not found in DB") pure
    let parentTreeGitHash = _te_gitHash parentTreeEntry
    parentTreeData <- readLeafTree store parentTreeGitHash
    treeEntries <- traverse (\h -> lookupTreeEntryByHeight' store parentTreeGitHash h parentTreeData)
                        spectrum
    newHeaderGitHash <- insertBlockHeaderIntoOdb store bh
    traverse_ (addTreeEntry treeB) treeEntries
    addTreeEntry treeB parentTreeEntry
    addSelfEntry treeB height hash newHeaderGitHash
    treeHash <- alloca $ \oid -> do
        throwOnGitError "createLeafTree" "git_treebuilder_write" $
            G.c'git_treebuilder_write oid repo treeB
        GitHash <$> oidToByteString oid
    createBlockHeaderTag store bh treeHash

    updateLeafTags store parentTreeEntry (TreeEntry height hash treeHash)

    -- TODO:
    --   - compute total difficulty weight vs the winning block, and atomic-replace
    --     the winning ref (e.g. @tags/BEST@) if the new block is better
    pure treeHash

  where
    height :: BlockHeight
    height = _blockHeight bh

    hash :: BlockHashBytes
    hash = getBlockHashBytes $ _blockHash bh

    parentHash :: BlockHashBytes
    parentHash = getBlockHashBytes $ _blockParent bh

    spectrum :: [BlockHeight]
    spectrum = getSpectrum height

    addTreeEntry :: Ptr G.C'git_treebuilder -> TreeEntry -> IO ()
    addTreeEntry tb (TreeEntry h hs gh) = tbInsert tb G.c'GIT_FILEMODE_TREE h hs gh

addSelfEntry :: Ptr G.C'git_treebuilder -> BlockHeight -> BlockHashBytes -> GitHash -> IO ()
addSelfEntry tb h hs gh = tbInsert tb G.c'GIT_FILEMODE_BLOB h hs gh

-- | Insert a tree entry into a @git_treebuilder@.
--
tbInsert
    :: Ptr G.C'git_treebuilder
    -> G.C'git_filemode_t
    -> BlockHeight
    -> BlockHashBytes
    -> GitHash
    -> IO ()
tbInsert tb mode h hs gh =
    withOid gh $ \oid ->
    B.unsafeUseAsCString (terminate name) $ \cname ->
    throwOnGitError "tbInsert" "git_treebuilder_insert" $
        G.c'git_treebuilder_insert nullPtr tb cname oid mode
  where
    name :: NullTerminated
    name = mkTreeEntryNameWith "" h hs

insertBlockHeaderIntoOdb :: GitStoreData -> BlockHeader -> IO GitHash
insertBlockHeaderIntoOdb (GitStoreData _ odb) bh =
    B.unsafeUseAsCStringLen serializedBlockHeader write
  where
    !serializedBlockHeader = runPutS $! encodeBlockHeader bh

    write :: (Ptr a, Int) -> IO GitHash
    write (cs, len) = alloca $ \oidPtr -> do
       throwOnGitError "insertBlockHeaderIntoOdb" "git_odb_write" $
           G.c'git_odb_write oidPtr odb (castPtr cs)
                                        (fromIntegral len)
                                        G.c'GIT_OBJ_BLOB
       GitHash <$> oidToByteString oidPtr

-- | Create a tag within @.git/refs/tags/bh/@ that matches the
-- @blockheight.blockhash@ syntax, as say found in a stored `BlockHeader`'s
-- "spectrum".
--
createBlockHeaderTag :: GitStoreData -> BlockHeader -> GitHash -> IO ()
createBlockHeaderTag gs@(GitStoreData repo _) bh leafHash =
    withObject gs leafHash $ \obj ->
    alloca $ \pTagOid ->
    B.unsafeUseAsCString (terminate tagName) $ \cstr ->
    -- @1@ forces libgit to overwrite this tag, should it already exist.
    throwOnGitError "createBlockHeaderTag" "git_tag_create_lightweight" $
        G.c'git_tag_create_lightweight pTagOid repo cstr obj 1
  where
    height :: BlockHeight
    height = _blockHeight bh

    hash :: BlockHashBytes
    hash = getBlockHashBytes $ _blockHash bh

    tagName :: NullTerminated
    tagName = mkTagName height hash

-- | The parent node upon which our new node was written is by definition no
-- longer a leaf, and thus its entry in @.git/refs/leaf/@ must be removed.
--
updateLeafTags :: GitStoreData -> TreeEntry -> TreeEntry -> IO ()
updateLeafTags store@(GitStoreData repo _) oldLeaf newLeaf = do
    tagAsLeaf store newLeaf
    B.unsafeUseAsCString (terminate $ mkName oldLeaf) $ \cstr ->
        throwOnGitError "updateLeafTags" "git_tag_delete" $
            G.c'git_tag_delete repo cstr

-- | Tag a `TreeEntry` in @.git/refs/leaf/@.
--
tagAsLeaf :: GitStoreData -> TreeEntry -> IO ()
tagAsLeaf store@(GitStoreData repo _) leaf =
    withObject store (_te_gitHash leaf) $ \obj ->
        alloca $ \pTagOid ->
        B.unsafeUseAsCString (terminate $ mkName leaf) $ \cstr ->
        throwOnGitError "tagAsLeaf" "git_tag_create_lightweight" $
            G.c'git_tag_create_lightweight pTagOid repo cstr obj 1

mkName :: TreeEntry -> NullTerminated
mkName (TreeEntry h bh _) = mkLeafTagName h bh

mkLeafTagName :: BlockHeight -> BlockHashBytes -> NullTerminated
mkLeafTagName = mkTreeEntryNameWith "leaf/"

-----------
-- BRACKETS
-----------

-- | Prevents other threads from manipulating the Git Store while we perform
-- some given action.
--
lockGitStore :: GitStore -> (GitStoreData -> IO a) -> IO a
lockGitStore (GitStore m) f = withMVar m f

-- | Bracket pattern around a `G.C'git_tree` struct.
--
withTreeObject
    :: GitStoreData
    -> GitHash
    -> (Ptr G.C'git_tree -> IO a)
    -> IO a
withTreeObject (GitStoreData repo _) gitHash f = bracket getTree G.c'git_tree_free f
  where
    getTree :: IO (Ptr G.C'git_tree)
    getTree = mask $ \restore -> alloca $ \ppTree -> withOid gitHash $ \oid -> do
        throwOnGitError "withTreeObject" "git_tree_lookup" $
            restore $ G.c'git_tree_lookup ppTree repo oid
        peek ppTree

withOid :: GitHash -> (Ptr G.C'git_oid -> IO a) -> IO a
withOid (GitHash strOid) f =
    B.unsafeUseAsCStringLen strOid $ \(cstr, clen) -> alloca $ \pOid -> do
        throwOnGitError "withOid" "git_oid_fromstrn" $
            G.c'git_oid_fromstrn pOid cstr (fromIntegral clen)
        f pOid

withObject :: GitStoreData -> GitHash -> (Ptr G.C'git_object -> IO a) -> IO a
withObject (GitStoreData repo _) hash f =
    withOid hash $ \oid ->
    alloca $ \pobj -> do
        throwOnGitError "withObject" "git_object_lookup" $
            G.c'git_object_lookup pobj repo oid G.c'GIT_OBJ_ANY
        peek pobj >>= f

withTreeBuilder :: (Ptr G.C'git_treebuilder -> IO a) -> IO a
withTreeBuilder f =
    alloca $ \pTB -> bracket_ (make pTB)
                              (peek pTB >>= G.c'git_treebuilder_free)
                              (peek pTB >>= f)
  where
    make :: Ptr (Ptr G.C'git_treebuilder) -> IO ()
    make p = throwOnGitError "withTreeBuilder" "git_treebuilder_create" $
        G.c'git_treebuilder_create p nullPtr

----------
-- FAILURE
----------

throwOnGitError :: Text -> Text -> IO CInt -> IO ()
throwOnGitError h c m = do
    code <- m
    when (code /= 0) $ throwGitError h c code

throwGitError :: Text -> Text -> CInt -> IO a
throwGitError h c e = throwIO $ GitFailure h c e

maybeTGitError :: IO CInt -> MaybeT IO ()
maybeTGitError m = do
    code <- liftIO m
    when (code /= 0) nothing

throwGitStoreFailure :: Text -> IO a
throwGitStoreFailure = throwIO . GitStoreFailure

--------
-- UTILS
--------

getSpectrum :: BlockHeight -> [BlockHeight]
getSpectrum (BlockHeight 0) = []
getSpectrum (BlockHeight d0) = map (BlockHeight . fromIntegral) . dedup $ startSpec ++ rlgs ++ recents
  where
    d0' :: Int64
    d0' = fromIntegral d0

    numRecents = 4
    d = max 0 (d0' - numRecents)
    recents = [d .. (max 0 (d0'-2))]       -- don't include d0 or its parent

    pow2s = [ 1 `unsafeShiftL` x | x <- [5..63] ]

    (startSpec, lastSpec) = fs id 0 pow2s
    diff = d - lastSpec

    -- reverse log spectrum should be quantized on the lower bits
    quantize :: Int64 -> Int64
    quantize !x = let !out = (d - x) .&. complement (x-1) in out

    lgs = map quantize $ takeWhile (< diff) pow2s
    rlgs = reverse lgs

    fs :: ([Int64] -> [Int64]) -> Int64 -> [Int64] -> ([Int64], Int64)
    fs !dl !lst (x:zs) | x < d     = fs (dl . (x:)) x zs
                       | otherwise = (dl [], lst)
    fs !dl !lst [] = (dl [], lst)

dedup :: Eq a => [a] -> [a]
dedup [] = []
dedup o@[_] = o
dedup (x:r@(y:_)) | x == y = dedup r
                  | otherwise = x : dedup r

-- TODO Update this example once a proper fixed-length encoding is chosen.
-- | Parse a git-object filename in the shape of:
--
-- @
-- 1023495.5e4fb6e0605385aee583035ae0db732e485715c8d26888d2a3571a26291fb58e
-- ^       ^
-- |       `-- base64-encoded block hash
-- `-- base64-encoded block height
-- @
parseLeafTreeFileName :: ByteString -> Maybe (BlockHeight, BlockHashBytes)
parseLeafTreeFileName fn = do
    height <- decodeHeight heightStr
    -- bh <- BlockHashBytes <$> hush (B64U.decode blockHash0)
    bh <- BlockHashBytes <$> hush (convertFromBase Base64URLUnpadded blockHash0)
    pure (height, bh)
  where
    -- TODO if the `rest` is fixed-length, it would be faster to use `splitAt`.
    (heightStr, rest) = B.break (== '.') fn
    blockHash0 = B.drop 1 rest

    decodeHeight :: ByteString -> Maybe BlockHeight
    decodeHeight = Just . BlockHeight . decodeHex

oidToByteString :: Ptr G.C'git_oid -> IO ByteString
oidToByteString pOid = bracket (G.c'git_oid_allocfmt pOid) free B.packCString

-- | Mysteriously missing from the main API of `BlockHash`.
--
getBlockHashBytes :: BlockHash -> BlockHashBytes
getBlockHashBytes (BlockHash _ bytes) = bytes

bhText :: BlockHeight -> Text
bhText (BlockHeight h) = T.pack $ show h

mkTagRef :: BlockHeight -> BlockHashBytes -> NullTerminated
mkTagRef height hash = nappend "tags/" (mkTagName height hash)

mkTagName :: BlockHeight -> BlockHashBytes -> NullTerminated
mkTagName = mkTreeEntryNameWith "bh/"

-- | Encode a `BlockHeight` and `BlockHashBytes` into the expected format,
-- append some decorator to the front (likely a section of a filepath), and
-- postpend a null-terminator.
--
mkTreeEntryNameWith :: ByteString -> BlockHeight -> BlockHashBytes -> NullTerminated
mkTreeEntryNameWith b (BlockHeight height) (BlockHashBytes hash) =
    NullTerminated [ b, encHeight, ".", encBH, "\0" ]
  where
    encBH :: ByteString
    encBH = convertToBase Base64URLUnpadded hash

    encHeight :: ByteString
    encHeight = FB.toStrictByteString $! FB.word64HexFixed height

decodeHex :: ByteString -> Word64
decodeHex = B.foldl' (\acc c -> (acc * 16) + fromIntegral (digitToInt c)) 0
-- {-# INLINE decodeHex #-}
