{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

module Test.Pos.Infra.Json
       ( tests
       ) where

import           Universum

import           Data.Map
import           Hedgehog (Property)
import qualified Hedgehog as H
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import           Network.Broadcast.OutboundQueue (MaxBucketSize (..))
import           Network.Broadcast.OutboundQueue.Types (NodeType (..))
import           Pos.Infra.Network.DnsDomains (DnsDomains (..), NodeAddr (..))
import           Pos.Infra.Network.Types (NodeName (..))
import           Pos.Infra.Network.Yaml (AllStaticallyKnownPeers (..),
                     NodeMetadata (..), NodeRegion (..), NodeRoutes (..),
                     Topology (..))

import           Test.Pos.Infra.Gen (genAllStaticallyKnownPeers, genDnsDomains,
                     genDomain, genMaxBucketSize, genNodeAddr,
                     genNodeAddrMaybe, genNodeMetadata, genNodeName,
                     genNodeRegion, genNodeRoutes, genNodeType, genTopology)
import           Test.Pos.Util.Golden (discoverGolden, goldenTestJSON)
import           Test.Pos.Util.Tripping (discoverRoundTrip,
                     roundTripsAesonYamlShow)

--------------------------------------------------------------------------------
-- NodeMetaData
--------------------------------------------------------------------------------

golden_NodeMetadata :: Property
golden_NodeMetadata =
    goldenTestJSON exampleNodeMetadata "test/golden/NodeMetadata"

roundTripNodeMetaData :: Property
roundTripNodeMetaData =
    roundTripsAesonYamlShow 1000 genNodeMetadata

--------------------------------------------------------------------------------
-- NodeName
--------------------------------------------------------------------------------

roundTripNodeName :: Property
roundTripNodeName =
    roundTripsAesonYamlShow 1000 genNodeName

--------------------------------------------------------------------------------
-- NodeRegion
--------------------------------------------------------------------------------

roundTripNodeRegion :: Property
roundTripNodeRegion =
    roundTripsAesonYamlShow 1000 genNodeRegion

--------------------------------------------------------------------------------
-- NodeRoutes
--------------------------------------------------------------------------------

roundTripNodeRoutes :: Property
roundTripNodeRoutes =
    roundTripsAesonYamlShow 1000 genNodeRoutes

--------------------------------------------------------------------------------
-- NodeType
--------------------------------------------------------------------------------

roundTripNodeType :: Property
roundTripNodeType =
    roundTripsAesonYamlShow 1000 genNodeType

--------------------------------------------------------------------------------
-- DnsDomains
--------------------------------------------------------------------------------

roundTripDnsDomains :: Property
roundTripDnsDomains =
    roundTripsAesonYamlShow 1000 genDnsDomains

--------------------------------------------------------------------------------
-- Valency
--------------------------------------------------------------------------------

roundTripValency :: Property
roundTripValency =
    roundTripsAesonYamlShow 1000 (Gen.int (Range.constant 1 100))

--------------------------------------------------------------------------------
-- Fallbacks
--------------------------------------------------------------------------------

roundTripFallbacks :: Property
roundTripFallbacks =
    roundTripsAesonYamlShow 1000 (Gen.int (Range.constant 1 100))

--------------------------------------------------------------------------------
-- NodeAddr (Maybe DNS.Domain)
--------------------------------------------------------------------------------

roundTripNodeAddrMaybe :: Property
roundTripNodeAddrMaybe =
    roundTripsAesonYamlShow 1000 genNodeAddrMaybe

--------------------------------------------------------------------------------
-- NodeAddr
--------------------------------------------------------------------------------

roundTripNodeAddr :: Property
roundTripNodeAddr =
    roundTripsAesonYamlShow 1000 (genNodeAddr genDomain)

--------------------------------------------------------------------------------
-- MaxBucketSize
--------------------------------------------------------------------------------

roundTripMaxBucketSize :: Property
roundTripMaxBucketSize =
    roundTripsAesonYamlShow 1000 genMaxBucketSize

--------------------------------------------------------------------------------
-- MaxBucketSize
--------------------------------------------------------------------------------

roundTripAllStaticallyKnownPeers :: Property
roundTripAllStaticallyKnownPeers =
    roundTripsAesonYamlShow 1000 genAllStaticallyKnownPeers

--------------------------------------------------------------------------------
-- Topology
--------------------------------------------------------------------------------

golden_TopologyBehindNAT :: Property
golden_TopologyBehindNAT =
    goldenTestJSON exampleTopologyBehindNAT "test/golden/TopologyBehindNAT"

golden_TopologyStatic :: Property
golden_TopologyStatic =
    goldenTestJSON exampleTopologyStatic "test/golden/TopologyStatic"

golden_TopologyP2P :: Property
golden_TopologyP2P =
    goldenTestJSON exampleTopologyP2P "test/golden/TopologyP2P"

golden_TopologyTraditional :: Property
golden_TopologyTraditional =
    goldenTestJSON exampleTopologyTraditional "test/golden/TopologyTraditional"

roundTripTopology :: Property
roundTripTopology =
    roundTripsAesonYamlShow 1000 genTopology

--------------------------------------------------------------------------------
-- Example golden datatypes
--------------------------------------------------------------------------------

exampleTopologyBehindNAT :: Topology
exampleTopologyBehindNAT =
    TopologyBehindNAT
        42
        50
        $ DnsDomains [[NodeAddrExact "185.255.111.139" (Just 65413)]
                     ,[NodeAddrDNS "QGrCxCYPaqJgFFympdkGamCUQSsTWv" (Just 53415)]
                     ,[NodeAddrDNS "wcrSGCKclFbbZUnTypSGJnvZcOlGTdVgWuAfUiUKFDtK\
                                   \EGfPcQKWSFfZbTbgPAKewXbXaGcqdFSdDYqsbyKQZIBl\
                                   \UcxNqonGMVIEYBiM" (Just 19071)]]

exampleNodeMetadata :: NodeMetadata
exampleNodeMetadata =
    NodeMetadata
        NodeCore
        (NodeRegion "4WM8")
        (NodeRoutes [[NodeName "YBQX"]
                    ,[NodeName "iXAP0JNYwx"]
                    ,[NodeName "c5"]
                    ,[NodeName "9YWMZZMcXA"]
                    ,[NodeName "QCQeWoFE"]
                    ,[NodeName "Mh4N3zyduO"]
                    ,[NodeName "JXSlSLRV"]])
        (DnsDomains [])
        2
        1
        (NodeAddrDNS (Just "BTemPBYBLBxVdLLzugXEdLfNHOICYZEXsmLGUUVnLvVitDZixHVJBX\
                           \eJbAddwugsFhFXSFxxdzJWRkwpySNAlLhrxHsyfQdLmrmkBmGWsiiu\
                           \FMuwpIdDRwdRXK") (Just 6732))
        True
        True
        BucketSizeUnlimited


exampleTopologyP2P :: Topology
exampleTopologyP2P = TopologyP2P 42 50 (BucketSizeMax 100)

exampleTopologyStatic :: Topology
exampleTopologyStatic = TopologyStatic $
    AllStaticallyKnownPeers $
        fromList [(NodeName "m1ZDkWY"
                 , NodeMetadata NodeCore
                                (NodeRegion "4XKfn3F2N")
                                (NodeRoutes [[NodeName "TOORKIKeT"]
                                           ,[NodeName "7fm"]
                                           ,[NodeName "eue2vV1hi"]
                                           ,[NodeName "mFFL"]
                                           ,[NodeName "84v"]
                                           ,[NodeName "8N"]
                                           ,[NodeName "xBD75E"]
                                           ,[NodeName "Yd78Fb"]])
                                (DnsDomains [])
                                1
                                1
                                (NodeAddrDNS
                                    (Just "ekKxWFhuqyvriOtsMUMQfUkhffLkpd")
                                    (Just 16071))
                                True
                                False
                                BucketSizeUnlimited)]

exampleTopologyTraditional :: Topology
exampleTopologyTraditional = TopologyTraditional 42 50 (BucketSizeMax 100)

tests :: IO Bool
tests = (&&) <$> H.checkSequential $$discoverGolden
             <*> H.checkParallel $$discoverRoundTrip
