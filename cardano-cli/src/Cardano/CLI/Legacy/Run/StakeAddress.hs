{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{- HLINT ignore "Monad law, left identity" -}

module Cardano.CLI.Legacy.Run.StakeAddress
  ( ShelleyStakeAddressCmdError(ShelleyStakeAddressCmdReadKeyFileError)
  , getStakeCredentialFromIdentifier
  , runLegacyStakeAddressCmds
  , runLegacyStakeAddressKeyGenToFileCmd

  , createDelegationCertRequirements
  , createRegistrationCertRequirements
  ) where

import           Cardano.Api
import qualified Cardano.Api.Ledger as Ledger
import           Cardano.Api.Shelley

import           Cardano.CLI.Legacy.Commands.StakeAddress
import           Cardano.CLI.Read
import           Cardano.CLI.Types.Common
import           Cardano.CLI.Types.Errors.ShelleyStakeAddressCmdError
import           Cardano.CLI.Types.Errors.StakeAddressDelegationError
import           Cardano.CLI.Types.Errors.StakeAddressRegistrationError
import           Cardano.CLI.Types.Key (DelegationTarget (..), StakeIdentifier (..),
                   StakeVerifier (..), VerificationKeyOrFile, readVerificationKeyOrFile,
                   readVerificationKeyOrHashOrFile)

import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Trans (lift)
import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Trans.Except.Extra (firstExceptT, hoistEither, left, newExceptT,
                   onLeft)
import qualified Data.ByteString.Char8 as BS
import           Data.Function ((&))
import qualified Data.Text.IO as Text

runLegacyStakeAddressCmds :: LegacyStakeAddressCmds -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeAddressCmds = \case
  StakeAddressKeyGen fmt vk sk ->
    runLegacyStakeAddressKeyGenToFileCmd fmt vk sk
  StakeAddressKeyHash vk mOutputFp ->
    runLegacyStakeAddressKeyHashCmd vk mOutputFp
  StakeAddressBuild stakeVerifier nw mOutputFp ->
    runLegacyStakeAddressBuildCmd stakeVerifier nw mOutputFp
  StakeRegistrationCert anyEra stakeIdentifier mDeposit outputFp ->
    runLegacyStakeCredentialRegistrationCertCmd anyEra stakeIdentifier mDeposit outputFp
  StakeCredentialDelegationCert anyEra stakeIdentifier stkPoolVerKeyHashOrFp outputFp ->
    runLegacyStakeCredentialDelegationCertCmd anyEra stakeIdentifier stkPoolVerKeyHashOrFp outputFp
  StakeCredentialDeRegistrationCert anyEra stakeIdentifier mDeposit outputFp ->
    runLegacyStakeCredentialDeRegistrationCertCmd anyEra stakeIdentifier mDeposit outputFp

--
-- Stake address command implementations
--

runLegacyStakeAddressKeyGenToFileCmd
  :: KeyOutputFormat
  -> VerificationKeyFile Out
  -> SigningKeyFile Out
  -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeAddressKeyGenToFileCmd fmt vkFp skFp = do
  let skeyDesc = "Stake Signing Key"
  let vkeyDesc = "Stake Verification Key"

  skey <- liftIO $ generateSigningKey AsStakeKey

  let vkey = getVerificationKey skey

  firstExceptT ShelleyStakeAddressCmdWriteFileError $ do
    case fmt of
      KeyOutputFormatTextEnvelope ->
        newExceptT $ writeLazyByteStringFile skFp $ textEnvelopeToJSON (Just skeyDesc) skey
      KeyOutputFormatBech32 ->
        newExceptT $ writeTextFile skFp $ serialiseToBech32 skey

    case fmt of
      KeyOutputFormatTextEnvelope ->
        newExceptT $ writeLazyByteStringFile vkFp $ textEnvelopeToJSON (Just vkeyDesc) vkey
      KeyOutputFormatBech32 ->
        newExceptT $ writeTextFile vkFp $ serialiseToBech32 vkey

runLegacyStakeAddressKeyHashCmd
  :: VerificationKeyOrFile StakeKey
  -> Maybe (File () Out)
  -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeAddressKeyHashCmd stakeVerKeyOrFile mOutputFp = do
  vkey <- firstExceptT ShelleyStakeAddressCmdReadKeyFileError
    . newExceptT
    $ readVerificationKeyOrFile AsStakeKey stakeVerKeyOrFile

  let hexKeyHash = serialiseToRawBytesHex (verificationKeyHash vkey)

  case mOutputFp of
    Just (File fpath) -> liftIO $ BS.writeFile fpath hexKeyHash
    Nothing -> liftIO $ BS.putStrLn hexKeyHash

runLegacyStakeAddressBuildCmd
  :: StakeVerifier
  -> NetworkId
  -> Maybe (File () Out)
  -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeAddressBuildCmd stakeVerifier network mOutputFp = do
  stakeAddr <-
    getStakeAddressFromVerifier network stakeVerifier
      & firstExceptT ShelleyStakeAddressCmdStakeCredentialError
  let stakeAddrText = serialiseAddress stakeAddr
  liftIO $
    case mOutputFp of
      Just (File fpath) -> Text.writeFile fpath stakeAddrText
      Nothing -> Text.putStrLn stakeAddrText


runLegacyStakeCredentialRegistrationCertCmd
  :: AnyShelleyBasedEra
  -> StakeIdentifier
  -> Maybe Lovelace -- ^ Deposit required in conway era
  -> File () Out
  -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeCredentialRegistrationCertCmd anyEra stakeIdentifier mDeposit oFp = do
  AnyShelleyBasedEra sbe <- pure anyEra
  stakeCred <-
    getStakeCredentialFromIdentifier stakeIdentifier
      & firstExceptT ShelleyStakeAddressCmdStakeCredentialError
  req <- firstExceptT StakeRegistrationError
           . hoistEither $ createRegistrationCertRequirements sbe stakeCred mDeposit
  writeRegistrationCert sbe req

 where
  writeRegistrationCert
    :: ShelleyBasedEra era
    -> StakeAddressRequirements era
    -> ExceptT ShelleyStakeAddressCmdError IO ()
  writeRegistrationCert sbe req = do
    let regCert = makeStakeAddressRegistrationCertificate req
    firstExceptT ShelleyStakeAddressCmdWriteFileError
      . newExceptT
      $ writeLazyByteStringFile oFp
      $ shelleyBasedEraConstraints sbe
      $ textEnvelopeToJSON (Just regCertDesc) regCert

  regCertDesc :: TextEnvelopeDescr
  regCertDesc = "Stake Address Registration Certificate"


createRegistrationCertRequirements
  :: ShelleyBasedEra era
  -> StakeCredential
  -> Maybe Lovelace
  -> Either StakeAddressRegistrationError (StakeAddressRequirements era)
createRegistrationCertRequirements sbe stakeCred mdeposit =
  case sbe of
    ShelleyBasedEraShelley ->
      return $ StakeAddrRegistrationPreConway ShelleyToBabbageEraShelley stakeCred
    ShelleyBasedEraAllegra ->
      return $ StakeAddrRegistrationPreConway ShelleyToBabbageEraAllegra stakeCred
    ShelleyBasedEraMary ->
      return $ StakeAddrRegistrationPreConway ShelleyToBabbageEraMary stakeCred
    ShelleyBasedEraAlonzo ->
      return $ StakeAddrRegistrationPreConway ShelleyToBabbageEraAlonzo stakeCred
    ShelleyBasedEraBabbage ->
      return $ StakeAddrRegistrationPreConway ShelleyToBabbageEraBabbage stakeCred
    ShelleyBasedEraConway ->
      case mdeposit of
        Nothing -> Left StakeAddressRegistrationDepositRequired
        Just dep ->
          return $ StakeAddrRegistrationConway ConwayEraOnwardsConway dep stakeCred


runLegacyStakeCredentialDelegationCertCmd
  :: AnyShelleyBasedEra
  -> StakeIdentifier
  -- ^ Delegator stake verification key, verification key file or script file.
  -> DelegationTarget
  -- ^ Delegatee stake pool verification key or verification key file or
  -- verification key hash.
  -> File () Out
  -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeCredentialDelegationCertCmd anyEra stakeVerifier delegationTarget outFp = do
  AnyShelleyBasedEra sbe <- pure anyEra
  case delegationTarget of
    StakePoolDelegationTarget poolVKeyOrHashOrFile -> do
      StakePoolKeyHash poolStakeVKeyHash <- lift (readVerificationKeyOrHashOrFile AsStakePoolKey poolVKeyOrHashOrFile)
        & onLeft (left . ShelleyStakeAddressCmdReadKeyFileError)
      let delegatee = Ledger.DelegStake poolStakeVKeyHash
      stakeCred <-
        getStakeCredentialFromIdentifier stakeVerifier
          & firstExceptT ShelleyStakeAddressCmdStakeCredentialError
      req <- firstExceptT StakeDelegationError . hoistEither
               $ createDelegationCertRequirements sbe stakeCred delegatee
      let delegCert = makeStakeAddressDelegationCertificate req
      firstExceptT ShelleyStakeAddressCmdWriteFileError
        . newExceptT
        $ writeLazyByteStringFile outFp
        $ textEnvelopeToJSON (Just @TextEnvelopeDescr "Stake Address Delegation Certificate") delegCert

createDelegationCertRequirements
  :: ShelleyBasedEra era
  -> StakeCredential
  -> Ledger.Delegatee Ledger.StandardCrypto
  -> Either StakeAddressDelegationError (StakeDelegationRequirements era)
createDelegationCertRequirements sbe stakeCred delegatee =
  case sbe of
    ShelleyBasedEraShelley -> do
      pId <- onlySpoDelegatee ShelleyToBabbageEraShelley delegatee
      return $ StakeDelegationRequirementsPreConway ShelleyToBabbageEraShelley stakeCred pId
    ShelleyBasedEraAllegra -> do
      pId <- onlySpoDelegatee ShelleyToBabbageEraAllegra delegatee
      return $ StakeDelegationRequirementsPreConway ShelleyToBabbageEraAllegra stakeCred pId
    ShelleyBasedEraMary -> do
      pId <- onlySpoDelegatee ShelleyToBabbageEraMary delegatee
      return $ StakeDelegationRequirementsPreConway ShelleyToBabbageEraMary stakeCred pId
    ShelleyBasedEraAlonzo -> do
      pId <- onlySpoDelegatee ShelleyToBabbageEraAlonzo delegatee
      return $ StakeDelegationRequirementsPreConway ShelleyToBabbageEraAlonzo stakeCred pId
    ShelleyBasedEraBabbage -> do
      pId <- onlySpoDelegatee ShelleyToBabbageEraBabbage delegatee
      return $ StakeDelegationRequirementsPreConway ShelleyToBabbageEraBabbage stakeCred pId
    ShelleyBasedEraConway ->
      return $ StakeDelegationRequirementsConwayOnwards ConwayEraOnwardsConway stakeCred delegatee

onlySpoDelegatee
  :: ShelleyToBabbageEra era
  -> Ledger.Delegatee (Ledger.EraCrypto (ShelleyLedgerEra era))
  -> Either StakeAddressDelegationError PoolId
onlySpoDelegatee w ledgerDelegatee =
  case ledgerDelegatee of
    Ledger.DelegStake stakePoolKeyHash ->
      Right $ StakePoolKeyHash $ shelleyToBabbageEraConstraints w stakePoolKeyHash
    Ledger.DelegVote{} ->
      Left . VoteDelegationNotSupported $ AnyShelleyToBabbageEra w
    Ledger.DelegStakeVote{} ->
      Left . VoteDelegationNotSupported $ AnyShelleyToBabbageEra w

runLegacyStakeCredentialDeRegistrationCertCmd
  :: AnyShelleyBasedEra
  -> StakeIdentifier
  -> Maybe Lovelace -- ^ Deposit required in conway era
  -> File () Out
  -> ExceptT ShelleyStakeAddressCmdError IO ()
runLegacyStakeCredentialDeRegistrationCertCmd anyEra stakeVerifier mDeposit oFp = do
  AnyShelleyBasedEra sbe <- pure anyEra
  stakeCred <-
    getStakeCredentialFromIdentifier stakeVerifier
      & firstExceptT ShelleyStakeAddressCmdStakeCredentialError
  req <- firstExceptT StakeRegistrationError
           . hoistEither $ createRegistrationCertRequirements sbe stakeCred mDeposit

  writeDeregistrationCert sbe req

  where
    writeDeregistrationCert
      :: ShelleyBasedEra era
      -> StakeAddressRequirements era
      -> ExceptT ShelleyStakeAddressCmdError IO ()
    writeDeregistrationCert sbe req = do
      let deRegCert = makeStakeAddressUnregistrationCertificate req
      firstExceptT ShelleyStakeAddressCmdWriteFileError
        . newExceptT
        $ writeLazyByteStringFile oFp
        $ shelleyBasedEraConstraints sbe
        $ textEnvelopeToJSON (Just deregCertDesc) deRegCert

    deregCertDesc :: TextEnvelopeDescr
    deregCertDesc = "Stake Address Deregistration Certificate"
