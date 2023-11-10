{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}
module Kuber.Server.Core where

import qualified Data.Text as T
import qualified Data.Aeson as A
import Data.Text.Lazy.Encoding    as TL
import qualified Data.Text.Lazy             as TL
import Cardano.Api
import Control.Exception (throw, try)
import qualified Data.Set as Set
import System.Exit (die)
import Cardano.Kuber.Api
import Cardano.Kuber.Util
import System.Environment (getEnv)
import System.FilePath (joinPath)
import Cardano.Ledger.Alonzo.Scripts (ExUnits(ExUnits))
import Data.Text.Conversions (Base16(Base16), convertText)
import Cardano.Api.Shelley (TxBody(ShelleyTxBody), fromShelleyTxIn, LedgerProtocolParameters)
import qualified Cardano.Ledger.TxIn as Ledger
import qualified Cardano.Ledger.Core as Ledger
import Cardano.Ledger.Alonzo.TxBody (inputs')
import qualified Data.Map as Map
import Data.Text (Text)
import Cardano.Kuber.Data.Models
import qualified Data.ByteString.Char8 as BS8
import Data.Functor ((<&>))
import Cardano.Kuber.Data.Parsers (parseTxIn, parseAddressBech32, parseAddressBech32)
import qualified Debug.Trace as Debug
import Data.Word (Word64)
import qualified Data.Aeson.Key as A
import Data.Time.Clock.POSIX ( POSIXTime, getPOSIXTime )
import Data.Aeson ((.:), ToJSON (toJSON))
import Kuber.Server.Model
import Control.Monad.IO.Class (liftIO)
import qualified Data.Aeson.Encoding as A


makeHandler a  kontract = liftIO $ evaluateKontract a kontract  >>= (\case
   Left fe -> throw fe
   Right pp -> pure pp)

makeHandler1 a  f p1 = makeHandler a (f p1)
makeHandler2 a  f p1 p2= makeHandler a (f p1 p2)



calculateMinFeeHandler :: (HasKuberAPI api) => TxModal -> Kontract api w FrameworkError Lovelace
calculateMinFeeHandler (TxModal (InAnyCardanoEra cera tx))  = case cera of
  BabbageEra -> kCalculateMinFee tx
  ConwayEra -> kCalculateMinFee tx
  _ -> kError FeatureNotSupported ("calculateMinFee: only BabbageEra and ConwayEra supported got : " ++ show cera )


calculateExUnitsHandler :: (HasKuberAPI api) => TxModal -> Kontract api w FrameworkError ExUnitsResponseModal
calculateExUnitsHandler (TxModal (InAnyCardanoEra cera tx))  = case cera of
  BabbageEra -> kEvaluateExUnits tx <&> ExUnitsResponseModal
  ConwayEra -> kEvaluateExUnits tx <&> ExUnitsResponseModal
  _ -> kError FeatureNotSupported ("calculateMinFee: only BabbageEra and ConwayEra supported got : " ++ show cera )


bindEra :: IsTxBuilderEra era => CardanoEra era -> t1 era -> t1 era
bindEra _ = id

queryPparamHandler  :: (HasChainQueryAPI api) =>  BabbageEraOnwards era->  Kontract api w FrameworkError (LedgerProtocolParameters era)
queryPparamHandler era = case era of
  BabbageEraOnwardsBabbage -> kQueryProtocolParams
  BabbageEraOnwardsConway -> kQueryProtocolParams

queryUtxosHandler :: (HasChainQueryAPI api) =>   BabbageEraOnwards era ->  [Text] ->  [Text] -> Kontract api w FrameworkError (UtxoModal ConwayEra)
queryUtxosHandler era   [] [] = KError (FrameworkError ParserError "Missing both address and txin in query param")
queryUtxosHandler era   addrTxts txinTxts = do
      if null addrTxts
        then do
          txins <- mapM (\v1 -> case parseTxIn  v1  of
                Right v -> pure v
                Left msg -> KError (FrameworkError ParserError msg)
            ) txinTxts
          case era of 
            BabbageEraOnwardsBabbage -> kQueryUtxoByTxin  (Set.fromList txins) <&> UtxoModal
            BabbageEraOnwardsConway -> kQueryUtxoByTxin  (Set.fromList txins) <&> UtxoModal
          
      else if null txinTxts
        then do
          addrs <-  mapM (\v1 -> case parseAddressBech32 @ConwayEra  v1 of
                    Right v -> pure  $ addressInEraToAddressAny v
                    Left msg -> KError (FrameworkError ParserError msg)
                ) addrTxts
          case era of 
            BabbageEraOnwardsBabbage -> do 
              utxo <- kQueryUtxoByAddress (Set.fromList addrs) 
              pure $ UtxoModal $  updateUtxoEra (bindEra BabbageEra utxo)
            BabbageEraOnwardsConway -> kQueryUtxoByAddress (Set.fromList addrs) <&> UtxoModal
      else
        KError (FrameworkError ParserError "Expected either address or txin in parameter")


getKeyHashHandler :: AddressModal -> IO KeyHashResponse
getKeyHashHandler aie = do
  case addressInEraToPaymentKeyHash (unAddressModal aie) of
    Nothing -> throw $ FrameworkError  ParserError  "Couldn't derive key-hash from address "
    Just ha -> pure $ KeyHashResponse $ BS8.unpack $ serialiseToRawBytesHex ha

translatePosixTimeHandler :: HasKuberAPI a =>  TimeTranslationReq -> Kontract a w FrameworkError TranslationResponse
translatePosixTimeHandler (TimeTranslationReq timestamp) = do
    TranslationResponse <$> kTimeToSlot timestamp <*> pure timestamp

translateSlotHandler :: HasKuberAPI a => SlotTranslationReq -> Kontract a w FrameworkError TranslationResponse
translateSlotHandler (SlotTranslationReq slotNo) = do
    TranslationResponse  slotNo <$> kSlotToTime slotNo

queryTimeHandler :: HasKuberAPI a =>  Kontract a w FrameworkError TranslationResponse
queryTimeHandler  = do
    now <- liftIO getPOSIXTime
    translatePosixTimeHandler (TimeTranslationReq now)


queryBalanceHandler :: HasChainQueryAPI a => Text ->   Kontract a w FrameworkError BalanceResponse
queryBalanceHandler addrStr =
    case parseAddressBech32 @ConwayEra addrStr of
      Left e -> KError $ FrameworkError ParserError e
      Right a -> do
        utxos<- kQueryUtxoByAddress (Set.singleton $ addressInEraToAddressAny  a)
        pure $ BalanceResponse utxos

txBuilderHandler ::  (HasKuberAPI a, IsTxBuilderEra era) =>  Maybe Bool -> TxBuilder_ era -> Kontract a w FrameworkError TxModal
txBuilderHandler submitM txBuilder = do
  liftIO $ putStrLn $ BS8.unpack $  prettyPrintJSON txBuilder
  tx <- case submitM of
    Just True ->  kBuildAndSubmit txBuilder
    _ ->  kBuildTx txBuilder
  pure $ TxModal $ InAnyCardanoEra bCardanoEra tx

submitTxHandler :: HasSubmitApi a =>  SubmitTxModal -> Kontract a w FrameworkError TxModal
submitTxHandler  (SubmitTxModal inanyEra@(InAnyCardanoEra era tx) mWitness) = do
  case mWitness of
        Nothing -> do
          kSubmitTx inanyEra
          pure $ TxModal inanyEra
        Just kw -> do
          let txBody = getTxBody tx
          -- TODO handle witnesses
          -- let signedTx= InAnyCardanoEra era (makeSignedTransaction (kw : getTxWitnesses tx) txbody)
          kSubmitTx inanyEra
          pure $ TxModal inanyEra

