{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StandaloneDeriving         #-}

-- For Show Errno and Condense SeekMode instances
{-# OPTIONS_GHC -Wno-orphans #-}
module Ouroboros.Storage.FS.API.Types (
    -- * Modes
    OpenMode(..)
  , AllowExisting(..)
  , allowExisting
  , SeekMode(..)
    -- * Paths
  , FsPath -- opaque
  , fsPathToList
  , fsPathFromList
  , fsPathSplit
  , fsPathInit
  , mkFsPath
  , MountPoint(..)
  , fsToFilePath
  , fsFromFilePath
    -- * Handles
  , Handle(..)
    -- * Offset
  , AbsOffset(..)
    -- * Errors
  , FsError(..)
  , FsErrorType(..)
  , sameFsError
  , isFsErrorType
  , prettyFsError
    -- * From 'IOError' to 'FsError'
  , ioToFsError
  , ioToFsErrorType
  ) where

import           Control.DeepSeq (force)
import           Control.Exception
import           Data.Function (on)
import           Data.List (intercalate, stripPrefix)
import qualified Data.Text as Strict
import           Data.Word
import           Foreign.C.Error (Errno (..))
import qualified Foreign.C.Error as C
import           GHC.Generics (Generic)
import qualified GHC.IO.Exception as GHC
import           GHC.Stack
import           System.FilePath
import           System.IO (SeekMode (..))
import qualified System.IO.Error as IO

import           Cardano.Prelude (NoUnexpectedThunks (..), UseIsNormalForm (..),
                     UseIsNormalFormNamed (..))

import           Ouroboros.Consensus.Util.Condense

{-------------------------------------------------------------------------------
  Modes
-------------------------------------------------------------------------------}

-- | How to 'hOpen' a new file.
data OpenMode
  = ReadMode
  | WriteMode     AllowExisting
  | AppendMode    AllowExisting
  | ReadWriteMode AllowExisting
  deriving (Eq, Show)

-- | When 'hOpen'ing a file:
data AllowExisting
  = AllowExisting
    -- ^ The file may already exist. If it does, it is reopened. If it
    -- doesn't, it is created.
  | MustBeNew
    -- ^ The file may not yet exist. If it does, an error
    -- ('FsResourceAlreadyExist') is thrown.
  deriving (Eq, Show)

allowExisting :: OpenMode -> AllowExisting
allowExisting openMode = case openMode of
  ReadMode         -> AllowExisting
  WriteMode     ex -> ex
  AppendMode    ex -> ex
  ReadWriteMode ex -> ex

{-------------------------------------------------------------------------------
  Paths
-------------------------------------------------------------------------------}

newtype FsPath = UnsafeFsPath { fsPathToList :: [Strict.Text] }
  deriving (Eq, Ord, Generic)
  deriving NoUnexpectedThunks via UseIsNormalForm FsPath

fsPathFromList :: [Strict.Text] -> FsPath
fsPathFromList = UnsafeFsPath . force

instance Show FsPath where
  show = intercalate "/" . map Strict.unpack . fsPathToList

instance Condense FsPath where
  condense = show

-- | Constructor for 'FsPath' ensures path is in normal form
mkFsPath :: [String] -> FsPath
mkFsPath = fsPathFromList . map Strict.pack

-- | Split 'FsPath' is essentially @(init fp, last fp)@
--
-- Like @init@ and @last@, 'Nothing' if empty.
fsPathSplit :: FsPath -> Maybe (FsPath, Strict.Text)
fsPathSplit fp =
    case reverse (fsPathToList fp) of
      []   -> Nothing
      p:ps -> Just (fsPathFromList (reverse ps), p)

-- | Drop the final component of the path
--
-- Undefined if the path is empty.
fsPathInit :: HasCallStack => FsPath -> FsPath
fsPathInit fp = case fsPathSplit fp of
                  Nothing       -> error $ "fsPathInit: empty path"
                  Just (fp', _) -> fp'

-- | Mount point
--
-- 'FsPath's are not absolute paths, but must be interpreted with respect to
-- a particualar mount point.
newtype MountPoint = MountPoint FilePath

fsToFilePath :: MountPoint -> FsPath -> FilePath
fsToFilePath (MountPoint mp) fp =
    mp </> foldr (</>) "" (map Strict.unpack $ fsPathToList fp)

fsFromFilePath :: MountPoint -> FilePath -> Maybe FsPath
fsFromFilePath (MountPoint mp) path = mkFsPath <$>
    stripPrefix (splitDirectories mp) (splitDirectories path)

{-------------------------------------------------------------------------------
  Handles
-------------------------------------------------------------------------------}

data Handle h = Handle {
      -- | The raw underlying handle
      handleRaw  :: !h

      -- | The path corresponding to this handle
      --
      -- This is primarily useful for error reporting.
    , handlePath :: !FsPath
    }
  deriving (Generic)
  deriving NoUnexpectedThunks via UseIsNormalFormNamed "Handle" (Handle h)

instance Eq h => Eq (Handle h) where
  (==) = (==) `on` handleRaw

instance Show (Handle h) where
  show (Handle _ fp) = "<Handle " ++ fsToFilePath (MountPoint "<root>") fp ++ ">"


{-------------------------------------------------------------------------------
  Offset wrappers
-------------------------------------------------------------------------------}

newtype AbsOffset = AbsOffset { unAbsOffset :: Word64 }
  deriving (Eq, Ord, Enum, Bounded, Num, Show)

{-------------------------------------------------------------------------------
  Errors
-------------------------------------------------------------------------------}

data FsError = FsError {
      -- | Error type
      fsErrorType   :: FsErrorType

      -- | Path to the file
    , fsErrorPath   :: FsPath

      -- | Human-readable string giving additional information about the error
    , fsErrorString :: String

      -- | The 'Errno', if available. This is more precise than the
      -- 'FsErrorType'.
    , fsErrorNo     :: Maybe Errno

      -- | Call stack
    , fsErrorStack  :: CallStack

      -- | Is this error due to a limitation of the mock file system?
      --
      -- The mock file system does not all of Posix's features and quirks.
      -- This flag will be set for such unsupported IO calls. Real I/O calls
      -- would not have thrown an error for these calls.
    , fsLimitation  :: Bool
    }
  deriving Show

deriving instance Show Errno

data FsErrorType
  = FsIllegalOperation
  | FsResourceInappropriateType
  -- ^ e.g the user tried to open a directory with hOpen rather than a file.
  | FsResourceAlreadyInUse
  | FsResourceDoesNotExist
  | FsResourceAlreadyExist
  | FsReachedEOF
  | FsDeviceFull
  | FsTooManyOpenFiles
  | FsInsufficientPermissions
  | FsInvalidArgument
  | FsOther
    -- ^ Used for all other error types
  deriving (Show, Eq)

instance Exception FsError where
    displayException = prettyFsError

-- | Check if two errors are semantically the same error
--
-- This ignores the error string, the errno, and the callstack.
sameFsError :: FsError -> FsError -> Bool
sameFsError e e' = fsErrorType e == fsErrorType e'
                && fsErrorPath e == fsErrorPath e'

isFsErrorType :: FsErrorType -> FsError -> Bool
isFsErrorType ty e = fsErrorType e == ty

prettyFsError :: FsError -> String
prettyFsError FsError{..} = concat [
      show fsErrorType
    , " for "
    , show fsErrorPath
    , ": "
    , fsErrorString
    , " at "
    , prettyCallStack fsErrorStack
    ]

{-------------------------------------------------------------------------------
  From 'IOError' to 'FsError'
-------------------------------------------------------------------------------}

-- | Translate exceptions thrown by IO functions to 'FsError'
--
-- We take the 'FsPath' as an argument. We could try to translate back from a
-- 'FilePath' to an 'FsPath' (given a 'MountPoint'), but we know the 'FsPath'
-- at all times anyway and not all IO exceptions actually include a filepath.
ioToFsError :: HasCallStack
            => FsPath -> IOError -> FsError
ioToFsError fp ioErr = FsError
    { fsErrorType   = ioToFsErrorType ioErr
    , fsErrorPath   = fp
    , fsErrorString = IO.ioeGetErrorString ioErr
    , fsErrorNo     = Errno <$> GHC.ioe_errno ioErr
    , fsErrorStack  = callStack
    , fsLimitation  = False
    }

-- | Assign an 'FsErrorType' to the given 'IOError'.
--
-- Note that we don't always use the classification made by
-- 'Foreign.C.Error.errnoToIOError' (also see 'System.IO.Error') because it
-- combines some errors into one 'IOErrorType', e.g., @EMFILE@ (too many open
-- files) and @ENOSPC@ (no space left on device) both result in
-- 'ResourceExhausted' while we want to keep them separate. For this reason,
-- we do a classification of our own based on the @errno@ while sometimes
-- deferring to the existing classification.
--
-- See the ERRNO(3) man page for the meaning of the different errnos.
ioToFsErrorType :: IOError -> FsErrorType
ioToFsErrorType ioErr = case Errno <$> GHC.ioe_errno ioErr of
    Just errno
      |  errno == C.eACCES
      || errno == C.eROFS
      || errno == C.ePERM
      -> FsInsufficientPermissions

      |  errno == C.eNOSPC
      -> FsDeviceFull

      |  errno == C.eMFILE
      || errno == C.eNFILE
      -> FsTooManyOpenFiles

      |  errno == C.eNOENT
      || errno == C.eNXIO
      -> FsResourceDoesNotExist

    _ | IO.isAlreadyInUseErrorType eType
      -> FsResourceAlreadyInUse

      | IO.isAlreadyExistsErrorType eType
      -> FsResourceAlreadyExist

      | IO.isEOFErrorType eType
      -> FsReachedEOF

      | IO.isIllegalOperationErrorType eType
      -> FsIllegalOperation

      | eType == GHC.InappropriateType
      -> FsResourceInappropriateType

      | eType == GHC.InvalidArgument
      -> FsInvalidArgument

      | otherwise
      -> FsOther
  where
    eType :: IO.IOErrorType
    eType = IO.ioeGetErrorType ioErr

{-------------------------------------------------------------------------------
  Condense instances
-------------------------------------------------------------------------------}

instance Condense SeekMode where
  condense RelativeSeek = "r"
  condense AbsoluteSeek = "a"
  condense SeekFromEnd  = "e"

instance Condense AllowExisting where
  condense AllowExisting = ""
  condense MustBeNew     = "!"

instance Condense OpenMode where
    condense ReadMode           = "r"
    condense (WriteMode     ex) = "w"  ++ condense ex
    condense (ReadWriteMode ex) = "rw" ++ condense ex
    condense (AppendMode    ex) = "a"  ++ condense ex

instance Condense (Handle h) where
  condense = show
