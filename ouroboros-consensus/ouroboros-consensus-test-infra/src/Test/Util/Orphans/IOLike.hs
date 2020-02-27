{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test.Util.Orphans.IOLike () where

import           Control.Monad.Class.MonadSTM (lengthTBQueueDefault)
import           Control.Monad.IOSim
import           Ouroboros.Consensus.Util.IOLike
import           Test.Util.Orphans.NoUnexpectedThunks ()

instance MonadSTMTxExtended (SimSTM s) where
  lengthTBQueue = lengthTBQueueDefault

instance IOLike (SimM s)
