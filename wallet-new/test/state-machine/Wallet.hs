{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TemplateHaskell     #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Wallet
  ( prop_wallet
  , prop_walletParallel
  , withWalletLayer
  )
  where

import           Universum

import           Data.Time.Units (Microsecond, toMicroseconds)
import           Data.TreeDiff (ToExpr (toExpr))
import           GHC.Generics (Generic, Generic1)
import           Test.QuickCheck (Arbitrary (arbitrary), Gen, Property,
                     elements, frequency, (===))
import           Test.QuickCheck.Monadic (monadicIO)

import           Test.StateMachine
import           Test.StateMachine.Types (Command (..), Commands (..),
                     StateMachine)

import qualified Test.StateMachine.Types.Rank2 as Rank2

import           Cardano.Wallet.API.Request (RequestParams (..))
import           Cardano.Wallet.API.Request.Filter (FilterOperations (..))
import           Cardano.Wallet.API.Request.Pagination (PaginationParams (..))
import           Cardano.Wallet.API.Response (WalletResponse (wrData))
import           Cardano.Wallet.API.Types.UnitOfMeasure (MeasuredIn (..),
                     UnitOfMeasure (..))
import qualified Cardano.Wallet.API.V1.Types as V1
import           Cardano.Wallet.Client (paginateAll)
import qualified Cardano.Wallet.Kernel as Kernel
import qualified Cardano.Wallet.Kernel.BIP39 as BIP39
import qualified Cardano.Wallet.Kernel.DB.Util.IxSet as DB
import           Cardano.Wallet.Kernel.Internal (PassiveWallet)
import qualified Cardano.Wallet.Kernel.Keystore as Keystore
import           Cardano.Wallet.Kernel.NodeStateAdaptor (mockNodeStateDef)
import qualified Cardano.Wallet.Kernel.Wallets as Kernel
import qualified Cardano.Wallet.WalletLayer as WL
import qualified Cardano.Wallet.WalletLayer.Kernel as WL

import qualified Pos.Binary.Class as BI
import qualified Pos.Core as Core
import qualified Pos.Crypto.Signing as Core
import           Pos.Infra.InjectFail (mkFInjects)
import           Pos.Util.Wlog (Severity)
import qualified Pos.Wallet.Web.State.Storage as OldStorage


------------------------------------------------------------------------

-- Wallet actions

data Action (r :: * -> *)
    = ResetWalletA
    | CreateWalletA WL.CreateWallet
    | GetWalletsA
    | GetWalletA V1.WalletId
    | UpdateWalletA V1.WalletId V1.WalletUpdate
    | UpdateWalletPasswordA V1.WalletId V1.PasswordUpdate
    | DeleteWalletA V1.WalletId
    -- TODO: add getting utxo (after account and transaction modelling)
    | CreateAccountA V1.WalletId V1.NewAccount
    | GetAccountsA V1.WalletId
    | GetAccountA V1.WalletId V1.AccountIndex
    | GetAccountBalanceA V1.WalletId V1.AccountIndex
    -- NOTE: we are ignoring pagination, filtering, and sorting operations
    | GetAccountAddressesA
        V1.WalletId
        V1.AccountIndex
    -- TODO: test pagination, filtering and sorting
--        RequestParams
--        (FilterOperations '[V1.V1 V1.Address] V1.WalletAddress)
    | UpdateAccountA V1.WalletId V1.AccountIndex V1.AccountUpdate
    | DeleteAccountA V1.WalletId V1.AccountIndex
    | CreateAddressA V1.NewAddress
    deriving (Show, Generic1, Rank2.Functor, Rank2.Foldable, Rank2.Traversable)

-- TODO: https://github.com/input-output-hk/cardano-sl/pull/3772#pullrequestreview-171983141
data Response (r :: * -> *)
    = ResetWalletR
    | CreateWalletR (Either WL.CreateWalletError V1.Wallet)
    | GetWalletsR (DB.IxSet V1.Wallet)
    | GetWalletR (Either WL.GetWalletError V1.Wallet)
    | UpdateWalletR (Either WL.UpdateWalletError V1.Wallet)
    | UpdateWalletPasswordR (Either WL.UpdateWalletPasswordError V1.Wallet)
    | DeleteWalletR (Either WL.DeleteWalletError ())
    -- TODO: add getting utxo (after account and transaction modelling)
    | CreateAccountR (Either WL.CreateAccountError V1.Account)
    | GetAccountsR (Either WL.GetAccountsError (DB.IxSet V1.Account))
    | GetAccountR (Either WL.GetAccountError V1.Account)
    | GetAccountBalanceR (Either WL.GetAccountError V1.AccountBalance)
    | GetAccountAddressesR (Either WL.GetAccountError [V1.WalletAddress])
    | UpdateAccountR (Either WL.UpdateAccountError V1.Account)
    | DeleteAccountR (Either WL.DeleteAccountError ())
    | CreateAddressR (Either WL.CreateAddressError V1.WalletAddress)
    deriving (Show, Generic1, Rank2.Foldable)


------------------------------------------------------------------------

-- Wallet state

-- TODO: should we put PassiveWallet reference into the model?
-- this is how CircurlarBufer.hs does it - it saves a spec and uses
-- a spec to check real state
data Model (r :: * -> *) = Model
    -- TODO: don't use touple here, use record
    { mWallets     :: [(V1.Wallet, Maybe V1.SpendingPassword)]
    , mAccounts    :: [V1.Account]
    , mUnhappyPath :: Int
    , mReset       :: Bool
    }
    deriving (Eq, Show, Generic)

-- TODO: can we make this shorter and derive only necessary things
-- FIXME: orphan instances
-- NOTE: this is use for diffing datatypes for pretty printer
deriving instance ToExpr (V1.V1 Core.Timestamp)
deriving instance ToExpr Core.Coin
deriving instance ToExpr Core.Timestamp
deriving instance ToExpr (V1.V1 Core.Coin)
deriving instance ToExpr (V1.V1 V1.AddressOwnership)
deriving instance ToExpr V1.AddressOwnership
instance ToExpr (V1.V1 Core.Address) where
    -- TODO: check is this viable solution
    toExpr = toExpr @String . show . BI.encode . V1.unV1
deriving instance ToExpr V1.WalletAddress
deriving instance ToExpr V1.AccountIndex
deriving instance ToExpr V1.Account
deriving instance ToExpr V1.Wallet
deriving instance ToExpr V1.WalletId
deriving instance ToExpr V1.AssuranceLevel
deriving instance ToExpr V1.SyncState
deriving instance ToExpr V1.WalletType
deriving instance ToExpr V1.SyncProgress
deriving instance ToExpr V1.SyncPercentage
deriving instance ToExpr V1.SyncThroughput
deriving instance ToExpr OldStorage.SyncThroughput
deriving instance ToExpr V1.EstimatedCompletionTime
instance ToExpr (V1.V1 Core.PassPhrase) where
    -- TODO: check is this viable solution
    toExpr = toExpr @String . show . BI.encode . V1.unV1
deriving instance ToExpr Core.BlockCount
deriving instance ToExpr (MeasuredIn 'Milliseconds Word)
deriving instance ToExpr (MeasuredIn 'BlocksPerSecond Word)
deriving instance ToExpr (MeasuredIn 'Percentage100 Word8)
deriving instance ToExpr (MeasuredIn 'BlocksPerSecond OldStorage.SyncThroughput)
instance ToExpr Microsecond where
    toExpr = toExpr . toMicroseconds
deriving instance ToExpr (Model Concrete)

initModel :: Model r
initModel = Model mempty mempty 0 False

-- If you need more fine grained distribution, use preconditions
preconditions :: Model Symbolic -> Action Symbolic -> Logic
preconditions _ ResetWalletA      = Top
-- NOTE: with this mechanism we are forcing ResetWalletA to be first action
-- in an action list generated. We need this because we are reusing same
-- db through all quickcheck runs - so we have to ensure ResetActionA is run
-- before any other action. Implementation by precondition is good enough and
-- generator won't need to try too many options until it reaches ResetActionA.
-- An alternative solution would be to modify `forAllCommands` in this way:
--
-- ```
-- forAllCommands' sm n action = forAllCommands sm n $ \cmds -> action $ Commands [Command ResetWalletA mempty] <> cmds
-- ```
--
-- The above would work a bit more performant (as we don't have failing preconditions)
-- but we are hacking around to lib internals which is not so idiomatic.
preconditions (Model _ _ _ True) action = case action of
    ResetWalletA              -> Top
    CreateWalletA _           -> Top
    GetWalletsA               -> Top
    GetWalletA _              -> Top
    UpdateWalletA _ _         -> Top
    UpdateWalletPasswordA _ _ -> Top
    DeleteWalletA _           -> Top
    CreateAccountA _ _        -> Top
    GetAccountsA _            -> Top
    GetAccountA _ _           -> Top
    GetAccountBalanceA _ _    -> Top
    GetAccountAddressesA _ _  -> Top
    UpdateAccountA _ _ _      -> Top
    DeleteAccountA _ _        -> Top
    CreateAddressA _          -> Top

    -- NOTE: don't use catch all pattern like
    --
    -- (_, _) ->
    --
    -- as it will most likely bite us.

-- if wallet is not reset then we shouldn't continue
preconditions (Model _ _ _ False) _   = Bot

transitions :: Model r -> Action r -> Response r -> Model r
transitions model@Model{..} cmd res = case (cmd, res) of
    (ResetWalletA, ResetWalletR) -> Model mempty mempty 0 True
    (ResetWalletA, _) -> shouldNotBeReachedError
    (CreateWalletA (WL.CreateWallet V1.NewWallet{..}), CreateWalletR (Right wallet)) ->
        -- TODO: use lenses
        model { mWallets = (wallet, newwalSpendingPassword) : mWallets }
    (CreateWalletA _, CreateWalletR (Left _)) -> increaseUnhappyPath
    (CreateWalletA _, _) -> shouldNotBeReachedError
    (GetWalletsA, GetWalletsR _) -> model
    (GetWalletsA, _) -> shouldNotBeReachedError
    (GetWalletA _, GetWalletR (Right _)) -> model
    (GetWalletA _, GetWalletR (Left _)) -> increaseUnhappyPath
    (GetWalletA _, _) -> shouldNotBeReachedError
    -- FIXME: hm - something strange is going on
    -- For some reason if I replace path bellow with
    --
    --  ... -> model
    --
    -- tests will pass - but I am not sure they should. In this case we
    -- are not correctly modeling this path and postcondition should be able to catch the mistake - but that's not happening. Check why is this the case!!
    (UpdateWalletA wId _, UpdateWalletR (Right wallet)) ->
        let thisWallet = (wId ==) . V1.walId . fst
            updatedWallets = map (first (const wallet)) $ filter thisWallet mWallets
        in model { mWallets = updatedWallets <> filter (not . thisWallet) mWallets }
    (UpdateWalletA _ _, UpdateWalletR (Left _)) -> increaseUnhappyPath
    (UpdateWalletA _ _, _) -> shouldNotBeReachedError
    (UpdateWalletPasswordA wId V1.PasswordUpdate{..}, UpdateWalletPasswordR (Right wallet)) ->
        let thisWallet = (wId ==) . V1.walId . fst
        in model { mWallets = (wallet, Just pwdNew) : filter (not . thisWallet) mWallets }
    (UpdateWalletPasswordA _ _, UpdateWalletPasswordR (Left _)) -> increaseUnhappyPath
    (UpdateWalletPasswordA _ _, _) -> shouldNotBeReachedError
    (DeleteWalletA wId, DeleteWalletR (Right _)) ->
        let thisWallet = (wId ==) . V1.walId . fst
        in model { mWallets = filter (not . thisWallet) mWallets }
    (DeleteWalletA _, DeleteWalletR (Left _)) -> increaseUnhappyPath
    (DeleteWalletA _, _) -> shouldNotBeReachedError
    (CreateAccountA _ _, CreateAccountR (Right account)) ->
        model { mAccounts = account : mAccounts }
    (CreateAccountA _ _, CreateAccountR (Left _)) -> increaseUnhappyPath
    (CreateAccountA _ _, _) -> shouldNotBeReachedError
    (GetAccountsA _, GetAccountsR (Right _)) -> model
    (GetAccountsA _, GetAccountsR (Left _)) -> increaseUnhappyPath
    (GetAccountsA _, _) -> shouldNotBeReachedError
    (GetAccountA _ _, GetAccountR (Right _)) -> model
    (GetAccountA _ _, GetAccountR (Left _)) -> increaseUnhappyPath
    (GetAccountA _ _, _) -> shouldNotBeReachedError
    (GetAccountBalanceA _ _, GetAccountBalanceR (Right _)) -> model
    (GetAccountBalanceA _ _, GetAccountBalanceR (Left _)) -> increaseUnhappyPath
    (GetAccountBalanceA _ _, _) -> shouldNotBeReachedError
    (GetAccountAddressesA _ _, GetAccountAddressesR (Right _)) -> model
    (GetAccountAddressesA _ _, GetAccountAddressesR (Left _)) -> increaseUnhappyPath
    (GetAccountAddressesA _ _, _) -> shouldNotBeReachedError
    (UpdateAccountA _ _ _, UpdateAccountR (Right account)) ->
        let thisAccount = V1.accountsHaveSameId account
        in model { mAccounts = account : filter (not . thisAccount) mAccounts }
    (UpdateAccountA _ _ _, UpdateAccountR (Left _)) -> increaseUnhappyPath
    (UpdateAccountA _ _ _, _) -> shouldNotBeReachedError
    (DeleteAccountA wId index, DeleteAccountR (Right _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
        in model { mAccounts = filter (not . thisAccount) mAccounts }
    (DeleteAccountA _ _, DeleteAccountR (Left _)) -> increaseUnhappyPath
    (DeleteAccountA _ _, _) -> shouldNotBeReachedError
    (CreateAddressA V1.NewAddress{..}, CreateAddressR (Right address)) ->
        let thisAccount V1.Account{..} = accWalletId == newaddrWalletId && accIndex == newaddrAccountIndex
            updatedAccounts = map update $ filter thisAccount mAccounts
            -- TODO: use lenses
            update acc = acc { V1.accAddresses = address:V1.accAddresses acc }
        in model { mAccounts = updatedAccounts <> filter (not . thisAccount) mAccounts }
    (CreateAddressA _, CreateAddressR (Left _)) -> increaseUnhappyPath
    (CreateAddressA _, _) -> shouldNotBeReachedError

    -- NOTE: don't use catch all pattern like
    --
    -- (_, _) ->
    --
    -- as it will most likely bite us.
  where
    -- TODO: use postcondition that ration of unhappy paths has to be expected (ie, similar to test coverage)
    -- If number of unhappy paths is too high something might go wrong and our tests are not covering enough happy paths (and vice versa)?
    increaseUnhappyPath = model { mUnhappyPath = mUnhappyPath + 1 }
    shouldNotBeReachedError = error "This branch should not be reached!"

-- TODO: use unit tests in wallet-new/test/unit for inspiration
postconditions :: Model Concrete -> Action Concrete -> Response Concrete -> Logic
postconditions Model{..} cmd res = case (cmd, res) of
    (ResetWalletA, ResetWalletR)               -> Top
    (ResetWalletA, _)                          -> shouldNotBeReachedError
    -- TODO: pissibly check that wallet wasn't added
    -- check that ratio of errors is normal/expected

    -- It should be expected for a wallet creation to fail sometimes, but not currently in our tests.
    (CreateWalletA _, CreateWalletR (Left _))  -> Bot
    -- TODO: check that wallet request and wallet response contain same attributes
    -- that we have created intended wallet
    -- FIXME: this postcondition can be made much stronger!
    -- Created wallet shouldn't be present in the model
    (CreateWalletA _, CreateWalletR (Right V1.Wallet{..})) -> Predicate $ NotElem walId (map (V1.walId . fst) mWallets)
    (CreateWalletA _, _) -> shouldNotBeReachedError
    -- Checks does our model have exact same wallets as real wallet
    (GetWalletsA, GetWalletsR wallets) ->
        -- For some reason received wallet will have slightly different timestamp
        -- then when it was created (CO-439).
        -- This is a workaround to check are two wallets equal but ignoring update password timestamp
        let walletIgnoreTimestamp w = w { V1.walSpendingPasswordLastUpdate = V1.V1 $ Core.Timestamp 0 }
        in sort (map walletIgnoreTimestamp $ DB.toList wallets) .== sort (map (walletIgnoreTimestamp. fst) mWallets)
    (GetWalletsA, _) -> shouldNotBeReachedError
    -- If wallet is not found in a real thing it also shouldn't exist in a model
    (GetWalletA wId, GetWalletR (Left _)) -> Predicate $ NotElem wId (map (V1.walId . fst) mWallets)
    -- Checks did we really get wallet with intended id. Also checks
    -- is returned walet same as the one in our model
    (GetWalletA wId, GetWalletR (Right wallet)) ->
        (V1.walId wallet .== wId)
        :&& Predicate (Elem wallet $ map fst mWallets)
    (GetWalletA _, _) -> shouldNotBeReachedError
    -- If wallet is not found in a real thing it also shouldn't exist in a model
    (UpdateWalletA wId _, UpdateWalletR (Left _)) -> Predicate $ NotElem wId (map (V1.walId . fst) mWallets)
    -- Checks if updated wallet is really what we got
    (UpdateWalletA wId V1.WalletUpdate{..}, UpdateWalletR (Right wallet)) ->
        let mWallet = update . fst <$> find ((== wId) . V1.walId . fst) mWallets
            update w = w { V1.walAssuranceLevel = uwalAssuranceLevel, V1.walName = uwalName }
        in mWallet .== Just wallet
    (UpdateWalletA _ _, _) -> shouldNotBeReachedError
    -- If password update didn't succeed we expect old password to be wrong
    -- or we didn't find the wallet at all
    (UpdateWalletPasswordA wId V1.PasswordUpdate{..}, UpdateWalletPasswordR (Left _)) ->
        let pass = snd <$> find ((== wId) . V1.walId . fst) mWallets
        in (Predicate (NotElem wId (map (V1.walId . fst) mWallets)))
                :|| (pass .== Just (Just pwdOld))
    -- If password update did succeed we expect old password to be correct
    -- and that we have manged to find wallet
    -- and that we updated correct wallet
    (UpdateWalletPasswordA wId V1.PasswordUpdate{..}, UpdateWalletPasswordR (Right wallet)) ->
        let pass = snd <$> find ((== wId) . V1.walId . fst) mWallets
        in (Predicate (Elem wId (map (V1.walId . fst) mWallets)))
                :&& (pass .== Just (Just pwdOld))
                :&& (wId .== V1.walId wallet)
    (UpdateWalletPasswordA _ _, _) -> shouldNotBeReachedError
    -- If wallet delete didn't succeed we expect wallet isn't found in model
    (DeleteWalletA wId, DeleteWalletR (Left _)) ->
        Predicate (NotElem wId (map (V1.walId . fst) mWallets))
    -- If wallet delete did succeed we expect wallet can be found in model
    (DeleteWalletA wId, DeleteWalletR (Right _)) ->
        Predicate (NotElem wId (map (V1.walId . fst) mWallets))
    (DeleteWalletA _, _) -> shouldNotBeReachedError
    -- Created account shouldn't be present in the model
    (CreateAccountA _ _, CreateAccountR (Right account)) ->
        let thisAccount = V1.accountsHaveSameId account
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    -- Account creation will fail if we try to create an account
    -- in a wallet that doesn't exist
    -- TODO: add more specific Left guards such as
    --
    -- CreateAccountR (Left CreateAccountError CreateAccountKeystoreNotFound WalletIdHdRnd HdRootId wId')
    --
    -- so that we don't handle the wront case
    (CreateAccountA wId _, CreateAccountR (Left _)) ->
        Predicate (NotElem wId (map (V1.walId . fst) mWallets))
    (CreateAccountA _ _, _) -> shouldNotBeReachedError
    -- Checks does our model have exact same accounts as real wallet
    (GetAccountsA wId, GetAccountsR (Right accounts)) ->
        sort (DB.toList accounts) .== sort mAccounts
    -- If there are no accounts we assume wallet doesn't exist
    (GetAccountsA wId, GetAccountsR (Left _)) ->
        Predicate $ NotElem wId (map (V1.walId . fst) mWallets)
    (GetAccountsA _, _) -> shouldNotBeReachedError
    -- If we managed to get account, that account should exist in the model
    -- TODO: also check that wallet id and account correspond to returned account
    (GetAccountA _ _, GetAccountR (Right account)) ->
        let mAccount = find (== account) mAccounts
        in mAccount .== Nothing
    -- If there is no account we assume account with such index and wallet id doesn't exist
    (GetAccountA wId index, GetAccountR (Left _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    (GetAccountA _ _, _) -> shouldNotBeReachedError
    -- If we managed to get account balance, that account should exist in the model and it should have exactly the same balance
    (GetAccountBalanceA wId index, GetAccountBalanceR (Right balance)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mBalance = V1.accAmount <$> find thisAccount mAccounts
        in mBalance .== Just (V1.acbAmount balance)
    -- If there is no account we assume account with such index and wallet id doesn't exist
    -- TODO: reuse GetAccountA which has exactly the same postcondition
    -- TODO: in general try to reuse postconditions between states, they
    -- seem to reuse many bits
    (GetAccountBalanceA wId index, GetAccountBalanceR (Left _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    (GetAccountBalanceA _ _, _) -> shouldNotBeReachedError
    -- Check did we get all account addresses
    (GetAccountAddressesA wId index, GetAccountAddressesR (Right walletAddresses)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mWalletAddresses = V1.accAddresses <$> find thisAccount mAccounts
        in mWalletAddresses .== Just walletAddresses
    -- If there is no account we assume account with such index and wallet id doesn't exist
    (GetAccountAddressesA wId index, GetAccountAddressesR (Left _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    (GetAccountAddressesA _ _, _) -> shouldNotBeReachedError
    -- Checks if updated account is really what we got
    (UpdateAccountA wId index V1.AccountUpdate{..}, UpdateAccountR (Right account)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = update <$> find thisAccount mAccounts
            update acc = acc { V1.accName = uaccName }
        in mAccount .== Just account
    -- If there is an error we assume account with such index and wallet id doesn't exist
    (UpdateAccountA wId index _, UpdateAccountR (Left _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    (UpdateAccountA _ _ _, _) -> shouldNotBeReachedError
    (DeleteAccountA wId index, DeleteAccountR (Left _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    -- If account delete did succeed we expect account can be found in model
    (DeleteAccountA wId index, DeleteAccountR (Right _)) ->
        let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
            mAccount = find thisAccount mAccounts
        in Boolean $ isJust mAccount
    (DeleteAccountA _ _, _) -> shouldNotBeReachedError
    -- If we managed to create a new address then specific account should exist, it has to have correct password and newly created address shouldn't already be in list of addresses of that account
    (CreateAddressA V1.NewAddress{..}, CreateAddressR (Right address)) ->
        let thisAccount V1.Account{..} = accWalletId == newaddrWalletId && accIndex == newaddrAccountIndex
            thisWallet = (== newaddrWalletId) . V1.walId . fst
            mAccount = find thisAccount mAccounts
            mWalletPass = snd <$> find thisWallet mWallets
            mIsNewAddress = Universum.elem address . V1.accAddresses <$> mAccount
        in (mIsNewAddress .== Just False) :&& (mWalletPass .== Just newaddrSpendingPassword)
    -- If error occured we assume acount with wallet id and account index
    -- doesn't exist.
    (CreateAddressA V1.NewAddress{..}, CreateAddressR (Left _)) ->
        let thisAccount V1.Account{..} = accWalletId == newaddrWalletId && accIndex == newaddrAccountIndex
            mAccount = find thisAccount mAccounts
        in mAccount .== Nothing
    (CreateAddressA _, _) -> shouldNotBeReachedError


    -- NOTE: don't use catch all pattern like
    --
    -- (_, _) ->
    --
    -- as it will most likely bite us.

  where
    shouldNotBeReachedError = error "This branch should not be reached!"

------------------------------------------------------------------------

-- Action generator

-- Same as quickchecks elements but if list is empty it will generate
-- arbitrary element
-- TODO: check do we have this functionality already in some utilities
genElements :: Arbitrary a => [a] -> Gen a
genElements [] = arbitrary
genElements xs = elements xs

-- TODO: reuse the one from wallet-new/test/unit/Test/Spec/Wallets.hs
genNewWalletRq :: Gen V1.NewWallet
genNewWalletRq = do
    spendingPassword <- frequency [(20, pure Nothing), (80, Just <$> arbitrary)]
    assuranceLevel   <- arbitrary
    walletName       <- arbitrary
    mnemonic <- arbitrary @(BIP39.Mnemonic 12)
    return $ V1.NewWallet (V1.BackupPhrase mnemonic)
                          spendingPassword
                          assuranceLevel
                          walletName
                          V1.CreateWallet

genPasswordUpdate :: Model Symbolic -> Gen (V1.WalletId, V1.PasswordUpdate)
genPasswordUpdate Model{..} = do
    -- Pick wallet to update password
    (wal, correctOldPass) <- second (fromMaybe mempty) <$> genElements mWallets
    oldPass <- frequency
                    -- Old pass can be wrong
                    [ (20, arbitrary)
                    -- Old pass can be correct
                    , (80, pure correctOldPass)
                    ]
    newPass <- frequency
                    -- New pass can be unset
                    [ (10, pure mempty)
                    -- New pass can stay the same
                    , (20, pure correctOldPass)
                    -- New pass can be arbitrary
                    , (70, arbitrary)
                    ]
    pure (V1.walId wal, V1.PasswordUpdate oldPass newPass)

genNewAccount :: Model Symbolic -> Gen (V1.WalletId, V1.NewAccount)
genNewAccount Model{..} = do
    -- Pick wallet to create an account
    (wal, correctOldPass) <- second (fromMaybe mempty) <$> genElements mWallets
    spendingPassword <- frequency
        -- pass can be unset
        [ (10, pure Nothing)
        -- pass can be empty
        , (10, pure $ Just mempty)
        -- pass can be arbitrary
        , (10, Just <$> arbitrary)
        -- pass can stay the same
        , (70, pure $ Just correctOldPass)
        ]
    name <- arbitrary
    pure (V1.walId wal, V1.NewAccount spendingPassword name)

genGetAccount :: Model Symbolic -> Gen (V1.WalletId, V1.AccountIndex)
genGetAccount Model{..} = do
    -- Pick account
    acc <- genElements mAccounts
    frequency
        -- both wallet id and account index exist but their
        -- combination is wrong
        [ (10, (,) <$> genElements (map V1.accWalletId mAccounts) <*> genElements (map V1.accIndex mAccounts))
        -- non existing account index
        , (10, (,) <$> genElements (map V1.accWalletId mAccounts) <*> arbitrary)
        -- non existing wallet id
        , (10, (,) <$> arbitrary <*> genElements (map V1.accIndex mAccounts))
        -- non existing wallet id and account index
        , (10, (,) <$> arbitrary <*> arbitrary)
        -- existing wallet id and account index
        , (10, pure (V1.accWalletId acc, V1.accIndex acc))
        ]

genNewAddress :: Model Symbolic -> Gen V1.NewAddress
genNewAddress model@Model{..} = do
    -- Pick wallet id and account index
    (wId, index) <- genGetAccount model
    let thisWallet = (== wId) . V1.walId . fst
        mCorrectOldPass = join $ snd <$> find thisWallet mWallets
    spendingPassword <- frequency
         -- pass can be unset
        [ (10, pure Nothing)
        -- pass can be empty
        , (10, pure $ Just mempty)
        -- pass can be arbitrary
        , (10, Just <$> arbitrary)
        -- pass can stay the same
        , (70, pure mCorrectOldPass)
        ]
    pure $ V1.NewAddress spendingPassword index wId

generator :: Model Symbolic -> Gen (Action Symbolic)
-- if wallet has not been reset, then we should first reset it!
generator (Model _ _ _ False) = pure ResetWalletA
generator model@Model{..} = frequency
    [ (1, pure ResetWalletA)
    , (5, CreateWalletA . WL.CreateWallet <$> genNewWalletRq)
    -- TODO: add generator for importing wallet from secret key
    , (5, pure GetWalletsA)
    -- This tests fetching existing wallet (except when there is no wallets in model)
    , (4, GetWalletA . V1.walId <$> genElements (map fst mWallets))
    -- This tests fetching probably non existing wallet
    , (1, GetWalletA <$> arbitrary)
--    -- This tests updates existing wallets (except when there is no wallets)
    , (4, UpdateWalletA . V1.walId <$> genElements (map fst mWallets) <*> arbitrary)
    -- This tests updating non existing wallet
    , (1, UpdateWalletA <$> arbitrary <*> arbitrary)
--    -- This tests updates password of existing wallets (except when there is no wallets)
    , (4, uncurry UpdateWalletPasswordA <$> genPasswordUpdate model)
    -- This tests updating non existing wallet
    , (1, UpdateWalletPasswordA <$> arbitrary <*> arbitrary)
    -- This tests deleting existing wallets
    , (4, DeleteWalletA . V1.walId <$> genElements (map fst mWallets))
    -- This tests deleting non existing wallet
    , (1, DeleteWalletA <$> arbitrary)
    -- This tests creating account in existing wallet
    , (4, uncurry CreateAccountA <$> genNewAccount model)
    -- This tests creating account in non existing wallet
    , (1, CreateAccountA <$> arbitrary <*> arbitrary)
    -- Test getting accounts of existing wallet
    , (4, GetAccountsA . V1.walId <$> genElements (map fst mWallets))
    -- Test getting accounts
    , (5, uncurry GetAccountA <$> genGetAccount model)
    -- Test getting accounts balance
    , (5, uncurry GetAccountBalanceA <$> genGetAccount model)
    -- Test getting accounts addresses
    , (5, uncurry GetAccountAddressesA <$> genGetAccount model)
    , (5, uncurry UpdateAccountA <$> genGetAccount model <*> arbitrary)
    -- Test deleting accounts
    , (5, uncurry DeleteAccountA <$> genGetAccount model)
    -- Test creating addresses
    , (5, CreateAddressA <$> genNewAddress model)
    ]

shrinker :: Action Symbolic -> [Action Symbolic]
shrinker _ = []

-- ------------------------------------------------------------------------
--
semantics :: WL.PassiveWalletLayer IO -> PassiveWallet -> Action Concrete -> IO (Response Concrete)
semantics pwl _ cmd = case cmd of
    ResetWalletA -> do
        -- TODO: check how it will behave if exception is raised here!
        WL.resetWalletState pwl
        return ResetWalletR
    CreateWalletA cw -> CreateWalletR <$> WL.createWallet pwl cw
    GetWalletsA      -> GetWalletsR <$> WL.getWallets pwl
    GetWalletA wId   -> GetWalletR <$> WL.getWallet pwl wId
    UpdateWalletA wId update -> UpdateWalletR <$> WL.updateWallet pwl wId update
    UpdateWalletPasswordA wId update -> UpdateWalletPasswordR <$> WL.updateWalletPassword pwl wId update
    DeleteWalletA wId -> DeleteWalletR <$> WL.deleteWallet pwl wId
    CreateAccountA wId ca -> CreateAccountR <$> WL.createAccount pwl wId ca
    GetAccountsA wId -> GetAccountsR <$> WL.getAccounts pwl wId
    GetAccountA wId index -> GetAccountR <$> WL.getAccount pwl wId index
    GetAccountBalanceA wId index -> GetAccountBalanceR <$> WL.getAccountBalance pwl wId index
    -- TODO: We are getting rid of pagination and filtering - so we should
    -- add back this later and test pagination and filtering as well
    GetAccountAddressesA wId index ->
        fmap GetAccountAddressesR . paginateAll' $ flip (WL.getAccountAddresses pwl wId index) NoFilters
    UpdateAccountA wId index update -> UpdateAccountR <$> WL.updateAccount pwl wId index update
    DeleteAccountA wId index -> DeleteAccountR <$> WL.deleteAccount pwl wId index
    CreateAddressA newAddr -> CreateAddressR <$> WL.createAddress pwl newAddr
  where
    paginateAll' :: Monad m => (RequestParams -> m (Either e (WalletResponse [a]))) -> m (Either e [a])
    paginateAll' request = fmap2 wrData . paginateAll $ \mPage mPerPage ->
        case (mPage, mPerPage) of
            (Just page, Just perPage) ->
                request $ RequestParams $ PaginationParams page perPage
            (Nothing, Nothing) ->
                error "paginateAll: this shouldn't happen by design"
      where
        fmap2 = fmap . fmap

-- TODO: reuse withLayer function defined in wallet-new/test/unit/Test/Spec/Fixture.hs
withWalletLayer
          :: (WL.PassiveWalletLayer IO -> PassiveWallet -> IO a)
          -> IO a
withWalletLayer cc = do
    Keystore.bracketTestKeystore $ \keystore -> do
        -- TODO: can we use fault injection in wallet to test expected failure cases?
        mockFInjects <- mkFInjects mempty
        WL.bracketPassiveWallet
            Kernel.UseInMemory
            devNull
            keystore
            mockNodeStateDef
            mockFInjects
            cc
  where
    devNull :: Severity -> Text -> IO ()
    devNull _ _ = return ()

-- NOTE: I (akegalj) was not sure how library exactly uses mock so there is an explanation here https://github.com/advancedtelematic/quickcheck-state-machine/issues/236#issuecomment-431858389
-- NOTE: `mock` is not used in a current quickcheck-state-machine-0.4.2 so in practice we could leave it out. Its still in an experimental phase and there is a possibility it will be added in future versions of this library, so we won't leave it out just yet
mock :: Model Symbolic -> Action Symbolic -> GenSym (Response Symbolic)
mock _ ResetWalletA      = pure ResetWalletR
-- TODO: add mocking up creating an actual wallet
-- For example you can take one from the model, just change wallet id
mock _ (CreateWalletA _) = pure $ CreateWalletR (Left $ WL.CreateWalletError Kernel.CreateWalletDefaultAddressDerivationFailed)
mock Model{..} GetWalletsA = pure $ GetWalletsR $ DB.fromList $ map fst mWallets
-- TODO: model other error paths like UnknownHdRoot?
mock Model{..} (GetWalletA wId) =
    let mExists = find ((wId ==) . V1.walId) $ map fst mWallets
        response = maybe (Left $ WL.GetWalletErrorNotFound wId) Right mExists
    in pure $ GetWalletR response
-- TODO: model other error paths?
mock Model{..} (UpdateWalletA wId V1.WalletUpdate{..}) =
    let thisWallet = (wId ==) . V1.walId
        -- TODO: use lenses
        update w = w { V1.walAssuranceLevel = uwalAssuranceLevel, V1.walName = uwalName }
        mExists = update <$> find thisWallet (map fst mWallets)
        response = maybe (Left $ WL.UpdateWalletErrorNotFound wId) Right mExists
    in pure $ UpdateWalletR response
mock Model{..} (UpdateWalletPasswordA wId V1.PasswordUpdate{..}) =
    let thisWallet = (wId ==) . V1.walId
        -- TODO: use lenses
        -- FIXME: update password timestamp here
        update w = w
        mExists = update <$> find thisWallet (map fst mWallets)
        -- TODO: instead return hd root error
        response = maybe (Left $ WL.UpdateWalletPasswordWalletIdDecodingFailed "In fact, I couldn't find the wallet with specific id" ) Right mExists
    in pure $ UpdateWalletPasswordR response
mock Model{..} (DeleteWalletA wId) =
    let thisWallet = (wId ==) . V1.walId
        mExists = find thisWallet (map fst mWallets)
        -- TODO: instead return hd root error
    in pure $ DeleteWalletR $
        if isJust mExists
            then Left $ WL.DeleteWalletWalletIdDecodingFailed "In fact, I couldn't find the wallet with specific id"
            else Right ()
mock Model{..} (CreateAccountA _ _) = pure $ CreateAccountR (Left $ WL.CreateAccountWalletIdDecodingFailed "In fact - this is just mocking")
mock Model{..} (GetAccountsA wId) = pure . GetAccountsR . Right . DB.fromList $ filter ((== wId) . V1.accWalletId) mAccounts
mock Model{..} (GetAccountA wId index) =
    let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
        mExists = find thisAccount mAccounts
    in pure $ GetAccountR $
        maybe (Left $ WL.GetAccountWalletIdDecodingFailed "In fact, I couldn't find the account with specific id and index") Right mExists
mock Model{..} (GetAccountBalanceA wId index) =
    let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
        mBalance = V1.AccountBalance . V1.accAmount <$> find thisAccount mAccounts
    in pure $ GetAccountBalanceR $
        maybe (Left $ WL.GetAccountWalletIdDecodingFailed "In fact, I couldn't find the account with specific id and index") Right mBalance
mock Model{..} (GetAccountAddressesA wId index) =
    let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
        mAccountAddresses = V1.accAddresses <$> find thisAccount mAccounts
    in pure $ GetAccountAddressesR $
        maybe (Left $ WL.GetAccountWalletIdDecodingFailed "In fact, I couldn't find the account with specific id and index") Right mAccountAddresses
mock Model{..} (UpdateAccountA wId index V1.AccountUpdate{..}) =
    let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
        mAccount = update <$> find thisAccount mAccounts
        update acc = acc { V1.accName = uaccName }
    in pure $ UpdateAccountR $
        maybe (Left $ WL.UpdateAccountWalletIdDecodingFailed "In fact, I couldn't find the account with specific id and index") Right mAccount
mock Model{..} (DeleteAccountA wId index) =
    let thisAccount V1.Account{..} = accWalletId == wId && accIndex == index
        mAccount = find thisAccount mAccounts
    in pure $ DeleteAccountR $
        if isJust mAccount
            then Left $ WL.DeleteAccountWalletIdDecodingFailed "In fact, I couldn't find the account with specific id and index"
            else Right ()
mock _ (CreateAddressA _) =
    pure $ CreateAddressR $ Left $ WL.CreateAddressAddressDecodingFailed "Mocking address creation"


------------------------------------------------------------------------

-- TODO: model invariant?
-- TODO: model distribution?
stateMachine :: WL.PassiveWalletLayer IO -> PassiveWallet -> StateMachine Model Action IO Response
stateMachine pwl pw =
    StateMachine
        initModel
        transitions
        preconditions
        postconditions
        Nothing
        generator
        Nothing
        shrinker
        (semantics pwl pw)
        mock

prop_wallet :: WL.PassiveWalletLayer IO -> PassiveWallet -> Property
prop_wallet pwl pw = forAllCommands sm Nothing $ \cmds -> monadicIO $ do
    print $ commandNamesInOrder cmds
    (hist, _, res) <- runCommands sm cmds
    prettyCommands sm hist $
        checkCommandNames cmds (res === Ok)
  where
    sm = stateMachine pwl pw

prop_walletParallel :: WL.PassiveWalletLayer IO -> PassiveWallet -> Property
prop_walletParallel pwl pw =
  forAllParallelCommands sm $ \cmds -> monadicIO $
    -- TODO: fix quickcheck with state machine pretty printer output (works well with tasty)
    prettyParallelCommands cmds =<< runParallelCommandsNTimes 100 sm cmds
  where
    sm = stateMachine pwl pw
