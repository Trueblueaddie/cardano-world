{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

{-# OPTIONS -fno-warn-orphans #-}

module Test.Dynamic.BFT (
    tests
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.QuickCheck

import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.Demo
import           Ouroboros.Consensus.Ledger.Mock
import           Ouroboros.Consensus.Node
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Util.Random
import           Ouroboros.Network.Chain (Chain)

import           Test.Dynamic.General
import           Test.Dynamic.Util

import           Test.Util.Orphans.Arbitrary ()
import           Test.Util.Range

tests :: TestTree
tests = testGroup "Dynamic chain generation" [
      testProperty "simple BFT convergence" $
        prop_simple_bft_convergence params
    ]
  where
    params = defaultSecurityParam

prop_simple_bft_convergence :: SecurityParam
                            -> NumCoreNodes
                            -> NumSlots
                            -> Seed
                            -> Property
prop_simple_bft_convergence k numCoreNodes =
    prop_simple_protocol_convergence
      (protocolInfo (DemoBFT k) numCoreNodes)
      isValid
      numCoreNodes
  where
    isValid :: [NodeId]
            -> Map NodeId ( NodeConfig DemoBFT
                          , Chain (SimpleBlock DemoBFT SimpleBlockMockCrypto))
            -> Property
    isValid nodeIds final = counterexample (show final') $
          tabulate "shortestLength" [show (rangeK k (shortestLength final'))]
     $    Map.keys final === nodeIds
     .&&. allEqual (takeChainPrefix <$> Map.elems final')
      where
        -- Without the 'NodeConfig's
        final' = snd <$> final
        takeChainPrefix :: Chain (SimpleBlock DemoBFT SimpleBlockMockCrypto)
                        -> Chain (SimpleBlock DemoBFT SimpleBlockMockCrypto)
        takeChainPrefix = id -- in BFT, chains should indeed all be equal.
